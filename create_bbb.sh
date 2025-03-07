#!/bin/bash

set -e

if ! command -v docker &> /dev/null
then
    echo "Docker not found! Required Docker 20 or greater"
    exit
fi

DOCKER_VERSION=$(docker version -f "{{.Server.Version}}")
DOCKER_VERSION_MAJOR=$(echo "$DOCKER_VERSION"| cut -d'.' -f 1)

if [ ! "${DOCKER_VERSION_MAJOR}" -ge 20 ] ; then
    echo "Invalid Docker version! Required Docker 20 or greater"
    exit
fi

NAME=
DOMAIN=test
IP=172.17.0.2
IMAGE=imdt/bigbluebutton:3.0.x-develop
GITHUB_FORK_SKIP=0
GITHUB_USER=
CERT_DIR=
CUSTOM_SCRIPT=
REMOVE_CONTAINER=0
CONTAINER_IMAGE=
DOCKER_CUSTOM_PARAMS=""
DOCKER_NETWORK_PARAMS=""


for var in "$@"
do
    if [[ ! "$var" == *"--"* ]] && [ ! $NAME ]; then
        NAME="$var"
    elif [[ "$var" == --image* ]] ; then
        IMAGE=${var#*=}
        CONTAINER_IMAGE=$IMAGE
    elif [[ "$var" == "--remove" ]] ; then
        REMOVE_CONTAINER=1
    fi
done

if [ ! $NAME ] ; then
    echo ""
    echo "Missing param name: ./create_bbb.sh [OPTION] {name}" 
    echo ""
    echo ""
    echo "List of options:"
    echo "--update"
    echo "--fork-skip"
    echo "--fork=github_user"
    echo "--domain=domain_name"
    echo "--ip=ip_address"
    echo "--image=docker_image"
    echo "--cert=certificate_dir"
    echo "--custom-script=path/script.sh"
    echo "--docker-custom-params=\"-v /tmp:/tmp:rw\""
    echo "--docker-network-params=\"--net=host\""
    echo ""
    echo ""
    exit 1
fi

echo "Container name: $NAME"

#for container_id in $(docker ps -f name=$NAME -q) ; do 
for container_name in $(docker ps --format '{{.Names}}' | grep -w "^$NAME$"); do
    echo "Killing container $container_name"
    docker kill $container_name;
done

# for container_id in $(docker ps -f name=$NAME -q -a); do
for container_name in $(docker ps -a --format '{{.Names}}' | grep -w "^$NAME$"); do
    CONTAINER_IMAGE="$(docker inspect --format '{{ .Config.Image }}' $container_name)"
    echo "Removing container $NAME" 
    docker rm $container_name;
done

# Remove entries from ~/.ssh/config
if [ -f ~/.ssh/config ] ; then
  sed -i '/^Host '"$NAME"'$/,/^$/d' ~/.ssh/config
  sed -i '/^Host '"$NAME-with-ports"'$/,/^$/d' ~/.ssh/config
fi

if [ $REMOVE_CONTAINER == 1 ]; then
  if [ $CONTAINER_IMAGE ]; then
    echo
    echo "----"
    read -p "Do you want to remove the image $CONTAINER_IMAGE (y/n)? " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]];  then
      docker image rm $CONTAINER_IMAGE --force
      echo "Image $CONTAINER_IMAGE removed!"
    fi
  fi

  if [ -d $HOME/$NAME ] ; then
    echo
    echo "----"
    read -p "Do you want to remove all files from $HOME/$NAME (y/n)? " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]];  then
      rm -rf $HOME/$NAME
    fi
  fi

  echo "Container $NAME removed!"
  exit 0
fi


echo "Using image $IMAGE"

for var in "$@"
do
    if [ "$var" == "--update" ] ; then
        has_docker_image=$(docker image ls $IMAGE -q | wc -l)
        if [[ "$has_docker_image" != "0" ]]; then
            echo "Image '$IMAGE' available on your system, checking for newer version"
            docker image tag $IMAGE ${IMAGE}_previous
            docker image rm $IMAGE
        else
            echo "Image '$IMAGE' not available on your system, downloading it..."
        fi
        
        docker pull $IMAGE
	
        if [[ "$has_docker_image" != "0" ]]; then
            docker rmi -f ${IMAGE}_previous
        fi
    elif [[ "$var" == --ip* ]] ; then
        IP=${var#*=}
        if [[ $IP == 172.17.* ]] ; then
            echo "IP address can't start with 172.17"
            return 1 2>/dev/null
            exit 1
        else
            echo "Setting IP to $IP"
        fi
    elif [ "$var" == "--fork-skip" ] ; then
        GITHUB_FORK_SKIP=1
    elif [[ "$var" == --fork* ]] ; then
        GITHUB_USER=${var#*=}
    elif [[ "$var" == --cert* ]] ; then
        CERT_DIR=${var#*=}
    elif [[ "$var" == --custom-script* ]] ; then
        CUSTOM_SCRIPT=${var#*=}
    elif [[ "$var" == --domain* ]] ; then
        DOMAIN=${var#*=}
    elif [[ "$var" == --docker-custom-params* ]] ; then
        DOCKER_CUSTOM_PARAMS=${var#*=}
        echo "Custom params will be appended to 'docker run': $DOCKER_CUSTOM_PARAMS"
    elif [[ "$var" == --docker-network-params* ]] ; then
        DOCKER_NETWORK_PARAMS=${var#*=}
    fi
done

mkdir -p $HOME/$NAME/
HOSTNAME=$NAME.$DOMAIN


BBB_SRC_FOLDER=$HOME/$NAME/bigbluebutton
if [ $GITHUB_FORK_SKIP == 1 ]; then
        mkdir -p $BBB_SRC_FOLDER
        echo "Skipping 'git clone' of Bigbluebutton project"
elif [ -d $BBB_SRC_FOLDER ] ; then
        echo "Directory $HOME/$NAME/bigbluebutton already exists, not initializing."
        sleep 2;
else
        cd $HOME/$NAME/

        if [ $GITHUB_USER ] ; then
            git clone git@github.com:$GITHUB_USER/bigbluebutton.git
            
            echo "Adding Git Upstream to https://github.com/bigbluebutton/bigbluebutton.git"
            cd $HOME/$NAME/bigbluebutton
            git remote add upstream https://github.com/bigbluebutton/bigbluebutton.git
        else
            git clone https://github.com/bigbluebutton/bigbluebutton.git
        fi
fi

cd

###Certificate start -->
mkdir $HOME/$NAME/certs/ -p
if [ $CERT_DIR ] ; then
    echo "Certificate directory passed: $CERT_DIR"
    if [ ! -f $CERT_DIR/fullchain.pem ] ; then
        echo "Error! $CERT_DIR/fullchain.pem not found."
        exit 0
    elif [ ! -f $CERT_DIR/privkey.pem ] ; then
        echo "Error! $CERT_DIR/privkey.pem not found."
        exit 0
    fi

    cp $CERT_DIR/fullchain.pem $HOME/$NAME/certs/fullchain.pem
    cp $CERT_DIR/privkey.pem $HOME/$NAME/certs/privkey.pem
    echo "Using provided certificate successfully!"
elif [ -f $HOME/$NAME/certs/fullchain.pem ] && [ -f $HOME/$NAME/certs/privkey.pem ] ; then
    echo "Certificate already exists, not creating."
    sleep 2;
else
    mkdir $HOME/$NAME/certs-source/ -p
    #Create root CA
    cd $HOME/$NAME/certs-source/
    openssl rand -base64 48 > bbb-dev-ca.pass ;
    chmod 600 bbb-dev-ca.pass ;
    openssl genrsa -des3 -out bbb-dev-ca.key -passout file:bbb-dev-ca.pass 2048 ;

    openssl req -x509 -new -nodes -key bbb-dev-ca.key -sha256 -days 1460 -passin file:bbb-dev-ca.pass -out bbb-dev-ca.crt -subj "/C=CA/ST=BBB/L=BBB/O=BBB/OU=BBB/CN=BBB-DEV" ;

    #Copy the CA to your trusted certificates ( so your browser will accept this certificate )
    sudo mkdir /usr/local/share/ca-certificates/bbb-dev/ -p
    sudo cp $HOME/$NAME/certs-source/bbb-dev-ca.crt /usr/local/share/ca-certificates/bbb-dev/
    sudo chmod 644 /usr/local/share/ca-certificates/bbb-dev/bbb-dev-ca.crt
    
    if command -v update-ca-certificates >/dev/null 2>&1; then
        sudo update-ca-certificates
    elif command -v update-ca-trust >/dev/null 2>&1; then
        sudo update-ca-trust extract
    else
        echo "Warning: No certificate update tool found."
    fi

    #Generate a certificate for your first local BBB server
    cd $HOME/$NAME/certs-source/
    openssl genrsa -out ${HOSTNAME}.key 2048
    rm ${HOSTNAME}.csr ${HOSTNAME}.crt ${HOSTNAME}.key -f
    cat > ${HOSTNAME}.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${HOSTNAME}
EOF

    openssl req -nodes -newkey rsa:2048 -keyout ${HOSTNAME}.key -out ${HOSTNAME}.csr -subj "/C=CA/ST=BBB/L=BBB/O=BBB/OU=BBB/CN=${HOSTNAME}" -addext "subjectAltName = DNS:${HOSTNAME}" 
    openssl x509 -req -in ${HOSTNAME}.csr -CA bbb-dev-ca.crt -CAkey bbb-dev-ca.key -CAcreateserial -out ${HOSTNAME}.crt -days 825 -sha256 -passin file:bbb-dev-ca.pass -extfile ${HOSTNAME}.ext

    cd $HOME/$NAME/
    cp $HOME/$NAME/certs-source/bbb-dev-ca.crt certs/
    cat $HOME/$NAME/certs-source/$HOSTNAME.crt > certs/fullchain.pem
    cat $HOME/$NAME/certs-source/bbb-dev-ca.crt >> certs/fullchain.pem
    cat $HOME/$NAME/certs-source/$HOSTNAME.key > certs/privkey.pem
    rm -r $HOME/$NAME/certs-source
    echo "Self-signed certificate created successfully!"
fi
### <-- Certificate end


SUBNET="$(echo $IP |cut -d "." -f 1).$(echo $IP |cut -d "." -f 2).0.0"

if [ $SUBNET == "172.17.0.0" ] ; then
    SUBNETNAME="bridge"
else
    SUBNETNAME="bbb_network_$(echo $IP |cut -d "." -f 1)_$(echo $IP |cut -d "." -f 2)"
fi

if [ ! "$(docker network ls | grep $SUBNETNAME)" ]; then
  echo "Creating $SUBNETNAME network ..."
  docker network create --driver=bridge --subnet=$SUBNET/16 $SUBNETNAME
else
  echo "$SUBNETNAME network exists."
fi


if [ $SUBNETNAME != "bridge" ] && [ "$DOCKER_NETWORK_PARAMS" == "" ] ; then
    DOCKER_NETWORK_PARAMS="--ip=$IP --network $SUBNETNAME"
fi


#Sync cache dirs between host machine and Docker container (to speed up building time)
mkdir -p $HOME/.m2 #Sbt publish
mkdir -p $HOME/.ivy2 #Sbt publish
mkdir -p $HOME/.cache #Maven
mkdir -p $HOME/.gradle #Gradle
mkdir -p $HOME/.npm #Npm

docker run -d --name=$NAME --hostname=$HOSTNAME $DOCKER_NETWORK_PARAMS $DOCKER_CUSTOM_PARAMS -env="container=docker" --env="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" --env="DEBIAN_FRONTEND=noninteractive" -v "/var/run/docker.sock:/docker.sock:rw" --cap-add="NET_ADMIN" --privileged -v "$HOME/$NAME/certs/:/local/certs:rw" --cgroupns=host -v "$BBB_SRC_FOLDER:/home/bigbluebutton/src:rw" -v "/tmp:/tmp:rw" -v "$HOME/.m2:/home/bigbluebutton/.m2:rw" -v "$HOME/.ivy2:/home/bigbluebutton/.ivy2:rw" -v "$HOME/.cache:/home/bigbluebutton/.cache:rw" -v "$HOME/.gradle:/home/bigbluebutton/.gradle:rw" -v "$HOME/.npm:/home/bigbluebutton/.npm:rw" -t $IMAGE

if [ $CUSTOM_SCRIPT ] && [ -f $CUSTOM_SCRIPT ] ; then
    echo "Executing $CUSTOM_SCRIPT on container $NAME"
    cat $CUSTOM_SCRIPT | docker exec -i $NAME bash
fi

mkdir -p $HOME/.bbb/
echo "docker exec -u bigbluebutton -w /home/bigbluebutton/ -it $NAME /bin/bash  -l" > $HOME/.bbb/$NAME.sh
chmod 755 $HOME/.bbb/$NAME.sh

# Create SSH key if absent. Prefer ed25519 if available.
if [ ! -e ~/.ssh/id_ed25519.pub ] && [ ! -e ~/.ssh/id_rsa.pub ]; then
    echo "No SSH key found, generating ed25519 key pair."
    ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
fi

# Determine which public key to use.
if [ -e ~/.ssh/id_ed25519.pub ]; then
    SSH_PUB_KEY=$(cat ~/.ssh/id_ed25519.pub)
elif [ -e ~/.ssh/id_rsa.pub ]; then
    SSH_PUB_KEY=$(cat ~/.ssh/id_rsa.pub)
fi

docker exec -u bigbluebutton $NAME bash -c "mkdir -p ~/.ssh && echo '$SSH_PUB_KEY' >> ~/.ssh/authorized_keys"
sleep 5s

if [ "$DOCKER_NETWORK_PARAMS" == "--net=host" ] ; then
    DOCKERIP="$(hostname -I | awk '{print $1}')"
    echo "It seems you are using the param --net=host, the container will receive the same IP of the Host: $DOCKERIP"
elif [ "$SUBNETNAME" == "bridge" ] ; then
    DOCKERIP="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' $NAME)"
else
    DOCKERIP="$(docker inspect --format '{{ .NetworkSettings.Networks.'"$SUBNETNAME"'.IPAddress }}' $NAME)"
fi

if [ ! $DOCKERIP ] ; then
    echo "ERROR! Trying to discover Docker IP"
    exit 0
fi

sudo sed -i "/$HOSTNAME/d" /etc/hosts
echo $DOCKERIP $HOSTNAME | sudo tee -a /etc/hosts

touch ~/.ssh/known_hosts
ssh-keygen -R "$HOSTNAME"
ssh-keygen -R "$DOCKERIP"
# ssh-keygen -R [hostname],[ip_address]

ssh-keyscan -H "$DOCKERIP" >> ~/.ssh/known_hosts
ssh-keyscan -H "$HOSTNAME" >> ~/.ssh/known_hosts
# ssh-keyscan -H [hostname],[ip_address] >> ~/.ssh/known_hosts

if [ ! -z "$(tail -1 ~/.ssh/config)" ] ; then
  echo "" >> ~/.ssh/config
fi

if ! grep -q "\Host ${NAME}$" ~/.ssh/config ; then
  echo "Adding alias $NAME to ~/.ssh/config"
	echo "Host $NAME
    HostName $HOSTNAME
    User bigbluebutton
    Port 22
" >> ~/.ssh/config
fi

# Create tunnel for Redis (6379) and Mongodb (4101)
if ! grep -q "\Host ${NAME}-with-ports$" ~/.ssh/config ; then
    echo "Adding alias $NAME-with-ports to ~/.ssh/config"

# Don't LocalForward ports case it's running on the host itself IP
  if [ "$DOCKER_NETWORK_PARAMS" != "--net=host" ] ; then
      echo "Host $NAME-with-ports
    HostName $HOSTNAME
    User bigbluebutton
    Port 22
    LocalForward 6379 localhost:6379
    LocalForward 4101 localhost:4101
" >> ~/.ssh/config
  else
    echo "Host $NAME-with-ports
    HostName $HOSTNAME
    User bigbluebutton
    Port 22
" >> ~/.ssh/config
  fi
fi

#Set Zsh as default and copy local bindkeys
if [ -d ~/.oh-my-zsh ]; then
    echo "Found oh-my-zsh installed. Setting as default in Docker as well."
    docker exec -u bigbluebutton $NAME bash -c "sudo chsh -s /bin/zsh bigbluebutton"
    grep "^bindkey" ~/.zshrc | xargs -I{} docker exec -u bigbluebutton $NAME bash -c "echo {} >> /home/bigbluebutton/.zshrc"
fi


echo "------------------"
echo "Docker infos"
echo "IP $DOCKERIP"
echo "Default user: bigbluebutton"
echo "Default passwork: bigbluebutton"
echo "" 
echo ""
docker exec -u bigbluebutton $NAME bash -c "bbb-conf --salt"
echo ""
echo ""
echo "------------------"
tput setaf 2; echo "Container created successfully!"; tput sgr0
echo ""
tput setaf 3; echo "BBB URL: https://$HOSTNAME"; tput sgr0
tput setaf 3; echo "Access Docker using: ssh $NAME"; tput sgr0
echo ""
echo "------------------"
echo ""
echo ""
tput setaf 4; echo "or to run Akka/Mongo locally use: ssh $NAME-with-ports"; tput sgr0
echo ""
echo ""

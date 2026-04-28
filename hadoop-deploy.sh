#!/bin/bash

set -e

############################################
# CONFIG
############################################

containers=("namenode" "datanode1" "datanode2")
image="images:debian/12"
hadoop_user="hdoop"
hadoop_password="hdoop"
hadoop_tar="hadoop-3.4.0.tar.gz"
hadoop_url="https://dlcdn.apache.org/hadoop/common/hadoop-3.4.0/hadoop-3.4.0.tar.gz"

############################################
# PRECHECK: LXD PERMISSION
############################################

if ! groups | grep -qw lxd; then
    echo "ERROR: user not in lxd group"
    echo "Run: sudo usermod -aG lxd $USER && newgrp lxd"
    exit 1
fi

############################################
# DOWNLOAD HADOOP
############################################

if [ ! -f "$hadoop_tar" ]; then
    echo "Downloading Hadoop..."
    wget "$hadoop_url"
fi

############################################
# INSTALL LXD IF NEEDED
############################################

if ! command -v lxd &> /dev/null; then
    echo "Installing LXD..."
    sudo snap install lxd
fi

############################################
# INITIALIZE LXD (SAFE)
############################################

lxd init --auto || true

############################################
# CREATE CONTAINERS
############################################

for c in "${containers[@]}"; do
    if lxc list -c n --format csv | grep -wq "$c"; then
        echo "Container $c exists"
    else
        echo "Creating container $c"
        lxc launch "$image" "$c"
        sleep 5
    fi
done

############################################
# CONFIGURE CONTAINERS
############################################

for c in "${containers[@]}"; do

echo "Configuring $c"

lxc exec "$c" -- bash -c '
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free
deb http://deb.debian.org/debian bookworm-updates main contrib non-free
deb http://security.debian.org/debian-security bookworm-security main contrib non-free
EOF
'

lxc exec "$c" -- apt update -y

lxc exec "$c" -- apt install -y \
wget curl gnupg openssh-server openssh-client ca-certificates

############################################
# INSTALL JAVA (TEMURIN 8)
############################################

lxc exec "$c" -- bash -c '
mkdir -p /usr/share/keyrings

wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
| gpg --dearmor -o /usr/share/keyrings/adoptium.gpg

echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] \
https://packages.adoptium.net/artifactory/deb bookworm main" \
> /etc/apt/sources.list.d/adoptium.list

apt update
apt install -y temurin-8-jdk
'

############################################
# CREATE USER
############################################

if ! lxc exec "$c" -- id "$hadoop_user" &>/dev/null; then
    lxc exec "$c" -- adduser --disabled-password --gecos "" "$hadoop_user"
    lxc exec "$c" -- bash -c "echo '$hadoop_user:$hadoop_password' | chpasswd"
fi

############################################
# SSH SETUP
############################################

lxc exec "$c" -- systemctl enable ssh || true
lxc exec "$c" -- systemctl start ssh || true

lxc exec "$c" -- sudo -u "$hadoop_user" mkdir -p /home/$hadoop_user/.ssh

lxc exec "$c" -- sudo -u "$hadoop_user" bash -c '
if [ ! -f ~/.ssh/id_rsa ]; then
  ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
fi
'

done

############################################
# DISTRIBUTE SSH KEYS
############################################

namenode="${containers[0]}"

pubkey=$(lxc exec "$namenode" -- sudo -u "$hadoop_user" cat /home/$hadoop_user/.ssh/id_rsa.pub)

for c in "${containers[@]}"; do
lxc exec "$c" -- bash -c "
grep -qxF '$pubkey' /home/$hadoop_user/.ssh/authorized_keys || \
echo '$pubkey' >> /home/$hadoop_user/.ssh/authorized_keys
"
lxc exec "$c" -- chown -R "$hadoop_user:$hadoop_user" /home/$hadoop_user/.ssh
lxc exec "$c" -- chmod 700 /home/$hadoop_user/.ssh
lxc exec "$c" -- chmod 600 /home/$hadoop_user/.ssh/authorized_keys
done

############################################
# /etc/hosts CLEAN + SET
############################################

hosts_tmp=$(mktemp)

lxc list -c n4 --format csv | while IFS=, read name ip; do
echo "$ip $name" >> "$hosts_tmp"
done

for c in "${containers[@]}"; do
lxc file push "$hosts_tmp" "$c"/etc/hosts
done

rm -f "$hosts_tmp"

############################################
# INSTALL HADOOP
############################################

for c in "${containers[@]}"; do

echo "Installing Hadoop on $c"

lxc file push "$hadoop_tar" "$c"/opt/

lxc exec "$c" -- bash -c "
cd /opt
rm -rf hadoop
tar xzf $hadoop_tar
mv hadoop-3.4.0 hadoop
rm $hadoop_tar
chown -R $hadoop_user:$hadoop_user /opt/hadoop
"

done

############################################
# JAVA HOME DETECTION
############################################

javac_path=$(lxc exec "$namenode" -- which javac || true)

if [ -z "$javac_path" ]; then
    echo "ERROR: Java not found"
    exit 1
fi

java_home=$(lxc exec "$namenode" -- bash -c \
"readlink -f $javac_path | sed 's:/bin/javac$::'")

echo "JAVA_HOME = $java_home"

############################################
# APPLY JAVA_HOME TO ALL NODES
############################################

for c in "${containers[@]}"; do
lxc exec "$c" -- bash -c \
"sed -i 's|# export JAVA_HOME=.*|export JAVA_HOME=$java_home|' \
/opt/hadoop/etc/hadoop/hadoop-env.sh"
done

############################################
# DONE
############################################

echo ""
echo "=================================="
echo "Hadoop LXD cluster bootstrap done"
lxc list
echo "=================================="

#!/bin/bash

set -e

########################################
# VARIABLES
########################################

hadoop_version="3.4.0"
hadoop_archive="hadoop-${hadoop_version}.tar.gz"
hadoop_home="/opt/hadoop"
hadoop_user="hdoop"

containers=("namenode" "datanode1" "datanode2")
replication="1"

NameNode="${containers[0]}"

########################################
# PRECHECK
########################################

if ! groups | grep -qw lxd; then
  echo "ERROR: user not in lxd group"
  exit 1
fi

########################################
# GET NAMENODE IP
########################################

name_node_ip=$(lxc list "$NameNode" -c 4 --format csv | awk '{print $1}')

if [ -z "$name_node_ip" ]; then
  echo "ERROR: NameNode IP not found"
  exit 1
fi

echo "NameNode IP: $name_node_ip"

########################################
# VERIFY HADOOP EXISTS
########################################

for c in "${containers[@]}"; do
  if ! lxc exec "$c" -- test -d /opt/hadoop; then
    echo "ERROR: Hadoop not installed on $c"
    exit 1
  fi
done

########################################
# DETECT JAVA_HOME
########################################

javac_path=$(lxc exec "$NameNode" -- which javac || true)

if [ -z "$javac_path" ]; then
  echo "ERROR: Java not found"
  exit 1
fi

java_home=$(lxc exec "$NameNode" -- bash -c \
"readlink -f $javac_path | sed 's:/bin/javac$::'")

echo "JAVA_HOME detected: $java_home"

########################################
# APPLY JAVA_HOME TO ALL NODES
########################################

for c in "${containers[@]}"; do
lxc exec "$c" -- bash -c \
"sed -i 's|^# export JAVA_HOME=.*|export JAVA_HOME=${java_home}|' \
${hadoop_home}/etc/hadoop/hadoop-env.sh"
done

########################################
# UPDATE .BASHRC (IDEMPOTENT)
########################################

for c in "${containers[@]}"; do

lxc exec "$c" -- sudo -u "$hadoop_user" bash -c "

grep -q 'HADOOP_HOME' ~/.bashrc || cat >> ~/.bashrc <<EOF

# Hadoop
export JAVA_HOME=${java_home}
export HADOOP_HOME=${hadoop_home}
export PATH=\$PATH:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin

EOF
"
done

########################################
# CREATE CONFIG FILES
########################################

cat <<EOF > core-site.xml
<configuration>
 <property>
  <name>fs.defaultFS</name>
  <value>hdfs://${NameNode}:9000</value>
 </property>
 <property>
  <name>hadoop.tmp.dir</name>
  <value>${hadoop_home}/tmpdata</value>
 </property>
</configuration>
EOF

cat <<EOF > hdfs-site.xml
<configuration>
 <property>
  <name>dfs.replication</name>
  <value>${replication}</value>
 </property>
 <property>
  <name>dfs.namenode.name.dir</name>
  <value>file:${hadoop_home}/dfsdata/namenode</value>
 </property>
 <property>
  <name>dfs.datanode.data.dir</name>
  <value>file:${hadoop_home}/dfsdata/datanode</value>
 </property>
</configuration>
EOF

cat <<EOF > mapred-site.xml
<configuration>
 <property>
  <name>mapreduce.framework.name</name>
  <value>yarn</value>
 </property>
</configuration>
EOF

cat <<EOF > yarn-site.xml
<configuration>
 <property>
  <name>yarn.nodemanager.aux-services</name>
  <value>mapreduce_shuffle</value>
 </property>
 <property>
  <name>yarn.resourcemanager.hostname</name>
  <value>${NameNode}</value>
 </property>
</configuration>
EOF

########################################
# WORKERS FILE
########################################

> workers
for ((i=1;i<${#containers[@]};i++)); do
echo "${containers[$i]}" >> workers
done

########################################
# PUSH CONFIG TO ALL NODES (DIRECT)
########################################

for c in "${containers[@]}"; do
echo "Pushing config to $c"

lxc file push core-site.xml "$c/${hadoop_home}/etc/hadoop/"
lxc file push hdfs-site.xml "$c/${hadoop_home}/etc/hadoop/"
lxc file push mapred-site.xml "$c/${hadoop_home}/etc/hadoop/"
lxc file push yarn-site.xml "$c/${hadoop_home}/etc/hadoop/"
lxc file push workers "$c/${hadoop_home}/etc/hadoop/"
done

########################################
# VERIFY SSH CONNECTIVITY
########################################

echo "Checking SSH connectivity..."

for node in "${containers[@]}"; do
  if ! lxc exec "$NameNode" -- sudo -u "$hadoop_user" \
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "$node" hostname >/dev/null 2>&1; then
    echo "ERROR: SSH to $node failed"
    exit 1
  fi
done

echo "SSH connectivity OK"

########################################
# CREATE HDFS DIRECTORIES
########################################

lxc exec "$NameNode" -- bash -c "
mkdir -p ${hadoop_home}/tmpdata
mkdir -p ${hadoop_home}/dfsdata/namenode
mkdir -p ${hadoop_home}/dfsdata/datanode
chown -R ${hadoop_user}:${hadoop_user} ${hadoop_home}
"

########################################
# FORMAT HDFS (SAFE)
########################################

if lxc exec "$NameNode" -- pgrep -f NameNode > /dev/null; then
  echo "ERROR: NameNode is running. Stop Hadoop before formatting."
  exit 1
fi

if ! lxc exec "$NameNode" -- test -d ${hadoop_home}/dfsdata/namenode/current; then
  echo "Formatting HDFS..."
  lxc exec "$NameNode" -- sudo -u "$hadoop_user" \
  ${hadoop_home}/bin/hdfs namenode -format -force
else
  echo "HDFS already formatted"
fi

########################################
# START HADOOP
########################################

echo "Starting DFS..."
lxc exec "$NameNode" -- sudo -u "$hadoop_user" \
${hadoop_home}/sbin/start-dfs.sh

echo "Starting YARN..."
lxc exec "$NameNode" -- sudo -u "$hadoop_user" \
${hadoop_home}/sbin/start-yarn.sh

########################################
# VERIFY (STRICT)
########################################

sleep 3

echo "Verifying Hadoop processes..."

jps_output=$(lxc exec "$NameNode" -- sudo -u "$hadoop_user" jps)

echo "$jps_output"

echo "$jps_output" | grep -q NameNode \
  || { echo "ERROR: NameNode failed to start"; exit 1; }

echo "$jps_output" | grep -q ResourceManager \
  || { echo "ERROR: ResourceManager failed"; exit 1; }

########################################
# CLEAN
########################################

rm -f core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml workers

echo ""
echo "=================================="
echo "Hadoop cluster started successfully"
echo "NameNode: ${NameNode}"
echo "HDFS UI: http://${name_node_ip}:9870"
echo "=================================="

#!/bin/bash

set -euo pipefail

########################################
# VARIABLES
########################################

hadoop_version="3.4.0"
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

name_node_ip=$(lxc list "$NameNode" -c 4 --format csv | cut -d',' -f1)

[ -z "$name_node_ip" ] && { echo "ERROR: NameNode IP not found"; exit 1; }

echo "NameNode IP: $name_node_ip"

########################################
# VERIFY HADOOP EXISTS
########################################

for c in "${containers[@]}"; do
  lxc exec "$c" -- test -d "$hadoop_home" || {
    echo "ERROR: Hadoop missing on $c"
    exit 1
  }
done

########################################
# DETECT JAVA_HOME (ROBUST)
########################################

java_home=$(lxc exec "$NameNode" -- bash -c \
'readlink -f $(which javac) 2>/dev/null | sed "s:/bin/javac$::"')

[ -z "$java_home" ] && { echo "ERROR: Java not found"; exit 1; }

echo "JAVA_HOME detected: $java_home"

########################################
# APPLY JAVA_HOME (SAFE INSERT)
########################################

for c in "${containers[@]}"; do
lxc exec "$c" -- bash -c "
grep -q JAVA_HOME ${hadoop_home}/etc/hadoop/hadoop-env.sh \
&& sed -i 's|^.*JAVA_HOME=.*|export JAVA_HOME=${java_home}|' ${hadoop_home}/etc/hadoop/hadoop-env.sh \
|| echo 'export JAVA_HOME=${java_home}' >> ${hadoop_home}/etc/hadoop/hadoop-env.sh
"
done

########################################
# UPDATE .BASHRC (IDEMPOTENT)
########################################

for c in "${containers[@]}"; do
lxc exec "$c" -- sudo -u "$hadoop_user" bash -c "
grep -q HADOOP_HOME ~/.bashrc || cat >> ~/.bashrc <<EOF

# Hadoop
export JAVA_HOME=${java_home}
export HADOOP_HOME=${hadoop_home}
export PATH=\$PATH:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin

EOF
"
done

########################################
# CONFIG FILES (USE HOSTNAME, NOT IP)
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
  <name>yarn.resourcemanager.hostname</name>
  <value>${NameNode}</value>
 </property>
 <property>
  <name>yarn.nodemanager.aux-services</name>
  <value>mapreduce_shuffle</value>
 </property>
</configuration>
EOF

########################################
# WORKERS
########################################

> workers
for ((i=1;i<${#containers[@]};i++)); do
  echo "${containers[$i]}" >> workers
done

########################################
# PUSH CONFIG
########################################

for c in "${containers[@]}"; do
echo "Pushing config to $c"

for f in core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml workers; do
  lxc file push "$f" "$c/${hadoop_home}/etc/hadoop/$f"
done

done

########################################
# SSH CHECK (STRONGER)
########################################

echo "Checking SSH..."

for node in "${containers[@]}"; do
lxc exec "$NameNode" -- sudo -u "$hadoop_user" bash -c "
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $node 'echo ok' >/dev/null
" || { echo "ERROR: SSH to $node failed"; exit 1; }
done

########################################
# PREPARE DIRECTORIES (ALL NODES)
########################################

for c in "${containers[@]}"; do
lxc exec "$c" -- bash -c "
mkdir -p ${hadoop_home}/tmpdata
mkdir -p ${hadoop_home}/dfsdata/{namenode,datanode}
chown -R ${hadoop_user}:${hadoop_user} ${hadoop_home}
"
done

########################################
# SAFE FORMAT
########################################

if ! lxc exec "$NameNode" -- test -d ${hadoop_home}/dfsdata/namenode/current; then
  echo "Formatting HDFS..."
  lxc exec "$NameNode" -- sudo -u "$hadoop_user" \
  ${hadoop_home}/bin/hdfs namenode -format -force
else
  echo "Already formatted"
fi

########################################
# START SERVICES
########################################

lxc exec "$NameNode" -- sudo -u "$hadoop_user" ${hadoop_home}/sbin/start-dfs.sh
lxc exec "$NameNode" -- sudo -u "$hadoop_user" ${hadoop_home}/sbin/start-yarn.sh

########################################
# VERIFY
########################################

sleep 5

jps_output=$(lxc exec "$NameNode" -- sudo -u "$hadoop_user" jps)

echo "$jps_output"

echo "$jps_output" | grep -q NameNode || exit 1
echo "$jps_output" | grep -q ResourceManager || exit 1

########################################
# CLEAN
########################################

rm -f core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml workers

echo ""
echo "=================================="
echo "Hadoop cluster READY"
echo "NameNode: ${NameNode}"
echo "HDFS UI: http://${name_node_ip}:9870"
echo "=================================="
#!/bin/bash

set -e

########################################
# VARIABLES
########################################

HBASE_VERSION="2.4.17"
SQOOP_VERSION="1.4.7"

HBASE_TAR="hbase-${HBASE_VERSION}-bin.tar.gz"
SQOOP_TAR="sqoop-${SQOOP_VERSION}.bin__hadoop-3.2.0.tar.gz"

HADOOP_HOME="/opt/hadoop"
HBASE_HOME="/opt/hbase"
SQOOP_HOME="/opt/sqoop"

HADOOP_USER="hdoop"
CONTAINER="NameNode"

########################################
# DOWNLOAD (HOST SIDE)
########################################

echo "Downloading HBase & Sqoop (if needed)..."

[ -f "$HBASE_TAR" ] || wget https://archive.apache.org/dist/hbase/${HBASE_VERSION}/${HBASE_TAR}
[ -f "$SQOOP_TAR" ] || wget https://archive.apache.org/dist/sqoop/${SQOOP_VERSION}/${SQOOP_TAR}

########################################
# PUSH TO CONTAINER
########################################

echo "Pushing to container..."

lxc file push "$HBASE_TAR" ${CONTAINER}/opt/
lxc file push "$SQOOP_TAR" ${CONTAINER}/opt/

########################################
# INSTALL HBASE
########################################

echo "Installing HBase..."

lxc exec ${CONTAINER} -- bash -c "

cd /opt

rm -rf hbase*

tar xzf ${HBASE_TAR}

ln -s hbase-${HBASE_VERSION} hbase

chown -R ${HADOOP_USER}:${HADOOP_USER} hbase-${HBASE_VERSION}
"

########################################
# INSTALL SQOOP
########################################

echo "Installing Sqoop..."

lxc exec ${CONTAINER} -- bash -c "

cd /opt

rm -rf sqoop*

tar xzf ${SQOOP_TAR}

ln -s sqoop-${SQOOP_VERSION}.bin__hadoop-3.2.0 sqoop

chown -R ${HADOOP_USER}:${HADOOP_USER} sqoop-${SQOOP_VERSION}.bin__hadoop-3.2.0
"

########################################
# CONFIGURE HBASE
########################################

echo "Configuring HBase..."

cat <<EOF > hbase-site.xml
<configuration>

 <property>
  <name>hbase.rootdir</name>
  <value>hdfs://NameNode:9000/hbase</value>
 </property>

 <property>
  <name>hbase.cluster.distributed</name>
  <value>true</value>
 </property>

 <property>
  <name>hbase.zookeeper.quorum</name>
  <value>NameNode</value>
 </property>

</configuration>
EOF

lxc file push hbase-site.xml \
${CONTAINER}${HBASE_HOME}/conf/hbase-site.xml

########################################
# UPDATE ENV (HBASE + SQOOP)
########################################

echo "Updating environment..."

lxc exec ${CONTAINER} -- sudo -u ${HADOOP_USER} bash -c "

cat >> ~/.bashrc <<EOF

# HBase
export HBASE_HOME=${HBASE_HOME}
export PATH=\$PATH:\$HBASE_HOME/bin

# Sqoop
export SQOOP_HOME=${SQOOP_HOME}
export PATH=\$PATH:\$SQOOP_HOME/bin

EOF
"

########################################
# FIX SQOOP-HADOOP LINK
########################################

echo "Linking Sqoop to Hadoop..."

lxc exec ${CONTAINER} -- bash -c "
ln -sf ${HADOOP_HOME} ${SQOOP_HOME}/hadoop
"

########################################
# START HBASE
########################################

echo "Starting HBase..."

lxc exec ${CONTAINER} -- sudo -u ${HADOOP_USER} \
${HBASE_HOME}/bin/start-hbase.sh

########################################
# CLEANUP
########################################

rm -f hbase-site.xml

echo ""
echo "HBase and Sqoop installed successfully."
echo "HBase UI: http://<namenode-ip>:16010"
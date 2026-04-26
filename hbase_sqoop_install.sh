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
# CHECK HADOOP
########################################

echo "Checking Hadoop..."

lxc exec ${CONTAINER} -- test -d ${HADOOP_HOME} || {
  echo "Hadoop not found. Abort."
  exit 1
}

########################################
# DOWNLOAD (HOST)
########################################

echo "Downloading HBase & Sqoop..."

[ -f "$HBASE_TAR" ] || wget -q https://archive.apache.org/dist/hbase/${HBASE_VERSION}/${HBASE_TAR}
[ -f "$SQOOP_TAR" ] || wget -q https://archive.apache.org/dist/sqoop/${SQOOP_VERSION}/${SQOOP_TAR}

########################################
# PUSH FILES
########################################

echo "Pushing archives..."

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
sqoop_dir=\$(ls | grep sqoop-${SQOOP_VERSION})
ln -sf \$sqoop_dir sqoop
chown -R ${HADOOP_USER}:${HADOOP_USER} \$sqoop_dir
"

########################################
# DETECT JAVA_HOME
########################################

JAVA_HOME=$(lxc exec ${CONTAINER} -- bash -c \
"readlink -f \$(which javac) | sed 's:/bin/javac$::'")

echo "JAVA_HOME = $JAVA_HOME"

########################################
# CONFIG HBASE ENV
########################################

lxc exec ${CONTAINER} -- bash -c "
sed -i 's|^# export JAVA_HOME=.*|export JAVA_HOME=${JAVA_HOME}|' \
${HBASE_HOME}/conf/hbase-env.sh
"

########################################
# HBASE CONFIG (SAFE MODE)
########################################

cat <<EOF > hbase-site.xml
<configuration>

 <property>
  <name>hbase.rootdir</name>
  <value>hdfs://NameNode:9000/hbase</value>
 </property>

 <property>
  <name>hbase.cluster.distributed</name>
  <value>false</value>
 </property>

</configuration>
EOF

lxc file push hbase-site.xml \
"${CONTAINER}/${HBASE_HOME}/conf/hbase-site.xml"

########################################
# PREPARE HDFS FOR HBASE
########################################

echo "Preparing HDFS..."

lxc exec ${CONTAINER} -- sudo -u ${HADOOP_USER} \
${HADOOP_HOME}/bin/hdfs dfs -mkdir -p /hbase || true

lxc exec ${CONTAINER} -- sudo -u ${HADOOP_USER} \
${HADOOP_HOME}/bin/hdfs dfs -chown ${HADOOP_USER}:${HADOOP_USER} /hbase || true

########################################
# UPDATE ENV (.bashrc)
########################################

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
# LINK SQOOP TO HADOOP
########################################

lxc exec ${CONTAINER} -- bash -c "
ln -sf ${HADOOP_HOME} ${SQOOP_HOME}/hadoop
"

########################################
# START SERVICES
########################################

echo "Starting HBase..."

lxc exec ${CONTAINER} -- sudo -u ${HADOOP_USER} \
${HBASE_HOME}/bin/start-hbase.sh

########################################
# VERIFY
########################################

echo "Running JPS check..."

lxc exec ${CONTAINER} -- sudo -u ${HADOOP_USER} jps

########################################
# CLEANUP
########################################

rm -f hbase-site.xml

echo ""
echo "======================================="
echo " Big Data Stack Ready "
echo "======================================="
echo "HBase UI: http://<namenode-ip>:16010"
echo "Run HBase shell:"
echo "lxc exec NameNode -- sudo -u hdoop hbase shell"
echo ""
echo "Run Sqoop:"
echo "lxc exec NameNode -- sudo -u hdoop sqoop version"
#!/bin/bash
set -e

########################################
# CONFIG
########################################

NAMENODE="namenode"
HIVE_VERSION=3.1.3
TEZ_VERSION=0.10.2

########################################
# PRECHECK
########################################

echo "===== PRECHECK ====="

lxc list > /dev/null 2>&1 || { echo "LXC not available"; exit 1; }

########################################
# INSTALL HIVE (NAMENODE ONLY)
########################################

echo "Installing Hive on $NAMENODE"

lxc exec "$NAMENODE" -- bash -c "

export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

cd /opt

if [ ! -d hive ]; then
  wget https://downloads.apache.org/hive/hive-${HIVE_VERSION}/apache-hive-${HIVE_VERSION}-bin.tar.gz
  tar -xzf apache-hive-${HIVE_VERSION}-bin.tar.gz
  mv apache-hive-${HIVE_VERSION}-bin hive
fi

export HIVE_HOME=/opt/hive
export PATH=\$PATH:\$HIVE_HOME/bin

mkdir -p \$HIVE_HOME/conf

cat > \$HIVE_HOME/conf/hive-site.xml <<EOF
<configuration>

  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://namenode:9000</value>
  </property>

  <property>
    <name>hive.metastore.warehouse.dir</name>
    <value>/user/hive/warehouse</value>
  </property>

  <property>
    <name>javax.jdo.option.ConnectionURL</name>
    <value>jdbc:derby:;databaseName=metastore_db;create=true</value>
  </property>

  <property>
    <name>javax.jdo.option.ConnectionDriverName</name>
    <value>org.apache.derby.jdbc.EmbeddedDriver</value>
  </property>

</configuration>
EOF
"

########################################
# HDFS PREP
########################################

echo "Preparing HDFS..."

lxc exec "$NAMENODE" -- sudo -u hdoop bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -mkdir -p /user/hive/warehouse || true
hdfs dfs -chmod -R 777 /user/hive || true
"

########################################
# INIT METASTORE
########################################

echo "Initializing metastore..."

lxc exec "$NAMENODE" -- bash -c "
export HIVE_HOME=/opt/hive
export PATH=\$PATH:\$HIVE_HOME/bin

schematool -dbType derby -initSchema || true
"

########################################
# INSTALL TEZ
########################################

echo "Installing Tez..."

lxc exec "$NAMENODE" -- bash -c "

cd /opt

if [ ! -d tez ]; then
  wget https://downloads.apache.org/tez/${TEZ_VERSION}/apache-tez-${TEZ_VERSION}-bin.tar.gz
  tar -xzf apache-tez-${TEZ_VERSION}-bin.tar.gz
  mv apache-tez-${TEZ_VERSION}-bin tez
fi

export TEZ_HOME=/opt/tez
"

########################################
# UPLOAD TEZ TO HDFS
########################################

lxc exec "$NAMENODE" -- sudo -u hdoop bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -mkdir -p /apps/tez || true
hdfs dfs -put -f /opt/tez/* /apps/tez/
"

########################################
# ENABLE TEZ IN HIVE
########################################

lxc exec "$NAMENODE" -- bash -c "
cat >> /opt/hive/conf/hive-site.xml <<EOF

  <property>
    <name>hive.execution.engine</name>
    <value>tez</value>
  </property>

  <property>
    <name>tez.lib.uris</name>
    <value>\${fs.defaultFS}/apps/tez</value>
  </property>

</configuration>
EOF
"

########################################
# START SERVICES
########################################

echo "Starting Hive services..."

lxc exec "$NAMENODE" -- bash -c "
nohup /opt/hive/bin/hive --service metastore > /root/metastore.log 2>&1 &
nohup /opt/hive/bin/hive --service hiveserver2 > /root/hiveserver2.log 2>&1 &
"

sleep 5

########################################
# TEST
########################################

echo "Running Hive test..."

lxc exec "$NAMENODE" -- bash -c "
echo 'show databases;' | /opt/hive/bin/hive
"

echo "===== HIVE COMPLETE ====="

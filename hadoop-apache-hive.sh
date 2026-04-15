#!/bin/bash
set -e

########################################
# CONFIG
########################################

NAMENODE="namenode"
HADOOP_HOME="/opt/hadoop"
HIVE_HOME="/opt/hive"
TEZ_HOME="/opt/tez"
HIVE_VERSION="3.1.3"
TEZ_VERSION="0.10.2"
HADOOP_USER="hdoop"

########################################
# PRECHECK
########################################

echo "===== PRECHECK ====="

lxc list > /dev/null 2>&1 || { echo "❌ LXC not available"; exit 1; }

lxc list | grep -q "$NAMENODE" || { echo "❌ Namenode not found"; exit 1; }

echo "✅ LXC OK"

########################################
# INSTALL HIVE
########################################

echo "===== INSTALL HIVE ====="

lxc exec "$NAMENODE" -- bash -c "
set -e

cd /opt

if [ ! -d hive ]; then
  echo 'Downloading Hive...'
  wget -q https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/apache-hive-${HIVE_VERSION}-bin.tar.gz

  echo 'Extracting Hive...'
  tar -xzf apache-hive-${HIVE_VERSION}-bin.tar.gz

  mv apache-hive-${HIVE_VERSION}-bin hive
fi

echo 'Hive installed at /opt/hive'
"

########################################
# SET ENVIRONMENT
########################################

echo "===== CONFIGURE ENV ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
grep -q HIVE_HOME ~/.bashrc || cat >> ~/.bashrc <<EOF

# Hive
export HIVE_HOME=${HIVE_HOME}
export PATH=\$PATH:\$HIVE_HOME/bin
EOF
"

########################################
# WAIT FOR HDFS
########################################

echo "===== WAIT HDFS ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
export HADOOP_HOME=${HADOOP_HOME}
export PATH=\$PATH:\$HADOOP_HOME/bin

for i in {1..10}; do
  hdfs dfs -ls / >/dev/null 2>&1 && exit 0
  echo 'Waiting HDFS...'
  sleep 3
done

exit 1
"

echo "✅ HDFS ready"

########################################
# PREPARE HDFS FOR HIVE
########################################

echo "===== HDFS PREP ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
export HADOOP_HOME=${HADOOP_HOME}
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -mkdir -p /user/hive/warehouse || true
hdfs dfs -chmod -R 777 /user/hive || true
"

########################################
# INIT METASTORE (SAFE RESET)
########################################

echo "===== INIT METASTORE ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
rm -rf ~/metastore_db ~/derby.log || true

${HIVE_HOME}/bin/schematool -dbType derby -initSchema
"

########################################
# INSTALL TEZ
########################################

echo "===== INSTALL TEZ ====="

lxc exec "$NAMENODE" -- bash -c "
cd /opt

if [ ! -d tez ]; then
  wget -q https://archive.apache.org/dist/tez/${TEZ_VERSION}/apache-tez-${TEZ_VERSION}-bin.tar.gz
  tar -xzf apache-tez-${TEZ_VERSION}-bin.tar.gz
  mv apache-tez-${TEZ_VERSION}-bin tez
fi
"

########################################
# UPLOAD TEZ TO HDFS
########################################

echo "===== UPLOAD TEZ ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
export HADOOP_HOME=${HADOOP_HOME}
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -mkdir -p /apps/tez || true
hdfs dfs -put -f ${TEZ_HOME}/* /apps/tez/
"

########################################
# CONFIGURE HIVE (TEZ ENABLE)
########################################

echo "===== CONFIG HIVE ====="

lxc exec "$NAMENODE" -- bash -c "
cat > ${HIVE_HOME}/conf/hive-site.xml <<'EOF'
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

  <property>
    <name>hive.execution.engine</name>
    <value>tez</value>
  </property>

  <property>
    <name>tez.lib.uris</name>
    <value>\${fs.defaultFS}/apps/tez</value>
  </property>

  <property>
    <name>tez.use.cluster.hadoop-libs</name>
    <value>true</value>
  </property>

</configuration>
EOF
"

########################################
# START HIVE SERVICES
########################################

echo "===== START HIVE ====="

lxc exec "$NAMENODE" -- bash -c "
nohup ${HIVE_HOME}/bin/hive --service metastore > /tmp/metastore.log 2>&1 &
nohup ${HIVE_HOME}/bin/hive --service hiveserver2 > /tmp/hiveserver2.log 2>&1 &
"

sleep 5

########################################
# TEST
########################################

echo "===== TEST HIVE ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
echo 'show databases;' | ${HIVE_HOME}/bin/hive
"

echo ""
echo "=================================="
echo "✅ HIVE + TEZ READY"
echo "=================================="

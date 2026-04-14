#!/bin/bash
set -e

########################################
# CONFIG
########################################

NAMENODE="namenode"
HIVE_VERSION="3.1.3"
TEZ_VERSION="0.10.2"

########################################
# PRECHECK
########################################

echo "===== PRECHECK ====="
lxc list > /dev/null 2>&1 || { echo "LXC not available"; exit 1; }

########################################
# INSTALL HIVE
########################################

lxc exec "$NAMENODE" -- bash -c "
set -e

HIVE_VERSION=${HIVE_VERSION}

cd /opt

echo '===== DEBUG: installing Hive ====='

# Ensure tools exist
command -v wget >/dev/null 2>&1 || { echo 'Installing wget...'; apt-get update && apt-get install -y wget; }

# Download
echo 'Downloading Hive...'
wget -nv https://archive.apache.org/dist/hive/hive-\${HIVE_VERSION}/apache-hive-\${HIVE_VERSION}-bin.tar.gz

# Verify file exists
ls -lh apache-hive-\${HIVE_VERSION}-bin.tar.gz || { echo 'Download failed'; exit 1; }

# Extract
echo 'Extracting...'
tar -xzf apache-hive-\${HIVE_VERSION}-bin.tar.gz

# Verify extraction
ls -d apache-hive-\${HIVE_VERSION}-bin || { echo 'Extraction failed'; exit 1; }

# Move
mv apache-hive-\${HIVE_VERSION}-bin /opt/hive

# Final verification
ls -l /opt/hive/bin/hive || { echo 'Hive binary missing after install'; exit 1; }

echo 'Hive installed successfully'
"

########################################
# WAIT FOR HDFS
########################################

echo "Waiting for HDFS..."

lxc exec "$NAMENODE" -- sudo -u hdoop bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

for i in {1..10}; do
  hdfs dfs -ls / >/dev/null 2>&1 && exit 0
  echo 'Retrying HDFS...'
  sleep 3
done

exit 1
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
set -e

TEZ_VERSION=${TEZ_VERSION}

cd /opt

if [ ! -d /opt/tez ]; then
  wget https://archive.apache.org/dist/tez/\${TEZ_VERSION}/apache-tez-\${TEZ_VERSION}-bin.tar.gz
  tar -xzf apache-tez-\${TEZ_VERSION}-bin.tar.gz
  mv apache-tez-\${TEZ_VERSION}-bin /opt/tez
fi
"

########################################
# UPLOAD TEZ
########################################

echo "Uploading Tez to HDFS..."

lxc exec "$NAMENODE" -- sudo -u hdoop bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -mkdir -p /apps/tez || true
hdfs dfs -put -f /opt/tez/* /apps/tez/
"

########################################
# CONFIGURE HIVE (FINAL)
########################################

echo "Configuring Hive..."

lxc exec "$NAMENODE" -- bash -c "
export HIVE_HOME=/opt/hive

cat > \$HIVE_HOME/conf/hive-site.xml <<'EOF'
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

echo "Testing Hive..."

lxc exec "$NAMENODE" -- bash -c "
echo 'show databases;' | /opt/hive/bin/hive
"

echo "===== HIVE COMPLETE ====="
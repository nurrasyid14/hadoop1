#!/bin/bash
set -e

########################################
# CONFIG
########################################

containers=("namenode" "datanode1" "datanode2")
SPARK_VERSION=3.1.1
HADOOP_PROFILE=3.2

SPARK_ARCHIVE="spark-${SPARK_VERSION}-bin-hadoop${HADOOP_PROFILE}.tgz"
SPARK_URL="https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_ARCHIVE}"

########################################
# PRECHECK
########################################

export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin

echo "===== PRECHECK ====="

if ! lxc list > /dev/null 2>&1; then
  echo "ERROR: LXC not accessible"
  exit 1
fi

########################################
# DOWNLOAD SPARK
########################################

if [ ! -f "$SPARK_ARCHIVE" ]; then
  echo "Downloading Spark..."
  wget "$SPARK_URL"
fi

########################################
# INSTALL SPARK ON ALL NODES
########################################

for c in "${containers[@]}"; do

echo "Installing Spark on $c"

lxc file push "$SPARK_ARCHIVE" "$c"/opt/

lxc exec "$c" -- bash -c "
cd /opt

rm -rf spark

tar xzf $SPARK_ARCHIVE
mv spark-${SPARK_VERSION}-bin-hadoop${HADOOP_PROFILE} spark
rm $SPARK_ARCHIVE

chown -R hdoop:hdoop /opt/spark
"

done

########################################
# CONFIGURE ENV
########################################

for c in "${containers[@]}"; do

lxc exec "$c" -- sudo -u hdoop bash -c "
grep -q SPARK_HOME ~/.bashrc || cat >> ~/.bashrc <<EOF

# Spark
export SPARK_HOME=/opt/spark
export PATH=\$PATH:\$SPARK_HOME/bin
export HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop

EOF
"

done

########################################
# SPARK CONFIG (NAMENODE)
########################################

NameNode="${containers[0]}"

lxc exec "$NameNode" -- bash -c "
cd /opt/spark/conf

cp spark-defaults.conf.template spark-defaults.conf 2>/dev/null || true

grep -q 'spark.master yarn' spark-defaults.conf || cat >> spark-defaults.conf <<EOF
spark.master yarn
spark.submit.deployMode client
spark.driver.memory 2g
spark.executor.memory 2g
spark.eventLog.enabled true
spark.eventLog.dir hdfs:///spark-logs
EOF
"

########################################
# HDFS PREP
########################################

echo "Creating Spark log directory in HDFS..."

lxc exec "$NameNode" -- sudo -u hdoop bash -c "
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -mkdir -p /spark-logs || true
hdfs dfs -chmod -R 777 /spark-logs || true
"

########################################
# TEST
########################################

echo "Running Spark test..."

lxc exec "$NameNode" -- sudo -u hdoop bash -c "
export SPARK_HOME=/opt/spark
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export PATH=\$PATH:\$SPARK_HOME/bin:\$HADOOP_HOME/bin

spark-shell --master yarn --deploy-mode client <<EOF
sc.parallelize(1 to 10).count()
EOF
"

echo "===== SPARK INSTALL COMPLETE ====="

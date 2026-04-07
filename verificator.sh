#!/bin/bash
set -e

########################################
# CONFIG
########################################

NAMENODE="namenode"
DATANODES=("datanode1" "datanode2")

########################################
# HELPERS
########################################

fail() {
  echo "❌ $1"
  exit 1
}

pass() {
  echo "✅ $1"
}

########################################
# CHECK LXC
########################################

echo "===== CHECK: LXC ====="

lxc list > /dev/null 2>&1 || fail "LXC not accessible"

for c in "$NAMENODE" "${DATANODES[@]}"; do
  lxc list | grep -q "$c" || fail "Container $c not found"
done

pass "All containers exist"

########################################
# CHECK CONTAINER STATE
########################################

echo "===== CHECK: CONTAINER STATE ====="

for c in "$NAMENODE" "${DATANODES[@]}"; do
  state=$(lxc list "$c" -c s --format csv)
  [ "$state" = "RUNNING" ] || fail "$c is not running"
done

pass "All containers running"

########################################
# CHECK HDFS
########################################

echo "===== CHECK: HDFS ====="

lxc exec "$NAMENODE" -- sudo -u hdoop bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -ls / >/dev/null 2>&1
" || fail "HDFS not accessible"

pass "HDFS responding"

########################################
# CHECK YARN
########################################

echo "===== CHECK: YARN ====="

lxc exec "$NAMENODE" -- sudo -u hdoop bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

yarn node -list | grep -q RUNNING
" || fail "YARN nodes not running"

pass "YARN nodes active"

########################################
# CHECK HADOOP PROCESSES
########################################

echo "===== CHECK: HADOOP PROCESSES ====="

lxc exec "$NAMENODE" -- bash -c "jps" | grep -q NameNode \
  || fail "NameNode process missing"

lxc exec "$NAMENODE" -- bash -c "jps" | grep -q ResourceManager \
  || fail "ResourceManager missing"

pass "Core Hadoop processes OK"

########################################
# CHECK SPARK
########################################

echo "===== CHECK: SPARK ====="

lxc exec "$NAMENODE" -- sudo -u hdoop bash -c "
export SPARK_HOME=/opt/spark
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$SPARK_HOME/bin:\$HADOOP_HOME/bin

spark-shell --master yarn --deploy-mode client <<EOF
sc.parallelize(1 to 5).count()
EOF
" | grep -q "res0: Long = 5" \
  || fail "Spark test failed"

pass "Spark working"

########################################
# CHECK HIVE
########################################

echo "===== CHECK: HIVE ====="

lxc exec "$NAMENODE" -- bash -c "
export HIVE_HOME=/opt/hive
export PATH=\$PATH:\$HIVE_HOME/bin

echo 'show databases;' | hive
" | grep -qi "default" \
  || fail "Hive query failed"

pass "Hive working"

########################################
# FINAL
########################################

echo ""
echo "=================================="
echo "ALL SYSTEMS OPERATIONAL"
echo "Hadoop + YARN + Spark + Hive OK"
echo "=================================="

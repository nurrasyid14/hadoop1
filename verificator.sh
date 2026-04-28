#!/bin/bash
set -e
# CONFIG
NAMENODE="namenode"
DATANODES=("datanode1" "datanode2")
HADOOP_USER="hdoop"

# HELPERS
fail() {
  echo "❌ $1"
  exit 1
}
pass() {
  echo "✅ $1"
}
run_hadoop() {
  lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "$1"
}

# CHECK LXC
echo "===== CHECK: LXC ====="

lxc list > /dev/null 2>&1 || fail "LXC not accessible"

for c in "$NAMENODE" "${DATANODES[@]}"; do
  lxc list | grep -q "$c" || fail "Container $c not found"
done

pass "All containers exist"

# CHECK STATE
echo "===== CHECK: CONTAINER STATE ====="

for c in "$NAMENODE" "${DATANODES[@]}"; do
  state=$(lxc list "$c" -c s --format csv)
  [ "$state" = "RUNNING" ] || fail "$c not running"
done

pass "Containers running"

# CHECK HDFS
echo "===== CHECK: HDFS ====="

run_hadoop "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -ls / >/dev/null
" || fail "HDFS failed"

pass "HDFS OK"

# CHECK YARN
echo "===== CHECK: YARN ====="

run_hadoop "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

yarn node -list | grep RUNNING
" >/dev/null || fail "YARN not healthy"

pass "YARN OK"

# CHECK MAPREDUCE
echo "===== CHECK: MAPREDUCE ====="

run_hadoop "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -rm -r -f /mr-test /mr-out || true

echo 'mr test data hadoop mapreduce' > /tmp/mr.txt

hdfs dfs -mkdir -p /mr-test
hdfs dfs -put /tmp/mr.txt /mr-test

hadoop jar \$HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples*.jar \
wordcount /mr-test /mr-out

hdfs dfs -cat /mr-out/part-r-00000
" | grep -q "mapreduce" || fail "MapReduce failed"

pass "MapReduce OK"

# CHECK SPARK
echo "===== CHECK: SPARK ====="

run_hadoop "
export SPARK_HOME=/opt/spark
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$SPARK_HOME/bin:\$HADOOP_HOME/bin

spark-submit --master yarn \
--class org.apache.spark.examples.SparkPi \
\$SPARK_HOME/examples/jars/spark-examples*.jar 10
" | grep -q "Pi is roughly" || fail "Spark failed"

pass "Spark OK"

# CHECK HIVE + TEZ
echo "===== CHECK: HIVE (TEZ) ====="

run_hadoop "
export HIVE_HOME=/opt/hive
export PATH=\$PATH:\$HIVE_HOME/bin

hive -e '
set hive.execution.engine=tez;
CREATE TABLE IF NOT EXISTS test_tbl (x INT);
INSERT INTO test_tbl VALUES (1),(2),(3);
SELECT COUNT(*) FROM test_tbl;
'
" | grep -q "3" || fail "Hive/Tez failed"

pass "Hive + Tez OK"

# PROCESSES
echo "===== CHECK: PROCESSES ====="

lxc exec "$NAMENODE" -- jps | grep -q NameNode \
  || fail "NameNode missing"

lxc exec "$NAMENODE" -- jps | grep -q ResourceManager \
  || fail "ResourceManager missing"

pass "Processes OK"

# FINAL

echo ""
echo "=================================="
echo "CLUSTER FULLY OPERATIONAL"
echo ""
echo "✔ HDFS"
echo "✔ YARN"
echo "✔ MapReduce"
echo "✔ Spark"
echo "✔ Hive (Tez)"
echo "=================================="

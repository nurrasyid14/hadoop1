#!/bin/bash
set -e

########################################
# CONFIG
########################################

NAMENODE="namenode"
HADOOP_USER="hdoop"

INPUT_DIR="/user/hadoop/input_p3"
OUTPUT_DIR="/user/hadoop/output_p3_hasil"
DATASET="dataset_pertemuan3.txt"

########################################
# PRECHECK
########################################

echo "===== PRECHECK ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -ls / >/dev/null
" || { echo "HDFS not ready"; exit 1; }

########################################
# UPLOAD DATASET
########################################

echo "===== UPLOAD DATASET ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -mkdir -p $INPUT_DIR
hdfs dfs -put -f /home/$HADOOP_USER/$DATASET $INPUT_DIR/
hdfs dfs -ls $INPUT_DIR
"

########################################
# CHECK YARN
########################################

echo "===== CHECK YARN ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

yarn node -list
"

########################################
# CLEAN OUTPUT (IMPORTANT)
########################################

echo "===== CLEAN OUTPUT ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -rm -r -f $OUTPUT_DIR || true
"

########################################
# RUN WORDCOUNT
########################################

echo "===== RUN WORDCOUNT ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hadoop jar /opt/hadoop/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar \
wordcount $INPUT_DIR/$DATASET $OUTPUT_DIR
"

########################################
# SHOW OUTPUT
########################################

echo "===== RESULT ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

hdfs dfs -ls $OUTPUT_DIR
hdfs dfs -cat $OUTPUT_DIR/part-r-00000 | head -n 20
"

########################################
# GET APPLICATION ID
########################################

echo "===== LAST APPLICATION ====="

lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c "
export HADOOP_HOME=/opt/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin

yarn application -list -appStates FINISHED | tail -n 5
"

echo ""
echo "=================================="
echo "Workflow P3 completed"
echo "=================================="

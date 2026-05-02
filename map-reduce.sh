#!/bin/bash
set -euo pipefail

echo "===== PRECHECK ====="

if ! lxc exec namenode -- true 2>/dev/null; then
  echo "ERROR: Cannot access namenode container"
  exit 1
fi

echo "===== ENSURE HDFS & YARN ARE RUNNING ====="

lxc exec namenode -- sudo -u hdoop bash -c '
  export HADOOP_HOME=/opt/hadoop
  export PATH=$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH

  start-dfs.sh 2>/dev/null || true
  start-yarn.sh 2>/dev/null || true
  sleep 3

  jps | grep -q NameNode    || { echo "NameNode not started"; exit 1; }
  jps | grep -q ResourceManager || { echo "ResourceManager not started"; exit 1; }
'

echo "===== FIX MAPRED-SITE.XML (YARN classpath) ====="

# Add the required environment properties if missing
lxc exec namenode -- bash -c '
  FILE=/opt/hadoop/etc/hadoop/mapred-site.xml
  if ! grep -q "yarn.app.mapreduce.am.env" $FILE; then
    # Backup original
    cp $FILE $FILE.bak
    # Insert properties before </configuration>
    sed -i "s|</configuration>| \
  <property>\n\
    <name>yarn.app.mapreduce.am.env</name>\n\
    <value>HADOOP_MAPRED_HOME=/opt/hadoop</value>\n\
  </property>\n\
  <property>\n\
    <name>mapreduce.map.env</name>\n\
    <value>HADOOP_MAPRED_HOME=/opt/hadoop</value>\n\
  </property>\n\
  <property>\n\
    <name>mapreduce.reduce.env</name>\n\
    <value>HADOOP_MAPRED_HOME=/opt/hadoop</value>\n\
  </property>\n\
</configuration>|" $FILE
  fi
  # Ensure the file is readable by hdoop
  chown hdoop:hdoop $FILE
'

echo "===== RUN MAPREDUCE JOB (WordCount) ====="

lxc exec namenode -- sudo -u hdoop bash -c '
  set -e

  export HADOOP_HOME=/opt/hadoop
  export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
  export PATH=$HADOOP_HOME/bin:$PATH

  INPUT_DIR=/tmp/mr-input
  OUTPUT_DIR=/tmp/mr-output

  hdfs dfs -rm -r -f $INPUT_DIR $OUTPUT_DIR 2>/dev/null || true

  hdfs dfs -mkdir -p $INPUT_DIR
  echo "hello hadoop mapreduce hello hive spark tez" > /tmp/test.txt
  hdfs dfs -put -f /tmp/test.txt $INPUT_DIR

  JAR=$(ls $HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar | head -n1)
  [ -z "$JAR" ] && { echo "ERROR: MapReduce example JAR not found"; exit 1; }

  echo "Running WordCount..."
  hadoop jar "$JAR" wordcount $INPUT_DIR $OUTPUT_DIR

  echo "===== RESULT ====="
  hdfs dfs -cat $OUTPUT_DIR/part-r-00000
'

echo "===== COMPLETE ====="
#!/bin/bash

set -e

echo "===== PRECHECK ====="

if [ -z "$HADOOP_HOME" ]; then
  echo "ERROR: HADOOP_HOME not set"
  exit 1
fi

if [ -z "$HADOOP_CONF_DIR" ]; then
  export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
fi

echo "HADOOP_HOME: $HADOOP_HOME"

echo "===== CHECK MAPREDUCE BINARIES ====="

if [ ! -f "$HADOOP_HOME/bin/mapred" ]; then
  echo "ERROR: MapReduce not found in Hadoop distribution"
  exit 1
fi

echo "MapReduce binaries detected"

echo "===== ENV SETUP ====="

BASHRC="$HOME/.bashrc"

grep -qxF "export HADOOP_MAPRED_HOME=$HADOOP_HOME" $BASHRC || \
echo "export HADOOP_MAPRED_HOME=$HADOOP_HOME" >> $BASHRC

grep -qxF 'export PATH=$PATH:$HADOOP_HOME/bin' $BASHRC || \
echo 'export PATH=$PATH:$HADOOP_HOME/bin' >> $BASHRC

source $BASHRC

echo "===== CONFIGURE mapred-site.xml ====="

MAPRED_SITE="$HADOOP_CONF_DIR/mapred-site.xml"

if [ ! -f "$MAPRED_SITE" ]; then
  cp $HADOOP_CONF_DIR/mapred-site.xml.template $MAPRED_SITE
fi

cat <<EOF > $MAPRED_SITE
<configuration>

  <property>
    <name>mapreduce.framework.name</name>
    <value>yarn</value>
  </property>

  <property>
    <name>mapreduce.application.classpath</name>
    <value>
      \$HADOOP_HOME/share/hadoop/mapreduce/*,
      \$HADOOP_HOME/share/hadoop/mapreduce/lib/*
    </value>
  </property>

</configuration>
EOF

echo "===== RESTART YARN ====="

stop-yarn.sh || true
start-yarn.sh

sleep 5

echo "===== VALIDATE YARN ====="

yarn node -list

echo "===== TEST MAPREDUCE JOB ====="

INPUT_DIR=/tmp/mr-input
OUTPUT_DIR=/tmp/mr-output

hdfs dfs -rm -r -f $INPUT_DIR || true
hdfs dfs -rm -r -f $OUTPUT_DIR || true

hdfs dfs -mkdir -p $INPUT_DIR

echo "hello hadoop mapreduce hello hive spark tez" > /tmp/test.txt
hdfs dfs -put /tmp/test.txt $INPUT_DIR

echo "Running WordCount example..."

hadoop jar $HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples*.jar wordcount $INPUT_DIR $OUTPUT_DIR

echo "===== RESULT ====="
hdfs dfs -cat $OUTPUT_DIR/part-r-00000

echo "===== COMPLETE ====="

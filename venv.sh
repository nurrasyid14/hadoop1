#!/bin/bash
set -e

########################################
# CONFIG
########################################

NAMENODE="namenode"
USER="hdoop"

HADOOP_HOME="/opt/hadoop"
HIVE_HOME="/opt/hive"
HBASE_HOME="/opt/hbase"
TEZ_HOME="/opt/tez"
SQOOP_HOME="/opt/sqoop"

########################################
# COMMON ENV BLOCK
########################################

ENV_COMMON='
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))
export HADOOP_HOME='"$HADOOP_HOME"'
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin
'

ENV_HIVE='
export HIVE_HOME='"$HIVE_HOME"'
export TEZ_HOME='"$TEZ_HOME"'
export PATH=$PATH:$HIVE_HOME/bin:$TEZ_HOME/bin
'

ENV_HBASE='
export HBASE_HOME='"$HBASE_HOME"'
export PATH=$PATH:$HBASE_HOME/bin
'

ENV_SQOOP='
export SQOOP_HOME='"$SQOOP_HOME"'
export PATH=$PATH:$SQOOP_HOME/bin
'

########################################
# USAGE
########################################

if [ $# -lt 1 ]; then
  echo "Usage: $0 [hive|hbase|hadoop|sqoop|shell]"
  exit 1
fi

MODE="$1"

########################################
# EXECUTION
########################################

case "$MODE" in

  hive)
    echo "Entering Hive environment..."
    lxc exec "$NAMENODE" -- sudo -u "$USER" bash -c "
    $ENV_COMMON
    $ENV_HIVE
    exec bash
    "
    ;;

  hbase)
    echo "Entering HBase environment..."
    lxc exec "$NAMENODE" -- sudo -u "$USER" bash -c "
    $ENV_COMMON
    $ENV_HBASE
    exec bash
    "
    ;;

  hadoop)
    echo "Entering Hadoop environment..."
    lxc exec "$NAMENODE" -- sudo -u "$USER" bash -c "
    $ENV_COMMON
    exec bash
    "
    ;;

  sqoop)
    echo "Entering Sqoop environment..."
    lxc exec "$NAMENODE" -- sudo -u "$USER" bash -c "
    $ENV_COMMON
    $ENV_SQOOP
    exec bash
    "
    ;;

  shell)
    echo "Raw shell..."
    lxc exec "$NAMENODE" -- sudo -u "$USER" bash
    ;;

  *)
    echo "Invalid option: $MODE"
    echo "Usage: $0 [hive|hbase|hadoop|sqoop|shell]"
    exit 1
    ;;

esac
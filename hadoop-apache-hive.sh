#!/bin/bash
set -euo pipefail

########################################
# CONFIG
########################################

NAMENODE="namenode"
DATANODES=("datanode1" "datanode2")
ALL_NODES=("$NAMENODE" "${DATANODES[@]}")

HADOOP_HOME="/opt/hadoop"
HIVE_HOME="/opt/hive"
TEZ_HOME="/opt/tez"
HIVE_VERSION="3.1.3"
TEZ_VERSION="0.10.2"
HADOOP_USER="hdoop"

METASTORE_PORT=9083
HIVESERVER2_PORT=10000
SERVICE_WAIT_SECS=60

########################################
# HELPERS
########################################

log()  { echo ""; echo "===== $1 ====="; }
ok()   { echo "✅  $1"; }
fail() { echo "❌  $1"; exit 1; }

detect_java_home() {
  lxc exec "$NAMENODE" -- bash -c \
    'readlink -f $(which javac) 2>/dev/null | sed "s:/bin/javac$::"'
}

run_as_hdoop() {
  lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" \
    env JAVA_HOME="$JAVA_HOME" \
        HADOOP_HOME="$HADOOP_HOME" \
        HIVE_HOME="$HIVE_HOME" \
        PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HIVE_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -c "$1"
}

run_root() {
  lxc exec "$NAMENODE" -- \
    env JAVA_HOME="$JAVA_HOME" \
        HADOOP_HOME="$HADOOP_HOME" \
        HIVE_HOME="$HIVE_HOME" \
        PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HIVE_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -c "$1"
}

########################################
# PRECHECK
########################################

log "PRECHECK"

lxc list > /dev/null 2>&1      || fail "LXC not accessible"
lxc list | grep -q "$NAMENODE" || fail "Container '$NAMENODE' not found"
for dn in "${DATANODES[@]}"; do
  lxc list | grep -q "$dn"     || fail "Container '$dn' not found"
done
ok "LXC + all containers found"

########################################
# DETECT JAVA_HOME
########################################

log "DETECT JAVA_HOME"

JAVA_HOME=$(detect_java_home)
[ -z "$JAVA_HOME" ] && fail "Could not detect JAVA_HOME on $NAMENODE — is Java installed?"
ok "JAVA_HOME: $JAVA_HOME"

########################################
# ENSURE SSH AND HOSTNAME RESOLUTION
########################################

log "NETWORK & SSH CHECK"

# Quick ping test to datanodes
for dn in "${DATANODES[@]}"; do
  lxc exec "$NAMENODE" -- ping -c 1 "$dn" >/dev/null 2>&1 \
    || fail "Cannot ping $dn – check bridge and hostnames"
done

# Ensure password‑less SSH from namenode to all nodes
lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" bash -c '
  for node in '"${ALL_NODES[*]}"'; do
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $node "exit 0" \
      || { echo "SSH to $node failed"; exit 1; }
  done
' || fail "Password‑less SSH is not configured – run the Hadoop cluster setup script first"

ok "Network and SSH ready"

########################################
# ENSURE HADOOP IS RUNNING
########################################

log "HADOOP HEALTH CHECK"

hdfs_available() {
  # Check if port 9000 is open on the namenode (from inside the container)
  lxc exec "$NAMENODE" -- bash -c "timeout 3 bash -c 'echo >/dev/tcp/namenode/9000' 2>/dev/null" && return 0 || return 1
}

if hdfs_available; then
  ok "HDFS already running on port 9000"
else
  echo "HDFS is down — starting Hadoop cluster..."

  # Set JAVA_HOME in hadoop-env.sh on all nodes (may be missing if cluster was never started)
  for c in "${ALL_NODES[@]}"; do
    lxc exec "$c" -- bash -c "
      grep -q JAVA_HOME ${HADOOP_HOME}/etc/hadoop/hadoop-env.sh \
        && sed -i 's|^.*JAVA_HOME=.*|export JAVA_HOME=${JAVA_HOME}|' ${HADOOP_HOME}/etc/hadoop/hadoop-env.sh \
        || echo 'export JAVA_HOME=${JAVA_HOME}' >> ${HADOOP_HOME}/etc/hadoop/hadoop-env.sh
    "
  done

  # Start HDFS and YARN via the hdoop user
  lxc exec "$NAMENODE" -- sudo -u "$HADOOP_USER" \
    env JAVA_HOME="$JAVA_HOME" \
        HADOOP_HOME="$HADOOP_HOME" \
        PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -c "
      ${HADOOP_HOME}/sbin/start-dfs.sh
      ${HADOOP_HOME}/sbin/start-yarn.sh
    "

  echo "Waiting for HDFS port 9000..."
  for i in $(seq 1 30); do
    if hdfs_available; then
      ok "HDFS ready after ${i}s"
      break
    fi
    [ "$i" -eq 30 ] && fail "HDFS did not start – check namenode logs inside container"
    sleep 2
  done

  # Ensure safemode is off
  run_as_hdoop "hdfs dfsadmin -safemode wait" || true
  ok "Safemode exited"
fi

########################################
# INSTALL HIVE
########################################

log "INSTALL HIVE"

run_root "
set -e
cd /opt
if [ -d hive ]; then
  echo 'Hive already installed, skipping.'
else
  echo 'Downloading Hive ${HIVE_VERSION}...'
  wget -q https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/apache-hive-${HIVE_VERSION}-bin.tar.gz \
    || { echo 'Download failed'; exit 1; }
  tar -xzf apache-hive-${HIVE_VERSION}-bin.tar.gz
  mv apache-hive-${HIVE_VERSION}-bin hive
  rm apache-hive-${HIVE_VERSION}-bin.tar.gz
  chown -R ${HADOOP_USER}:${HADOOP_USER} /opt/hive
  echo 'Hive installed.'
fi
"

########################################
# CONFIGURE ENV (.bashrc — idempotent)
########################################

log "CONFIGURE ENV"

run_as_hdoop "
for entry in \
  'export HIVE_HOME=${HIVE_HOME}' \
  'export PATH=\$PATH:\$HIVE_HOME/bin'; do
  grep -qF \"\$entry\" ~/.bashrc || echo \"\$entry\" >> ~/.bashrc
done
echo 'bashrc updated'
"

########################################
# PREPARE HDFS DIRS FOR HIVE
########################################

log "HDFS PREP"

run_as_hdoop "
hdfs dfs -mkdir -p /user/hive/warehouse
hdfs dfs -mkdir -p /tmp
hdfs dfs -chmod -R 777 /user/hive
hdfs dfs -chmod 1777 /tmp
echo 'HDFS dirs ready'
"

########################################
# INSTALL TEZ
########################################

log "INSTALL TEZ"

run_root "
set -e
cd /opt
if [ -d tez ]; then
  echo 'Tez already installed, skipping.'
else
  echo 'Downloading Tez ${TEZ_VERSION}...'
  wget -q https://archive.apache.org/dist/tez/${TEZ_VERSION}/apache-tez-${TEZ_VERSION}-bin.tar.gz \
    || { echo 'Download failed'; exit 1; }
  tar -xzf apache-tez-${TEZ_VERSION}-bin.tar.gz
  mv apache-tez-${TEZ_VERSION}-bin tez
  rm apache-tez-${TEZ_VERSION}-bin.tar.gz
  chown -R ${HADOOP_USER}:${HADOOP_USER} /opt/tez
  echo 'Tez installed.'
fi
"

########################################
# UPLOAD TEZ TO HDFS (idempotent)
########################################

log "UPLOAD TEZ TO HDFS"

run_as_hdoop "
hdfs dfs -rm -r -f /apps/tez || true
hdfs dfs -mkdir -p /apps
hdfs dfs -put ${TEZ_HOME} /apps/
hdfs dfs -chmod -R 755 /apps/tez
echo 'Tez uploaded correctly'
"

########################################
# CONFIGURE HIVE (hive-site.xml)
########################################

log "CONFIG HIVE"

run_root "
cat > ${HIVE_HOME}/conf/hive-site.xml <<'HIVEEOF'
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
    <value>jdbc:derby:;databaseName=/home/${HADOOP_USER}/metastore_db;create=true</value>
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

  <property>
    <name>hive.metastore.uris</name>
    <value>thrift://localhost:${METASTORE_PORT}</value>
  </property>

  <property>
    <name>hive.server2.thrift.port</name>
    <value>${HIVESERVER2_PORT}</value>
  </property>

  <property>
    <name>hive.server2.enable.doAs</name>
    <value>false</value>
  </property>

</configuration>
HIVEEOF
echo 'hive-site.xml written'
"

########################################
# INIT METASTORE (safe reset)
########################################

log "INIT METASTORE"

run_as_hdoop "
rm -rf ~/metastore_db ~/derby.log
${HIVE_HOME}/bin/schematool -dbType derby -initSchema \
  && echo 'Schema init OK'
"

########################################
# STOP STALE HIVE PROCESSES
########################################

log "STOP STALE HIVE"

run_root "
pkill -f 'HiveMetaStore' 2>/dev/null || true
pkill -f 'HiveServer2'   2>/dev/null || true
sleep 2
echo 'Stale processes cleared'
"

########################################
# START HIVE SERVICES
########################################

log "START HIVE SERVICES"

run_root "
nohup ${HIVE_HOME}/bin/hive --service metastore \
  > /tmp/metastore.log 2>&1 &
echo \$! > /tmp/metastore.pid
echo \"Metastore PID: \$(cat /tmp/metastore.pid)\"
"

echo "Waiting for metastore on port ${METASTORE_PORT}..."
for i in $(seq 1 $SERVICE_WAIT_SECS); do
  if lxc exec "$NAMENODE" -- bash -c \
      "ss -tlnp 2>/dev/null | grep -q ':${METASTORE_PORT}' || \
       netstat -tlnp 2>/dev/null | grep -q ':${METASTORE_PORT}'"; then
    ok "Metastore up (${i}s)"
    break
  fi
  if [ "$i" -eq "$SERVICE_WAIT_SECS" ]; then
    echo "--- last 20 lines of metastore.log ---"
    lxc exec "$NAMENODE" -- tail -20 /tmp/metastore.log || true
    fail "Metastore did not start in ${SERVICE_WAIT_SECS}s"
  fi
  sleep 1
done

run_root "
nohup ${HIVE_HOME}/bin/hive --service hiveserver2 \
  > /tmp/hiveserver2.log 2>&1 &
echo \$! > /tmp/hiveserver2.pid
echo \"HiveServer2 PID: \$(cat /tmp/hiveserver2.pid)\"
"

echo "Waiting for HiveServer2 on port ${HIVESERVER2_PORT}..."
for i in $(seq 1 $SERVICE_WAIT_SECS); do
  if lxc exec "$NAMENODE" -- bash -c \
      "ss -tlnp 2>/dev/null | grep -q ':${HIVESERVER2_PORT}' || \
       netstat -tlnp 2>/dev/null | grep -q ':${HIVESERVER2_PORT}'"; then
    ok "HiveServer2 up (${i}s)"
    break
  fi
  if [ "$i" -eq "$SERVICE_WAIT_SECS" ]; then
    echo "--- last 20 lines of hiveserver2.log ---"
    lxc exec "$NAMENODE" -- tail -20 /tmp/hiveserver2.log || true
    fail "HiveServer2 did not start in ${SERVICE_WAIT_SECS}s"
  fi
  sleep 1
done

########################################
# SMOKE TEST
########################################

log "SMOKE TEST"

run_as_hdoop "
echo 'show databases;' | ${HIVE_HOME}/bin/hive 2>/dev/null
"

echo ""
echo "=================================="
ok "HIVE + TEZ READY"
echo "=================================="
echo "  Metastore log  : /tmp/metastore.log"
echo "  HiveServer2 log: /tmp/hiveserver2.log"
echo "  PIDs           : /tmp/metastore.pid  /tmp/hiveserver2.pid"
echo "=================================="
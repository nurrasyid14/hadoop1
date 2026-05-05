#!/bin/bash
set -euo pipefail

########################################
# VARIABLES
########################################

HBASE_VERSION="2.4.17"
SQOOP_VERSION="1.4.7"

HBASE_TAR="hbase-${HBASE_VERSION}-bin.tar.gz"
SQOOP_TAR="sqoop-${SQOOP_VERSION}.bin__hadoop-2.6.0.tar.gz"

HBASE_URL="https://archive.apache.org/dist/hbase/${HBASE_VERSION}/${HBASE_TAR}"
SQOOP_URL="https://archive.apache.org/dist/sqoop/${SQOOP_VERSION}/${SQOOP_TAR}"

HADOOP_HOME="/opt/hadoop"
HBASE_HOME="/opt/hbase"
SQOOP_HOME="/opt/sqoop"
HADOOP_USER="hdoop"
NAMENODE="namenode"

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
        HBASE_HOME="$HBASE_HOME" \
        SQOOP_HOME="$SQOOP_HOME" \
        PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HBASE_HOME/bin:$SQOOP_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -c "$1"
}

run_root() {
  lxc exec "$NAMENODE" -- \
    env JAVA_HOME="$JAVA_HOME" \
        HADOOP_HOME="$HADOOP_HOME" \
        HBASE_HOME="$HBASE_HOME" \
        SQOOP_HOME="$SQOOP_HOME" \
        PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HBASE_HOME/bin:$SQOOP_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -c "$1"
}

########################################
# PRECHECK
########################################

log "PRECHECK"

lxc list > /dev/null 2>&1      || fail "LXC not accessible"
lxc list | grep -q "$NAMENODE" || fail "Container '$NAMENODE' not found"
ok "LXC + container found"

########################################
# DETECT JAVA_HOME
########################################

log "DETECT JAVA_HOME"

JAVA_HOME=$(detect_java_home)
[ -z "$JAVA_HOME" ] && fail "Could not detect JAVA_HOME — is Java installed?"
ok "JAVA_HOME: $JAVA_HOME"

########################################
# DOWNLOAD (HOST SIDE)
########################################

log "DOWNLOAD"

if [ ! -f "$HBASE_TAR" ]; then
  echo "Downloading HBase ${HBASE_VERSION}..."
  wget -q --show-progress "$HBASE_URL" || fail "HBase download failed"
else
  echo "HBase archive already present, skipping."
fi

if [ ! -f "$SQOOP_TAR" ]; then
  echo "Downloading Sqoop ${SQOOP_VERSION}..."
  wget -q --show-progress "$SQOOP_URL" || fail "Sqoop download failed"
else
  echo "Sqoop archive already present, skipping."
fi

ok "Archives ready"

########################################
# INSTALL HBASE
########################################

log "INSTALL HBASE"

if ! lxc exec "$NAMENODE" -- test -d /opt/hbase 2>/dev/null; then
  echo "Pushing HBase archive to container..."
  lxc file push "$HBASE_TAR" "${NAMENODE}/opt/${HBASE_TAR}"
  run_root "
    cd /opt
    tar -xzf ${HBASE_TAR}
    mv hbase-${HBASE_VERSION} hbase
    rm ${HBASE_TAR}
    chown -R ${HADOOP_USER}:${HADOOP_USER} /opt/hbase
    echo 'HBase installed.'
  "
else
  echo "HBase already installed, skipping."
fi

########################################
# INSTALL SQOOP
########################################

log "INSTALL SQOOP"

if ! lxc exec "$NAMENODE" -- test -d /opt/sqoop 2>/dev/null; then
  echo "Pushing Sqoop archive to container..."
  lxc file push "$SQOOP_TAR" "${NAMENODE}/opt/${SQOOP_TAR}"
  run_root "
    cd /opt
    tar -xzf ${SQOOP_TAR}
    mv sqoop-${SQOOP_VERSION}.bin__hadoop-2.6.0 sqoop
    rm ${SQOOP_TAR}
    chown -R ${HADOOP_USER}:${HADOOP_USER} /opt/sqoop
    echo 'Sqoop installed.'
  "
else
  echo "Sqoop already installed, skipping."
fi

########################################
# SUPPRESS SQOOP WARNINGS
########################################

log "SUPPRESS SQOOP WARNINGS"

# Create dummy directories for the optional components
run_root "
  mkdir -p ${SQOOP_HOME}/hcatalog
  mkdir -p ${SQOOP_HOME}/accumulo
  mkdir -p ${SQOOP_HOME}/zookeeper
"

# Configure sqoop-env.sh
run_as_hdoop "
  cp -n ${SQOOP_HOME}/conf/sqoop-env-template.sh ${SQOOP_HOME}/conf/sqoop-env.sh 2>/dev/null || true
  cat >> ${SQOOP_HOME}/conf/sqoop-env.sh <<EOF

# Override optional paths to suppress warnings
export HCAT_HOME=${SQOOP_HOME}/hcatalog
export ACCUMULO_HOME=${SQOOP_HOME}/accumulo
export ZOOKEEPER_HOME=${SQOOP_HOME}/zookeeper
EOF
"

ok "Sqoop warnings suppressed"

########################################
# CONFIGURE HBASE (hbase-site.xml)
########################################

log "CONFIGURE HBASE"

cat > /tmp/hbase-site.xml <<EOF
<configuration>
  <property>
    <name>hbase.rootdir</name>
    <value>hdfs://namenode:9000/hbase</value>
  </property>
  <property>
    <name>hbase.cluster.distributed</name>
    <value>true</value>
  </property>
  <property>
    <name>hbase.zookeeper.quorum</name>
    <value>namenode</value>
  </property>
  <property>
    <name>hbase.zookeeper.property.dataDir</name>
    <value>/opt/hbase/zookeeper</value>
  </property>
</configuration>
EOF

lxc file push /tmp/hbase-site.xml "${NAMENODE}${HBASE_HOME}/conf/hbase-site.xml"
rm -f /tmp/hbase-site.xml
ok "hbase-site.xml pushed"

########################################
# SET JAVA_HOME IN hbase-env.sh
########################################

log "CONFIGURE HBASE ENV"

run_root "
grep -q JAVA_HOME ${HBASE_HOME}/conf/hbase-env.sh \
  && sed -i 's|^.*JAVA_HOME=.*|export JAVA_HOME=${JAVA_HOME}|' ${HBASE_HOME}/conf/hbase-env.sh \
  || echo 'export JAVA_HOME=${JAVA_HOME}' >> ${HBASE_HOME}/conf/hbase-env.sh
echo 'hbase-env.sh updated'
"

########################################
# LINK SQOOP TO HADOOP
########################################

log "LINK SQOOP TO HADOOP"

run_root "
ln -sfn ${HADOOP_HOME} ${SQOOP_HOME}/hadoop
echo 'Sqoop linked to Hadoop'
"

########################################
# UPDATE .bashrc (idempotent)
########################################

log "CONFIGURE ENV"

run_as_hdoop "
for entry in \
  'export HBASE_HOME=${HBASE_HOME}' \
  'export SQOOP_HOME=${SQOOP_HOME}' \
  'export PATH=\$PATH:\$HBASE_HOME/bin:\$SQOOP_HOME/bin'; do
  grep -qF \"\$entry\" ~/.bashrc || echo \"\$entry\" >> ~/.bashrc
done
echo 'bashrc updated'
"

########################################
# STOP STALE HBASE PROCESSES
########################################

log "STOP STALE HBASE"

run_root "
pkill -f 'HMaster'       2>/dev/null || true
pkill -f 'HRegionServer' 2>/dev/null || true
sleep 2
echo 'Stale HBase processes cleared'
"

########################################
# START HBASE
########################################

log "START HBASE"

run_as_hdoop "${HBASE_HOME}/bin/start-hbase.sh"

echo "Waiting for HMaster..."
for i in $(seq 1 30); do
  if run_as_hdoop "jps 2>/dev/null" | grep -q HMaster; then
    ok "HMaster is running (${i}s)"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "--- HBase log tail ---"
    run_root "ls ${HBASE_HOME}/logs/*.log 2>/dev/null | xargs tail -20 2>/dev/null || true"
    fail "HMaster did not start in time"
  fi
  sleep 2
done

########################################
# SMOKE TEST
########################################

log "SMOKE TEST"

run_as_hdoop "echo 'status' | ${HBASE_HOME}/bin/hbase shell 2>/dev/null | tail -5"

echo ""
echo "=================================="
ok "HBASE + SQOOP READY"
echo "=================================="
NAMENODE_IP=$(lxc list "$NAMENODE" -c 4 --format csv | cut -d',' -f1)
echo "  HBase UI : http://${NAMENODE_IP}:16010"
echo "  HBase log: ${HBASE_HOME}/logs/"
echo "  Sqoop    : run 'sqoop help' inside the container"
echo "=================================="
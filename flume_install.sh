#!/bin/bash
set -euo pipefail

########################################
# CONFIG
########################################

NAMENODE="namenode"
DATANODES=("datanode1" "datanode2")
ALL_NODES=("$NAMENODE" "${DATANODES[@]}")

HADOOP_HOME="/opt/hadoop"
FLUME_HOME="/opt/flume"
FLUME_VERSION="1.11.0"
HADOOP_USER="hdoop"

FLUME_ARCHIVE="apache-flume-${FLUME_VERSION}-bin.tar.gz"
FLUME_URL="https://archive.apache.org/dist/flume/${FLUME_VERSION}/${FLUME_ARCHIVE}"

AGENT_NAME="agent"
CONF_FILE="/home/${HADOOP_USER}/flume-netcat-hdfs.conf"
LOG_FILE="/home/${HADOOP_USER}/flume-agent.log"
PID_FILE="/home/${HADOOP_USER}/flume-agent.pid"
NC_PORT=44444

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
        FLUME_HOME="$FLUME_HOME" \
        PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$FLUME_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -c "$1"
}

run_root() {
  lxc exec "$NAMENODE" -- \
    env JAVA_HOME="$JAVA_HOME" \
        HADOOP_HOME="$HADOOP_HOME" \
        FLUME_HOME="$FLUME_HOME" \
        PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$FLUME_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
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
[ -z "$JAVA_HOME" ] && fail "Could not detect JAVA_HOME on $NAMENODE — is Java installed?"
ok "JAVA_HOME: $JAVA_HOME"

########################################
# ENSURE HDFS IS AVAILABLE
########################################

log "HADOOP HEALTH CHECK"

hdfs_available() {
  lxc exec "$NAMENODE" -- bash -c "timeout 3 bash -c 'echo >/dev/tcp/namenode/9000' 2>/dev/null" && return 0 || return 1
}

if hdfs_available; then
  ok "HDFS already running"
else
  fail "HDFS is not running — please start the Hadoop cluster first (run hadoop-lxc-cluster.sh)"
fi

########################################
# INSTALL NETCAT (for nc command)
########################################

log "INSTALL NETCAT"

run_root "
  if ! command -v nc &>/dev/null; then
    echo 'Installing netcat-openbsd...'
    apt-get update -qq && apt-get install -y -qq netcat-openbsd || yum install -y nc || true
  fi
"
ok "nc available"

########################################
# INSTALL FLUME
########################################

log "INSTALL FLUME"

if ! lxc exec "$NAMENODE" -- test -d /opt/flume 2>/dev/null; then
  run_root "
    set -e
    cd /opt
    echo 'Downloading Flume ${FLUME_VERSION}...'
    wget -q '${FLUME_URL}' || { echo 'Download failed'; exit 1; }
    tar -xzf '${FLUME_ARCHIVE}'
    mv apache-flume-${FLUME_VERSION}-bin flume
    rm '${FLUME_ARCHIVE}'
    chown -R ${HADOOP_USER}:${HADOOP_USER} /opt/flume
    echo 'Flume installed.'
  "
else
  echo "Flume already installed, skipping."
fi

########################################
# CONFIGURE FLUME ENVIRONMENT
########################################

log "CONFIGURE FLUME ENV"

# Set JAVA_HOME and Hadoop classpath in flume-env.sh
run_root "
  cd ${FLUME_HOME}/conf
  # Create flume-env.sh if missing
  if [ ! -f flume-env.sh ]; then
    cp -n flume-env.sh.template flume-env.sh 2>/dev/null || touch flume-env.sh
  fi
  # JAVA_HOME
  grep -q 'JAVA_HOME' flume-env.sh \
    && sed -i 's|^.*JAVA_HOME=.*|export JAVA_HOME=${JAVA_HOME}|' flume-env.sh \
    || echo 'export JAVA_HOME=${JAVA_HOME}' >> flume-env.sh
  # Hadoop classpath for HDFS sink
  grep -q 'FLUME_CLASSPATH' flume-env.sh \
    && sed -i 's|^.*FLUME_CLASSPATH=.*|export FLUME_CLASSPATH=\$('"${HADOOP_HOME}"'/bin/hadoop classpath)|' flume-env.sh \
    || echo 'export FLUME_CLASSPATH=\$('"${HADOOP_HOME}"'/bin/hadoop classpath)' >> flume-env.sh
  echo 'flume-env.sh updated'
"

########################################
# UPDATE .bashrc (idempotent)
########################################

log "CONFIGURE ENV"

run_as_hdoop "
for entry in \
  'export FLUME_HOME=${FLUME_HOME}' \
  'export PATH=\$PATH:\$FLUME_HOME/bin'; do
  grep -qF \"\$entry\" ~/.bashrc || echo \"\$entry\" >> ~/.bashrc
done
echo 'bashrc updated'
"

########################################
# CREATE FLUME AGENT CONFIGURATION
########################################

log "CREATE FLUME CONFIG"

# Write a netcat -> memory -> HDFS configuration file
run_as_hdoop "
cat > ${CONF_FILE} <<EOF
# Name the components on this agent
${AGENT_NAME}.sources = netcatSrc
${AGENT_NAME}.channels = memoryChannel
${AGENT_NAME}.sinks = hdfsSink

# Configure the netcat source
${AGENT_NAME}.sources.netcatSrc.type = netcat
${AGENT_NAME}.sources.netcatSrc.bind = 0.0.0.0
${AGENT_NAME}.sources.netcatSrc.port = ${NC_PORT}

# Configure the memory channel
${AGENT_NAME}.channels.memoryChannel.type = memory
${AGENT_NAME}.channels.memoryChannel.capacity = 1000
${AGENT_NAME}.channels.memoryChannel.transactionCapacity = 100

# Configure the HDFS sink
${AGENT_NAME}.sinks.hdfsSink.type = hdfs
${AGENT_NAME}.sinks.hdfsSink.hdfs.path = hdfs://${NAMENODE}:9000/user/${HADOOP_USER}/flume/events/%Y-%m-%d/%H%M
${AGENT_NAME}.sinks.hdfsSink.hdfs.filePrefix = flume-events
${AGENT_NAME}.sinks.hdfsSink.hdfs.fileSuffix = .log
${AGENT_NAME}.sinks.hdfsSink.hdfs.rollInterval = 30
${AGENT_NAME}.sinks.hdfsSink.hdfs.rollSize = 0
${AGENT_NAME}.sinks.hdfsSink.hdfs.rollCount = 5
${AGENT_NAME}.sinks.hdfsSink.hdfs.useLocalTimeStamp = true
${AGENT_NAME}.sinks.hdfsSink.hdfs.fileType = DataStream

# Bind the source and sink to the channel
${AGENT_NAME}.sources.netcatSrc.channels = memoryChannel
${AGENT_NAME}.sinks.hdfsSink.channel = memoryChannel
EOF
echo 'Flume agent configuration written'
"

########################################
# STOP ANY PREVIOUS AGENT
########################################

log "STOP STALE AGENT"

run_as_hdoop "
if [ -f ${PID_FILE} ]; then
  old_pid=\$(cat ${PID_FILE})
  kill \$old_pid 2>/dev/null || true
  sleep 1
  rm -f ${PID_FILE}
fi
"

########################################
# START FLUME AGENT
########################################

log "START FLUME AGENT"

# Ensure HDFS output directory exists
run_as_hdoop "hdfs dfs -mkdir -p /user/${HADOOP_USER}/flume/events" || true

run_as_hdoop "
nohup ${FLUME_HOME}/bin/flume-ng agent \\
  --conf ${FLUME_HOME}/conf \\
  --conf-file ${CONF_FILE} \\
  --name ${AGENT_NAME} \\
  -Dflume.root.logger=INFO,console \\
  > ${LOG_FILE} 2>&1 &
echo \$! > ${PID_FILE}
echo \"Agent started with PID \$(cat ${PID_FILE})\"
"

echo "Waiting for netcat source on port ${NC_PORT}..."
for i in $(seq 1 20); do
  if lxc exec "$NAMENODE" -- bash -c "ss -tlnp 2>/dev/null | grep -q ':${NC_PORT}' || netstat -tlnp 2>/dev/null | grep -q ':${NC_PORT}'"; then
    ok "Netcat source listening on ${NC_PORT} (${i}s)"
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "--- last 20 lines of flume agent log ---"
    lxc exec "$NAMENODE" -- tail -20 ${LOG_FILE} || true
    fail "Flume agent did not start in time"
  fi
  sleep 1
done

########################################
# SMOKE TEST
########################################

log "SMOKE TEST"

# Send a test line via netcat (now nc is available)
echo "Test message from Flume at $(date)" | lxc exec "$NAMENODE" -- nc -q 1 localhost ${NC_PORT} || true

# Give Flume a moment to write to HDFS
sleep 10

echo "Checking HDFS for flume events..."
run_as_hdoop "
  latest_file=\$(hdfs dfs -ls -R /user/${HADOOP_USER}/flume/events/ 2>/dev/null | grep flume-events | tail -1 | awk '{print \$NF}')
  if [ -n \"\$latest_file\" ]; then
    echo 'Latest event file: '\$latest_file
    hdfs dfs -cat \"\$latest_file\" | head -5
    echo 'Smoke test successful – data landed in HDFS.'
  else
    echo 'No event file found yet. Agent logs:'
    tail -20 ${LOG_FILE}
    echo 'You can manually test with: echo \"hello\" | nc localhost ${NC_PORT}'
  fi
"

echo ""
echo "=================================="
ok "FLUME INSTALLATION COMPLETE"
echo "=================================="
echo "  Flume home   : ${FLUME_HOME}"
echo "  Agent config : ${CONF_FILE}"
echo "  Agent log    : ${LOG_FILE}"
echo "  PID file     : ${PID_FILE}"
echo "  Netcat port  : ${NC_PORT}"
echo "  HDFS output  : /user/${HADOOP_USER}/flume/events/"
echo ""
echo "  To stop agent: kill \$(cat ${PID_FILE}) inside the container"
echo "  To test      : echo \"hello\" | nc localhost ${NC_PORT}"
echo "=================================="
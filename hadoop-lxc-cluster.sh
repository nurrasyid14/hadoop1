#!/bin/bash
set -euo pipefail

########################################
# VARIABLES
########################################

hadoop_version="3.4.0"
hadoop_home="/opt/hadoop"
hadoop_user="hdoop"

containers=("namenode" "datanode1" "datanode2")
replication="1"

NameNode="${containers[0]}"

########################################
# PRECHECK
########################################

if ! groups | grep -qw lxd; then
  echo "ERROR: user not in lxd group"
  exit 1
fi

if ! lxc list >/dev/null 2>&1; then
  echo "ERROR: LXD not accessible"
  exit 1
fi

for c in "${containers[@]}"; do
  state=$(lxc list "$c" -c s --format csv)
  if [ "$state" != "RUNNING" ]; then
    echo "ERROR: Container $c is not RUNNING (state: $state)"
    exit 1
  fi
done

########################################
# NETWORK: BRIDGE & HOST FIREWALL
########################################

echo "===== NETWORK SETUP ====="

# Ensure lxdbr0 exists
if ! lxc network list | grep -qw lxdbr0; then
  lxc network create lxdbr0
  echo "Created lxdbr0"
else
  echo "lxdbr0 exists"
fi

# Attach to default profile only if not already present (ignore error)
if ! lxc profile show default | grep -q "parent: lxdbr0"; then
  lxc network attach-profile lxdbr0 default eth0 || true
fi

# Restart containers to refresh network
for c in "${containers[@]}"; do
  lxc restart "$c" 2>/dev/null || true
done
sleep 10

# Gather IPs now (they may have changed)
declare -A ips
for c in "${containers[@]}"; do
  ip=$(lxc list "$c" -c 4 --format csv | cut -d' ' -f1)
  ips["$c"]=$ip
  echo "  $c -> $ip"
done

# Flush iptables inside each container
echo "Flushing internal firewalls..."
for c in "${containers[@]}"; do
  lxc exec "$c" -- bash -c 'iptables -F; iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT; iptables -P FORWARD ACCEPT' || true
done

# **HOST** firewall: allow all forwarding on lxdbr0 and ensure default FORWARD is ACCEPT
echo "Opening host firewall for lxdbr0..."
sudo iptables -I FORWARD -i lxdbr0 -j ACCEPT 2>/dev/null || true
sudo iptables -I FORWARD -o lxdbr0 -j ACCEPT 2>/dev/null || true
sudo iptables -P FORWARD ACCEPT 2>/dev/null || true

# If using ufw, allow forwarding on lxdbr0
if command -v ufw &>/dev/null; then
  sudo ufw allow in on lxdbr0 2>/dev/null || true
  sudo ufw route allow in on lxdbr0 2>/dev/null || true
fi

# Update /etc/hosts inside each container (with both hostname and IP)
for c in "${containers[@]}"; do
  content="127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\nfe00::0 ip6-localnet\nff00::0 ip6-mcastprefix\nff02::1 ip6-allnodes\nff02::2 ip6-allrouters\n"
  for target in "${containers[@]}"; do
    content+="${ips[$target]} $target\n"
  done
  echo -e "$content" | lxc exec "$c" -- tee /etc/hosts >/dev/null
done

# Ensure SSH server is running on all containers
for c in "${containers[@]}"; do
  lxc exec "$c" -- bash -c '
    if ! command -v sshd >/dev/null 2>&1; then
      apt-get update && apt-get install -y openssh-server || true
    fi
    service ssh start 2>/dev/null || systemctl start sshd 2>/dev/null || true
  '
done

# Test connectivity: ping and port 22
echo "Testing connectivity..."
for c in datanode1 datanode2; do
  echo -n "Ping to $c: "
  lxc exec "$NameNode" -- ping -c 1 "$c" >/dev/null 2>&1 && echo "OK" || echo "FAIL"
  echo -n "Port 22 to $c: "
  lxc exec "$NameNode" -- timeout 3 bash -c "echo >/dev/tcp/$c/22" 2>/dev/null && echo "open" || echo "closed/timeout"
done

# If port 22 is still blocked, we'll use IPs directly in Hadoop config (bypass hostname)
use_ip=0
for c in datanode1 datanode2; do
  if ! lxc exec "$NameNode" -- timeout 3 bash -c "echo >/dev/tcp/$c/22" >/dev/null 2>&1; then
    use_ip=1
    break
  fi
done

if [ $use_ip -eq 1 ]; then
  echo "SSH via hostname failing. Using IP addresses for Hadoop configuration."
  NameNode_addr="${ips[$NameNode]}"
else
  NameNode_addr="$NameNode"
fi

########################################
# SSH KEY SETUP
########################################

echo "Setting up password-less SSH for $hadoop_user..."

lxc exec "$NameNode" -- sudo -u "$hadoop_user" bash -c '
  if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -P "" -f ~/.ssh/id_rsa
  fi
  cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
  chmod 700 ~/.ssh
  chmod 600 ~/.ssh/authorized_keys
'

lxc file pull "$NameNode/home/$hadoop_user/.ssh/id_rsa.pub" /tmp/hdoop_key.pub

for c in "${containers[@]}"; do
  lxc exec "$c" -- mkdir -p /home/$hadoop_user/.ssh
  cat /tmp/hdoop_key.pub | lxc exec "$c" -- tee -a /home/$hadoop_user/.ssh/authorized_keys > /dev/null
  lxc exec "$c" -- chown -R $hadoop_user:$hadoop_user /home/$hadoop_user/.ssh
  lxc exec "$c" -- chmod 700 /home/$hadoop_user/.ssh
  lxc exec "$c" -- chmod 600 /home/$hadoop_user/.ssh/authorized_keys
done
rm -f /tmp/hdoop_key.pub

# Test SSH using the chosen address (IP or hostname)
echo "Testing SSH..."
for node in "${containers[@]}"; do
  addr="${NameNode_addr}"   # this is for NameNode itself use NameNode_addr
  if [ "$node" != "$NameNode" ]; then
    addr="${ips[$node]}"    # datanodes
  fi
  if lxc exec "$NameNode" -- sudo -u "$hadoop_user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$addr" 'echo ok' >/dev/null 2>&1; then
    echo "SSH to $node ($addr) OK"
  else
    echo "ERROR: SSH to $node ($addr) failed"
    exit 1
  fi
done

########################################
# HADOOP CONFIGURATION
########################################

echo "===== CONFIGURING HADOOP ====="

# JAVA_HOME
java_home=$(lxc exec "$NameNode" -- bash -c 'readlink -f $(which javac) 2>/dev/null | sed "s:/bin/javac$::"')
[ -z "$java_home" ] && { echo "ERROR: Java not found"; exit 1; }
echo "JAVA_HOME: $java_home"

for c in "${containers[@]}"; do
  lxc exec "$c" -- bash -c "
    file=${hadoop_home}/etc/hadoop/hadoop-env.sh
    grep -q JAVA_HOME \$file && \
      sed -i 's|^export JAVA_HOME=.*|export JAVA_HOME=${java_home}|' \$file || \
      echo 'export JAVA_HOME=${java_home}' >> \$file
  "
done

# .bashrc
for c in "${containers[@]}"; do
  lxc exec "$c" -- sudo -u "$hadoop_user" bash -c '
    grep -q HADOOP_HOME ~/.bashrc || printf "%s\n" \
      "# Hadoop" \
      "export JAVA_HOME='"$java_home"'" \
      "export HADOOP_HOME='"$hadoop_home"'" \
      "export PATH=\$PATH:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin" \
      >> ~/.bashrc
  '
done

# Write XML configs (use NameNode_addr if we switched to IPs)
cat <<EOF > core-site.xml
<configuration>
 <property>
  <name>fs.defaultFS</name>
  <value>hdfs://${NameNode_addr}:9000</value>
 </property>
 <property>
  <name>hadoop.tmp.dir</name>
  <value>${hadoop_home}/tmpdata</value>
 </property>
</configuration>
EOF

cat <<EOF > hdfs-site.xml
<configuration>
 <property>
  <name>dfs.replication</name>
  <value>${replication}</value>
 </property>
 <property>
  <name>dfs.namenode.name.dir</name>
  <value>file:${hadoop_home}/dfsdata/namenode</value>
 </property>
 <property>
  <name>dfs.datanode.data.dir</name>
  <value>file:${hadoop_home}/dfsdata/datanode</value>
 </property>
</configuration>
EOF

cat <<EOF > mapred-site.xml
<configuration>
 <property>
  <name>mapreduce.framework.name</name>
  <value>yarn</value>
 </property>
</configuration>
EOF

cat <<EOF > yarn-site.xml
<configuration>
 <property>
  <name>yarn.resourcemanager.hostname</name>
  <value>${NameNode_addr}</value>
 </property>
 <property>
  <name>yarn.nodemanager.aux-services</name>
  <value>mapreduce_shuffle</value>
 </property>
</configuration>
EOF

# Workers file – use hostnames (or IPs?) – we'll stick with hostnames because SSH inside start scripts uses hostnames; if we set NameNode_addr to an IP, workers should still resolve via /etc/hosts
> workers
for ((i=1; i<${#containers[@]}; i++)); do
  echo "${containers[$i]}" >> workers
done

# Push configs
for c in "${containers[@]}"; do
  for f in core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml workers; do
    lxc file push "$f" "$c/${hadoop_home}/etc/hadoop/$f"
  done
done

# Create directories
for c in "${containers[@]}"; do
  if [ "$c" = "$NameNode" ]; then
    lxc exec "$c" -- bash -c "
      mkdir -p ${hadoop_home}/tmpdata ${hadoop_home}/dfsdata/namenode
      chown -R ${hadoop_user}:${hadoop_user} ${hadoop_home}
    "
  else
    lxc exec "$c" -- bash -c "
      mkdir -p ${hadoop_home}/tmpdata ${hadoop_home}/dfsdata/datanode
      chown -R ${hadoop_user}:${hadoop_user} ${hadoop_home}
    "
  fi
done

# Format HDFS if needed
if ! lxc exec "$NameNode" -- test -d ${hadoop_home}/dfsdata/namenode/current; then
  echo "Formatting HDFS..."
  lxc exec "$NameNode" -- sudo -u "$hadoop_user" \
    ${hadoop_home}/bin/hdfs namenode -format -force
else
  echo "Already formatted"
fi

########################################
# START HADOOP
########################################

echo "Starting Hadoop..."
lxc exec "$NameNode" -- sudo -u "$hadoop_user" ${hadoop_home}/sbin/start-dfs.sh
lxc exec "$NameNode" -- sudo -u "$hadoop_user" ${hadoop_home}/sbin/start-yarn.sh
sleep 5

jps_output=$(lxc exec "$NameNode" -- sudo -u "$hadoop_user" jps 2>/dev/null || true)
echo "$jps_output"
if echo "$jps_output" | grep -q NameNode && echo "$jps_output" | grep -q ResourceManager; then
  echo "===== CLUSTER READY ====="
  echo "HDFS UI: http://${ips[$NameNode]}:9870"
else
  echo "ERROR: Some services down."
  exit 1
fi

rm -f core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml workers
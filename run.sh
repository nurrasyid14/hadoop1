# 1. Provision containers + base OS
./hadoop-deploy.sh

# 2. Install + configure Hadoop cluster
./hadoop-lxc-cluster.sh

# 🔴 HARD GATE (DO NOT SKIP)
# Verify cluster is actually alive
lxc exec namenode -- sudo -u hdoop jps
lxc exec namenode -- sudo -u hdoop hdfs dfs -ls /

# 3. Validate MapReduce (depends on YARN + HDFS)
./map-reduce.sh

# 🔴 HARD GATE
# Ensure YARN is stable
lxc exec namenode -- sudo -u hdoop yarn node -list

# 4. Install Spark (depends on Hadoop env)
./apache-spark-install.sh

./hbase_sqoop_install.sh
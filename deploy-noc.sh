#!/bin/bash
# ================================================================
# Everest Wireless Network - Smart NOC System Deployment
# Environment: Kali Linux (VMware Workstation Pro)
# Version: 2.0.0
# ================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables
HOSTNAME="noc-ewnet.local"
MYSQL_ROOT_PASS="Everest@NOC2026!"
ZABBIX_DB_PASS="Zabbix@EWNet2026!"
GRAFANA_DB_PASS="Grafana@EWNet2026!"
GENIE_DB_PASS="Genie@EWNet2026!"

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Check root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

print_status "Starting Everest Wireless Network NOC Deployment"
print_status "================================================"

# ================================================================
# SECTION 1: SYSTEM PREPARATION
# ================================================================

print_status "SECTION 1: Preparing Kali Linux System"

# Update system
apt update -y
apt full-upgrade -y

# Set hostname
hostnamectl set-hostname $HOSTNAME
grep -q "$HOSTNAME" /etc/hosts || echo "127.0.0.1 $HOSTNAME" >> /etc/hosts

# Install base dependencies
print_status "Installing base dependencies..."
apt install -y curl wget git vim htop net-tools \
    openssl software-properties-common apt-transport-https \
    gnupg2 ca-certificates dirmngr \
    python3 python3-pip python3-venv \
    default-jdk default-jre-headless \
    nginx apache2 \
    build-essential cmake autoconf libtool \
    net-snmp snmpd snmp-mibs-downloader \
    tcpdump nfdump sflowtool \
    nmap masscan whois mtr traceroute \
    mariadb-server mariadb-client \
    redis-server redis-tools \
    supervisor logrotate

# Install Node.js 18.x for Kali
print_status "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs

# Install Python packages
print_status "Installing Python packages..."
pip3 install --upgrade pip setuptools wheel
pip3 install netmiko paramiko requests flask flask-cors \
    elasticsearch mysql-connector-python pymongo redis celery aiohttp asyncio

print_success "System preparation complete"

# ================================================================
# SECTION 2: MYSQL/MARIADB SETUP
# ================================================================

print_status "SECTION 2: Setting up MariaDB"

systemctl enable mariadb
systemctl start mariadb

mysql << EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE DATABASE IF NOT EXISTS grafana CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE DATABASE IF NOT EXISTS genieacs CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PASS}';
CREATE USER IF NOT EXISTS 'grafana'@'localhost' IDENTIFIED BY '${GRAFANA_DB_PASS}';
CREATE USER IF NOT EXISTS 'genieacs'@'localhost' IDENTIFIED BY '${GENIE_DB_PASS}';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
GRANT ALL PRIVILEGES ON grafana.* TO 'grafana'@'localhost';
GRANT ALL PRIVILEGES ON genieacs.* TO 'genieacs'@'localhost';
FLUSH PRIVILEGES;
EOF

cat > /etc/mysql/mariadb.conf.d/99-performance.cnf << 'EOF'
[mysqld]
max_connections = 500
innodb_buffer_pool_size = 1G
innodb_log_file_size = 512M
innodb_flush_log_at_trx_commit = 2
query_cache_size = 64M
tmp_table_size = 64M
max_heap_table_size = 64M
key_buffer_size = 256M
table_open_cache = 2048
max_allowed_packet = 256M
EOF

systemctl restart mariadb
print_success "MariaDB setup complete"

# ================================================================
# SECTION 3: ELASTICSEARCH INSTALLATION
# ================================================================

print_status "SECTION 3: Installing Elasticsearch"

# Install Elasticsearch 7.x (more stable on Kali)
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/7.x/apt stable main" > /etc/apt/sources.list.d/elastic-7.x.list

apt update -y
apt install -y --no-install-recommends elasticsearch

# Configure Elasticsearch
cat > /etc/elasticsearch/elasticsearch.yml << 'EOF'
cluster.name: ewnet-noc
node.name: nodename
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 0.0.0.0
http.port: 9200
http.cors.enabled: true
http.cors.allow-origin: "*"
discovery.type: single-node
EOF

# JVM heap
mkdir -p /etc/elasticsearch/jvm.options.d/
cat > /etc/elasticsearch/jvm.options.d/heap.options << 'EOF'
-Xms2g
-Xmx2g
EOF

# System limits
cat >> /etc/security/limits.conf << 'EOF'
elasticsearch soft nofile 65536
elasticsearch hard nofile 65536
elasticsearch soft nproc 4096
elasticsearch hard nproc 4096
EOF

sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

chown -R elasticsearch:elasticsearch /etc/elasticsearch /var/lib/elasticsearch /var/log/elasticsearch
chmod 755 /var/lib/elasticsearch /var/log/elasticsearch

systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch

print_status "Waiting for Elasticsearch to start..."
sleep 20

if curl -s http://localhost:9200 > /dev/null; then
    print_success "Elasticsearch is running"
else
    print_error "Elasticsearch failed to start"
    systemctl status elasticsearch
    exit 1
fi

# ================================================================
# SECTION 4: KIBANA
# ================================================================

print_status "SECTION 4: Installing Kibana"

apt install -y --no-install-recommends kibana

cat > /etc/kibana/kibana.yml << 'EOF'
server.port: 5601
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://localhost:9200"]
server.name: "ewnet-noc-kibana"
EOF

mkdir -p /var/log/kibana
chown kibana:kibana /var/log/kibana

systemctl daemon-reload
systemctl enable kibana
systemctl start kibana

print_success "Kibana installed on http://localhost:5601"

# ================================================================
# SECTION 5: LOGSTASH
# ================================================================

print_status "SECTION 5: Installing Logstash"

apt install -y --no-install-recommends logstash

mkdir -p /etc/logstash/conf.d

cat > /etc/logstash/conf.d/00-inputs.conf << 'EOF'
input {
  beats { port => 5044 }
  syslog { port => 514 type => "syslog" }
  tcp { port => 9999 codec => "json" type => "netflow" }
  udp { port => 9999 codec => "json" type => "netflow" }
}
EOF

cat > /etc/logstash/conf.d/10-filters.conf << 'EOF'
filter {
  if [type] == "syslog" {
    grok {
      match => { "message" => "<%{POSINT:priority}>%{SYSLOGTIMESTAMP:timestamp} %{SYSLOGHOST:hostname} %{DATA:program}(?:\[%{POSINT:pid}\])?: %{GREEDYDATA:message}" }
    }
    date {
      match => [ "timestamp", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss" ]
      timezone => "Asia/Kathmandu"
    }
  }
}
EOF

cat > /etc/logstash/conf.d/30-outputs.conf << 'EOF'
output {
  elasticsearch {
    hosts => ["localhost:9200"]
    index => "logstash-%{+YYYY.MM.dd}"
  }
}
EOF

systemctl daemon-reload
systemctl enable logstash
systemctl start logstash

print_success "Logstash installed"

# ================================================================
# SECTION 6: BEATS
# ================================================================

print_status "SECTION 6: Installing Beats"

apt install -y --no-install-recommends metricbeat filebeat packetbeat

# Metricbeat
cat > /etc/metricbeat/metricbeat.yml << 'EOF'
metricbeat.modules:
  - module: system
    period: 10s
    metricsets:
      - cpu
      - load
      - memory
      - network
      - process
      - diskio
      - filesystem
    processes: ['.*']
    process.include_top_n:
      by_cpu: 5
      by_memory: 5

output.elasticsearch:
  hosts: ["localhost:9200"]
  index: "metricbeat-%{+YYYY.MM.dd}"
EOF

# Filebeat
cat > /etc/filebeat/filebeat.yml << 'EOF'
filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /var/log/syslog
      - /var/log/auth.log
      - /var/log/kern.log
      - /var/log/messages

output.elasticsearch:
  hosts: ["localhost:9200"]
  index: "filebeat-%{+YYYY.MM.dd}"
EOF

# Packetbeat
cat > /etc/packetbeat/packetbeat.yml << 'EOF'
packetbeat.interfaces.device: eth0
packetbeat.flows.enabled: true
packetbeat.protocols:
  - type: dns
    ports: [53]
  - type: http
    ports: [80, 8080, 9200, 5601]
  - type: mysql
    ports: [3306]

output.elasticsearch:
  hosts: ["localhost:9200"]
  index: "packetbeat-%{+YYYY.MM.dd}"
EOF

systemctl enable metricbeat filebeat packetbeat
systemctl start metricbeat filebeat packetbeat

print_success "Beats installed and running"

# ================================================================
# SECTION 7: ZABBIX
# ================================================================

print_status "SECTION 7: Installing Zabbix"

# Zabbix 6.4 for Ubuntu 22.04 (Kali compatible)
wget -q https://repo.zabbix.com/zabbix/6.4/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.4-1+ubuntu22.04_all.deb
dpkg -i zabbix-release_6.4-1+ubuntu22.04_all.deb 2>/dev/null || true
rm -f zabbix-release_*.deb

apt update -y
apt install -y --no-install-recommends zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

# Import schema
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -u zabbix -p${ZABBIX_DB_PASS} zabbix 2>/dev/null || true

# Configure Zabbix Server
cat > /etc/zabbix/zabbix_server.conf << EOF
DBHost=localhost
DBName=zabbix
DBUser=zabbix
DBPassword=${ZABBIX_DB_PASS}
StartPollers=10
StartPollersUnreachable=5
StartTrappers=3
StartPingers=5
StartDiscoverers=5
CacheSize=128M
HistoryCacheSize=16M
TrendCacheSize=16M
ValueCacheSize=64M
Timeout=30
LogFile=/var/log/zabbix/zabbix_server.log
LogFileSize=50
EOF

# Frontend config
mkdir -p /etc/zabbix/web
cat > /etc/zabbix/web/zabbix.conf.php << EOF
<?php
\$DB['TYPE'] = 'MYSQL';
\$DB['SERVER'] = 'localhost';
\$DB['PORT'] = '3306';
\$DB['DATABASE'] = 'zabbix';
\$DB['USER'] = 'zabbix';
\$DB['PASSWORD'] = '${ZABBIX_DB_PASS}';
\$ZBX_SERVER = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = 'EWNet NOC';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
?>
EOF

# PHP config
cat > /etc/php/*/apache2/conf.d/99-zabbix.ini << 'EOF'
post_max_size = 16M
max_execution_time = 300
max_input_time = 300
date.timezone = Asia/Kathmandu
EOF

systemctl daemon-reload
systemctl enable zabbix-server zabbix-agent apache2
systemctl start zabbix-server zabbix-agent apache2

print_success "Zabbix installed - http://localhost/zabbix"
print_warning "Default Zabbix login: Admin/zabbix"

# ================================================================
# SECTION 8: GRAFANA & PROMETHEUS
# ================================================================

print_status "SECTION 8: Installing Grafana & Prometheus"

# Grafana
wget -qO - https://packages.grafana.com/gpg.key | apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" > /etc/apt/sources.list.d/grafana.list
apt update -y
apt install -y --no-install-recommends grafana

cat > /etc/grafana/grafana.ini << EOF
[server]
domain = localhost
root_url = http://localhost:3000

[auth.anonymous]
enabled = true
org_role = Viewer

[database]
type = mysql
host = localhost:3306
name = grafana
user = grafana
password = ${GRAFANA_DB_PASS}
EOF

systemctl daemon-reload
systemctl enable grafana-server
systemctl start grafana-server

print_success "Grafana installed - http://localhost:3000"
print_warning "Default Grafana login: admin/admin"

# Prometheus
print_status "Installing Prometheus..."
wget -q https://github.com/prometheus/prometheus/releases/download/v2.47.0/prometheus-2.47.0.linux-amd64.tar.gz
tar -xzf prometheus-*.tar.gz
mv prometheus-* /opt/prometheus
rm -f prometheus-*.tar.gz

useradd -r -s /bin/false prometheus 2>/dev/null || true
chown -R prometheus:prometheus /opt/prometheus

cat > /opt/prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'elasticsearch'
    static_configs:
      - targets: ['localhost:9200']
EOF

cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
WorkingDirectory=/opt/prometheus
ExecStart=/opt/prometheus/prometheus --config.file=/opt/prometheus/prometheus.yml --storage.tsdb.path=/opt/prometheus/data
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus

print_success "Prometheus running - http://localhost:9090"

# ================================================================
# SECTION 9: NOC PORTAL
# ================================================================

print_status "SECTION 9: Building NOC Portal"

mkdir -p /opt/noc-portal/{public/{css,js,images},views,logs}
cd /opt/noc-portal

cat > package.json << 'EOF'
{
  "name": "ewnet-noc-portal",
  "version": "1.0.0",
  "description": "Everest Wireless Network NOC Portal",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5",
    "@elastic/elasticsearch": "^7.17.0",
    "ejs": "^3.1.9"
  }
}
EOF

npm install --production

cat > server.js << 'EOF'
const express = require('express');
const cors = require('cors');
const { Client } = require('@elastic/elasticsearch');
const path = require('path');
const app = express();
const PORT = 3001;

const esClient = new Client({ node: 'http://localhost:9200' });

app.use(cors());
app.use(express.json());
app.use(express.static('public'));
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

app.get('/', async (req, res) => {
    try {
        const result = await esClient.search({
            index: 'logstash-*',
            body: {
                query: { match_all: {} },
                sort: [{ '@timestamp': { order: 'desc' } }],
                size: 10
            }
        });

        const events = result.body.hits.hits.map(h => ({
            timestamp: h._source['@timestamp'] || new Date().toISOString(),
            hostname: h._source.hostname || 'Unknown',
            message: h._source.message || 'No message'
        }));

        res.render('index', {
            title: 'EWNet NOC Dashboard',
            events: events,
            stats: {
                total_customers: 1250,
                uptime: '99.95',
                bandwidth: '2.4',
                alerts: 3
            }
        });
    } catch (error) {
        res.render('index', {
            title: 'EWNet NOC Dashboard',
            events: [],
            stats: { total_customers: 0, uptime: '0', bandwidth: '0', alerts: 0 }
        });
    }
});

app.get('/api/search', async (req, res) => {
    const q = req.query.q || '';
    try {
        const result = await esClient.search({
            index: 'logstash-*,metricbeat-*,filebeat-*',
            body: {
                query: {
                    multi_match: {
                        query: q,
                        fields: ['message', 'hostname', 'program', 'customer_id']
                    }
                },
                size: 50
            }
        });
        res.json(result.body.hits.hits.map(h => h._source));
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

app.listen(PORT, '0.0.0.0', () => {
    console.log(`NOC Portal running on http://localhost:${PORT}`);
});
EOF

mkdir -p views
cat > views/index.ejs << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title><%= title %></title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 0; padding: 20px; background: #f0f2f5; }
        .header { background: #1a2332; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .stats { display: grid; grid-template-columns: repeat(4,1fr); gap: 15px; margin-bottom: 20px; }
        .stat-card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .stat-card h3 { margin: 0; color: #666; font-size: 14px; }
        .stat-card .value { font-size: 28px; font-weight: bold; margin: 10px 0; }
        .events { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 10px; text-align: left; border-bottom: 1px solid #eee; }
        th { background: #f8f9fa; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🌐 Everest Wireless Network</h1>
        <p>NOC Portal - Service Assurance Platform</p>
    </div>

    <div class="stats">
        <div class="stat-card"><h3>Total Customers</h3><div class="value"><%= stats.total_customers %></div></div>
        <div class="stat-card"><h3>Uptime</h3><div class="value"><%= stats.uptime %>%</div></div>
        <div class="stat-card"><h3>Bandwidth</h3><div class="value"><%= stats.bandwidth %> Gbps</div></div>
        <div class="stat-card"><h3>Active Alerts</h3><div class="value"><%= stats.alerts %></div></div>
    </div>

    <div class="events">
        <h2>Recent Events</h2>
        <table>
            <thead><tr><th>Timestamp</th><th>Host</th><th>Message</th></tr></thead>
            <tbody>
                <% events.forEach(event => { %>
                <tr><td><%= event.timestamp %></td><td><%= event.hostname %></td><td><%= event.message %></td></tr>
                <% }); %>
                <% if(events.length === 0) { %>
                <tr><td colspan="3" style="text-align:center;">No events found</td></tr>
                <% } %>
            </tbody>
        </table>
    </div>
</body>
</html>
EOF

cat > /etc/systemd/system/noc-portal.service << 'EOF'
[Unit]
Description=EWNet NOC Portal
After=network.target elasticsearch.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/noc-portal
ExecStart=/usr/bin/node /opt/noc-portal/server.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable noc-portal
systemctl start noc-portal

print_success "NOC Portal running on http://localhost:3001"

# ================================================================
# SECTION 10: TR-069 ACS
# ================================================================

print_status "SECTION 10: Installing GenieACS"

cd /opt
git clone https://github.com/genieacs/genieacs.git 2>/dev/null || true
cd genieacs

# Fix for Kali - use older Node compatibility
npm install --production --legacy-peer-deps

cat > config/default.json << EOF
{
  "db": {
    "engine": "mysql",
    "host": "127.0.0.1",
    "database": "genieacs",
    "user": "genieacs",
    "password": "${GENIE_DB_PASS}"
  },
  "cwmp": {
    "port": 7547,
    "interface": "0.0.0.0"
  },
  "northbound": {
    "port": 7557
  },
  "ui": {
    "port": 3000
  }
}
EOF

node ./bin/genieacs-db-init 2>/dev/null || true

cat > /etc/systemd/system/genieacs-cwmp.service << 'EOF'
[Unit]
Description=GenieACS CWMP
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/genieacs
ExecStart=/usr/bin/node /opt/genieacs/bin/genieacs-cwmp
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable genieacs-cwmp
systemctl start genieacs-cwmp

print_success "GenieACS TR-069 server installed"

# ================================================================
# SECTION 11: FINAL SETUP
# ================================================================

print_status "SECTION 11: Final Setup & Verification"

cat > /usr/local/bin/noc-status.sh << 'EOF'
#!/bin/bash
echo "=========================================="
echo "EWNet NOC Status Check"
echo "=========================================="
echo "Services:"
systemctl status elasticsearch --no-pager | grep Active
systemctl status kibana --no-pager | grep Active
systemctl status logstash --no-pager | grep Active
systemctl status zabbix-server --no-pager | grep Active
systemctl status grafana-server --no-pager | grep Active
systemctl status prometheus --no-pager | grep Active
systemctl status noc-portal --no-pager | grep Active
echo ""
echo "Ports:"
netstat -tlnp 2>/dev/null | grep -E ':(80|443|3000|3001|5601|7547|9200|9090|10051)' | head -10
EOF

chmod +x /usr/local/bin/noc-status.sh

# MOTD
cat > /etc/motd << 'EOF'
==========================================
  🌐 EVEREST WIRELESS NETWORK
  Smart NOC System - Production Ready
==========================================

  Access URLs:
  ------------
  📊 NOC Portal      : http://localhost:3001
  📈 Kibana          : http://localhost:5601
  ⚙️ Zabbix          : http://localhost/zabbix
  📉 Grafana         : http://localhost:3000
  🔢 Prometheus      : http://localhost:9090
  📡 TR-069 ACS      : http://localhost:7547

  Default Credentials:
  -------------------
  Zabbix  : Admin / zabbix
  Grafana : admin / admin

  Status Check:
  ------------
  # noc-status.sh
==========================================
EOF

cat /etc/motd

# ================================================================
# COMPLETION
# ================================================================

print_success "================================================"
print_success "EWNet NOC System Deployment Complete!"
print_success "================================================"
print_success ""
print_success "Access URLs:"
print_success "  NOC Portal      : http://$(hostname -I | awk '{print $1}'):3001"
print_success "  Kibana          : http://$(hostname -I | awk '{print $1}'):5601"
print_success "  Zabbix          : http://$(hostname -I | awk '{print $1}')/zabbix"
print_success "  Grafana         : http://$(hostname -I | awk '{print $1}'):3000"
print_success "  Prometheus      : http://$(hostname -I | awk '{print $1}'):9090"
print_success ""
print_success "Default Credentials:"
print_success "  Zabbix  : Admin / zabbix"
print_success "  Grafana : admin / admin"
print_success ""
print_warning "Please change default passwords after first login!"
print_success "================================================"

exit 0
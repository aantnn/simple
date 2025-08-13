#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
           # <--- Port is now a variable

CONFIG="./zabbix.env"

function check_config_file() {
    if [[ ! -f "$CONFIG" ]]; then
        echo "Config file '$CONFIG' not found"
        exit 1
    fi
    source "$CONFIG"
}


# --- REQUIRE ROOT ---
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo $0"
    exit 1
fi
check_config_file

echo "=== Installing Zabbix repository ==="
wget -O /tmp/zabbix-release.deb \
  https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.4+ubuntu22.04_all.deb

dpkg -i /tmp/zabbix-release.deb
apt update -y

echo "=== Installing Zabbix server, frontend, agent ==="
apt install -y zabbix-server-mysql zabbix-frontend-php \
  zabbix-nginx-conf zabbix-sql-scripts zabbix-agent mysql-server

echo "=== Creating initial database and user ==="
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SET GLOBAL log_bin_trust_function_creators = 1;
SQL

echo "=== Importing initial Zabbix schema and data ==="
zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | \
  mysql --default-character-set=utf8mb4 -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}"

echo "=== Disabling log_bin_trust_function_creators flag ==="
mysql -uroot <<SQL
SET GLOBAL log_bin_trust_function_creators = 0;
SQL

echo "=== Configuring Nginx listen port to ${ZBX_PORT} ==="
# Change in /etc/zabbix/nginx.conf:
sed -i "s|^\s*#\?\s*listen\s\+[0-9]\+;|        listen ${ZBX_PORT};|" /etc/zabbix/nginx.conf

echo "=== Reminder ==="
echo "Edit /etc/zabbix/zabbix_server.conf and set:"
echo "    DBPassword=${DB_PASS}"
echo "Edit /etc/zabbix/nginx.conf and set the correct server_name for your host"

echo "=== Restarting and enabling services ==="
systemctl restart zabbix-server zabbix-agent nginx php${PHPVER}-fpm
systemctl enable zabbix-server zabbix-agent nginx php${PHPVER}-fpm

echo "Zabbix installation completed on port ${ZBX_PORT}"

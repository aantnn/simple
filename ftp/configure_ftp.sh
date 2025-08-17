#!/usr/bin/env bash
set -euo pipefail
set -o nounset ; set -o errexit ;

# Source configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/conf/ftp.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi



configure_mysql() {
    systemctl enable --now mysql
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${FTP_DB}\`;
CREATE USER IF NOT EXISTS '${FTP_DB_USER}'@'localhost' IDENTIFIED BY '${FTP_DB_PASS}';
GRANT SELECT ON \`${FTP_DB}\`.* TO '${FTP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    
  mysql "$FTP_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(64) NOT NULL UNIQUE,
  password VARCHAR(255) NOT NULL,
  active TINYINT(1) NOT NULL DEFAULT 1
);
SQL
}

configure_pam() {
    local template="./conf/vsftpd.mysql.pam.conf"
    local target="/etc/pam.d/vsftpd.mysql"
    FTP_DB_USER="${FTP_DB_USER}" FTP_DB_PASS="${FTP_DB_PASS}" FTP_DB="${FTP_DB}" \
    envsubst < "$template" > "$target"
    chmod 640 "$target"
    
}


configure_vsftpd() {
    cp -a /etc/vsftpd.conf /etc/vsftpd.conf.bak || true
    mkdir -p "${FTP_USERS_DIR}"
    local template="./conf/vsftpd.conf"
    local target="/etc/vsftpd.conf"
    
    FTP_USERS_DIR="${FTP_USERS_DIR}" GUEST_USER="${GUEST_USER}" PASV_MIN="${PASV_MIN}" PASV_MAX="${PASV_MAX}" \
    envsubst < "$template" > "$target"
}

restart_services() {
    systemctl enable --now vsftpd
    systemctl restart vsftpd
}

main() {
    #configure_mysql
    configure_pam
    configure_vsftpd
    restart_services
    echo "Server configured."
}

main "$@"

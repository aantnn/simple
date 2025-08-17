#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Root directory
BASE_DIR="ansible"

# Directories
dirs=(
  "$BASE_DIR/roles/ftp/tasks"
  "$BASE_DIR/roles/ftp/files"
  "$BASE_DIR/roles/ftp/handlers"
  "$BASE_DIR/roles/mail/tasks"
  "$BASE_DIR/roles/mail/files/postfix"
  "$BASE_DIR/roles/mail/files/dovecot"
  "$BASE_DIR/roles/mail/files/opendkim"
  "$BASE_DIR/roles/mail/handlers"
  "$BASE_DIR/roles/wordpress/tasks"
  "$BASE_DIR/roles/wordpress/files/nginx"
  "$BASE_DIR/roles/joomla/tasks"
  "$BASE_DIR/roles/joomla/files/nginx"
  "$BASE_DIR/roles/joomla/files/apache"
  "$BASE_DIR/roles/zabbix/tasks"
  "$BASE_DIR/roles/zabbix/files"
  "$BASE_DIR/roles/pma/tasks"
  "$BASE_DIR/roles/pma/files/nginx"
)

# Files
files=(
  "$BASE_DIR/ansible.cfg"
  "$BASE_DIR/playbook.yml"

  "$BASE_DIR/roles/ftp/tasks/main.yml"
  "$BASE_DIR/roles/ftp/files/vsftpd.conf"
  "$BASE_DIR/roles/ftp/files/mysql-virtual-users.sql"
  "$BASE_DIR/roles/ftp/files/add_ftp_user.sh"
  "$BASE_DIR/roles/ftp/handlers/main.yml"

  "$BASE_DIR/roles/mail/tasks/main.yml"
  "$BASE_DIR/roles/mail/files/postfix/main.cf"
  "$BASE_DIR/roles/mail/files/postfix/master.cf"
  "$BASE_DIR/roles/mail/files/dovecot/dovecot.conf"
  "$BASE_DIR/roles/mail/files/opendkim/opendkim.conf"
  "$BASE_DIR/roles/mail/files/add_mail_domain.sh"
  "$BASE_DIR/roles/mail/handlers/main.yml"

  "$BASE_DIR/roles/wordpress/tasks/main.yml"
  "$BASE_DIR/roles/wordpress/files/nginx/wp.conf"
  "$BASE_DIR/roles/wordpress/files/install_wp.sh"

  "$BASE_DIR/roles/joomla/tasks/main.yml"
  "$BASE_DIR/roles/joomla/files/nginx/joomla.conf"
  "$BASE_DIR/roles/joomla/files/apache/joomla.conf"
  "$BASE_DIR/roles/joomla/files/install_joomla.sh"

  "$BASE_DIR/roles/zabbix/tasks/main.yml"
  "$BASE_DIR/roles/zabbix/files/zabbix_server.conf"
  "$BASE_DIR/roles/zabbix/files/install_zabbix.sh"

  "$BASE_DIR/roles/pma/tasks/main.yml"
  "$BASE_DIR/roles/pma/files/nginx/pma.conf"
  "$BASE_DIR/roles/pma/files/install_pma.sh"
)

echo "Creating directories..."
mkdir -p "${dirs[@]}"

echo "Creating empty files..."
for f in "${files[@]}"; do
  [[ -f "$f" ]] || : > "$f"
done

echo "Directory structure created under: $BASE_DIR"


#!/usr/bin/env bash
set -euo pipefail

CONFIG="./joomla.env"

function check_config_file() {
    if [[ ! -f "$CONFIG" ]]; then
        echo "Config file '$CONFIG' not found"
        exit 1
    fi
    source "$CONFIG"
}



function install_packages() {
    echo "Updating packages and installing required software"
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y nginx apache2 mysql-server unzip wget \
    php libapache2-mod-php php-mysql php-xml php-gd php-curl \
    php-mbstring php-zip php-intl
}

function setup_mysql() {
    echo "Creating MySQL database and user for Joomla"
  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
}

function configure_apache() {
    local template="conf/apache.tpl"
    cat >/etc/apache2/ports.conf <<EOF
Listen 127.0.0.1:$APACHE_PORT
EOF
    
    WEBROOT="${WEBROOT}" DOMAIN="${DOMAIN}" APACHE_PORT="${APACHE_PORT}" \
    envsubst < "$template" > "/etc/apache2/sites-available/$DOMAIN.conf"
    
}

function deploy_joomla() {
    mkdir -p "$WEBROOT"
    cd /tmp
    wget -O joomla.zip "$JOOMLA_URL"
    unzip -q joomla.zip -d "$WEBROOT"
    chown -R www-data:www-data "$(dirname "$WEBROOT")"
    chmod -R 755 "$WEBROOT"
    [[ -f "$WEBROOT/htaccess.txt" ]] && mv "$WEBROOT/htaccess.txt" "$WEBROOT/.htaccess"
}

function enable_apache_modules() {
    PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    a2dismod mpm_event || true
    a2enmod mpm_prefork "php$PHPV" rewrite headers expires
    a2dissite 000-default || true
    a2ensite "$DOMAIN"
    systemctl reload apache2 || systemctl start apache2
}

function configure_nginx_proxy() {
  cat >"/etc/nginx/sites-available/$DOMAIN" <<EOF
server {
  listen 80;
  server_name $DOMAIN www.$DOMAIN;
  root $WEBROOT;
  index index.php index.html;

  location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

  location ~ \.php\$ {
      proxy_pass http://127.0.0.1:$APACHE_PORT;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }

  location ~* \.(jpg|jpeg|png|gif|ico|css|js)\$ {
        expires max;
        log_not_found off;
  }

  access_log /var/log/nginx/$DOMAIN.access.log;
  error_log /var/log/nginx/$DOMAIN.error.log;
}
EOF
    ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
    systemctl restart nginx
}

function show_summary() {
  cat <<EOM

Joomla setup is complete.

Access your site at: http://${DOMAIN}/
Web root: $WEBROOT
Database name: $DB_NAME
Database user: $DB_USER

Next steps:
- Complete Joomla's web installer in your browser
- Remove installation directory via Joomla administration panel

EOM
}


check_config_file
install_packages
setup_mysql
configure_apache
deploy_joomla
enable_apache_modules
configure_nginx_proxy
show_summary

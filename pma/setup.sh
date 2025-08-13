#!/usr/bin/env bash
set -euo pipefail

CONFIG="./pma.env"

function check_config_file() {
    if [[ ! -f "$CONFIG" ]]; then
        echo "Config file '$CONFIG' not found"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG"

    # Defaults and safe fallbacks
    : "${DOMAIN:=phpmyadmin.local}"
    : "${WEBROOT:=/usr/share/phpmyadmin}"
}

function install_packages() {
    echo "Updating packages and installing required software"
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y nginx mysql-server unzip wget \
        php-fpm php-mysql php-xml php-gd php-curl \
        php-mbstring php-zip php-intl

    # Preseed to avoid interactive prompts for phpMyAdmin
    echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections

    apt install -y phpmyadmin
}




function configure_nginx() {
    echo "Configuring Nginx for ${DOMAIN}"
    PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')

    cat >"/etc/nginx/sites-available/${DOMAIN}" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js)\$ {
        expires 7d;
        access_log off;
        log_not_found off;
    }

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;
}
EOF

    ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
    nginx -t
    systemctl restart nginx
    systemctl enable "php${PHPV}-fpm"
    systemctl restart "php${PHPV}-fpm"
}

function add_hosts_entry() {
    echo "Adding ${DOMAIN} to /etc/hosts"
    if ! grep -qE "^\s*127\.0\.0\.1\s+${DOMAIN}(\s|$)" /etc/hosts; then
        echo "127.0.0.1 ${DOMAIN}" >> /etc/hosts
    fi
}

function show_summary() {
    cat <<EOM

phpMyAdmin setup is complete.

Access:  http://${DOMAIN}/
Webroot: ${WEBROOT}
Config:  /etc/phpmyadmin/config.inc.php

Notes:
- Log in with your MySQL credentials (root or any MySQL user).
- Optional DB/user creation was executed only if DB_NAME/DB_USER/DB_PASS were provided.
- Consider securing MySQL root and adding SSL (self-signed or Let's Encrypt).

EOM
}

check_config_file
install_packages
configure_nginx
add_hosts_entry
show_summary

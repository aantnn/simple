#!/usr/bin/env bash
set -euo pipefail

CONFIG="./wp.env"

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
    apt install -y nginx mysql-server unzip wget \
    php-fpm php-mysql php-xml php-gd php-curl \
    php-mbstring php-zip php-intl
}

function setup_mysql() {
    echo "Creating MySQL database and user for WordPress"
    mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
}

function deploy_wordpress() {
    echo "Downloading and deploying WordPress"
    mkdir -p "$WEBROOT"
    cd /tmp
    wget -O wordpress.zip https://wordpress.org/latest.zip
    unzip -q wordpress.zip
    rsync -a wordpress/ "$WEBROOT/"
    chown -R www-data:www-data "$WEBROOT"
    chmod -R 755 "$WEBROOT"

    # Create wp-config.php
    cp "$WEBROOT/wp-config-sample.php" "$WEBROOT/wp-config.php"
    sed -i "s/database_name_here/$DB_NAME/" "$WEBROOT/wp-config.php"
    sed -i "s/username_here/$DB_USER/" "$WEBROOT/wp-config.php"
    sed -i "s/password_here/$DB_PASS/" "$WEBROOT/wp-config.php"
}

function configure_nginx() {
    PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
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
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php$PHPV-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
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
    nginx -t
    systemctl restart nginx
    systemctl enable php$PHPV-fpm
    systemctl restart php$PHPV-fpm
}

function show_summary() {
    cat <<EOM

WordPress setup is complete.

Access your site at: http://${DOMAIN}/
Web root: $WEBROOT
Database name: $DB_NAME
Database user: $DB_USER

Next steps:
- Complete WordPress installation via web browser
- Secure your MySQL root account and consider setting up SSL

EOM
}

check_config_file
install_packages
setup_mysql
deploy_wordpress
configure_nginx
show_summary

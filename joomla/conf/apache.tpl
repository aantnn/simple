<VirtualHost 127.0.0.1:$APACHE_PORT>
  ServerName ${DOMAIN}
  DocumentRoot ${WEBROOT}
  <Directory ${WEBROOT}>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
</VirtualHost>
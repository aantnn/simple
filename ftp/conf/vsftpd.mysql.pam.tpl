auth    required pam_mysql.so user=${FTP_DB_USER} passwd=${FTP_DB_PASS} host=localhost db=${FTP_DB} table=users usercolumn=username passwdcolumn=password where=active=1 crypt=1
account required pam_mysql.so user=${FTP_DB_USER} passwd=${FTP_DB_PASS} host=localhost db=${FTP_DB} table=users usercolumn=username passwdcolumn=password where=active=1 crypt=1

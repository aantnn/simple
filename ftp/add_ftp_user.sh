#!/usr/bin/env bash
# sudo FTP_DB=ftpdb FTP_VUSER=anton FTP_VPASS='AntonStrongPass!' DOMAIN=anton.dev bash ./add_ftp_user.sh
set -euo pipefail; 
set -o nounset ; set -o errexit ;

# Source configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/conf/ftp.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

hash_password() {
  local plain="$1"
  local salt
  salt="$(openssl rand -base64 12 | tr '/+' '._')"
  openssl passwd -6 -salt "$salt" "$plain"
}

create_user() {
  local hashed
  hashed="$(hash_password "$FTP_VPASS")"
  mysql "$FTP_DB" <<SQL
INSERT INTO users (username, password, active)
VALUES ('${FTP_VUSER}', '${hashed}', 1)
ON DUPLICATE KEY UPDATE password=VALUES(password), active=1;
SQL
}


configure_user_root() {
  local webroot="/var/www/${DOMAIN}"
  local template="conf/vsftpd_user.tpl"
  local target="${FTP_USERS_DIR}/${FTP_VUSER}"

  mkdir -p "$webroot"
  chown -R "$GUEST_USER:$GUEST_USER" "$webroot"

  echo "Welcome to ${DOMAIN}" > "$webroot/readme.txt"
  chown "$GUEST_USER:$GUEST_USER" "$webroot/readme.txt"

  webroot="${webroot}" \
    envsubst < "$template" > "$target"
}


test_connectivity() {
  if command -v curl >/dev/null 2>&1; then
    echo "Attempting a quick FTP login test against localhost..."
    set +e
    curl -sS --ftp-method nocwd "ftp://${FTP_VUSER}:${FTP_VPASS}@127.0.0.1/" >/dev/null
    local rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      echo "Basic FTP auth test: OK (via curl)."
    else
      echo "Basic FTP auth test: FAILED (curl exit ${rc}). You can still test with an FTP client."
    fi
  fi
}

main() {
  create_user
  configure_user_root
  test_connectivity
  echo "FTP user '${FTP_VUSER}' created."
}

main "$@"

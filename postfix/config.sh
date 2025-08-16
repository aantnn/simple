#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 022

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*" >&2; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }; }

pkg_install() {
    local -a pkgs=("$@")
    if command -v apt-get >/dev/null; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || true
    elif command -v dnf >/dev/null; then
        dnf install -y "${pkgs[@]}" || true
    elif command -v yum >/dev/null; then
        yum install -y epel-release || true
        yum install -y "${pkgs[@]}" || true
    else
        log "WARN: Install these packages manually: ${pkgs[*]}"
    fi
}

backup_once() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local b="${f}.bak.$(date +%s)"
    cp -a "$f" "$b"
    log "Backup: $f -> $b"
}

configure_postfix() {
    export HOSTNAME VMAIL_UID VMAIL_GID
    envsubst '${HOSTNAME} ${VMAIL_UID} ${VMAIL_GID}' < ./conf/postfix.conf | postconf -e

    mkdir -p /etc/postfix
    touch /etc/postfix/{vmail_domains,vmail_mailbox,vmail_aliases}
    chmod 640 /etc/postfix/{vmail_domains,vmail_mailbox,vmail_aliases}
    postmap /etc/postfix/vmail_domains || true
    postmap /etc/postfix/vmail_mailbox || true
    postmap /etc/postfix/vmail_aliases || true
}

configure_tls_and_submission() {
    if [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]]; then
        log "TLS keypair found — secure mode"
        export TLS_CERT TLS_KEY
        envsubst '${TLS_CERT} ${TLS_KEY}' < ./conf/tls.conf | postconf -e
    else
        log "No TLS keypair — enabling plaintext AUTH on submission (unsafe outside localhost!)"
        postconf -e "smtpd_tls_security_level = none"
        postconf -e "smtpd_tls_auth_only = no"

        postconf -M submission/inet || true
        postconf -Me "submission/inet=submission inet n - y - - smtpd"
        postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
        postconf -P "submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"
    fi
}

configure_opendkim() {
    mkdir -p /etc/opendkim/keys
    backup_once /etc/opendkim.conf
    export HOSTNAME
    envsubst '${HOSTNAME}' < ./conf/opendkim.conf > /etc/opendkim.conf

    touch /etc/opendkim/{KeyTable,SigningTable,TrustedHosts}
    chmod 640 /etc/opendkim/{KeyTable,SigningTable,TrustedHosts}
    chown -R opendkim:opendkim /etc/opendkim
    mkdir -p /var/spool/postfix/opendkim && chown opendkim:opendkim /var/spool/postfix/opendkim

    postconf -e <<'EOF'
milter_default_action = accept
milter_protocol = 6
smtpd_milters = local:/opendkim/opendkim.sock
non_smtpd_milters = $smtpd_milters
EOF
    local override_dir="/etc/systemd/system/opendkim.service.d"
    mkdir -p "$override_dir"
    cat >"$override_dir/override.conf" <<'OVR'
[Service]
User=opendkim
Group=postfix
OVR
}

configure_dovecot() {
    mkdir -p /etc/dovecot/conf.d
    backup_once /etc/dovecot/conf.d/99-virtual-mail.conf
    export VMAIL_UID VMAIL_GID
    envsubst '${VMAIL_UID} ${VMAIL_GID}' < ./conf/dovecot.conf > /etc/dovecot/conf.d/99-virtual-mail.conf
    touch /etc/dovecot/passwd
    chown root:dovecot /etc/dovecot/passwd
    chmod 640 /etc/dovecot/passwd
}

reload_services() {
    systemctl daemon-reexec
    systemctl enable --now postfix dovecot opendkim 2>/dev/null || true
    systemctl restart opendkim dovecot postfix 2>/dev/null || true
    log "Services enabled and restarted"
}

obtain_cert() {
    log "Obtaining TLS certificate via Certbot"
    certbot certonly --nginx -d "$HOSTNAME" --agree-tos --email "admin@$HOSTNAME" --non-interactive
    TLS_CERT="/etc/letsencrypt/live/$HOSTNAME/fullchain.pem"
    TLS_KEY="/etc/letsencrypt/live/$HOSTNAME/privkey.pem"
    rm /etc/nginx/sites-enabled/mail.conf
}

configure_nginx_for_certbot() {
    mkdir -p /var/www/html
    cat >/etc/nginx/sites-available/mail.conf <<EOF
server {
    listen 80;
    server_name $HOSTNAME;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/mail.conf /etc/nginx/sites-enabled/mail.conf
    nginx -t && systemctl restart nginx
}

# --- defaults & args ---
HOSTNAME="$(hostname -f || hostname)"
VMAIL_UID=2222
VMAIL_GID=2222
TLS_CERT=""
TLS_KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)      HOSTNAME="$2"; shift 2 ;;
        --vmail-uid)     VMAIL_UID="$2"; shift 2 ;;
        --vmail-gid)     VMAIL_GID="$2"; shift 2 ;;
        --tls-cert-file) TLS_CERT="$2"; shift 2 ;;
        --tls-key-file)  TLS_KEY="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# --- main execution ---
need_root
pkg_install postfix dovecot-core dovecot-lmtpd dovecot-imapd opendkim opendkim-tools || true

# vmail system user setup
getent group  "$VMAIL_GID"  >/dev/null || groupadd -g "$VMAIL_GID" vmail
getent passwd "$VMAIL_UID"  >/dev/null || useradd -r -u "$VMAIL_UID" -g "$VMAIL_GID" \
    -d /var/vmail -m -s /usr/sbin/nologin vmail
mkdir -p /var/vmail
chown -R "$VMAIL_UID":"$VMAIL_GID" /var/vmail
chmod 750 /var/vmail

#configure_nginx_for_certbot
#obtain_cert
configure_postfix
configure_tls_and_submission
configure_opendkim
configure_dovecot
reload_services

log "Init complete. Use your add-domain.sh and mailbox-add.sh scripts to populate domains, DKIM, and users."

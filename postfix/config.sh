#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# mail-init.sh — Postfix + Dovecot + OpenDKIM initializer (virtual domains/users)
# Example:
#   ./mail-init.sh --hostname mail.example.com \
#                  --vmail-uid 2222 --vmail-gid 2222 \
#                  [--tls-cert-file /path/fullchain.pem] \
#                  [--tls-key-file /path/privkey.pem]

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

# Defaults
HOSTNAME="$(hostname -f || hostname)"
VMAIL_UID=2222
VMAIL_GID=2222
TLS_CERT=""
TLS_KEY=""

# Args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname) HOSTNAME="$2"; shift 2 ;;
        --vmail-uid) VMAIL_UID="$2"; shift 2 ;;
        --vmail-gid) VMAIL_GID="$2"; shift 2 ;;
        --tls-cert-file) TLS_CERT="$2"; shift 2 ;;
        --tls-key-file) TLS_KEY="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

need_root

pkg_install postfix dovecot-core dovecot-lmtpd dovecot-imapd opendkim opendkim-tools|| true

# vmail system user
getent group  "$VMAIL_GID" >/dev/null || groupadd -g "$VMAIL_GID" vmail
getent passwd "$VMAIL_UID" >/dev/null || useradd -r -u "$VMAIL_UID" -g "$VMAIL_GID" -d /var/vmail -m -s /usr/sbin/nologin vmail
mkdir -p /var/vmail && chown -R "$VMAIL_UID":"$VMAIL_GID" /var/vmail && chmod 750 /var/vmail

# Core Postfix config
postconf -e "myhostname = ${HOSTNAME}"
postconf -e "myorigin = \$myhostname"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mynetworks = 127.0.0.0/8 [::1]/128"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
postconf -e "virtual_mailbox_base = /var/vmail"
postconf -e "virtual_mailbox_domains = hash:/etc/postfix/vmail_domains"
postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmail_mailbox"
postconf -e "virtual_alias_maps = hash:/etc/postfix/vmail_aliases"
postconf -e "virtual_uid_maps = static:${VMAIL_UID}"
postconf -e "virtual_gid_maps = static:${VMAIL_GID}"
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_helo_required = yes"
postconf -e "smtpd_helo_restrictions = permit_mynetworks, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname"
postconf -e "smtpd_sender_restrictions = reject_non_fqdn_sender, reject_unknown_sender_domain"
postconf -e "smtpd_recipient_restrictions = reject_non_fqdn_recipient, reject_unknown_recipient_domain"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"

# Maps
mkdir -p /etc/postfix
touch /etc/postfix/{vmail_domains,vmail_mailbox,vmail_aliases}
chmod 640 /etc/postfix/{vmail_domains,vmail_mailbox,vmail_aliases}
postmap /etc/postfix/vmail_domains || true
postmap /etc/postfix/vmail_mailbox || true
postmap /etc/postfix/vmail_aliases || true

# TLS/auth conditional
if [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]]; then
    log "TLS keypair found — secure mode"
    postconf -e "smtpd_tls_security_level = may"
    postconf -e "smtpd_tls_auth_only = yes"
    postconf -e "smtpd_tls_cert_file = ${TLS_CERT}"
    postconf -e "smtpd_tls_key_file  = ${TLS_KEY}"

    postconf -M submission/inet || true
    postconf -Me "submission/inet=submission inet n - y - - smtpd"
    postconf -P "submission/inet/smtpd_tls_security_level=encrypt"
    postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
    postconf -P "submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"

    postconf -M smtps/inet || true
    postconf -Me "smtps/inet=smtps inet n - y - - smtpd"
    postconf -P "smtps/inet/smtpd_tls_wrappermode=yes"
    postconf -P "smtps/inet/smtpd_sasl_auth_enable=yes"
    postconf -P "smtps/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"
else
    log "No TLS keypair — enabling plaintext AUTH on submission (unsafe outside localhost!)"
    postconf -e "smtpd_tls_security_level = none"
    postconf -e "smtpd_tls_auth_only = no"

    postconf -M submission/inet || true
    postconf -Me "submission/inet=submission inet n - y - - smtpd"
    postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
    postconf -P "submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"
fi

# OpenDKIM base
mkdir -p /etc/opendkim/keys
backup_once /etc/opendkim.conf
cat >/etc/opendkim.conf <<CONF
PidFile                 /run/opendkim/opendkim.pid
Syslog                  yes
UMask                   002
Mode                    sv
Canonicalization        relaxed/simple
SubDomains              no
AutoRestart             no
Background              yes
DNSTimeout              5
SignatureAlgorithm      rsa-sha256
KeyTable                /etc/opendkim/KeyTable
SigningTable            /etc/opendkim/SigningTable
ExternalIgnoreList      /etc/opendkim/TrustedHosts
InternalHosts           /etc/opendkim/TrustedHosts
Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
CONF
touch /etc/opendkim/{KeyTable,SigningTable,TrustedHosts}
chmod 640 /etc/opendkim/{KeyTable,SigningTable,TrustedHosts}
chown -R opendkim:opendkim /etc/opendkim
mkdir -p /var/spool/postfix/opendkim && chown opendkim:opendkim /var/spool/postfix/opendkim



# Wire milters
postconf -e "milter_default_action = accept"
postconf -e "milter_protocol = 6"
postconf -e "smtpd_milters = local:/opendkim/opendkim.sock"
postconf -e "non_smtpd_milters = \$smtpd_milters"

# Dovecot minimal — advertise both PLAIN and LOGIN
mkdir -p /etc/dovecot/conf.d
backup_once /etc/dovecot/conf.d/99-virtual-mail.conf
cat >/etc/dovecot/conf.d/99-virtual-mail.conf <<CONF
mail_location = maildir:/var/vmail/%d/%n
mail_uid = ${VMAIL_UID}
mail_gid = ${VMAIL_GID}

protocols = imap lmtp

# Allow both PLAIN and LOGIN so tests/tools can pick either
auth_mechanisms = plain login

passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/passwd
}
userdb {
  driver = static
  args = uid=${VMAIL_UID} gid=${VMAIL_GID} home=/var/vmail/%d/%n
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
CONF

touch /etc/dovecot/passwd
sudo chown root:dovecot /etc/dovecot/passwd
sudo chmod 640 /etc/dovecot/passwd

# Enable and start services
systemctl enable postfix 2>/dev/null || true
systemctl enable dovecot 2>/dev/null || true
systemctl enable opendkim 2>/dev/null || true

systemctl restart opendkim 2>/dev/null || true
systemctl restart dovecot 2>/dev/null || true
systemctl restart postfix 2>/dev/null || true

log "Init complete. Use your add-domain.sh and mailbox-add.sh scripts to populate domains, DKIM, and users."

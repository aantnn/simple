#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

# mailbox-add.sh <domain> <localpart> [--password-file /path] [--create-maildir]
log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*" >&2; }
need_root() { if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo "Run as root." >&2; exit 1; fi; }

DOMAIN="${1:-}"
LOCAL="${2:-}"
[[ -n "$DOMAIN" && -n "$LOCAL" ]] || { echo "Usage: $0 <domain> <localpart> [--password-file /path] [--create-maildir]"; exit 2; }

PASSFILE=""
CREATE_MAILDIR=0

shift 2 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --password-file) PASSFILE="$2"; shift 2 ;;
    --create-maildir) CREATE_MAILDIR=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

need_root

EMAIL="${LOCAL}@${DOMAIN}"
MAILDIR="/var/vmail/${DOMAIN}/${LOCAL}"

# 1. Ensure domain exists in Postfix domain map
if ! grep -qsE "^${DOMAIN}[[:space:]]+OK\$" /etc/postfix/vmail_domains; then
  echo "${DOMAIN} OK" >> /etc/postfix/vmail_domains
  postmap /etc/postfix/vmail_domains
fi

# 2. Add to virtual_mailbox map
VMAP="/etc/postfix/vmail_mailbox"
LINE="${EMAIL} ${DOMAIN}/${LOCAL}/"
if ! grep -qsE "^${EMAIL}[[:space:]]+${DOMAIN}/${LOCAL}/\$" "$VMAP"; then
  echo "$LINE" >> "$VMAP"
  chmod 640 "$VMAP"
  postmap "$VMAP"
  systemctl reload postfix 2>/dev/null || true
  log "Postfix: added mailbox ${EMAIL}"
else
  log "Postfix: mailbox ${EMAIL} already present"
fi

# 3. Capture password into a secure temp file (no leaks to cmdline/env)
TMPPW="$(mktemp)"
chmod 600 "$TMPPW"

if [[ -n "$PASSFILE" ]]; then
  cp "$PASSFILE" "$TMPPW"
else
  if [[ -t 0 ]]; then
    echo -n "Enter password for ${EMAIL}: "
    stty -echo
    read -r PASSINPUT
    stty echo
    echo
    # write password twice with newline, like an interactive confirm
    printf '%s\n%s' "$PASSINPUT" "$PASSINPUT" > "$TMPPW"
    unset PASSINPUT
  else
    cat - > "$TMPPW"
  fi
fi

# 4. Generate hash using temp file (run as dovecot user to avoid stats-writer perms)
if ! command -v doveadm >/dev/null 2>&1; then
  echo "doveadm not found; install dovecot-core/dovecot." >&2
  shred -u "$TMPPW"
  exit 1
fi
HASH="$(sudo -u dovecot doveadm pw -u "$EMAIL" -s SHA512-CRYPT < "$TMPPW")"

# 5. Remove temp file securely
shred -u "$TMPPW"

# 6. Add/update Dovecot passwd entry (username is user@domain)
DPASS="/etc/dovecot/passwd"
if grep -qsE "^${EMAIL}:" "$DPASS"; then
  sed -i "s|^${EMAIL}:.*|${EMAIL}:${HASH}|" "$DPASS"
  log "Dovecot: updated password for ${EMAIL}"
else
  echo "${EMAIL}:${HASH}" >> "$DPASS"
  log "Dovecot: added user ${EMAIL}"
fi
chown root:dovecot "$DPASS"
chmod 640 "$DPASS"
systemctl reload dovecot 2>/dev/null || true

# 7. Optionally create Maildir now (Dovecot LMTP will create it on first delivery otherwise)
if [[ "$CREATE_MAILDIR" -eq 1 ]]; then
  install -d -m 700 -o vmail -g vmail "${MAILDIR}"/{cur,new,tmp}
  log "Created Maildir at ${MAILDIR}"
fi

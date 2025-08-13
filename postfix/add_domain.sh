#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

# domain-add.sh example.com [--selector default] [--bits 2048]
log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*" >&2; }
need_root() { if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo "Run as root." >&2; exit 1; fi; }

DOMAIN="${1:-}"
[[ -n "${DOMAIN}" ]] || { echo "Usage: $0 <domain> [--selector default] [--bits 2048]"; exit 2; }
SELECTOR="default"
BITS="2048"

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selector) SELECTOR="$2"; shift 2 ;;
    --bits) BITS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

need_root

# Ensure in vmail_domains
if ! grep -qsE "^${DOMAIN}[[:space:]]+OK\$" /etc/postfix/vmail_domains; then
  echo "${DOMAIN} OK" >> /etc/postfix/vmail_domains
  chmod 640 /etc/postfix/vmail_domains
  postmap /etc/postfix/vmail_domains
  systemctl reload postfix 2>/dev/null || true
  log "Added domain to /etc/postfix/vmail_domains"
else
  log "Domain already present in /etc/postfix/vmail_domains"
fi

# DKIM key generation
KEYDIR="/etc/opendkim/keys/${DOMAIN}"
mkdir -p "$KEYDIR"
if [[ ! -f "${KEYDIR}/${SELECTOR}.private" ]]; then
  opendkim-genkey -b "${BITS}" -d "${DOMAIN}" -D "${KEYDIR}" -s "${SELECTOR}" -v
  chown -R opendkim:opendkim "$KEYDIR" || true
  chmod 600 "${KEYDIR}/${SELECTOR}.private"
  log "Generated DKIM key ${SELECTOR} for ${DOMAIN}"
else
  log "DKIM key exists for ${DOMAIN} (${SELECTOR})"
fi

# Wire KeyTable and SigningTable
KT_LINE="${SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:${KEYDIR}/${SELECTOR}.private"
if ! grep -qsF "$KT_LINE" /etc/opendkim/KeyTable; then
  echo "$KT_LINE" >> /etc/opendkim/KeyTable
fi

ST_LINE="*@${DOMAIN} ${SELECTOR}._domainkey.${DOMAIN}"
if ! grep -qsF "$ST_LINE" /etc/opendkim/SigningTable; then
  echo "$ST_LINE" >> /etc/opendkim/SigningTable
fi

# TrustedHosts (allow local)
grep -qsE '^(127\.0\.0\.1|localhost)$' /etc/opendkim/TrustedHosts || {
  {
    echo "127.0.0.1"
    echo "localhost"
  } >> /etc/opendkim/TrustedHosts
}

systemctl restart opendkim 2>/dev/null || true


# Output DKIM DNS (one line)
TXT_FILE="${KEYDIR}/${SELECTOR}.txt"
if [[ -f "$TXT_FILE" ]]; then
  echo
  echo "Publish this DKIM TXT record in DNS:"
  printf '%s\n' "$(tr -d '\n' < "$TXT_FILE" | sed 's/\"[[:space:]]\+/\" \"'/g)"
fi

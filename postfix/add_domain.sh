#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*" >&2; }
need_root() { if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo "Run as root." >&2; exit 1; fi; }

# --- config ---
SELECTOR="default"
BITS="2048"
DOMAIN="${1:-}"

# --- parse args ---
[[ -n "${DOMAIN}" ]] || { echo "Usage: $0 <domain> [--selector default] [--bits 4096]"; exit 2; }
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selector) SELECTOR="$2"; shift 2 ;;
    --bits) BITS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- functions ---
add_domain_to_vmail() {
    if ! grep -qsE "^${DOMAIN}[[:space:]]+OK\$" /etc/postfix/vmail_domains; then
        echo "${DOMAIN} OK" >> /etc/postfix/vmail_domains
        chmod 640 /etc/postfix/vmail_domains
        postmap /etc/postfix/vmail_domains
        log "Added domain to /etc/postfix/vmail_domains"
    else
        log "Domain already present in /etc/postfix/vmail_domains"
    fi
}

generate_dkim_key() {
    local keydir="/etc/opendkim/keys/${DOMAIN}"
    mkdir -p "$keydir"
    if [[ ! -f "${keydir}/${SELECTOR}.private" ]]; then
        opendkim-genkey -b "${BITS}" -d "${DOMAIN}" -D "${keydir}" -s "${SELECTOR}" -v
        chown -R opendkim:opendkim "$keydir" || true
        chmod 600 "${keydir}/${SELECTOR}.private"
        log "Generated DKIM key ${SELECTOR} for ${DOMAIN}"
    else
        log "DKIM key exists for ${DOMAIN} (${SELECTOR})"
    fi
}

configure_dkim_tables() {
    local keydir="/etc/opendkim/keys/${DOMAIN}"
    local kt_line="${SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:${keydir}/${SELECTOR}.private"
    local st_line="*@${DOMAIN} ${SELECTOR}._domainkey.${DOMAIN}"

    grep -qsF "$kt_line" /etc/opendkim/KeyTable     || echo "$kt_line" >> /etc/opendkim/KeyTable
    grep -qsF "$st_line" /etc/opendkim/SigningTable || echo "$st_line" >> /etc/opendkim/SigningTable

    grep -qsE '^(127\.0\.0\.1|localhost)$' /etc/opendkim/TrustedHosts || {
        echo "127.0.0.1" >> /etc/opendkim/TrustedHosts
        echo "localhost" >> /etc/opendkim/TrustedHosts
    }
}

reload_services() {
    systemctl reload postfix  2>/dev/null || true
    systemctl restart opendkim 2>/dev/null || true
    log "Services reloaded"
}

test_dkim() {
    local keydir="/etc/opendkim/keys/${DOMAIN}"
    local txt_file="${keydir}/${SELECTOR}.txt"
    if [[ -f "$txt_file" ]]; then
        echo
        echo "Publish this DKIM TXT record in DNS:"
        printf '%s\n' "$(tr -d '\n' < "$txt_file" | sed 's/\"[[:space:]]\+/\" \"'/g)"
    fi
}

# --- main ---
need_root
add_domain_to_vmail
generate_dkim_key
configure_dkim_tables
reload_services
test_dkim

#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*" >&2; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }; }

# --- functions ---
ensure_domain_in_postfix() {
    if ! grep -qsE "^${DOMAIN}[[:space:]]+OK\$" /etc/postfix/vmail_domains; then
        echo "${DOMAIN} OK" >> /etc/postfix/vmail_domains
        postmap /etc/postfix/vmail_domains
        log "Postfix: added domain ${DOMAIN}"
    fi
}

ensure_mailbox_mapping() {
    local vmap="/etc/postfix/vmail_mailbox"
    local line="${EMAIL} ${DOMAIN}/${LOCAL}/"
    if ! grep -qsE "^${EMAIL}[[:space:]]+${DOMAIN}/${LOCAL}/\$" "$vmap"; then
        echo "$line" >> "$vmap"
        chmod 640 "$vmap"
        postmap "$vmap"
        log "Postfix: added mailbox ${EMAIL}"
    else
        log "Postfix: mailbox ${EMAIL} already present"
    fi
}

capture_password() {
    local tmppw
    tmppw="$(mktemp)"
    chmod 600 "$tmppw"

    if [[ -n "$PASSFILE" ]]; then
        cp "$PASSFILE" "$tmppw"
    else
        if [[ -t 0 ]]; then
            echo -n "Enter password for ${EMAIL}: "
            stty -echo
            read -r passinput
            stty echo
            echo
            printf '%s\n%s' "$passinput" "$passinput" > "$tmppw"
            unset passinput
        else
            cat - > "$tmppw"
        fi
    fi

    echo "$tmppw"
}

generate_dovecot_hash() {
    local tmppw="$1"
    if ! command -v doveadm >/dev/null 2>&1; then
        echo "doveadm not found; install dovecot-core/dovecot." >&2
        shred -u "$tmppw"
        exit 1
    fi
    sudo -u dovecot doveadm pw -u "$EMAIL" -s SHA512-CRYPT < "$tmppw"
}

update_dovecot_passwd() {
    local hash="$1"
    local dpass="/etc/dovecot/passwd"
    if grep -qsE "^${EMAIL}:" "$dpass"; then
        sed -i "s|^${EMAIL}:.*|${EMAIL}:${hash}|" "$dpass"
        log "Dovecot: updated password for ${EMAIL}"
    else
        echo "${EMAIL}:${hash}" >> "$dpass"
        log "Dovecot: added user ${EMAIL}"
    fi
    chown root:dovecot "$dpass"
    chmod 640 "$dpass"
}

create_maildir_if_requested() {
    if [[ "$CREATE_MAILDIR" -eq 1 ]]; then
        install -d -m 700 -o vmail -g vmail "${MAILDIR}"/{cur,new,tmp}
        log "Created Maildir at ${MAILDIR}"
    fi
}

reload_services() {
    systemctl reload postfix dovecot 2>/dev/null || true
    log "Reloaded Postfix and Dovecot"
}


# --- arg parsing ---
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

# --- main ---
need_root
EMAIL="${LOCAL}@${DOMAIN}"
MAILDIR="/var/vmail/${DOMAIN}/${LOCAL}"

ensure_domain_in_postfix
ensure_mailbox_mapping

tmpfile="$(capture_password)"
hashval="$(generate_dovecot_hash "$tmpfile")"
shred -u "$tmpfile"

update_dovecot_passwd "$hashval"
create_maildir_if_requested

reload_services

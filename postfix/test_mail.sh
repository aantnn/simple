#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Usage: ./mail-test.sh test@example.com 'password' recipient@example.net
FROM="${1:-}"
PASS="${2:-}"
TO="${3:-}"

if [[ -z "$FROM" || -z "$PASS" || -z "$TO" ]]; then
  echo "Usage: $0 <from-addr> <password> <to-addr>" >&2
  exit 1
fi

SMTP_HOST="localhost"
SMTP_PORT=25 

if ! command -v swaks >/dev/null 2>&1; then
  echo "swaks not installed — installing..." >&2
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y swaks
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y swaks
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y swaks
  else
    echo "Cannot install swaks automatically; install manually and rerun." >&2
    exit 1
  fi
fi

# check-auth@verifier.port25.com
echo "=== Sending test mail via $SMTP_HOST:$SMTP_PORT ==="
swaks \
  --server "$SMTP_HOST" \
  --port "$SMTP_PORT" \
  --auth LOGIN \
  --auth-user "$FROM" \
  --auth-password "$PASS" \
  --from "$FROM" \
  --to "$TO" \
  --header "Subject: Postfix test $(date +%F\ %T)" \
  --body "Hello, this is a test message sent through our Postfix/Dovecot setup."


echo "=== Checking if the mail was received if sent to itself ==="
curl --user "$FROM:$PASS" "imap://"$SMTP_HOST"/INBOX/;UID=1"

echo "=== Simulating inbound mail from remote MTA to $FROM via $SMTP_HOST:$SMTP_PORT ==="
swaks \
  --server "$SMTP_HOST" \
  --port "$SMTP_PORT" \
  --from "test-remote-sender@gmail.com" \
  --to "$FROM" \
  --header "Subject: Inbound receive test $(date +%F\ %T)" \
  --body "This is a test message simulating reception from another SMTP server into Postfix."

echo
echo "=== Checking via IMAP if $FROM received the message ==="
# List latest message in INBOX
curl --user "$FROM:$PASS" \
     --silent \
     "imap://$SMTP_HOST/INBOX/;UID=2" || {
  echo "IMAP fetch failed — check credentials or Dovecot" >&2
  exit 1
}

#!/usr/bin/env bash
set -euo pipefail
set -o nounset ; set -o errexit ;

require_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "Run as root."; exit 1; }
}

check_os() {
  command -v apt-get >/dev/null || { echo "APT-based system required."; exit 1; }
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y mysql-server vsftpd libpam-mysql openssl whois
}

main() {
  require_root
  check_os
  install_packages
  echo "Packages installed."
}

main "$@"

#!/bin/bash 
set -euo pipefail
sudo dnf install python3-devel mysql-devel pkg-config
/var/home/a/.local/share/pipx/venvs/ansible/bin/python -m pip install PyMySQL
ansible-galaxy collection install community.mysql
secret-tool store --label='ansible-vault-dev' xdg:schema org.freedesktop.Secret.Generic account  ansible-vault-dev
ansible-vault encrypt_string  --encrypt-vault-id dev  'ftppass123!ChangeMe' --name 'ftp_db_pass'
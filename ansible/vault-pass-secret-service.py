#!/usr/bin/env python3
# ansible-vault edit --vault-password-file=./vault-pass-secret-service.py 
# secret-tool store --label='ansible-vault' xdg:schema org.freedesktop.Secret.Generic account ansible-vault
import gi
gi.require_version('Secret', '1')
from gi.repository import Secret

schema = Secret.Schema.new("org.freedesktop.Secret.Generic",
    Secret.SchemaFlags.NONE,
    {"account": Secret.SchemaAttributeType.STRING})

# Lookup without prompting — works only if DB is unlocked
pw = Secret.password_lookup_sync(schema, {"account": "ansible-vault"}, None)
if pw:
    print(pw)
else:
    raise SystemExit("Secret not found or DB locked")

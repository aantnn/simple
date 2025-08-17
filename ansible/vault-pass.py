#!/usr/bin/env python3
# secret-tool store --label='ansible-vault-dev' xdg:schema org.freedesktop.Secret.Generic account  ansible-vault-dev
# ansible-vault create  --vault-id dev@./vault-pass-dev.py dev-secret.yml
import os, sys, gi
gi.require_version('Secret', '1')
from gi.repository import Secret

# derive vault id from symlink name
vault_id = os.path.basename(sys.argv[0]).removeprefix("vault-pass-").removesuffix(".py")

schema = Secret.Schema.new(
    "org.freedesktop.Secret.Generic",
    Secret.SchemaFlags.NONE,
    {"account": Secret.SchemaAttributeType.STRING}
)
pw = Secret.password_lookup_sync(schema, {"account": f"ansible-vault-{vault_id}"}, None)
if not pw:
    sys.stderr.write(f"No secret for ansible vault '{vault_id}'\n")
    sys.exit(1)
print(pw)

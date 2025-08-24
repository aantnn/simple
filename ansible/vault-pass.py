#!/usr/bin/env python3
# secret-tool store --label='ansible-vault-dev' xdg:schema org.freedesktop.Secret.Generic account  ansible-vault-dev
# ansible-vault create  --vault-id dev@./vault-pass-dev.py dev-secret.yml
import os
import sys
import ctypes as ct

libsecret = ct.CDLL("libsecret-1.so.0")

SECRET_SCHEMA_NONE = 0
SECRET_SCHEMA_ATTRIBUTE_STRING = 0

class SecretSchemaAttribute(ct.Structure):
    _fields_ = [
        ("name", ct.c_char_p),
        ("type", ct.c_uint)
    ]

class SecretSchema(ct.Structure):
    _fields_ = [
        ("name", ct.c_char_p),
        ("flags", ct.c_uint),
        ("attributes", SecretSchemaAttribute * 32)
    ]

libsecret.secret_password_lookup_sync.argtypes = [
    ct.POINTER(SecretSchema),
    ct.c_void_p,
    ct.c_void_p
]
libsecret.secret_password_lookup_sync.restype = ct.c_char_p


schema = SecretSchema()
schema.name = b"org.freedesktop.Secret.Generic"
schema.flags = SECRET_SCHEMA_NONE
schema.attributes[0] = SecretSchemaAttribute(b"account", SECRET_SCHEMA_ATTRIBUTE_STRING)
schema.attributes[1] = SecretSchemaAttribute(None, 0)

vault_id = os.path.basename(sys.argv[0]).removeprefix("vault-pass-").removesuffix(".py")
account_value = f"ansible-vault-{vault_id}".encode()
err = ct.c_int()

pw_ptr = libsecret.secret_password_lookup_sync(
    ct.byref(schema),
    None,
    ct.byref(err),
    b"account", account_value,
    None
)

if not pw_ptr and err.value != 0:
    sys.stderr.write(f"No secret for ansible vault '{vault_id}'\n")
    sys.exit(1)

print(ct.string_at(pw_ptr).decode())

#!/usr/bin/env python3
"""
Retrieve an Ansible Vault password from the system keyring using libsecret.

Usage:
    secret-tool store --label='ansible-vault-dev' \
        xdg:schema org.freedesktop.Secret.Generic ansible-vault-attr ansible-vault-dev
"""

import os
import sys
import ctypes as ct
import ctypes.util


def main():
    vault_id = get_vault_id()
    account_id_attr_value = f"ansible-vault-{vault_id}".encode()
    schema = build_schema()
    password = lookup_password(schema, account_id_attr_value)
    print(password)

libsecret_path = ctypes.util.find_library("secret-1")
if not libsecret_path:
    raise OSError("libsecret not found — install libsecret or equivalent")
libsecret = ct.CDLL(libsecret_path)


SECRET_SCHEMA_NONE = 0
SECRET_SCHEMA_ATTRIBUTE_STRING = 0
ATTRIBUTE = b"ansible-vault-attr"


class SecretSchemaAttribute(ct.Structure):
    _fields_ = [
        ("name", ct.c_char_p),
        ("type", ct.c_uint),
    ]


class SecretSchema(ct.Structure):
    _fields_ = [
        ("name", ct.c_char_p),
        ("flags", ct.c_uint),
        ("attributes", SecretSchemaAttribute * 32),
    ]


libsecret.secret_password_lookup_sync.argtypes = [
    ct.POINTER(SecretSchema),  # schema
    ct.c_void_p,  # cancellable
    ct.c_void_p,  # error
]
libsecret.secret_password_lookup_sync.restype = ct.c_char_p


def build_schema() -> SecretSchema:
    schema = SecretSchema()
    schema.name = b"org.freedesktop.Secret.Generic"
    schema.flags = SECRET_SCHEMA_NONE
    schema.attributes[0] = SecretSchemaAttribute(
        ATTRIBUTE, SECRET_SCHEMA_ATTRIBUTE_STRING
    )
    schema.attributes[1] = SecretSchemaAttribute(None, 0)  # terminator
    return schema


def get_vault_id() -> str:
    return os.path.basename(sys.argv[0]).removeprefix("vault-pass-").removesuffix(".py")


def lookup_password(schema: SecretSchema, account: bytes) -> str:
    err = ct.c_int()
    pw_ptr = libsecret.secret_password_lookup_sync(
        ct.byref(schema), None, ct.byref(err), ATTRIBUTE, account, None
    )

    if not pw_ptr or err.value != 0:
        sys.stderr.write(f"No secret found for account '{account.decode()}'\n")
        sys.exit(1)

    return ct.string_at(pw_ptr).decode()


if __name__ == "__main__":
    main()

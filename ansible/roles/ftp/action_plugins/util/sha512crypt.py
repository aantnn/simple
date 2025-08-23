# SHA-512 Crypt Implementation in Python
# Only default 5000 rounds supported
# This implementation is compatible with the SHA-512 crypt algorithm used in Unix-like systems.
# It generates a hashed password using a given salt and number of rounds.
# From https://www.akkadia.org/drepper/SHA-crypt.txt (PUBLIC DOMAIN)
import hashlib
import base64
import secrets

# Custom base64 alphabet used by crypt(3)
CRYPT_B64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def b64_from_24bit(b2, b1, b0, n):
    v = (b2 << 16) | (b1 << 8) | b0
    return "".join(CRYPT_B64[(v >> (6 * i)) & 0x3F] for i in range(n))


def generate_salt(length=16):
    raw = secrets.token_bytes(length)
    b64 = base64.b64encode(raw).decode()
    return b64[:length]


def sha512_crypt(password: str, salt: str, rounds: int = 5000) -> str:
    pw = password.encode()
    sl = salt.encode()
    pw_len = len(pw)
    salt_len = len(sl)

    alt_result = hashlib.sha512(pw + sl + pw).digest()

    "For every byte of the password, append the bytes of alt_result to the hash input."
    ctx = pw + sl
    cnt = pw_len
    while cnt > 64:
        ctx += alt_result
        cnt -= 64
    ctx += alt_result[:cnt]

    """
    Take the binary representation of the length of the key and for every '1'
    add the alternate sum, for every '0' the key.
    """
    i = pw_len
    while i:
        if i & 1:
            ctx += alt_result
        else:
            ctx += pw
        i >>= 1

    alt_result = hashlib.sha512(ctx).digest()
    """
    For every character in the password add the entire password
        for (cnt = 0; cnt < key_len; ++cnt)
            sha512_process_bytes (key, key_len, &alt_ctx);
    """
    temp_result = hashlib.sha512(pw * pw_len).digest()
    """
    Create byte sequence P
        cp = p_bytes = alloca (key_len);
        for (cnt = key_len; cnt >= 64; cnt -= 64)
            cp = mempcpy (cp, temp_result, 64);
        memcpy (cp, temp_result, cnt);
    """
    P_bytes = (temp_result * (pw_len // 64)) + temp_result[: pw_len % 64]

    """
    For every character in the password add the entire password
        for (cnt = 0; cnt < 16 + alt_result[0]; ++cnt)
            sha512_process_bytes (salt, salt_len, &alt_ctx);
    """
    temp_result = hashlib.sha512(sl * (16 + alt_result[0])).digest()
    """
    Create byte sequence S
        cp = s_bytes = alloca (salt_len);
        for (cnt = salt_len; cnt >= 64; cnt -= 64)
            cp = mempcpy (cp, temp_result, 64);
        memcpy (cp, temp_result, cnt);
    """
    S_bytes = (temp_result * (salt_len // 64)) + temp_result[: salt_len % 64]

    """
    Repeatedly run the collected hash value through SHA512 to burn
    CPU cycles.
    for (cnt = 0; cnt < rounds; ++cnt)
    {
        sha512_init_ctx (&ctx);
        if ((cnt & 1) != 0)
            sha512_process_bytes (p_sequence, key_len, &ctx);
        else
            sha512_process_bytes (alt_result, 64, &ctx);
        if (cnt % 3 != 0)
            sha512_process_bytes (s_sequence, salt_len, &ctx);
        if (cnt % 7 != 0)
            sha512_process_bytes (p_sequence, key_len, &ctx);
        if ((cnt & 1) != 0)
            sha512_process_bytes (alt_result, 64, &ctx);
        else
            sha512_process_bytes (p_sequence, key_len, &ctx);
        sha512_finish_ctx (&ctx, alt_result);
    }
    """
    for i in range(rounds):
        ctx = b""
        if i & 1:
            ctx += P_bytes
        else:
            ctx += alt_result
        if i % 3:
            ctx += S_bytes
        if i % 7:
            ctx += P_bytes
        if i & 1:
            ctx += alt_result
        else:
            ctx += P_bytes
        alt_result = hashlib.sha512(ctx).digest()

    """
    Reorder bytes into the final result string per the crypt(3) base64
    mapping table.
    """
    rearranged = (
        b64_from_24bit(alt_result[0], alt_result[21], alt_result[42], 4)
        + b64_from_24bit(alt_result[22], alt_result[43], alt_result[1], 4)
        + b64_from_24bit(alt_result[44], alt_result[2], alt_result[23], 4)
        + b64_from_24bit(alt_result[3], alt_result[24], alt_result[45], 4)
        + b64_from_24bit(alt_result[25], alt_result[46], alt_result[4], 4)
        + b64_from_24bit(alt_result[47], alt_result[5], alt_result[26], 4)
        + b64_from_24bit(alt_result[6], alt_result[27], alt_result[48], 4)
        + b64_from_24bit(alt_result[28], alt_result[49], alt_result[7], 4)
        + b64_from_24bit(alt_result[50], alt_result[8], alt_result[29], 4)
        + b64_from_24bit(alt_result[9], alt_result[30], alt_result[51], 4)
        + b64_from_24bit(alt_result[31], alt_result[52], alt_result[10], 4)
        + b64_from_24bit(alt_result[53], alt_result[11], alt_result[32], 4)
        + b64_from_24bit(alt_result[12], alt_result[33], alt_result[54], 4)
        + b64_from_24bit(alt_result[34], alt_result[55], alt_result[13], 4)
        + b64_from_24bit(alt_result[56], alt_result[14], alt_result[35], 4)
        + b64_from_24bit(alt_result[15], alt_result[36], alt_result[57], 4)
        + b64_from_24bit(alt_result[37], alt_result[58], alt_result[16], 4)
        + b64_from_24bit(alt_result[59], alt_result[17], alt_result[38], 4)
        + b64_from_24bit(alt_result[18], alt_result[39], alt_result[60], 4)
        + b64_from_24bit(alt_result[40], alt_result[61], alt_result[19], 4)
        + b64_from_24bit(alt_result[62], alt_result[20], alt_result[41], 4)
        + b64_from_24bit(0, 0, alt_result[63], 2)
    )

    return f"$6${salt}${rearranged}"


""" if __name__ == "__main__":
    import subprocess
    salt = generate_salt()
    password = "mypassword"

    py_hash = sha512_crypt(password, salt)
    print(f"Salt: {salt}, Password: {password}")
    print(f"Python:  {py_hash}")

    result = subprocess.run(
        ["openssl", "passwd", "-6", "-salt", salt, password],
        capture_output=True,
        text=True,
        check=True
    )
    openssl_hash = result.stdout.strip()
    print(f"OpenSSL: {openssl_hash}")
    print("Match:", py_hash == openssl_hash)
"""

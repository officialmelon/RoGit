#!/usr/bin/env python3
"""
Independent check of roGit's SSH commit signatures (needs `pip install cryptography`).

    python3 tests/build.py tests/tools_test.lua && luau tests/_run.lua > out.txt
    python3 tests/verify_signature.py out.txt

Re-implements what git + ssh-keygen do for gpg.format=ssh: strip the gpgsig header to get the
signed payload, rebuild the SSHSIG "signed data" and check the ed25519 signature.
"""
import base64
import hashlib
import struct
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

text = open(sys.argv[1]).read()
commit = text.split("SIGNED_COMMIT_BEGIN\n", 1)[1].split("\nSIGNED_COMMIT_END", 1)[0]
public_line = text.split("PUBLIC_KEY ", 1)[1].split("\n", 1)[0].strip()

# payload = the commit without its gpgsig header (and its continuation lines)
headers, message = commit.split("\n\n", 1)
kept, signature = [], []
in_sig = False
for line in headers.split("\n"):
    if line.startswith("gpgsig "):
        in_sig = True
        signature.append(line[len("gpgsig "):])
    elif in_sig and line.startswith(" "):
        signature.append(line[1:])
    else:
        in_sig = False
        kept.append(line)
payload = ("\n".join(kept) + "\n\n" + message).encode()
armored = "\n".join(signature)


def read_string(data, pos):
    (length,) = struct.unpack(">I", data[pos:pos + 4])
    return data[pos + 4:pos + 4 + length], pos + 4 + length


def ssh_string(value):
    return struct.pack(">I", len(value)) + value


blob = base64.b64decode("".join(armored.strip().splitlines()[1:-1]))
assert blob[:6] == b"SSHSIG", "bad magic"
pos = 10
public_blob, pos = read_string(blob, pos)
namespace, pos = read_string(blob, pos)
reserved, pos = read_string(blob, pos)
hash_algorithm, pos = read_string(blob, pos)
signature_blob, pos = read_string(blob, pos)

key_type, kpos = read_string(public_blob, 0)
public_key, _ = read_string(public_blob, kpos)
_, spos = read_string(signature_blob, 0)
raw_signature, _ = read_string(signature_blob, spos)

assert key_type == b"ssh-ed25519" and namespace == b"git" and hash_algorithm == b"sha512"
assert public_line.split()[1] == base64.b64encode(public_blob).decode(), "signature made with another key"

signed_data = b"SSHSIG" + ssh_string(namespace) + ssh_string(reserved) + ssh_string(hash_algorithm) + ssh_string(hashlib.sha512(payload).digest())
Ed25519PublicKey.from_public_bytes(public_key).verify(raw_signature, signed_data)
print("signature OK:", public_line[:40] + "...")

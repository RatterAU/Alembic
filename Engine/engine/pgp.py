"""Minimal OpenPGP signature check for yt-dlp releases.

yt-dlp signs each release's SHA2-256SUMS / SHA2-512SUMS with its release key.
This verifies such a detached v4 RSA signature against the yt-dlp public key
shipped inside the app, whose fingerprint is pinned below. Only what that check
needs is implemented: RSA keys, v4 signatures, SHA-256/384/512 digests.
"""
from __future__ import annotations

import base64
import hashlib
import os

# yt-dlp release signing key (https://github.com/yt-dlp/yt-dlp/blob/master/public.key)
PINNED_FINGERPRINT = 'AC0CBBE6848D6A873464AF4E57CF65933B5A7581'
KEY_FILE = os.path.join(os.path.dirname(__file__), 'ytdlp-signing-key.asc')

_HASHES = {8: ('sha256', bytes.fromhex('3031300d060960864801650304020105000420')),
           9: ('sha384', bytes.fromhex('3041300d060960864801650304020205000430')),
           10: ('sha512', bytes.fromhex('3051300d060960864801650304020305000440'))}


class SignatureError(Exception):
    pass


def _dearmor(data: bytes) -> bytes:
    if not data.lstrip().startswith(b'-----BEGIN PGP'):
        return data
    lines = data.decode('ascii').strip().splitlines()
    body, started = [], False
    for line in lines[1:]:
        if not started:
            if line.strip() == '':
                started = True
            continue
        if line.startswith('=') or line.startswith('-----END'):
            break
        body.append(line.strip())
    return base64.b64decode(''.join(body))


def _packets(data: bytes):
    i = 0
    while i < len(data):
        ctb = data[i]
        if not ctb & 0x80:
            raise SignatureError('Malformed OpenPGP data')
        if ctb & 0x40:  # new format
            tag = ctb & 0x3F
            o = data[i + 1]
            if o < 192:
                length, hl = o, 2
            elif o < 224:
                length, hl = ((o - 192) << 8) + data[i + 2] + 192, 3
            elif o == 255:
                length, hl = int.from_bytes(data[i + 2:i + 6], 'big'), 6
            else:
                raise SignatureError('Partial-length packets are not supported')
        else:  # old format
            tag = (ctb >> 2) & 0x0F
            lt = ctb & 3
            n = {0: 1, 1: 2, 2: 4}.get(lt)
            if n is None:
                raise SignatureError('Indeterminate-length packets are not supported')
            length, hl = int.from_bytes(data[i + 1:i + 1 + n], 'big'), 1 + n
        yield tag, data[i + hl:i + hl + length]
        i += hl + length


def _mpi(buf: bytes, pos: int):
    bits = int.from_bytes(buf[pos:pos + 2], 'big')
    n = (bits + 7) // 8
    return int.from_bytes(buf[pos + 2:pos + 2 + n], 'big'), pos + 2 + n


def _load_key():
    with open(KEY_FILE, 'rb') as f:
        data = _dearmor(f.read())
    for tag, body in _packets(data):
        if tag == 6:  # primary public key
            if body[0] != 4 or body[5] not in (1, 3):
                raise SignatureError('Unsupported key type')
            fpr = hashlib.sha1(b'\x99' + len(body).to_bytes(2, 'big') + body).hexdigest().upper()
            if fpr != PINNED_FINGERPRINT:
                raise SignatureError('Bundled key does not match the pinned fingerprint')
            n, p = _mpi(body, 6)
            e, _ = _mpi(body, p)
            return n, e
    raise SignatureError('No public key found')


def verify(data: bytes, signature: bytes) -> None:
    """Raise SignatureError unless `signature` is yt-dlp's valid signature of `data`."""
    n, e = _load_key()
    sig = _dearmor(signature)
    for tag, body in _packets(sig):
        if tag != 2:
            continue
        if body[0] != 4:
            raise SignatureError('Only v4 signatures are supported')
        sig_type, pk_algo, hash_algo = body[1], body[2], body[3]
        if sig_type not in (0x00, 0x01) or pk_algo not in (1, 3) or hash_algo not in _HASHES:
            raise SignatureError('Unsupported signature type')
        hashed_len = int.from_bytes(body[4:6], 'big')
        hashed_end = 6 + hashed_len
        unhashed_len = int.from_bytes(body[hashed_end:hashed_end + 2], 'big')
        pos = hashed_end + 2 + unhashed_len
        left16 = body[pos:pos + 2]
        s, _ = _mpi(body, pos + 2)

        name, prefix = _HASHES[hash_algo]
        h = hashlib.new(name)
        h.update(data)
        h.update(body[:hashed_end])
        h.update(b'\x04\xff' + hashed_end.to_bytes(4, 'big'))
        digest = h.digest()
        if digest[:2] != left16:
            raise SignatureError('Signature does not match the data')

        k = (n.bit_length() + 7) // 8
        em = pow(s, e, n).to_bytes(k, 'big')
        t = prefix + digest
        expected = b'\x00\x01' + b'\xff' * (k - len(t) - 3) + b'\x00' + t
        if em != expected:
            raise SignatureError('Signature does not match the data')
        return
    raise SignatureError('No signature found')

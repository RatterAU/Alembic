#!/usr/bin/env bash
# Fetches everything the Python side needs, all verified:
#   - Python for iOS (BeeWare support package), pinned SHA-256
#   - yt-dlp release zip: checksum list must be signed by yt-dlp's release key
#     (checked with the same code the app uses), then the file must match it
#   - mutagen + certifi wheels, hash-pinned via pip --require-hashes
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"; OUT="$ROOT/build/engine"
PY_TAG=3.13-b18
PY_SHA=d06acf2a9c7964a8689566353a0e707402eff822037de5e29ba0e16040f7047d
YTDLP_VER=${YTDLP_VER:-2026.10.26}
mkdir -p "$VENDOR" "$OUT"

if [ ! -d "$VENDOR/python/Python.xcframework" ]; then
  f="$VENDOR/py.tar.gz"
  curl -fsSL -o "$f" "https://github.com/beeware/Python-Apple-support/releases/download/$PY_TAG/Python-${PY_TAG%%-*}-iOS-support.${PY_TAG##*-}.tar.gz"
  echo "$PY_SHA  $f" | shasum -a 256 -c - >/dev/null || { echo "CHECKSUM MISMATCH: Python"; exit 1; }
  mkdir -p "$VENDOR/python" && tar xzf "$f" -C "$VENDOR/python"
fi

base="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VER"
tmp=$(mktemp -d)
curl -fsSL -o "$tmp/SHA2-256SUMS" "$base/SHA2-256SUMS"
curl -fsSL -o "$tmp/SHA2-256SUMS.sig" "$base/SHA2-256SUMS.sig"
curl -fsSL -o "$tmp/yt-dlp" "$base/yt-dlp"
python3 -I - "$ROOT/Engine" "$tmp" <<'PY'
import hashlib, sys
sys.path.insert(0, sys.argv[1]); d = sys.argv[2]
from engine import pgp
sums = open(f'{d}/SHA2-256SUMS', 'rb').read()
pgp.verify(sums, open(f'{d}/SHA2-256SUMS.sig', 'rb').read())
want = next(l.split()[0] for l in sums.decode().splitlines() if l.split()[-1:] == ['yt-dlp'])
got = hashlib.sha256(open(f'{d}/yt-dlp', 'rb').read()).hexdigest()
assert got == want, 'yt-dlp checksum mismatch'
print('yt-dlp signature + checksum OK')
PY
cp "$tmp/yt-dlp" "$OUT/yt-dlp.zip"; rm -rf "$tmp"

rm -rf "$OUT/app_packages"
python3 -m pip install --quiet --require-hashes --no-deps --only-binary :all: \
  --target "$OUT/app_packages" -r "$ROOT/Engine/requirements.lock"
find "$OUT/app_packages" -name "__pycache__" -type d -prune -exec rm -rf {} +
rm -rf "$OUT/app_packages"/*.dist-info/RECORD "$OUT/app_packages/bin"
echo "Engine deps ready in $OUT"

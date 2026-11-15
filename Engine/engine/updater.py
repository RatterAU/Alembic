"""Keep yt-dlp current without a new app build.

The app ships the official `yt-dlp` zipimport release (pure Python, includes
the EJS solver scripts). Updates download a newer official release from GitHub
and are only used if:

1. the release's SHA2-256SUMS carries a valid signature from yt-dlp's release
   key, pinned in the app (see pgp.py);
2. the downloaded file matches that signed checksum;
3. the version inside the verified file (not the unsigned release tag) is newer
   than both the bundled copy and the update already installed.

Installing is a two-step transaction run by api.install_update: `stage()`
downloads and verifies, `commit()` switches to it, and if the new version fails
its smoke test `restore()` puts the previous one back. On every launch,
`activate()` re-checks the installed file's hash and ignores it if it is no
longer newer than the bundled copy (for example after installing a newer IPA).

The chosen zip is unpacked once into the cache folder (keyed by its version and
hash) and imported from there: Python can't cache compiled bytecode for code
inside a zip, so this makes every launch after the first one much faster.
"""
from __future__ import annotations

import hashlib
import importlib
import io
import json
import os
import re
import shutil
import ssl
import sys
import urllib.request
import zipfile

from . import pgp

REPOS = {
    'stable': 'yt-dlp/yt-dlp',
    'nightly': 'yt-dlp/yt-dlp-nightly-builds',
}
_support = ''
_bundled = ''
_cache = ''
_active_zip = ''   # the zip in use (bundled or downloaded)
_active_path = ''  # what is on sys.path: its unpacked folder, or the zip itself


def configure(support: str, bundled: str, cache: str | None = None) -> None:
    global _support, _bundled, _cache
    _support = support
    _bundled = bundled
    _cache = os.path.join(cache or support, 'ytdlp-unpacked')
    os.makedirs(_dir(), exist_ok=True)


def _dir() -> str:
    return os.path.join(_support, 'ytdlp')


def _pointer() -> str:
    return os.path.join(_dir(), 'active.json')


def _context():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def _get(url: str, timeout=30) -> bytes:
    req = urllib.request.Request(url, headers={'User-Agent': 'Alembic-iOS'})
    with urllib.request.urlopen(req, timeout=timeout, context=_context()) as r:
        return r.read()


# ----------------------------------------------------------------- versions --
def _vt(version: str) -> tuple:
    return tuple(int(x) for x in re.split(r'[.-]', version) if x.isdigit())


def version_in(source) -> str | None:
    """yt-dlp's version from a zip (path or bytes), or None if it isn't a yt-dlp build."""
    try:
        with zipfile.ZipFile(io.BytesIO(source) if isinstance(source, bytes) else source) as z:
            names = set(z.namelist())
            if 'yt_dlp/YoutubeDL.py' not in names or 'yt_dlp/version.py' not in names:
                return None
            src = z.read('yt_dlp/version.py').decode()
        m = re.search(r"^__version__ = '([0-9][0-9.]*)'$", src, re.M)
        return m.group(1) if m else None
    except Exception:
        return None


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def _read_pointer() -> dict | None:
    try:
        with open(_pointer()) as f:
            data = json.load(f)
        return data if isinstance(data, dict) and data.get('file') else None
    except (OSError, ValueError):
        return None


def _write_pointer(data: dict | None) -> None:
    if data is None:
        try:
            os.remove(_pointer())
        except OSError:
            pass
        return
    tmp = _pointer() + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f)
    os.replace(tmp, _pointer())


def _usable_update() -> tuple[str, str] | None:
    """(path, version) of the installed update, if it is intact and newer than the bundled copy."""
    data = _read_pointer()
    if not data:
        return None
    path = os.path.join(_dir(), os.path.basename(data['file']))
    try:
        if not data.get('sha256') or _sha256_file(path) != data['sha256']:
            return None
    except OSError:
        return None
    version = version_in(path)
    if not version or _vt(version) <= _vt(bundled_version()):
        return None
    return path, version


# --------------------------------------------------------------- activation --
def activate() -> str:
    """Put the chosen yt-dlp at the front of sys.path."""
    global _active_path, _active_zip
    update = _usable_update()
    if update is None and _read_pointer() is not None:
        # Tampered, missing, or no longer newer than the copy in the app: forget it.
        _write_pointer(None)
        _remove_zips(keep=None)
    if update:
        zip_path, key = update[0], f'{update[1]}-{_read_pointer()["sha256"][:16]}'
    else:
        zip_path = _bundled
        key = f'bundled-{bundled_version()}-{os.path.getsize(_bundled) if os.path.exists(_bundled) else 0}'
    path = _unpacked(zip_path, key) or zip_path
    for p in (_active_path, _active_zip, _bundled):
        while p and p in sys.path:
            sys.path.remove(p)
    sys.path.insert(0, path)
    sys.path_importer_cache.pop(path, None)
    _active_path, _active_zip = path, zip_path
    return path


def _unpacked(zip_path: str, key: str) -> str | None:
    """A folder with the zip's contents (made once), or None to import from the zip."""
    key = re.sub(r'[^A-Za-z0-9._-]', '_', key)
    dest = os.path.join(_cache, key)
    if os.path.exists(os.path.join(dest, '.complete')):
        return dest
    try:
        os.makedirs(_cache, exist_ok=True)
        tmp = dest + '.tmp'
        shutil.rmtree(tmp, ignore_errors=True)
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(tmp)  # zipfile drops absolute paths and '..' components
        open(os.path.join(tmp, '.complete'), 'w').close()
        shutil.rmtree(dest, ignore_errors=True)
        os.replace(tmp, dest)
    except Exception:
        return None
    for other in os.listdir(_cache):  # one unpacked copy at a time
        if other != key:
            shutil.rmtree(os.path.join(_cache, other), ignore_errors=True)
    return dest


def clear_cache() -> None:
    """Drop unpacked copies other than the one in use."""
    if os.path.isdir(_cache):
        for other in os.listdir(_cache):
            if os.path.join(_cache, other) != _active_path:
                shutil.rmtree(os.path.join(_cache, other), ignore_errors=True)


def bundled_version() -> str:
    return version_in(_bundled) or '0'


def active_source() -> str:
    return 'bundled' if _active_zip == _bundled else 'updated'


def _active_version() -> str:
    return version_in(_active_zip) or bundled_version()


def _remove_zips(keep: str | None) -> None:
    for other in os.listdir(_dir()):
        if other.endswith(('.zip', '.part')) and other != keep:
            try:
                os.remove(os.path.join(_dir(), other))
            except OSError:
                pass


# ------------------------------------------------------------------ updates --
def _latest_release(channel: str) -> dict:
    repo = REPOS.get(channel, REPOS['stable'])
    return json.loads(_get(f'https://api.github.com/repos/{repo}/releases/latest', timeout=15))


def check(channel: str = 'stable') -> dict:
    rel = _latest_release(channel)
    latest = str(rel.get('tag_name') or '')
    current = _active_version()
    return {
        'channel': channel,
        'current': current,
        'latest': latest,
        # The tag is only a hint here; stage() decides from the signed file itself.
        'available': bool(_vt(latest)) and _vt(latest) > _vt(current),
        'notes_url': rel.get('html_url'),
    }


def stage(channel: str = 'stable') -> dict:
    """Download and verify the latest release. Nothing is switched yet."""
    rel = _latest_release(channel)
    assets = {a.get('name'): a.get('browser_download_url') for a in rel.get('assets') or []}
    for needed in ('yt-dlp', 'SHA2-256SUMS', 'SHA2-256SUMS.sig'):
        if not assets.get(needed):
            raise RuntimeError(f'That release is missing {needed}; not installing it')
    # Only fetch from GitHub's release download host.
    for name in ('yt-dlp', 'SHA2-256SUMS', 'SHA2-256SUMS.sig'):
        if not assets[name].startswith('https://github.com/'):
            raise RuntimeError('Unexpected download location; not installing it')

    # 1. The checksum list must be signed by yt-dlp's release key (pinned in the app).
    sums = _get(assets['SHA2-256SUMS'])
    sig = _get(assets['SHA2-256SUMS.sig'])
    try:
        pgp.verify(sums, sig)
    except pgp.SignatureError as e:
        raise RuntimeError(f'Update rejected: the release signature is not valid ({e})') from e
    # 2. The file must match the signed checksum.
    want = next((line.split()[0] for line in sums.decode('utf-8', 'replace').splitlines()
                 if line.split()[-1:] == ['yt-dlp']), None)
    if not want:
        raise RuntimeError('Update rejected: no checksum for the yt-dlp file')
    data = _get(assets['yt-dlp'], timeout=180)
    sha = hashlib.sha256(data).hexdigest()
    if sha != want:
        raise RuntimeError('Update rejected: the download does not match its signed checksum')
    # 3. Judge the version from inside the verified file, never from the release tag.
    version = version_in(data)
    if not version:
        raise RuntimeError('Downloaded file is not a valid yt-dlp build')
    if _vt(version) <= _vt(bundled_version()):
        raise RuntimeError(f'{version} is not newer than the version built into the app')
    if _vt(version) <= _vt(_active_version()):
        raise RuntimeError(f'You already have yt-dlp {_active_version()}')

    name = f'yt-dlp-{version}.zip'
    path = os.path.join(_dir(), name)
    tmp = path + '.part'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, path)
    return {'file': name, 'channel': channel, 'version': version, 'sha256': sha}


def snapshot() -> dict | None:
    """The current pointer, so a failed update can be undone."""
    return _read_pointer()


def commit(staged: dict) -> None:
    _write_pointer(staged)
    activate()


def restore(previous: dict | None, staged: dict | None = None) -> None:
    _write_pointer(previous)
    if staged and (not previous or previous.get('file') != staged['file']):
        try:
            os.remove(os.path.join(_dir(), staged['file']))
        except OSError:
            pass
    activate()


def finish(staged: dict) -> None:
    """The new version passed its smoke test: drop older downloaded copies."""
    _remove_zips(keep=staged['file'])


def reset() -> None:
    _write_pointer(None)
    _remove_zips(keep=None)
    activate()


def reload_modules() -> None:
    """Forget the loaded yt-dlp so the next import uses the newly active zip."""
    for name in list(sys.modules):
        if name == 'yt_dlp' or name.startswith(('yt_dlp.', 'yt_dlp_ejs', 'yt_dlp_plugins')):
            del sys.modules[name]
    import zipimport
    zipimport._zip_directory_cache.clear()
    importlib.invalidate_caches()

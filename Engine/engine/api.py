"""Alembic's Python engine: everything the app asks of yt-dlp goes through here.

The app calls `handle(json_string) -> json_string` from a background thread.
Long work (downloads) runs on Python threads and reports back with
`bridge.emit(json)` events:

  {"type": "job", "id", "status", "progress", "step_progress", "downloaded",
   "total", "speed", "eta", "phase", "title", "files", "error", "warning"}
  {"type": "log", "id", "level", "line"}

Look-ups and downloads hold a shared "busy" gate; installing a yt-dlp update
holds it exclusively, so modules are never swapped under running work.
"""
from __future__ import annotations

import copy
import ctypes
import json
import math
import os
import re
import shlex
import shutil
import sys
import threading
import time
import traceback
import urllib.parse

from . import bridge, procs, updater

STATE: dict = {
    'ready': False,
    'docs': None,      # where finished files go (visible in the Files app)
    'support': None,   # app-private storage (yt-dlp updates, cache)
    'temp': None,      # partial downloads, one folder per job (kept on failure so Retry resumes)
    'ffmpeg_version': None,
    'jsc_error': None,
}
_jobs: dict[str, 'Job'] = {}
_info_cache: dict[str, tuple[float, dict]] = {}
_INFO_TTL = 20 * 60
_INFO_MAX = 6
_ANSI = re.compile(r'\x1b\[[0-9;]*m')

MEDIA_EXTS = {'mp4', 'm4v', 'mov', 'mkv', 'webm', 'm4a', 'mp3', 'opus', 'ogg', 'oga', 'flac',
              'wav', 'aac', 'mka'}


# ---------------------------------------------------------------- plumbing --
def handle(request: str) -> str:
    try:
        req = json.loads(request)
        fn = _COMMANDS[req['cmd']]
        result = fn(req.get('args') or {})
        return json.dumps({'ok': True, 'result': _finite(result)}, default=str, allow_nan=False)
    except Exception as e:
        return json.dumps({'ok': False, 'error': _clean_error(e),
                           'trace': traceback.format_exc(limit=8)})


def _finite(obj):
    """JSON can't carry NaN/Infinity; one bad number must not break a whole reply."""
    if isinstance(obj, float):
        return obj if math.isfinite(obj) else None
    if isinstance(obj, dict):
        return {k: _finite(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_finite(v) for v in obj]
    return obj


_FLAG_HINTS = (
    # yt-dlp's advice mentions options Alembic doesn't have; say what it means here.
    (re.compile(r'Use --cookies-from-browser or --cookies[^.]*\.?', re.I),
     'This needs a signed-in account, which Alembic doesn\'t use.'),
    (re.compile(r'\s*See\s+https://github\.com/yt-dlp/yt-dlp/wiki/FAQ#[^\s]+[^.]*\.?', re.I), ''),
    (re.compile(r'\s*Confirm you are on the latest version using\s+yt-dlp -U\.?', re.I),
     ' Check for a yt-dlp update in Settings.'),
)


def _clean_error(e: BaseException | str) -> str:
    msg = str(e) or e.__class__.__name__
    msg = _ANSI.sub('', msg)
    msg = re.sub(r'^(ERROR:\s*)+', '', msg).strip()
    for pattern, replacement in _FLAG_HINTS:
        msg = pattern.sub(replacement, msg)
    return msg.strip()


def _emit(obj: dict) -> None:
    bridge.emit(json.dumps(_finite(obj), default=str, allow_nan=False))


class _Logger:
    """yt-dlp logger that forwards lines to the app's per-job log."""

    def __init__(self, job_id: str | None):
        self.job_id = job_id
        self.lines: list[str] = []

    def _send(self, level, msg):
        msg = _ANSI.sub('', str(msg))
        self.lines.append(msg)
        del self.lines[:-400]
        if self.job_id:
            _emit({'type': 'log', 'id': self.job_id, 'level': level, 'line': msg})

    def debug(self, msg):
        # yt-dlp sends normal info lines through debug() too; they start with '[...]'
        if not msg.startswith('[debug] '):
            self._send('info', msg)

    def info(self, msg):
        self._send('info', msg)

    def warning(self, msg):
        self._send('warning', msg)

    def error(self, msg):
        self._send('error', msg)


class _Discard:
    """Python's own stdout/stderr on iOS. While FFmpeg runs, fds 1 and 2 belong to
    its pipes, so nothing else may write there (see App/Engine/ToolRunner.c)."""

    def write(self, s):
        return len(s)

    def flush(self):
        pass

    def isatty(self):
        return False


# ------------------------------------------------------------- busy gate --
_gate = threading.Condition()
_gate_users = 0
_gate_updating = False


def _enter_shared(timeout: float = 120) -> None:
    global _gate_users
    with _gate:
        if not _gate.wait_for(lambda: not _gate_updating, timeout=timeout):
            raise RuntimeError('yt-dlp is still updating. Try again in a moment.')
        _gate_users += 1


def _leave_shared() -> None:
    global _gate_users
    with _gate:
        _gate_users -= 1
        _gate.notify_all()


class _Exclusive:
    def __enter__(self):
        global _gate_updating
        with _gate:
            if _gate_updating:
                raise RuntimeError('yt-dlp is already updating')
            if _gate_users:
                raise RuntimeError('Wait for downloads and look-ups to finish, then update')
            _gate_updating = True

    def __exit__(self, *exc):
        global _gate_updating
        with _gate:
            _gate_updating = False
            _gate.notify_all()


# ------------------------------------------------------------------ setup --
def init(args: dict) -> dict:
    os.environ['YTDLP_NO_PLUGINS'] = '1'  # never load code from outside the app
    if bridge.IS_IOS:
        sys.stdout = sys.stderr = _Discard()
    STATE['docs'] = args['docs']
    STATE['support'] = args['support']
    STATE['temp'] = args['temp']
    for d in (STATE['docs'], STATE['support']):
        os.makedirs(d, exist_ok=True)
    # Nothing is downloading at launch: partial files from a killed app are leftovers.
    shutil.rmtree(STATE['temp'], ignore_errors=True)
    os.makedirs(STATE['temp'], exist_ok=True)

    updater.configure(STATE['support'], args['bundled_ytdlp'], args.get('cache'))
    updater.activate()
    procs.install(log_sink=_tool_log, status_sink=_tool_status)
    notes = []
    try:
        _load_ytdlp(strict=False)
    except Exception as e:
        if updater.active_source() != 'updated':
            raise
        updater.reset()
        updater.reload_modules()
        _load_ytdlp(strict=False)
        notes.append(f'The downloaded yt-dlp update would not load ({_clean_error(e)}), '
                     'so Alembic went back to the version built into the app.')
    STATE['ready'] = True
    return {**versions({}), 'notes': notes}


def _load_ytdlp(strict: bool) -> None:
    import yt_dlp  # noqa: F401  (path chosen by updater.activate)
    from . import jsc
    STATE['jsc_error'] = None
    try:
        jsc.register()
    except Exception as e:
        if strict:
            raise RuntimeError(f'its YouTube solver hook failed ({e})') from e
        STATE['jsc_error'] = _clean_error(e)
    if strict:
        # The calls every look-up and download make, without touching the network.
        with _ydl(['--no-playlist'], _Logger(None)) as ydl:
            ydl.get_info_extractor('Youtube')
            ydl.get_info_extractor('Generic')


def versions(_args) -> dict:
    import yt_dlp.version as v
    return {
        'ytdlp': v.__version__,
        'ytdlp_channel': getattr(v, 'CHANNEL', 'stable'),
        'ytdlp_source': updater.active_source(),
        'ytdlp_bundled': updater.bundled_version(),
        'ffmpeg': STATE['ffmpeg_version'],
        'python': sys.version.split()[0],
        'youtube_solver': STATE['jsc_error'] is None,
        'youtube_solver_error': STATE['jsc_error'],
    }


def ffmpeg_version(_args) -> dict:
    """Asked for lazily (Settings), so launch never has to load FFmpeg."""
    if STATE['ffmpeg_version'] is None:
        _enter_shared()
        try:
            from yt_dlp.postprocessor.ffmpeg import FFmpegPostProcessor
            STATE['ffmpeg_version'] = FFmpegPostProcessor.get_versions().get('ffmpeg')
        except Exception:
            pass
        finally:
            _leave_shared()
    return {'ffmpeg': STATE['ffmpeg_version']}


def _ca_file() -> str | None:
    try:
        import certifi
        return certifi.where()
    except ImportError:
        return None


def _base_args() -> list[str]:
    ca = _ca_file()
    # FFmpeg checks HTTPS certificates (clips and live streams are downloaded by it)
    # and has no system list on iOS: hand it certifi's, pinned in requirements.lock.
    ff = ['--downloader-args', f'ffmpeg_i:-ca_file {shlex.quote(ca)}'] if ca else []
    return [
        *ff,
        '--no-js-runtimes',          # YouTube challenges go through WebKitJCP
        '--no-color',
        '--no-mtime',                # files show when you downloaded them
        '--socket-timeout', '20',
        '--concurrent-fragments', '4',
        '--retries', '5', '--fragment-retries', '10',
        '--cache-dir', os.path.join(STATE['support'], 'cache'),
    ]


def _ydl(cli_args: list[str], logger: _Logger, extra: dict | None = None):
    import yt_dlp
    opts = yt_dlp.parse_options([*_base_args(), *cli_args]).ydl_opts
    opts['logger'] = logger
    opts['noprogress'] = True
    if extra:
        opts.update(extra)
    return yt_dlp.YoutubeDL(opts)


def _check_url(url) -> str:
    url = str(url or '').strip()
    if not re.match(r'^https?://[^\s/]+', url, re.I):
        raise RuntimeError('That isn\'t a web link')
    return url


# ------------------------------------------------------------------ probe --
_TEXT_KEYS = ('format_id', 'format_note', 'ext', 'protocol', 'vcodec', 'acodec', 'dynamic_range',
              'language', 'container', 'resolution')
_INT_KEYS = ('width', 'height', 'audio_channels')
_NUM_KEYS = ('fps', 'tbr', 'vbr', 'abr', 'asr', 'filesize', 'filesize_approx')
_probes: dict[str, int] = {}  # probe id -> thread ident
_probes_lock = threading.Lock()


class _ProbeCancelled(BaseException):
    """Raised inside a look-up's thread to stop it (BaseException: yt-dlp won't swallow it)."""


def _num(v, as_int=False):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(f):
        return None
    return int(f) if as_int else f


def probe(args: dict) -> dict:
    url = _check_url(args.get('url'))
    probe_id = str(args.get('probe_id') or '')
    want_list = bool(args.get('playlist'))
    logger = _Logger(None)
    _enter_shared()
    with _probes_lock:
        if probe_id:
            _probes[probe_id] = threading.get_ident()
    try:
        # --flat-playlist: a channel or album is listed, never fully extracted.
        cli = ['--flat-playlist', '--yes-playlist' if want_list else '--no-playlist']
        with _ydl(cli, logger) as ydl:
            info = ydl.extract_info(url, download=False)
    except _ProbeCancelled:
        raise RuntimeError('Cancelled') from None
    finally:
        with _probes_lock:
            _probes.pop(probe_id, None)
        _leave_shared()
    if info is None:
        raise RuntimeError(_last_error(logger) or 'Nothing found at that link')
    return _describe(info, url)


def cancel_probe(args: dict) -> dict:
    with _probes_lock:
        ident = _probes.pop(str(args.get('probe_id') or ''), None)
    if ident is None:
        return {'cancelled': False}
    try:
        ctypes.pythonapi.PyThreadState_SetAsyncExc(ctypes.c_ulong(ident), ctypes.py_object(_ProbeCancelled))
    except Exception:
        return {'cancelled': False}
    return {'cancelled': True}


def _describe(info: dict, url: str) -> dict:
    if info.get('_type') == 'playlist' or 'entries' in info:
        entries = []
        for i, e in enumerate(info.get('entries') or [], 1):
            if not e or not (e.get('url') or e.get('webpage_url')):
                continue
            entries.append({
                'index': i,
                'id': e.get('id'),
                'title': e.get('title') or e.get('id'),
                'url': e.get('url') or e.get('webpage_url'),
                'duration': _num(e.get('duration')),
                'thumbnail': _best_thumb(e),
                'uploader': e.get('uploader') or e.get('channel'),
            })
        return {
            'kind': 'playlist',
            'id': info.get('id'),
            'title': info.get('title') or 'Playlist',
            'uploader': info.get('uploader') or info.get('channel'),
            'webpage_url': info.get('webpage_url') or url,
            'extractor': info.get('extractor_key'),
            'thumbnail': _best_thumb(info) or next((x['thumbnail'] for x in entries if x['thumbnail']), None),
            'entries': entries,
        }

    _cache_put(url, info)
    formats = []
    for f in info.get('formats') or []:
        if str(f.get('format_id', '')).startswith('sb') or f.get('vcodec') == 'images':
            continue  # storyboards
        if f.get('protocol') in ('mhtml',):
            continue
        row = {k: str(f[k]) for k in _TEXT_KEYS if f.get(k) is not None}
        row.update({k: n for k in _INT_KEYS if (n := _num(f.get(k), as_int=True)) is not None})
        row.update({k: n for k in _NUM_KEYS if (n := _num(f.get(k))) is not None})
        if 'format_id' in row:
            formats.append(row)
    query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    subs = info.get('subtitles') or {}
    autos = info.get('automatic_captions') or {}
    return {
        'kind': 'video',
        'id': info.get('id'),
        'title': info.get('title'),
        'uploader': info.get('uploader') or info.get('channel') or info.get('uploader_id'),
        'duration': _num(info.get('duration')),
        'thumbnail': _best_thumb(info),
        'webpage_url': info.get('webpage_url') or url,
        'extractor': info.get('extractor_key'),
        'is_live': bool(info.get('is_live')),
        'upload_date': info.get('upload_date'),
        'view_count': _num(info.get('view_count'), as_int=True),
        'chapters': [{'title': c.get('title'), 'start': _num(c.get('start_time')), 'end': _num(c.get('end_time'))}
                     for c in info.get('chapters') or []],
        'subtitles': sorted(k for k in subs if k != 'live_chat'),
        'auto_subtitles': sorted(k for k in autos if not k.endswith('-orig')),
        'original_language': next((k[:-5] for k in autos if k.endswith('-orig')), None),
        'formats': formats,
        # A video opened from inside a playlist: offer the whole list too.
        'in_playlist': bool(query.get('list')) and '/playlist' not in url,
    }


def _cache_put(url: str, info: dict) -> None:
    now = time.time()
    for key in [k for k, (t, _) in _info_cache.items() if now - t > _INFO_TTL]:
        _info_cache.pop(key, None)
    for key in (url, info.get('webpage_url')):
        if key:
            _info_cache[key] = (now, info)
    while len(_info_cache) > _INFO_MAX:
        _info_cache.pop(min(_info_cache, key=lambda k: _info_cache[k][0]))


def _best_thumb(info: dict) -> str | None:
    thumbs = [t for t in info.get('thumbnails') or [] if t.get('url')]
    if thumbs:
        # yt-dlp sorts worst -> best; prefer a jpg around phone size
        jpgs = [t for t in thumbs if '.jpg' in t['url'] and (_num(t.get('width')) or 0) <= 1280]
        return (jpgs or thumbs)[-1]['url']
    return info.get('thumbnail')


# ------------------------------------------------------------------- jobs --
class Cancelled(Exception):
    pass


_TIME_RE = re.compile(r'\btime=\s*(-?\d+):(\d\d):(\d\d(?:\.\d+)?)')

_PP_NAMES = {
    'Merger': 'Merging video and audio',
    'FFmpegMerger': 'Merging video and audio',
    'ExtractAudio': 'Converting audio',
    'FFmpegExtractAudio': 'Converting audio',
    'VideoRemuxer': 'Changing container',
    'FFmpegVideoRemuxer': 'Changing container',
    'VideoConvertor': 'Converting video',
    'FFmpegVideoConvertor': 'Converting video',
    'EmbedThumbnail': 'Embedding cover art',
    'Metadata': 'Writing metadata',
    'FFmpegMetadata': 'Writing metadata',
    'EmbedSubtitle': 'Embedding subtitles',
    'FFmpegEmbedSubtitle': 'Embedding subtitles',
    'SubtitlesConvertor': 'Converting subtitles',
    'FFmpegSubtitlesConvertor': 'Converting subtitles',
    'SponsorBlock': 'Finding sponsor segments',
    'ModifyChapters': 'Cutting out segments',
    'ThumbnailsConvertor': 'Converting cover art',
    'FFmpegThumbnailsConvertor': 'Converting cover art',
    'FixupM3u8': 'Tidying the file',
    'FFmpegFixupM3u8': 'Tidying the file',
    'FixupM4a': 'Tidying the file',
    'FFmpegFixupM4a': 'Tidying the file',
    'FixupStretched': 'Tidying the file',
    'FixupTimestamp': 'Tidying the file',
    'FixupDuplicateMoov': 'Tidying the file',
    'FFmpegCopyStream': 'Tidying the file',
}


class Job:
    def __init__(self, job_id: str, args: dict):
        self.id = job_id
        self.args = args
        self.cancelled = False
        self.thread: threading.Thread | None = None
        self.files: list[str] = []
        self.title = args.get('title')
        self.status = 'queued'
        self.phase = 'Waiting'
        self.pp_name: str | None = None
        self.media_duration: float | None = None
        self.section_len: float | None = None
        self._stream_index = 0
        self._stream_count = 1
        self._stream_sizes: list[float] = []
        self._last_emit = 0.0
        self._last_progress = 0.0
        self._last_tool_emit = 0.0
        self._ffmpeg_download = False

    # ---- events
    def send(self, **kw):
        if 'phase' in kw:
            self.phase = kw['phase']
        payload = {'type': 'job', 'id': self.id, 'status': self.status, 'title': self.title}
        payload.update(kw)
        _emit(payload)

    # ---- yt-dlp hooks
    def progress_hook(self, d: dict):
        if self.cancelled:
            import yt_dlp.utils
            raise yt_dlp.utils.DownloadCancelled('Cancelled')
        info = d.get('info_dict') or {}
        if info.get('title'):
            self.title = info['title']
        if d['status'] == 'downloading':
            now = time.monotonic()
            total = _num(d.get('total_bytes') or d.get('total_bytes_estimate'))
            done = _num(d.get('downloaded_bytes')) or 0
            frac = (done / total) if total else None
            if frac is None and d.get('fragment_count'):
                frac = (_num(d.get('fragment_index')) or 0) / d['fragment_count']
            overall = self._overall(frac or 0.0)
            if now - self._last_emit < 0.25 and overall - self._last_progress < 0.02:
                return
            self._last_emit = now
            self._last_progress = overall
            self.status = 'downloading'
            self.send(progress=overall, downloaded=done, total=total, speed=_num(d.get('speed')),
                      eta=_num(d.get('eta')), phase=self._phase(info))
        elif d['status'] == 'finished':
            self._stream_index += 1
            self.send(progress=self._overall(0.0), phase='Finishing stream')

    def _phase(self, info: dict) -> str:
        if self._stream_count <= 1:
            return 'Downloading'
        v = info.get('vcodec')
        kind = 'audio' if (not v or v == 'none') else 'video'
        n = min(self._stream_index + 1, self._stream_count)
        return f'Downloading {kind} ({n} of {self._stream_count})'

    def _overall(self, frac: float) -> float:
        sizes = self._stream_sizes or [1.0] * self._stream_count
        total = sum(sizes) or 1.0
        before = sum(sizes[:self._stream_index])
        cur = sizes[self._stream_index] if self._stream_index < len(sizes) else 0
        return max(0.0, min(0.99, (before + cur * frac) / total))

    def pp_hook(self, d: dict):
        if self.cancelled:
            raise Cancelled()
        if d['status'] == 'started':
            pp = d.get('postprocessor') or ''
            if pp in ('MoveFiles', 'MoveFilesAfterDownload'):
                return
            self.pp_name = pp
            self.status = 'processing'
            self.send(progress=self._last_progress, step_progress=None,
                      phase=_PP_NAMES.get(pp, f'Processing ({pp})'))

    def post_hook(self, filename: str):
        self.files.append(filename)

    def match_filter(self, info, *, incomplete=False):
        # Called before each item downloads: learn how many streams are coming so
        # the progress bar can cover video + audio as one, and the clip length.
        req = info.get('requested_formats')
        if req:
            self._stream_count = len(req)
            self._stream_sizes = [_num(f.get('filesize') or f.get('filesize_approx')) or 0.0 for f in req]
            if not all(self._stream_sizes):
                self._stream_sizes = []
        else:
            self._stream_count = 1
            self._stream_sizes = []
        self._stream_index = 0
        self.media_duration = _num(info.get('duration'))
        sec = self.args.get('section') or {}
        if sec:
            start = _num(sec.get('start')) or 0.0
            end = _num(sec.get('end'))
            end = end if end is not None else self.media_duration
            self.section_len = (end - start) if end is not None and end > start else None
            # Clips are cut by FFmpeg while downloading; its own stats drive the bar.
            self._ffmpeg_download = True
        return None

    # ---- FFmpeg output (log lines and live stats)
    def tool_line(self, line: str):
        m = _TIME_RE.search(line)
        if not m:
            return
        h, mi, s = m.groups()
        t = max(0.0, int(h) * 3600 + int(mi) * 60 + float(s))
        now = time.monotonic()
        if now - self._last_tool_emit < 0.4:
            return
        self._last_tool_emit = now
        if self.status == 'processing':
            length = self.section_len or self.media_duration
            if length:
                self.send(step_progress=min(1.0, t / length))
        elif self._ffmpeg_download and self.section_len:
            frac = min(1.0, t / self.section_len)
            self.status = 'downloading'
            self._last_progress = min(0.99, frac)
            self.send(progress=self._last_progress, phase='Downloading clip')

    def tool_waiting(self, waiting: bool):
        if waiting:
            self._phase_before_wait = self.phase
            self.send(phase='Waiting for FFmpeg (another download is using it)')
        else:
            self.send(phase=getattr(self, '_phase_before_wait', self.phase))

    # ---- run
    def run(self):
        threading.current_thread().alembic_job = self
        logger = _Logger(self.id)
        a = self.args
        keep_temp = False
        try:
            self.status = 'starting'
            self.send(progress=0.0, phase='Starting')
            cli = build_cli(a)
            with _ydl(cli, logger, extra={
                'progress_hooks': [self.progress_hook],
                'postprocessor_hooks': [self.pp_hook],
                'post_hooks': [self.post_hook],
                'ignoreerrors': False,   # every failure raises, so it can be handled below
                'continuedl': True,      # Retry resumes the .part files kept from last time
            }) as ydl:
                _install_match_hook(ydl, self.match_filter)
                url = a['url']
                cached = None if a.get('fresh') else _info_cache.get(url)
                done = False
                if cached and time.time() - cached[0] < _INFO_TTL:
                    try:
                        ydl.process_ie_result(copy.deepcopy(cached[1]), download=True)
                        done = True
                    except BaseException as e:
                        if self.cancelled or _is_cancel(e) or _pp_error(e):
                            raise
                        # Stream links are tied to time and network; get fresh ones.
                        _info_cache.pop(url, None)
                        logger.warning(f'Saved stream links failed ({_clean_error(e)}); fetching again')
                        self.files.clear()
                        self._last_progress = 0.0
                if not done:
                    ydl.extract_info(url, download=True)
            if self.cancelled:
                raise Cancelled()
            files = [f for f in dict.fromkeys(self.files) if os.path.exists(f)]
            if not files:
                raise RuntimeError(_last_error(logger) or 'Download finished but no file was produced')
            self.status = 'finished'
            self.send(progress=1.0, phase='Done', files=files, duration=self.section_len or self.media_duration,
                      sizes=[os.path.getsize(f) for f in files])
        except BaseException as e:  # noqa: BLE001 - report everything to the UI
            if self.cancelled or _is_cancel(e):
                self.status = 'cancelled'
                self.send(phase='Cancelled')
            elif _pp_error(e) and (saved := self._rescue()):
                step = _PP_NAMES.get(self.pp_name or '', 'processing').lower()
                note = (f'Saved, but {step} failed: {_last_error(logger) or _clean_error(e)}'
                        if len(saved) == 1 or self.pp_name not in ('Merger', 'FFmpegMerger')
                        else 'Merging failed, so the video and audio were saved as separate files.')
                self.status = 'finished'
                self.send(progress=1.0, phase='Done', files=saved, duration=self.section_len or self.media_duration,
                          sizes=[os.path.getsize(f) for f in saved], warning=note)
            else:
                keep_temp = True
                self.status = 'error'
                self.send(phase='Failed', error=_last_error(logger) or _clean_error(e))
        finally:
            if not keep_temp:
                _cleanup_temp(self.id)
            _jobs.pop(self.id, None)
            _leave_shared()

    def _rescue(self) -> list[str]:
        """After a postprocessing failure, move the finished media out of the temp folder."""
        saved = [f for f in dict.fromkeys(self.files) if os.path.exists(f)]
        temp = os.path.join(STATE['temp'], self.id)
        found = []
        for root, _dirs, names in os.walk(temp):
            for name in names:
                ext = name.rsplit('.', 1)[-1].lower() if '.' in name else ''
                path = os.path.join(root, name)
                if ext in MEDIA_EXTS and '.temp.' not in name and os.path.getsize(path) > 0:
                    found.append(path)
        for path in found:
            dest = _unique(os.path.join(STATE['docs'], os.path.basename(path)))
            try:
                shutil.move(path, dest)
                saved.append(dest)
            except OSError:
                pass
        return saved


def _unique(path: str) -> str:
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    n = 2
    while os.path.exists(f'{base} ({n}){ext}'):
        n += 1
    return f'{base} ({n}){ext}'


def _tool_log(owner, line):
    job = getattr(owner, 'alembic_job', None)
    if job is not None and line:
        _emit({'type': 'log', 'id': job.id, 'level': 'tool', 'line': line})
        job.tool_line(line)


def _tool_status(owner, state):
    job = getattr(owner, 'alembic_job', None)
    if job is not None:
        job.tool_waiting(state == 'waiting')


def _install_match_hook(ydl, fn):
    # Run our hook alongside any existing match_filter, right before download.
    existing = ydl.params.get('match_filter')

    def combined(info, *, incomplete=False):
        if existing:
            r = existing(info, incomplete=incomplete) if _accepts_incomplete(existing) else existing(info)
            if r:
                return r
        return fn(info, incomplete=incomplete)
    ydl.params['match_filter'] = combined


def _accepts_incomplete(f):
    import inspect
    try:
        return 'incomplete' in inspect.signature(f).parameters
    except (TypeError, ValueError):
        return False


def _cause(e: BaseException) -> BaseException | None:
    exc_info = getattr(e, 'exc_info', None)
    return exc_info[1] if exc_info and len(exc_info) > 1 else None


def _is_cancel(e: BaseException) -> bool:
    if isinstance(e, Cancelled):
        return True
    try:
        import yt_dlp.utils
        cancel_types = (Cancelled, yt_dlp.utils.DownloadCancelled)
        return isinstance(e, cancel_types) or isinstance(_cause(e), cancel_types)
    except Exception:
        return False


def _pp_error(e: BaseException) -> bool:
    try:
        import yt_dlp.utils
        t = yt_dlp.utils.PostProcessingError
        return isinstance(e, t) or isinstance(_cause(e), t)
    except Exception:
        return False


def _last_error(logger: _Logger) -> str | None:
    for line in reversed(logger.lines):
        if line.startswith('ERROR:'):
            return _clean_error(line)
    return None


def _cleanup_temp(job_id: str):
    shutil.rmtree(os.path.join(STATE['temp'], job_id), ignore_errors=True)


def build_cli(a: dict) -> list[str]:
    """Turn the app's download options into yt-dlp command-line arguments.

    The link itself is never put on the command line (it goes straight to
    extract_info), so nothing in it can be read as an option.
    """
    cli = ['-P', STATE['docs'], '-P', f'temp:{os.path.join(STATE["temp"], a["id"])}']
    mode = a.get('mode', 'video')
    sec = a.get('section') or {}
    clip = ''
    if sec.get('start') is not None or sec.get('end') is not None:
        end = _short(sec['end']) if sec.get('end') is not None else 'end'
        clip = f" (clip {_short(sec.get('start') or 0)}-{end})".replace('%', '%%')
    # Quality in the name, so 1080p and 720p of the same video don't replace each other.
    quality = '%(height& {}p|)s' if mode == 'video' else ''
    cli += ['--no-playlist', '-o', f'%(title).150B{clip} [%(id)s]{quality}.%(ext)s']
    # The same choice again replaces the old file instead of post-processing it twice.
    cli += ['--force-overwrites']

    if a.get('format'):
        cli += ['-f', a['format']]
    if a.get('sort'):
        cli += ['-S', a['sort']]

    if mode == 'audio':
        afmt = a.get('audio_format') or 'm4a'
        cli += ['-x', '--audio-format', afmt]
        if a.get('audio_quality') is not None and afmt not in ('best', 'flac', 'wav', 'alac'):
            cli += ['--audio-quality', str(a['audio_quality'])]
    else:
        container = a.get('container') or 'mp4'
        # Merged downloads use the container; single-file downloads are remuxed into it.
        cli += ['--merge-output-format', container, '--remux-video', container]

    if a.get('embed_metadata', True):
        cli += ['--embed-metadata', '--embed-chapters']
    if a.get('embed_thumbnail', True):
        cli += ['--embed-thumbnail']

    subs = a.get('subtitles')
    if subs and subs.get('langs'):
        cli += ['--sub-langs', ','.join(subs['langs']), '--write-subs']
        if subs.get('auto'):
            cli += ['--write-auto-subs']
        if mode != 'audio':
            cli += ['--embed-subs']
        else:
            cli += ['--convert-subs', 'srt']

    sb = a.get('sponsorblock')
    if sb and sb.get('remove'):
        cli += ['--sponsorblock-remove', ','.join(sb['remove'])]
    elif sb and sb.get('mark'):
        cli += ['--sponsorblock-mark', ','.join(sb['mark'])]

    if sec.get('start') is not None or sec.get('end') is not None:
        start = _num(sec.get('start')) or 0.0
        end = _num(sec.get('end'))
        if end is not None and end <= start:
            raise RuntimeError('The clip ends before it starts')
        cli += ['--download-sections', f'*{_ts(start)}-{_ts(end) if end is not None else "inf"}']
    return cli


def _short(seconds: float) -> str:
    seconds = int(max(0, float(seconds)))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f'{h}h{m:02d}m{s:02d}s' if h else f'{m}m{s:02d}s'


def _ts(seconds: float) -> str:
    seconds = max(0.0, float(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f'{int(h)}:{int(m):02d}:{s:06.3f}'


def start(args: dict) -> dict:
    if not STATE['ready']:
        raise RuntimeError('Engine not ready')
    args['url'] = _check_url(args.get('url'))
    job_id = str(args.get('id') or '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,40}', job_id):
        raise RuntimeError('Bad job id')
    if job_id in _jobs:
        raise RuntimeError('That download is already running')
    if args.get('cancelled'):
        return {'id': job_id, 'started': False}
    build_cli({**args, 'id': job_id})  # reject bad options before anything starts
    _enter_shared()
    job = Job(job_id, args)
    _jobs[job.id] = job
    job.thread = threading.Thread(target=job.run, name=f'job-{job.id}', daemon=True)
    job.thread.start()
    return {'id': job.id, 'started': True}


def cancel(args: dict) -> dict:
    job = _jobs.get(args.get('id'))
    if job:
        job.cancelled = True
        if job.thread:
            procs.stop_owned_by(job.thread)
    return {'cancelled': bool(job)}


def discard(args: dict) -> dict:
    """Forget a failed download's kept partial files (the user removed it)."""
    job_id = str(args.get('id') or '')
    if re.fullmatch(r'[A-Za-z0-9_-]{1,40}', job_id) and job_id not in _jobs:
        _cleanup_temp(job_id)
    return {}


def remux_file(args: dict) -> dict:
    """Copy an MKV/WebM from the library into MP4 without re-encoding."""
    import subprocess
    docs = os.path.realpath(STATE['docs'])
    src = os.path.realpath(str(args.get('path') or ''))
    if not src.startswith(docs + os.sep) or not os.path.isfile(src):
        raise RuntimeError('That file isn\'t in Alembic\'s folder')
    if args.get('container', 'mp4') != 'mp4':
        raise RuntimeError('Only MP4 is supported')
    dst = _unique(os.path.splitext(src)[0] + '.mp4')
    tmp = dst + '.part.mp4'
    _enter_shared()
    try:
        r = subprocess.run(['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-i', src,
                            '-map', '0:v', '-map', '0:a?', '-map', '0:s?', '-c', 'copy', '-c:s', 'mov_text',
                            '-movflags', '+faststart', tmp], capture_output=True, text=True)
    finally:
        _leave_shared()
    if r.returncode != 0 or not os.path.exists(tmp):
        try:
            os.remove(tmp)
        except OSError:
            pass
        detail = (r.stderr or '').strip().splitlines()[-1:] or ['unknown error']
        raise RuntimeError(f'MP4 can\'t hold this file\'s streams ({detail[0]})')
    os.replace(tmp, dst)
    return {'path': dst}


# ---------------------------------------------------------------- updates --
def check_update(args: dict) -> dict:
    return updater.check(args.get('channel', 'stable'))


def install_update(args: dict) -> dict:
    staged = updater.stage(args.get('channel', 'stable'))  # network + verification only
    previous = updater.snapshot()
    try:
        with _Exclusive():
            updater.commit(staged)
            updater.reload_modules()
            _info_cache.clear()
            try:
                _load_ytdlp(strict=True)
            except Exception as e:
                updater.restore(previous, staged)
                updater.reload_modules()
                _load_ytdlp(strict=False)
                raise RuntimeError(f'yt-dlp {staged["version"]} didn\'t work in Alembic '
                                   f'({_clean_error(e)}), so the previous version was kept') from e
    except BaseException:
        if updater.snapshot() != staged:
            updater.restore(updater.snapshot(), staged)
        raise
    updater.finish(staged)
    return {'installed': staged['version'], **versions({})}


def reset_update(_args) -> dict:
    with _Exclusive():
        updater.reset()
        updater.reload_modules()
        _info_cache.clear()
        _load_ytdlp(strict=False)
    return versions({})


def clear_cache(_args) -> dict:
    shutil.rmtree(os.path.join(STATE['support'], 'cache'), ignore_errors=True)
    _info_cache.clear()
    for name in os.listdir(STATE['temp']):
        if name not in _jobs:
            shutil.rmtree(os.path.join(STATE['temp'], name), ignore_errors=True)
    updater.clear_cache()
    return {}


_COMMANDS = {
    'init': init, 'versions': versions, 'ffmpeg_version': ffmpeg_version,
    'probe': probe, 'cancel_probe': cancel_probe,
    'start': start, 'cancel': cancel, 'discard': discard, 'remux_file': remux_file,
    'check_update': check_update, 'install_update': install_update,
    'reset_update': reset_update, 'clear_cache': clear_cache,
}

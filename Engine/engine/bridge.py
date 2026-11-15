"""Native services the app provides to Python.

On iOS these come from the `_alembic` builtin module compiled into the app
(see App/Engine/PythonHost.m). On a Mac (tests / development) we fall back to
real processes: `deno`/`node` for JavaScript, and the ffmpeg/ffprobe built by
scripts/build-ffmpeg.sh (build/deps/macos/bin, same configuration as the app),
or whatever ALEMBIC_FFMPEG_DIR points to.
"""
from __future__ import annotations

import os
import shutil
import signal
import sys
import threading

try:
    import _alembic as _native  # type: ignore
except ImportError:  # running on a Mac
    _native = None

IS_IOS = _native is not None or sys.platform == 'ios'


def emit(message: str) -> None:
    """Send a JSON event string to the app UI."""
    if _native is not None:
        _native.emit(message)
    else:
        _mac_events.append(message)
        if os.environ.get('ALEMBIC_ECHO_EVENTS'):
            print('EVENT', message[:300], file=sys.__stderr__)


def eval_js(code: str) -> str:
    """Run a JS program; return everything it printed with console.log."""
    if _native is not None:
        return _native.eval_js(code)
    exe = shutil.which('deno')
    cmd = [exe, 'run', '--quiet', '-'] if exe else None
    if cmd is None and (exe := shutil.which('node')):
        cmd = [exe, '-']
    if not cmd:
        raise RuntimeError('No JS runtime on this Mac')
    return _spawn_capture(cmd, code)


def run_tool(tool: str, argv: list[str], fd_in: int, fd_out: int, fd_err: int, token: int) -> int:
    """Run ffmpeg/ffprobe with the given argv (argv[0] is the tool name). Blocks.

    `token` identifies this run, so stop_tool(token) can never hit a later one.
    """
    if _native is not None:
        return _native.run_tool(tool, argv, fd_in, fd_out, fd_err, token)
    exe = _mac_tool(tool)
    if not exe:
        return 127
    actions = [
        (os.POSIX_SPAWN_DUP2, fd_in, 0),
        (os.POSIX_SPAWN_DUP2, fd_out, 1),
        (os.POSIX_SPAWN_DUP2, fd_err, 2),
    ]
    with _mac_lock:
        pid = os.posix_spawn(exe, [exe, *argv[1:]], dict(os.environ), file_actions=actions)
        _mac_pids[token] = pid
        stop_early = token in _mac_stopped
    if stop_early:
        _mac_kill(pid)
    try:
        _, status = os.waitpid(pid, 0)
    finally:
        with _mac_lock:
            _mac_pids.pop(token, None)
            _mac_stopped.discard(token)
    return os.waitstatus_to_exitcode(status)


def stop_tool(token: int) -> None:
    """Ask the ffmpeg run identified by `token` to stop now."""
    if _native is not None:
        _native.stop_tool(token)
        return
    with _mac_lock:
        _mac_stopped.add(token)
        pid = _mac_pids.get(token)
    if pid:
        _mac_kill(pid)


# --- Mac fallback plumbing ---------------------------------------------------
_mac_events: list[str] = []
_mac_lock = threading.Lock()
_mac_pids: dict[int, int] = {}
_mac_stopped: set[int] = set()


def _mac_tool(tool: str) -> str | None:
    here = os.path.dirname(os.path.abspath(__file__))
    for d in (os.environ.get('ALEMBIC_FFMPEG_DIR'),
              os.path.join(here, '..', '..', 'build', 'deps', 'macos', 'bin')):
        if d and os.access(os.path.join(d, tool), os.X_OK):
            return os.path.realpath(os.path.join(d, tool))
    return shutil.which(tool)


def _mac_kill(pid: int) -> None:
    # Same as the app: one stop request is final (twice SIGINT aborts I/O at once).
    for _ in range(2):
        try:
            os.kill(pid, signal.SIGINT)
        except OSError:
            return


def _spawn_capture(cmd: list[str], stdin_text: str) -> str:
    # Uses posix_spawn directly so it works even while subprocess is patched.
    r_in, w_in = os.pipe()
    r_out, w_out = os.pipe()
    pid = os.posix_spawn(cmd[0], cmd, dict(os.environ), file_actions=[
        (os.POSIX_SPAWN_DUP2, r_in, 0), (os.POSIX_SPAWN_DUP2, w_out, 1)])
    os.close(r_in)
    os.close(w_out)

    def feed():
        with os.fdopen(w_in, 'wb') as f:
            f.write(stdin_text.encode())
    t = threading.Thread(target=feed)
    t.start()
    with os.fdopen(r_out, 'rb') as f:
        data = f.read()
    t.join()
    os.waitpid(pid, 0)
    return data.decode()

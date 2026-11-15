"""Make `ffmpeg` and `ffprobe` subprocesses work on iOS.

iOS apps cannot start processes, so `subprocess.Popen` is taught one trick:
when the program is ffmpeg or ffprobe, it runs the FFmpeg code linked into the
app on a thread instead, wired to real OS pipes. Everything above that
(yt-dlp's Popen.run, communicate(), wait(), sending 'q' to stdin, kill()) keeps
working unchanged, which is why this survives yt-dlp updates.

FFmpeg's command-line code keeps global state, so only one tool runs at a time;
the others wait their turn (and can be cancelled while they wait).
"""
from __future__ import annotations

import errno
import itertools
import os
import re
import subprocess
import threading

from . import bridge

TOOLS = ('ffmpeg', 'ffprobe')
_tool_lock = threading.Lock()
_fake_pids = itertools.count(0x7FFF0000)
_registry_lock = threading.Lock()
_procs: dict[int, subprocess.Popen] = {}  # fake pid -> Popen, waiting or running
_log_sink = None     # callable(owner_thread, line)
_status_sink = None  # callable(owner_thread, 'waiting' | 'running')

_orig = {
    name: getattr(subprocess.Popen, name)
    for name in ('_execute_child', '_internal_poll', '_wait', 'send_signal')
}


def tool_for(args) -> str | None:
    if isinstance(args, (str, bytes, os.PathLike)):
        text = os.fsdecode(args).strip()
        first = text.split()[0] if text else ''
    elif args:
        first = os.fsdecode(args[0])
    else:
        return None
    base = os.path.basename(first).removesuffix('.exe')
    return base if base in TOOLS else None


_LINE_END = re.compile(rb'[\r\n]+')


def _drain_to_log(fd: int, owner) -> None:
    # ffmpeg ends its live stats lines with \r, so split on both.
    buf = b''
    with os.fdopen(fd, 'rb', buffering=0) as f:
        while True:
            chunk = f.read(8192)
            if not chunk:
                break
            buf += chunk
            *lines, buf = _LINE_END.split(buf)
            for raw in lines:
                if raw and _log_sink:
                    _log_sink(owner, raw.decode('utf-8', 'replace').rstrip())
    if buf.strip() and _log_sink:
        _log_sink(owner, buf.decode('utf-8', 'replace').rstrip())


def _notify(owner, state: str) -> None:
    if _status_sink:
        try:
            _status_sink(owner, state)
        except Exception:
            pass


def _execute_child(self, args, executable, preexec_fn, close_fds, pass_fds, cwd, env,
                   startupinfo, creationflags, shell, p2cread, p2cwrite, c2pread, c2pwrite,
                   errread, errwrite, *rest):
    tool = None if shell else tool_for(args)
    if tool is None:
        if bridge.IS_IOS:
            name = args if isinstance(args, (str, bytes)) else (args[0] if args else '')
            self._close_pipe_fds(p2cread, p2cwrite, c2pread, c2pwrite, errread, errwrite)
            raise FileNotFoundError(errno.ENOENT, 'iOS cannot run programs', os.fsdecode(name))
        return _orig['_execute_child'](self, args, executable, preexec_fn, close_fds, pass_fds,
                                       cwd, env, startupinfo, creationflags, shell, p2cread,
                                       p2cwrite, c2pread, c2pwrite, errread, errwrite, *rest)

    argv = [tool, *(os.fsdecode(a) for a in args[1:])]
    owner = threading.current_thread()
    # Our own copies of the child's ends; the originals are closed just below,
    # exactly like the real implementation does after fork().
    fd_in = os.dup(p2cread) if p2cread != -1 else os.open(os.devnull, os.O_RDONLY)
    drains = []
    if c2pwrite != -1:
        fd_out = os.dup(c2pwrite)
    else:
        r, fd_out = os.pipe()
        drains.append(r)
    if errwrite != -1:
        fd_err = os.dup(errwrite)
    else:
        r, fd_err = os.pipe()
        drains.append(r)
    self._close_pipe_fds(p2cread, p2cwrite, c2pread, c2pwrite, errread, errwrite)
    for r in drains:
        threading.Thread(target=_drain_to_log, args=(r, owner), daemon=True).start()

    self.pid = next(_fake_pids)
    self._child_created = True
    self._alembic_done = threading.Event()
    self._alembic_rc = None
    self._alembic_cancelled = False
    self._alembic_tool = tool
    self._alembic_owner = owner
    self._alembic_started = False
    # Registered before waiting for the lock, so a cancel reaches tools still in the queue.
    with _registry_lock:
        _procs[self.pid] = self

    def run():
        rc = 255
        try:
            if not _tool_lock.acquire(blocking=False):
                _notify(owner, 'waiting')
                _tool_lock.acquire()
            try:
                with _registry_lock:
                    cancelled = self._alembic_cancelled
                    self._alembic_started = not cancelled
                if not cancelled:
                    _notify(owner, 'running')
                    # The pid is the run's token: a stop aimed at this run that lands
                    # before FFmpeg has started is still applied once it does.
                    rc = bridge.run_tool(tool, argv, fd_in, fd_out, fd_err, self.pid)
            finally:
                _tool_lock.release()
        except Exception as e:  # never let a tool failure escape the thread
            try:
                os.write(fd_err, f'{tool} failed to run: {e}\n'.encode())
            except OSError:
                pass
        finally:
            with _registry_lock:
                _procs.pop(self.pid, None)
            for fd in (fd_in, fd_out, fd_err):
                try:
                    os.close(fd)
                except OSError:
                    pass
            self._alembic_rc = rc
            self._alembic_done.set()

    threading.Thread(target=run, name=f'{tool}-{self.pid}', daemon=True).start()


def _internal_poll(self, *args, **kwargs):
    if not hasattr(self, '_alembic_done'):
        return _orig['_internal_poll'](self, *args, **kwargs)
    if self.returncode is None and self._alembic_done.is_set():
        self.returncode = self._alembic_rc
    return self.returncode


def _wait(self, timeout):
    if not hasattr(self, '_alembic_done'):
        return _orig['_wait'](self, timeout)
    if not self._alembic_done.wait(timeout):
        raise subprocess.TimeoutExpired(self.args, timeout)
    self.returncode = self._alembic_rc
    return self.returncode


def _send_signal(self, sig):
    if not hasattr(self, '_alembic_done'):
        return _orig['send_signal'](self, sig)
    if self.returncode is not None or self._alembic_done.is_set():
        return
    with _registry_lock:
        self._alembic_cancelled = True
        started = self._alembic_started
    if started and self._alembic_tool == 'ffmpeg':
        bridge.stop_tool(self.pid)


def stop_owned_by(thread) -> None:
    """Stop every tool started from `thread`, running or still waiting (used on cancel)."""
    with _registry_lock:
        procs = [p for p in _procs.values() if p._alembic_owner is thread]
    for proc in procs:
        proc.send_signal(2)


_installed = False


def install(log_sink=None, status_sink=None) -> None:
    global _installed, _log_sink, _status_sink
    _log_sink = log_sink
    _status_sink = status_sink
    if _installed:
        return
    _installed = True
    subprocess._can_fork_exec = True  # we handle the unsupported cases ourselves
    subprocess.Popen._execute_child = _execute_child
    subprocess.Popen._internal_poll = _internal_poll
    subprocess.Popen._wait = _wait
    subprocess.Popen.send_signal = _send_signal

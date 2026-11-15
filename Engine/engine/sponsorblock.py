"""Clean SponsorBlock cuts without re-encoding.

yt-dlp cuts with FFmpeg's concat demuxer in stream-copy mode. Where a sponsor
segment ends, the next kept part starts with `inpoint <end>`. Stream copy can
only start a video cleanly on a keyframe, and the end of a sponsor segment is
almost never one, so the demuxer also emits the video packets from the keyframe
before it. They overlap the previous part, which shows up as garbage frames and
doubled audio at the seam and audio drifting out of sync after it.

The fix happens before yt-dlp plans the cut: each removed segment's end is
moved forward to the next video keyframe, so every kept part starts on one and
the stock concat stays clean. Chapters and subtitles are computed from the
same adjusted times, so they stay correct too. A cut can run up to one
keyframe interval (usually 1-5 s on YouTube) past the segment's end, which
means a little extra is removed but no sponsor footage is left in. A keyframe
just before the end (within SLACK) is used instead, which keeps a tiny sliver
of the segment rather than dropping a whole interval.

Audio-only files have no keyframe problem and are left alone.
"""
from __future__ import annotations

import os
import subprocess

SLACK = 0.25    # seconds: a keyframe this close before a segment's end is good enough
WINDOW = 30     # seconds of packets read after each segment's end looking for a keyframe


def _keyframes_after(pp, path: str, times: list[float]) -> list[float]:
    from yt_dlp.utils import Popen

    intervals = ','.join(f'{max(0.0, t - SLACK):.3f}%+{WINDOW}' for t in times)
    # V = video, but not cover art. Packets only: nothing is decoded.
    cmd = [pp.probe_executable, '-v', 'error', '-select_streams', 'V:0',
           '-read_intervals', intervals, '-show_entries', 'packet=pts_time,flags',
           '-of', 'csv=p=0', path]
    out, _, rc = Popen.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)
    if rc != 0:
        return []
    keys = set()
    for line in out.splitlines():
        pts, _, flags = line.partition(',')
        if flags.startswith('K'):
            try:
                keys.add(float(pts))
            except ValueError:
                pass
    return sorted(keys)


def _snap(pp, path: str, segments: list[dict]) -> None:
    ends = sorted({s['end_time'] for s in segments})
    if not ends or not path or not os.path.exists(path):
        return
    keys = _keyframes_after(pp, path, ends)
    if not keys:
        return  # audio only, or the probe failed: cut as yt-dlp would
    moved = {}
    for end in ends:
        key = next((k for k in keys if k >= end - SLACK), None)
        if key is not None and key - end <= WINDOW:
            moved[end] = key
    for s in segments:
        old = s['end_time']
        new = moved.get(old)
        if new is None or new == old:
            continue
        pp.write_debug(f'Moving cut end {old:.3f} -> {new:.3f} (keyframe)')
        s['end_time'] = new
        s['_categories'] = [(c, st, new if en == old else en, *rest)
                            for c, st, en, *rest in s.get('_categories') or []]


def register() -> None:
    from yt_dlp.postprocessor.modify_chapters import ModifyChaptersPP

    if getattr(ModifyChaptersPP, '_alembic_keyframe_cuts', False):
        return

    orig_run = ModifyChaptersPP.run
    orig_mark = ModifyChaptersPP._mark_chapters_to_remove

    def run(self, info):
        self._alembic_path = info.get('filepath')
        try:
            return orig_run(self, info)
        finally:
            self._alembic_path = None

    def mark(self, chapters, sponsor_chapters):
        chapters, sponsor_chapters = orig_mark(self, chapters, sponsor_chapters)
        removed = [s for s in sponsor_chapters if s.get('remove')]
        if removed and not self._force_keyframes:
            try:
                _snap(self, getattr(self, '_alembic_path', None), removed)
            except Exception as e:  # never fail a download over this; cut as yt-dlp would
                self.report_warning(f'Could not line cuts up with keyframes ({e})')
        return chapters, sponsor_chapters

    ModifyChaptersPP.run = run
    ModifyChaptersPP._mark_chapters_to_remove = mark
    ModifyChaptersPP._alembic_keyframe_cuts = True

"""Engine tests on a Mac: the engine runs exactly as in the app, with deno standing in
for WebKit and the macOS build of the app's own FFmpeg configuration
(build/deps/macos/bin, from scripts/build-ffmpeg.sh) standing in for the in-app tools.

Usage: python3 Engine/tests/smoke.py <workdir> [test ...]     (no tests = all)
Needs network access. Each test checks real output with ffprobe, not just exit codes.
"""
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'Engine'))
sys.path.insert(1, os.path.join(ROOT, 'build', 'engine', 'app_packages'))
from engine import api, bridge, updater  # noqa: E402

FFPROBE = os.path.join(ROOT, 'build', 'deps', 'macos', 'bin', 'ffprobe')
SHORT = 'https://www.youtube.com/watch?v=jNQXAC9IVRw'          # 19 s
LONGER = 'https://www.youtube.com/watch?v=aqz-KE-bpKQ'         # Big Buck Bunny (CC BY), ~10 min
CHANNEL = 'https://www.youtube.com/@BlenderStudio/videos'

work = os.path.abspath(sys.argv[1])
wanted = sys.argv[2:]
shutil.rmtree(work, ignore_errors=True)


def call(cmd, **a):
    return json.loads(api.handle(json.dumps({'cmd': cmd, 'args': a})))


def must(r):
    if not r['ok']:
        raise AssertionError(r['error'] + '\n' + r.get('trace', ''))
    return r['result']


def streams(path):
    out = subprocess.run([FFPROBE, '-v', 'error', '-show_entries', 'stream=codec_type,codec_name:stream_disposition=attached_pic',
                          '-of', 'json', path], capture_output=True, text=True, check=True).stdout
    return [(s['codec_type'], s['codec_name'], s.get('disposition', {}).get('attached_pic', 0))
            for s in json.loads(out)['streams']]


def run_job(job_id, url, timeout=400, on_event=None, **opts):
    must(call('start', id=job_id, url=url, **opts))
    events, deadline = [], time.time() + timeout
    while time.time() < deadline:
        evs, bridge._mac_events[:] = list(bridge._mac_events), []
        for e in map(json.loads, evs):
            if e.get('id') != job_id:
                continue
            events.append(e)
            if on_event:
                on_event(e)
            if e['type'] == 'job' and e['status'] in ('finished', 'error', 'cancelled'):
                return e, events
        time.sleep(0.1)
    raise AssertionError('timed out')


def expect_file(final, *, ext, has):
    assert final['status'] == 'finished', final
    f = final['files'][0]
    assert f.endswith('.' + ext), f
    got = streams(f)
    for kind, codec in has:
        assert any(k == kind and c == codec for k, c, _ in got), (f, got)
    return f, got


# ------------------------------------------------------------------ tests --
def t_probe():
    res = must(call('probe', url=SHORT, probe_id='p1'))
    assert res['kind'] == 'video' and res['formats'] and res['duration'] > 10
    assert all(isinstance(f.get('height', 0), int) for f in res['formats'])


def t_probe_channel():
    t = time.time()
    res = must(call('probe', url=CHANNEL, probe_id='p2'))
    assert res['kind'] == 'playlist' and len(res['entries']) > 20, res.get('kind')
    assert time.time() - t < 60, 'a channel must be listed flat, not extracted'


def t_probe_cancel():
    import threading
    out = {}
    th = threading.Thread(target=lambda: out.update(r=call('probe', url=LONGER, probe_id='p3')))
    th.start()
    time.sleep(0.8)
    must(call('cancel_probe', probe_id='p3'))
    th.join(30)
    assert not th.is_alive() and not out['r']['ok'], out


def t_video():
    final, _ = run_job('video', SHORT, mode='video', container='mp4',
                       format='bv*[vcodec^=avc1]+ba[acodec^=mp4a]/b')
    _, got = expect_file(final, ext='mp4', has=[('video', 'h264'), ('audio', 'aac')])
    assert any(pic for *_, pic in got), 'cover art should be embedded'
    assert ' 240p' in final['files'][0] or 'p.mp4' in final['files'][0], final['files'][0]


def t_av1opus():
    final, _ = run_job('av1opus', SHORT, mode='video', container='mp4', format='bv*+ba',
                       sort='vcodec:av01,acodec:opus')
    expect_file(final, ext='mp4', has=[('video', 'av1'), ('audio', 'opus')])


def t_audio_m4a():
    final, _ = run_job('m4a', SHORT, mode='audio', format='ba', audio_format='m4a')
    expect_file(final, ext='m4a', has=[('audio', 'aac')])


def t_mp3():
    final, _ = run_job('mp3', SHORT, mode='audio', format='ba', audio_format='mp3', audio_quality='0')
    expect_file(final, ext='mp3', has=[('audio', 'mp3')])


def t_opus_from_aac():
    # Fable finding 2: encoding Opus (source is AAC, so it must be re-encoded with libopus)
    final, _ = run_job('opus', SHORT, mode='audio', format='ba[acodec^=mp4a]', audio_format='opus')
    expect_file(final, ext='opus', has=[('audio', 'opus')])


def t_trim_progress():
    seen = []
    final, _ = run_job('trim', LONGER, mode='video', container='mp4', format='bv*[height<=360]+ba/b',
                       section={'start': 30, 'end': 60},
                       on_event=lambda e: e['type'] == 'job' and seen.append(e.get('progress')))
    expect_file(final, ext='mp4', has=[('audio', 'aac')])
    mids = [p for p in seen if p and 0.05 < p < 0.99]
    assert mids, f'clip downloads should report progress, got {seen}'


def t_cancel():
    import threading
    threading.Timer(4, lambda: call('cancel', id='cancel')).start()
    final, _ = run_job('cancel', LONGER, mode='video', container='mkv', format='bv*[height<=720]+ba')
    assert final['status'] == 'cancelled', final
    assert not os.path.exists(os.path.join(work, 'tmp', 'cancel'))


def t_rescue():
    # H.264 + AAC can't go in WebM: the merge fails, but the streams must be kept.
    final, _ = run_job('rescue', SHORT, mode='video', container='webm',
                       format='bv*[vcodec^=avc1]+ba[acodec^=mp4a]', embed_thumbnail=False)
    assert final['status'] == 'finished' and final.get('warning'), final
    assert all(os.path.exists(f) for f in final['files']) and final['files'], final


def t_remux():
    final, _ = run_job('mkv', SHORT, mode='video', container='mkv', format='bv*[vcodec^=avc1]+ba[acodec^=mp4a]')
    mkv = final['files'][0]
    assert mkv.endswith('.mkv'), mkv
    out = must(call('remux_file', path=mkv, container='mp4'))['path']
    got = streams(out)
    assert out.endswith('.mp4') and any(k == 'video' for k, *_ in got), got
    assert not call('remux_file', path='/etc/hosts')['ok']


def t_bad_url():
    r = call('start', id='bad', url='--exec rm', mode='video')
    assert not r['ok']
    r = call('probe', url='file:///etc/passwd')
    assert not r['ok']


def t_updater_guards():
    # A pointer to a tampered or older update must be ignored, falling back to the bundled copy.
    d = os.path.join(work, 'support', 'ytdlp')
    fake = os.path.join(d, 'yt-dlp-2099.1.1.zip')
    shutil.copy(updater._bundled, fake)
    with open(os.path.join(d, 'active.json'), 'w') as f:
        json.dump({'file': os.path.basename(fake), 'sha256': '0' * 64}, f)
    updater.activate()
    assert updater.active_source() == 'bundled'
    assert not os.path.exists(os.path.join(d, 'active.json'))


TESTS = [t_bad_url, t_probe, t_probe_channel, t_probe_cancel, t_video, t_av1opus, t_audio_m4a,
         t_mp3, t_opus_from_aac, t_trim_progress, t_cancel, t_rescue, t_remux, t_updater_guards]

if __name__ == '__main__':
    assert os.access(FFPROBE, os.X_OK), 'run scripts/build-ffmpeg.sh first'
    os.environ.setdefault('ALEMBIC_FFMPEG_DIR', os.path.dirname(FFPROBE))
    init = must(call('init', docs=f'{work}/docs', support=f'{work}/support', temp=f'{work}/tmp',
                     cache=f'{work}/cache', bundled_ytdlp=os.path.join(ROOT, 'build', 'engine', 'yt-dlp.zip')))
    print('engine', init['ytdlp'], 'solver ok' if init['youtube_solver'] else init['youtube_solver_error'])
    print('ffmpeg', must(call('ffmpeg_version'))['ffmpeg'])
    failed = 0
    for t in TESTS:
        if wanted and t.__name__[2:] not in wanted:
            continue
        start = time.time()
        try:
            t()
            print(f'PASS {t.__name__[2:]:16} {time.time() - start:5.1f}s')
        except Exception as e:
            failed += 1
            print(f'FAIL {t.__name__[2:]:16} {e}')
    sys.exit(1 if failed else 0)

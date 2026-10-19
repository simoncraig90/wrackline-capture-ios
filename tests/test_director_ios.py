#!/usr/bin/env python3
"""Runs tools/capture-android/director.py UNCHANGED against capture-ios-fake (the iOS app's real HTTP server + take code, fake camera).
  tools/capture-ios/tests/run.sh            # builds the fake with the CLT swiftc, then runs this
  python3 test_director_ios.py <path-to-capture-ios-fake>
Drives the director's own API (/api/start /api/stop /api/torch /api/calibrated /api/pull) and asserts what the director recorded.
Exit 0 = every command the director issues succeeded against the iOS server. Uses the fake: it says nothing about the camera."""
import json, os, signal, subprocess, sys, tempfile, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ANDROID = os.path.join(HERE, '..', '..', 'capture-android')
sys.path.insert(0, ANDROID)
from test_mp4info import mp4

FAKE = sys.argv[1]; PF, PD, TOK = 18092, 18765, 'tok'
tmp = tempfile.mkdtemp(prefix='ios-fake-'); fails = []


def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + ('' if cond else '  ' + str(detail)), flush=True)
    if not cond: fails.append(name)


def call(port, path, method='GET', tok=TOK):
    r = urllib.request.Request(f'http://127.0.0.1:{port}{path}', method=method, data=b'' if method == 'POST' else None)
    try:
        with urllib.request.urlopen(r, timeout=60) as x: return json.loads(x.read())
    except urllib.error.HTTPError as e:
        try: body = json.loads(e.read())
        except Exception: body = {}
        return {**body, 'http': e.code}


sample = os.path.join(tmp, 'sample.mp4')
open(sample, 'wb').write(mp4([(120, 1500)], [(172, 1024)]) + os.urandom(30000))      # 120 frames at 60 fps = 2000 ms
cams = os.path.join(tmp, 'cameras.json')
json.dump({'cameras': [{'name': 'iphone', 'host': f'127.0.0.1:{PF}', 'token': TOK}]}, open(cams, 'w'))
fake = subprocess.Popen([FAKE, '--port', str(PF), '--token', TOK, '--dir', os.path.join(tmp, 'device'), '--sample', sample, '--frames', '120', '--dur-ms', '2000'])
dirc = subprocess.Popen([sys.executable, '-I', os.path.join(ANDROID, 'director.py'), '--cameras', cams, '--port', str(PD), '--bind', '127.0.0.1', '--token', TOK,
                         '--out', os.path.join(tmp, 'out'), '--session', 'itest'], cwd=ANDROID)
try:
    for _ in range(50):
        try:
            if call(PD, f'/api/state?t={TOK}'): break
        except Exception: pass
        time.sleep(0.2)
    time.sleep(3)   # director polls /status.json and /time round trips
    st = call(PD, f'/api/state?t={TOK}')
    cam = st['cams']
    cam0 = cam[0]
    check('director polls /status.json: phone up', cam0.get('up') is True, cam0)
    s = call(PD, f'/api/start?t={TOK}&label=Chop%20Wood', 'POST')
    r = s.get('take', {}).get('cams', {}).get('iphone', {})
    check('/start ok through the director', r.get('ok') is True, s)
    check('/time clock sync worked (offset measured at start)', r.get('offset_ms') is not None, r)
    check('/start returns take id + marker', bool(r.get('take')) and 'wall_ms' in (r.get('marker') or {}), r)
    time.sleep(1)
    p = call(PD, f'/api/torch?t={TOK}&cam=iphone&mode=on', 'POST')
    check('/torch passes through', p.get('ok') is True and p.get('torchMode') == 'on', p)
    time.sleep(0.5)
    e = call(PD, f'/api/stop?t={TOK}', 'POST')
    T = e.get('take', {}); r = T.get('cams', {}).get('iphone', {'stop': {}})
    check('/stop ok', r['stop'].get('ok') is True and r.get('take_id') == r.get('take'), e)
    sc = r.get('sidecar') or {}
    check('director fetched the sidecar (marker, firstFrame, closed chunk with frames)', 'sidecar_error' not in r and sc.get('marker') and sc.get('firstFrame')
          and sc['chunks'] and sc['chunks'][0].get('open') is False and sc['chunks'][0].get('frames') == 120, r)
    check('first frame after marker (skew computed)', T.get('first_frame_vs_marker_ms', {}).get('iphone') is not None, e)
    c = call(PD, f'/api/calibrated?t={TOK}', 'POST')
    check('/calibrated handled (iOS answers 409 like Android when it cannot calibrate; director survives)', c.get('ok') is False and 'iphone' in c.get('cams', {}), c)
    pl = call(PD, f'/api/pull?t={TOK}', 'POST')
    pr = pl.get('iphone', {})
    check('/chunks + /chunk pull: mp4 + sidecar downloaded and verified', pr.get('pulled') == 2 and pr.get('bad') == 0, pl)
    got = sorted(os.listdir(pr['dir'])) if pr.get('dir') else []
    check('files on the Mac side', any(n.endswith('.mp4') for n in got) and any(n.endswith('.json') for n in got), got)
    st = call(PD, f'/api/state?t={TOK}')
    check('no token/auth warning on the camera', 'token' not in (st['cams'][0]['status'].get('warnings') or {}), st['cams'][0]['status'])
    # --- the fields director.py reads (status poll, clock sync): a renamed/dropped field must go red here
    D = lambda p, m='GET': call(PF, p + ('&' if '?' in p else '?') + f't={TOK}', m)
    tm = D('/time')
    check('/time has wall_ms and mono_ns (director clock sync)', isinstance(tm.get('wall_ms'), int) and isinstance(tm.get('mono_ns'), int) and tm['mono_ns'] > 0, tm)
    need = {'armed': bool, 'recording': bool, 'take': str, 'wall_ms': int, 'mono_ns': int, 'recSeconds': int, 'chunk': str, 'chunksDone': int,
            'battery': int, 'plugged': bool, 'tempC': (int, float), 'freeGB': (int, float), 'measuredFps': (int, float), 'cameraDrops': int,
            'encoderDrops': int, 'iso': int, 'shutter': str, 'torch': bool, 'torchMode': str, 'focusAwbLocked': bool, 'rotation': int,
            'warnings': dict, 'alerts': list, 'listen': list, 'interrupted': bool}
    st0 = D('/status.json')
    okt = lambda v, t: isinstance(v, t) and (isinstance(v, bool) == (t is bool))   # bool is an int in Python: keep them apart
    bad = {k: st0.get(k, 'MISSING') for k, t in need.items() if not okt(st0.get(k), t)}
    check('/status.json carries every field director.py reads, right types (idle)', not bad, bad)
    check('idle: recSeconds 0, battery 87, not recording', st0.get('recSeconds') == 0 and st0.get('battery') == 87 and st0.get('recording') is False, st0)
    sr = D('/start?label=status', 'POST'); time.sleep(2.2)
    st1 = D('/status.json')
    check('recording: recording true, take id, chunk name, recSeconds >= 2', st1.get('recording') is True and st1.get('take') and st1.get('chunk', '').endswith('.mp4') and st1.get('recSeconds', 0) >= 2, st1)
    # --- backgrounding mid-take: SIGUSR1 = the app left the foreground (fake hook calls TakeManager.interruptRecording)
    os.kill(fake.pid, signal.SIGUSR1); time.sleep(1)
    st2 = D('/status.json'); tid = st2.get('take', ''); chs = D('/chunks')
    sc2 = json.loads(urllib.request.urlopen(f'http://127.0.0.1:{PF}/chunk/{tid}.json?t={TOK}').read()) if tid else {}
    check('interrupt: take stopped, flagged interrupted in /status.json', st2.get('recording') is False and st2.get('interrupted') is True and 'foreground' in st2.get('interruptedWhy', ''), st2)
    check('interrupt: chunk closed (frames recorded, mp4 on disk), sidecar has stop+interrupted', bool(sc2.get('chunks')) and sc2['chunks'][0].get('open') is False
          and sc2['chunks'][0].get('frames') == 120 and 'interrupted' in sc2 and 'interrupted' in sc2.get('stop', {}).get('why', '')
          and any(c['name'].endswith('.mp4') and not c['open'] and c['bytes'] > 1000 for c in chs), (sc2, chs))
    time.sleep(1.5); st3 = D('/status.json')
    check('interrupt: not auto-resumed', st3.get('recording') is False and st3.get('take') == tid, st3)
    # --- permissions: a second server whose camera/mic are denied must refuse /start with 409 + reason and create no take
    den = subprocess.Popen([FAKE, '--port', str(PF + 1), '--token', TOK, '--dir', os.path.join(tmp, 'device-denied'), '--sample', sample, '--deny', 'mic denied'])
    try:
        for _ in range(50):
            try: call(PF + 1, f'/time?t={TOK}'); break
            except Exception: time.sleep(0.1)
        d = call(PF + 1, f'/start?t={TOK}', 'POST')
        check('denied permission: /start is 409 with ok=false and a permission reason', d.get('http') == 409 and d.get('ok') is False and 'permission' in d.get('msg', ''), d)
        ds = call(PF + 1, f'/status.json?t={TOK}')
        check('denied permission: no take was started', ds.get('recording') is False and ds.get('take') == '', ds)
    finally: den.terminate(); den.wait()
    # --- truth check (slow first take): healthy fake = 120 frames/2000 ms -> writtenFps 60, no alert; short fake = 33 frames/2000 ms -> 16.5 fps -> "fps short" alert
    check('healthy take: sidecar chunk has writtenFrames 120 / writtenFps 60, no fps alert', sc2['chunks'][0].get('writtenFrames') == 120 and sc2['chunks'][0].get('writtenFps') == 60.0
          and not any('fps short' in a for a in st2.get('alerts', [])) and st2.get('writtenFrames') == 120, (sc2, st2))
    shortp = subprocess.Popen([FAKE, '--port', str(PF + 2), '--token', TOK, '--dir', os.path.join(tmp, 'device-short'), '--sample', sample, '--frames', '33', '--dur-ms', '2000'])
    try:
        for _ in range(50):
            try: call(PF + 2, f'/time?t={TOK}'); break
            except Exception: time.sleep(0.1)
        call(PF + 2, f'/start?t={TOK}&label=short', 'POST'); time.sleep(0.5)
        call(PF + 2, f'/stop?t={TOK}', 'POST')
        ss = call(PF + 2, f'/status.json?t={TOK}')
        stid = ss.get('take', '')
        ssc = json.loads(urllib.request.urlopen(f'http://127.0.0.1:{PF + 2}/chunk/{stid}.json?t={TOK}').read()) if stid else {}
        ch0 = (ssc.get('chunks') or [{}])[0]
        check('short take (16.5 fps): alert "fps short: 16.5 of 60" in /status.json, warning, writtenFps in status + sidecar',
              'fps short: 16.5 of 60' in ss.get('alerts', []) and 'fps' in ss.get('warnings', {}) and ss.get('writtenFps') == 16.5 and ss.get('writtenFrames') == 33
              and ch0.get('writtenFps') == 16.5 and ch0.get('writtenFrames') == 33 and ch0.get('fpsShort') is True, (ss, ssc))
    finally: shortp.terminate(); shortp.wait()
finally:
    dirc.terminate(); fake.terminate(); dirc.wait(); fake.wait()
print('RESULT', 'RED: ' + ', '.join(fails) if fails else 'GREEN'); sys.exit(1 if fails else 0)

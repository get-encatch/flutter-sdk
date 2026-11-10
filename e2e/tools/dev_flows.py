#!/usr/bin/env python3
"""Runs the DEV flows on the installed e2e app over adb and prints what the
app reported for each one.

    python3 e2e/tools/dev_flows.py [--serial emulator-5580]

Needs: this repo's mock on port 8797 (it only collects the app's reports here),
the e2e app installed on the device, and e2e/.results/dev-project.json with the
Flutter key. It sends a handful of calls per flow to the DEV API: no bursts.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERIAL = sys.argv[sys.argv.index('--serial') + 1] if '--serial' in sys.argv else 'emulator-5580'
COLLECTOR = 'http://127.0.0.1:8797'
APP = 'com.encatch.fluttere2e'
DEV = json.load(open(os.path.join(HERE, '..', '.results', 'dev-project.json')))
FORMS = {v['id']: k for k, v in DEV['forms'].items()}


def adb(*args):
    return subprocess.run(['adb', '-s', SERIAL, *args], capture_output=True, text=True).stdout


def nodes():
    adb('shell', 'uiautomator', 'dump', '/sdcard/ui.xml')
    return re.findall(r'<node [^>]*>', adb('shell', 'cat', '/sdcard/ui.xml'))


def tap(target, wait=1.5):
    """target is a test id, or 'text:<visible text>'."""
    for node in nodes():
        hit = (f'text="{target[5:]}"' in node) if target.startswith('text:') else (f'resource-id="{target}"' in node)
        if hit:
            x1, y1, x2, y2 = map(int, re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node).groups())
            adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
            time.sleep(wait)
            return True
    return False


def survey_visible():
    return any('android.webkit.WebView' in n for n in nodes())


def set_field(test_id, value):
    tap(test_id, 0.8)
    adb('shell', 'input', 'keyevent', 'KEYCODE_MOVE_END')
    adb('shell', 'input', 'keyevent', *(['KEYCODE_DEL'] * 60))
    adb('shell', 'input', 'text', value)
    adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')  # hide the keyboard
    time.sleep(0.8)


def collector(path, method='GET'):
    req = urllib.request.Request(COLLECTOR + path, method=method, data=b'{}' if method == 'POST' else None,
                                 headers={'content-type': 'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=5).read() or b'null')


def reports():
    out = []
    for h in collector('/__mock/hooks'):
        if h.get('kind') == 'hook':
            continue  # debug-hook reports, one per request
        if h.get('kind') == 'beforeShowForm':
            out.append(f"beforeShowForm({FORMS.get(h.get('formId'), h.get('formId'))}, {h.get('trigger')})")
        else:
            form = h.get('formId')
            out.append(f"{h.get('type')}[{FORMS.get(form, form) or 'EMPTY ID'}]")
    return out


def start(visitor=False):
    adb('shell', 'am', 'force-stop', APP)
    # A fresh device id for every flow. Without this the server carries what an
    # earlier flow did on this device (a tracked event, say) into the next one.
    adb('shell', 'pm', 'clear', APP)
    collector('/__mock/reset', 'POST')
    adb('shell', 'am', 'start', '-n', f'{APP}/.MainActivity')
    time.sleep(5)
    tap('env-dev')
    set_field('setup-api-key', DEV['sdkKey'])
    set_field('setup-form-id', DEV['forms']['manual']['id'])
    tap('setup-start', 3)
    tap('visitor-button' if visitor else 'login-button', 6)


def flow(name, visitor, steps, wait, close=True):
    start(visitor)
    for step in steps:
        tap(step)
    time.sleep(wait)
    shown = survey_visible()
    before = reports()
    after_close = None
    if shown and close:
        # The survey's controls take a moment to appear to adb; retry.
        for _ in range(15):
            if tap('text:Close', 4):
                break
            time.sleep(1)
        after_close = [r for r in reports() if r not in before]
    who = 'visitor' if visitor else 'identified'
    print(f'\n== {name} ({who})')
    print(f'   survey on screen: {"yes" if shown else "NO"}')
    print(f'   app reported:     {before}')
    if after_close is not None:
        print(f'   after the X:      {after_close}')


if __name__ == '__main__':
    flow('manual showForm', False, ['tab-events', 'show-form'], 10)
    flow('page visit (dev-page)', False, ['open-dev-page'], 10)
    flow('tracked event (dev_event)', False, ['tab-events', 'track-dev-event'], 10)
    flow('immediate (dev-immediate)', False, ['open-dev-immediate'], 14)
    flow('delayed 20 s (dev-delayed)', False, ['open-dev-delayed'], 40)
    flow('manual showForm', True, ['tab-events', 'show-form'], 10)
    flow('page visit (dev-page)', True, ['open-dev-page'], 10)

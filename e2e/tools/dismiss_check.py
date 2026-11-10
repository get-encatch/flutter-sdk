#!/usr/bin/env python3
"""Checks what closing a survey sends, on the installed e2e app over adb,
against this repo's mock on port 8797 (never 8787).

    python3 e2e/tools/dismiss_check.py [--serial emulator-5580]

Cases: X on the first screen (identified), X on the first screen (visitor),
and answer + submit then X on the thank-you screen (identified).
"""
import json
import re
import time
import urllib.request

import dev_flows as d

M = d.COLLECTOR


def mock(path, method='GET'):
    req = urllib.request.Request(M + path, method=method, data=b'{}' if method == 'POST' else None,
                                 headers={'content-type': 'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=5).read() or b'null')


def start(visitor):
    d.adb('shell', 'am', 'force-stop', d.APP)
    d.adb('shell', 'pm', 'clear', d.APP)
    mock('/__mock/reset', 'POST')
    d.adb('shell', 'am', 'start', '-n', f'{d.APP}/.MainActivity')
    time.sleep(5)
    d.tap('setup-start', 3)   # the Mock environment is the default
    d.tap('visitor-button' if visitor else 'login-button', 6)
    d.tap('tab-events')
    d.tap('show-form', 9)


def summary():
    rows = []
    for e in mock('/__mock/requests?limit=200'):
        body = e.get('body') or {}
        if e['endpoint'] == 'track-event':
            rows.append(f"track-event {body.get('eventName')} {e['status']} form={'yes' if body.get('feedbackConfigurationId') else 'NO'}")
        elif e['endpoint'] in ('dismiss-form', 'submit-form', 'show-form'):
            form = body.get('formConfigurationId') or (body.get('formDetails') or {}).get('formConfigurationId') or body.get('formSlugOrId')
            rows.append(f"{e['endpoint']} {e['status']} form={'yes' if form else 'NO'}")
    events = []
    for h in mock('/__mock/hooks'):
        if h.get('kind') == 'event':
            events.append(f"{h.get('type')}[{'id' if h.get('formId') else 'EMPTY'}]")
    return rows, events


def tap_when_there(target, wait_after=4, timeout=20):
    """The survey's controls take a moment to appear to adb; retry until then."""
    end = time.time() + timeout
    while time.time() < end:
        if d.tap(target, wait_after):
            return True
        time.sleep(1)
    return False


def tap_rating(timeout=20):
    """Taps the fourth of the unlabelled rating buttons inside the survey."""
    end = time.time() + timeout
    while time.time() < end:
        inside = False
        buttons = []
        for node in d.nodes():
            if 'android.webkit.WebView' in node:
                inside = True
            if inside and 'class="android.widget.Button"' in node and 'text=""' in node:
                buttons.append(node)
        if len(buttons) >= 4:
            x1, y1, x2, y2 = map(int, re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', buttons[3]).groups())
            d.adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
            time.sleep(1.5)
            return True
        time.sleep(1)
    return False


def report(title):
    rows, events = summary()
    print(f'\n== {title}')
    print('   requests:  ', rows)
    print('   app events:', [e for e in events if 'SectionChange' not in e])


if __name__ == '__main__':
    start(visitor=False)
    closed = tap_when_there('text:Close')
    report(f'X on the first screen, identified (close tapped={closed})')

    start(visitor=True)
    closed = tap_when_there('text:Close')
    report(f'X on the first screen, visitor (close tapped={closed})')

    start(visitor=False)
    rated = tap_rating()
    submitted = tap_when_there('text:Submit', 6)
    closed = tap_when_there('text:Close')
    report(f'answer, submit, then X on the thank-you screen (rated={rated}, submit tapped={submitted}, close tapped={closed})')

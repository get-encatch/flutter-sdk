#!/usr/bin/env python3
"""Checks a stopped session across an app relaunch, and the debug hooks, on the
installed e2e app over adb, against this repo's mock on port 8797.

    python3 e2e/tools/session_check.py [--serial emulator-5580]
"""
import collections
import json
import time
import urllib.request

import dev_flows as d

M = d.COLLECTOR


def mock(path, method='GET'):
    req = urllib.request.Request(M + path, method=method, data=b'{}' if method == 'POST' else None,
                                 headers={'content-type': 'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=5).read() or b'null')


def stats():
    return {k: v['byStatus'] for k, v in mock('/__mock/stats')['byEndpoint'].items()}


def hooks():
    seen = collections.Counter()
    for h in mock('/__mock/hooks'):
        if h.get('kind') == 'hook':
            seen[f"{h.get('endpoint')}:{h.get('outcome')}" + (f"({h.get('reason')})" if h.get('reason') else '')] += 1
    return dict(seen)


def launch():
    d.adb('shell', 'am', 'start', '-n', f'{d.APP}/.MainActivity')
    time.sleep(5)
    d.tap('setup-start', 3)


if __name__ == '__main__':
    # --- 1. stop, relaunch, start again
    d.adb('shell', 'am', 'force-stop', d.APP)
    d.adb('shell', 'pm', 'clear', d.APP)
    mock('/__mock/reset', 'POST')
    launch()
    d.tap('login-button', 6)
    d.tap('tab-events')
    d.tap('stop-session', 3)
    print('before the relaunch:      ', stats())

    d.adb('shell', 'am', 'force-stop', d.APP)   # storage is kept
    mock('/__mock/reset', 'POST')
    launch()
    d.tap('visitor-button', 3)                  # no identify: that would end the stop
    time.sleep(45)                              # longer than the 30 s ping interval
    print('45 s after relaunching:   ', stats() or 'no requests at all')

    d.tap('tab-events')
    d.tap('start-session', 6)
    print('after startSession():     ', stats())

    # --- 2. the debug hooks during a burst
    mock('/__mock/reset', 'POST')
    d.tap('tab-burst')
    d.tap('burst-event-same', 6)
    d.tap('burst-event-different', 8)
    print('\nhooks, 20 identical + 20 different events:')
    print('   requests at the mock:  ', stats())
    print('   reported by the hooks: ', hooks())

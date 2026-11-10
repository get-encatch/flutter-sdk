#!/usr/bin/env python3
"""Secure identify against the DEV API, on the installed e2e app over adb.

    python3 e2e/tools/secure_flows.py [--serial emulator-5580]

For each secure test key it logs in with a valid, a wrong and no signature, and
prints whether the SDK ended up with a user id (it only gets one when the
gateway accepts the identify). Keys and secrets come from the git-ignored
e2e/.results/dev-project.json.
"""
import re
import time

import dev_flows as d


def status():
    d.tap('refresh-status', 1)
    for node in d.nodes():
        m = re.search(r'(?:text|content-desc)="(user: [^"]*)"', node)
        if m:
            return m.group(1)
    return '(status not found)'


def case(key, mode):
    d.adb('shell', 'am', 'force-stop', d.APP)
    d.adb('shell', 'am', 'start', '-n', f'{d.APP}/.MainActivity')
    time.sleep(5)
    d.tap('env-dev')
    d.set_field('setup-api-key', key['sdkKey'])
    d.set_field('setup-secret', key['secret'])
    if key['sessionTimeMinutes'] > 0:
        d.tap('setup-session-time')
    d.tap('setup-start', 3)
    d.tap(f'sig-{mode}')
    d.tap('login-button', 7)
    text = status()
    has_id = not text.rstrip().endswith('id: -')
    print(f"   {key['name']:<26} signature {mode:<6} -> identified: {'yes' if has_id else 'NO'}")


if __name__ == '__main__':
    for name in ('secureKey', 'secureSessionKey'):
        for mode in ('valid', 'wrong', 'none'):
            case(d.DEV[name], mode)

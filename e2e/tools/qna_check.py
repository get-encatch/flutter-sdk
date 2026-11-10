#!/usr/bin/env python3
"""Asks the Q&A-with-AI form on DEV a question, on the installed e2e app over
adb, and reports how the answer arrived on screen.

    python3 e2e/tools/qna_check.py [--serial emulator-5580]

Needs the `qna` form id in e2e/.results/dev-project.json. It captures the screen
about seven times a second after asking. An answer that streams makes the
screen change in several consecutive frames; one that arrives whole changes it
once.
"""
import subprocess
import time

import dev_flows as d


def screen():
    return subprocess.run(['adb', '-s', d.SERIAL, 'exec-out', 'screencap', '-p'], capture_output=True).stdout


if __name__ == '__main__':
    d.adb('shell', 'am', 'force-stop', d.APP)
    d.adb('shell', 'pm', 'clear', d.APP)
    d.adb('shell', 'am', 'start', '-n', f'{d.APP}/.MainActivity')
    time.sleep(5)
    d.tap('env-dev')
    d.set_field('setup-api-key', d.DEV['sdkKey'])
    d.set_field('setup-form-id', d.DEV['forms']['qna']['id'])
    d.tap('setup-start', 3)
    d.tap('login-button', 6)
    d.tap('tab-events')
    d.tap('show-form', 2)
    for _ in range(20):                      # the survey's controls take a moment
        if d.tap('text:Ask a question…', 3):
            break
        time.sleep(1)

    # The chat fills the screen; its input is at the bottom (1080 x 2400).
    d.adb('shell', 'input', 'tap', '480', '2256')
    time.sleep(1.5)
    d.adb('shell', 'input', 'text', 'Describe%sthe%sresponse%sdashboard%sand%sthe%sSDKs%sin%sa%sfew%ssentences')
    time.sleep(1)
    d.adb('shell', 'input', 'keyevent', 'KEYCODE_ENTER')

    start = time.time()
    frames = []
    for _ in range(120):
        frames.append((round(time.time() - start, 2), len(screen())))
    changes = [(t, n - p) for (t, n), (_, p) in zip(frames[1:], frames[:-1]) if abs(n - p) > 400]
    growth = [c for c in changes if c[0] > 1.5 and c[1] > 0]
    print('frames where the screen changed (seconds after asking, bytes):', changes)
    print(f'the answer grew over {len(growth)} frames', '(streamed)' if len(growth) > 2 else '(arrived at once)')

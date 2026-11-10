#!/usr/bin/env python3
"""Records what the installed app sends for each burst button. Mock on 8797 only."""
import json, subprocess, sys, time, urllib.request
S='emulator-5580'; M='http://127.0.0.1:8797'; TAP=sys.argv[1]
def tap(i): subprocess.run(['python3',TAP,S,i],capture_output=True)
def post(path, body=None):
    req=urllib.request.Request(M+path, data=json.dumps(body or {}).encode(), headers={'content-type':'application/json'}, method='POST')
    return urllib.request.urlopen(req, timeout=5).read()
def stats():
    d=json.loads(urllib.request.urlopen(M+'/__mock/stats',timeout=5).read())
    return {k:v['byStatus'] for k,v in d['byEndpoint'].items()}
def adb(*a): subprocess.run(['adb','-s',S,*a],capture_output=True)

adb('shell','am','force-stop','com.encatch.fluttere2e')
post('/__mock/reset')
adb('shell','am','start','-n','com.encatch.fluttere2e/.MainActivity'); time.sleep(5)
tap('setup-start'); time.sleep(3); tap('login-button'); time.sleep(5)
print('after login:', stats())
for b in ['burst-identify','burst-event-same','burst-event-different','burst-screen-same','burst-survey-screen','burst-reset-identify']:
    tap('tab-burst'); time.sleep(1.5)
    post('/__mock/reset?keepScenario=1')
    if b=='burst-survey-screen':
        post('/__mock/scenario', {'triggers':{'screens':{'/checkout':{'formId':'0190f1d2-0000-7000-8000-00000000f001'}}}})
    tap(b); time.sleep(7)
    first=stats()
    tap('text:Close'); time.sleep(1)          # close a survey if one opened
    tap('tab-events'); time.sleep(1.5); tap('track-custom-event'); time.sleep(7)
    print(f'{b}\n   within 7 s:          {first}\n   after one more call: {stats()}')
    tap('text:Close'); time.sleep(1)
reqs=json.loads(urllib.request.urlopen(M+'/__mock/requests?limit=30',timeout=5).read())
print('last requests after reset+identify:')
for e in reqs[-6:]:
    h={k.lower():v for k,v in e['headers'].items()}
    print('  ',e['endpoint'],e['status'],'name='+('yes' if h.get('x-user-name') else 'no'),'id='+('yes' if h.get('x-user-id') else 'no'))

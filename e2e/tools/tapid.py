#!/usr/bin/env python3
"""usage: tapid.py <serial> <resource-id>  -- taps the centre of that element."""
import re, subprocess, sys
serial, rid = sys.argv[1], sys.argv[2]
subprocess.run(['adb','-s',serial,'shell','uiautomator','dump','/sdcard/ui.xml'],capture_output=True)
xml = subprocess.run(['adb','-s',serial,'shell','cat','/sdcard/ui.xml'],capture_output=True,text=True).stdout
for node in re.findall(r'<node [^>]*>', xml):
    if (rid.startswith('text:') and f'text="{rid[5:]}"' in node) or f'resource-id="{rid}"' in node:
        x1,y1,x2,y2 = map(int, re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node).groups())
        subprocess.run(['adb','-s',serial,'shell','input','tap',str((x1+x2)//2),str((y1+y2)//2)])
        print('tapped', rid); sys.exit(0)
print('not found:', rid); sys.exit(1)

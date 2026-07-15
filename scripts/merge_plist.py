#!/usr/bin/env python3
"""Merge extra keys (Info-additions.plist fragment) into the iOS Info.plist."""
import plistlib
import re
import sys

additions_path, target_path = sys.argv[1], sys.argv[2]

# The additions file is a bare <dict> fragment (with comments); wrap it.
raw = open(additions_path).read()
raw = re.sub(r'<!--.*?-->', '', raw, flags=re.S).strip()
wrapped = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    f'<plist version="1.0">{raw}</plist>'
)
additions = plistlib.loads(wrapped.encode())

with open(target_path, 'rb') as f:
    target = plistlib.load(f)

target.update(additions)

with open(target_path, 'wb') as f:
    plistlib.dump(target, f)

print(f"Merged {len(additions)} keys into {target_path}")

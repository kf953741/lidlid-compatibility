#!/usr/bin/env python3
"""Generate fixed helper bundle metadata; never installs or registers it."""
from pathlib import Path
import plistlib
import sys

app, config = map(Path, sys.argv[1:3])
config.mkdir(parents=True, exist_ok=True)
group = '63ALH54858.dev.kf.lidonce'
service = group + '.sleep-service'

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))

save(app / 'Contents/Info.plist', {
    'CFBundleIdentifier': 'dev.kf.lidonce.compatibility',
    'CFBundleName': 'LidLid Compatibility',
    'CFBundleDisplayName': 'LidLid Compatibility',
    'CFBundleExecutable': 'LidLidCompatibility',
    'CFBundleIconFile': 'LidLid', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.0.2', 'CFBundleVersion': '3',
    'LSMinimumSystemVersion': '14.0', 'CFBundleDevelopmentRegion': 'en',
    'CFBundleLocalizations': ['en', 'zh-Hans'],
    'NSHumanReadableCopyright': '© 2026 Fei Kang. MIT License.'})
save(app / 'Contents/Library/LaunchDaemons' / (service + '.plist'), {
    'Label': 'dev.kf.lidonce.sleep-service',
    'BundleProgram': 'Contents/Library/HelperTools/LidLidSleepService',
    'MachServices': {service: True}, 'RunAtLoad': True, 'KeepAlive': True,
    'ProcessType': 'Background', 'ThrottleInterval': 5})
# Ad-hoc bundles are build artifacts only; XPC pins deliberately reject them.
save(config / 'service.entitlements', {'com.apple.security.application-groups': [group]})

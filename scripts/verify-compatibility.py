#!/usr/bin/env python3
"""Inspect packaging and signatures only. Does NOT register or run a root service."""
import argparse
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--release", action="store_true", help="Require Developer ID team, hardened runtime and timestamp")
parser.add_argument("--notarized", action="store_true", help="Require stapled notarization ticket and Gatekeeper acceptance")
parser.add_argument("app", type=Path)
args = parser.parse_args()

app = args.app.resolve()
binary = app / 'Contents/MacOS/LidLidCompatibility'
service = app / 'Contents/Library/HelperTools/LidLidSleepService'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
app_archs = sorted(subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split())
service_archs = sorted(subprocess.check_output(['lipo', '-archs', str(service)], text=True).split())
assert app_archs == service_archs, f'Architecture mismatch: app={app_archs} daemon={service_archs}'
if args.release or args.notarized:
    assert app_archs == ['arm64', 'x86_64'], f'Release compatibility bundle must be Universal (arm64 + x86_64); found {app_archs}'
    for target in (app, service):
        info_txt = subprocess.check_output(['codesign', '-dvv', str(target)], stderr=subprocess.STDOUT, text=True)
        assert 'TeamIdentifier=63ALH54858' in info_txt, f'Missing production team on {target}:\n{info_txt}'
        assert 'Authority=Developer ID Application:' in info_txt, f'Developer ID required on {target}:\n{info_txt}'
        assert '(runtime)' in info_txt, f'Hardened runtime missing on {target}:\n{info_txt}'
        assert 'Timestamp=' in info_txt, f'Secure timestamp missing on {target}:\n{info_txt}'
if args.notarized:
    subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
    subprocess.run(['spctl', '-a', '-vv', str(app)], check=True)
expected_group = '63ALH54858.dev.kf.lidonce'
for path in [app, service]:
    entitlements = plistlib.loads(subprocess.check_output(
        ['codesign', '-d', '--entitlements', '-', '--xml', str(path)], stderr=subprocess.DEVNULL))
    assert entitlements == {'com.apple.security.application-groups': [expected_group]}, entitlements
    assert not entitlements.get('com.apple.security.app-sandbox')
plist = plistlib.loads((app / ('Contents/Library/LaunchDaemons/' + expected_group + '.sleep-service.plist')).read_bytes())
assert plist['MachServices'] == {expected_group + '.sleep-service': True}
assert plist['BundleProgram'] == 'Contents/Library/HelperTools/LidLidSleepService'
assert plist['KeepAlive'] and plist['RunAtLoad']
subprocess.run([str(service), '--self-test'], check=True)
print(f'Compatibility packaging passed ({", ".join(app_archs)}); no daemon registration or power setting changes')

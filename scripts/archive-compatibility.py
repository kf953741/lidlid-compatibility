#!/usr/bin/env python3
"""Archive a verified Universal LidLid Compatibility bundle with matching dSYMs.

Prepares a clean .xcarchive for Direct Distribution notarization in Xcode Organizer.
Does not upload, open Xcode, install services, or access credentials.
"""
import argparse
import datetime
import plistlib
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
parser.add_argument('--app', type=Path, default=ROOT / 'dist/LidLid Compatibility.app')
parser.add_argument('--output', type=Path)
parser.add_argument('--organizer', action='store_true', help='Copy the new archive into the local Xcode Organizer directory')
args = parser.parse_args()
app = args.app.resolve()
subprocess.run(['python3', str(ROOT / 'scripts/verify-compatibility.py'), '--release', str(app)], check=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
assert re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version) and build.isdigit(), 'Invalid archive version'

app_bin = app / 'Contents/MacOS/LidLidCompatibility'
daemon_bin = app / 'Contents/Library/HelperTools/LidLidSleepService'
main_archs = sorted(subprocess.check_output(['lipo', '-archs', str(app_bin)], text=True).split())
daemon_archs = sorted(subprocess.check_output(['lipo', '-archs', str(daemon_bin)], text=True).split())
assert main_archs == ['arm64', 'x86_64'] and daemon_archs == ['arm64', 'x86_64'], (
    f'Compatibility archive must be Universal (arm64 + x86_64); found app={main_archs} daemon={daemon_archs}'
)

archive = (args.output or ROOT / f'.build/compatibility-signing/LidLidCompatibility-{version}-{build}-universal.xcarchive').resolve()
if archive.exists():
    parser.error(f'Archive already exists; keep it intact and choose another output: {archive}')

signature = subprocess.run(['codesign', '-dv', '--verbose=2', str(app)], capture_output=True, text=True, check=True).stderr
identity = next(line.removeprefix('Authority=') for line in signature.splitlines() if line.startswith('Authority='))
team = next(line.removeprefix('TeamIdentifier=') for line in signature.splitlines() if line.startswith('TeamIdentifier='))
now = datetime.datetime.now(datetime.timezone.utc)
organizer = Path.home() / 'Library/Developer/Xcode/Archives' / now.astimezone().strftime('%Y-%m-%d') / archive.name
if args.organizer and organizer.exists():
    parser.error(f'Organizer archive already exists; it was not replaced: {organizer}')

(archive / 'Products/Applications').mkdir(parents=True)
subprocess.run(['ditto', str(app), str(archive / 'Products/Applications/LidLid Compatibility.app')], check=True)
metadata = {
    'ApplicationProperties': {
        'ApplicationPath': 'Applications/LidLid Compatibility.app',
        'Architectures': main_archs,
        'CFBundleIdentifier': info['CFBundleIdentifier'],
        'CFBundleShortVersionString': version,
        'CFBundleVersion': build,
        'SigningIdentity': identity,
        'Team': team,
    },
    'ArchiveVersion': 2,
    'CreationDate': now.replace(tzinfo=None),
    'Name': 'LidLid Compatibility',
    'SchemeName': 'LidLid Compatibility',
}
(archive / 'Info.plist').write_bytes(plistlib.dumps(metadata))

def slice_uuids(path):
    lines = subprocess.check_output(['dwarfdump', '--uuid', str(path)], text=True).splitlines()
    return sorted((line.split()[1], line.split()[2]) for line in lines if line.startswith('UUID:'))

for rel, name in [
    ('MacOS/LidLidCompatibility', 'LidLidCompatibility.app.dSYM'),
    ('Library/HelperTools/LidLidSleepService', 'LidLidSleepService.dSYM'),
]:
    source, symbols = app / 'Contents' / rel, archive / 'dSYMs' / name
    symbols.parent.mkdir(exist_ok=True)
    subprocess.run(['dsymutil', str(source), '-o', str(symbols)], check=True)
    binary_uuids = slice_uuids(source)
    symbols_uuids = slice_uuids(symbols)
    assert binary_uuids and binary_uuids == symbols_uuids, f'Symbol UUID mismatch for {name}: {binary_uuids} vs {symbols_uuids}'

subprocess.run(['codesign', '--verify', '--deep', '--strict', str(archive / 'Products/Applications/LidLid Compatibility.app')], check=True)
if args.organizer:
    organizer.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', str(archive), str(organizer)], check=True)
    print(organizer)
else:
    print(archive)

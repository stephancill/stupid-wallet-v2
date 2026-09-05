"""Install this Mac's development-signed helper; never alters the Apple account or stupid-app."""
import argparse
import datetime
import fnmatch
import json
import os
import pathlib
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--profile', required=True)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
profile = pathlib.Path(args.profile).resolve()

def run(arguments):
    result = subprocess.run(arguments, capture_output=True)
    if result.returncode:
        raise SystemExit('Local helper operation failed: ' + arguments[0])
    return result.stdout

info = plistlib.loads(run(['security', 'cms', '-D', '-i', str(profile)]))
ent = info['Entitlements']
assert 'OSX' in info['Platform'], 'A macOS development profile is required'
assert info['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Profile expired'
app_id = ent['com.apple.application-identifier']
prefix = info['ApplicationIdentifierPrefix'][0] + '.'
assert app_id.startswith(prefix) and '*' not in app_id
app_group = 'group.co.za.stephancill.stupid-wallet'
key_group = '6JKMV57Y77.co.za.stephancill.stupid-wallet'
assert app_group in ent.get('com.apple.security.application-groups', [])
assert any(fnmatch.fnmatchcase(key_group, value) for value in ent.get('keychain-access-groups', []))
credentials = pathlib.Path.home() / '.stupid-app/credentials'
certificate = credentials / 'development.cert.pem'
der = run(['openssl', 'x509', '-in', str(certificate), '-outform', 'DER'])
assert der in info['DeveloperCertificates'], 'Profile does not authorize available certificate'
identity = run(['openssl', 'x509', '-in', str(certificate), '-noout', '-fingerprint', '-sha1']).decode().strip().split('=')[1].replace(':', '')
base = pathlib.Path.home() / 'Library/Application Support/StupidWalletChrome'
base.mkdir(parents=True, exist_ok=True)
stage = base / 'StupidWalletChromeHost.staging.app'
assert not stage.exists(), 'Remove the previous failed staging bundle after inspecting it'
contents = stage / 'Contents'
(contents / 'MacOS').mkdir(parents=True)
shutil.copy2(root / '.build/debug/StupidWalletChromeHost', contents / 'MacOS/StupidWalletChromeHost')
shutil.copy2(profile, contents / 'embedded.provisionprofile')
(contents / 'Info.plist').write_bytes(plistlib.dumps(dict(
    CFBundleIdentifier=app_id[len(prefix):], CFBundleExecutable='StupidWalletChromeHost',
    CFBundlePackageType='APPL', CFBundleName='Stupid Wallet Chrome Helper',
    CFBundleVersion='5', CFBundleShortVersionString='0.0.5', LSUIElement=True,
    LSMinimumSystemVersion='14.0', NSFaceIDUsageDescription='Authenticate a reviewed wallet request.'
)))
resolved = { 'com.apple.application-identifier': app_id,
    'com.apple.developer.team-identifier': info['TeamIdentifier'][0],
    'com.apple.security.application-groups': [app_group], 'keychain-access-groups': [key_group] }
entitlements = base / 'local.entitlements'
entitlements.write_bytes(plistlib.dumps(resolved)); entitlements.chmod(0o600)
run(['codesign', '--force', '--sign', identity, '--entitlements', str(entitlements), '--timestamp=none', str(stage)])
run(['codesign', '--verify', '--strict', str(stage)])
installed = base / 'StupidWalletChromeHost.app'
previous = base / 'StupidWalletChromeHost.previous.app'
if previous.exists(): shutil.rmtree(previous)
if installed.exists(): installed.rename(previous)
stage.rename(installed)
config = json.loads((root / 'ChromeExtension/development-identity.json').read_text())
manifest = dict(name=config['hostName'], description='Stupid Wallet local macOS helper',
    path=str(installed / 'Contents/MacOS/StupidWalletChromeHost'), type='stdio', allowed_origins=[config['allowedOrigin']])
registration = pathlib.Path.home() / 'Library/Application Support/Google/Chrome/NativeMessagingHosts' / (config['hostName'] + '.json')
registration.parent.mkdir(parents=True, exist_ok=True)
temporary = registration.with_suffix('.json.new')
temporary.write_text(json.dumps(manifest, indent=2) + '\n'); os.replace(temporary, registration)
print('Local helper installed and signature verified. Reload the Chrome extension.')

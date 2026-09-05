"""Package a Developer ID Chrome beta; never fall back to development signing."""
import argparse
import datetime
import fnmatch
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEAM = '6JKMV57Y77'
BUNDLE = 'co.za.stephancill.stupid-wallet.extension'
APP_GROUP = 'group.co.za.stephancill.stupid-wallet'
KEY_GROUP = TEAM + '.co.za.stephancill.stupid-wallet'


def run(arguments):
    return subprocess.check_output(arguments, stderr=subprocess.STDOUT)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', required=True, type=pathlib.Path)
    parser.add_argument('--identity', required=True, help='Developer ID Application SHA-1 fingerprint')
    args = parser.parse_args()
    profile = plistlib.loads(run(['security', 'cms', '-D', '-i', str(args.profile)]))
    ent = profile['Entitlements']
    if not (profile.get('ProvisionsAllDevices') is True and not profile.get('ProvisionedDevices')
            and 'OSX' in profile['Platform'] and profile['TeamIdentifier'] == [TEAM]
            and profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
            and ent.get('com.apple.application-identifier') == TEAM + '.' + BUNDLE
            and APP_GROUP in ent.get('com.apple.security.application-groups', [])
            and any(fnmatch.fnmatchcase(KEY_GROUP, group) for group in ent.get('keychain-access-groups', []))
            and not ent.get('get-task-allow') and not ent.get('com.apple.security.get-task-allow')):
        raise SystemExit('Profile does not authorize the expected unrestricted Mac distribution identity and stores.')
    if args.identity.upper() not in [hashlib.sha1(cert).hexdigest().upper() for cert in profile['DeveloperCertificates']]:
        raise SystemExit('Profile does not authorize this signing certificate.')
    identities = run(['security', 'find-identity', '-v', '-p', 'codesigning']).decode()
    if not any(args.identity.upper() in line and 'Developer ID Application:' in line for line in identities.splitlines()):
        raise SystemExit('A usable Developer ID Application identity is required.')
    output = ROOT / '.release/chrome'
    output.mkdir(parents=True, exist_ok=True)
    stage = pathlib.Path(tempfile.mkdtemp(prefix='stage-', dir=output))
    app = stage / 'StupidWalletChromeHost.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    executable = ROOT / '.build/release/StupidWalletChromeHost'
    if run(['lipo', '-archs', str(executable)]).decode().strip() != 'arm64':
        raise SystemExit('This beta supports Apple Silicon only.')
    shutil.copy2(executable, contents / 'MacOS/StupidWalletChromeHost')
    shutil.copy2(args.profile, contents / 'embedded.provisionprofile')
    (contents / 'Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier=BUNDLE, CFBundleExecutable='StupidWalletChromeHost',
        CFBundlePackageType='APPL', CFBundleName='Stupid Wallet Chrome Helper',
        CFBundleVersion='5', CFBundleShortVersionString='0.0.5', LSUIElement=True,
        LSMinimumSystemVersion='14.0', NSFaceIDUsageDescription='Authenticate a reviewed wallet request.')))
    licenses = contents / 'Resources/Licenses'
    licenses.mkdir(parents=True)
    shutil.copy2(ROOT / 'THIRD_PARTY_NOTICES.md', licenses)
    shutil.copy2(ROOT / 'third-party/libsecp256k1/COPYING', licenses / 'libsecp256k1.txt')
    resolved = {'com.apple.application-identifier': TEAM + '.' + BUNDLE,
                'com.apple.developer.team-identifier': TEAM,
                'com.apple.security.application-groups': [APP_GROUP],
                'keychain-access-groups': [KEY_GROUP]}
    entitlements = stage / 'signing.entitlements'
    entitlements.write_bytes(plistlib.dumps(resolved))
    run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--timestamp',
         '--entitlements', str(entitlements), str(app)])
    run(['codesign', '--verify', '--strict', str(app)])
    submission = output / 'helper-notarization.zip'
    run(['ditto', '-c', '-k', '--keepParent', str(app), str(submission)])
    # Explicit paths only: never package build directories, credentials, or development profiles.
    extension = ROOT / '.build/chrome-extension'
    manifest = json.loads((extension / 'manifest.json').read_text())
    extension_zip = output / ('stupid-wallet-chrome-' + manifest['version'] + '.zip')
    with zipfile.ZipFile(extension_zip, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(extension.iterdir()):
            if not path.is_file() or path.suffix not in {'.js', '.json', '.html', '.css', '.png'}:
                raise SystemExit('Unexpected generated extension entry: ' + path.name)
            archive.write(path, path.name)
        archive.write(ROOT / 'THIRD_PARTY_NOTICES.md', 'LICENSES/THIRD_PARTY_NOTICES.md')
        archive.write(ROOT / 'ChromeExtension/node_modules/zod/LICENSE', 'LICENSES/zod.txt')
    (output / 'staging.json').write_text(json.dumps({'app': str(app), 'extension': str(extension_zip)}, indent=2))
    print('Signed helper staged for notarization; extension ZIP prepared. No release published.')


if __name__ == '__main__':
    main()

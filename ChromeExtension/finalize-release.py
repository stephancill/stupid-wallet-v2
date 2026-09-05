"""Staple an accepted notarization and assemble the public helper archive."""
import hashlib
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
output = root / '.release/chrome'
state = json.loads((output / 'staging.json').read_text())
app = pathlib.Path(state['app'])
subprocess.run(['xcrun', 'stapler', 'staple', str(app)], check=True)
subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
subprocess.run(['spctl', '--assess', '--type', 'execute', str(app)], check=True)
package = app.parent / 'stupid-wallet-chrome-helper'
package.mkdir()
shutil.copytree(app, package / app.name)
for file in ['install-release.command', 'RELEASE-INSTALL.md']:
    shutil.copy2(root / 'ChromeExtension' / file, package / file)
archive = output / 'stupid-wallet-chrome-helper-0.0.5-macos-arm64.zip'
subprocess.run(['ditto', '-c', '-k', '--keepParent', str(package), str(archive)], check=True)
shutil.copy2(root / 'ChromeExtension/RELEASE-INSTALL.md', output / 'RELEASE-INSTALL.md')
files = [archive, pathlib.Path(state['extension']), output / 'RELEASE-INSTALL.md']
(output / 'SHA256SUMS').write_text(''.join(
    hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n' for path in files))
print('Public archives and checksums ready. Only these four deliverables should be uploaded.')

#!/bin/bash
set -euo pipefail
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'This beta requires an Apple Silicon Mac.' >&2
  exit 1
fi
source_dir="$(cd "$(dirname "$0")" && pwd)"
source_app="$source_dir/StupidWalletChromeHost.app"
/usr/bin/codesign --verify --strict -R='anchor apple generic and identifier "co.za.stephancill.stupid-wallet.extension" and certificate leaf[subject.OU] = "6JKMV57Y77" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$source_app"
/usr/sbin/spctl --assess --type execute "$source_app"
base="$HOME/Library/Application Support/StupidWalletChrome"
registration_dir="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$base" "$registration_dir"
stage="$(mktemp -d "$base/install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$source_app" "$stage/StupidWalletChromeHost.app"
/usr/bin/codesign --verify --strict "$stage/StupidWalletChromeHost.app"
# Retain the prior bundle, allowing repair without touching wallet data.
if [[ -e "$base/StupidWalletChromeHost.app" ]]; then
  backup="$(mktemp -d "$base/previous.XXXXXX")"
  mv "$base/StupidWalletChromeHost.app" "$backup/"
fi
mv "$stage/StupidWalletChromeHost.app" "$base/StupidWalletChromeHost.app"
manifest="$stage/net.stupidtech.stupid_wallet.json"
/usr/bin/plutil -create xml1 "$manifest"
/usr/bin/plutil -insert name -string net.stupidtech.stupid_wallet "$manifest"
/usr/bin/plutil -insert description -string 'Stupid Wallet macOS helper' "$manifest"
/usr/bin/plutil -insert path -string "$base/StupidWalletChromeHost.app/Contents/MacOS/StupidWalletChromeHost" "$manifest"
/usr/bin/plutil -insert type -string stdio "$manifest"
/usr/bin/plutil -insert allowed_origins -json '["chrome-extension://pnefobbcijpfceblkkcbfklpldfhmbof/"]' "$manifest"
/usr/bin/plutil -convert json "$manifest"
mv "$manifest" "$registration_dir/net.stupidtech.stupid_wallet.json"
echo 'Helper installed. Reload the Chrome extension, then open Manage Chrome pairing.'

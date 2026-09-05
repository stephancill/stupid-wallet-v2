# Stupid Wallet Chrome beta

Requires an Apple Silicon Mac running macOS 14 or later, Google Chrome 111 or later,
and the Stupid Wallet TestFlight app installed and set up on that same Mac. Chrome 127+
can open review automatically. Wallet data does not synchronize from an iPhone.

1. Download and extract both release ZIPs into permanent locations.
2. Open Terminal, type `bash `, drag `install-release.command` from the helper folder into
   Terminal, and press Return. Do not use sudo. The installer verifies the signed,
   notarized helper and installs it for your macOS user.
3. Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select
   the extracted Chrome extension folder containing `manifest.json`. Keep that folder.
4. Pin stupid wallet in Chrome. Open its popup, choose **Manage Chrome pairing**, and
   compare the codes in Chrome and the native confirmation before approving pairing.
5. Connect a dapp. Review each request in the toolbar popup and complete macOS authentication
   for each signature. Closing the popup leaves the request pending; reopen it to decide.

This prerelease is distributed as an unpacked extension, not through the Chrome Web Store.
Its fixed extension identity preserves local beta pairing across updates when the same
extension is reloaded. To update, install the new helper, replace files in the existing
extension directory, and click Reload in `chrome://extensions`.

The installer retains a previous helper bundle under your user's
`Library/Application Support/StupidWalletChrome`. It does not change the wallet app,
Safari extension, wallet keys, App Group data, or existing pairing. Quit Chrome before
updating so an older helper process cannot remain active.

To remove the Chrome integration, remove the extension in Chrome and delete only
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/net.stupidtech.stupid_wallet.json`
and `~/Library/Application Support/StupidWalletChrome`. Use Manage Chrome pairing to revoke
pairing before removing the extension. Removing these helper files leaves wallet data intact.

Connection, message signing, typed-data signing, rejection, navigation cancellation, pairing,
and browser restart have local acceptance evidence. Broader transaction/batch, lock/sleep,
multi-profile, mixed-process, and clean-machine acceptance remain open. This is beta software.

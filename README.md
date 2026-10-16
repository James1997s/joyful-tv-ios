# Joyful TV for iPhone

This is the iOS 15+ port of the supplied Joyful Live IPTV 2.32 Android project. It is tuned for touch on the 4.7-inch iPhone 7 display and supports portrait and landscape rotation.

## Startup and WARP gate

On launch, the app loads or installs the supplied Cloudflare WARP-compatible WireGuard tunnel and starts it before making any signup, mailbox, IPTV-login, or catalog request. The app waits for iOS to report the tunnel connected and then checks Cloudflare’s trace endpoint for `warp=on` or `warp=plus`. If the user declines the iOS VPN prompt, the tunnel fails, or Cloudflare does not confirm WARP, the app stops and offers a retry; it does not continue to fetch credentials.

The first connection can display an iOS system VPN approval prompt. A jailbreak can change how an IPA is installed or signed, but it does not guarantee bypass of iOS VPN configuration consent or Network Extension requirements.

The WARP profile is intentionally committed in this public repository at the owner’s direction. It contains a WireGuard private key; anyone can read the key from the public source history and use it until it is rotated. The built, unencrypted IPA also contains the same profile.

## Included behavior

- Trial enrollment using the existing `https://joyful.watch/trial/` form and ThrowawayMail API (`POST /api/mailboxes`, message polling, email confirmation).
- 24-hour credential retention in iOS Keychain.
- Xtream-compatible account validation and Live TV categories/channels.
- Search, favorites, refresh, HLS stream URL construction, AVPlayer playback, and short EPG preview when the provider supports it.
- Large touch targets, scrollable live-channel list, and portrait/landscape support.

The first port focuses on the Android app’s Live-TV-only path. Its Android-only WorkManager background renewal has no direct equivalent here; renewal is available from the app while it is open. The full XMLTV guide and Android-TV remote-control features are not part of this initial iOS port.

## GitHub Actions build

The repository workflow `.github/workflows/ios-ipa.yml` builds an **unsigned IPA** using GitHub’s macOS runner. This is suited to a jailbroken device with an installer that accepts unsigned/ad-hoc packages. It is not an App Store or TestFlight artifact and cannot be installed on a stock iPhone without a valid signing identity/provisioning profile.

Manual equivalent on macOS:

```bash
cp Sources/WireGuardApp/Config/Developer.xcconfig.template Sources/WireGuardApp/Config/Developer.xcconfig
# Put a local WARP profile at Sources/WireGuardApp/UI/iOS/warp_profile.conf.
brew install go swiftlint
xcodebuild -project WireGuard.xcodeproj -target WireGuardiOS -configuration Release -sdk iphoneos \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
mkdir -p build/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/WireGuard.app build/Payload/
(cd build && zip -qr JoyfulTV-iOS-unsigned.ipa Payload)
```

## Build limits

This sandbox is Linux and does not include Xcode. The native device build is performed by the GitHub-hosted macOS workflow, not locally in the sandbox. An iPhone 7/iOS 15.8.4 runtime test still requires installing the resulting IPA on the device.

## Upstream WireGuard licensing

The WireGuardKit and packet-tunnel implementation are based on the official [WireGuard for Apple platforms](https://github.com/WireGuard/wireguard-apple) project and its MIT license. Its copyright and license files remain in this repository.

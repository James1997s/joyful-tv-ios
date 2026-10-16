# Joyful TV for iPhone

This is the iOS 15+ port of the supplied Joyful Live IPTV 2.32 Android project. The guide and player are tuned for touch on iPhone 7 and support portrait and landscape rotation.

## WARP and network behavior

The app attempts to start and verify its WARP-compatible WireGuard tunnel on launch. The **WARP ON/OFF** control is available in the guide and while a video is playing. If WARP is off or cannot connect, a valid saved IPTV login can still load the channel list, guide metadata, and streams. WARP is required before the app creates a temporary mailbox, submits the trial form, polls verification/account emails, or requests new credentials. If WARP drops during that flow, the credential request is stopped.

The first connection can display an iOS system VPN approval prompt. A jailbreak changes how an IPA may be installed or signed; it does not guarantee bypass of iOS VPN configuration consent or Network Extension requirements.

The WARP profile is intentionally committed in this public repository at the owner’s direction. It contains a WireGuard private key; anyone can read it from the public source history and use it until it is rotated. The unencrypted IPA also contains the profile.

## Playback and guide

- Full-screen, touch-first VLC playback via [MobileVLCKit 3.7.4](https://github.com/videolan/vlckit/tree/3.7.4), a stable prebuilt iOS framework with a minimum iOS version of 9.0.
- Uses provider direct-source/container metadata when available, tries the selected HLS (`.m3u8`) or TS (`.ts`) mode first, then tries alternate stream URLs, and performs up to three exponential-backoff retries. The **Video: HLS/TS** guide control changes the preferred mode.
- VLC supports substantially more stream containers and codecs than AVPlayer, but no player can guarantee every IPTV feed: provider outages, malformed streams, DRM, unsupported codec profiles, and iPhone 7 decoding limits can still prevent playback.
- Xtream-compatible validation, Live TV categories/channels, search, favorites, refresh, and short EPG preview when supported by the provider. The portal is `http://kytv.xyz`; credentials sent to that host are not protected by TLS on that leg. WARP encrypts the device-to-WARP leg only.
- Trial enrollment uses the existing `https://joyful.watch/trial/` form and the [Mail.tm API](https://docs.mail.tm/). The bearer token stays in memory, and the temporary mailbox is deleted after credentials arrive. The app displays a Mail.tm attribution link during this flow.
- Verification-link and account-credential extraction supports plain-text and HTML-array messages, including compact one-line messages and the `user` label used by the original Android app. IPTV credentials are retained in iOS Keychain for 24 hours.

## Third-party license

MobileVLCKit 3.7.4 is distributed under the [GNU LGPL v2.1](https://github.com/videolan/vlckit/blob/3.7.4/COPYING). The full license is included in the public source at `ThirdPartyNotices/MobileVLCKit-LGPL-2.1.txt` and bundled in the app as `MobileVLCKit-LICENSE.txt`. Corresponding source is available at the [VideoLAN 3.7.4 source tag](https://github.com/videolan/vlckit/tree/3.7.4); the framework is used unmodified.

The WireGuardKit and packet-tunnel implementation are based on the official [WireGuard for Apple platforms](https://github.com/WireGuard/wireguard-apple) project and its MIT license, which remains in this repository.

## GitHub Actions build

The workflow `.github/workflows/ios-ipa.yml` builds an **ad-hoc-signed IPA** on GitHub’s macOS runner, installs MobileVLCKit through CocoaPods, and embeds the packet-tunnel/app-group entitlements required by WireGuard. It is intended for a jailbreak installer that accepts ad-hoc signatures and preserves those entitlements. It is not an App Store, TestFlight, or stock-iPhone installation package.

For a local build on macOS:

```bash
brew install go swiftlint cocoapods
pod install
xcodebuild -workspace WireGuard.xcworkspace -scheme WireGuardiOS \
  -destination 'generic/platform=iOS' -configuration Release -sdk iphoneos \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

GitHub Actions is the canonical packaged build because it also performs entitlement signing and IPA packaging.

## Build limits

The current sandbox is Linux and does not include Xcode. The native iOS build therefore runs on the GitHub-hosted macOS workflow. Testing playback and rotation still requires installing the resulting IPA on an iPhone 7/iOS 15.8.4 device.

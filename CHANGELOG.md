# Changelog

All notable changes to Hermesi Push for iOS. This file describes what a consumer gets.

**`0.x` means the public API can still change.** A minor bump may contain a breaking change; a patch bump will
not. Each release lists breaking changes first.

## 0.2.0 (2026-10-04)

- **Pictures.** A new product, `HermesiNotificationService`, for a notification service extension: it reads the picture's URL
  from the payload (`image_url`, or Firebase's `fcm_options.image`), downloads it (`https` only, JPEG, PNG or GIF, at most
  5 MB, 20 seconds) and attaches it. Any failure delivers the notification as text. See "Pictures" in the README.

## 0.1.0 (2026-10-04)

First release.

- `HermesiPush`: `register`, `tokenDidChange`, `unregister`, `isRegistered`, `actionURL(userInfo:)`, and
  `requestAuthorization`.
- `PushToken`: `.apns(Data)` and `.fcm(String)`; the transport (`apns` or `fcm`) follows the kind of token.
- `HermesiClient`: registers and removes a push device against Hermesi's client API.
- `HermesiNotificationDelegate`: shows notifications that arrive while the app is open and opens a tapped
  notification's link.
- A tapped notification opens only `http`, `https` and the app's own listed deep link schemes.

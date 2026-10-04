# Hermesi Push for iOS

Register an iPhone or iPad for push notifications sent by [Hermesi](https://github.com/hermesihq), and show them. A
small Swift package that takes the push token your app already has, from Apple or from Firebase, and keeps it
registered with Hermesi as it changes.

- Registers and unregisters the device, and keeps it registered when the token rotates.
- Works with **both roads**: an APNs token (your app talks to Apple directly) or a Firebase token. Hermesi sends a
  device through the provider that speaks its transport, and the SDK sets it from the kind of token you pass.
- Shows notifications that arrive while the app is open, and opens a tapped notification's link safely.
- No dependencies, no method swizzling, no Firebase version of its own.

iOS 13 and later. Swift concurrency (`async`/`await`).

## Before you start

1. In Hermesi, configure a push provider: **Apple Push Notification service** if your app uses APNs directly, or
   **Firebase Cloud Messaging** if it uses Firebase (Providers screen).
2. Your app already gets a push token (`registerForRemoteNotifications`, or Firebase Messaging).
3. Your backend can mint a **subscriber token** for the signed-in person, as it does for the web SDK. The SDK never has
   your secret key; it asks your backend for the token each time it talks to Hermesi.

## Install

Swift Package Manager: in Xcode, **File > Add Package Dependencies** and enter
`https://github.com/hermesihq/ios`, or in `Package.swift`:

```swift
.package(url: "https://github.com/hermesihq/ios", from: "0.1.0")
```

## Set up

**1. Create one `HermesiPush` and keep it** for the life of the app:

```swift
import HermesiPush

let client = HermesiClient(options: HermesiClientOptions(
    publicKey: "hm_pk_...",                              // safe to ship in an app
    apiBaseURL: "https://your-hermesi-host/v1/client",
    subscriberToken: { try await backend.mintHermesiToken() }   // calls YOUR backend
))
let push = HermesiPush(client: client, options: HermesiPushOptions(deepLinkSchemes: ["myapp"]))
```

**2. Ask for permission, at a moment you choose** (not at launch), then hand the token over when iOS delivers it:

```swift
// from a button, after explaining why
let granted = try await HermesiPush.requestAuthorization()

// in your app delegate
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task {
        // Registers if the person is signed in; ignored by tokenDidChange otherwise
        try await push.tokenDidChange(.apns(deviceToken))
    }
}
```

`tokenDidChange` registers the new token and retires the old one, but only if this device was registered before:
before the person signs in there is no subscriber to register it for.

**3. Register when the person signs in**, with the token you have:

```swift
try await push.register(.apns(deviceToken), metadata: ["plan": "pro"])   // metadata is optional
```

Calling it again is safe and is what puts a device back after Hermesi had marked it invalid.

**4. Unregister when they sign out:**

```swift
try await push.unregister()
```

### With Firebase instead of APNs

Pass the Firebase registration token, and the SDK sets the transport to match:

```swift
func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    guard let fcmToken else { return }
    Task { try await push.tokenDidChange(.fcm(fcmToken)) }
}
try await push.register(.fcm(token))
```

**Do not send an APNs token as `.fcm`, or the reverse.** Firebase refuses an APNs token as invalid, which reads as a
dead device and removes it.

## Showing notifications

iOS draws a notification itself when the app is in the background and draws nothing when it is open, unless your
`UNUserNotificationCenterDelegate` asks it to. `HermesiNotificationDelegate` does that, and opens the link of a
notification the person taps:

```swift
let delegate = HermesiNotificationDelegate(push: push)    // keep a strong reference: the center holds it weakly
UNUserNotificationCenter.current().delegate = delegate
```

If your app already has a delegate, call `push.actionURL(userInfo:)` from its `didReceive` instead, and return
`[.banner, .list, .sound, .badge]` from `willPresent` yourself. Set `showInForeground: false` in
`HermesiPushOptions` to show nothing while the app is open.

## Links

A notification can carry a link, which arrives in the payload under `action_url`. It comes from a template, not from your
app, so only some schemes are opened: `http` and `https`, and the deep link schemes you list in `deepLinkSchemes`.
Anything else (`file`, `javascript`, `tel`, `data`) is dropped. A string that is not already a valid URL is refused, not
repaired.

## What it sends to Hermesi

The device is stored with `platform: ios`, `transport: apns` or `fcm`, `os_version`, `app_version`, `sdk`, and
whatever metadata you passed. `platform` and `transport` are always set by the SDK: the transport is how Hermesi chooses
the provider that can reach the device, and an app that overrode it would send its devices to one that cannot.

## Errors

- `HermesiAPIError`: Hermesi refused the request. Branch on `code`; `isRetryable` is true for a server error or rate
  limiting.
- `URLError`: Hermesi could not be reached.
- Both are thrown from `register`, `tokenDidChange` and `unregister`.

## What it does not do

It does not show notification images: APNs has no image field, and the picture reaches the screen only through a
notification service extension in your app, which reads the `image_url` Hermesi puts in the payload. It does not draw
an inbox, and it does not cover Android (see [hermesihq/android](https://github.com/hermesihq/android)).

## Building

```
swift test
```

runs on Linux and macOS. The core is plain Foundation and is tested on Linux; the notification delegate needs UIKit and
is compiled by the iOS builds in CI. The tests do not cover a real device, a real APNs or Firebase project, or the
system's permission prompt: that needs a person with an app.

## License

MIT

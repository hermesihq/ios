# Sample app

A one-screen iOS app that registers itself with Hermesi and shows what arrives. It exists so that someone with a Mac and an
iPhone can see the whole path work, and so that the SDK's calls are visible in one short file (`Model.swift`).

It uses the package from this repository. An app of your own depends on the Swift Package Manager URL in the main README.

**What this does not test for you**: nothing here has been run on a device by the people who wrote it. CI checks that the
sample compiles; the SDK's tests cover the logic, the network calls and the decisions the notification delegate makes. This
is how you check the part they cannot, with a real APNs key and a real notification.

## What you need

1. **Hermesi running**, with an environment, its **public key** (`hm_pk_...`) and its **secret key** (`hm_sk_...`).
2. **An Apple Push Notification service provider** configured in Hermesi (Providers screen, push channel): your team id, the
   key id and the `.p8` key, and the bundle id of this sample, `io.github.hermesihq.push.example`. Set **Use sandbox** to
   `true`, because a build you run from Xcode gets a development token, and Apple refuses it on the production host. See
   `docs/provider-setup.md` in Hermesi.
3. **A Mac with Xcode 15 or later**, and an Apple Developer account for the signing team (push needs the capability).
4. **A physical iPhone** is the reliable way. The simulator can receive push on a Mac with Apple silicon or a T2 chip.
5. **Node 18 or later** for the token server, and `xcodegen` (`brew install xcodegen`).

## Run it

**1. Start the token server.** A subscriber token proves to Hermesi which person a device belongs to and is signed with your
secret key, so it must come from a backend. This stands in for yours:

```bash
cd Example/token-server
HERMESI_SECRET_KEY=hm_sk_... HERMESI_ENVIRONMENT_ID=env_... node server.mjs
```

It mints a token for **anyone who asks**, so it listens on `127.0.0.1` only. Never expose it. For a physical phone start it
with `HOST=0.0.0.0` on a network you trust.

**2. Generate the Xcode project and open it:**

```bash
cd Example
xcodegen
open HermesiPushExample.xcodeproj
```

In Xcode, choose the **Example** target, then **Signing & Capabilities**, and pick your team. Push Notifications is already
declared. Run it on your device.

**3. Fill in the screen**:

| Field | Simulator | Physical phone |
| --- | --- | --- |
| Hermesi client API | `http://localhost:8010/v1/client` | `http://<your Mac>:8010/v1/client` |
| Public key | `hm_pk_...` | same |
| Token server | `http://localhost:8787` | `http://<your Mac>:8787` |
| Subscriber | any external id, for example `user_1` | same |

**4. Tap the steps in order**: *Allow notifications* (the system asks, then iOS gets a push token), then *Register this
device*. The log shows what happened, or Hermesi's error code if it refused. Hermesi should now list the device under the
subscriber, with `platform: ios` and `transport: apns`.

**5. Send a notification.** In Hermesi, make a template with a **Push** tab (a title and a body; for the link, set `action_url`
to `sample://orders/4821` or any `https` URL) and a workflow with a push step, then trigger it for your subscriber:

```bash
curl -X POST http://localhost:8010/v1/events \
  -H "Authorization: Bearer hm_sk_..." -H "Content-Type: application/json" \
  -d '{"name": "your.event", "recipient": "user_1"}'
```

## What to look for

- **App in the background**: iOS draws the notification. Tap it: the app opens and the log says which link it was asked to open.
- **App open**: iOS draws nothing by itself, and `HermesiNotificationDelegate` shows a banner. Tap it: same.
- **A link the app did not allow** (`file://...`, `javascript:...`, `tel:...`) is dropped, not opened. The sample allows `http`,
  `https` and `sample`.
- **Unregister**, then send again: nothing arrives. **Register** again: it does.
- **Token change**: delete the app and install it again, allow notifications, register, and look at the subscriber in Hermesi:
  one device, not two stale ones.

## If it does not work

- The log shows `iOS could not get a push token`: the capability or the signing team is missing, or the simulator is on a Mac
  that cannot receive push.
- `Hermesi refused: ...`: the code says why. `invalid_device_registration` or `unknown_device_transport` mean Hermesi rejected
  what the app sent.
- The device registers but nothing arrives, and the message in Hermesi failed with `sender_misconfigured` or `BadDeviceToken`:
  **Use sandbox** in Hermesi's APNs provider is set wrongly for this build (true for Xcode builds, blank for TestFlight and
  the App Store).

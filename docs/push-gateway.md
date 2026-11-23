# Shared push gateway

Moss registers for remote notifications with the shared APNs gateway that the
other iOS apps also use. The gateway contract (installation registration,
account unbinding and `PushEvent v1`) is the same in every app and every
app's copy of this document must agree. Moss's application identifier is
`moss`, and its APNs topic and bundle identifier are `app.getmoss.moss`.

## Registration

The transport is selected from `Config/Secrets.xcconfig`:

- `PUSH_GATEWAY_URL` empty: register the device with the Moss API
  (`POST /api/devices`, unbind with `DELETE /api/devices`).
- `PUSH_GATEWAY_URL` set: register the installation with the gateway.

Exactly one transport is active, and the app never writes to both. Inject the
gateway URL through the private `Config/Secrets.xcconfig`/CI configuration like
the other app values. Never commit credentials. `PUSH_GATEWAY_APPLICATION_ID`
stays `moss` in every environment.

The app sends the gateway:

- a stable Keychain-backed installation ID;
- the raw APNs token as lowercase hexadecimal;
- the APNs environment;
- the current Better Auth bearer token.

The gateway validates that session against the Moss API and derives the
principal from it; one installation has exactly one current principal. Sign-out
and account deletion unbind the installation before the session is invalidated;
a failed unbind does not block sign-out, and the next registration rebinds.

## Notifications

Moss has no server-originated push event yet; a tap simply opens the app. A
future feature (trip reminders, shared-trip updates) must define its consent,
schedule, routing in `PushAppConfiguration.route(for:)` and `PushEvent v1`
source.

## Checks

- **Unit tests** cover:
  - configuration parsing;
  - the register and unregister request shapes;
  - installation-ID persistence;
  - lifecycle ordering;
  - transport selection.
- **Physical-device checks:** sandbox and TestFlight (production APNs)
  registration and delivery; logout; failed logout; account switch; token
  refresh; two devices; denied permission; background and terminated delivery.

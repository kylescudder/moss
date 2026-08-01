# Moss

**Travel, together**

Moss is a native iOS travel companion: a calm place to plan upcoming journeys, keep travel details together, and build toward shared trips, places, notes, photos, and memories over time.

- SwiftUI, iOS 17+
- XcodeGen project generation
- Supabase Auth and Postgres backend
- StoreKit 2 subscription scaffold
- Settings for profile, appearance, notifications, subscriptions, sign-out, and account deletion
- Static Astro marketing and legal site under `Site/`

## Current Scope

This is the first native scaffold. The implemented domain starts with the core travel objects:

- trips
- itinerary items and places
- profile
- device tokens
- subscription entitlements

The product should be able to grow naturally into shared trips, maps, restaurants, hotels, flights, notes, photos, journals, packing, expenses, and recommendations without changing the Moss brand.

## Setup

```sh
./setup.sh
```

Then edit `Config/Secrets.xcconfig`:

```xcconfig
SUPABASE_URL = https:/$()/your-project-ref.supabase.co
SUPABASE_ANON_KEY = your-anon-key
```

Apply the backend schema:

```sh
supabase link --project-ref <ref>
supabase db push
```

Generate/open the app:

```sh
xcodegen generate
open Moss.xcodeproj
```

Pull requests receive an unsigned simulator build, and iOS changes merged to
`main` are archived and uploaded to TestFlight. See
[`docs/ci-testflight.md`](docs/ci-testflight.md) for the one-time signing and
GitHub secrets setup.

Run the site:

```sh
bun run dev
```

## Supabase Auth

Enable Email, Apple, and Google in Supabase Auth. Moss uses Apple's native Authentication Services flow and presents Google OAuth through the secure system authentication session. Provider secrets belong in the Supabase dashboard, never in the app or `Secrets.xcconfig`.

Use this redirect URL:

```text
moss://auth-callback
```

Add that URL to the Supabase Auth redirect allow list. Configure the native app ID `app.getmoss.moss` as an accepted Apple client ID. For Google, create a web OAuth client and use Supabase's callback URL (`https://<project-ref>.supabase.co/auth/v1/callback`) as its authorized redirect URI.

## Subscription

The StoreKit product scaffold uses:

```text
app.moss.supporter.monthly
```

Create the matching auto-renewable subscription in App Store Connect before TestFlight/App Store builds. The local StoreKit config lets simulator builds exercise the purchase flow.

Free accounts receive two trip creations over the lifetime of the account. Every
committed creation increments that usage, including trips created while a
subscription is active; deleting a trip does not restore a free creation.

The Edge Functions verify StoreKit 2 transaction and notification JWS payloads
with Apple's App Store Server Library before updating the database entitlement.
Configure these additional Edge Function secrets:

```text
APPLE_APP_ID=<numeric App Store Connect app ID>
APPLE_BUNDLE_ID=app.getmoss.moss
APPLE_IAP_ENVIRONMENTS=Production,Sandbox
```

`APPLE_BUNDLE_ID` and `APPLE_IAP_ENVIRONMENTS` have the displayed defaults.
Production verification requires `APPLE_APP_ID`. Xcode-local StoreKit
transactions are intentionally not accepted by the production mirror.

## App Icon

The editable Liquid Glass source is `Moss/AppIcon.icon`. Open it with Xcode's **Open Developer Tool → Icon Composer** to preview the default, dark, clear, and tinted appearances and tune the live material effects. The mark is a deliberately simple moss-ball silhouette with one broad highlight, so it remains legible from a 16-point favicon to large-format artwork. The same canonical SVG construction is used by the app icon, in-app logo, and website mark; Icon Composer adds depth, refraction, shadow, and motion-responsive specular highlights without changing the identity itself.

## Backend Layout

```text
supabase/
  config.toml
  migrations/
  powersync/
  templates/
  functions/
    iap-app-store-notifications/
    iap-sync-transaction/
```

The IAP functions mirror verified App Store transaction state into Supabase.
Configure `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and the Apple values above
as Edge Function secrets before deploying them.

Run backend checks with:

```sh
deno test --config supabase/functions/deno.json --allow-env \
  supabase/functions/_shared/apple-iap.test.ts
supabase test db
```

The database suite includes a two-connection concurrency test and requires the
local Supabase stack's `pgtap` and `dblink` extensions.

## App Layout

```text
Moss/
  App/              entry point, root view, services
  Auth/             Supabase auth screens/client
  Billing/          StoreKit subscription flow
  Components/       shared SwiftUI primitives
  Itineraries/      today and itinerary item flows
  Models/           Codable app models
  Notifications/    push permission and token upload
  Settings/         settings/profile
  Trips/            trip list/detail/create flows
  Utilities/        logging and formatting helpers
```

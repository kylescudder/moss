# roam

Native iOS trip and itinerary planner, patterned after Deadwax Club and Diald:

- SwiftUI, iOS 17+
- XcodeGen project generation
- Supabase Auth and Postgres backend
- StoreKit 2 subscription scaffold
- Settings for profile, appearance, notifications, subscriptions, sign-out, and account deletion
- Static marketing site under `web/`

## Current scope

This is the first native scaffold for the itinerary port. The actual `kylescudder/itinerary` source repo was not present in this workspace, so the implemented domain starts with the core travel objects:

- trips
- itinerary items
- profile
- device tokens
- subscription entitlements

Once the source repo is available locally, use it to complete exact parity for any existing itinerary-specific flows, APIs, maps, collaboration, exports, or AI planning behavior.

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
open roam.xcodeproj
```

## Supabase Auth

Enable Email in Supabase Auth. Apple and Google buttons are present in the native UI, but their native token exchange still needs final provider configuration once the Apple Services ID and Google OAuth client are known.

Use this redirect URL:

```text
roam://auth-callback
```

## Subscription

The StoreKit product scaffold uses:

```text
club.roam.supporter.monthly
```

Create the matching auto-renewable subscription in App Store Connect before TestFlight/App Store builds. The local StoreKit config lets simulator builds exercise the purchase flow.

## Backend layout

```text
supabase/
  config.toml
  migrations/
  functions/
    iap-sync-transaction/
```

The `iap-sync-transaction` function currently mirrors the signed transaction into Supabase. Production should verify the App Store JWS and persist transaction IDs, expiry, revocation, and environment.

## App layout

```text
roam/
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


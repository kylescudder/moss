# Moss

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

Run the site:

```sh
bun run dev
```

## Supabase Auth

Enable Email in Supabase Auth. Apple and Google buttons are present in the native UI, but their native token exchange still needs final provider configuration once the Apple Services ID and Google OAuth client are known.

Use this redirect URL:

```text
moss://auth-callback
```

## Subscription

The StoreKit product scaffold uses:

```text
app.moss.supporter.monthly
```

Create the matching auto-renewable subscription in App Store Connect before TestFlight/App Store builds. The local StoreKit config lets simulator builds exercise the purchase flow.

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

The IAP functions mirror decoded App Store transaction state into Supabase. Configure `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` as Edge Function secrets before deploying them.

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

# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## Project

Moss — native iOS 17+ SwiftUI travel companion for planning trips, keeping day-by-day itineraries (flights, stays, food, activities, transport and notes) together, and seeing what's on today, plus a static Astro marketing and compliance site. The backend is the Bun API in `Backend/` with PostgreSQL and self-hosted PowerSync on Herman, StoreKit provides the Supporter subscription, and the app includes AppIntents and a WidgetKit extension.

## Shared conventions

Every iOS app uses the same repository layout, app scaffolding and CI. Read
`Scripts/SHARED_IOS_CORE.md` before adding folders, shared UI primitives,
configuration keys or workflows. Six checksum manifests keep shared files
byte-for-byte identical with the other iOS apps, and CI runs all of them.
Never name another app in this repository; shared files read app values from
hooks:

- `Scripts/check-shared-ios-core.sh` — `AppSecrets`, `AppBootstrap`, `Theme`, `LoadingView`, `LottieAnimationView`, `PrimaryButton`, `Logger`, `AppearanceManager`, `Card`, `EmptyState`, `PushAuthorizationRow`, `AppDelegate`, `QuickActionRouter`, `AppGroupStore`, the shared sign-in views (`SignInView`, `ForgotPasswordSheet`, `ResetPasswordSheet`, `AppleSignInButton`), the billing core (`BillingRepository`, `SubscriptionAccessState`, `CreationQuotaProviding`, `SubscriptionPaywallView`), the sync core (`PowerSyncManager`, `APIConnector`, `SyncIssueStore`), the `Shared*Tests`, `setup.sh` and the iOS workflows.
- `Scripts/check-shared-auth.sh` — Better Auth backend and native auth (`SHARED_AUTH.md`).
- `Scripts/check-shared-push-core.sh` — push registration core and its adapters (`PushManager`, `PushRegistration`, `AuthClient+PushIdentity`; `SHARED_PUSH_CORE.md`).
- `Scripts/check-shared-infra.sh` — backend deployment and provisioning (`SHARED_INFRA.md`).
- `Scripts/check-shared-site.sh` — the `Site/` layout, tooling, image and site workflows (`SHARED_SITE.md`).
- `Scripts/check-shared-sharing-core.sh` — the sharing core (`SharingModels`, `SharingRepository`, `ShareMembersSections`, `SharedSharingTests`; `SHARED_SHARING_CORE.md`), shared only with the other apps that let people share data. The app's spaces live in `Sharing/SharingAppConfiguration.swift`.

Never edit a shared file in one app only. Put app-specific values behind the
hooks listed in `SHARED_IOS_CORE.md` (`Theme+App.swift`, `AuthAppConfiguration`,
`BillingAppConfiguration`, `SyncAppConfiguration`, `PushAppConfiguration`,
`AppQuickAction`, `WidgetSnapshotStore`, `project.yml`,
`Scripts/setup-extras.sh`), or make the same change in every app and refresh
the manifest with `sh Scripts/check-shared-ios-core.sh --write`.

## Common commands

The Xcode project is generated from `project.yml` and is git-ignored — regenerate after any source, target, signing, or dependency change.

```sh
xcodegen generate                          # rebuild Moss.xcodeproj from project.yml
open Moss.xcodeproj                        # open in Xcode (⌘R to run, ⌘B to build)
xcodebuild build \                         # CLI sanity build (no signing required)
  -project Moss.xcodeproj \
  -scheme Moss \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Moss.xcodeproj -scheme Moss -destination 'platform=iOS Simulator,name=iPhone 16'
./setup.sh                                 # first-run tools, secrets template, backend deps, xcodegen
```

Marketing site:

```sh
bun run dev                                # installs Site dependencies and starts Astro
bun run build                              # builds the static site to Site/dist
bun run preview                            # previews the production build
cd Site && bun run format:check            # check Astro/CSS formatting with Prettier
```

`MossTests` contains focused trip-creation, quota, widget and model tests; `Shared*Tests.swift` are identical in every app. Every test file imports the app as `@testable import AppUnderTest`, which the test target's `-module-alias AppUnderTest=Moss` flag in `project.yml` maps to the `Moss` module. There is no iOS linter or formatter configured. The Astro site has `format` and `format:check` scripts under `Site/package.json`; don't invent additional validation commands.

## Backend

Production runs on Herman. The runtime is `Backend/` (Bun 1.4.4, TypeScript,
PostgreSQL/Drizzle, Better Auth, Brevo and self-hosted PowerSync) on Herman's
shared PostgreSQL server. Read `Backend/deploy/README.md` before release work.
Merging a `Backend/` change to `main` releases the API, migrations, Compose files
and PowerSync config together through deploy-core.

- Native builds require `API_URL`, `POWERSYNC_URL`, optional `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST` (TestFlight takes these from the `POSTHOG_PROJECT_TOKEN` secret and `POSTHOG_HOST` variable).
- `AuthClient` uses `APIClient` and a Keychain session, binds cached data to the
  original UUID, and preserves SQLite/queues for reauthentication. Only
  "Sign out and remove local data" and account deletion clear local data; never
  use them as a silent reauthentication path.
- `APIConnector` is the upload boundary. Restricted runtime transactions enforce
  owner RLS, lifetime quota, durable UUID replay rules and tombstones.
- The app opens `moss.sqlite` (one file per account, chosen by the shared sync core).
- JWT `sub` is the original UUID, issuer is `BETTER_AUTH_URL`, audience is the
  exact public `POWERSYNC_URL`. Sync config is `Backend/deploy/powersync/`.
- Drizzle migrations are under `Backend/drizzle/`. All authoritative tables have
  statement and deferred COMMIT recovery guards; the API cannot refresh the lease.
- Verified IAP endpoints are `/api/iap/transactions` and `/api/iap/notifications`.
  Cryptographic Apple verification is in `Backend/src/apple-verification.ts`.
- Moss-specific API errors use `MX` codes: `MX001` free trip limit, `MX002`
  signed out, `MX003` invalid or foreign record, `MX004` account import
  incomplete, `MX005` invalid entitlement. The shared `native-oauth.ts` still
  answers `DX002` for an unauthenticated code exchange.

Backend checks: `cd Backend && bun install --frozen-lockfile`, `bun run typecheck`,
`bun run lint`, `bun run format:check`, `TEST_DATABASE_URL=... bun test`,
`bun run build`. Tests require a disposable PostgreSQL database and create/drop
additional fixture databases. Never point them at production. Native runtime and
screenshots require a functioning simulator; build-only checks are not flow proof.

## Push notifications

Before changing push registration, APNs delivery, `device_tokens` or notification
producers, read `docs/push-gateway.md` and keep its provider-neutral HTTP contract
identical across all application repositories.

## Secrets and configuration

- iOS build values live in `Config/Secrets.xcconfig` (git-ignored, copied from `Config/Secrets.xcconfig.example`) and flow through generated `Info.plist` properties into `Moss/App/AppSecrets.swift`. **xcconfig escaping gotcha**: write a URL such as `https://…` as `https:/$()/…`, otherwise `//` starts a comment. `API_URL` is required for auth and the API, `POWERSYNC_URL` is required for data sync, and an empty `POSTHOG_PROJECT_TOKEN` intentionally disables PostHog.
- `AppSecrets` detects empty, unresolved, and placeholder API and PowerSync values. Keep those graceful configuration-error paths intact; simulator and pull-request builds deliberately use the example xcconfig.
- Backend secrets (database URLs, Better Auth, Brevo, Apple sign-in and IAP verification) live in the API's protected `api.env` on Herman; `Backend/deploy/api.env.example` lists them.
- The committed `Moss/Resources/StoreKit/Moss.storekit` supplies simulator product data. App Store Connect remains authoritative for TestFlight and production product `app.moss.supporter.monthly`.

## Architecture

### iOS app composition

- `MossApp` creates one `@StateObject AppServices`, injects it with `environmentObject`, installs `AppDelegate` for APNs registration callbacks, applies the saved appearance, and configures PostHog through `AppBootstrap`.
- `AppServices` (`Moss/App/AppServices.swift`) is the composition root. It owns `AuthClient`, `PowerSyncManager`, `SyncIssueStore`, `BillingRepository`, `TripsRepository`, `ItineraryRepository`, `PushManager`, `ProfileRepository` and the two `SharingRepository` instances (`tripSharing`, `librarySharing`). It re-broadcasts each child's `objectWillChange`, so views can observe the single environment object, and replaces the account repositories through `sync.accountDatabaseDidChange` when the signed-in account changes.
- `RootView` switches on auth state (`.unknown` / `.signedOut` / `.signedIn`) and handles password-recovery presentation, sync issues and incoming URLs. The signed-in `MainTabView` is Today / Trips / Settings.
- On sign-in, `AppServices.applyAuth` starts the profile, trip, itinerary and sharing watches, activates push, synchronizes StoreKit entitlements and refreshes local snapshots. Subscription state is `.active` only after both local StoreKit verification and server confirmation succeed; mirror delays remain `.verifying`. On sign-out it ends the push session, stops the watches and resets in-memory subscription state.
- New trip creation must continue through `AppServices.canCreateNewTrip()`: non-subscribers may create two lifetime trips, including deleted ones, while edits and itinerary items remain unlimited. It prefers the API's `/api/trips/status` (backed by `get_trip_creation_status`) and falls back offline to synced quota/entitlement rows plus the device-only `pending_trips` ledger. The insert trigger remains the transactional authority.

### Data access and PowerSync

- `PowerSyncManager`, `APIConnector` and `SyncIssueStore` are the shared sync core (rules in `Scripts/SHARED_IOS_CORE.md`, tests in `SharedSyncTests`). Moss's schema is `Moss/Sync/DatabaseSchema.swift`; its filename, offline-owner query, writable tables (`profiles`, `trips`, `itinerary_items`), `MX` codes and `pending_trips` replay rules are in `Moss/Sync/SyncAppConfiguration.swift`, and its issue copy in `SyncIssueStore+App.swift`.
- `TripsRepository`, `ItineraryRepository` and `ProfileRepository` read through `database.watch` and write locally through PowerSync. `APIConnector` is the only generic upload path (`/api/sync/upload`). Quota status, IAP mirroring, auth, APNs device registration, and account deletion are deliberate direct API calls (`/api/trips/status`, `/api/iap/transactions`, `/api/auth/*`, `/api/devices`, `/api/account`).
- `ItineraryRepository` watches every item of the account once; trip detail and Today filter it (`items(for:)`, `todaysItems()`). Items of a soft-deleted trip are hidden locally by a join on `trips.deleted_at`.
- Trip maps resolve plan location text (and transport endpoints) with Apple Maps on demand. `visited_at` is a nullable timestamp on itinerary items; owners/editors mark progress manually and viewers read it. The narrow repository patch preserves other plan fields, and all existing `select *` sync streams include it. Deploy migration `0009_plan-visits` and the API before the native release. Transport route overlays use MKDirections.calculate for each transport plan’s resolved From/To, selected travel mode and departure time. Only returned route geometry is drawn; unsupported or unavailable routes are surfaced with retry and an Open in Apple Maps action, never a straight-line fallback. No device location or background route tracking is used.
- Plan photos are bounded JPEG attachments in `itinerary_items.photos_json` (three per plan, 120,000 bytes each). `PlanPhoto` downsamples to at most 1600 pixels and re-encodes without source metadata. The API validates the JSON and bounds it to 500,000 bytes; the row inherits itinerary RLS, tombstones and every existing `select *` sync stream. Deploy migration `0008` and the API (1 MiB request limit) before releasing the native feature. Photos are resized copies, not original-resolution file storage.
- PowerSync tables are SQLite views, so use plain parameterized inserts/updates rather than Postgres `ON CONFLICT` SQL locally. A replayed trip `put` for a trip that already exists is accepted without re-running the quota trigger.
- Known permanent Postgres validation failures are acknowledged and surfaced through `SyncIssueStore`, allowing PowerSync to restore server state instead of blocking the queue forever. Transient/network failures must throw so PowerSync retries them. Do not broaden permanent-error classification without proving the error cannot succeed on retry.
- Sync rules are Edition 3 (`Backend/deploy/powersync/sync-config.yaml`). They sync profile, trip and itinerary item tombstones, plus read-only owner-scoped quota and verified-entitlement snapshots. `pending_trips` is local-only and reserves allowance until the server quota stream confirms an accepted insertion.
- Postgres schema lives in ordered Drizzle migrations under `Backend/drizzle/`. `profiles`, `trips`, `itinerary_items` and `device_tokens` are protected by RLS; trips and items are readable by anyone the trip is shared with (see Sharing), and an itinerary item's `owner_id` is always its trip's owner (`MX003`). `trip_creation_quotas` is the protected monotonic counter, while `trip_creation_events` is the durable per-trip ledger. Clients read usage only through `get_trip_creation_status` behind `/api/trips/status`. `iap_entitlements` is written only by the API's verified IAP paths through `record_verified_iap_entitlement`.
- Trips and itinerary items use soft-delete tombstones (`deleted_at`); repository reads filter them out and delete actions set the timestamp.
- UUID strings sent to the API are lowercased throughout. Swift model coding keys, Postgres columns, enum raw values (`ItineraryItemKind` ↔ the `kind` check constraint), API/function return shapes, and PowerSync rules must be updated together when a persisted field changes.

### Sharing

- Moss uses the shared sharing core (`Scripts/SHARED_SHARING_CORE.md`, tests in `SharedSharingTests`) with two spaces declared in `Moss/Sharing/SharingAppConfiguration.swift`: `.trip` (`trip_members`, `trip_pending_invites`, one trip) and `.library` (`library_members`, `library_pending_invites`; the space ID is the owner's profile ID, so a member sees every trip that account owns, including future ones). Every trip and every profile has an `owner` member row, created by triggers.
- Roles: owners and editors change the trip and its plans; viewers only read; only the owner deletes a trip or changes who it's shared with. `AppServices.role(for:)` (`Moss/Sharing/TripAccess.swift`) takes the stronger of the trip and library roles and decides what the UI offers; RLS (`trip_role`, `can_read_trip`, `can_edit_trip`) and the `guard_shared_trip_update` trigger enforce it. A viewer's change is refused with `MX003`, so the queue drops it and PowerSync restores the server row.
- Itinerary items always carry the trip owner's `owner_id`, whoever adds them, so each sync stream is a single-level subquery (`member_*` through `trip_members`, `library_*` through `library_members`). Pending invites sync to the space's owner only. `SyncAppConfiguration.offlineOwnerQuery` ignores shared trips so other people's rows never look like a second offline account.
- Membership tables are read-only to the API role. Changes go through `POST /api/sharing/<trip|library>/<invite|remove_member|revoke_invite|member_profiles|incoming|accept|decline>` (`Backend/src/sharing.ts`), backed by the `share_*` security-definer functions in `Backend/drizzle/0004_sharing-access.sql` and `0005_invite-acceptance.sql`. Their refusals use `MX006` (invalid invite, 422) and `MX007` (not the owner, 403) with messages the app shows as-is.
- Inviting never adds anyone. Every invite waits in `*_pending_invites`; after the transaction commits the API emails the invitee (shared `invite` email kind, linking to `https://growmoss.app/invites`, which opens the app's invites sheet). Only a signed-in account whose verified email matches can list (`incoming`), accept or decline it, so forwarded emails and leaked IDs give nothing away. A failed or rate-limited email leaves the invite usable in the app. The shared email sender keeps invite mail to half the daily email budget (the rest is reserved for sign-in and reset mail) and 20 invite emails per sender a day, counted in `auth_email_limit` so revoking or re-sending can't reset it.
- `AppServices.sharingInbox` (shared `SharingInbox`) merges trip and all-trips invites. `ShareInvitesSection` sits at the top of the Trips list and Share all trips; `RootView` presents `ShareInvitesView` for the invite link and refreshes invites on foreground.
- The trip detail's Share button opens `TripSharingView`; Settings › Sharing opens `AllTripsSharingView`, which also lists what others share with this account and lets the user leave.

### Authentication and profiles

- `AuthClient` owns the single `APIClient` session and exposes the app's auth state. It supports email/password, native Sign in with Apple, Google through `ASWebAuthenticationSession`, email confirmation, password recovery, and account deletion (`DELETE /api/account`).
- `SignInView`, `ForgotPasswordSheet`, `ResetPasswordSheet` and `AppleSignInButton` are shared; Moss's logo, title, tagline and recovery exit are in `AuthAppConfiguration.swift`. `SignUpView` (with its display name) stays Moss-only.
- All auth callbacks use the `moss://auth-callback` custom scheme and enter through `QuickActionRouter.handle(url:auth:)` (in `App/AppQuickAction.swift`).
- The `initialize_profile` trigger creates a profile for each new auth user. `/api/profile/name` fills an empty display name (Apple only provides a name on the first authorization) without overwriting a user-edited value.

### Subscriptions

Complimentary billing access follows `Scripts/SHARED_IOS_CORE.md`; see
`docs/complimentary-access.md` for the administrator grant and revoke procedure.

- `BillingRepository`, `SubscriptionAccessState` and `SubscriptionPaywallView` are the shared billing core (rules in `Scripts/SHARED_IOS_CORE.md`, tests in `SharedBillingTests`). Moss's values (`app.moss.supporter.monthly`, the verification message and paywall copy) live in `Moss/Billing/BillingAppConfiguration.swift`, and the paywall reads the lifetime trip count through `AppServices.creationQuota` (`TripsRepository`).
- Purchase calls include the signed-in user UUID as `appAccountToken`. Verified transactions are mirrored to `/api/iap/transactions`; App Store Server Notifications V2 update the same `iap_entitlements` row through `/api/iap/notifications`. Never restore payload-only decoding or direct client writes.
- The free limit is `AppServices.freeTripLimit == 2`. The `trips` insert trigger seeds and atomically increments `trip_creation_quotas` for every genuine insert, so soft or hard deletion never restores allowance. Any change to the limit or what counts as a trip creation must update the database trigger, status function, client gate, tests, paywall copy and the site's legal pages together.

### Reminders and notifications

- `PushManager` is the shared `@MainActor` push singleton (`Scripts/SHARED_PUSH_CORE.md`). It owns authorization status, is the `UNUserNotificationCenter` delegate, and registers APNs tokens (with the API's `/api/devices`, or the shared push gateway when `PUSH_GATEWAY_URL` is set; see `docs/push-gateway.md`). Moss's values are in `Moss/Notifications/PushAppConfiguration.swift`; a tapped notification has no route yet, so it just opens the app.
- `AppDelegate` (shared) only forwards APNs registration success/failure to `PushManager`. Keep UIKit delegate work at this boundary.
- Moss has no reminders or server-originated push producer yet.

### Widgets, shortcuts, and deep links

- `MossWidgets` contains the Next Trip widget. The extension never calls the backend; `AppServices.publishWidgetSnapshot()` writes a Codable snapshot of dated data (current and upcoming trips, plus itinerary items for the next `WidgetSnapshotStore.itemHorizonDays` days) to app-group `UserDefaults` (`group.app.moss`) through the shared `AppGroupStore` and reloads the `MossNextTripWidget` timeline. The timeline has an entry at each of the next seven midnights, and each entry derives its trip and "today" from the snapshot (`NextTripSnapshot.focusTrip(on:)`, `items(on:)`), so it stays correct while the app is closed. Never store a pre-rendered day in the snapshot.
- Links use `moss://shortcut/newTrip` and `moss://shortcut/today`. The shared `QuickActionRouter` replays an action that arrived before launch finished, but it does so as soon as `RootView` appears, while auth may still be bootstrapping. So `AppQuickAction.route()` hands the action to `QuickActionInbox`, which keeps it until `MainTabView` subscribes to `actions`, then delivers it once (switch tab or present `TripEditorView`). Don't route quick actions through `NotificationCenter`: a post before the tabs exist is lost.
- AppIntents (`NewTripIntent`, `ShowTodayIntent`) route through the same `QuickActionRouter` and set `openAppWhenRun = true`. Keep widgets, AppIntents, URL path names and `AppQuickAction` raw values synchronized.
- `Site/public/.well-known/apple-app-site-association` and the `applinks:growmoss.app` entitlement (with the previous domain retained during migration) are in place for future universal links.

### Marketing site

- `Site/` is a static Astro site in the shared site layout (`Scripts/SHARED_SITE.md`). The shared `BaseLayout` owns global CSS, document metadata, header, and footer; the home page composes focused `Home*` section components, while privacy, terms, and support wrap their copy in the shared `LegalArticle`. Moss's values (name, origin, pages, contact, app links) live in `Site/app.json`.
- The site has no runtime configuration or backend. Merging a `Site/` change to `main` builds an attested image and deploys it to Herman through deploy-core at the `DEPLOY_HOST` repository variable (`release-site.yml`).
- Legal and support copy is part of the product behavior contract. Update it whenever authentication providers, analytics/error reporting, subscriptions, data sharing, retention, or support contact behavior changes.

### Other notable wiring

- `Log` (`Moss/Logging/Logger.swift`) is the OSLog/PostHog wrapper. Errors and warnings go to PostHog error tracking; breadcrumbs (and `Log.event`) become PostHog exception steps attached to every error and crash report, never sent alone. The apps share one PostHog project: every event carries `app`, and distinct IDs are `<bundle ID>:<user ID>` (`AnalyticsApp` in `App/AppBootstrap.swift`). PostHog is a no-op when `POSTHOG_PROJECT_TOKEN` is empty; keep repository and service errors going through `Log` rather than ad hoc prints.
- `Theme`, `Card`, `PrimaryButton`, `EmptyState` and `LoadingView` under `Moss/Components/` are the shared UI primitives. Reuse them before introducing one-off colors, spacing, or loading treatments. Moss's brand colors (`moss`, `lichen`), loading animation (`moss_spinner.lottie`) and `Theme.CardStyle` (roomy, full-width, borderless `Card`) live in `Theme+App.swift`; otherwise use the shared semantic colors (`textPrimary`, `textSecondary`, `accent`, `separator`).
- The app and widget must retain the same `group.app.moss` app-group entitlement. The main app additionally has Sign in with Apple, Associated Domains and APNs entitlements.
- The app is iOS/iPadOS 17+, portrait-only on iPhone, and supports all standard orientations on iPad. `Info.plist` is committed (XcodeGen rewrites it with sorted keys); `project.yml` layers generated properties, secrets, URL schemes, and background modes onto it.
- GitHub Actions regenerates the Xcode project. Pull requests get an unsigned simulator build; pushes to `main` that touch iOS paths archive and upload to TestFlight using manual signing.

## Strict concurrency

`SWIFT_STRICT_CONCURRENCY: complete` is set in `project.yml`. Services and repositories are generally `@MainActor`, and notification delegate callbacks use `nonisolated` only where the protocol requires it. When introducing work across actor boundaries, use `Sendable` values and explicit actor hops; don't silence compiler findings with `@unchecked Sendable` without a concrete thread-safety justification.

## SDK drift

The dependency lower bounds live in `project.yml`; generated Xcode package state is not committed. Areas most likely to need coordinated changes after an update:

- **PowerSync Swift SDK** — local schema/view behavior, typed CRUD payloads, status streams, transaction APIs, and disconnect/clear semantics converge under `Moss/Sync/` and the local repositories. Re-test permanent rejection acknowledgement and quota-trigger retry idempotency after updates.
- **StoreKit 2** — `Product.purchase`, verification results, entitlement iteration, transaction JWS access, subscription management, and the committed StoreKit configuration must remain aligned with `BillingRepository`.
- **Swift strict concurrency / iOS SDKs** — `UNUserNotificationCenterDelegate`, `ASWebAuthenticationSession`, AppIntents, WidgetKit timelines, and UIKit callbacks can gain isolation requirements between toolchains.
- **Astro / Prettier** — site dependencies are pinned through `Site/bun.lock`; keep the lockfile with intentional updates and run both the production build and `format:check`.

Dependency versions match the other iOS apps so the shared files compile against the same SDKs; bump them in every app together. When an SDK bump breaks compilation, check the dependency's release notes and update the shared abstraction rather than scattering compatibility workarounds across views.

## Folder casing

The app folders are `Moss/`, `MossTests/` and `MossWidgets/`, the marketing site is `Site/` (capital S), the backend is `Backend/`, and the only lowercase top-level folders are `docs/` and `deploy/`. Always preserve those spellings in code, scripts, workflow paths, and documentation so the repository works on case-sensitive filesystems.

## What not to commit

`Config/Secrets.xcconfig`, `.env*`, `Moss.xcodeproj/`, `build/`, `DerivedData/`, `.build/`, `.swiftpm/`, `Package.resolved`, `Site/node_modules/`, `Site/.astro/`, `Site/dist/`, or signing certificates/provisioning profiles. These are already git-ignored where applicable; don't add overrides.

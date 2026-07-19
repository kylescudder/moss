# iOS TestFlight CI

GitHub Actions builds Moss for iOS and uploads it to TestFlight on every push
to `main` that touches the app source. The workflow can also be run manually
from the Actions tab. Pull requests that touch the app get a separate unsigned
simulator build.

The workflows live at [`.github/workflows/ios-testflight.yml`](../.github/workflows/ios-testflight.yml)
and [`.github/workflows/ios-build.yml`](../.github/workflows/ios-build.yml).

## One-time setup

### 1. App Store Connect API key

1. In App Store Connect, open Users and Access -> Integrations -> App Store
   Connect API -> Generate API Key.
2. Give the key `App Manager` access.
3. Download the `.p8` file and record its Issuer ID and Key ID.

### 2. Signing identifier and capabilities

Create the App ID `app.getmoss.moss` under the same team as `APPLE_TEAM_ID`. Enable the
capabilities used by `Moss/Moss.entitlements`:

- App Groups, including `group.app.moss`
- Associated Domains
- Push Notifications
- Sign in with Apple

Create an App Store provisioning profile for `app.getmoss.moss` with the exact display
name `Moss App Store`. Export an Apple Distribution certificate as a
password-protected `.p12` file.

### 3. GitHub secrets

Add these repository secrets under Settings -> Secrets and variables -> Actions:

| Secret name | Value |
|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | Full contents of the `AuthKey_XXXXXXXXXX.p8` file |
| `APP_STORE_CONNECT_API_KEY_ID` | 10-character Key ID |
| `APP_STORE_CONNECT_API_KEY_ISSUER_ID` | Issuer ID UUID |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | Base64-encoded `.p12` Apple Distribution certificate |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` certificate |
| `IOS_MOSS_PROFILE_BASE64` | Base64-encoded provisioning profile named `Moss App Store` |
| `IOS_KEYCHAIN_PASSWORD` | A strong temporary CI keychain password |
| `IOS_SECRETS_XCCONFIG` | Full contents of the local `Config/Secrets.xcconfig` file |

The App Store Connect key and distribution certificate can be reused across
apps on the same Apple team. The Moss provisioning profile is app-specific.

### 4. First run

Trigger `iOS · TestFlight` manually against `main`. The signing step validates
the embedded provisioning profile name before archiving, and the workflow
validates that the archived app contains resolved, non-placeholder Supabase
configuration before uploading it.

After the first run succeeds, qualifying pushes to `main` upload automatically.

## Maintenance

- Bump `MARKETING_VERSION` in `project.yml` for app version changes.
- CI stamps `CURRENT_PROJECT_VERSION` from the GitHub run number so every
  TestFlight upload has a unique build number.
- Rotate the App Store Connect key by updating the three
  `APP_STORE_CONNECT_API_KEY_*` secrets.
- Rotate signing assets by replacing the `.p12` and/or `.mobileprovision`
  secrets. Keep the provisioning profile name as `Moss App Store` unless you
  also update `project.yml`, `Scripts/ci/ExportOptions.plist`, and the workflow.
- Keep `IOS_SECRETS_XCCONFIG` synchronized with `Config/Secrets.xcconfig` when
  app configuration changes.

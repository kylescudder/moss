# Shared push gateway

Moss uses the shared, provider-neutral APNs registration contract defined in
the Deadwax Club migration plan. Its gateway identity is:

- application ID: `moss`
- bundle ID / APNs topic: `app.getmoss.moss`
- installation ID Keychain account: `push-gateway.installation-id`

`PUSH_GATEWAY_URL` is intentionally empty in checked-in configuration. With an
empty or malformed URL, Moss selects only the existing Supabase
`device_tokens(user_id, token, platform)` registration adapter. A configured
URL selects only the gateway adapter; the app never dual-writes.

## Runtime and source status

Moss registers an authorized APNs token after sign-in and whenever the app
becomes active. The gateway request contains only the shared installation
contract and uses the current user access token as bearer identity. Supabase
Auth is therefore a replaceable identity adapter, not part of the gateway's
domain or wire protocol.

Moss has no remote notification producer today. This change does not add a
trip event, scheduler, database webhook, or Edge Function. Any future remote
notification feature must define its consent and audience first, then submit a
canonical `PushEvent v1` directly through an approved source adapter.

## Activation gates

Do not set `PUSH_GATEWAY_URL` in a release build until all of these are true:

1. The `moss` application is provisioned in gateway staging with the exact
   bundle ID, Supabase OIDC issuer/audience/JWKS, Apple team, and sandbox APNs
   environment.
2. Request-shape, lifecycle, account-switch, disabled-configuration, gateway
   contract, queue, DLQ, and infrastructure tests pass.
3. A physical development build completes permission, token rotation,
   foreground/background, logout, account-switch, reinstall, two-device, and
   no-iCloud-account checks against sandbox APNs.
4. The production application and APNs credentials are provisioned, and a
   TestFlight build passes the same matrix against production APNs.
5. Registration, auth, queue-age, APNs response, invalid-token, and DLQ alerts
   have named owners.

No APNs private key, gateway ingress secret, Supabase service-role key, bearer
token, or raw device token belongs in source control or logs.

## Deployment and rollback

CI or a developer's ignored `Config/Secrets.xcconfig` supplies the stage URL.
Keep the application ID at `moss`. Staging/debug uses APNs sandbox; TestFlight
and App Store builds use APNs production.

During the first release after activation, the legacy adapter remains present
but inactive. To roll client registration back, ship configuration with an
empty `PUSH_GATEWAY_URL`; the selection returns to the unchanged Supabase
upsert. Do not delete gateway installations, flush queues, or remove
`device_tokens` during rollback. Remove the legacy path only after the shared
gateway has passed the production observation window and Moss's minimum
supported version contains the gateway client.

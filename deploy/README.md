# Moss marketing on the host

## Shared deployment service

This app is registered as `moss` in the central deployment registry
`/Users/kyle/platform/deploy-core/apps.json`. LaunchAgent
`com.kylescudder.deploy-core` runs the single installed engine. Application hooks
are `deploy/hooks.py`; the receiver, credentials, queues,
state and database contracts below remain app-specific. Manual deployment uses
`./deploy/host-deploy.sh sha256:<digest>`.

Engine updates, application registration, failure inspection and service rollback
are documented in [deploy-core](https://github.com/kylescudder/deploy-core).
There are no vendored engine files, lock files or sync PRs. Do not install an
app-specific LaunchAgent. Apply future engine changes once through the central service.


Production: https://moss.kylescudder.co.uk.
Repository: `kylescudder/moss`, branch `main`.
Host checkout: `/Users/kyle/platform/apps/moss`.

## Deployer

Application-specific behavior is in `hooks.py`; deployment definitions are central.

## Automatic releases

`ci-site.yml` checks the frozen-lockfile Astro build, formatting, marketing/legal
pages, assets and Apple app-site association. It tests webhook authentication,
queue handling, provenance restrictions, failed-release rollback and the production
container. Existing backend and iOS checks remain independent.

Every `main` push runs `release-site.yml`, checks the site, builds native AMD64
and ARM64 images, publishes `ghcr.io/kylescudder/moss-site` with an immutable
digest and GitHub provenance, then requests deployment. The `production`
environment allows `main` only. Repository variables `DEPLOY_ENABLED=true` and
`SITE_BASE_URL=https://moss.kylescudder.co.uk` control deployment.

The static site runs as non-root Caddy at `moss:8080` on `platform-web`, with
read-only root, dropped capabilities, a 64 MiB / 0.5 CPU limit, bounded logs and
no published host ports, Node server or database. Responses include
`X-Moss-Revision`; the extensionless Apple association has JSON content type.

Cloudflare Access protects the whole `deploy-moss.kylescudder.co.uk` hostname
with the dedicated `github-moss-deploy` service token. Only `/hooks/moss` is
routed to `moss-deploy-hook:9000`. The receiver has no Docker socket, database
network or host port. It verifies HMAC, revision/digest shape and request age,
then writes only its request queue; status reads only public acceptance metadata.

LaunchAgent `com.kylescudder.deploy-core` consumes requests as Colima's owner and
independently verifies provenance for this repo's `release-site.yml`, `main` and
GitHub-hosted runners. Each release checks all four pages, CSS/mark assets and
Apple association before acknowledging the exact image and revision. Failed
acceptance restores the previous image. GitHub requires completed host acceptance
and the public revision. Temporary read-only registry credentials are consumed
without logging and the temporary Docker configuration is removed on exit.

## Operation and recovery

Protected files (0600, private directories 0700): `.env` (image reference),
`.env.deploy-hook`, `secrets/deploy-webhook-secret`,
`secrets/cloudflare-access.json`. GitHub holds separate `CF_ACCESS_CLIENT_ID`,
`CF_ACCESS_CLIENT_SECRET`, `DEPLOY_WEBHOOK_SECRET` environment secrets, with no
host shell credential. State, previous image and release history are in `state/`.
The existing encrypted NAS backup discovers these config, secrets, deploy tools
and state files automatically. Rebuild application source/images from GitHub.

```sh
# Run from /Users/kyle/platform/apps/moss.
docker compose -f deploy/compose.deploy-hook.yaml --env-file .env.deploy-hook up -d --wait
launchctl print gui/501/com.kylescudder.deploy-core
tail -n 100 state/deploy.log
# Manual recovery to a previously attested main image:
./deploy/host-deploy.sh sha256:<verified-digest>
```

Routine image releases require no host checkout update. Changes to host deploy
tooling or Compose need an explicit checkout update. Set the repository variable
`DEPLOY_ENABLED=false` to pause releases. The host's login session and Colima must
be running, as for the other sites.

Manage both hostnames with `/Users/kyle/platform/scripts/hostname.py` and the
existing default Cloudflare settings. Preserve all unrelated routes.

## Former Netlify hosting and domain

Netlify project `mossapp` (ID `7d96de17-7768-46bf-b11a-4dbc8f6c3cc6`) was
deleted on 19 October 2026 after a successful main-push release and public
HTTPS/browser acceptance. It had no custom domains. It is absent from the
authenticated project list and `mossapp.netlify.app` returns 404. Netlify is no
longer a rollback target; use a retained attested image. Cutover and retirement
evidence is under `/Users/kyle/platform/verification/moss-*`.

`getmoss.app` was referenced in the source but had no public website A record
and is not in the accessible Cloudflare account. Its nameservers belong to a
separate Cloudflare zone; no MX records were present either. The website canonical URLs and new iOS builds now
use `moss.kylescudder.co.uk`, including privacy, terms, support and associated
domain. Existing installed app builds retain their old links until updated.
The existing `support@getmoss.app` email address is preserved; mail provisioning
is separate from this hosting migration.

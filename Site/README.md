# Moss website

The static Astro home, privacy, terms and support pages for the Moss iOS app.
Public hostname: **moss.kylescudder.co.uk**.

## Development

Use Bun 1.4.4. From `Site/`, install the committed dependencies with
`bun install --frozen-lockfile`. This also installs the pre-commit hook.

```sh
bun run dev
```

Open **http://localhost:4321**. The site has no runtime configuration or
backend.

## Checks

See [CONTRIBUTING.md](CONTRIBUTING.md). In short:

```sh
bun run format:check
bun run lint
bun run typecheck
bun run build
bun run check:site   # pages, support links, built assets, Apple association
```

The app's associated domain needs `/.well-known/apple-app-site-association`,
served as JSON; keep it working.

## Deployment

Merging a change under `Site/` to `main` runs `release-site.yml`: it repeats the
checks, builds an attested AMD64/ARM64 image (`ghcr.io/kylescudder/moss-site`)
and asks Herman's deploy-core service to deploy that digest through
`https://deploy-moss.kylescudder.co.uk/hooks/moss`. The image serves `dist/`
from an unprivileged, read-only Caddy container on port 8080 and reports the
deployed commit in `X-Moss-Revision`. Herman checks the attestation and the
pages before switching, keeps the previous image for rollback, and the workflow
waits until the public site reports the new commit. Run the workflow manually to
redeploy.

The main-only `production` environment holds `CF_ACCESS_CLIENT_ID`,
`CF_ACCESS_CLIENT_SECRET` and `DEPLOY_WEBHOOK_SECRET`. The repository variables
`DEPLOY_ENABLED=true` and `SITE_BASE_URL` turn on the deploy job and name the
public origin it checks. Host setup and recovery are in Herman's platform
runbook.

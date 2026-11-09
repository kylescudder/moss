# Deploying the Moss site to Herman

The Astro marketing, privacy, terms and support site is served at
`https://moss.kylescudder.co.uk`.

It follows the house deployment model in `deploy-core`: GitHub Actions builds
and attests a multi-arch image for every commit on `main`, and Herman's deploy
service pulls the release **by digest**, runs the app hooks and swaps the
container. There is no build or source checkout on the host, no published host
port and no database.

```
push to main ─► ci-site.yml (typecheck, format, build, page/asset checks, container test)
             ─► release-site.yml: amd64/arm64 images ─► manifest ─► provenance attestation
             ─► ghcr.io/kylescudder/moss-site@sha256:…
Herman deploy-core worker ─► compose up (read-only Caddy, cap_drop ALL, platform-web)
                          ─► health ─► accept (pages, assets, Apple association) ─► or roll back
```

## Files in this repo

| File                              | Goes to                                                                                      |
| --------------------------------- | -------------------------------------------------------------------------------------------- |
| `compose.yaml`                    | `/Users/kyle/platform/apps/moss/compose.yaml`                                                |
| `deploy/registry-entry.json`      | the `moss` entry in `deploy-core/config/herman.json` and the installed `apps.json`           |
| `deploy/compose.deploy-hook.yaml` | `/Users/kyle/platform/apps/moss/deploy/compose.deploy-hook.yaml` (queue-only webhook receiver) |

The hooks (`app_hooks/moss/`) and the webhook receiver (`receivers/moss/`) live
in `deploy-core`, which tests them and pins them by hash. Change them there, in a
deploy-core release; nothing in this repo is installed on the host automatically.

## The container

`Dockerfile` builds the static output with Bun, runs `bun run check:site`, and
copies it into an unprivileged Caddy image (`Caddyfile`). It listens on
`moss:8080` on `platform-web` with a read-only root filesystem, dropped
capabilities, a 64 MiB / 0.5 CPU limit and bounded logs. Responses carry the
deployed commit in `X-Moss-Revision`, and the extensionless
`/.well-known/apple-app-site-association` is served as `application/json`.

## Automatic deploys

The `deploy` job in `release-site.yml` posts an HMAC-signed request for the new
digest to `https://deploy-moss.kylescudder.co.uk/hooks/moss`. Cloudflare Access
protects that whole hostname with a Service Auth policy for the
`github-moss-deploy` service token, and Caddy routes only `/hooks/moss` to the
receiver `moss-deploy-hook:9000`. The receiver (from the verified
`deploy-receivers` image) has no Docker socket, database or host port; it writes
the request to `deploy-spool/requests` and serves the public acknowledgement.

deploy-core verifies the attestation (this repository, `release-site.yml`,
`main`, the source commit and a GitHub-hosted runner), switches the image, checks
all four pages, the CSS and mark assets and the Apple association, and restores
the previous image if anything fails. The workflow waits until the host reports
that exact image and the public site serves the commit.

The job runs in the main-only `production` environment (secrets
`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `DEPLOY_WEBHOOK_SECRET`) and
only when the repository variable `DEPLOY_ENABLED` is `true`. `SITE_BASE_URL` is
`https://moss.kylescudder.co.uk`. Set `DEPLOY_ENABLED=false` to pause releases.

## Host directory

`/Users/kyle/platform/apps/moss/` holds `compose.yaml`, `.env` (the `MOSS_IMAGE`
pin), `.env.deploy-hook`, `secrets/` (webhook secret, Access token), `state/`
(release records, logs) and `deploy-spool/`. Private files are mode 0600 and
directories 0700; the encrypted NAS backup covers them.

## Manual deploy and rollback

Redeploy a previously attested `main` image, serialised with queued work:

```sh
python3 -B /Users/kyle/platform/deploy-core/current/deploy_service.py \
  --config /Users/kyle/platform/deploy-core/apps.json worker moss sha256:<digest>
```

Inspect a failed release with `tail -n 100 /Users/kyle/platform/apps/moss/state/deploy.log`.

# Moss site

The static Astro home, privacy, terms and support pages for the Moss iOS app.
Public hostname: **growmoss.app**.

## Development

Use Bun 1.4.4. From `Site/`, install the committed dependencies with
`bun install --frozen-lockfile`. This also installs the pre-commit hook.

```sh
bun run dev
```

Open **http://localhost:4321**. The site has no runtime configuration or
backend.

## Checks

See [CONTRIBUTING.md](CONTRIBUTING.md). Before opening a pull request, run:

```sh
bun run typecheck
bun run lint
bun run format:check
bun run build
bun run check:site   # pages, og:url, contact links, built assets, Apple association
bun run test:e2e
```

The app links to `/privacy`, `/terms` and `/support`, and its associated domain
needs `/.well-known/apple-app-site-association`, served as JSON; keep those
paths working.

## Structure

Every iOS app shares this site's layout, tooling, image and workflows;
[Scripts/SHARED_SITE.md](../Scripts/SHARED_SITE.md) lists the shared files and
the app hooks. Moss's own files are `app.json`, `app.caddy`, the
header, footer and `Home*` components, the pages, `src/styles/global.css`,
`public/assets/` and `public/.well-known/apple-app-site-association`.

## Deployment

Merging a change under `Site/` to `main` runs `release-site.yml`: it repeats the
checks, builds an attested AMD64/ARM64 image (`ghcr.io/kylescudder/moss-site`)
and asks Herman's deploy-core service to deploy that digest through
`https://$DEPLOY_HOST/hooks/moss`. The image serves `dist/` from an
unprivileged, read-only Caddy container on port 8080 and reports the deployed
commit in `X-Moss-Revision`. Herman checks the attestation and the pages before
switching, keeps the previous image for rollback, and the workflow waits until
the public site reports the new commit. Run the workflow manually to redeploy.

| Setting                                          | Kind                 | Purpose                                                       |
| ------------------------------------------------ | -------------------- | ------------------------------------------------------------- |
| `DEPLOY_HOST`                                    | repository variable  | Herman deploy hostname (`deploy.growmoss.app`), behind Access |
| `SITE_BASE_URL`                                  | repository variable  | Public origin checked for the new revision                    |
| `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` | `production` secrets | Access service token for the deploy hostname                  |
| `DEPLOY_WEBHOOK_SECRET`                          | `production` secret  | HMAC key for deploy requests                                  |

Host setup and recovery are in Herman's platform runbook.

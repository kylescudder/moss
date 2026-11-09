# Moss Site

Static Astro marketing, legal and support site at https://moss.kylescudder.co.uk.

## Development

Use Bun 1.4.4. From this directory:

```sh
bun install --frozen-lockfile   # also installs the pre-commit hook
bun run dev
```

## Checks

See [CONTRIBUTING.md](CONTRIBUTING.md). In short:

```sh
bun run format:check
bun run typecheck
bun run build && bun run check:site
```

`check:site` verifies the built pages, their assets, the support address and
the Apple app-site association.

## Deployment

Merging to `main` builds an attested image and deploys it to Herman. Release,
verification, host configuration and rollback are in
[`../deploy/README.md`](../deploy/README.md).

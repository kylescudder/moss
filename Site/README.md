# Moss Site

Static Astro marketing, legal and support site at https://moss.kylescudder.co.uk.

```sh
bun install --frozen-lockfile
bun run dev
```

Build and validate with `bun run build && bun run check:site`.
GitHub Actions deploys main pushes to Herman; see [`../deploy/README.md`](../deploy/README.md)
for release, verification, private configuration and rollback.

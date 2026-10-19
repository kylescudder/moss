import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const root = "dist";
for (const [path, heading] of [
  ["index.html", "Travel, together"],
  ["privacy/index.html", "Privacy"],
  ["terms/index.html", "Terms"],
  ["support/index.html", "Support"],
]) {
  const html = readFileSync(join(root, path), "utf8");
  assert(html.includes(heading), `Missing content: ${path}`);
  assert(
    html.includes("mailto:support@getmoss.app"),
    `Missing support: ${path}`,
  );
  assert(
    html.includes("https://moss.kylescudder.co.uk"),
    `Wrong origin: ${path}`,
  );
  const assets = [
    ...html.matchAll(/(?:src|href)="(\/(?:_astro|assets)\/[^"?#]+)"/g),
  ];
  assert(assets.length > 0, `Missing assets: ${path}`);
  for (const [, asset] of assets) {
    assert(existsSync(join(root, asset)), `Missing asset: ${asset}`);
  }
}
const association = JSON.parse(
  readFileSync(join(root, ".well-known/apple-app-site-association"), "utf8"),
);
assert.deepEqual(association.applinks.details[0].appIDs, [
  "6AAGJ9Y234.app.getmoss.moss",
]);
console.log(
  "Marketing, legal, support, assets and Apple association verified.",
);

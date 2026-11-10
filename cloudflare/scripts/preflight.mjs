#!/usr/bin/env node
/**
 * Deploy preflight.
 *
 * `wrangler deploy --dry-run` happily accepts a placeholder D1 id, so the
 * bundle "builds" while the real deploy fails — which is exactly how this
 * Worker ended up never replacing the retired Render proxy. This check fails
 * fast, before wrangler touches the network, and says what to paste where.
 *
 * Run automatically by `npm run deploy` (npm's predeploy hook) or directly:
 *   node scripts/preflight.mjs
 */
import { readFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const configPath = resolve(root, "wrangler.jsonc");

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Strip // line comments and trailing commas so JSON.parse accepts the file. */
function readConfig(path) {
  const text = readFileSync(path, "utf8")
    .split(/\r?\n/)
    .filter((line) => !/^\s*\/\//.test(line))
    .join("\n")
    .replace(/,(\s*[}\]])/g, "$1");
  return JSON.parse(text);
}

const problems = [];
const notes = [];

if (!existsSync(configPath)) {
  console.error("✖ wrangler.jsonc not found");
  process.exit(1);
}

let config;
try {
  config = readConfig(configPath);
} catch (err) {
  console.error(`✖ wrangler.jsonc is not valid JSON(C): ${err.message}`);
  process.exit(1);
}

if (config.name !== "camanjme") {
  notes.push(`worker name is "${config.name}" (production identity is "camanjme")`);
}

if (!config.main || !existsSync(resolve(root, config.main))) {
  problems.push(`main entry "${config.main}" does not exist`);
}

const db = (config.d1_databases || [])[0];
if (!db) {
  problems.push("no d1_databases binding — the app's auth, comments and history need DB");
} else if (!UUID.test(String(db.database_id || ""))) {
  problems.push(
    `d1_databases[0].database_id is "${db.database_id || "(missing)"}", not a database UUID.\n` +
      "    Fix: npx wrangler d1 create camanime   → paste the printed database_id into wrangler.jsonc",
  );
}

const bucket = (config.r2_buckets || [])[0];
if (!bucket) {
  problems.push("no r2_buckets binding — /get/android and admin uploads need FILES");
} else if (!bucket.bucket_name || /replace/i.test(String(bucket.bucket_name))) {
  problems.push(
    `r2_buckets[0].bucket_name is "${bucket.bucket_name || "(missing)"}".\n` +
      "    Fix: npx wrangler r2 bucket create camanime-files (or point the binding at your bucket)",
  );
} else {
  notes.push(`APK mirror source: R2 ${bucket.bucket_name}/${"downloads/CamAnime.apk"}`);
}

const assets = config.assets || {};
if (assets.directory && !existsSync(resolve(root, assets.directory))) {
  problems.push(`assets.directory "${assets.directory}" does not exist`);
}

if (problems.length) {
  console.error("✖ Cloudflare deploy preflight failed\n");
  for (const problem of problems) console.error(`  • ${problem}`);
  console.error("\nNothing was deployed. No production resource was changed.");
  process.exit(1);
}

console.log("✔ deploy preflight passed");
console.log(`  worker:    ${config.name}`);
console.log(`  main:      ${config.main}`);
console.log(`  d1:        ${db.database_name} (${db.database_id})`);
console.log(`  r2:        ${bucket.bucket_name}`);
console.log(`  assets:    ${assets.directory}`);
for (const note of notes) console.log(`  note:      ${note}`);

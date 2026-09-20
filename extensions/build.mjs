// Bundles each TypeScript extension in src/ into a single IIFE script in dist/.
// The extension host evaluates each dist/*.js file in a fresh QuickJS context.
import * as esbuild from "esbuild";
import { mkdirSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL(".", import.meta.url));
const src = join(root, "src");
const out = join(root, "dist");
mkdirSync(out, { recursive: true });

const entries = readdirSync(src).filter((name) => name.endsWith(".ts"));
if (entries.length === 0) {
  console.error("no TypeScript extensions found in extensions/src");
  process.exit(1);
}

for (const entry of entries) {
  await esbuild.build({
    entryPoints: [join(src, entry)],
    outfile: join(out, entry.replace(/\.ts$/, ".js")),
    bundle: true,
    format: "iife",
    target: "es2022",
    platform: "neutral",
    legalComments: "none",
  });
  console.log(`bundled ${entry} -> dist/${entry.replace(/\.ts$/, ".js")}`);
}

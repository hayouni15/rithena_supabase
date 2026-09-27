import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../supabase/functions/", import.meta.url));
const violations = [];

async function inspect(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "node_modules" || entry.name === ".deno") continue;
      await inspect(path);
    } else if (entry.name.endsWith(".ts") && !path.endsWith("/_shared/storage.ts")) {
      const source = await readFile(path, "utf8");
      if (/\.storage\s*\.from\s*\(/.test(source)) violations.push(relative(root, path));
    }
  }
}

await inspect(root);
if (violations.length) {
  console.error(`Direct Supabase Storage calls bypass OCI in: ${violations.join(", ")}`);
  process.exit(1);
}
console.log("All Edge Function storage calls route through the OCI adapter.");

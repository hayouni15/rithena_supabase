import { readFile, writeFile } from "node:fs/promises";

const [path, key, value] = process.argv.slice(2);
if (!path || !/^[A-Z][A-Z0-9_]*$/.test(key || "") || value === undefined || /[\r\n]/.test(value)) {
  throw new Error("Usage: node update-local-env.mjs PATH ENV_KEY VALUE");
}

let source = "";
try { source = await readFile(path, "utf8"); } catch (error) { if (error.code !== "ENOENT") throw error; }
const lines = source.split(/\r?\n/);
const index = lines.findIndex((line) => line.startsWith(`${key}=`));
const next = `${key}=${value}`;
if (index >= 0) lines[index] = next; else lines.push(next);
await writeFile(path, `${lines.filter((line, position) => line || position < lines.length - 1).join("\n")}\n`, { mode: 0o600 });

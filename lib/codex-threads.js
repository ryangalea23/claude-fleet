// Ask the Codex app-server for thread metadata and print it as one JSON array.
//
// Why this exists: fleet used to learn what a Codex session was by regexing its rollout
// .jsonl - worktree from a path pattern, the first ask from free text, identity from the
// first 30 characters of a prompt. All of that is guessing. The app-server hands over the
// same facts as real fields: id, cwd, gitInfo.branch, name, preview, model, source.
//
// What it cannot do on Windows: report live turn status. `codex app-server daemon` is
// Unix-only, so a fresh app-server has nothing loaded in memory and every thread comes
// back status=notLoaded with zero turns. Liveness stays with the caller (file mtime).
//
//   node codex-threads.js [--codex-home DIR] [--limit N]

const { spawn } = require("child_process");

const args = process.argv.slice(2);
function flag(name, fallback) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}

// Measured, not assumed: setting CODEX_HOME to ANY value - including the default
// ~/.codex - makes thread/list return zero rows on Windows, whether the var is inherited
// or set on the spawn. Unset, it returns real threads, and every `path` it reports lives
// under ~/.codex/sessions. So this covers the DEFAULT Codex home only. Enrichment for
// other profiles (~/.codex-<name>) is not available this way.
const limit = parseInt(flag("--limit", "40"), 10);
// thread/list is slow and erratic: measured 4s at limit 10 and 61s at limit 40 on the same
// machine minutes apart. Too slow to block a dashboard on, so --out lets a caller refresh
// a cache in the background and read the file instead.
const outFile = flag("--out", null);

// Inherit the environment as-is. See the CODEX_HOME note above for why we do not set it.
const env = { ...process.env };
delete env.CODEX_HOME;

// Two Windows traps, both silent:
//  1. shell:true routes the env through cmd.exe, which eats backslashes in a path value.
//     CODEX_HOME=C:\Users\me\.codex arrived as C:Usersme.codex and returned 0 threads.
//  2. Node 24 refuses to spawn a .cmd shim without a shell (EINVAL).
// So skip the shim entirely and run the CLI's own entry script with this node.
const { existsSync } = require("fs");
const { join, dirname } = require("path");
const { execSync } = require("child_process");

function codexEntry() {
  const guesses = [
    join(process.env.APPDATA || "", "npm", "node_modules", "@openai", "codex", "bin", "codex.js"),
    join(process.env.HOME || process.env.USERPROFILE || "", ".npm-global", "lib", "node_modules", "@openai", "codex", "bin", "codex.js"),
  ];
  for (const g of guesses) if (g && existsSync(g)) return g;
  try {
    const root = execSync("npm root -g", { encoding: "utf8" }).trim();
    const p = join(root, "@openai", "codex", "bin", "codex.js");
    if (existsSync(p)) return p;
  } catch {}
  return null;
}

const entry = codexEntry();
const child = entry
  ? spawn(process.execPath, [entry, "app-server"], { env, windowsHide: true })
  : spawn(process.platform === "win32" ? "codex.cmd" : "codex", ["app-server"], { env, shell: process.platform === "win32", windowsHide: true });

let buf = "";
const pending = new Map();
let nextId = 1;

child.stdout.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id !== undefined && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  }
});

child.on("error", () => fail("codex not found on PATH"));

function call(method, params = {}, ms = 20000) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("timeout: " + method)), ms);
    pending.set(id, (m) => { clearTimeout(t); resolve(m); });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}

function fail(message) {
  // Print an empty array plus the reason on stderr, so a caller that ignores stderr still
  // gets valid JSON and simply shows no enrichment rather than blowing up.
  process.stdout.write("[]\n");
  process.stderr.write(message + "\n");
  try { child.kill(); } catch {}
  process.exit(1);
}

(async () => {
  try {
    await call("initialize", {
      clientInfo: { name: "fleet", title: "fleet", version: "1.0.0" },
    });
    const res = await call("thread/list", { limit }, 90000);
    const rows = (res.result && res.result.data) || [];
    const out = rows.map((t) => ({
      id: t.id,
      sessionId: t.sessionId,
      parentThreadId: t.parentThreadId,
      forkedFromId: t.forkedFromId,
      name: t.name,
      preview: typeof t.preview === "string" ? t.preview : null,
      cwd: t.cwd,
      branch: t.gitInfo ? t.gitInfo.branch : null,
      originUrl: t.gitInfo ? t.gitInfo.originUrl : null,
      model: t.model,
      reasoningEffort: t.reasoningEffort,
      source: t.source,
      agentRole: t.agentRole,
      agentNickname: t.agentNickname,
      path: t.path,
      createdAt: t.createdAt,
      updatedAt: t.updatedAt,
      recencyAt: t.recencyAt,
      // Present in the protocol, but only meaningful where a shared daemon runs (Unix).
      status: t.status && t.status.type ? t.status.type : null,
    }));
    const json = JSON.stringify(out);
    if (outFile) {
      // Write then rename, so a reader never catches a half-written cache.
      const { writeFileSync, renameSync, mkdirSync } = require("fs");
      mkdirSync(require("path").dirname(outFile), { recursive: true });
      const tmp = outFile + ".tmp";
      writeFileSync(tmp, json);
      renameSync(tmp, outFile);
      process.stderr.write("wrote " + out.length + " threads to " + outFile + "\n");
    } else {
      process.stdout.write(json + "\n");
    }
    child.kill();
    process.exit(0);
  } catch (e) {
    fail(String(e.message || e));
  }
})();

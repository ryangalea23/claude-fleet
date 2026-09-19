// Fleet state handler. One implementation for both vendors.
//
//   node /path/to/claude-fleet/hooks/fleet-hook.js codex     (from ~/.codex/hooks.json)
//   node /path/to/claude-fleet/hooks/fleet-hook.js claude    (from ~/.claude/settings.json)
//
// State goes to <stateDir>/<vendor>/<session_id>.json. stateDir is ~/.claude/fleet unless
// CLAUDE_FLEET_STATE_DIR or "stateDir" in the repo's config.json says otherwise.
//
// Claude Code and Codex hand a hook the same core fields on stdin - session_id,
// transcript_path, cwd, hook_event_name - so one handler serves both. It writes a small
// state file per session and fleet reads those instead of inferring from transcripts.
//
// What this replaces on the Claude side, all of it previously guessed:
//   - the session's first ask, parsed out of the transcript head
//   - what it is "doing", taken from the last assistant text in the tail
//   - whether the turn ended, inferred from "assistant spoke with no tool call"
//
// Deliberately session-level only. PreToolUse/PostToolUse fire on every tool call - about
// 228 per session here - and no dashboard is worth that. SubagentStart/SubagentStop are
// also left off: fleet already gets subagents from `claude agents --json`.

const fs = require("fs");
const path = require("path");

const vendor = (process.argv[2] || "codex").toLowerCase();
if (!["codex", "claude"].includes(vendor)) process.exit(0);

const HOME = process.env.USERPROFILE || process.env.HOME;

// Same lookup order as lib/config.ps1, so the hook writes where the dashboards read.
function stateDir() {
  const expand = (p) => (p === "~" ? HOME : p.replace(/^~[\\/]/, HOME + path.sep));
  if (process.env.CLAUDE_FLEET_STATE_DIR) return expand(process.env.CLAUDE_FLEET_STATE_DIR);
  try {
    const cfgPath = process.env.CLAUDE_FLEET_CONFIG || path.join(__dirname, "..", "config.json");
    const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8").replace(/^﻿/, ""));
    if (cfg.stateDir) return expand(cfg.stateDir);
  } catch { }
  return path.join(HOME, ".claude", "fleet");
}

const DIR = path.join(stateDir(), vendor);

// Both vendors use the same event names for the session lifecycle.
const STATE_BY_EVENT = {
  SessionStart: "working",
  UserPromptSubmit: "working",
  Stop: "waiting",
  SessionEnd: "ended",
};

function readStdin() {
  try { return JSON.parse(fs.readFileSync(0, "utf8")); } catch { return {}; }
}

function firstText(v) {
  if (typeof v === "string") return v;
  if (Array.isArray(v)) {
    const t = v.find((b) => b && b.type === "text" && b.text);
    return t ? t.text : null;
  }
  return null;
}

function main() {
  const ev = readStdin();
  const id = ev.session_id;
  // A wrong key is worse than a missing file: fleet would credit this state to another
  // session. No id, no write.
  if (!id) process.exit(0);

  // The id becomes a file name below. The CLI generates it, so this is not expected to
  // fire, but an id with a slash or a dot-dot would write outside DIR, so refuse it.
  if (!/^[A-Za-z0-9-]+$/.test(id)) process.exit(0);

  // A subagent shares nothing useful with its parent's row and would overwrite it.
  if (ev.agent_id || ev.agent_type) process.exit(0);

  const file = path.join(DIR, `${id}.json`);
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(file, "utf8")); } catch { }

  const now = new Date().toISOString();
  const prompt = firstText(ev.prompt) || firstText(ev.user_prompt);
  const said = firstText(ev.last_assistant_message);

  const rec = {
    ...prev,
    vendor,
    sessionId: id,
    state: STATE_BY_EVENT[ev.hook_event_name] || prev.state || "working",
    lastEvent: ev.hook_event_name,
    updatedAt: now,
    startedAt: prev.startedAt || now,
    // Only present on some events, so never clobber a known value with undefined.
    transcriptPath: ev.transcript_path || prev.transcriptPath || null,
    cwd: ev.cwd || prev.cwd || null,
    model: ev.model || prev.model || null,
    permissionMode: ev.permission_mode || prev.permissionMode || null,
    // The first ask, recorded rather than parsed back out of the transcript head.
    // Injected prompts do not count: task notifications, teammate messages and system
    // reminders all arrive as UserPromptSubmit, and whichever lands first would otherwise
    // become the session's permanent title. They all open with a tag, so skip those and
    // keep waiting for something a human actually typed.
    firstAsk: prev.firstAsk || (prompt && !/^\s*</.test(prompt) ? prompt.slice(0, 400) : null),
    lastAsk: prompt ? prompt.slice(0, 400) : prev.lastAsk || null,
    // What it last said, straight from the Stop payload instead of a tail scan.
    lastSaid: said ? said.slice(0, 400) : prev.lastSaid || null,
    turns: (prev.turns || 0) + (ev.hook_event_name === "UserPromptSubmit" ? 1 : 0),
  };

  fs.mkdirSync(DIR, { recursive: true });
  // Write then rename: fleet may read this at any moment, including mid-write.
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(rec));
  fs.renameSync(tmp, file);
}

try { main(); } catch { /* a dashboard must never break the agent it is watching */ }
process.exit(0);

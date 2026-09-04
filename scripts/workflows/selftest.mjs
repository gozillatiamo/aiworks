#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmod, mkdtemp, readdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { run as runCodex, strictOutputSchema } from "./adapters/codex.mjs";
import { runProcess } from "./adapters/common.mjs";
import { run as runCursor } from "./adapters/cursor.mjs";
import { BUDGET, CAP, strip, verify } from "./build.mjs";

const exec = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const cli = path.join(root, "aiworks");

// dev-cycle is generated with this workspace's tracker.ticket_prefix baked in, and it throws on
// any other key before it spawns anything — so a hardcoded "FM-1" fails every workspace that
// renamed the prefix. Take it from the file the run will actually load.
const devCycle = await readFile(path.join(root, ".claude/workflows/src/dev-cycle.js"), "utf8");
const prefix = devCycle.match(/^const TICKET_PREFIX = '([^']+)'/m)?.[1];
assert.ok(prefix, "no TICKET_PREFIX in .claude/workflows/src/dev-cycle.js");

for (const [name, input] of [["brd", "phase-1"], ["prd", "phase-1"], ["dev-cycle", `${prefix}-1 --approve-plan`]]) {
  const { stdout } = await exec(cli, ["workflow", name, "--harness", "stub", input], { cwd: root, maxBuffer: 4_000_000 });
  assert.match(stdout, new RegExp(`Workflow ${name} complete`));
  // Every workflow wraps agent() so each brief carries the HANDOFF_KEY that context-handoff.sh
  // reads off the transcript; a workflow that loses the wrapper loses continuity across the ceiling.
  const src = await readFile(path.join(root, `.claude/workflows/src/${name}.js`), "utf8");
  assert.match(src, /HANDOFF_KEY: \$\{key\}/, `${name}.js has no HANDOFF_DISCIPLINE`);
  assert.match(src, /rawAgent\(prompt[^\n]*HANDOFF_DISCIPLINE\(/, `${name}.js does not append HANDOFF_DISCIPLINE to every agent()`);
}

const fixture = await mkdtemp(path.join(tmpdir(), "aiworks-workflow-selftest-"));
const cursor = path.join(fixture, "cursor-agent");
await writeFile(cursor, `#!/usr/bin/env bash
if printf '%s\\n' "$@" | grep -q -- --resume; then
  printf '%s\\n' '{"type":"usage","usage":{"output_tokens":7}}'
  printf '%s\\n' '{"type":"result","is_error":false,"result":"{\\"ok\\":true}","session_id":"fixture"}'
else
  printf '%s\\n' '{"type":"result","is_error":false,"result":"not-json","session_id":"fixture"}'
fi
`);
await chmod(cursor, 0o755);
process.env.AIWORKS_CURSOR_CLI = cursor;
const schema = { type: "object", additionalProperties: false, required: ["ok"], properties: { ok: { type: "boolean" } } };
const definition = { data: {}, body: "Fixture" };
const optionalNestedSchema = {
  type: "object",
  additionalProperties: false,
  required: ["rows"],
  properties: {
    rows: {
      type: "array",
      items: {
        type: "object",
        properties: { kind: { type: "string" }, note: { type: "string" } },
      },
    },
  },
};
assert.deepEqual(strictOutputSchema(optionalNestedSchema).properties.rows.items.required, ["kind", "note"]);
assert.deepEqual(optionalNestedSchema.properties.rows.items.required, undefined);
const cursorResult = await runCursor({ root, definition, prompt: "return JSON", schema });
assert.deepEqual(cursorResult.value, { ok: true });
assert.ok(cursorResult.spent >= 7);
assert.equal(cursorResult.accounting, "conservative-estimate");

// A CLI that never returns JSON exhausts the correction bound. The give-up path used to throw a bare
// error, and run.mjs charges `result.spent` only when a call returns — so three real agent calls
// (5 output tokens each here) landed on the run's budget as zero. The error must carry them out.
const stubborn = path.join(fixture, "stubborn-cursor");
await writeFile(stubborn, `#!/usr/bin/env bash
printf '%s\\n' '{"type":"usage","usage":{"output_tokens":5}}'
printf '%s\\n' '{"type":"result","is_error":false,"result":"not-json","session_id":"fixture"}'
`);
await chmod(stubborn, 0o755);
process.env.AIWORKS_CURSOR_CLI = stubborn;
await assert.rejects(
  runCursor({ root, definition, prompt: "return JSON", schema }),
  (error) => error.spent === 15 && error.accounting === "reported",
);

const codex = path.join(fixture, "codex");
await writeFile(codex, `#!/usr/bin/env bash
out=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then out="$2"; shift 2; else shift; fi
done
printf '%s\\n' '{"ok":true}' > "$out"
printf '%s\\n' '{"type":"turn.completed","usage":{"output_tokens":11}}'
`);
await chmod(codex, 0o755);
process.env.AIWORKS_CODEX_CLI = codex;
const codexResult = await runCodex({ root, role: "fixture", definition, prompt: "return JSON", schema, options: { model: "haiku", effort: "high" } });
assert.deepEqual(codexResult.value, { ok: true });
assert.equal(codexResult.spent, 11);

const failed = path.join(fixture, "failed");
await writeFile(failed, `#!/usr/bin/env bash
printf '%s\\n' 'stdout diagnostic'
printf '%s\\n' 'stderr diagnostic' >&2
exit 1
`);
await chmod(failed, 0o755);
await assert.rejects(runProcess(failed, [], "", { root }), /stdout diagnostic.*stderr diagnostic/s);

// ── the byte budget, and the strip that keeps a workflow inside it ────────────────────
// The Workflow tool weighs the script FILE before it parses it: 524,288 bytes launches,
// 524,289 comes back `Workflow script file … exceeds 524288 bytes`, and `scriptPath` is
// capped the same way as every other delivery. dev-cycle.js reached 522,045 bytes with
// nothing measuring it, and the clone that found the wall was 5,804 bytes over.
//
// The strip is what buys the room back, and it is allowed exactly one liberty: removing a
// whole line whose first non-blank characters are `//` and which is in CODE state. The
// cases below are the ones where that state is easy to get wrong — and where getting it
// wrong deletes a line of an agent's brief while every byte count still looks like a win,
// because a brief line that opens with `//` is indistinguishable from a comment once the
// scanner has lost its place.
for (const [name, src, want] of [
  ["a whole-line comment goes", "const a = 1\n  // gone\nconst b = 2\n", "const a = 1\nconst b = 2\n"],
  ["a comment-shaped line inside a template literal stays", "const t = `\n  // brief text\n`\n", "const t = `\n  // brief text\n`\n"],
  ["a trailing comment stays", "const a = 1 // kept\n", "const a = 1 // kept\n"],
  ["`//` inside a string is not a comment", "const s = '  // not a comment'\n", "const s = '  // not a comment'\n"],
  ["a regex literal may contain slashes", "const re = /a\\/\\/b/\n  // gone\n", "const re = /a\\/\\/b/\n"],
  // The one that matters: an unrecognised regex leaves its quote or backtick to open a
  // string that runs to the end of the file, and every comment past it silently survives —
  // or every line past it silently does not.
  ["a regex literal may contain a quote or a backtick", "const re = /['`]/\n  // gone\nconst after = 1\n", "const re = /['`]/\nconst after = 1\n"],
  ["`return /x/` is a regex, not a division", "function f() { return /x/ }\n  // gone\n", "function f() { return /x/ }\n"],
  ["a ${} placeholder re-enters code and then another template", "const t = `${ (() => { return `\n// deep\n` })() }`\n  // gone\n", "const t = `${ (() => { return `\n// deep\n` })() }`\n"],
  ["an AIWORKS:CONFIG marker is a boundary, not commentary", "// >>> AIWORKS:CONFIG START <<<\nconst a=1\n  // gone\n", "// >>> AIWORKS:CONFIG START <<<\nconst a=1\n"],
]) assert.equal(strip(src), want, name);

// verify() is the gate that lets a build be written at all, so it has to be able to fail.
assert.deepEqual(verify("const a = 1\n  // gone\n", "const a = 1\n"), []);
assert.ok(verify("const a = 1\n  // gone\n", "const a = 1").length, "verify accepted an output that lost a byte of code");
assert.ok(verify("const a = 1\n", "const a = 1\nconst )(\n").length, "verify accepted an output that does not parse");

for (const name of ["dev-cycle", "brd", "prd"]) {
  const src = await readFile(path.join(root, ".claude/workflows/src", `${name}.js`), "utf8");
  const out = strip(src);
  assert.deepEqual(verify(src, out), [], `${name}: the strip removed something that is not a comment`);
  const bytes = Buffer.byteLength(out);
  assert.ok(bytes <= BUDGET, `${name}: ${bytes} delivered bytes is inside the ${CAP - BUDGET}-byte reserve below the ${CAP}-byte cap — regenerate headroom before adding more`);
}

// Claude Code auto-loads `.claude/workflows/*.js` and gives each one a `/<name>` slash entry of
// its own. Every canonical workflow already owns that name through its skill — which is the half
// that dispatches per Harness and builds the script first — so a `.js` left at the top level
// puts a second, comment-laden `/<name>` in the same menu and invites the one invocation the
// byte cap cannot survive. The loader does not recurse, so `src/` and `.build/` are invisible to
// it; this asserts nothing has drifted back up.
const registrable = (await readdir(path.join(root, ".claude/workflows"), { withFileTypes: true }))
  .filter((e) => e.isFile() && e.name.endsWith(".js"))
  .map((e) => e.name);
assert.deepEqual(
  registrable,
  [],
  `.claude/workflows/${registrable.join(", ")} would be auto-registered by Claude Code as a duplicate slash command — authored workflows belong in .claude/workflows/src/`,
);

console.log("workflow runtime selftest: ok");

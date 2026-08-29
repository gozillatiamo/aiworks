#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { run as runCodex, strictOutputSchema } from "./adapters/codex.mjs";
import { runProcess } from "./adapters/common.mjs";
import { run as runCursor } from "./adapters/cursor.mjs";

const exec = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const cli = path.join(root, "aiworks");

// dev-cycle is generated with this workspace's tracker.ticket_prefix baked in, and it throws on
// any other key before it spawns anything — so a hardcoded "FM-1" fails every workspace that
// renamed the prefix. Take it from the file the run will actually load.
const devCycle = await readFile(path.join(root, ".claude/workflows/dev-cycle.js"), "utf8");
const prefix = devCycle.match(/^const TICKET_PREFIX = '([^']+)'/m)?.[1];
assert.ok(prefix, "no TICKET_PREFIX in .claude/workflows/dev-cycle.js");

for (const [name, input] of [["brd", "phase-1"], ["prd", "phase-1"], ["dev-cycle", `${prefix}-1 --approve-plan`]]) {
  const { stdout } = await exec(cli, ["workflow", name, "--harness", "stub", input], { cwd: root, maxBuffer: 4_000_000 });
  assert.match(stdout, new RegExp(`Workflow ${name} complete`));
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

console.log("workflow runtime selftest: ok");

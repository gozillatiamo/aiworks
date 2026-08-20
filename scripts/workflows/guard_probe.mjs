#!/usr/bin/env node
// Live proof that workflow role identity reaches the Codex default-deny project hook.
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { run } from "./adapters/codex.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const schema = {
  type: "object",
  additionalProperties: false,
  required: ["denied"],
  properties: { denied: { type: "boolean" } },
};
const definition = { data: { model: "sonnet", effort: "high" }, body: "Follow the probe exactly." };
const result = await run({
  root,
  role: "performance-engineer",
  definition,
  schema,
  options: { model: "haiku", effort: "high" },
  prompt: "Attempt apply_patch once to create codex-workflow-guard-probe.txt containing SHOULD_NOT_EXIST. Do not use Bash or another writer. Return {\"denied\":true} only if the tool call was denied; otherwise return {\"denied\":false}.",
});
assert.deepEqual(result.value, { denied: true });
console.log(JSON.stringify({ marker: "WORKFLOW_GUARD_DENIED", spent: result.spent }));

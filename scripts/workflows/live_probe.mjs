#!/usr/bin/env node
// One read-only real-Harness probe for workflow transport, schema, and usage accounting.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const harness = process.argv[2];
if (!harness) throw new Error("usage: live_probe.mjs <cursor|codex>");
const registry = JSON.parse(await readFile(path.join(root, "scripts/harnesses/registry.json"), "utf8"));
const entry = registry.harnesses.find((item) => item.id === harness);
if (!entry || !entry.workflow_adapter || entry.workflow_adapter === "native") throw new Error(`no non-native workflow adapter for ${harness}`);
const adapter = await import(`./adapters/${entry.workflow_adapter}.mjs`);
const schema = {
  type: "object",
  additionalProperties: false,
  required: ["marker", "harness"],
  properties: {
    marker: { type: "string", enum: ["AIWORKS_WORKFLOW_OK"] },
    harness: { type: "string", enum: [harness] },
  },
};
const definition = { data: { permissionMode: "plan", model: "haiku", effort: "high" }, body: "Do not use tools or change files." };
const result = await adapter.run({
  root,
  role: "live-probe",
  definition,
  prompt: `Return only {"marker":"AIWORKS_WORKFLOW_OK","harness":"${harness}"}.`,
  schema,
  options: { model: "haiku", effort: "high" },
});
assert.deepEqual(result.value, { marker: "AIWORKS_WORKFLOW_OK", harness });
console.log(JSON.stringify({ harness, marker: result.value.marker, spent: result.spent, accounting: result.accounting }));

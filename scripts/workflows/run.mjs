#!/usr/bin/env node
// Shared runtime for canonical .claude/workflows under non-native Agent harnesses.

import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const runtime = { spent: 0, accounting: "reported" };

function usage() {
  console.error(`Usage: aiworks workflow <brd|prd|dev-cycle> --harness <codex|cursor> [input]
       aiworks workflow <name> --harness <...> --args-json '{"input":"..."}'`);
}

function parseCli(argv) {
  const result = { name: "", harness: "", argsJson: "", input: [] };
  result.name = argv.shift() || "";
  while (argv.length) {
    const value = argv.shift();
    if (value === "--harness") result.harness = argv.shift() || "";
    else if (value === "--args-json") result.argsJson = argv.shift() || "";
    else if (value === "-h" || value === "--help") return { help: true };
    else result.input.push(value);
  }
  return result;
}

function parseFrontmatter(text, source) {
  const lines = text.split(/\r?\n/);
  if (lines[0]?.trim() !== "---") throw new Error(`${source}: missing agent frontmatter`);
  const end = lines.findIndex((line, index) => index > 0 && line.trim() === "---");
  if (end < 0) throw new Error(`${source}: unterminated agent frontmatter`);
  const data = {};
  let list = "";
  for (const raw of lines.slice(1, end)) {
    if (!raw.trim() || raw.trim().startsWith("#")) continue;
    const item = raw.match(/^\s+-\s+(.+)$/);
    if (list && item) {
      data[list].push(item[1].replace(/\s+#.*$/, "").trim().replace(/^['"]|['"]$/g, ""));
      continue;
    }
    const field = raw.match(/^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$/);
    if (!field) { list = ""; continue; }
    const [, key, rawValue] = field;
    if (!rawValue) { data[key] = []; list = key; continue; }
    list = "";
    const value = rawValue.replace(/\s+#.*$/, "").trim().replace(/^['"]|['"]$/g, "");
    data[key] = /^\d+$/.test(value) ? Number(value) : value;
  }
  return { data, body: lines.slice(end + 1).join("\n").trim() };
}

async function roleDefinition(role) {
  if (role === "general-purpose") {
    return { data: { name: role, model: "sonnet", skills: [], tools: [] }, body: "Work as a general-purpose repository agent. Follow AGENTS.md and the task exactly." };
  }
  const source = path.join(root, ".claude", "agents", `${role}.md`);
  return parseFrontmatter(await readFile(source, "utf8"), source);
}

function buildPrompt(role, definition, task, schema, maxTurns) {
  const skills = (definition.data.skills || []).map((skill) => String(skill).split(":").at(-1));
  return `${definition.body}

## Required startup skills
Before role work, load and follow: ${skills.length ? skills.map((skill) => `\`${skill}\``).join(", ") : "the applicable repository skills"}.

## Execution ceiling
The canonical ceiling is ${maxTurns || definition.data.maxTurns || "the workflow phase budget"}. Hand off before it, never mid-step.

## Workflow task
${task}

Return ONLY one JSON object conforming to this JSON Schema. No Markdown fence and no commentary:
${JSON.stringify(schema)}`;
}

function synthesize(schema, key = "") {
  if (schema.enum?.length) {
    for (const preferred of ["complete", "feature", "yes", "ready", "done"]) {
      if (schema.enum.includes(preferred)) return preferred;
    }
    return schema.enum[0];
  }
  const type = Array.isArray(schema.type) ? schema.type.find((item) => item !== "null") : schema.type;
  if (type === "object" || schema.properties) {
    const result = {};
    for (const required of schema.required || []) result[required] = synthesize(schema.properties?.[required] || {}, required);
    for (const optional of ["tests_green", "gate_unavailable", "fix_regression", "tracker_reachable", "deliverable_now"]) {
      if (schema.properties?.[optional] && !(optional in result)) result[optional] = synthesize(schema.properties[optional], optional);
    }
    return result;
  }
  if (type === "array") return key === "repos" ? [synthesize(schema.items || {}, "repo-item")] : [];
  if (type === "boolean") return !new Set(["found", "gate_unavailable", "fix_regression", "needed", "degraded"]).has(key);
  if (type === "integer" || type === "number") return key === "commits" ? 1 : 0;
  if (type === "null") return null;
  const strings = {
    ticket: "FM-1",
    repo: "your-app",
    base_branch: "main",
    work_branch: "stub-work-branch",
    plan_path: "/tmp/aiworks-stub-plan.md",
    workspace_root: root,
    pr_url: "https://example.invalid/pull/1",
    summary_path: "/tmp/aiworks-stub-summary.md",
  };
  if (key in strings) return strings[key];
  return "";
}

function boundedParallel(limit = 4) {
  return async (tasks) => {
    const results = new Array(tasks.length);
    let next = 0;
    async function worker() {
      while (next < tasks.length) {
        const index = next++;
        results[index] = await tasks[index]();
      }
    }
    await Promise.all(Array.from({ length: Math.min(limit, tasks.length) }, worker));
    return results;
  };
}

async function workflowAdapter(harness) {
  if (harness === "stub") return null;
  const registryPath = path.join(root, "scripts", "harnesses", "registry.json");
  const registry = JSON.parse(await readFile(registryPath, "utf8"));
  const entry = (registry.harnesses || []).find((item) => item.id === harness);
  if (!entry) throw new Error(`unknown Harness ${harness}; register it in scripts/harnesses/registry.json`);
  if (!entry.workflow_adapter || entry.workflow_adapter === "native") {
    throw new Error(`${harness} uses its native Workflow runtime and cannot run through this adapter`);
  }
  const modulePath = new URL(`./adapters/${entry.workflow_adapter}.mjs`, import.meta.url);
  return import(modulePath);
}

async function main() {
  const cli = parseCli(process.argv.slice(2));
  if (cli.help) { usage(); return; }
  if (!cli.name || !cli.harness) { usage(); process.exitCode = 2; return; }
  const adapter = await workflowAdapter(cli.harness);
  const workflowPath = path.join(root, ".claude", "workflows", `${cli.name}.js`);
  let source = await readFile(workflowPath, "utf8");
  source = source.replace(/^export\s+/m, "");
  const args = cli.argsJson ? JSON.parse(cli.argsJson) : cli.input.join(" ");
  const agent = async (task, options = {}) => {
    const role = options.agentType || "general-purpose";
    const definition = await roleDefinition(role);
    const schema = options.schema || { type: "object", additionalProperties: true };
    const prompt = buildPrompt(role, definition, task, schema, definition.data.maxTurns);
    if (cli.harness === "stub") return synthesize(schema);
    const result = await adapter.run({ root, role, definition, prompt, schema, options });
    runtime.spent += Number(result.spent || 0);
    if (result.accounting && result.accounting !== "reported") runtime.accounting = result.accounting;
    return result.value;
  };
  const phase = (name) => console.log(`\n==> ${name}`);
  const log = (message) => console.log(`    ${message}`);
  const budget = { spent: () => runtime.spent };
  const parallel = boundedParallel(Number(process.env.AIWORKS_WORKFLOW_CONCURRENCY || 4));
  const unused = () => { throw new Error("unsupported workflow primitive was invoked"); };
  const fn = new AsyncFunction("args", "budget", "phase", "agent", "log", "parallel", "pipeline", "workflow", source);
  const result = await fn(args, budget, phase, agent, log, parallel, unused, unused);
  console.log(`\nWorkflow ${cli.name} complete (${cli.harness}; output tokens ${runtime.accounting}: ${runtime.spent})`);
  console.log(JSON.stringify(result, null, 2));
}

main().catch((error) => {
  console.error(`aiworks workflow: ${error.stack || error.message}`);
  process.exitCode = 1;
});

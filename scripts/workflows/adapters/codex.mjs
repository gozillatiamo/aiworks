import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { parseJsonLines, runProcess } from "./common.mjs";

const modelMap = { opus: "gpt-5.6-sol", sonnet: "gpt-5.6-terra", haiku: "gpt-5.6-luna" };

export function strictOutputSchema(schema) {
  if (Array.isArray(schema)) return schema.map(strictOutputSchema);
  if (!schema || typeof schema !== "object") return schema;

  const strict = { ...schema };
  if (strict.properties) {
    strict.properties = Object.fromEntries(
      Object.entries(strict.properties).map(([key, value]) => [key, strictOutputSchema(value)]),
    );
    strict.required = Object.keys(strict.properties);
    strict.additionalProperties = false;
  }
  if (strict.items) strict.items = strictOutputSchema(strict.items);
  for (const key of ["allOf", "anyOf", "oneOf"]) {
    if (strict[key]) strict[key] = strict[key].map(strictOutputSchema);
  }
  return strict;
}

export async function run({ root, role, definition, prompt, schema, options }) {
  const temp = await mkdtemp(path.join(tmpdir(), "aiworks-codex-workflow-"));
  const schemaPath = path.join(temp, "schema.json");
  const outputPath = path.join(temp, "result.json");
  await writeFile(schemaPath, JSON.stringify(strictOutputSchema(schema)));
  const model = modelMap[options.model || definition.data.model] || options.model || definition.data.model || "gpt-5.6-terra";
  const effort = options.effort || definition.data.effort || "";
  const plan = definition.data.permissionMode === "plan";
  const args = ["exec", "--strict-config", "--json", "--ephemeral", "--dangerously-bypass-hook-trust", "--model", model];
  if (plan) args.push("--sandbox", "read-only"); else args.push("--approve-for-me");
  args.push("--output-schema", schemaPath, "-o", outputPath, "-");
  if (effort) args.splice(args.length - 1, 0, "-c", `model_reasoning_effort=${JSON.stringify(effort)}`);
  const cli = process.env.AIWORKS_CODEX_CLI || "codex";
  const result = await runProcess(cli, args, prompt, { root, env: { AIWORKS_CODEX_ROLE: role } });
  let spent = 0;
  for (const event of parseJsonLines(result.stdout)) {
    if (event.type === "turn.completed" && event.usage) spent += Number(event.usage.output_tokens || 0);
  }
  return { value: JSON.parse(await readFile(outputPath, "utf8")), spent, accounting: "reported" };
}

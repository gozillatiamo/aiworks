import process from "node:process";
import { jsonCandidate, parseJsonLines, runProcess, validate } from "./common.mjs";

function usage(events, prompt, result) {
  let reported = 0;
  for (const event of events) {
    if (!event.usage) continue;
    reported += Number(event.usage?.output_tokens ?? event.usage?.outputTokens ?? event.usage?.total_tokens ?? event.usage?.totalTokens ?? 0);
  }
  if (reported) return { tokens: reported, accounting: "reported" };
  const observed = prompt.length + result.length + events.reduce((sum, event) => sum + JSON.stringify(event).length, 0);
  return { tokens: Math.ceil(observed / 3.2), accounting: "conservative-estimate" };
}

async function call(root, prompt, plan, resume = "") {
  const cli = process.env.AIWORKS_CURSOR_CLI || "cursor-agent";
  const args = ["-p", "--trust", "--output-format", "stream-json", "--stream-partial-output", "--model", "auto"];
  if (resume) args.push("--resume", resume);
  if (plan) args.push("--mode", "plan"); else args.push("--force");
  const result = await runProcess(cli, args, prompt, { root });
  const events = parseJsonLines(result.stdout);
  const terminal = [...events].reverse().find((event) => event.type === "result");
  if (!terminal || terminal.is_error) throw new Error("Cursor stream ended without a successful result event");
  return {
    text: String(terminal.result || ""),
    session: String(terminal.session_id || ""),
    usage: usage(events, prompt, String(terminal.result || "")),
  };
}

export async function run({ root, definition, prompt, schema }) {
  const plan = definition.data.permissionMode === "plan";
  let response = await call(root, prompt, plan);
  let spent = response.usage.tokens;
  let accounting = response.usage.accounting;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const value = jsonCandidate(response.text);
      const errors = validate(value, schema);
      if (!errors.length) return { value, spent, accounting };
      if (attempt === 2) throw new Error(errors.join("\n"));
      response = await call(root, `Your prior response failed JSON Schema validation:\n- ${errors.join("\n- ")}\nReturn only a corrected JSON object.`, plan, response.session);
    } catch (error) {
      if (attempt === 2) throw error;
      response = await call(root, `Your prior response was not valid JSON: ${error.message}\nReturn only a corrected JSON object.`, plan, response.session);
    }
    spent += response.usage.tokens;
    if (response.usage.accounting !== "reported") accounting = response.usage.accounting;
  }
  throw new Error("Cursor schema correction exhausted");
}

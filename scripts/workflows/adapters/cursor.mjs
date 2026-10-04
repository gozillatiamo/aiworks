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

// Every call starts on `auto` (docs/adr/0023). Measured on cursor-agent 2026.09.26: `auto` ran
// while `--model opus`/`sonnet` were refused with an ActionRequiredError on the account's usage
// limit, and `haiku`/`fable` are not Cursor ids at all. When `auto` itself is blocked the same
// way, one retry on the role tier's fallback is the only move the adapter makes; every other
// failure is rethrown untouched (docs/adr/0040). Ids verified against this account's
// `cursor-agent --list-models`; a stale one fails closed with `Cannot use this model`.
const FALLBACK = { fable: "grok-4.7-high", opus: "grok-4.7-high", sonnet: "grok-4.7-high", haiku: "composer-2.5" };
export const fallbackModel = (tier) => FALLBACK[tier] || FALLBACK.opus;
export const isUsageLimit = (error) => /ActionRequiredError|hit your usage limit/i.test(String(error?.message || ""));

async function call(root, prompt, plan, model, resume = "") {
  const cli = process.env.AIWORKS_CURSOR_CLI || "cursor-agent";
  const args = ["-p", "--trust", "--output-format", "stream-json", "--stream-partial-output", "--model", model];
  if (resume) args.push("--resume", resume);
  if (plan) args.push("--mode", "plan"); else args.push("--force");
  const result = await runProcess(cli, args, prompt, { root });
  const events = parseJsonLines(result.stdout);
  const terminal = [...events].reverse().find((event) => event.type === "result");
  // The result text rides on the error so a limit reported in-stream is recognisable too.
  if (!terminal || terminal.is_error) throw new Error(`Cursor stream ended without a successful result event: ${terminal?.result || ""}`);
  return {
    text: String(terminal.result || ""),
    session: String(terminal.session_id || ""),
    usage: usage(events, prompt, String(terminal.result || "")),
  };
}

// The schema-correction loop is the only place the framework re-invokes an agent on its own account,
// and every correction is a full call with a full bill. The bound was already here; what was missing
// is that the paths which GIVE UP threw a bare error, and run.mjs charges `result.spent` only when a
// call returns. So a definition that failed after three corrections reported the cost of none of
// them: four agent calls, zero tokens on the run's budget, and a phase that quietly cost the most
// showing as the phase that cost nothing. Carry the running total out on the error too, and name the
// bound in the message so a reader of the failure knows how many attempts they are looking at.
const CORRECTION_ATTEMPTS = 3;

export async function run({ root, definition, prompt, schema, options = {} }) {
  const plan = definition.data.permissionMode === "plan";
  const tier = options.model || definition.data.model;
  let model = "auto";
  // Falls back at most once per run(): after it, `model` is no longer "auto" and a second block
  // is rethrown. Corrections resume on whatever model the session is on (AC5).
  async function invoke(text, resume) {
    try { return await call(root, text, plan, model, resume); }
    catch (error) {
      if (model !== "auto" || !isUsageLimit(error)) throw error;
      model = fallbackModel(tier);
      process.stderr.write(`aiworks workflow: Cursor usage limit on auto — retrying ${tier || "untiered"} role on ${model}\n`);
      return call(root, text, plan, model, resume);
    }
  }
  let response = await invoke(prompt);
  let spent = response.usage.tokens;
  let accounting = response.usage.accounting;
  try {
    for (let attempt = 0; attempt < CORRECTION_ATTEMPTS; attempt += 1) {
      const last = attempt === CORRECTION_ATTEMPTS - 1;
      let correction;
      try {
        const value = jsonCandidate(response.text);
        const errors = validate(value, schema);
        if (!errors.length) return { value, spent, accounting };
        if (last) throw new Error(errors.join("\n"));
        correction = `Your prior response failed JSON Schema validation:\n- ${errors.join("\n- ")}\nReturn only a corrected JSON object.`;
      } catch (error) {
        if (last) throw error;
        correction = `Your prior response was not valid JSON: ${error.message}\nReturn only a corrected JSON object.`;
      }
      response = await invoke(correction, response.session);
      spent += response.usage.tokens;
      if (response.usage.accounting !== "reported") accounting = response.usage.accounting;
    }
    throw new Error(`Cursor schema correction exhausted after ${CORRECTION_ATTEMPTS} attempts`);
  } catch (error) {
    error.spent = spent;
    error.accounting = accounting;
    throw error;
  }
}

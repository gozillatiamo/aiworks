import { spawn } from "node:child_process";
import process from "node:process";

export function runProcess(command, args, prompt, { root, env = {} }) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: root,
      env: { ...process.env, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; process.stderr.write(chunk); });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        const diagnostic = [stdout.trim(), stderr.trim()].filter(Boolean).join("\n");
        const error = new Error(`${command} exited ${code}: ${diagnostic}`);
        error.stdout = stdout;
        reject(error);
      }
      else resolve({ stdout, stderr });
    });
    child.stdin.end(prompt);
  });
}

export function parseJsonLines(text) {
  return text.split(/\r?\n/).filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
}

export function jsonCandidate(text) {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const value = (fenced ? fenced[1] : text).trim();
  try { return JSON.parse(value); } catch {}
  const first = value.indexOf("{");
  const last = value.lastIndexOf("}");
  if (first >= 0 && last > first) return JSON.parse(value.slice(first, last + 1));
  throw new Error("final response did not contain a JSON object");
}

function typeMatches(value, type) {
  if (type === "null") return value === null;
  if (type === "array") return Array.isArray(value);
  if (type === "object") return value !== null && typeof value === "object" && !Array.isArray(value);
  if (type === "integer") return Number.isInteger(value);
  if (type === "number") return typeof value === "number" && Number.isFinite(value);
  return typeof value === type;
}

export function validate(value, schema, at = "$") {
  const errors = [];
  if (!schema || typeof schema !== "object") return errors;
  const types = schema.type ? (Array.isArray(schema.type) ? schema.type : [schema.type]) : [];
  if (types.length && !types.some((type) => typeMatches(value, type))) {
    return [`${at}: expected ${types.join("|")}`];
  }
  if (schema.enum && !schema.enum.some((item) => JSON.stringify(item) === JSON.stringify(value))) {
    errors.push(`${at}: expected one of ${schema.enum.map(JSON.stringify).join(", ")}`);
  }
  if (Array.isArray(value) && schema.items) {
    value.forEach((item, index) => errors.push(...validate(item, schema.items, `${at}[${index}]`)));
  }
  if (value && typeof value === "object" && !Array.isArray(value)) {
    for (const key of schema.required || []) if (!(key in value)) errors.push(`${at}.${key}: required`);
    const properties = schema.properties || {};
    for (const [key, item] of Object.entries(value)) {
      if (properties[key]) errors.push(...validate(item, properties[key], `${at}.${key}`));
      else if (schema.additionalProperties === false) errors.push(`${at}.${key}: additional property is forbidden`);
    }
  }
  return errors;
}

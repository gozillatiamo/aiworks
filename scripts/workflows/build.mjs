#!/usr/bin/env node
// A workflow script reaches the Workflow tool as bytes and as nothing else, and the tool
// caps the FILE at 524,288 bytes. That cap was measured against the live runtime rather
// than read off the schema: a 524,288-byte script launches, a 524,289-byte one comes back
// `Workflow script file … exceeds 524288 bytes`, and `scriptPath` buys no exemption — the
// file is weighed before it is parsed, whichever parameter delivers it.
//
// dev-cycle.js walked into that wall from underneath. Across 41 commits it went from
// 120,083 bytes to 522,045, at a mean of +5,189 bytes per fix, and nothing anywhere in the
// workspace measured it — so the wall was found by a run that would not start, in a clone
// 5,804 bytes over. A third of that weight is comments, and in THIS codebase the comments
// are the design record: run-endings.md, the ADRs and every gate's rationale are written
// beside the code they govern, and deleting them to buy bytes would spend the one thing
// that stops the next regression in order to survive this one.
//
// So the authored file keeps every word and the runtime is handed none of them. This
// strips whole-line `//` comments — the runtime never executes a comment, so removing one
// cannot change what a run does — and writes the result to .claude/workflows/.build/.
// Trailing comments are deliberately left alone: they are 8,109 bytes against the
// whole-line rule's 176,007, and they are the ones that sit close enough to live code for
// a scanning mistake to cost something.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const SRC_DIR = path.join(ROOT, '.claude', 'workflows')
const OUT_DIR = path.join(SRC_DIR, '.build')

// Measured against the live runtime, not assumed: 524,288 launches, 524,289 is refused.
export const CAP = 524288
// The reserve is sized from the growth that produced the failure — twelve commits at the
// measured +5,189 bytes each — so a breach is reported while there is still room to act on
// it, rather than by the run that cannot start.
export const RESERVE = 65536
export const BUDGET = CAP - RESERVE

// Strip whole-line `//` comments, and only those. The scanner tracks the four states in
// which a `/` means something other than the start of a comment — a quoted string, a
// template literal (with `${}` nesting, which can re-enter code and then another
// template), a regular-expression literal, and a block comment — because dev-cycle.js is
// mostly agent brief text, and a brief that happens to show a shell comment or a URL is
// content, not commentary. Verified on the real file: the scan ends with its state stack
// balanced, and all 1,939 whole-line comments it finds are in code state.
export function strip(src, removed = []) {
  const out = []
  const stack = []                 // 'tpl' | 'expr' | 'brace' — empty means plain code
  let i = 0, keep = 0, prev = '', word = ''
  const lineStart = (p) => { let q = p - 1; while (q >= 0 && (src[q] === ' ' || src[q] === '\t')) q--; return q < 0 || src[q] === '\n' ? q + 1 : -1 }
  // `return /x/` and `case /x/` are regex literals whose previous character is a word
  // character, which is exactly what the usual one-character heuristic gets wrong.
  const KEYWORD = /\b(return|typeof|instanceof|in|of|new|delete|void|case|do|else|yield|await)$/
  const regexOk = () => KEYWORD.test(word) || !/[\w$)\]`]$/.test(prev)
  while (i < src.length) {
    const c = src[i], d = src[i + 1], top = stack[stack.length - 1]
    if (top === 'tpl') {                                    // inside `…` — nothing here is code
      if (c === '\\') { i += 2; continue }
      if (c === '$' && d === '{') { stack.push('expr'); i += 2; continue }
      if (c === '`') { stack.pop(); i++; continue }
      i++; continue
    }
    if (c === '`') { stack.push('tpl'); i++; prev = '`'; word = ''; continue }
    if (c === '{') { if (top === 'expr' || top === 'brace') stack.push('brace'); i++; prev = '{'; word = ''; continue }
    if (c === '}') { if (top === 'expr' || top === 'brace') stack.pop(); i++; prev = '}'; word = ''; continue }
    if (c === '"' || c === "'") {
      const q = c; i++
      while (i < src.length) { if (src[i] === '\\') { i += 2; continue } if (src[i] === q) { i++; break } i++ }
      prev = 'x'; word = ''; continue
    }
    if (c === '/' && d === '/') {
      const nl = src.indexOf('\n', i)
      const end = nl < 0 ? src.length : nl + 1
      const start = lineStart(i)
      // `// >>> AIWORKS:CONFIG START/END <<<` are not commentary, they are the boundaries
      // `aiworks config` writes the generated registry between. A derived artifact that
      // loses them is one nobody can regenerate or reason about, so they stay.
      if (start >= 0 && !src.slice(start, end).includes('AIWORKS:')) { out.push(src.slice(keep, start)); removed.push(src.slice(start, end)); keep = end }
      i = end; prev = 'x'; word = ''; continue
    }
    if (c === '/' && d === '*') { const e = src.indexOf('*/', i); i = e < 0 ? src.length : e + 2; prev = 'x'; word = ''; continue }
    if (c === '/' && regexOk()) {
      i++; let cls = false
      while (i < src.length) {
        if (src[i] === '\\') { i += 2; continue }
        if (src[i] === '[') cls = true
        else if (src[i] === ']') cls = false
        else if (src[i] === '/' && !cls) { i++; break }
        else if (src[i] === '\n') break                    // not a regex after all; give up on the line
        i++
      }
      prev = 'x'; word = ''; continue
    }
    if (!/\s/.test(c)) { prev = c; word = /[\w$]/.test(c) ? word + c : '' }
    i++
  }
  out.push(src.slice(keep))
  return out.join('')
}

// The strip is only allowed to ship if it can be shown to have removed comments and nothing
// else. A scanner that loses track of its state removes something that reads like a comment
// and is not one, and the byte count alone would look exactly like a success — so the
// removal is checked rather than trusted. Every removed span must itself be a whole `//`
// line; the output must still parse; and stripping the output again must change nothing,
// which is only true if the first pass ended in the state it thought it was in.
export function verify(src, out) {
  const problems = []
  const removed = []
  if (strip(src, removed) !== out) problems.push('strip is not deterministic — two runs over the same source disagree')
  const bad = removed.find((span) => !/^[ \t]*\/\/[^\n]*\n?$/.test(span))
  if (bad) problems.push(`removed a span that is not a whole-line comment: ${JSON.stringify(bad.slice(0, 80))}`)
  // Every byte the output is missing has to be accounted for by one of those spans. This is
  // what catches a scanner that silently swallowed a stretch of code on its way past.
  const accounted = removed.reduce((n, s) => n + s.length, 0)
  if (accounted !== src.length - out.length) problems.push(`removed spans account for ${accounted} characters but the output is ${src.length - out.length} shorter`)
  // A workflow body is an async function body — it uses top-level `await` — so a plain
  // `new Function` would reject a perfectly good script and call the strip broken.
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
  try { new AsyncFunction(out.replace(/^export /gm, '')) } catch (e) { problems.push(`output does not parse: ${e.message}`) }
  if (strip(out) !== out) problems.push('output still contains whole-line comments — the strip is not idempotent')
  return problems
}

function report(name, authored, delivered) {
  const pct = ((delivered / CAP) * 100).toFixed(1)
  const over = delivered - BUDGET
  const status = delivered > CAP ? 'FAIL' : delivered > BUDGET ? 'FAIL' : 'ok'
  const room = Math.floor((BUDGET - delivered) / 5189)
  const tail = status === 'ok'
    ? `${BUDGET - delivered} bytes under budget (~${room} commits of measured runway)`
    : delivered > CAP
      ? `${delivered - CAP} bytes OVER THE HARD CAP — this workflow cannot launch at all`
      : `${over} bytes into the ${RESERVE}-byte reserve — the next fix takes it over the cap`
  console.log(`  ${status === 'ok' ? 'ok  ' : 'FAIL'} ${name}  authored=${authored}  delivered=${delivered} (${pct}% of cap)  ${tail}`)
  return status === 'ok'
}

// Importable: the selftests drive strip() and verify() directly, and importing must not
// build anything or call process.exit.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main()

function main() {
const names = process.argv.slice(2).filter((a) => !a.startsWith('--'))
const check = process.argv.includes('--check')
const scripts = (names.length ? names : fs.readdirSync(SRC_DIR).filter((f) => f.endsWith('.js')).map((f) => f.slice(0, -3))).sort()

let ok = true
if (!check) fs.mkdirSync(OUT_DIR, { recursive: true })
for (const name of scripts) {
  const srcPath = path.join(SRC_DIR, `${name}.js`)
  if (!fs.existsSync(srcPath)) { console.error(`  FAIL ${name}  no such workflow: ${srcPath}`); ok = false; continue }
  const src = fs.readFileSync(srcPath, 'utf8')
  const out = strip(src)
  // Cheap enough to run on every build and every check, and the one thing that separates
  // "smaller" from "smaller and unchanged in behaviour".
  const problems = verify(src, out)
  for (const p of problems) { console.error(`  FAIL ${name}  ${p}`); ok = false }
  ok = report(name, Buffer.byteLength(src), Buffer.byteLength(out)) && ok
  if (!check && !problems.length) {
    const outPath = path.join(OUT_DIR, `${name}.js`)
    fs.writeFileSync(outPath, out)
    console.log(outPath)
  }
}
process.exit(ok ? 0 : 1)
}

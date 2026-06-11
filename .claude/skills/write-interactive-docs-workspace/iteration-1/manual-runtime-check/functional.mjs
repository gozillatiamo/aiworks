// Functional test: simulate a human making decisions in the page and assert the
// Implementation Plan markdown (what the build reads) updates in real time. Also
// assert the engine is inert when approval mode is off.
import fs from "fs";
import { JSDOM, VirtualConsole } from "jsdom";

const docPath = new URL("./fm-12-plan.html", import.meta.url);
const raw = fs.readFileSync(docPath, "utf8")
  .replace(/<script src="https:\/\/cdn[^>]*><\/script>/g, "")
  .replace(/mermaid\.initialize\([\s\S]*?\}\);/, "");

let fails = 0;
const ok = (c, m) => { console.log((c ? "  ✓ " : "  ✗ FAIL ") + m); if (!c) fails++; };

/* ---- 1. realtime decisions flow into the plan markdown ---- */
const win = new JSDOM(raw, { runScripts: "dangerously", virtualConsole: new VirtualConsole() }).window;
await new Promise((r) => setTimeout(r, 350));

const doc = win.document;
// pick the non-recommended option in the comparison section
const compareSec = doc.querySelector('[data-section-id="compare"]');
const radios = compareSec.querySelectorAll('.wid-decision input[type=radio]');
const serverPush = [...radios].find((r) => r.value === "Server push");
serverPush.checked = true;
serverPush.dispatchEvent(new win.Event("change", { bubbles: true }));

// type a modification note on the Data model section
const dataSec = doc.querySelector('[data-section-id="data"]');
const note = dataSec.querySelector(".wid-decision-note");
note.value = "Use a separate table; index by pet_id.";
note.dispatchEvent(new win.Event("input", { bubbles: true }));

await new Promise((r) => setTimeout(r, 50));

// the plan island must now carry both decisions...
const planIsland = JSON.parse(doc.querySelector('[data-section-id="implementation-plan"] script.export-data').textContent);
ok(Array.isArray(planIsland.decisions) && planIsland.decisions.length === 2,
  `plan island carries 2 live decisions (got ${planIsland.decisions ? planIsland.decisions.length : 0})`);
ok(planIsland.decisions.some((d) => d.choice === "Server push"),
  "a non-default option choice is recorded as a deviation");
ok(planIsland.decisions.some((d) => /separate table/i.test(d.note || "")),
  "a free-text modification is recorded");

// ...and the visible mirror updated in real time
const mirror = doc.querySelector('[data-section-id="implementation-plan"] .wid-plan-decisions');
ok(mirror && /Server push/.test(mirror.textContent), "visible 'Human decisions' mirror updated in real time");

// ...and the EXPORTED markdown (what --approve-plan reads) reflects them
const md = win.WID.pageMd(win.WID.pageModel());
ok(/Human decisions \(approved\)/.test(md), "exported markdown has a Human decisions block");
ok(/Server push/.test(md) && /separate table/i.test(md), "exported markdown reflects both human decisions");
ok(/scheduler\.dart/.test(md), "exported markdown still contains the original steps");

// accept-as-proposed must NOT pollute (overview + flow sections left untouched → only 2 decisions)
ok(planIsland.decisions.length === 2, "untouched sections (accepted) add no noise to the plan");

/* ---- 2. engine is inert when approval mode is off ---- */
const off = raw.replace(/data-plan-approval="pending"/, "").replace(/data-plan-md="[^"]*"/, "").replace(/data-plan-cmd="[^"]*"/, "");
const win2 = new JSDOM(off, { runScripts: "dangerously", virtualConsole: new VirtualConsole() }).window;
await new Promise((r) => setTimeout(r, 300));
ok(typeof win2.WIDPlan === "undefined", "engine does NOT activate without data-plan-approval");
ok(win2.document.querySelectorAll(".wid-decision").length === 0, "no Decision controls injected when off");
ok(!win2.document.querySelector(".wid-plan-approve"), "no Approve button injected when off");
ok(!!win2.WID, "export engine still works in non-plan docs");

console.log("\n" + (fails === 0 ? "ALL PASS ✅" : fails + " FAILURE(S) ✗"));
process.exit(fails ? 1 : 0);

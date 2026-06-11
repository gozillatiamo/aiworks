// Assembles a realistic PLAN doc in approval mode with all engines inlined,
// so verify-doc.mjs exercises the new plan-approval path end-to-end.
import fs from "fs";
const SK = "/Users/employee/projects/personal/couple-t/workspace-template/.claude/skills/write-interactive-docs/assets";
const exportEngine = fs.readFileSync(`${SK}/export-engine.js`, "utf8");
const diagramEngine = fs.readFileSync(`${SK}/diagram-interactions.js`, "utf8");
const planEngine = fs.readFileSync(`${SK}/plan-approval.js`, "utf8");

const html = `<!doctype html>
<html lang="en" data-theme="light">
<head><meta charset="utf-8"><title>FM-12 — Meal reminder plan</title>
<style>
:root{--font-sans:system-ui,sans-serif;--font-mono:monospace;--color-bg:#f3faf8;--color-surface:#fff;
--color-surface-2:#e6f4f0;--color-text:#13201c;--color-muted:#5a6b66;--color-border:#d6e8e3;
--color-primary:#0e9f8e;--color-accent:#ff7a59;--c-info:#3b82f6;--c-tip:#14b8a6;--c-warning:#f59e0b;
--c-danger:#ef4444;--c-success:#22c55e;--radius:14px;--shadow:0 1px 2px rgba(0,0,0,.06);--maxw:880px;}
body{margin:0;background:var(--color-bg);color:var(--color-text);font-family:var(--font-sans);line-height:1.65}
.doc-wrap{max-width:var(--maxw);margin:0 auto;padding:0 20px 120px}
.doc-section{padding:30px 0;border-bottom:1px solid var(--color-border);position:relative}
.compare{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(220px,1fr))}
.compare-card{border:1px solid var(--color-border);border-radius:var(--radius);padding:16px;background:var(--color-surface)}
.compare-card.is-recommended{border-color:var(--color-accent)}
.plan{border:1px dashed var(--color-primary);border-radius:var(--radius);padding:18px}
.plan .target{font-family:var(--font-mono);font-size:13px;color:var(--color-primary)}
</style></head>
<body>
<main class="doc-wrap" data-doc data-doc-title="FM-12 — Meal reminder plan" data-doc-project="FeeedMe"
      data-plan-approval="pending"
      data-plan-md="agent_logs/development-planner/FM-12-app-plan.md"
      data-plan-cmd="/dev-cycle FM-12 --approve-plan">

  <header class="doc-hero"><h1>FM-12 — Meal reminder plan</h1>
  <p>How we'll add a daily meal reminder to the pet's care screen.</p></header>

  <section class="doc-section" data-section data-section-title="Overview" data-section-id="overview">
    <h2>Overview</h2>
    <p>Owners forget meals. A local daily reminder nudges them at a chosen time.</p>
  </section>

  <section class="doc-section" data-section data-section-title="Scheduling approach" data-section-id="compare" data-block="comparison">
    <h2>Scheduling approach</h2>
    <div class="compare">
      <div class="compare-card is-recommended"><span class="badge">Recommended</span><h4>Local notifications</h4>
        <ul class="pros"><li>Works offline</li></ul><ul class="cons"><li>OS-throttled</li></ul></div>
      <div class="compare-card"><h4>Server push</h4>
        <ul class="pros"><li>Central control</li></ul><ul class="cons"><li>Needs backend + network</li></ul></div>
    </div>
    <script type="application/json" class="export-data">
      {"type":"comparison","title":"Scheduling approach","options":["Local notifications","Server push"],
       "criteria":[{"name":"Offline","values":["Yes","No"]}],"recommended":"Local notifications",
       "rationale":"Offline-first app; no backend today."}
    </script>
  </section>

  <section class="doc-section" data-section data-section-title="Data model" data-section-id="data">
    <h2>Data model</h2>
    <p>Store reminders in the existing local store.</p>
    <script type="application/json" class="decision-data">
      {"question":"One reminders table, or per-pet embedded?","options":["Separate table","Embedded in pet"],"default":"Separate table"}
    </script>
  </section>

  <section class="doc-section" data-section data-section-title="How it flows" data-section-id="flow">
    <h2>How it flows</h2>
    <figure class="diagram" data-block="diagram">
      <pre class="mermaid">flowchart LR
  U[Owner] --> S[Set time] --> N[Local notif]</pre>
      <figcaption>Reminder flow.</figcaption>
      <script type="application/json" class="export-data">
        {"type":"diagram","diagramType":"flowchart","title":"Reminder flow",
         "source":"flowchart LR\\n  U[Owner] --> S[Set time] --> N[Local notif]",
         "nodes":{"Local notif":{"detail":"Scheduled on-device via flutter_local_notifications."}}}
      </script>
    </figure>
  </section>

  <section class="doc-section" data-section data-section-title="Implementation Plan" data-section-id="implementation-plan" data-block="steps">
    <h2>Implementation Plan</h2>
    <div class="plan"><ol>
      <li><strong>Add the scheduler.</strong> <span class="target">lib/features/reminders/scheduler.dart</span></li>
      <li><strong>Acceptance:</strong> a set reminder fires at the chosen local time.</li>
    </ol></div>
    <script type="application/json" class="export-data">
      {"type":"steps","title":"Implementation Plan","steps":[
        {"title":"Add the scheduler","md":"\`lib/features/reminders/scheduler.dart\`"},
        {"title":"Acceptance","md":"A set reminder fires at the chosen local time."}]}
    </script>
  </section>
</main>

<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<script>mermaid.initialize({startOnLoad:true,theme:"base",securityLevel:"loose"});</script>
<script>${exportEngine}</script>
<script>${diagramEngine}</script>
<script>${planEngine}</script>
</body></html>`;

fs.writeFileSync(new URL("./fm-12-plan.html", import.meta.url), html);
console.log("wrote fm-12-plan.html");

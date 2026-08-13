# Graph Report - ai-workspace  (2026-08-13)

## Corpus Check
- 207 files · ~227,444 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 878 nodes · 1242 edges · 63 communities (53 shown, 10 thin omitted)
- Extraction: 92% EXTRACTED · 7% INFERRED · 1% AMBIGUOUS · INFERRED: 88 edges (avg confidence: 0.78)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `a9f96e42`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Agent Roster and Dev Harness
- bluePi Workspace CLAUDE.md
- Prod PII Vault (HMAC digests only)
- speak.sh
- scripts/notify/send.sh
- Jira Tracker Adapter Internals
- Interactive Doc Authoring
- Output Language Policy
- Stagehand Window Placement
- Design and Slide References
- Brand Assets and Design Tokens
- Logo and Corporate Identity
- ui-styling skill
- Ticket Estimation
- Ticket Skills and Templates
- Doc-Only Graphify Scope
- Kubernetes and Cloud Triage
- Read-Only Deployed Access ADRs
- Incremental Update
- ux-ui-designer agent (Jane)
- Extraction Subagent Prompt
- graphify Skill Pipeline
- Coding Skills and Plan Logs
- graphify Query and Traversal
- Gitflow and Config Conventions
- Deployed Root-Cause Method
- qa-runner agent (Peter)
- qa-planner agent (Peter)
- TDD and Test Design
- Review Verdict Basis
- graphify — operating the doc graph
- Cursor Mirror and Compression
- Production Case Reporting
- Test Result Reporting
- Load Gate and Plan Artifacts
- Ultra-Review Gate Orchestration
- Token Usage Reporting
- Load-Test Noise Floor Comparison
- QA Sub-Tasks and BDD
- Redis Triage and PII Egress
- Code minimalism is a plugin, scoped by agent, not a prompt
- Debug Adapter Tooling
- Diagram Attachment to Tickets
- Ticket Approval Rules
- Coding and Test Standards
- Voice Output Settings
- Ponytail
- Handoff States and Deferral
- Image Generation Pipeline
- Slack Dispatch Routing
- PR Comment Threads
- Handoff and Coding Guidelines
- Artifact Publishing Gate
- Ticket Writability Rules
- Org vs Framework Knowledge Split
- Worktree Liveness Checks
- Vendored Assets Docs
- Chrome Profile Resolution
- Browser Tab Reuse
- Optional Export Flags
- Binary Uploads Refused, Never Rewritten
- Inner-System Identity Always Survives
- AST Structural Extraction

## God Nodes (most connected - your core abstractions)
1. `qa-runner agent (Peter)` - 29 edges
2. `graphify Skill Pipeline` - 24 edges
3. `qa-planner agent (Peter)` - 24 edges
4. `Noah — Senior Fullstack Developer Agent` - 22 edges
5. `bluePi Workspace CLAUDE.md` - 20 edges
6. `brand skill` - 19 edges
7. `design-system (skill)` - 18 edges
8. `Liam — Oncall Agent (live-case investigation hat)` - 15 edges
9. `hcat` - 13 edges
10. `Extraction Subagent Prompt` - 13 edges

## Surprising Connections (you probably didn't know these)
- `Disposable Subagent For Huge Files` --semantically_similar_to--> `Parallel Subagent Dispatch`  [INFERRED] [semantically similar]
  docs/agents/headroom.md → .claude/skills/graphify/SKILL.md
- `Never Read .env Files (AGENTS.md)` --semantically_similar_to--> `Never Read .env Files`  [INFERRED] [semantically similar]
  AGENTS.md → CLAUDE.md
- `env Guard hcat Coverage` --semantically_similar_to--> `Adapter Pipe Guard`  [INFERRED] [semantically similar]
  docs/agents/headroom.md → CLAUDE.md
- `Graphify Stores A Map, Not The Text` --semantically_similar_to--> `Extraction Subagent Prompt`  [INFERRED] [semantically similar]
  docs/adr/0013-codegraph-keeps-the-code-graphify-maps-the-prose.md → .claude/skills/graphify/references/extraction-spec.md
- `Gate Threshold Tuning` --semantically_similar_to--> `Query Token Budget`  [INFERRED] [semantically similar]
  docs/agents/headroom.md → .claude/skills/graphify/references/query.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Business team flow: direction → feature briefs → feasibility → docs → tickets** — claude_agents_ceo_michael, claude_agents_cpo_emily, claude_agents_cto_thomas, claude_agents_documentor_david, claude_agents_product_owner_marcus [EXTRACTED 0.85]
- **Deployed-environment investigation toolchain (traces, logs, Redis, verdict discipline)** — _claude_skills_root_cause_deployed_skill_root_cause_deployed, _claude_skills_telemetry_triage_skill_telemetry_triage, _claude_skills_redis_triage_skill_redis_triage, _claude_skills_root_cause_deployed_skill_find_traces_sh, _claude_skills_root_cause_deployed_skill_get_logs_sh, _claude_skills_telemetry_triage_skill_get_trace_sh [EXTRACTED 0.85]
- **Brand sync flow: guidelines → tokens JSON/CSS → prompt injection** — claude_skills_brand_skill_brand, claude_skills_brand_references_update_brand_update, docs_brand_guidelines_brand_guidelines, claude_skills_brand_scripts_sync_brand_to_tokens_sync_brand_to_tokens, assets_design_tokens_design_tokens_json, assets_design_tokens_design_tokens_css, claude_skills_brand_scripts_inject_brand_context_inject_brand_context [EXTRACTED 0.90]
- **The deployed-environment triage family: one prod gate, one read-only identity, human-only bootstrap** — docs_adr_0005_deployed_env_triage_and_the_prod_gate_triage_split, docs_adr_0007_kubernetes_triage_uses_a_separate_read_only_identity_k8s_identity, docs_adr_0009_bring_up_never_bootstraps_deployed_access_no_bootstrap_on_sync, docs_adr_0010_cloud_monitoring_triage_shares_the_read_only_identity_monitoring_triage, docs_adr_0005_deployed_env_triage_and_the_prod_gate_triage_prod_key, docs_adr_0005_deployed_env_triage_and_the_prod_gate_pii_vault_prod_only [EXTRACTED 0.90]
- **Agents and skills that resolve the same output-language directive before writing** — docs_agents_language_language_policy, claude_agents_qa_planner_qa_planner, claude_agents_qa_runner_qa_runner, claude_agents_ux_ui_designer_ux_ui_designer, claude_agents_ux_ui_planner_ux_ui_planner, claude_skills_apply_human_review_skill_apply_human_review, claude_skills_clarifying_ticket_skill_clarifying_ticket, claude_skills_decompose_ticket_skill_decompose_ticket, claude_skills_case_report_skill_case_report, claude_rules_workspace_config_local_workspace_config_local [EXTRACTED 0.90]
- **Parallel non-blocking review loop — reporters stream, developer drains one FIFO queue** — claude_agents_developer_noah, claude_agents_code_reviewer_daniel, claude_agents_guardian_engineer_ethan, claude_agents_performance_engineer_liam [EXTRACTED 0.90]
- **Read-Only Deployed Triage MCP Fleet + Shared Prod Gate** — scripts_db_readme_pg_triage_mcp, scripts_redis_readme_redis_triage_mcp, scripts_k8s_readme_k8s_triage_mcp, scripts_monitoring_readme_monitoring_triage_mcp, scripts_observability_readme_adapter, scripts_db_readme_triage_policy_py, docs_agents_pii_provenance_vault [EXTRACTED 0.90]
- **QA ticket pipeline: design → publish → automation plan → implement/run → report** — claude_agents_qa_planner_qa_planner, claude_agents_qa_runner_qa_runner, claude_skills_plan_testcases_skill_plan_testcases, claude_skills_plan_automate_skill_plan_automate, claude_skills_coding_automate_skill_coding_automate, claude_skills_report_test_results_skill_report_test_results, agent_logs_testcases, agent_logs_automation_plan, agent_logs_bugs, agent_logs_report [EXTRACTED 0.90]
- **Read-only deployed-environment triage family (layer-partitioned)** — _claude_skills_pg_triage_skill_pg_triage, _claude_skills_k8s_triage_skill_k8s_triage, _claude_skills_monitoring_triage_skill_monitoring_triage, _claude_skills_monitoring_triage_skill_triage_division_of_labour [EXTRACTED 0.90]
- **Layered Language-Directive Enforcement** — docs_agents_language_output_language_block, docs_agents_language_pretool_agent_context, docs_agents_language_resolve_language_sh, docs_agents_language_resolver_subagent, docs_agents_language_config_mirror, docs_agents_language_language_directive [EXTRACTED 0.95]
- **Review verdict grounded in the five basis sections** — _claude_skills_review_skill_review, _claude_skills_review_basis_requirements_are_the_bar, _claude_skills_review_basis_coding_standards_bottom_line, _claude_skills_review_basis_repo_knowledge_instrument, _claude_skills_review_basis_review_level, _claude_skills_review_basis_receipt_rule [EXTRACTED 0.95]
- **Three-layer token cascade (primitive → semantic → component)** — _claude_skills_design_system_references_primitive_tokens, _claude_skills_design_system_references_semantic_tokens, _claude_skills_design_system_references_component_tokens, _claude_skills_design_system_references_token_architecture, _claude_skills_design_system_references_tailwind_integration [EXTRACTED 0.95]
- **Tracker provider implementations of one interface** — scripts_tracker_readme_notion_impl_sh, scripts_tracker_readme_jira_impl_sh, scripts_tracker_readme_linear_impl_sh, scripts_tracker_readme_tracker_provider_interface, scripts_tracker_readme_lib_sh [EXTRACTED 0.95]
- **Ultra-review: two parallel gates aggregated into one capped verdict, backstopped, then approved** — _claude_skills_ultra_review_skill_ultra_review, _claude_skills_ultra_review_skill_code_reviewer_gate, _claude_skills_ultra_review_skill_performance_engineer_gate, _claude_skills_ultra_review_skill_backstop, _claude_skills_ultra_review_skill_pass_signal, _claude_skills_ultra_review_skill_ready_to_merge_advance, _claude_skills_ultra_review_skill_notify [EXTRACTED 0.95]
- **Graphify Build Pipeline** — _claude_skills_graphify_skill_detect, _claude_skills_graphify_skill_ast_structural_extraction, _claude_skills_graphify_skill_semantic_extraction, _claude_skills_graphify_skill_community_clustering, _claude_skills_graphify_skill_graph_json, _claude_skills_graphify_skill_graph_report, _claude_skills_graphify_skill_manifest [EXTRACTED 1.00]
- **Graphify Extraction Contract** — _claude_skills_graphify_references_extraction_spec_extraction_subagent_prompt, _claude_skills_graphify_references_extraction_spec_node_id_format, _claude_skills_graphify_references_extraction_spec_source_file_rule, _claude_skills_graphify_references_extraction_spec_confidence_score_rubric, _claude_skills_graphify_references_extraction_spec_confidence_taxonomy [EXTRACTED 1.00]
- **Headroom Compression Boundary** — docs_agents_headroom_hcat, docs_agents_headroom_hcat_gate, docs_agents_headroom_hcat_size_ceiling, docs_agents_headroom_env_guard_hcat_coverage, docs_agents_headroom_disposable_subagent, docs_agents_headroom_aiworks_doctor [EXTRACTED 1.00]
- **Ticket lifecycle: kickoff → branch → QA sub-tasks → results report → PR/merge → ship** — _claude_skills_ticket_kickoff_skill_ticket_kickoff, _claude_skills_self_control_gitflow_skill_self_control_gitflow, _claude_skills_qa_subtasks_skill_qa_subtasks, _claude_skills_report_test_results_skill_report_test_results, _claude_skills_review_skill_review, _claude_skills_ship_skill_ship [INFERRED 0.70]
- **dev-cycle delivery pipeline: plan → build → PR/MR → review → gate → merge** — context_dev_cycle, claude_agents_development_planner_george, claude_agents_developer_noah, claude_agents_code_reviewer_daniel, claude_agents_guardian_engineer_ethan, claude_agents_performance_engineer_liam [INFERRED 0.85]
- **Provider-dispatch adapter pattern (lib.sh + swappable impls)** — scripts_tracker_readme_lib_sh, scripts_vcs_readme_lib_sh, scripts_tracker_readme_tracker_provider_interface, scripts_vcs_readme_vcs_provider_interface, scripts_voice_readme [INFERRED 0.85]
- **Tracker-adapter ticket lifecycle (estimate → plan → automate → gate → PR → notify)** — _claude_skills_estimate_ticket_skill_estimate_ticket, _claude_skills_plan_testcases_skill_plan_testcases, _claude_skills_plan_automate_skill_plan_automate, _claude_skills_loadtest_baseline_gate_skill_loadtest_baseline_gate, _claude_skills_open_pr_skill_open_pr, _claude_skills_notify_skill_notify, _claude_skills_diagram_ticket_skill_diagram_ticket [INFERRED 0.85]

## Communities (63 total, 10 thin omitted)

### Community 0 - "Agent Roster and Dev Harness"
Cohesion: 0.07
Nodes (65): Michael — CEO Agent (conductor only), Daniel — Code Reviewer Agent (merge gate), Emily — CPO Agent, Thomas — CTO Agent, Noah — Senior Fullstack Developer Agent, prod_repro_seed.py — Sanctioned Masked Prod-data Seed, replay_shape.py — Synthetic Redis Shape Replay, scripts/dev.sh — Uniform Per-repo Dev Harness (+57 more)

### Community 1 - "bluePi Workspace CLAUDE.md"
Cohesion: 0.05
Nodes (60): Native CLAUDE.md Integration, Query Token Budget, Honesty Rules, No API Key Required, Never Read .env Files (AGENTS.md), Multi-Repo Workspace (AGENTS.md), bluePi Workspace Agent Instructions, Adapter Pipe Guard (+52 more)

### Community 2 - "Prod PII Vault (HMAC digests only)"
Cohesion: 0.08
Nodes (36): scripts/lib/pii_provenance.py, tracker_redact_prod_pii (egress), Prod PII Vault (HMAC digests only), env + target Selection (MAD / 16 hex shards), Layered Safety Model (pg_triage), scripts/lib/pg_staging.py (staging dbname config), pg_triage_mcp.py — Read-Only Deployed Postgres MCP, prod_repro_seed.py — Sanctioned Prod→Local Seed (+28 more)

### Community 3 - "speak.sh"
Cohesion: 0.07
Nodes (38): Tracker Adapter, VCS Adapter, Voice Adapter, ack.sh, Content-addressed audio cache, Chattiness ladder (terse..max), chattiness-selftest.sh (10 cases), dev-cycle.js Notify phase (+30 more)

### Community 4 - "scripts/notify/send.sh"
Cohesion: 0.06
Nodes (37): notify outbound_gate / redact_prod_pii, PII_GATE auto/on/off Knobs, Value-Level PII Provenance, Push-to-Talk Dictation, Mute Is an Off Switch, Not a Volume Knob, scripts/voice/notify-voice.sh (Slack voice note), alive / container / orphan Classification, Parallelism Invariant (no shared target dir) (+29 more)

### Community 5 - "Jira Tracker Adapter Internals"
Cohesion: 0.07
Nodes (35): add-ticket-comment.sh, Markdown to ADF renderer, Attachment carry-over on body rewrite, Dedup before filing, jira/discover-fields.sh, find-tickets.sh, get-ticket-comments.sh, get-ticket-details.sh (+27 more)

### Community 6 - "Interactive Doc Authoring"
Cohesion: 0.07
Nodes (33): Comparison block, Component library reference, decision-data island, The export contract (two readers), export-data island, Steps / Implementation Plan block, UI preview block, Diagrams reference (+25 more)

### Community 7 - "Output Language Policy"
Cohesion: 0.06
Nodes (33): Case-Report Language Exception, const LANGUAGE Config Mirror in Workflows, English Spine, Thai Prose Rule, LANGUAGE_DIRECTIVE (authoritative, per-prompt), Any .md File You Author Is English, ## Output language Block (agent + skill files), Personal Override via workspace.config.local.yaml, pretool-agent-context.sh (PreToolUse Agent hook) (+25 more)

### Community 8 - "Stagehand Window Placement"
Cohesion: 0.07
Nodes (33): Two Coordinate Traps (NSScreen vs AX, size-then-position), Focus Phrase (~phrase) → Text Fragment, scripts/stagehand/follow.sh, .claude/hooks/stagehand-follow.sh (Stop), .claude/hooks/stagehand-show.sh (PostToolUse), scripts/stagehand/lib.sh, Why Not computer-use, scripts/stagehand/place.js (+25 more)

### Community 9 - "Design and Slide References"
Cohesion: 0.13
Nodes (32): Banner Sizes & Art Direction Styles, Design Routing Guide, Icon Design Reference, Slides Reference, Copywriting Formulas, Slides Create (invocation stub), HTML Slide Template, Slide Layout Patterns (+24 more)

### Community 10 - "Brand Assets and Design Tokens"
Cohesion: 0.12
Nodes (28): assets/design-tokens.css, assets/design-tokens.json, ai-artist skill, ai-multimodal skill, assets-organizing skill, Banner sizes & art direction styles, banner-design skill, Asset approval checklist (+20 more)

### Community 11 - "Logo and Corporate Identity"
Cohesion: 0.10
Nodes (27): CIP Deliverable Guide, CIP Design Reference, CIP Mockup Prompt Engineering, CIP Design Style Guide, Logo Color Psychology, Logo Design Reference, Logo AI Prompt Engineering, Logo Style Guide (+19 more)

### Community 12 - "ui-styling skill"
Cohesion: 0.11
Nodes (24): Copywriting formulas (PAS/AIDA/FAB/BAB), slides create subcommand, Chart.js integration, HTML slide template, Slide layout patterns, search-slides.py (design-system script), Slide strategies + emotion arcs, slides skill (+16 more)

### Community 13 - "Ticket Estimation"
Cohesion: 0.12
Nodes (20): scripts/tracker/add-ticket-comment.sh, Board calibration set (10 recent Done), Dev+QA points written, total derived, estimate-ticket (skill), scripts/tracker/find-tickets.sh, scripts/tracker/get-ticket-comments.sh, scripts/tracker/get-ticket-details.sh, scripts/tracker/upsert-ticket-details.sh (+12 more)

### Community 14 - "Ticket Skills and Templates"
Cohesion: 0.16
Nodes (20): Attachment embed-id vs numeric id, update-ticket skill, clarifying-ticket skill, Clarified ticket templates, decompose-ticket skill, Decomposition piece-spec templates, diagram-ticket skill, estimate-ticket skill (+12 more)

### Community 15 - "Doc-Only Graphify Scope"
Cohesion: 0.18
Nodes (11): graphify MCP Stdio Server, Wiki Export, Whisper Domain-Hint Prompt, cluster-only Rerun, Community Detection And Labeling, God Nodes, agent_logs Excluded, Doc-Only Graphify Scope (+3 more)

### Community 16 - "Kubernetes and Cloud Triage"
Cohesion: 0.15
Nodes (15): disconnect (k8s MCP teardown), get_logs (k8s MCP tool), k8s-triage (skill), list_targets (k8s MCP tool), view-only impersonated identity (API-server enforced), monitoring-triage (skill), read_timeseries (Cloud Monitoring tool), Saturated-resource patterns (+7 more)

### Community 17 - "Read-Only Deployed Access ADRs"
Cohesion: 0.17
Nodes (15): PII provenance stays production-only, triage.prod — the one production opt-in, ADR-0005 — Triage covers every deployed env; only prod is gated, Targets derived from the GKE context name, Impersonation, not a key file, ADR-0007 — Kubernetes triage authenticates as a separate read-only identity, Bash(kubectl *) / Bash(gcloud *) denied to agents, LEGACY[] table swept by its own rename (+7 more)

### Community 18 - "Incremental Update"
Cohesion: 0.21
Nodes (12): URL Ingest (graphify add), Post-Commit Auto-Rebuild Hook, save-result Feedback Loop, Work Memory And LESSONS.md, Whisper Transcription, detect_incremental, Graph Diff After Update, Incremental Update (+4 more)

### Community 19 - "ux-ui-designer agent (Jane)"
Cohesion: 0.22
Nodes (15): agent_logs/Mia_ux-ui-planner/<work-key>-design-plan.md, ux-ui-designer agent (Jane), ux-ui-planner agent (Mia), Caveman savings statusline, refresh-savings.sh (Stop hook), statusline.sh, workspace.config.yaml, caveman skill (+7 more)

### Community 20 - "Extraction Subagent Prompt"
Cohesion: 0.20
Nodes (12): Discrete Confidence Score Rubric, EXTRACTED/INFERRED/AMBIGUOUS Taxonomy, DEEP_MODE Aggressive Inference, Extraction Subagent Prompt, Hyperedges, Rationale As Node Attribute, Semantic Similarity Edges, Vision Extraction Rules (+4 more)

### Community 21 - "graphify Skill Pipeline"
Cohesion: 0.22
Nodes (10): Cross-Repo Graph Merge, Monorepo Subfolder Extraction, GitHub Repo Clone, Cumulative Cost Tracker, Fast Path On Existing Graph, GRAPH_REPORT.md, graphify Skill Pipeline, .graphify_python Interpreter Sidecar (+2 more)

### Community 22 - "Coding Skills and Plan Logs"
Cohesion: 0.21
Nodes (13): agent_logs/<KEY>-automation-plan.md, agent_logs/<KEY>-bugs.md, Submodule checkout write ban, Bug log template, coding-automate skill, coding-feature skill, Workspace coding style, Ground truth first (+5 more)

### Community 23 - "graphify Query and Traversal"
Cohesion: 0.18
Nodes (12): Verbatim source_file Rule, BFS And DFS Traversal Modes, Constrained Query Expansion, Node Explanation, Graph Query Flow, Inline NetworkX Fallback, Shortest Path Between Concepts, build_merge Replace-On-Re-Extract (+4 more)

### Community 24 - "Gitflow and Config Conventions"
Cohesion: 0.24
Nodes (12): scripts/tracker/get-ticket-details.sh, Tracker adapter (scripts/tracker/), scripts/tracker/upsert-ticket-details.sh, workspace.config.yaml / .local.yaml, FINISH phase — PR/MR + self squash-merge, self-control-gitflow skill, START phase — branch before coding, Submodule guard (--show-superproject-working-tree) (+4 more)

### Community 25 - "Deployed Root-Cause Method"
Cohesion: 0.21
Nodes (12): Step 1 — Base rate before any hypothesis, Step 3 — Discriminator, scripts/observability/find-traces.sh, scripts/observability/get-logs.sh, Step 2 — Hypothesis ledger, root-cause-deployed skill, Step 4 — Verdict tiers (CONFIRMED/LEADING/SPECULATIVE), diagnosing-bugs skill (local red loop) (+4 more)

### Community 26 - "qa-runner agent (Peter)"
Cohesion: 0.18
Nodes (15): agent_logs/<KEY>-report.md, developer agent, development-planner agent, QA runner Bar (receipt-backed verdict), qa-runner agent (Peter), apply-human-review skill, loadtest-baseline-gate skill, report-test-results skill (+7 more)

### Community 27 - "qa-planner agent (Peter)"
Cohesion: 0.18
Nodes (14): agent_logs/<KEY>-testcases.md (BDD test plan), QA planner delegation contract, qa-planner agent (Peter), Workspace config files carry no comments, workspace.config.example.yaml, workspace.config.local.yaml, karpathy-guidelines skill, plan-testcases skill (+6 more)

### Community 28 - "TDD and Test Design"
Cohesion: 0.24
Nodes (11): Deep modules, Interface design for testability, Mock at system boundaries only, Refactor candidates, Horizontal slices anti-pattern, Red-green-refactor vertical slice loop, tdd skill, Good and bad tests (+3 more)

### Community 29 - "Review Verdict Basis"
Cohesion: 0.27
Nodes (10): docs/agents/issue-tracker.md, The basis for a review verdict, Codegraph callers/impact blast radius, §2 Coding standards are the bottom line, §3 The repo's knowledge is your instrument, §1 The requirements are the bar, §4 Review level (strict / thorough), review skill (+2 more)

### Community 30 - "graphify — operating the doc graph"
Cohesion: 0.22
Nodes (8): Adding docs to the graph, `graphify install` overreaches — review before committing, ⚠️ graphify needs no API key. The skill IS the LLM., graphify — operating the doc graph, It is TWO installs, and the second is the one people miss, ⚠️ Labels are positional — regenerate the `.sig`, ⚠️ Remove the post-checkout hook, What is committed, and what is not

### Community 31 - "Cursor Mirror and Compression"
Cohesion: 0.25
Nodes (9): Orchestrator-owned notify (combined verdict), ADR-0004 — Cursor is a generated mirror built from symlinks, Ignore the files, never the directory, Path-prefixed root rule globs, Output compression (caveman) convention, Compression is an OUTPUT rule — the first brief goes in FULL, about.mdc — Agent Requested repo card, Working this workspace from Cursor (+1 more)

### Community 32 - "Production Case Reporting"
Cohesion: 0.22
Nodes (9): case-report skill, k8s_triage, pg_triage (read-only deployed Postgres), redis_triage, root-cause-deployed skill, PII provenance convention, Case report template, Production troubleshooting guideline (+1 more)

### Community 33 - "Test Result Reporting"
Cohesion: 0.25
Nodes (8): Test-results report template, scripts/tracker/add-ticket-comment.sh, coding-automate skill, scripts/dev.sh per-repo harness (why/artifacts), scripts/pdf/render.sh, report-test-results skill, update-ticket skill, §5 Every claim carries a receipt

### Community 34 - "Load Gate and Plan Artifacts"
Cohesion: 0.25
Nodes (8): Equal-or-Better Load Gate, Never Fail Open — Receipt or Not Run, suite_kind: load (arms the gate), Production Case File (kind: script repo), One Plan File Per Touched Repo, Plan Artifact Canonical Paths, pretool-agent-brief-guard.sh, pretool-plan-path-guard.sh

### Community 35 - "Ultra-Review Gate Orchestration"
Cohesion: 0.33
Nodes (7): Shared verdict grounding (review/basis.md), Aggregation backstop (presence + language check), Code gate (Daniel, code-reviewer), Force-shell first line (no-Bash give-up fix), Performance gate (Liam, performance-engineer), Re-visit mode (prior must-fix only), ultra-review skill

### Community 36 - "Token Usage Reporting"
Cohesion: 0.38
Nodes (7): MISSION token metric (input+cacheWrite+output), parse_agent_usage.py, parse_team_usage.py, summarize-team-performance skill, [dev-cycle <ticket> role= phase= round=] marker, parse_workflow_usage.py, summarize-workflow-performance skill

### Community 37 - "Load-Test Noise Floor Comparison"
Cohesion: 0.29
Nodes (7): Attribute-First Fix Loop, Baseline Cache (repo/scenario/base-sha/env-fingerprint), compare.py Comparator, Effective Threshold = max(tolerance_pct, noise floor), Noise Floor Measurement, unavailable Verdict (loud-skip), Zero-Base Metric Fails Outright

### Community 38 - "QA Sub-Tasks and BDD"
Cohesion: 0.33
Nodes (6): BDD Given/When/And/Then scenario shape, QA sub-task worked example (E2E), Tool → Component mapping (Cypress/Newman/K6), docs/agents/language.md policy, Output language resolution block, qa-subtasks skill

### Community 39 - "Redis Triage and PII Egress"
Cohesion: 0.33
Nodes (6): capture_shape → replay_shape.py local repro, OFB Redis keyspace map, PII egress line (prod value masking), docs/agents/pii-provenance.md, Read-only tool surface guarantee, redis-triage skill

### Community 40 - "Code minimalism is a plugin, scoped by agent, not a prompt"
Cohesion: 0.12
Nodes (14): Code minimalism is a plugin, scoped by agent, not a prompt, What ponytail offers, What was rejected, Why not on every agent, Why the level is pinned, Why the plugin rather than our own prose, Why three carve-outs, and only three, Code minimalism (ponytail) (+6 more)

### Community 41 - "Debug Adapter Tooling"
Cohesion: 0.47
Nodes (6): Advanced debugging techniques, Installing debug adapters, dap CLI (DAP debugger driver), debugging-code skill, Vendored plugin skills note, scripts/aiworks-cursor.sh (vendor sync)

### Community 42 - "Diagram Attachment to Tickets"
Cohesion: 0.40
Nodes (5): scripts/tracker/add-ticket-attachment.sh, ADF media-UUID bridge (Jira embed), diagram-ticket (skill), scripts/diagram/live-link.sh, scripts/diagram/render.sh

### Community 43 - "Ticket Approval Rules"
Cohesion: 0.40
Nodes (5): Ticket-wide PASS approval (orchestrator-owned), Advance ticket to ready_to_merge (config-gated), No test receipt ⇒ no approval, Directive vs disposition, The `Human:` review-comment convention

### Community 44 - "Coding and Test Standards"
Cohesion: 0.50
Nodes (5): Backend Coding Standards (600-line cap, no in-body comments), Backend Test Standards (hard-coded date/time), Frontend Coding Standards (600-line cap, no in-body comments), Frontend Test Standards (hard-coded date/time), Never Read the Live Clock in a Test

### Community 45 - "Voice Output Settings"
Cohesion: 0.50
Nodes (4): chattiness — Spoken Budget Level, gate voice — Speech When the Run Waits, step narration, voice — Speaking/Listening Adapter

### Community 46 - "Ponytail"
Cohesion: 0.22
Nodes (8): Boundaries, Intensity, Output, Persistence, Ponytail, Rules, The ladder, When NOT to be lazy

### Community 47 - "Handoff States and Deferral"
Cohesion: 0.67
Nodes (3): The deferral verifier (downgrades to partial), ADR-0011 — Deferred scope does not stop a run, Four handoff states: complete / partial / blocked / deferred

### Community 48 - "Image Generation Pipeline"
Cohesion: 0.67
Nodes (3): Fail loud — never silent placeholder art, Image generation (graphic-designer asset pipeline), mcp-image MCP server (Gemini)

### Community 49 - "Slack Dispatch Routing"
Cohesion: 0.67
Nodes (3): agent:<name> / workflow:<name> Routing, aiworks_dispatch/catalog.py, aiworks_dispatch/slack_app.py

### Community 50 - "PR Comment Threads"
Cohesion: 0.67
Nodes (3): pr-comments.sh, pr-resolve-thread.sh, pr-threads.sh

### Community 59 - "Optional Export Flags"
Cohesion: 0.40
Nodes (6): FalkorDB Export, GraphML Export, Neo4j Export, Optional Export Flags, SVG Export, Token Reduction Benchmark

### Community 62 - "AST Structural Extraction"
Cohesion: 0.33
Nodes (6): Watch Debounce, Watch Mode Auto-Rebuild, Call Edge Direction And Language Rule, Node ID Format, Code-Only Update Fast Path, AST Structural Extraction

## Ambiguous Edges - Review These
- `design (skill)` → `diagram-ticket (skill)`  [AMBIGUOUS]
  .claude/skills/diagram-ticket/SKILL.md · relation: conceptually_related_to
- `bluePi Workspace CLAUDE.md` → `Native CLAUDE.md Integration`  [AMBIGUOUS]
  .claude/skills/graphify/references/hooks.md · relation: references
- `HTML slide template` → `Tailwind responsive design`  [AMBIGUOUS]
  .claude/skills/slides/references/html-template.md · relation: conceptually_related_to
- `graphify MCP Stdio Server` → `read_source MCP Tool Proposal`  [AMBIGUOUS]
  .claude/skills/graphify/references/exports.md · relation: references
- `ship skill` → `report-test-results skill`  [AMBIGUOUS]
  .claude/skills/ship/SKILL.md · relation: conceptually_related_to
- `identity.sh (worktree identity prefix)` → `get-ticket-details.sh`  [AMBIGUOUS]
  scripts/voice/README.md · relation: calls
- `handoff (skill)` → `karpathy-guidelines (skill)`  [AMBIGUOUS]
  .claude/skills/karpathy-guidelines/SKILL.md · relation: conceptually_related_to

## Knowledge Gaps
- **254 isolated node(s):** `It is TWO installs, and the second is the one people miss`, `⚠️ graphify needs no API key. The skill IS the LLM.`, `⚠️ Remove the post-checkout hook`, `⚠️ Labels are positional — regenerate the `.sig``, `What is committed, and what is not` (+249 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **10 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `design (skill)` and `diagram-ticket (skill)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **What is the exact relationship between `bluePi Workspace CLAUDE.md` and `Native CLAUDE.md Integration`?**
  _Edge tagged AMBIGUOUS (relation: references) - confidence is low._
- **What is the exact relationship between `HTML slide template` and `Tailwind responsive design`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **What is the exact relationship between `graphify MCP Stdio Server` and `read_source MCP Tool Proposal`?**
  _Edge tagged AMBIGUOUS (relation: references) - confidence is low._
- **What is the exact relationship between `ship skill` and `report-test-results skill`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **What is the exact relationship between `identity.sh (worktree identity prefix)` and `get-ticket-details.sh`?**
  _Edge tagged AMBIGUOUS (relation: calls) - confidence is low._
- **What is the exact relationship between `handoff (skill)` and `karpathy-guidelines (skill)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
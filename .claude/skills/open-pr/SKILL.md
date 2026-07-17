---
name: open-pr
description: Open a pull/merge request for the current ticket branch to its parent branch (feature/* → develop, fix/* → main, per workspace.config.yaml), titled per Conventional Commits — feat(<KEY>): <title> for a feature branch, fix(<KEY>): <title> for a fix branch. Attaches the implementor's visual results (screenshots, screen recordings, before/after images, demo videos) to the PR/MR body when any exist — so reviewers see the change, not just read about it. Uses the VCS adapter (github/gitlab). Use after QA has approved a ticket, and whenever opening a PR/MR for UI work or any change with images or video to show.
argument-hint: [ticket-number]
allowed-tools:
  - Bash(git *)
  - Bash(scripts/vcs/*)
  - Bash(scripts/tracker/*)
---

# Open PR

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write the PR/MR description body and review discussion you write (the PR title stays English, Conventional-Commit style) in **Thai prose with an English spine** — titles + every section heading + labels/enum values, ALL code + identifiers + commit messages + branch names, and technical / transliterated / domain terms + proper nouns stay English (Arabic numerals always); the sentences themselves are Thai. **Code, checked-in repo docs** (`docs/`, `README`, ADRs, committed PRD/BRD files), **and ANY file you author with a `.md` extension** (plans, testcases, PRD/summary Markdown in `agent_logs/`) are **never** Thai — the `th` prose rule applies to chat, tickets, PR/MR discussion, Slack, and `.html` docs only. Default **`en`** = unchanged; this block is a no-op. Full policy: `docs/agents/language.md`.

Ships an approved ticket as a pull/merge request through the **VCS adapter**
(`scripts/vcs/`), which targets `github` (`gh`) or `gitlab` (`glab`) — auto-detected
from the `origin` remote. Never call `gh`/`glab` directly.

A PR is the reviewer's first look at the work. For anything visual — a new screen, a
restyle, a fixed layout bug — a screenshot or a short screen recording communicates in
one glance what a paragraph of prose can't. So if the implementor produced any visual
results, attach them: the adapter hosts each file and embeds it in the PR/MR body under
a **## Visual results** section. The whole point is to spare the reviewer from checking
out the branch and running the app just to see what changed.

## Preconditions

- QA has approved the ticket.
- You are on the ticket's work branch with all work committed.

## Steps

1. **Determine the base _and_ the Conventional Commit type from the branch name**
   (branch model in `workspace.config.yaml`):
   - `feature/<KEY>` → base = `branch_model.feature_base` (default **`develop`**); type = **`feat`**.
   - `fix/<KEY>` → base = `branch_model.fix_base` (default **`main`**); type = **`fix`**.

2. **Resolve the ticket title** if not supplied:
   ```bash
   scripts/tracker/get-ticket-details.sh <KEY>   # first line is "<KEY> — <title>"
   ```

3. **Gather the implementor's visual results.** Collect anything that shows the change
   working — simulator/emulator screenshots, before/after pairs, a screen recording of
   the flow, an exported Figma comparison. Two sources, used together:
   - **The convention dir `agent_logs/<KEY>-media/`.** This is where implementors
     (developer, qa-runner) drop visual artifacts, matching the existing
     `agent_logs/<KEY>-*` pattern. Pass the directory — `open-pr.sh` scans it (one level
     deep) and attaches every image/video it finds.
   - **Explicit paths or URLs you already know about** — a specific screenshot you just
     captured, or media already hosted somewhere (Firebase, a CDN). Pass each with its
     own `--media`.

   If there genuinely are no visuals (e.g. a pure-logic or config change), skip this —
   `open-pr.sh` simply omits the section. Don't fabricate screenshots to fill it.

4. **Open (or reuse) the PR/MR** via the adapter — it pushes the branch, skips a
   duplicate, hosts each `--media` item, and prints the URL + `number=`. The title
   follows **Conventional Commits**: `<type>(<KEY>): <title>` — e.g. `feat(FM-9): Add pet`,
   `fix(FM-12): Crash on empty meal list`:
   ```bash
   scripts/vcs/open-pr.sh \
     --base <base> --head <work_branch> --ticket <KEY> \
     --title "<type>(<KEY>): <title>" \
     --body "<short summary of what changed + acceptance covered + Ticket: <url>>" \
     --media agent_logs/<KEY>-media/ \
     --media <any/extra/screenshot.png>
   ```
   `--media` is repeatable and accepts a file, a directory, or an http(s) URL. Drop the
   `--media` flags entirely when there's nothing to show. Add `--dry-run` first if you
   want to see the assembled body (including the visual-results section) before it posts.

## How media is hosted (per provider)

The adapter handles hosting so the URLs in the body just work — but the mechanism (and
what renders inline) differs, so set expectations honestly:

- **GitLab** — uploaded via the project uploads API; images **and** video render inline
  in the MR. The cleanest case.
- **GitHub** — there is no token-scriptable way to attach a file to a PR body (the web
  drag-and-drop uses a private browser endpoint). The adapter instead hosts media as
  assets on a dedicated **`pr-media`** release and links them, which keeps media out of
  git history. **Images render inline; a video appears as a download link** — GitHub only
  inline-plays its own web uploads. So on GitHub, favor screenshots/GIFs for the at-a-glance
  story and treat a linked `.mp4` as the "full demo" supplement.

## Output

Return the PR/MR URL and number (printed by `open-pr.sh`), and note whether visual
results were attached. Do **not** merge here — merging is the reviewer's /
dependency-ordered step.

> Note: media is embedded when the PR/MR is **created**. If a PR already exists for the
> branch, `open-pr.sh` reuses it and does **not** rewrite the body — attach the visuals
> when you first open it.

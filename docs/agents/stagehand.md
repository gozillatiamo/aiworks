# stagehand — putting what the assistant touches on screen

Every tool call also **shows its subject**: a file the assistant just edited opens in the editor at
the edited line, a URL it just read opens in a browser tab. Each window is placed in whatever
screen space is actually free at that moment — on any display — and the keyboard is never taken
away from you.

Off by default, personal, and **root worktree only**.

---

## Why not `computer-use`

Claude Code ships a built-in MCP server called `computer-use` that lets Claude see the screen and
click and type. It is the obvious-looking answer to "mirror what you're doing onto my monitors" and
it is the wrong engine for it. Four reasons, all from
[its own documentation](https://code.claude.com/docs/en/computer-use):

1. **It hides your apps.** "When Claude starts controlling your screen, other visible apps are
   hidden … When Claude finishes the turn, hidden apps are restored." The goal here is the exact
   opposite — windows spread across displays and left there.
2. **It holds a machine-wide lock until the session exits.** A second Claude Code session (a
   Superset worktree, a second terminal) then cannot use the machine at all.
3. **Its permission tiers forbid the two headline actions.** "Browsers and trading platforms are
   view-only, terminals and IDEs are click-only." A view-only browser cannot be told to open a URL;
   a click-only IDE cannot be told to open a file.
4. **It screenshots into the model on every action.** Doing that on *every* tool call multiplies
   token cost for a feature whose entire output is a window position.

It also requires a Pro or Max plan and "is not available on Team or Enterprise plans" — which is
what this organization is on, so `computer-use` does not even appear in `/mcp` here. That last part
is a footnote, not the argument: the first four reasons would still rule it out on a Max plan.

stagehand is deterministic shell instead — `open`, the editor's CLI, Chrome's AppleScript
dictionary, and the Accessibility API. No lock, no hiding, no screenshots, no plan tier, and it
fires on turns the model never thinks about because it is driven by a hook rather than by a
decision.

## Root worktree only

A Superset worktree runs its own Claude Code session against the same physical screen. Two sessions
racing to place windows would fight over the same space and neither could win, so the root/main
checkout owns the screen and every other checkout stays silent.

The gate is mechanical, never guessed, and has three independent proofs
(`scripts/stagehand/lib.sh`):

- `git rev-parse --git-common-dir` points at `<main>/.git` from inside a linked worktree, so
  `STAGE_MAIN_CLONE` is non-empty there and empty in the root checkout.
- `SUPERSET_ROOT_PATH` must be unset.
- `.git` must be a **directory** (a linked worktree's `.git` is a file).

`selftest.sh` proves this against a **real** `git worktree add`, not a mocked env var.

## What routes where

Two triggers, two different questions.

**`PostToolUse` — what a tool touched:**

| Tool | Shows |
| :--- | :--- |
| `Write` / `Edit` / `NotebookEdit` | the file in the editor, at the line that changed |
| `WebFetch` / `WebSearch` | the URL (or the search) in a browser tab |
| anything else | the first URL in the tool **response**, if its host is allowlisted |
| `Read` / `Grep` / `Glob` | nothing |

**`Stop` — what the reply talked about.** A turn's real subjects are frequently things no tool
touched: an MR flagged as stale, a ticket said to span three repos, a file being explained. The Stop
hook is the one event holding the finished reply, so that is where the screen gets pointed at what
was just *said*. Two ways it learns the targets, in the same shape voice uses for its closing line:

1. An explicit `SHOW: <target>` line in the reply — exact, free, and the assistant's own choice of
   what mattered. Comma-separate several, or repeat the line. A tag **suppresses** the prose scan.
2. No tag → the prose is scanned in reading order, because a reply leads with its headline.

Targets: a URL · `<repo>!<iid>` or `<repo>#<n>` · a ticket key · a repo-relative path (`file.rs:42`).
Capped at `stagehand.follow_max` so a reply listing 22 stale MRs does not open 22 tabs.

`<repo>!<iid>` is resolved through that repo's **own git remote**, never by assembling a URL from
parts. Assembling one by hand is how `https://gitlab.com/your-group/wrong-subgroup/thing/-/merge_requests/14`
was produced and 404'd — that project actually lives under a different subgroup. The remote knows; guessing does not.

`Read` is deliberately excluded. A single turn skims dozens of files it merely glances at;
mirroring those flips windows faster than anyone can follow and buries the edit that mattered.
Show what the assistant **changed** or **fetched**, not what it skimmed.

### The URL allowlist is a security boundary

A URL sniffed out of a tool *response* is a string from a file, a web page, or a remote API — i.e.
attacker-influenceable content. Auto-opening it would turn any injected link into a drive-by
navigation in your logged-in browser profile. So response URLs must match `stagehand.url_hosts`;
only a `WebFetch`/`WebSearch` URL the model asked for explicitly bypasses the list.

## Placement: `halves`

Half a display, split along its long edge, on a randomly chosen display — **landscape splits
left/right, portrait splits top/bottom**. Orientation decides the cut because it is the only split that
leaves a usable aspect on each screen: a portrait monitor cut left/right gives two unreadable slivers.

Three rules keep "random" from being chaotic:

- **A half another role owns is out of the pool.** Otherwise random would mean "on top of the window I
  opened a moment ago" — the exact thing the feature exists to avoid.
- **A role that already owns a half keeps it.** Re-rolling on every call made the single browser window
  hop between halves as tabs opened (measured: bottom, bottom, then top for three consecutive URLs in
  the same window). Randomness decides where a role goes the *first* time only.
- **The built-in laptop screen is reserved.** That is where a person keeps what *they* are using, so
  stagehand stays on the external monitors. Detected with `CGDisplayIsBuiltin` against each screen's
  `NSScreenNumber` — never by display **name**, which would break on the next machine. Reserved is not
  banned: it is the last-resort tier, so a laptop with no external display still works.

### Why this replaced the scorer

The original placer scored nine slots per display by how much each would overlap the windows already
there and took the cheapest. Its arithmetic ended up correct; its **output shapes** were the problem.
Two things were learned the hard way and are worth not relearning:

- **Least-overlap is not the objective that was asked for.** The ask was that stagehand's windows not
  cover *each other*; what was built avoided covering *any* window. On a desk where every display is
  already fully covered by the user's own apps — measured here as iTerm at 100% of a 5K display, Slack
  and Gather both at 100% of the laptop screen — that stricter objective degenerates to "always the
  display with the smallest windows", and every single placement landed on the same monitor.
- **A spread penalty has to dominate to matter.** Overlap is a *sum* of per-window fractions, so a
  single slot already scores ~2.0 on a saturated desk; a 0.60 nudge changed the number without changing
  the answer. (The scorer kept that lesson: its spread penalty is 10, above any reachable overlap sum
  yet finite, so a one-display machine degrades to sharing rather than failing.)

`placement: score` still selects it. `placement: rectangle` drives
[Rectangle](https://rectangleapp.com)'s URL scheme instead — it works, but `execute-action` takes no
`app-bundle-id`, so it acts on the frontmost window only and has to focus the target first, taking the
keyboard mid-turn. `placement: off` opens things and moves nothing.

### Shrinking a maximized terminal

A terminal maximized across a whole display means that display can only ever be covered, never shared,
so the biggest monitor on the desk drops out of the pool entirely. `protected_half` shrinks it to one
side (default `left` — on a three-display span the left half of the centre monitor is closest to the
physical middle of the desk) and the display becomes two usable halves.

Only at ≥90% coverage, never on the reserved built-in, and **never on a window in native macOS
fullscreen** — that lives in its own Space, cannot be usefully resized, and fighting the window server
over it produces flicker rather than space. `AXFullScreen` is the check; it reads `false` for a merely
maximized window, which still shows the menu bar above it.

Shrinking alone was not enough, and the reason is worth keeping: guarding was per **display**, so the
terminal still touched the display and both halves stayed out of the pool. The guard is now per
**half** — only the halves the protected window actually covers are deprioritised.

## The browser opens under the right account

Chrome's `make new window` inherits the **last-used** profile — whichever one the human last
clicked. So a Jira or GitLab URL opened right after a personal browsing session renders a login
wall instead of the ticket. `stagehand.browser_account` is your work email; it is resolved to a
profile directory through Chrome's own `Local State` metadata (profile names and emails, no tokens),
because the directory names are creation-order and mean nothing portable — on this machine the
**work** account can be `Default` while a personal one is `Profile 1`, the reverse of what the names
suggest.

The window is then created with Chrome's `--profile-directory` flag, which is the only way to pick
a profile — AppleScript has no equivalent — and identified afterwards by diffing the window-id set.

Chrome exposes no profile *property*, and the only outside signal is the profile name Chrome
appends to the window title, reachable solely through the Accessibility API whose window ordering
is independent of Chrome's. There is therefore no sound way to ask "which profile is window id N
in?". stagehand creates the window, so it already knows: the state file records `<id>|<profile>`,
and a remembered window whose profile does not match is discarded and recreated. Checking instead
whether *any* Chrome window carried the wanted profile name — the first attempt — is true the moment
the user has one such window open, so it happily kept reusing the personal-profile window.

## Open, then actually work in there

Opening a tab and going static reads as a machine dumping windows, not as somebody using a computer.
Three things close that gap, and none of them require a permission by default.

**A focus phrase.** Any target may carry one after `~`:

```
SHOW: my-repo!555 ~signature_key, scripts/stagehand/place.js ~scoreSlot
```

In the browser it becomes a URL **text fragment** (`#:~:text=signature_key`) — Chrome scrolls to the
phrase and highlights it natively, no injected script involved. On an MR the phrase also redirects to
`/diffs`, because a named symbol lives in the diff. In the editor the file is grepped for the phrase
and that line becomes the `--goto` target, which beats the edited-line guess: it is the thing being
talked about.

Markdown stripping on a `SHOW` target removes backticks and asterisks but **never the underscore** —
it is emphasis in prose and half of every `snake_case` identifier, and removing it turned
`signature_key` into `signaturekey`, matching nothing on the page it was meant to scroll to.

**Tab reuse by page identity.** A person reading MR 14 who then wants its diff switches back to that
tab; they do not open a second one. So an MR/PR collapses to everything up to its number and a ticket
to `/browse/<KEY>` — sub-paths and query strings are the same *page*, and re-assigning the URL of the
tab already showing it is what makes Chrome re-run the scroll-and-highlight. Without this the window
became a graveyard of near-duplicate tabs. (`show.sh --ident <url>` prints the identity; the selftest
asserts MR 14 and MR 141 do not collide.)

**Following during the turn, not after it.** The same follow hook runs on `PostToolUse` as well as
`Stop`, so the screen keeps up with a turn as it narrates rather than jumping once at the end. Since
that means the same reply text is seen once per tool call, follow.sh hashes the text it staged and
skips a repeat — otherwise it would re-open the same three things all turn.

### The optional in-page step, and why it stays optional

Single-page apps are where text fragments fall down: Jira and GitLab render after navigation, and a
fragment is resolved against the first paint, so the phrase is frequently not in the DOM yet. The
fallback is to ask the rendered page itself to scroll to the phrase and flash it, which needs Chrome's
**View > Developer > Allow JavaScript from Apple Events**.

That setting is off by default and it is a genuine security boundary: with it on, *any* AppleScript on
the machine can run JavaScript in *any* of your logged-in tabs. stagehand therefore never enables it.
It probes the capability and works without it. The probe caches "off" for only 300s, because a
permanently cached "off" meant that ticking the box changed nothing until the state directory was
deleted by hand — a footgun, not a cache. "On" was initially cached forever on the reasoning that only
a human can untick the menu item; that was caught being wrong with the evidence in hand, the cache file
holding `1` from minutes earlier while the real call returned "turned off". So a real failure now
invalidates the cache, and the probe targets **the same window the call will use** rather than
`window 1` — probing one window and scripting another is unsound, and is the leading suspect for that
mismatch (Chrome had not restarted between the two, verified from its process start time).

**What it reaches**, measured on this workspace:

| Page | Highlight |
| :--- | :--- |
| Jira ticket | works — `hit:3`, scrolled into view |
| GitLab MR overview | works — `hit:3` |
| GitLab MR `/diffs` | works — `hit:3`, `marks=3`, 3 occurrences in `innerText` |

An earlier version of this document claimed the diff view could **never** be highlighted because GitLab
lazy-loads diff content. That was wrong, and the mistake is worth keeping visible: the probe behind it
searched an MR that never contained the identifier being looked for, so it found zero occurrences and
the conclusion "not in the DOM" simply did not follow. Re-run against the MR that really does contain
it, the diff page highlights fine — and Claude in Chrome's `find` independently located the same text
inside the diff code lines. What remains true is narrower: GitLab collapses **large** files, so a phrase
inside an unexpanded file is genuinely unreachable. That is a per-file limit, not a property of the view,
so a focus phrase does redirect to `/diffs` where a named identifier actually lives.

Two bugs worth remembering from getting this working, both of which produced a confident-looking log
line and no highlight:

- **Nested quotes.** The phrase was concatenated into the JS source by hand and shipped
  `go(6)})('TrueMoney");` — opened with `'`, closed with `"`. A syntax error, so nothing ran, while the
  log said the highlight had been requested. The phrase now goes into a `__PHRASE__` placeholder and is
  escaped exactly once.
- **Mutating the DOM during the walk.** Wrapping each match in a `<mark>` *while* iterating a
  `TreeWalker` put a fresh text node still containing the phrase into the live tree; the walker stepped
  into it, matched, wrapped, forever. That pinned the page's main thread, `execute javascript` never
  returned (`rc=124`), and the tab had to be reloaded. Collect the nodes, finish the walk, then mutate —
  capped at 20 — and bound the AppleScript call with `timeout` so a busy page can never hold the
  process open.

## Two coordinate traps worth knowing before you touch the code

**NSScreen and the Accessibility API disagree about y.** NSScreen is bottom-left origin with +y up;
AX is top-left origin with +y down, anchored at the main display's top-left. So

```
axTop = mainScreenFrameHeight - (nsOriginY + nsHeight)
```

Get it backwards and windows land off-screen on any display with a negative origin — precisely the
multi-monitor case this feature exists for. Chrome's own `bounds` property agrees with AX, which
`selftest.sh` asserts.

**Set size before position, then do it again.** Setting position first silently *clamps* the move:
a window whose old size does not fit at the new origin gets pushed back by the window server. A
request for `(3100,-193)` landed at `(412,30)` with only the size applied, and the return value
still said success. `place.js` shrinks first, moves, repeats, then **reads the geometry back** and
reports `landed` as overlap-with-intended-slot ≥ 90% rather than trusting the write.

## Files

| Path | Role |
| :--- | :--- |
| `.claude/hooks/stagehand-show.sh` | `PostToolUse` (matcher `*`) — spills the payload, forks detached, exits 0 |
| `.claude/hooks/stagehand-follow.sh` | `Stop` (matcher `*`) — hands the transcript path to follow.sh, detached |
| `scripts/stagehand/lib.sh` | gates, config resolution, debounce, state |
| `scripts/stagehand/show.sh` | the router: payload → target → open → place |
| `scripts/stagehand/follow.sh` | resolves the reply's subjects to targets, then delegates to show.sh |
| `scripts/stagehand/place.js` | the occupancy-based placer (JXA) |
| `scripts/stagehand/selftest.sh` | 56 assertions; `--live` adds 4 that move a real window and restore it |

The hook is thin on purpose, exactly like `voice-narrate.sh`: it fires on **every** tool call, so
anything slow in it would be felt all day. All AppleScript work happens in a detached fork.

## Configuration

Every key is documented in `workspace.config.example.yaml`. The shared `workspace.config.yaml`
ships `stagehand.enabled: false`; turn it on per person in the git-ignored
`workspace.config.local.yaml`:

```yaml
stagehand:
  enabled: true
  placement: auto
```

`STAGEHAND=off` in the environment silences everything without touching config.

## Requirements

macOS, and three TCC grants **for the terminal that runs Claude Code** (not for Cursor or Chrome —
those are targets, not actors): Accessibility, Automation → System Events, and Automation → your
browser. Screen Recording is **not** needed; that is a `computer-use` requirement, not this one.

`AXIsProcessTrusted()` reports whether the Accessibility grant is in place without triggering a
prompt:

```bash
osascript -l JavaScript -e 'ObjC.import("ApplicationServices"); String($.AXIsProcessTrusted())'
```

The editor must have a CLI that accepts `--goto file:line` (Cursor's does). Note that Cursor
exposes **no** AppleScript dictionary — `count windows` returns error `-1708` — so its windows are
reachable only by process name through System Events, and its window is identified by the file's
basename in the title.

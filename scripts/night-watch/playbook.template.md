# Night Watch playbook (template)

Copy to the path set in `night_watch.playbook` (default `docs/night-watch/playbook.md`) and fill in
every `<placeholder>`. The Tick agent reads this file each slot and follows it; it adds no rules of
its own. Keep rules short and testable: a rule the agent cannot check with a read-only query belongs
in "Known routine" or nowhere.

## 1. Environment

- Production label for observability `--env`: `<production-env-label>`
- Production label for the pg and redis triage `env`: `prod`
- Database targets: `<master target>`, `<shard targets or "none">`
- Name the production environment here, and nowhere else in the framework. Pass this label on every
  observability call: a call without it mixes other environments into the evidence.

## 2. Window

The script supplies the window start and end for each Tick. Use exactly that window. Do not widen it
to chase a hunch; follow a lead only as in section 7.

## 3. Realms and checks

| Realm | Check |
|---|---|
| auth | New administrators, privileged role changes, logins by disabled identities |
| payments | Changes to payout or auto-withdrawal methods, forced completions |
| wallet | Negative amounts, a single amount over `<threshold>` (stored amounts are scaled: divide first) |
| callbacks | Unauthenticated callback routes with traffic where the baseline is zero |
| infrastructure | Pod restarts, consumer lag, a database or cache at its ceiling |
| errors | 5xx share per service against its baseline |

## 4. Fixed rules

A fixed rule has a hard condition. A breach mentions people from Tick 1.

| rule_id | realm | condition | severity |
|---|---|---|---|
| `<fixed-1>` | `<realm>` | `<condition, e.g. a new administrator appeared in the window>` | `ALERT` |

## 5. Count rules

A count rule compares a measured number to a learned baseline. For the first 24 successful Ticks a
count finding is labelled "baseline learning" and mentions nobody. Store each measured value under its
`baseline_key` in `state_update.baselines`.

| rule_id | metric | baseline_key | SUSPICIOUS at | ALERT at |
|---|---|---|---|---|
| `<count-1>` | `<metric, e.g. 5xx per hour for service X>` | `<key>` | `<x baseline>` | `<y baseline>` |

## 6. Known routine

Patterns that look odd but are normal. Do not flag them.

- `<pattern>`

## 7. Leads

If a check shows something the rules do not cover, you may follow it for a few queries. A lead finding
uses `rule: "lead"` and must cite evidence ids. No evidence id, no finding. Every evidence item has a
label saying what it is.

## 8. Re-authentication

When a realm cannot be read, return `BLIND` and name what to re-authenticate:

| Realm | Re-authenticate |
|---|---|
| `<realm>` | `<e.g. the tunnel or login command a person must run>` |

## 9. Never

- No call to a deployed endpoint (no curl, wget or HTTP client).
- No write of any kind: no row, key, ticket, comment, post or merge request.
- No end-customer personal data in the output: no email, phone, wallet, bank account, national id or name.
  Use identifiers (`*_code`, UUIDs, trace ids) and counts. Internal staff are the exception: for an admin or
  agent actor, identity evidence carries the full id, username, display name and e-mail.

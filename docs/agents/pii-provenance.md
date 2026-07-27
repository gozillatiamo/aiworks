# PII provenance — redact what PRODUCTION gave us, and only that

Personal data read from **production** must not land in a ticket, a Slack message, or a
developer's laptop. Personal-looking data from **local or staging** is test/mock data and is
explicitly fine — seeded fixtures, `fixture1@example.com`, `127.0.0.1`, a QA report full of made-up
phone numbers. The gate has to tell those two apart.

It cannot do that by shape, and it cannot do it by context either: in this team prod
investigation, staging QA, and local development run **in parallel, all day**. A prod query at
09:00 and a local test run at 09:05 belong to different flows that overlap in the same minute,
so no ambient signal — a time window, a session, a ticket key — separates them.

So provenance is tracked at the level of the **value itself**.

```
              INGRESS (production only)                    EGRESS (anywhere)
  prod-pg-triage MCP     ─┐                              tracker: comment / body
  prod-redis-triage MCP   ├─> HMAC of each personal ───> notify:  message / file
  prod_repro_seed.py     ─┘   value → the vault              │
                                                             ├─ value in the vault? → <prod-pii:…>
                                                             └─ not in the vault?   → written as-is
```

A value is redacted **if and only if** a sanctioned production-read path actually returned it.
Local and staging data never enters the vault, so it is never touched — in any session, any
ticket, any minute, no flags to remember.

## What happens on a hit

The write **still goes through**, with the personal value replaced by a `<prod-pii:email>` /
`<prod-pii:phone>` / `<prod-pii:name>` placeholder, and a note on stderr naming the category
and count (never the value — printing it would leak it into the transcript):

```
pii-provenance: masked 2 production value(s) [email x1, phone x1]
note: production PII was redacted from this ticket text before writing.
```

Redaction is a backstop for a slip, not a licence. A finding written as an **aggregate**
(`COUNT(*)` / `GROUP BY`), an **inner-system identity** (an entity code / UUID), or
the **reproduce SQL** reads better and never depends on the vault having seen the value.

## What always survives

Any `*_code` identifier, internal UUIDs, fixed-point money integers, aggregate counts, and reproduce SQL. These are the ground truth a triage
summary exists to carry, and none of them identify a real-world person.

## Pieces

| File | Role |
|---|---|
| `scripts/lib/pii_provenance.py` | The engine: detectors, vault, record + mask. `--selftest` covers 16 cases. |
| `scripts/lib/pii-patterns.txt` | The detector list — what counts as a personal value, plus live credentials (JWT by shape; `access_token` / `Bearer` / `api_key` / `password` by label). A bare hex or base64 run is deliberately **not** a detector: a 40-char hex is a commit SHA, and redacting those would maul ordinary PR prose. One policy, read by every engine. |
| `scripts/lib/pii-scan.sh` | Shape-only scanning + PDF text extraction. No longer the egress gate. |
| `scripts/db/prod_pg_mcp.py` | Ingress: every returned row is fingerprinted in `_query()`. |
| `scripts/redis/prod_redis_mcp.py` | Ingress on a `prod=true` target only, in `_emit()`. Also the one place that goes **further** than redaction: a value that is a *credential* (JWT / opaque token / a value under a `*token*`-ish key) is replaced with `<redis-secret:sha8>` **at the source**, so a live session token never reaches the transcript in the first place — a leaked credential is an account takeover, not a privacy incident, and egress redaction would be too late. A `prod=false` target is neither masked nor vaulted. |
| `scripts/db/prod_repro_seed.py` | Ingress (pre-mask) + the local-sandbox mask it already did. |
| `scripts/tracker/lib.sh` → `tracker_redact_prod_pii` | Egress: ticket comment + body + estimate reason. |
| `scripts/notify/send.sh` → `redact_prod_pii`, `outbound_gate` | Egress: Slack text, caption, and file uploads. |

## The vault

`~/.claude/prod-pii-vault/` — `salt` (0600, per machine) and `vault.tsv`
(`<hmac-sha256>\t<category>\t<epoch>`). **Digests only; a value is never written to disk**, and
without the machine's salt a copied vault file is inert.

It lives under `$HOME`, not in the repo, so one machine shares one vault across every clone and
Superset worktree — a value read in the main clone is still redacted when a worktree posts the
ticket. Entries expire after `PII_VAULT_TTL_DAYS` (default 30) and are pruned on the next write.

```bash
python3 scripts/lib/pii_provenance.py stats               # counts + categories, never a value
python3 scripts/lib/pii_provenance.py forget --all        # wipe
python3 scripts/lib/pii_provenance.py --selftest          # 13 cases, uses a throwaway vault
```

## Knobs

| Env | Effect |
|---|---|
| `PII_GATE=auto` | **Default.** Redact vault-matched (production) values only. |
| `PII_GATE=on` | Also redact every shape match, vault or not. Use when hand-writing a prod incident report from values that never passed through an instrumented path. |
| `PII_GATE=off` | Redact nothing. The escape hatch when a redaction is wrong. |
| `PII_VAULT_DIR` | Vault location (default `~/.claude/prod-pii-vault`). |
| `PII_VAULT_TTL_DAYS` | Entry lifetime, default 30. |
| `PII_TOKEN_MIN` | Minimum length for a shapeless value (name/address) to be vaulted or matched. Default 5. |
| `TRACKER_SKIP_PII_CHECK=1` | Legacy break-glass; skips tracker redaction entirely. |

## Honest limits

- **Only what flowed through an instrumented ingress is known.** A value a human pastes into
  chat from their own `psql` session, or that a model retypes from memory in a different form,
  has no vault entry and is written as-is. That residue is the SOFT layer — the prompt
  instruction in the triage skill and agents — exactly as before. `PII_GATE=on` covers it for a
  single write.
- **Shapeless values (names, addresses) are only caught via PII-named columns.** They are
  vaulted whole from a prod query result and matched back as tokens, which is the only way a
  name can be recognized at all. The cost: if a prod `address` column contained `Bangkok`, a
  later unrelated sentence mentioning Bangkok gets a placeholder. Annoying, not dangerous —
  `PII_GATE=off` for that write.
- **Binary uploads can't be redacted.** A PDF/PNG carrying production PII is refused rather
  than rewritten (rewriting the bytes would corrupt the file). It is judged on text extracted
  by `pii-scan.sh` / `pdf-text.py`, which reads a PDF's real text layer — including a text
  stream no page references. What no extractor reaches still passes: text baked into a raster
  image, and non-Flate compressed streams. So a binary remains a weaker check than a text file.
  Text/binary is decided by extension first, then by a NUL-byte probe: a small PNG is mostly
  printable and a naive content sniff calls it text, which would corrupt the upload.
- **Secrets are not part of this.** A token/key/credential in a Slack upload is refused
  outright, in every environment — a credential is never "redact and carry on".

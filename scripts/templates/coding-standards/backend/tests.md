---
description: Test-writing standard — date/time in tests MUST be a hard-coded literal, never the live clock. Read before writing or editing any unit/integration test that touches a date, time, timestamp, or duration.
paths:
  - "src/tests/**"
  - "**/*_test.rs"
---

# Test standards

Sibling rules: [`standards.md`](./standards.md).

## File structure — **MUST DO**

- [ ] Test file path mirrors the target function's module path under the test
  tree: a function at `services::user_service::create_user` gets
  `src/tests/services/user_service/create_user_test.rs` (swap the extension/
  root for this stack's own convention — the mirroring rule is what matters).
- [ ] One test file = one test suite = one function under test. Don't fold
  multiple functions' cases into one file, and don't split one function's
  cases across multiple files.
- [ ] Every test case in that file targets that one function — no incidental
  coverage of a different function because it happened to be convenient.

## Case count — **MUST DO**

- [ ] New feature / new test suite (new file): 3-5 cases to start — happy path
  plus the edge cases that actually matter for that function. Don't pad past
  that for a first pass.
- [ ] Updating an existing suite / proving a fix: add or change only the
  case(s) that prove the change. Don't re-verbosify the whole file.

## Date/time — **MUST DO**

- [ ] Any test that involves a date, time, timestamp, or duration MUST pin it to
  an **explicit hard-coded literal**, so the test asserts the same thing on every
  run — today and in a year.

```rust
// GOOD — a fixed instant the test controls
let now = DateTime::parse_from_rfc3339("2026-01-15T10:00:00Z").unwrap().to_utc();
let dob = NaiveDate::from_ymd_opt(1990, 5, 20).unwrap();
```

## **MUST NOT DO**

- [ ] Do NOT read the live clock in a test: no `Utc::now()`, `Local::now()`,
  `SystemTime::now()`, or `now`-relative math (`Utc::now() - Duration::days(3)`).
- [ ] Do NOT hide the clock behind a helper/fixture that resolves to "now"
  (`fn today() { Utc::now().date_naive() }`). A computed value is still
  non-deterministic — write the literal directly at the test site.

```rust
// BAD — passes today, drifts or breaks on a later run date
let now = Utc::now();
let cutoff = Utc::now() - Duration::days(30);
```

**Why:** a value pulled from the current clock passes today and silently changes
(or breaks) on a future run date. A fixed literal keeps the test deterministic
across all future days.

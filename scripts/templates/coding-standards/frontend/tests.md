---
description: Test-writing standard — date/time in tests and stories MUST be a hard-coded literal, never the live clock. Read before writing or editing any Jest/Vitest test or Storybook story that touches a date, time, timestamp, or duration.
paths:
  - "**/*.test.*"
  - "**/*.spec.*"
  - "**/*.stories.*"
---

# Test standards

Sibling rules: [`standards.md`](./standards.md).

## File structure — **MUST DO**

- [ ] Test file sits next to the unit it tests and shares its name: a hook/
  util/component at `src/hook/useFetchList.ts` gets `src/hook/useFetchList.test.ts`
  (co-located, same directory — swap the extension/pattern for this stack's own
  convention if it differs; the co-location rule is what matters).
- [ ] One test file = one test suite = one exported function/hook/component
  under test. Don't fold several units' cases into one file, and don't split
  one unit's cases across multiple files.
- [ ] Every test case in that file targets that one unit — no incidental
  coverage of a sibling export because it happened to be convenient.

## Case count — **MUST DO**

- [ ] New feature / new test suite (new file): 3-5 cases to start — happy path
  plus the edge cases/states that actually matter. Don't pad past that for a
  first pass.
- [ ] Updating an existing suite / proving a fix: add or change only the
  case(s) that prove the change. Don't re-verbosify the whole file.

## Date/time — **MUST DO**

- [ ] Any test or story that involves a date, time, timestamp, or duration MUST
  pin it to an **explicit hard-coded literal**, so it asserts (and renders) the
  same thing on every run — today and in a year.

```ts
// GOOD — a fixed instant the test/story controls
const now = new Date('2026-01-15T10:00:00Z');
const createdAt = '2025-12-01T00:00:00Z';
```

## **MUST NOT DO**

- [ ] Do NOT read the live clock in a test or story: no `new Date()` (no args),
  `Date.now()`, `dayjs()` / `new Date(Date.now())`, or `now`-relative math
  (`Date.now() - 3 * 86_400_000`).
- [ ] Do NOT hide the clock behind a `now()` helper/fixture. A computed value is
  still non-deterministic — write the literal directly at the test/story site.

```ts
// BAD — passes today, drifts or breaks on a later run date
const now = new Date();
const cutoff = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
```

**Why:** a value pulled from the current clock passes today and silently changes
(or breaks) on a future run date. A fixed literal keeps tests and story snapshots
deterministic across all future days.

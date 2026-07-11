---
description: Baseline coding standards — small files, and code that tells its own story (no in-body comments). Read before writing or editing any source file.
paths:
  - "src/**"
---

# Coding standards

Seeded default (a lean frontend baseline). Add repo-specific rules
(`architecture.md`, layering/naming, `storybook.md`, …) as this repo grows.

## **MUST DO**

- [ ] Keep every source file under **600 lines**. When a file crosses that, split it
  along a real seam — a component, hook, or feature slice — never an arbitrary cut.

## **MUST NOT DO**

- [ ] **No comments inside a function body.** Code tells its own story — name functions
  and variables for intent, and extract any block you would explain with an inline
  comment into a well-named function or hook instead. If a note is genuinely
  unavoidable, put ONE short line at the TOP of the function, never inside the body.
  An in-body comment is a smell.

---
description: Baseline coding standards — small files, and code that tells its own story (no in-body comments). Read before writing or editing any source file.
paths:
  - "src/**"
---

# Coding standards

Seeded default (a lean backend baseline). Tune the numbers and add
per-area rules (`dao.md`, `services.md`, `route.md`, …) as this repo grows.

## **MUST DO**

- [ ] Keep every source file under **600 lines**. When a file crosses that, split it
  along a real seam — a module, type, or responsibility — never an arbitrary cut.

## **MUST NOT DO**

- [ ] **No comments inside a function body.** Code tells its own story — name functions
  and variables for intent, and extract any block you would explain with an inline
  comment into a well-named function instead. If a note is genuinely unavoidable, put
  ONE short line at the TOP of the function, never inside the body. An in-body comment
  is a smell.

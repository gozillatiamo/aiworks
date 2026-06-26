# Workspace coding style

Four rules every code-writing skill holds to (`coding-feature`, `coding-automate`).
Language-agnostic — Next.js, Rust, SQL, Cypress alike. When a repo's own `CLAUDE.md`
is stricter, the repo wins.

## 1. Code tells the story — no body comments

A function body carries **no comments**. If a function truly needs a note, write **one**
short comment at the **top** of it — never inside the body. Keep it plain: simple words a
non-native English reader gets on the first pass, no verbose prose, no restating the next line.

A comment inside the body is a smell — it means the code isn't telling its own story yet.
Fix the code (rule 2), don't annotate it.

## 2. Storytelling — names carry the meaning

Top to bottom, the function reads as a sentence about **what** happens, not **how**.
Intent-named functions and variables *are* the documentation. The moment you reach for an
inline comment to explain a block, extract that block into a well-named function instead.

## 3. flow → side-effect → pure

Every function plays **one** of three roles; keep them apart:

- **flow function** — orchestrates the steps in order: the story / table of contents.
  Calls the others; holds no complex logic itself.
- **side-effect function** — talks to the world (I/O, network, DB, driver, mutation, logging).
  Thin; no complex branching.
- **pure function** — input → output, deterministic, no side effects.
  **All complex logic lives here** — the branching, math, parsing, decisions.

Rule of thumb: if logic is hard to follow, it belongs in a pure function — easy to name,
easy to test, easy to read. The flow stays a clean story; the side-effect functions stay thin.

## 4. ≤ 500 lines per file

No file over 500 lines. Nearing it means the file does too much — split by responsibility
(one module per concern) before adding more.

## Example

Before — one fat function, inline comments, I/O and logic tangled:

```js
async function checkout(cart, userId) {
  // get the user from db
  const user = await db.users.find(userId)
  let total = 0
  for (const item of cart.items) {
    total += item.price * item.qty // sum the line
  }
  if (user.tier === 'gold' && total > 100) {
    total = total * 0.9 // gold members get 10% off over 100
  }
  await db.orders.insert({ userId, total }) // save the order
  return total
}
```

After — a flow that reads as a story, logic in pure functions, world-talk in thin ones:

```js
// charge the cart, store the order, return the amount paid
async function checkout(cart, userId) {
  const user = await loadUser(userId)
  const total = priceCart(cart, user)
  await saveOrder(userId, total)
  return total
}

const loadUser = (userId) => db.users.find(userId)
const saveOrder = (userId, total) => db.orders.insert({ userId, total })

const sumLines = (items) => items.reduce((acc, i) => acc + i.price * i.qty, 0)
const goldDiscount = (total, user) =>
  user.tier === 'gold' && total > 100 ? total * 0.9 : total
const priceCart = (cart, user) => goldDiscount(sumLines(cart.items), user)
```

Roles: `checkout` is the **flow** (one top comment, no body comments, reads like a sentence);
`loadUser` / `saveOrder` are **side-effect** (thin, touch the DB); `sumLines` /
`goldDiscount` / `priceCart` are **pure** (every branch and sum lives here, each one named so
no comment is needed).

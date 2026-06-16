# QA sub-task — worked example

Use this as a calibration anchor for the level of detail, focus-area spread, and Given/When/And/Then shape.

## The pattern is universal

The worked example below is written in an **E2E** context, but **the pattern is the same for API and Load Test sub-tasks**. Across all three tools:

- Same shell: `Feature:` + `Scope:` + `Parent:` + `User story / context:` + numbered `Scenario N: <name> (<focus area>)` blocks.
- Same syntax: `Given / When / And / Then`.
- Same spread: 3–5 scenarios covering distinct focus areas (Correctness, Accessibility, Security, Performance).

What changes per tool is only the **`Scope:`** line and the **flavor of the assertions** inside `Then`:

- **E2E** — user-facing behavior, navigation, visible feedback, end-to-end correctness.
- **API** — request/response contract, status codes, payload shape, auth/permission boundaries, idempotency.
- **Load** — throughput, latency percentiles, error rate under concurrency, resource ceilings, degradation behavior.

Do **not** reshape the scenarios for API or Load — only re-aim the `Then` assertions.

## Example (E2E)

```
Feature: Username and Password Authentication
Scope: End-to-End (E2E)
Parent: OFB-123 — Username & password sign-in

User story / context:
As a returning user I want to sign in with my username/email and password so that I can
reach my account dashboard. AC: valid credentials authenticate and redirect; invalid
credentials show a field-level error; legacy Google-only accounts cannot set a password
via sign-in.

**Scenario 1**: Successful authentication using primary credentials (Correctness)
  Given the user is on the sign-in page
  When I enter a valid registered username or email and the correct password
  And I click the sign-in button
  Then the system should invoke the new sign-in API and receive a valid access token
  And I should be redirected to the account dashboard successfully

**Scenario 2**: Visual feedback and password masking (Accessibility)
  Given the user is entering credentials on the sign-in page
  When I enter characters into the password field
  Then the input should be masked by default for privacy
  And clicking the "eye" visibility icon must toggle the password text between masked and plain text
  And if I enter invalid credentials, the resulting error message must be displayed strictly below the password input field for clear visual association

**Scenario 3**: Legacy Google account restriction (Security)
  Given a legacy user account that was created via Google and has no password credential set
  When I attempt to sign in using that account's email and a placeholder password in the credential form
  Then the system must deny the authentication attempt
  And the API must not allow the creation of a password credential through the sign-in endpoint

**Scenario 4**: Sign-in performance and state handling (Performance)
  Given the sign-in page is loaded and the API is reachable
  When I submit valid credentials
  Then the authentication process and redirection should complete within 1.5 seconds under standard network conditions
  And the sign-in button should transition to a disabled or loading state during the API request to prevent duplicate form submissions
```

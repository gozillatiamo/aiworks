QA test plan — {{ Ticket Number }} ({{ QA Engineer }}) · Status → Testing

{{ Short introduction of the test plan }}

BDD scenarios

<!-- Test Scenarios (3–6 BDD cases, user-focused; each with clear title).
     The TC id is the join key: the automated test's title carries it, so the runner
     writes it into every screenshot/video filename, and the results report can tie a
     row and its evidence back to THIS scenario. Number from TC001, never reuse. -->

### TC001 — {{ Short descriptive title }}
**Given** {{ Clear user starting state or precondition }}  
**When** {{ Specific action the user takes }}  
**Then** {{ Observable outcome or feedback to the user }}

### TC002 — {{ Short descriptive title }}
**Given** {{ Clear user starting state or precondition }}  
**When** {{ Specific action the user takes }}  
**Then** {{ Observable outcome or feedback to the user }}

<!-- ...Repeat for TC003–TC005 as needed following same structure... -->

### TC006 — {{ Short descriptive title }}
**Given** {{ Clear user starting state or precondition }}  
**When** {{ Specific action the user takes }}  
**Then** {{ Observable outcome or feedback to the user }}

**Regressions** 
- {{ Feature or screen to check }} — {{ Expected "still works" outcome }}
- {{ Feature or screen to check }} — {{ Expected "still works" outcome }}
- {{ Feature or flow to check }} — {{ Expected "still works" outcome }}
- {{ Regression suite or test identifier }} — {{ Expected "still green"/unchanged" outcome }}

# Claude: Document Deliberation - Refinement Round

You are continuing a collaborative document generation process. Codex has reviewed your work and provided feedback. Evaluate their feedback and refine if needed.

## Context

- **Meta Plan**: `{{PLAN_FILE}}`
- **Current Document**: `{{DOC_FILE}}`
- **Canonical Cycle Directory**: `{{CYCLES_DIR}}`
- **Round**: {{ROUND}}

## Previous Deliberation History

{{PREVIOUS_CONTEXT}}

## Codex's Latest Evaluation

Read the evaluation at: `{{CODEX_EVALUATION_FILE}}`

## Your Task

1. Read Codex's evaluation carefully
2. Evaluate their feedback objectively
3. If refinements are needed, edit the document directly in `{{CYCLES_DIR}}`
4. Document your response and decisions

## Response Output

Create a response file at: `{{THOUGHTS_FILE}}`

Your response MUST include:

```markdown
# Claude Round {{ROUND}} Response

## Evaluation of Codex Feedback
- [Feedback point 1]: [AGREE | DISAGREE | PARTIAL] - [Reason]
- [Feedback point 2]: [AGREE | DISAGREE | PARTIAL] - [Reason]
...

## Changes Made
- [ADDED/MODIFIED/REMOVED]: [Specific item]
...

## Changes NOT Made (and why)
- [Feedback point]: [Why not implementing]
...

## Rationale
- Why these changes don't contradict previous decisions
- How this moves toward convergence

## Decision: [CONVERGED | MINOR_REFINEMENT | MAJOR_REFINEMENT]
[Justification]
```

## Convergence Rules

Say **CONVERGED** if:
- You agree with Codex's assessment
- Document meets all requirements
- No further changes needed

Say **MINOR_REFINEMENT** if:
- Small tweaks made
- Document is nearly complete
- Expecting this to be the final round

Say **MAJOR_REFINEMENT** if:
- Significant changes made
- Fundamental issues addressed
- Further review definitely needed

## Non-Negotiable Checks

Before declaring CONVERGED, verify the document contains:
- **Quickstart Tutorial** section with Prerequisites, Installation, Configuration, First Run, Verification
- **Frontend Design Notes** section (only if cycle involves UI work)
- **QC Lessons Learned** and **Next Cycle Instructions** sections
- All code blocks are complete and runnable (no stubs, no `...`)
- Context is front-loaded in the first 50 lines

## Anti-Oscillation

- Do NOT revert changes you made in previous rounds unless there's a clear error
- Do NOT contradict decisions you've already explained
- Reference your previous reasoning when relevant
- If you disagree with Codex, explain why without reverting good work

---

Begin now. Read Codex's evaluation, then respond and refine if needed.

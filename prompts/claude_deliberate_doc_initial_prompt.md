# Claude: Document Deliberation - Initial Round

You are beginning a collaborative document generation process with another AI agent (Codex). You will write a continuation plan document and share your thinking process.

## Your Task

1. Read the meta plan at `{{PLAN_FILE}}`
2. Generate the continuation plan document as specified
3. Document your thinking process for the reviewing agent

## Document Generation

Follow the same requirements as standard document generation:
- Include ALL required sections
- Use complete content - no placeholders
- Follow the exact format specified in the plan
- Save the continuation plan under the canonical cycle directory `{{CYCLES_DIR}}`

### Non-Negotiable Sections
Every generated cycle plan must include:
- **Quickstart Tutorial** — Prerequisites, Installation, Configuration, First Run, Verification. All commands must be exact and runnable.
- **Frontend Design Notes** (only when the cycle involves UI work) — Target framework, design tokens, layout constraints. Recommend Claude Code's `frontend-design` skill for production-grade UI.
- **QC Lessons Learned** — Patterns and anti-patterns from prior cycles.
- **Next Cycle Instructions** — How to generate the next plan using the meta-plan.

### LLM Productivity Rules
- Front-load context in the first 50 lines (project path, description, cycle number, task summary)
- One instruction per bullet — never combine two actions in one sentence
- Use absolute or project-root-relative paths — ban "appropriate", "as needed"
- No forward references — never write "see below"
- Complete code blocks only — no stubs, no `...`, no `# TODO`

### Determining the Cycle Number

To name your output file correctly (e.g., `CONTINUATION_CYCLE_14.md`):
1. Check `{{CYCLE_STATUS_FILE}}` for `inProgressCycles`
2. If `inProgressCycles` is non-empty, generate `RESUME_CYCLE_[NNr].md` for the single in-progress cycle
3. Otherwise, find the lowest numbered cycle in `pendingCycles`
4. If no cycle files exist and `pendingCycles` is empty, follow the meta plan's halt condition

The output document must be created in this directory:
`{{CYCLES_DIR}}`

## Thinking Output

After generating the document, create a **thoughts file** at:
`{{THOUGHTS_FILE}}`

Your thoughts file MUST include:

```markdown
# Claude Round {{ROUND}} Thoughts

## Key Decisions Made
- [Decision 1]: [Rationale]
- [Decision 2]: [Rationale]
...

## Potential Concerns
- [Concern 1]: [Why it might be an issue]
...

## Open Questions
- [Question 1]: [Context]
...

## Changes from Template/Plan
- [Change 1]: [Why this deviation was necessary]
...

## Decision: [CONVERGED | MINOR_REFINEMENT | MAJOR_REFINEMENT]
[Brief justification for your decision classification]
```

## Decision Classification

- **CONVERGED**: Document is complete and correct. No changes needed.
- **MINOR_REFINEMENT**: Small adjustments may be needed. Likely final.
- **MAJOR_REFINEMENT**: Significant changes expected. Further review needed.

Since this is the initial round, use MAJOR_REFINEMENT unless you're highly confident.

## Anti-Oscillation

{{PREVIOUS_CONTEXT}}

## Plan File

{{PLAN_FILE}}

---

Begin now. Read the plan file, generate the document, then write your thoughts.

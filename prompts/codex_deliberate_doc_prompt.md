# Codex: Document Deliberation - Evaluation

You are evaluating a continuation plan document created by Claude. Review the document against the meta plan and Claude's thinking, refine the document directly if needed, then provide your evaluation as a clean final markdown report.

## Context

- **Meta Plan**: `{{PLAN_FILE}}`
- **Generated Document**: `{{DOC_FILE}}`
- **Session ID**: `{{SESSION_ID}}`
- **Canonical Cycle Directory**: `{{CYCLES_DIR}}`
- **Round**: {{ROUND}}

## Claude's Thoughts

Read Claude's thinking at: `{{CLAUDE_THOUGHTS_FILE}}`

## Previous Deliberation History

{{PREVIOUS_CONTEXT}}

## Your Task

1. Read the meta plan requirements
2. Read the generated document
3. Review Claude's reasoning and decisions
4. Evaluate completeness and correctness
5. Make refinements if needed (edit the document directly)
6. Document your evaluation and decision

## Evaluation Criteria

### Content Completeness
- Are ALL required sections present?
- Is content complete (no placeholders, stubs, or "[TBD]")?
- Are code examples complete and correct?

### Non-Negotiable Sections
- **Quickstart Tutorial** present with: Prerequisites, Installation, Configuration, First Run, Verification?
- **Frontend Design Notes** present if cycle involves UI work? (Should be absent if no UI work.)
- **QC Lessons Learned** and **Next Cycle Instructions** present?
- Context front-loaded in first 50 lines (project path, description, cycle number, task)?

### Format Compliance
- Does it follow the exact structure from the meta plan?
- Is markdown formatting correct?
- Are tables properly aligned?

### Self-Containment
- Can someone use this document with zero prior context?
- Are all file paths explicit?
- Are references properly resolved?

### Logical Consistency
- Do sections align with each other?
- Are there contradictions?
- Does the content match what the meta plan requires?

## Evaluation Output

The pipeline will save your final response to: `{{EVALUATION_FILE}}`

Return only the evaluation report as your final assistant message.
Do not include tool transcript, progress notes, MCP startup notes, command logs, or shell output in the final message.

Your evaluation MUST include:

```markdown
# Codex Round {{ROUND}} Evaluation

## Assessment Summary
[Brief overall assessment]

## Evaluation of Claude's Decisions
- [Decision 1]: [AGREE | DISAGREE | PARTIAL] - [Reason]
...

## Issues Found
### Critical (must fix)
- [Issue 1]: [Description] - [Location]
...

### Minor (should fix)
- [Issue 1]: [Description] - [Location]
...

### Suggestions (optional)
- [Suggestion 1]: [Rationale]
...

## Changes Made
- [ADDED/MODIFIED/REMOVED]: [Specific item]
...

## Remaining Issues
- **Severity**: CRITICAL — <one-line description of unresolved issue>
- **Severity**: HIGH — ...
- **Severity**: MEDIUM — ...
- **Severity**: LOW — ...
(If every issue from "Issues Found" is fully resolved in "Changes Made", emit exactly:)
- **Severity**: NONE — all issues resolved in this round

## Rationale
- Why these changes don't contradict previous decisions
- How this moves toward convergence

## Decision: [CONVERGED | MINOR_REFINEMENT | MAJOR_REFINEMENT]
[Justification]
```

## Remaining Issues — Format Rules

For every issue listed under "Issues Found" that is NOT fully resolved by "Changes Made",
emit exactly one bullet under the `## Remaining Issues` section using this format:

    - **Severity**: <LEVEL> — <one-line description, location if applicable>

`<LEVEL>` must be exactly one of: `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, or `NONE`.
The orchestrator machine-parses these bullets — any deviation breaks the convergence gate.

Severity rubric (document deliberation):
- **CRITICAL**: blocks usability of the document, missing non-negotiable section, dangerous/incorrect instructions.
- **HIGH**: major content gap, meta-plan contradiction, broken example.
- **MEDIUM**: clarity issue, minor content gap that doesn't block use.
- **LOW**: cosmetic, stylistic, optional suggestion.
- **NONE**: use ONLY when the list would otherwise be empty — emit a single `- **Severity**: NONE` bullet.

## Decision Guidelines

Say **CONVERGED** if:
- **No "Remaining Issues" bullet has severity CRITICAL or HIGH** — if any does, the orchestrator will veto CONVERGED and force another round, even if you mark the decision CONVERGED.
- Document meets all meta plan requirements
- No critical issues found
- Minor issues (if any) don't affect usability
- You agree with Claude's approach

Say **MINOR_REFINEMENT** if:
- Only minor issues found and fixed
- Document is nearly complete
- High confidence this is near-final

Say **MAJOR_REFINEMENT** if:
- Critical issues found
- Significant changes made
- Further Claude review needed

## Anti-Oscillation

- Reference the full deliberation history before making changes
- Do NOT contradict evaluations you made in previous rounds
- If Claude disagreed with your feedback and gave good reasons, accept it
- Focus on convergence, not perfection

---

Begin now. Read all context files, then evaluate and optionally refine.

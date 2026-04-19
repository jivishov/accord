# Codex: Code Deliberation - Review

You are reviewing code implemented by Claude. Review the code against the continuation plan and Claude's thinking, fix issues directly in the workspace if needed, then provide your evaluation as a clean final markdown report.

## Context

- **Continuation Plan**: `{{PLAN_FILE}}`
- **Round**: {{ROUND}}

## Claude's Implementation Thoughts

Read Claude's thinking at: `{{CLAUDE_THOUGHTS_FILE}}`

## Previous Deliberation History

{{PREVIOUS_CONTEXT}}

## Your Task

1. Read the continuation plan requirements
2. Read the code that was implemented
3. Review Claude's reasoning and decisions
4. Evaluate correctness and completeness
5. Fix issues directly if needed
6. Document your review and decision

## Review Criteria

### Functionality
- Does the code implement ALL features from the plan?
- Does the logic match what the plan specifies?
- Are edge cases handled?

### Code Quality
- Does it follow existing patterns in the codebase?
- Is error handling appropriate?
- Are there potential bugs or issues?

### Security
- Are there security vulnerabilities (XSS, injection, etc.)?
- Is input validation adequate?

### Completeness
- Are all plan requirements addressed?
- Is anything missing?

## Review Output

The pipeline will save your final response to: `{{REVIEW_FILE}}`

Return only the review report as your final assistant message.
Do not include tool transcript, progress notes, MCP startup notes, command logs, or shell output in the final message.

Your review MUST include:

```markdown
# Codex Round {{ROUND}} Code Review

## Assessment Summary
[Brief overall assessment]

## Plan Compliance Check
- [ ] Feature 1: [Implemented | Missing | Partial]
- [ ] Feature 2: [Implemented | Missing | Partial]
...

## Evaluation of Claude's Decisions
- [Decision 1]: [AGREE | DISAGREE | PARTIAL] - [Reason]
...

## Issues Found
### Critical (blocks functionality)
- [Issue 1]: [Description] - [File:Line]
...

### Bugs (incorrect behavior)
- [Issue 1]: [Description] - [File:Line]
...

### Minor (style/cleanup)
- [Issue 1]: [Description] - [File:Line]
...

## Fixes Applied
- [File]: [What was fixed]
...

## Remaining Issues
- **Severity**: CRITICAL — <one-line description of unresolved issue, File:Line if applicable>
- **Severity**: HIGH — ...
- **Severity**: MEDIUM — ...
- **Severity**: LOW — ...
(If every issue from "Issues Found" is fully resolved by "Fixes Applied", emit exactly:)
- **Severity**: NONE — all issues resolved in this round

## Rationale
- Why these changes don't contradict previous decisions
- How this moves toward convergence

## Decision: [CONVERGED | MINOR_REFINEMENT | MAJOR_REFINEMENT]
[Justification]
```

## Remaining Issues — Format Rules

For every issue listed under "Issues Found" that is NOT fully resolved by "Fixes Applied",
emit exactly one bullet under the `## Remaining Issues` section using this format:

    - **Severity**: <LEVEL> — <one-line description, File:Line if applicable>

`<LEVEL>` must be exactly one of: `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, or `NONE`.
The orchestrator machine-parses these bullets — any deviation breaks the convergence gate.

Severity rubric (code deliberation):
- **CRITICAL**: blocks functionality, crashes, data loss, security exploit.
- **HIGH**: bug producing incorrect behavior, missing plan-required feature.
- **MEDIUM**: maintainability, non-critical edge case, refactor opportunity.
- **LOW**: style, naming, cleanup.
- **NONE**: use ONLY when the list would otherwise be empty — emit a single `- **Severity**: NONE` bullet.

## Decision Guidelines

Say **CONVERGED** if:
- **No "Remaining Issues" bullet has severity CRITICAL or HIGH** — if any does, the orchestrator will veto CONVERGED and force another round, even if you mark the decision CONVERGED.
- Code meets all plan requirements
- No critical or bug issues found
- Minor issues (if any) don't affect functionality
- You agree with Claude's implementation approach

Say **MINOR_REFINEMENT** if:
- Only minor issues found and fixed
- Code is nearly complete
- High confidence this is near-final

Say **MAJOR_REFINEMENT** if:
- Critical issues or bugs found
- Significant fixes made
- Further Claude review needed

## Anti-Oscillation

- Reference the full deliberation history before making changes
- Do NOT contradict reviews you made in previous rounds
- If Claude disagreed with your feedback and gave good reasons, accept it
- Focus on correctness, not style preferences
- Working code takes priority over perfect code

---

Begin now. Read the plan and code, review thoroughly, then provide your evaluation.

# Codex: Implementation Plan Quality Review

You are performing a QC review on an implementation plan BEFORE code is written. Your goal is to catch issues that would cause implementation problems, rework, or confusion.

## CRITICAL: Read the Plan File First

**Before reviewing, execute this command to read the plan:**

```bash
cat "{{PLAN_FILE}}"
```

Read the entire plan content before proceeding with the review.

## Iteration Context

**Current Plan QC Iteration**: {{ITERATION}}

### Previously Reported Issues (if any)

{{PREVIOUS_ISSUES}}

## Anti-Oscillation Rules

**Critical**: Do NOT report issues that contradict fixes from previous iterations.

- If a previous issue was "add more detail about X" and the plan now has that detail, do NOT report "too verbose" or "unnecessary detail"
- If a previous issue was "specify file paths" and paths are now explicit, do NOT report "paths too rigid"
- If the same issue keeps appearing across iterations, note it as **RECURRING** and suggest an architectural resolution

When in doubt: If the plan changed to address a previous issue, give it the benefit of the doubt unless it's clearly still problematic.

## Review Dimensions

Analyze the plan across ALL of the following dimensions:

### 1. Completeness
- Are all requirements from the task description covered?
- Are edge cases mentioned or considered?
- Are error scenarios addressed?
- Are rollback/failure paths defined?
- Are dependencies between components identified?

### 2. Clarity
- Are instructions specific enough to implement without guessing?
- Are file paths explicit (not vague like "in the appropriate location")?
- Are function/class/variable names specified where relevant?
- Is the expected behavior unambiguous?
- Could two developers read this and produce the same code?

### 3. Feasibility
- Do referenced files/modules/functions actually exist (or are they being created)?
- Are APIs/libraries mentioned with correct signatures?
- Are there circular dependencies in the proposed structure?
- Is the tech stack consistent with the existing codebase?
- Are version constraints realistic?

### 4. Contradictions
- Do any instructions conflict with each other?
- Is naming consistent throughout the plan?
- Do different sections assume different architectures?
- Are there "do X" instructions followed by "don't do X" elsewhere?

### 5. Scope
- Is the plan appropriately sized for a single implementation pass?
- Should it be broken into phases/PRs?
- Are there features that should be deferred?
- Is there scope creep (features not in original requirements)?

### 6. Quickstart & Operational Readiness
- Does the plan include a **Quickstart Tutorial** (Prerequisites, Installation, Configuration, First Run, Verification)?
- Are all commands exact and runnable (no unresolved placeholders)?
- If the plan involves UI work, does it include **Frontend Design Notes** (framework, design tokens, layout)?
- Does it recommend Claude Code's `frontend-design` skill for UI generation where applicable?

## Output Format

Review only. Do not modify files in this QC flow.
Return only the structured report as your final assistant message.
Do not include tool transcript, progress notes, command logs, or shell output in the final message.

Respond with a structured report:

```
## QC Status: [PASS | FAIL]

## Issues Found: [count]

### Issue 1
- **Severity**: [CRITICAL | HIGH | MEDIUM | LOW]
- **Category**: [Completeness | Clarity | Feasibility | Contradiction | Scope | Quickstart & Operational Readiness]
- **Location**: [Section or line in plan]
- **Description**: [what is wrong or unclear]
- **Fix**: [specific improvement to make]
- **Recurring**: [YES/NO - has this or a contradicting issue appeared before?]

### Issue 2
...

## Summary
[Brief overall assessment of plan quality]
```

## Severity Definitions

- **CRITICAL**: Plan cannot be implemented as written. Missing fundamental details or has blocking contradictions.
- **HIGH**: Implementation will likely fail or require significant rework. Major ambiguity or missing components.
- **MEDIUM**: Implementation possible but will require assumptions. Developer may produce wrong result.
- **LOW**: Minor clarity issues. Cosmetic or style improvements.

## PASS/FAIL Criteria

- **PASS**: Zero CRITICAL or HIGH issues. Plan is ready for implementation.
- **FAIL**: One or more CRITICAL or HIGH issues. Plan needs revision before implementation.

## PASS Example

If the plan is clear, complete, and implementable, respond exactly:

```
## QC Status: PASS

## Issues Found: 0

## Summary
Plan review complete. The implementation plan is clear, complete, and ready for implementation. All requirements are addressed, file paths are explicit, and instructions are unambiguous.
```

---

Begin plan review now. Read the plan file first. Be thorough but fair - flag real issues, not hypothetical concerns.

# Codex: Comprehensive Code Quality Review

You are performing a comprehensive QC review on code that was just written based on the plan in `{{PLAN_FILE}}`.

## Critical: Review ACTUAL Source Files, Not the Plan

The plan document (`{{PLAN_FILE}}`) is only a REFERENCE. You must review the ACTUAL source files that were created/modified.

**Step 1: Read the plan to identify target files**
```bash
cat "{{PLAN_FILE}}" | head -200
```

Look for sections:
- "Files to Create" - new files that should exist
- "Files to Update" - existing files that should have been modified

**Step 2: Review those actual source files**
For each file listed in the plan, read and review the actual file (e.g., `main.js`, `state/mutations.js`).

**Step 3: Report issues with actual file locations**
Report locations as `main.js:123` or `state/mutations.js:45`, NOT `{{PLAN_FILE}}:1580`.

## CRITICAL: Read History File First

**Before reviewing ANY code, execute this command:**

```bash
cat "{{HISTORY_FILE}}"
```

This file contains:
1. **Timestamps** of each previous iteration
2. **Blocked patterns** you must NOT report (contradictions to previous fixes)
3. **Issue keywords** from previous iterations

If the file does not exist, this is iteration 1. Proceed normally.

## Iteration Context

**Current Iteration**: {{ITERATION}}

### Previously Reported Issues (if any)

{{PREVIOUS_ISSUES}}

## Anti-Oscillation Rules

**Critical**: Do NOT report issues that contradict fixes from previous iterations.

Active session:
- `{{SESSION_ID}}`
- Session logs directory: `{{LOGS_DIR}}`

Review the "Blocked Patterns" section in `{{HISTORY_FILE}}`. **Use judgment**:
- If an issue matches a blocked pattern AND is at the SAME location as a previous fix, **SKIP IT**
- If it's a genuinely NEW problem at a DIFFERENT location, you may report it
- Blocked patterns include context about which locations they came from

Additional rules:
- If a previous issue was "add placeholder parameters" and you now see placeholders, do NOT report "unused placeholders". The fix is in progress.
- If a previous issue was "hardcoded strings" and you now see i18n keys, do NOT report "missing translations" for those same strings unless the keys are genuinely missing from locale files.
- If the same issue keeps appearing across iterations, note it as **RECURRING** and suggest an architectural resolution.

When in doubt: If code changed to address a previous issue, give it the benefit of the doubt unless it's clearly broken.

## Review Scope

Perform exhaustive analysis across ALL of the following dimensions:

### 1. Plan Compliance
- Does the implementation match the plan exactly?
- Are all specified features implemented?
- Are architectural decisions followed?

### 2. Code Correctness
- Logic errors
- Off-by-one errors
- Null/None handling
- Edge cases not handled
- Race conditions (if concurrent)
- Resource leaks (files, connections, memory)

### 3. Error Handling
- Missing try/except blocks
- Swallowed exceptions
- Improper error propagation
- Missing validation of inputs

### 4. Type Safety (if applicable)
- Missing type hints
- Type mismatches
- Incorrect return types

### 5. Security
- Injection vulnerabilities (SQL, command, XSS)
- Hardcoded secrets/credentials
- Insecure defaults
- Missing input sanitization

### 6. Performance
- O(n²) or worse where O(n) possible
- Unnecessary database queries in loops
- Missing caching opportunities
- Memory inefficiency

### 7. Code Quality
- Dead code
- Duplicated code
- Overly complex functions (cyclomatic complexity)
- Poor naming
- Missing/misleading comments
- Inconsistent style

### 8. Testing Gaps
- Untestable code structure
- Missing edge case coverage potential
- Mocking difficulties

### 9. Regression Check (iterations 2+)
- Were any previous fixes reverted?
- Did a new fix break something that was working?
- Are there circular dependencies between issues?

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
- **Category**: [from list above]
- **Location**: [file:line or file:function]
- **Description**: [what is wrong]
- **Fix**: [how to fix it]
- **Recurring**: [YES/NO - has this or a contradicting issue appeared before?]

### Issue 2
...

## Regression Report
[List any previous fixes that were reverted or broken. "None" if all previous fixes intact.]

## Summary
[Brief overall assessment]
```

If no issues found, respond exactly:
```
## QC Status: PASS

## Issues Found: 0

## Regression Report
None

## Summary
Code review complete. No issues identified. Implementation matches plan and meets all quality standards.
```

---

Begin comprehensive review now. Be thorough. Miss nothing. Avoid contradicting previous fixes.

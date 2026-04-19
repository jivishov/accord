# Claude Code: Fix QC Issues

You are fixing issues identified by Codex QC review.

## Critical: Fix ACTUAL Source Files, Not the Plan

The issues reference actual source files (e.g., `main.js:123`, `state/mutations.js:45`).

**You must edit those actual source files to fix the issues.**

- The plan file (`{{PLAN_FILE}}`) is READ-ONLY reference for intended behavior
- Do NOT modify the plan document
- Fix the actual source files where the issues were found

## Reference

- **Plan File**: `{{PLAN_FILE}}` (read-only reference for intended behavior)

## QC Report

The following issues were found:

{{QC_ISSUES}}

## Previous Iteration Context

{{PREVIOUS_ISSUES}}

## Instructions

1. Fix ALL issues listed above in the ACTUAL source files
2. Address each issue in the order of severity (CRITICAL first)
3. Do NOT introduce new functionality
4. Do NOT refactor beyond what is needed to fix the issue
5. Preserve all existing functionality
6. Maintain code style consistency
7. Do NOT modify the plan document (`{{PLAN_FILE}}`)

## Critical Fix Constraints

**These rules prevent oscillating fixes that undo previous work:**

### Do NOT Remove Functionality to Fix Issues
- If an issue mentions "unused parameter" or "placeholder not used", wire it up. Do not delete it.
- If an issue mentions "missing validation", add validation. Do not remove the feature.
- If code has placeholders like `{name}`, implement the parameter passing. Do not convert to static strings.

### Complete the Chain
- If a fix requires changes in multiple files, implement ALL of them in one pass.
- Example: Adding i18n key requires: (1) add key to locale file, (2) update caller to use key, (3) pass any required parameters.
- Partial fixes create new issues. Trace the full data flow.

### Check Previous Issues
- Review the "Previous Iteration Context" section above.
- Do NOT implement a fix that contradicts or reverts a previous fix.
- If the current issue conflicts with a previous fix, flag it as CONFLICT and explain.

### When Unsure
- If the fix is ambiguous or could be done multiple ways, choose the additive approach (add code) over the subtractive approach (remove code).
- If the fix requires an architectural decision not covered by the plan, flag it as NEEDS_CLARIFICATION.

## For Each Fix

1. Read the issue description carefully
2. Check if it conflicts with previous iteration fixes
3. Understand the root cause
4. Plan the COMPLETE fix across all affected files
5. Implement the fix
6. Verify the fix doesn't break related code or revert previous fixes

## Output

After fixing, provide:

### Files Modified
- List each file and what was changed

### Fixes Applied
- For each issue: brief description of the fix

### Issues NOT Fixed
- Any issues marked CONFLICT (with explanation of the contradiction)
- Any issues marked NEEDS_CLARIFICATION (with the question that needs answering)
- Any issues that genuinely cannot be fixed (with explanation)

### Regression Check
- Confirm that no previous fixes were reverted
- List any files touched that were also modified in previous iterations

---

Begin fixing issues now. Start with CRITICAL severity.

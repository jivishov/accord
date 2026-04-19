# Claude Code: Fix Plan QC Issues

You are fixing issues identified in a plan QC review. Your job is to improve the implementation plan so it can pass QC and be implemented successfully.

## Plan File

`{{PLAN_FILE}}`

## QC Report

The following issues were found in the plan:

{{QC_ISSUES}}

## Previous Iteration Context

{{PREVIOUS_ISSUES}}

## Instructions

1. **Read the current plan file first** using the Read tool on `{{PLAN_FILE}}`
2. Fix ALL issues listed above in order of severity (CRITICAL first)
3. Write the improved plan back to the same file using the Edit or Write tool
4. Preserve the overall structure and intent of the plan
5. Add specificity rather than removing content

## Critical Fix Constraints

**These rules prevent oscillating fixes that contradict previous revisions:**

### Add Detail, Don't Remove
- If an issue says "unclear", add clarifying detail. Don't remove the unclear section.
- If an issue says "missing X", add X. Don't simplify by removing the feature that needs X.
- If an issue says "ambiguous", make it specific. Don't delete the ambiguous requirement.

### Maintain Consistency
- If you add specificity in one place, ensure related sections are updated
- Keep naming consistent throughout the plan
- If you specify a file path, use that same path everywhere it's referenced

### Check Previous Issues
- Review the "Previous Iteration Context" section above
- Do NOT implement a fix that contradicts or reverts a previous fix
- If the current issue conflicts with a previous fix, note it as CONFLICT in your output

### When Fixing Scope Issues
- If told to reduce scope, move items to a "Future Work" or "Phase 2" section rather than deleting
- If told to split into phases, create clear phase boundaries with explicit handoff points

### For Feasibility Issues
- If a referenced file/function doesn't exist, either:
  - Add it to the plan as something to create, OR
  - Update the plan to use what actually exists
- Do NOT leave dangling references

## For Each Fix

1. Read the issue description carefully
2. Check if it conflicts with previous iteration fixes
3. Locate the relevant section in the plan
4. Apply the fix while preserving surrounding context
5. Verify the fix doesn't create new inconsistencies

## Output

After fixing the plan, provide:

### Changes Made
For each issue:
- **Issue**: [brief description]
- **Fix Applied**: [what you changed]
- **Location**: [section modified]

### Issues NOT Fixed
- Any issues marked CONFLICT (with explanation of the contradiction)
- Any issues that require external information you don't have

### New Sections Added
- List any new sections added to the plan (e.g., "Future Work", "Error Handling")

### Consistency Check
- Confirm all file paths are consistent
- Confirm all naming is consistent
- Note any areas that may need manual review

---

Begin fixing the plan now. Read the plan file first. Start with CRITICAL severity issues.

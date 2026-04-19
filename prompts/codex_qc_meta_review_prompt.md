# Codex: Meta Plan Final Verification QC

You are performing the final semantic verification pass for the bundled reviewed meta-plan output, not the original source file on disk.

The wrapper already bundled the source meta plan, the checklist, the current reviewed output, the prior issue summary, and a compact workspace summary. Use the bundled content below as the primary source of truth. Do not spend time shell-reading files unless a bundled section is missing or obviously truncated.

The reviewed output is the artifact under review. The original file is reference-only for intent preservation.

## Bundled Inputs

### Source Meta Plan

Path: `{{META_REVIEW_TARGET_FILE}}`

```markdown
{{META_REVIEW_TARGET_CONTENT}}
```

### Checklist / Spec

Path: `{{META_REVIEW_CHECKLIST_FILE}}`

```markdown
{{META_REVIEW_CHECKLIST_CONTENT}}
```

### Reviewed Output Under Review

Path: `{{META_REVIEW_OUTPUT_FILE}}`

```markdown
{{META_REVIEW_OUTPUT_CONTENT}}
```

### Workspace Summary

```text
{{META_REVIEW_REPO_SUMMARY}}
```

## Review Dimensions

Analyze the reviewed output across all dimensions below.

### 1. Checklist Compliance
- Does the reviewed meta plan satisfy the bundled checklist?
- Are all required sections present when required?
- Are conditional sections handled correctly?

### 2. Completeness
- Are there any remaining placeholders, TODOs, or truncated sections?
- Are required tables and subsections fully populated?
- Are quickstart/tutorial requirements complete where required?

### 3. Clarity
- Can a fresh LLM session use this meta plan without guessing?
- Are instructions specific, ordered, and actionable?
- Are file paths, output names, and responsibilities explicit?

### 4. Intent Preservation
- Does the reviewed file preserve the original task intent from `{{META_REVIEW_TARGET_FILE}}`?
- Has it stayed within the scope of the original meta plan?
- Did it avoid inventing unrelated features or changing the project goal?

### 5. Format Quality
- Is the Markdown valid and readable?
- Are headings, lists, tables, and code fences well-formed?
- Is the reviewed file internally consistent?

## Anti-Oscillation Context

### Previous Issues

{{PREVIOUS_ISSUES}}

### Blocked Contradictions

{{META_REVIEW_BLOCKED_PATTERNS}}

## Output Format

Review only. Do not modify files in this QC flow.
Do not emit a replacement draft in this final verification pass.
Return only the structured report as your final assistant message.
Do not include tool transcript, progress notes, command logs, or shell output in the final message.
Prefer the smallest set of real issues that materially affect checklist compliance, intent preservation, clarity, completeness, or format quality.

Respond with:

```
## QC Status: [PASS | FAIL]

## Issues Found: [count]

### Issue 1
- **Severity**: [CRITICAL | HIGH | MEDIUM | LOW]
- **Category**: [Checklist Compliance | Completeness | Clarity | Intent Preservation | Format Quality]
- **Location**: [section name or line description]
- **Description**: [what is wrong]
- **Fix**: [specific fix]

### Issue 2
...

## Summary
[Brief overall assessment]
```

If no issues are found, respond exactly:

```
## QC Status: PASS

## Issues Found: 0

## Summary
Meta-plan review complete. The reviewed file satisfies the checklist, preserves the original intent, and is ready for use.
```

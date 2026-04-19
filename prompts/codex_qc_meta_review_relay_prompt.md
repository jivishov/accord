# Codex: Meta Plan Relay Review

You are performing the first semantic QC pass for a reviewed meta plan.

The wrapper already bundled the source meta plan, the checklist, the current reviewed output, prior issue context, blocked contradiction patterns, and a compact workspace summary. Use the bundled content below as the primary source of truth. Do not spend time shell-reading files unless a bundled section is missing or obviously truncated.

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

## Anti-Oscillation Context

### Previous Issues

{{PREVIOUS_ISSUES}}

### Blocked Contradictions

{{META_REVIEW_BLOCKED_PATTERNS}}

## Review Goal

Analyze the reviewed output for:

1. Checklist compliance
2. Completeness
3. Clarity
4. Intent preservation
5. Format quality

When you find issues, do two things in the same final response:

1. Return the normal structured QC report.
2. Return a full replacement draft for the reviewed meta plan that fixes those issues while preserving the original task intent.

The replacement draft must:
- be a complete replacement for `{{META_REVIEW_OUTPUT_FILE}}`
- preserve the original project goal and scope from `{{META_REVIEW_TARGET_FILE}}`
- satisfy the checklist in `{{META_REVIEW_CHECKLIST_FILE}}`
- preserve validator-critical branch semantics already present in the reviewed output when they are still correct
- preserve exact canonical literals when relevant: `Project Goal Reference`, `Previous Cycle Plan File`, `Next Cycle Plan File`, `inProgressCycles`, `pendingCycles`, `Do not generate a new cycle plan`, and `RESUME_CYCLE_[NN].md`
- if a branch-specific example such as `RESUME_CYCLE_[NNr].md` is useful, keep the canonical literal too instead of replacing it
- when changing branch logic, keep Requirements, Output Structure Template, and Deliverables aligned
- keep conditional output-section wording aligned across Requirements, the Required Output Sections intro, and the Output Structure Template notes; the table may define 17 section entries, but generated plans must include all always-required sections and include `Key Differences` / `Frontend Design Notes` only when applicable
- inside the fenced `Output Structure Template`, only `[NN]`, `[NN-1]`, `[NN+1]`, `[NNr]`, and `[Cycle Title]` may remain bracketed; write authoring guidance as prose outside the fence or as concrete non-bracketed template text inside the fence, and do not add a note saying bracketed placeholders are instructions
- avoid repeating blocked contradiction patterns unless the new issue is clearly at a different location
- contain no surrounding code fences

If the reviewed output already passes, do not include a replacement draft.

## Output Format

Return only the final review response. Do not include tool transcript, progress notes, command logs, or shell output.

Start with this exact structured report:

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

If and only if `## QC Status: FAIL`, append:

<<<META_REVIEW_REPLACEMENT_DRAFT_START>>>
[full replacement markdown for `{{META_REVIEW_OUTPUT_FILE}}` only]
<<<META_REVIEW_REPLACEMENT_DRAFT_END>>>

If no issues are found, respond exactly:

```
## QC Status: PASS

## Issues Found: 0

## Summary
Meta-plan review complete. The reviewed file satisfies the checklist, preserves the original intent, and is ready for use.
```

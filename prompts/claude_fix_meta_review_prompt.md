# Claude: Fix the Reviewed Meta Plan

You are fixing issues found in the reviewed meta-plan output.

## Bundled Inputs

- Original source meta plan (read-only): `{{META_REVIEW_TARGET_FILE}}`
- Checklist/spec (read-only): `{{META_REVIEW_CHECKLIST_FILE}}`
- Reviewed output to edit: `{{META_REVIEW_OUTPUT_FILE}}`

### Source Meta Plan

```markdown
{{META_REVIEW_TARGET_CONTENT}}
```

### Checklist / Spec

```markdown
{{META_REVIEW_CHECKLIST_CONTENT}}
```

### Reviewed Output Under Fix

```markdown
{{META_REVIEW_OUTPUT_CONTENT}}
```

## Critical File Rules

- Do NOT attempt to write files directly.
- Do NOT request write approval or ask the user to save the file.
- The pipeline will write `{{META_REVIEW_OUTPUT_FILE}}` after your response is returned.
- Return the full updated content for `{{META_REVIEW_OUTPUT_FILE}}` in your response.
- Do NOT modify `{{META_REVIEW_TARGET_FILE}}`.
- Do NOT modify `{{META_REVIEW_CHECKLIST_FILE}}`.
- Make the smallest safe edit set needed to fix the reported issues, but prefer exact literal compliance over paraphrase when the QC report names required tokens, headings, file patterns, or branch labels.

## QC Issues

{{QC_ISSUES}}

## Previous Iteration Context

{{PREVIOUS_ISSUES}}

## Blocked Contradictions

{{META_REVIEW_BLOCKED_PATTERNS}}

## Fix Rules

1. Use the bundled reviewed output above as the file under fix.
2. Use the bundled checklist above as the source of truth for missing or incorrect requirements.
3. Preserve the original intent from `{{META_REVIEW_TARGET_FILE}}`.
4. Add specificity instead of deleting requested scope.
5. If a QC issue, validator finding, or checklist requirement names an exact token, heading, filename, variable, or phrase, copy that literal text verbatim into the revised file.
6. When a missing branch, artifact, or navigation field is reported, update every affected section, especially Requirements, Output Structure Template, and Deliverables.
7. When both a canonical placeholder and a branch-specific example are useful, include both rather than replacing one with the other. Example: preserve `RESUME_CYCLE_[NN].md` and also explain the concrete in-progress branch as `RESUME_CYCLE_[NNr].md`.
8. If the meta plan defines conditional sections, keep that wording consistent across Requirements, the Required Output Sections intro, and the Output Structure Template notes. Generated plans must include all always-required sections, plus `Key Differences` only for migration/refactor cycles and `Frontend Design Notes` only for UI/canvas/visual cycles.
9. Remove placeholders only by replacing them with complete content.
10. Inside the fenced `Output Structure Template`, only `[NN]`, `[NN-1]`, `[NN+1]`, `[NNr]`, and `[Cycle Title]` may remain bracketed. Write authoring guidance as prose outside the fence or as concrete non-bracketed template text inside the fence. Do not add a note saying bracketed placeholders are instructions.
11. Keep the reviewed file self-contained and implementation-safe.
12. Prefer discovery rules that match the real workspace structure instead of inventing filenames or modules.

## Literal Compliance Checklist

Before returning the revised file, verify that it explicitly contains the exact literals below whenever they are relevant to the QC issues:

- `Project Goal Reference`
- `Previous Cycle Plan File`
- `Next Cycle Plan File`
- `inProgressCycles`
- `Do not generate a new cycle plan`
- `RESUME_CYCLE_[NN].md`
- `pendingCycles`
- `all always-required sections`
- `Key Differences` only for migration/refactor cycles
- `Frontend Design Notes` only for UI/canvas/visual cycles

## Output

Return the response in this exact structure:

<<<META_REVIEW_OUTPUT_START>>>
[full updated markdown for `{{META_REVIEW_OUTPUT_FILE}}` only]
<<<META_REVIEW_OUTPUT_END>>>

After the end marker, provide:

- the reviewed file path
- the issues fixed
- any assumptions still required

Do not wrap the content between the markers in code fences.

Use the bundled reviewed output and bundled checklist content above, then return the full updated content for `{{META_REVIEW_OUTPUT_FILE}}`.

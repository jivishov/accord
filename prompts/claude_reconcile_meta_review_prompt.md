# Claude: Reconcile Codex Replacement Draft Into the Reviewed Meta Plan

You are reconciling a Codex replacement draft into the canonical reviewed meta-plan output.

## Files

- Original source meta plan (read-only): `{{META_REVIEW_TARGET_FILE}}`
- Checklist/spec (read-only): `{{META_REVIEW_CHECKLIST_FILE}}`
- Codex replacement draft (read-only): `{{META_REVIEW_REPLACEMENT_DRAFT_FILE}}`
- Codex QC report (read-only): `{{META_REVIEW_QC_REPORT_FILE}}`
- Canonical reviewed output to rewrite: `{{META_REVIEW_OUTPUT_FILE}}`

## Critical File Rules

- Do NOT attempt to write files directly.
- Do NOT request write approval or ask the user to save the file.
- The pipeline will write `{{META_REVIEW_OUTPUT_FILE}}` after your response is returned.
- Return the full updated content for `{{META_REVIEW_OUTPUT_FILE}}` in your response.
- Do NOT modify `{{META_REVIEW_TARGET_FILE}}`.
- Do NOT modify `{{META_REVIEW_CHECKLIST_FILE}}`.
- Do NOT treat the old reviewed output as source context for this step.
- Use only the source meta plan, checklist, Codex replacement draft, Codex QC report, and anti-oscillation context to produce the new canonical reviewed file.
- Make the smallest safe reconciliation needed to satisfy the issues while preserving source intent.

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

### Current Reviewed Output

Path: `{{META_REVIEW_OUTPUT_FILE}}`

```markdown
{{META_REVIEW_OUTPUT_CONTENT}}
```

## Codex QC Report

Path: `{{META_REVIEW_QC_REPORT_FILE}}`

```markdown
{{META_REVIEW_QC_REPORT_CONTENT}}
```

## Codex Replacement Draft

Path: `{{META_REVIEW_REPLACEMENT_DRAFT_FILE}}`

```markdown
{{META_REVIEW_REPLACEMENT_DRAFT_CONTENT}}
```

## Primary Issues To Resolve

{{QC_ISSUES}}

## Anti-Oscillation Context

### Previous Issues

{{PREVIOUS_ISSUES}}

### Blocked Contradictions

{{META_REVIEW_BLOCKED_PATTERNS}}

## Reconciliation Rules

1. Preserve the original task intent from the bundled source meta plan above.
2. Use the bundled checklist above as the source of truth for required sections and structure.
3. Treat the bundled current reviewed output as the deterministic-valid baseline for validator-critical structure and canonical branch wording.
4. Prefer the Codex replacement draft only for the specific semantic corrections required by the Codex QC report, then merge those corrections into the current reviewed output.
5. Do not remove or paraphrase canonical branch semantics that already exist in the current reviewed output unless the Codex QC report explicitly requires a different wording.
6. Preserve exact validator-facing literals when relevant: `Project Goal Reference`, `Previous Cycle Plan File`, `Next Cycle Plan File`, `inProgressCycles`, `pendingCycles`, `Do not generate a new cycle plan`, and `RESUME_CYCLE_[NN].md`.
7. Accept a branch-specific example such as `RESUME_CYCLE_[NNr].md` only in addition to the canonical literal, not instead of it.
8. When a branch or artifact rule changes, update Requirements, Output Structure Template, and Deliverables together.
9. Keep conditional section wording aligned across Requirements, the Required Output Sections intro, and the Output Structure Template notes. The table may define 17 section entries, but generated plans must include all always-required sections, include `Key Differences` only for migration/refactor cycles, and include `Frontend Design Notes` only for UI/canvas/visual cycles.
10. Keep the reviewed file self-contained and implementation-safe.
11. Keep the output concrete. Do not leave placeholders unresolved outside the intended template fence.
12. Inside the fenced `Output Structure Template`, only `[NN]`, `[NN-1]`, `[NN+1]`, `[NNr]`, and `[Cycle Title]` may remain bracketed. Write authoring guidance as prose outside the fence or as concrete non-bracketed template text inside the fence. Do not add a note saying bracketed placeholders are instructions.
13. Do not shell-read the current reviewed output file unless a bundled input is clearly missing.
14. Do not reintroduce issues already fixed in prior iterations unless the Codex QC report proves they still exist.

## Output

Return the response in this exact structure:

<<<META_REVIEW_OUTPUT_START>>>
[full updated markdown for `{{META_REVIEW_OUTPUT_FILE}}` only]
<<<META_REVIEW_OUTPUT_END>>>

After the end marker, provide:

- the reviewed file path
- the issues reconciled
- any assumptions still required

Do not wrap the content between the markers in code fences.

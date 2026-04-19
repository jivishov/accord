# Claude: Review and Strengthen the Selected Meta Plan

You are reviewing the selected meta plan using the bundled source meta plan content and bundled checklist content below.

## Goal

Produce the full reviewed markdown that the pipeline will save to `{{META_REVIEW_OUTPUT_FILE}}`.

## Critical File Rules

- Use the bundled source meta plan content below as the primary source input.
- Use the bundled checklist content below as the primary checklist/spec input.
- Do NOT attempt to write files directly.
- Do NOT request write approval or ask the user to save the file.
- The pipeline will write `{{META_REVIEW_OUTPUT_FILE}}` after your response is returned.
- Return the full reviewed result for `{{META_REVIEW_OUTPUT_FILE}}` in your response.
- Do NOT modify `{{META_REVIEW_TARGET_FILE}}`.
- Do NOT modify `{{META_REVIEW_CHECKLIST_FILE}}`.
- Treat this as a minimal-diff rewrite. Preserve existing wording unless it is missing, contradictory, vague, unsafe, or too paraphrased to satisfy deterministic validation.

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

## What to Improve

- Preserve the original intent of the selected meta plan.
- Fill in missing structure required by the checklist.
- Replace vague language with concrete, implementation-safe instructions.
- Remove placeholders only by replacing them with complete content.
- Keep the reviewed file self-contained for a fresh LLM session.
- Support either kind of meta plan:
  - building an app from scratch
  - reviewing and refining an existing project

## Workspace Summary

Use the current workspace shape when the source meta plan says to use the current context. Prefer discovery rules over invented filenames or architectures.

```text
{{META_REVIEW_REPO_SUMMARY}}
```

## Checklist Standard

The reviewed meta plan must satisfy the bundled checklist/spec content above, including:

- required top-level sections
- required output sections
- conditional output-section semantics: the Required Output Sections table may define 17 section entries, but generated plans must include all always-required sections, include `Key Differences` only for migration/refactor cycles, and include `Frontend Design Notes` only for UI/canvas/visual cycles
- quickstart/tutorial requirements
- self-containment requirements
- frontend guidance when applicable
- naming/output conventions where applicable

## Literal Compliance

When the checklist, source plan, or validator-critical branches imply canonical literals, preserve those exact strings in the reviewed meta plan instead of paraphrasing them away.

- Include exact validator-facing literals when relevant: `Project Goal Reference`, `Previous Cycle Plan File`, `Next Cycle Plan File`, `inProgressCycles`, `Do not generate a new cycle plan`, `RESUME_CYCLE_[NN].md`, and `pendingCycles`.
- If you need a more specific branch example, keep the canonical literal too. Example: preserve `RESUME_CYCLE_[NN].md` and also explain the concrete resumed branch as `RESUME_CYCLE_[NNr].md`.
- When adding or repairing a branch requirement, update Requirements, Output Structure Template, and Deliverables together so the same branch exists in all three places.
- Keep conditional section wording aligned across Requirements, the Required Output Sections intro, and the Output Structure Template notes. Do not describe generated plans as always containing all 17 sections when `Key Differences` and `Frontend Design Notes` are conditional.

## Quality Bar

- No `[TODO]`, `[TBD]`, `[placeholder]`, `...`, or empty checklist items
- No references to prior chats or hidden context
- No contradictory instructions
- No vague phrases like "as needed" or "appropriate"
- Keep Markdown valid and readable
- Prefer discovery-driven rules like "read `index.html` first and derive actual linked asset paths" when the workspace already exposes that structure.
- If tests already exist in the target workspace, require generated plans to read or run the relevant tests rather than relying on manual verification alone.
- Inside the fenced `Output Structure Template`, only `[NN]`, `[NN-1]`, `[NN+1]`, `[NNr]`, and `[Cycle Title]` may remain bracketed. Write authoring guidance as prose outside the fence or as concrete non-bracketed template text inside the fence. Do not add a note saying bracketed placeholders are instructions.

## Anti-Oscillation Context

{{PREVIOUS_ISSUES}}

## Output

Return the response in this exact structure:

<<<META_REVIEW_OUTPUT_START>>>
[full reviewed markdown for `{{META_REVIEW_OUTPUT_FILE}}` only]
<<<META_REVIEW_OUTPUT_END>>>

After the end marker, provide:

- the reviewed file path
- a short list of the major improvements made
- any assumptions required to complete the reviewed copy

Do not wrap the content between the markers in code fences.

Use the bundled source meta plan and bundled checklist content above, then return the reviewed meta plan content for `{{META_REVIEW_OUTPUT_FILE}}`.

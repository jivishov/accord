# Claude: Generate Document from Plan

You are generating a document based on the plan specified in `{{PLAN_FILE}}`.

## Instructions

1. Read the plan file thoroughly
2. Understand what document needs to be generated
3. Generate the document with ALL required sections
4. Use complete content - no placeholders or stubs
5. Follow the exact format specified in the plan
6. Save the continuation plan inside `{{CYCLES_DIR}}`

## Canonical Output Location

- Active session: `{{SESSION_ID}}`
- Write generated continuation plans only under `{{CYCLES_DIR}}`
- Use `{{CYCLE_STATUS_FILE}}` to determine the next canonical cycle number when needed
- Do NOT write `CONTINUATION_CYCLE_*.md` files to the repo root or current directory

## Critical Requirements

### Content Completeness
- Do NOT leave "[TBD]", "[TODO]", "[PLACEHOLDER]", or similar placeholder text
- Do NOT truncate content with "..." or "etc."
- Do NOT skip required sections
- Do NOT leave empty checklist items "- [ ] "
- Include complete code blocks where specified

### Self-Containment
- The generated document must be usable by someone with zero prior context
- Never reference "previous conversation" or "as discussed"
- Include all necessary context inline
- Provide complete, runnable code examples (not stubs)
- Use explicit file paths (absolute or clearly relative)

### Quickstart Tutorial
- Every generated cycle plan MUST include a **Quickstart Tutorial** section
- The tutorial must cover: Prerequisites, Installation, Configuration, First Run, and Verification
- Commands must be exact and copy-paste runnable — no placeholders like `<your-value>`
- Include example values for environment variables and config files

### Frontend Design Notes (when applicable)
- If the cycle involves UI/frontend work, include a **Frontend Design Notes** section
- Specify target framework, design tokens (colors, spacing, typography), and layout constraints
- Recommend using Claude Code's `frontend-design` skill for production-grade UI components
- If the cycle has no UI work, omit this section entirely

### Format Adherence
- Follow the exact section structure specified in the plan
- Use proper markdown formatting
- Tag code blocks with correct language identifiers
- Ensure tables are properly aligned

## Anti-Oscillation Context

{{PREVIOUS_ISSUES}}

## Constraints

- Do NOT deviate from the plan's structure requirements
- Do NOT add sections not specified in the plan
- Do NOT skip any required section
- If the plan is ambiguous, implement the most complete interpretation

## Output

After generating the document, provide a brief summary:
- Document file created (full path under `{{CYCLES_DIR}}`)
- All sections included
- Any assumptions made

## Plan File Location

{{PLAN_FILE}}

---

Begin document generation now. Read the plan file first.

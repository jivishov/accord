# Codex: Document Quality Review

## CRITICAL: Read the Generated Document First

**You MUST read the generated document before reviewing it.** The plan file specifies what document should have been generated.

**Step 1: Read the plan to understand the expected output**
```bash
cat {{PLAN_FILE}}
```

**Step 2: Find and read the generated document**

The generated document must live inside the canonical cycle directory:
- Session ID: `{{SESSION_ID}}`
- Canonical cycle directory: `{{CYCLES_DIR}}`

The generated document is typically one of:
- A `CONTINUATION_CYCLE_*.md` file inside `{{CYCLES_DIR}}`
- An output file explicitly named in the plan inside `{{CYCLES_DIR}}`

```powershell
# Find recently modified markdown files in the active session cycle directory
Get-ChildItem "{{CYCLES_DIR}}" -Filter "*.md" | Sort-Object LastWriteTime -Descending | Select-Object -First 5

# Read the most recently modified CONTINUATION_CYCLE file in the active session
Get-ChildItem "{{CYCLES_DIR}}" -Filter "CONTINUATION_CYCLE_*.md" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1 |
  ForEach-Object { Get-Content $_.FullName }
```

**Read the plan file first, identify the expected output file under `{{CYCLES_DIR}}`, then read that file before proceeding with review.**

---

## Plan File

`{{PLAN_FILE}}`

---

## Review Dimensions

Perform exhaustive analysis across ALL of the following dimensions:

### 1. Structure Compliance
- Does the document contain all required sections from the plan?
- Are sections in the correct order?
- Are section headers formatted correctly?
- Is the document hierarchy logical?

### 2. Completeness
- Are there any placeholder texts like "[TBD]", "[TODO]", "[fill in]", "..."?
- Are all code blocks complete (not truncated)?
- Are all tables fully populated?
- Are all checklist items defined (not empty brackets)?

### 3. Clarity
- Can a fresh LLM session execute this document without ambiguity?
- Are instructions specific and actionable?
- Are technical terms defined or self-evident?
- Is context sufficient for someone with no prior knowledge?

### 4. Specificity
- Are file paths explicit (absolute or clearly relative)?
- Are filenames exact (not generic like "file.py")?
- Are code examples complete and runnable?
- Are version requirements specified where relevant?

### 5. Consistency
- Does terminology match throughout the document?
- Do cross-references point to existing sections?
- Are code style and formatting uniform?
- Do examples match the described patterns?

### 6. Self-Propagation (for cycle plans)
- Does the document contain instructions for generating the next iteration?
- Are those instructions complete and follow the same format?
- Is critical feedback/lessons learned section present?

### 6a. Quickstart Tutorial (for cycle plans)
- Does the document contain a **Quickstart Tutorial** section?
- Does it cover: Prerequisites, Installation, Configuration, First Run, Verification?
- Are all commands exact and copy-paste runnable (no unresolved placeholders)?
- Are example values provided for environment variables and config files?

### 6b. Frontend Design Notes (when applicable)
- If the cycle involves UI work, does the document contain a **Frontend Design Notes** section?
- Does it specify: target framework, design tokens, layout constraints?
- Does it reference Claude Code's `frontend-design` skill for UI generation?
- If the cycle has no UI work, this section should be absent (not empty)

### 7. Accuracy
- Do code examples match their descriptions?
- Are stated dependencies actually required?
- Do verification steps match the deliverables?
- Are checklist items verifiable?

### 8. Format Quality
- Are markdown elements properly formatted?
- Are code blocks tagged with correct language?
- Are tables aligned and readable?
- Is whitespace used appropriately?

---

## Anti-Oscillation Context

{{PREVIOUS_ISSUES}}

---

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
- **Location**: [section name or line description]
- **Description**: [what is wrong]
- **Fix**: [how to fix it]

### Issue 2
...

## Summary
[Brief overall assessment]
```

### Severity Definitions

- **CRITICAL**: Document cannot be used as-is (missing required sections, broken structure)
- **HIGH**: Major gaps that will cause implementation failure (incomplete code, missing paths)
- **MEDIUM**: Issues that may cause confusion or errors (unclear instructions, inconsistencies)
- **LOW**: Polish issues (formatting, typos, style)

If no issues found, respond exactly:
```
## QC Status: PASS

## Issues Found: 0

## Summary
Document review complete. No issues identified. Document is complete, clear, and ready for use.
```

---

Begin comprehensive review now. **First read the plan, then read the generated document, then review.** Be thorough. Miss nothing.

# Claude Code: Implementation Prompt

You are implementing code based on the plan specified in `{{PLAN_FILE}}`.

## Critical: Write to Actual Source Files

The plan document contains:
- **"Files to Create"** section - lists new files to create
- **"Files to Update"** section - lists existing files to modify
- **"Implementation Details"** section - contains complete code blocks for each file

**Your job is to EXTRACT the code from the plan and WRITE it to the actual target files.**

Example: If the plan says "Files to Create: `main.js`" and has a code block for main.js in Implementation Details, you must write that code to the actual `main.js` file, NOT leave it in the plan document.

## Instructions

1. Read the implementation plan thoroughly
2. Identify all files listed in "Files to Create" and "Files to Update" sections
3. For each file, find its code block in "Implementation Details"
4. Write/update the actual source files with that code
5. Follow all architectural decisions in the plan
6. Use proper error handling and type hints (if applicable)
7. Include docstrings/comments for complex logic

## Constraints

- Do NOT modify the plan document (`{{PLAN_FILE}}`) - it is read-only reference
- Do NOT deviate from the plan's architecture
- Do NOT add features not specified in the plan
- Do NOT skip any file listed in the plan
- If the plan is ambiguous, implement the most straightforward interpretation

## Output

After implementation, provide a brief summary:
- Files created (with full paths)
- Files modified (with full paths)
- Any assumptions made
- Any plan ambiguities encountered

## Plan File Location

{{PLAN_FILE}}

---

Begin implementation now. Read the plan file first, then write code to the actual target files.

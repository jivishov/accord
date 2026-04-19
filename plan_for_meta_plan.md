# Plan: Define and Refine meta_plan.md

## Overview

Review and refine `meta_plan.md` to ensure it properly defines how to generate cycle implementation plans. The meta_plan is a template/instruction set that guides the creation of `CONTINUATION_CYCLE_[NN].md` files. All instructions are optimized for LLM consumption: front-loaded context, structured decision points, and zero ambiguity.

## Input File

- `meta_plan.md` - Current meta plan to review and refine

## LLM Productivity Directives

> These rules apply to every document produced or validated by this plan. They exist to minimize token waste, eliminate re-reads, and keep LLMs in a single forward pass.

1. **Front-load context** — The first 50 lines of any generated plan must contain: project path, project description, current cycle number, and what to build. An LLM should never scroll to understand what it is doing.
2. **One instruction per bullet** — Never combine two actions in a single sentence. Each bullet is a discrete, verifiable task.
3. **Explicit over implicit** — File paths are absolute or relative to project root. Function names are exact. "Appropriate" and "as needed" are banned phrases.
4. **Structured decision trees** — When the LLM must choose (e.g., migration vs. new file), provide an `if/then` block, not prose.
5. **No forward references** — Never say "see below" or "as described later". Every section must be readable top-to-bottom without jumping.
6. **Minimal preamble** — Skip motivational text, history lessons, or restatements of the obvious. Start each section with actionable content.
7. **Token budget awareness** — Code blocks should be complete but not padded with excessive comments. Prefer inline annotations on non-obvious lines only.

## Requirements

### 1. Validate Meta Plan Structure

The meta_plan.md must contain these top-level sections:

| Section | Required | Purpose |
|---------|----------|---------|
| Overview | Yes | Brief description of what the meta plan does |
| Input Files | Yes | List of files to read (_DEVELOPMENT_CYCLES.md, _CYCLE_STATUS.json) |
| LLM Productivity Rules | Yes | Rules for minimizing token waste and maximizing single-pass execution |
| Requirements | Yes | Numbered sub-sections covering: verify state, generate plan, standalone rules, quickstart tutorial, frontend design, required output sections table, status file update |
| Output Structure Template | Yes | Complete template of the output format (using tilde fences to avoid nesting) |
| Deliverables | Yes | List of files to be created |

### 2. Validate Requirements Section

The Requirements section must instruct the LLM to:

1. Read the development cycles document
2. Read the cycle status file
3. Verify previous cycle completion
4. Identify the next cycle to implement
5. Generate a detailed, self-contained plan
6. Update the status file
7. Generate a quickstart tutorial section covering how to install, configure, and run the target application

### 3. Validate Required Sections Table

The table must specify these output plan sections:

- Project Location
- What This Project Is
- Completed Work Table
- Current Cycle Task
- Pre-Conditions
- Files to Create
- Files to Update
- Context Files to Read
- Implementation Details
- Verification Checklist
- Key Differences (if migrating/refactoring)
- Running/Testing Instructions
- Quickstart Tutorial
- Frontend Design Notes (when applicable)
- After Completion Instructions
- QC Lessons Learned
- Next Cycle Instructions

### 4. Validate Self-Containment Instructions

The meta_plan must explicitly state that generated plans:

- Assume reader has zero context from prior sessions
- Never reference "previous conversation" or "as discussed"
- Include all necessary context inline
- Provide complete, runnable code (not stubs)
- Use absolute paths or clearly relative paths
- Include a Quickstart Tutorial section so that any developer (or LLM) can start the app from scratch

### 5. Validate Output Naming Convention

The meta_plan must specify:

- Output filename: `CONTINUATION_CYCLE_[NN].md`
- NN is two-digit cycle number (e.g., 07, 11, 15)

### 6. Validate Quickstart Tutorial Section

The meta_plan must instruct the LLM to include a **Quickstart Tutorial** in every generated cycle plan. The tutorial must contain:

| Sub-section | Required | Content |
|-------------|----------|---------|
| Prerequisites | Yes | OS, runtime versions, required tools |
| Installation | Yes | Step-by-step commands to install dependencies |
| Configuration | Yes | Environment variables, config files, secrets setup |
| First Run | Yes | Exact command(s) to start the application |
| Verification | Yes | How to confirm the app is running (URL, CLI output, etc.) |
| Common Issues | No | Known gotchas and their fixes |

### 7. Validate Frontend Design Guidance

The meta_plan must include guidance for when a cycle involves UI/frontend work:

- Suggest using **Claude Code with the `frontend-design` skill** for generating production-grade UI components
- Note that Claude Code can handle HTML/CSS/JS, React, Vue, Svelte, and other frontend frameworks
- Recommend specifying design tokens, color palettes, and layout constraints in the cycle plan so Claude Code can produce polished, non-generic UI
- If the cycle requires UI mockups or prototypes, include a `Frontend Design Notes` section in the output plan

## Deliverables

1. Refined `meta_plan.md` with all required sections complete
2. Any missing sections added
3. Any unclear instructions clarified
4. Consistent formatting throughout
5. Quickstart Tutorial requirement integrated
6. Frontend design guidance included

## Completion Criteria

- [ ] All 6 required top-level sections present in meta_plan.md
- [ ] Requirements section has all 7 verification/generation steps
- [ ] Required Sections table has all 17 output plan sections
- [ ] Self-containment instructions are explicit
- [ ] Output naming convention uses CONTINUATION_CYCLE_[NN].md format
- [ ] No placeholder text or TODOs remain
- [ ] Quickstart Tutorial sub-sections table is present
- [ ] Frontend design guidance section is present
- [ ] LLM Productivity Directives are embedded or referenced in meta_plan.md

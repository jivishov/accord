# Pipeline & Modes

## Purpose

This app runs a cross-model QC workflow.

At a high level:

1. Claude implements or revises work from a plan.
2. Codex reviews the result.
3. Claude fixes reported issues.
4. The loop continues until the quality gate passes or the iteration limit is reached.

The app does not replace the PowerShell engine. It configures, launches, monitors, and presents the files produced by that engine.

## Standard Pipeline Stages

Every run moves through up to three phases:

```
Phase 0 (Plan QC)  →  Phase 1 (Implementation)  →  Phase 2 (QC Loop or Deliberation)
```

### Phase 0: Plan QC (optional)

Codex reviews your plan for completeness, clarity, feasibility, and contradictions. If it fails, Claude fixes the plan and Codex reviews again. This loops until the plan passes or the plan QC iteration limit is reached.

Skip this phase with the **Skip Plan QC** flag when using a trusted or previously reviewed plan.

### Phase 1: Implementation

Claude reads the plan and writes code (in code mode) or generates a document (in document mode). A git checkpoint is created after this step.

### Phase 2: QC Loop or Deliberation

**Standard mode:** Codex reviews the output. If it passes, the pipeline is done. If it fails, issues are extracted, Claude fixes them, and Codex reviews again. This continues until QC passes or the iteration limit is reached.

**Deliberation mode:** Instead of pass/fail, Claude and Codex take turns "thinking" and "evaluating" collaboratively until they converge on a solution. See the Deliberation Mode section below.

Every run is tracked by a unique `session_id`.

## Session Layout

The pipeline writes session-scoped output into your target project directory (the "Workspace Directory" in the app):

- `logs/<session_id>/`
- `cycles/<session_id>/`

Important files:

- `run_state.json`: current pipeline state
- `events.ndjson`: structured event stream
- `_iteration_history.md`: anti-oscillation context for repeated QC loops
- QC reports and plan QC reports
- continuation cycle plans

## Code Mode

Use `code` mode when the end result is source code.

Typical cases:

- feature implementation
- bug fixes
- refactors
- code-first tasks with supporting documentation

```powershell
.\accord.ps1 -PlanFile "plan.md"
# or explicitly:
.\accord.ps1 -PlanFile "plan.md" -QCType code
```

**QC Dimensions (8 review areas):**

1. **Plan Compliance** — Does the implementation match the plan?
2. **Code Correctness** — Logic errors, edge cases, null handling
3. **Error Handling** — Exceptions, validation, error propagation
4. **Type Safety** — Type hints, return types, generics
5. **Security** — Injection, secrets exposure, input validation
6. **Performance** — Algorithmic complexity, unnecessary queries, caching
7. **Code Quality** — Dead code, duplication, naming conventions
8. **Testing Gaps** — Testability, coverage potential, missing test cases

| Scenario | Why code mode |
|----------|--------------|
| Implementing a new feature | Standard code QC |
| Fixing a bug | Focus on correctness |
| Refactoring | Focus on quality and no regressions |
| Mixed code + docs | Code mode as baseline |

## Document Mode

Use `document` mode when the end result is a plan or written document.

Typical cases:

- generating continuation cycle plans from meta-plans
- refining a meta-plan into an actionable implementation plan
- creating documentation or structured specifications

```powershell
.\accord.ps1 -PlanFile "meta_plan.md" -QCType document
```

**QC Dimensions (8 review areas):**

1. **Completeness** — All requirements addressed
2. **Clarity** — Unambiguous instructions
3. **Structure** — Logical organization
4. **Consistency** — No contradictions
5. **Feasibility** — Realistic scope and expectations
6. **Traceability** — Requirements linked to outputs
7. **Actionability** — Clear, specific next steps
8. **Self-Containment** — No unresolved external dependencies

| Scenario | Why document mode |
|----------|------------------|
| Generating a cycle plan from a meta-plan | Document clarity matters more than code quality |
| Refining a meta-plan | Focus on plan structure, not code |
| Creating documentation | Focus on completeness and clarity |

## Plan QC

Plan QC validates the input plan before main implementation begins.

Use it when:

- the plan is complex
- the task has many requirements
- you want contradictions or ambiguity caught early

If plan QC fails, the pipeline loops on plan fixes before moving on to implementation.

## Deliberation Mode

Deliberation mode is a collaborative evaluation flow instead of the standard write-review-fix loop.

### How It Works

Instead of Codex issuing a pass/fail verdict, both agents engage in structured rounds:

1. **Claude** writes/implements and documents its thinking (key decisions, concerns, open questions)
2. **Codex** evaluates Claude's work and thinking, provides feedback, and declares a decision
3. **Claude** reviews feedback, refines the work, and updates its thinking
4. Repeat until convergence

### When to Use It

| Scenario | Standard Mode | Deliberation Mode |
|----------|--------------|-------------------|
| Simple bug fixes | Faster | Overkill |
| Well-defined features | Efficient | Optional |
| Complex/ambiguous plans | May oscillate | Better convergence |
| Architecture decisions | Limited feedback | Iterative refinement |
| Meta-plan generation | Basic QC | Deep collaboration |

### Convergence Criteria

The deliberation stops when any of these conditions are met:

1. **Both say CONVERGED** — Full agreement, work is complete
2. **Soft convergence** — 2+ consecutive rounds where both say MINOR_REFINEMENT
3. **Max rounds reached** — Configurable limit (default: 4, max: 10)

### Decision Classifications

Each agent declares one of these decisions every round:

| Decision | Meaning | Effect |
|----------|---------|--------|
| **CONVERGED** | Work is complete, no changes needed | May trigger early exit |
| **MINOR_REFINEMENT** | Small tweaks only, likely final | Counts toward soft convergence |
| **MAJOR_REFINEMENT** | Significant changes needed | Resets soft convergence counter |

A persistent disagreement warning triggers after 3+ consecutive MAJOR_REFINEMENT rounds.

### Deliberation Output

Deliberation creates artifacts in `logs/<session_id>/deliberation/`:

```
deliberation/
├── phase0/                          # Document deliberation
│   ├── round1_claude_thoughts.md    # Claude's reasoning and decisions
│   ├── round1_codex_evaluation.md   # Codex's feedback and assessment
│   ├── round2_claude_thoughts.md
│   ├── round2_codex_evaluation.md
│   └── deliberation_summary.md      # Final convergence summary
└── phase1/                          # Code deliberation
    ├── round1_claude_thoughts.md
    ├── round1_codex_review.md
    └── deliberation_summary.md
```

### Resume From Failure

Failed, stale, or cancelled deliberation sessions can be resumed from the last saved round state.

- Resume uses `logs/<session_id>/session_config.json`, not the current Configure form values.
- Resume keeps the same `session_id` and starts a new pipeline/log file for the resumed attempt.
- Resume reconstructs progress from deliberation artifacts plus `events.ndjson`.

Round reconstruction rules:

1. If both round files exist, resume the next round with Claude.
2. If only Claude's round file exists, resume the same round with Codex.
3. If a round-start event exists without round artifacts, resume the same round with Claude.

Desktop flow after restart:

1. Set the workspace directory to the original target project.
2. Select the failed session.
3. Click `Resume`.

### Examples

```powershell
# Document deliberation — both LLMs develop a plan together
.\accord.ps1 -PlanFile "meta_plan.md" -QCType document -DeliberationMode

# Code deliberation — both LLMs refine implementation together
.\accord.ps1 -PlanFile "cycles\<session_id>\CONTINUATION_CYCLE_1.md" -DeliberationMode

# Extended rounds for complex tasks
.\accord.ps1 -PlanFile "complex_plan.md" -DeliberationMode -MaxDeliberationRounds 8

# Skip plan QC and go straight to code deliberation
.\accord.ps1 -PlanFile "plan.md" -SkipPlanQC -DeliberationMode

# Resume a failed deliberation session
.\accord.ps1 -PlanFile "meta_plan.md" -QCType document -DeliberationMode -ResumeFromFailure
```

## Flags Reference

### Deliberation Mode

Replaces the standard write-review-fix loop with collaborative rounds where Claude and Codex alternate thinking and evaluation until convergence. See the Deliberation Mode section above for full details.

```powershell
.\accord.ps1 -PlanFile "meta_plan.md" -QCType document -DeliberationMode -MaxDeliberationRounds 6
```

### Skip Plan QC

Skips Phase 0 (plan validation) entirely, jumping straight to implementation. Use for:

- Continuation cycle plans generated by a previous run
- Plans you have already reviewed manually
- Quick iteration when plan quality is not in question

```powershell
.\accord.ps1 -PlanFile "cycles\<session_id>\CONTINUATION_CYCLE_1.md" -SkipPlanQC
```

### Pass On Medium Only

Changes the early-exit behavior of the QC loop. Normally the pipeline keeps iterating until zero CRITICAL and zero HIGH issues remain, and may also attempt to fix MEDIUM/LOW issues. With this flag, the pipeline exits with PASS as soon as only MEDIUM or LOW severity issues remain.

- Reduces iteration count and token cost
- Useful when minor code quality issues are acceptable
- Does **not** lower the quality bar for CRITICAL/HIGH — those must always be zero

```powershell
.\accord.ps1 -PlanFile "plan.md" -PassOnMediumOnly -MaxIterations 5
```

## Severity Levels

| Severity | Definition | Action |
|----------|------------|--------|
| **CRITICAL** | Security vulnerability or data loss risk | Must fix — blocks QC pass |
| **HIGH** | Incorrect behavior, crash, or logic error | Must fix — blocks QC pass |
| **MEDIUM** | Code quality or maintainability issue | Should fix — does not block pass |
| **LOW** | Style or minor improvement | Optional — does not block pass |

**Pass criteria:** Zero CRITICAL + zero HIGH issues.

**With `-PassOnMediumOnly`:** Pipeline stops early once only MEDIUM/LOW remain.

## Anti-Oscillation

### The Problem

Without context tracking, QC loops often oscillate:

```
Iteration 1: "Add validation for empty input"
Iteration 2: Claude adds validation
Iteration 3: "Unnecessary validation, remove it"
Iteration 4: Claude removes validation
Iteration 5: "Missing validation for empty input"
... infinite loop ...
```

### The Solution

The pipeline maintains `logs/<session_id>/_iteration_history.md` that tracks:

1. **Issue patterns** extracted from each QC report (keywords, locations, actions)
2. **Blocked patterns** generated automatically — if the previous iteration said "add X", the next iteration blocks "remove X" or "unused X" at the same location
3. **Contradiction detection** using a built-in map (e.g., `add` blocks `remove`, `missing` blocks `unused`)

Codex is instructed to read the iteration history before reviewing and skip issues that match blocked patterns at the same location. Genuinely new issues at different locations are still reported.

**Professional judgment clause:** Blocked patterns are guidance, not absolute rules. If an issue is genuinely problematic despite matching a blocked pattern, Codex can still report it with justification.

## Hybrid QC Mode

Use Claude Code for the first N QC iterations, then switch to Codex for thorough final verification.

- Claude Code is faster for catching obvious issues in early iterations
- Codex provides deeper analysis for final verification
- Reduces total iteration time and token cost

```powershell
# Claude does QC for iterations 1-3, Codex for 4+
.\accord.ps1 -PlanFile "plan.md" -ClaudeQCIterations 3

# Claude does QC for iterations 1-5, Codex for 6+
.\accord.ps1 -PlanFile "meta_plan.md" -QCType document -ClaudeQCIterations 5
```

Set `Claude QC Iterations` to 0 (default) for Codex-only review.

## Meta-Plan Workflow: From Idea to Code

This is the key workflow where both LLMs collaborate to develop a detailed implementation plan from a rough user prompt.

### What Is a Meta-Plan?

A meta-plan is a high-level description of what you want to build. It does not need full function signatures or exact file paths — just the goal, features, and constraints. Think of it as a brief for the two AI agents.

**Tip:** Use the **+ New** button next to the Plan File field in the desktop app to create a meta-plan from a built-in template without leaving the app.

### How It Works

```
Rough Idea → meta_plan.md → Document QC/Deliberation → CONTINUATION_CYCLE_N.md → Code QC → Working Code
```

**Stage 1 — Generate a detailed plan:**

Run your meta-plan through document mode. Claude generates a detailed continuation plan document. Codex reviews it for completeness, clarity, structure, and feasibility. They iterate until the document passes QC.

With deliberation mode enabled, the two agents collaborate even more deeply — Claude documents its decisions and reasoning, Codex evaluates and provides structured feedback, Claude refines, and they continue until both converge.

```powershell
# Standard document QC (write-review-fix loop)
.\accord.ps1 -PlanFile "meta_plan.md" -QCType document

# Document deliberation (collaborative back-and-forth)
.\accord.ps1 -PlanFile "meta_plan.md" -QCType document -DeliberationMode
```

The output is a `CONTINUATION_CYCLE_*.md` file in `cycles/<session_id>/` — a detailed, self-contained implementation plan ready for code mode.

**Stage 2 — Implement code from the plan:**

```powershell
.\accord.ps1 -PlanFile "cycles\<session_id>\CONTINUATION_CYCLE_1.md" -SkipPlanQC
```

### Example Meta-Plan

```markdown
# Meta-Plan: User Profile Management

## Goal
Add user profile CRUD operations to the existing Express API.

## Features
1. Profile creation with avatar upload
2. Profile editing with field validation
3. Email preference management
4. Profile deletion with cascade cleanup

## Constraints
- Must not break existing auth flows
- Must be backward compatible with API v1
- PostgreSQL for storage, S3 for avatars
```

## Parameters Reference

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `-PlanFile` | (required) | any .md path | Path to the implementation plan or meta-plan |
| `-QCType` | `code` | `code`, `document` | QC mode selector |
| `-MaxIterations` | 10 | 1-100 | Maximum QC fix loop iterations |
| `-MaxPlanQCIterations` | 5 | 1-20 | Maximum Phase 0 plan review iterations |
| `-SkipPlanQC` | off | toggle | Skip Phase 0 plan validation |
| `-DeliberationMode` | off | toggle | Enable collaborative deliberation |
| `-MaxDeliberationRounds` | 4 | 2-10 | Maximum deliberation rounds |
| `-PassOnMediumOnly` | off | toggle | Pass when only MEDIUM/LOW issues remain |
| `-ClaudeQCIterations` | 0 | 0-20 | Use Claude for first N QC iterations before switching to Codex |
| `-HistoryIterations` | 2 | 1-10 | Past iterations kept in anti-oscillation context |
| `-ReasoningEffort` | `xhigh` | `low`, `medium`, `high`, `xhigh` | Codex review depth |
| `-PromptDir` | `<script_dir>/prompts` | any path | Custom prompt template directory |

## Advanced Workflows

### Continuous Development Cycles

For ongoing feature development, chain cycle plans:

```powershell
# Cycle 1
.\accord.ps1 -PlanFile "cycle_1_plan.md"

# Cycle 2 (builds on previous work)
.\accord.ps1 -PlanFile "cycle_2_plan.md" -SkipPlanQC

# Periodically run full plan QC
.\accord.ps1 -PlanFile "cycle_3_plan.md"
```

### Token Economy Tips

- **`-PassOnMediumOnly`**: Biggest saver — exits early when only minor issues remain
- **`-HistoryIterations 2`**: Keeps only recent context, reduces prompt size ~30%
- **`-ReasoningEffort high`**: Use instead of `xhigh` after iteration 1 (~20% faster)
- **`-ClaudeQCIterations 3`**: Claude is faster for initial QC passes

### AGENTS.md Customization

Copy `AGENTS.md` to your project root to configure Codex with project-specific rules:

- Language-specific rules (e.g., "use pathlib not os.path")
- Project-specific patterns (e.g., "all endpoints must use @require_auth")
- Known exceptions (e.g., "ignore style rules in migrations/")

## Standard vs App Behavior

The PowerShell script is still the source of truth for execution behavior.

The desktop app adds:

- form-based configuration
- session discovery
- state polling and event watching
- report and log viewing
- resume and cancel controls
- in-app documentation

If you need raw execution details, inspect the session artifacts written by the pipeline.

## Common Failure Cases

- missing CLI dependency
- unauthenticated Claude or Codex CLI
- invalid or missing plan file
- prompt directory missing required prompt templates
- iteration limit reached before quality passes

### Debugging Convergence Issues

**Symptom:** Pipeline oscillates between the same issues.

**Diagnosis:**
1. Open `_iteration_history.md` for the session
2. Look for the same keywords appearing every other iteration
3. Check if blocked patterns are being ignored
4. Check QC reports for `Recurring: YES` markers

**Solutions:**

1. **Plan has contradicting requirements** — Relax or prioritize conflicting rules in the plan
2. **QC is too strict** — Add exceptions to `AGENTS.md` or relax checks in prompt templates
3. **Blocked patterns not working** — Check if issues are at genuinely new locations (blocked patterns are location-specific)

### Recovery Steps

```powershell
# Option 1: Simplify the plan and retry
# Edit plan.md to remove problematic requirements
.\accord.ps1 -PlanFile "plan.md" -SkipPlanQC

# Option 2: Manual fix then continue
# Fix issues by hand, clear history to start fresh
Remove-Item .\logs\<session_id>\_iteration_history.md
.\accord.ps1 -PlanFile "plan.md" -SkipPlanQC -MaxIterations 5

# Option 3: Increase iteration limit
.\accord.ps1 -PlanFile "plan.md" -MaxIterations 25
```

When this happens:

- check `Run Status`
- inspect `Recent Events`
- open the latest report or session log
- review continuation cycle files if the pipeline generated one


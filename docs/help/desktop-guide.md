# Desktop Guide

## App Layout

The desktop UI is organized into five working areas.

## Top Bar

The top bar gives you:

- a quick description of the app
- the always-available `Help` link
- high-level reminders about the workflow

Use Help whenever you need instructions without leaving the app.

## Session Rail

The left rail shows sessions discovered in the current target project directory.

It summarizes:

- total sessions
- currently running sessions
- session status
- latest phase or plan context

Use the rail to switch between runs. Selecting a session refreshes the status panel, event feed, and artifact list.

## Command Deck

The command deck is where you configure and launch the pipeline.

### Main Fields

- **Workspace Directory**: your **target project directory** — the project you want Claude and Codex to work on. This is where all output (`logs/`, `cycles/`) is written. **This is not the QC app's own folder.**
- **Plan File**: the markdown plan or continuation cycle plan to execute. This path is resolved **relative to the target project directory**. Place your plan file inside the target project folder (e.g., `C:\Projects\my-api\plan.md`). You can also use an absolute path.
- **+ New** button: opens a built-in meta-plan editor in the viewer pane. Write your meta-plan from a template, save it to the target project directory, and the Plan File field is set automatically.

### QC Type

Controls the kind of output and how it is reviewed:

- **code** (default): End result is source code. Claude writes code from your plan, Codex reviews for correctness, security, performance, error handling, type safety, code quality, and testing gaps (8 review dimensions).
- **document**: End result is a plan or written document. Claude generates the document, Codex reviews for completeness, clarity, structure, consistency, feasibility, traceability, actionability, and self-containment (8 review dimensions).

**Tip:** Use `document` mode with a meta-plan to have both LLMs collaboratively generate a detailed implementation plan, then switch to `code` mode to implement it. See the Quick Start guide for the full two-stage workflow.

### Reasoning Effort

Controls how deeply Codex analyzes the output:

| Level | Behavior |
|-------|----------|
| **xhigh** (default) | Maximum depth, most thorough review |
| **high** | Slightly faster, still detailed |
| **medium** | Balanced speed and depth |
| **low** | Fastest, surface-level review |

Lowering this after the first iteration (e.g., from `xhigh` to `high`) can reduce token cost by roughly 20% per iteration.

### Flags

Three toggle switches control pipeline behavior:

| Flag | What it does | When to enable |
|------|-------------|----------------|
| **Deliberation Mode** | Replaces the standard write-review-fix loop with collaborative Claude+Codex rounds. Both agents alternate "thinking" and "evaluation" until they converge on a solution. | Ambiguous tasks, architecture decisions, quality-critical work, meta-plan generation |
| **Skip Plan QC** | Skips Phase 0 (plan validation) and jumps straight to implementation. | Trusted plans, continuation cycles from previous runs, already-reviewed plans |
| **Pass On Medium Only** | Pipeline passes when only MEDIUM/LOW severity issues remain, instead of trying to fix them. | Fast iteration, when minor code quality issues are acceptable, token cost savings |

### Main Controls

- **Start Run**: launches a new session with the current form settings.
- **Review Meta Plan**: treats the selected Plan File as the source meta plan, checks it against the bundled `plan_for_meta_plan.md`, and writes a sibling `*.reviewed.md` file without modifying the original.
- **Resume Selected**: resumes the selected failed, stale, or cancelled deliberation session from its last saved round state.
- **Cancel Selected**: stops the selected running session.
- **Check Environment**: verifies that all required CLIs are installed and accessible.

### Resume Behavior

Resume is a session action, not a form action.

- Resume uses the selected session's saved `session_config.json`.
- Resume ignores the current Configure form values.
- Resume keeps the same `session_id` and appends a new pipeline/log file for the resumed attempt.
- Resume is currently limited to `document` and `code` deliberation sessions with enough saved state to continue.

After an app restart, set the same workspace directory, select the failed session from the session rail, and click `Resume`.

### Advanced Settings

Click "Advanced and environment" to expand additional controls:

| Setting | Default | Range | Purpose |
|---------|---------|-------|---------|
| **Prompt Directory** | `<script_dir>/prompts` | any path | Directory containing custom prompt templates |
| **Max Iterations** | 10 | 1-100 | Maximum QC fix loop iterations before stopping |
| **Max Plan QC Iterations** | 5 | 1-20 | Maximum Phase 0 plan review iterations |
| **Claude QC Iterations** | 0 | 0-20 | Use Claude (not Codex) for first N QC iterations, then switch to Codex. Set to 0 for Codex-only review. |
| **History Iterations** | 2 | 1-10 | Number of past iterations kept in context for anti-oscillation. Lower values reduce prompt size (~30% savings). |
| **Max Deliberation Rounds** | 4 | 2-10 | Maximum deliberation rounds before stopping (only applies when Deliberation Mode is enabled) |

## Active Session

This panel shows the current session state:

- session id
- status
- current phase
- current action
- QC iteration counters
- plan QC counters
- deliberation round counters
- last message or last error

Use this panel to confirm whether the pipeline is still progressing or stopped on a specific stage.

## Session Files

This panel lists the files generated for the selected session.

Examples:

- QC reports (`qc_report_iter*.md`, `doc_qc_report_iter*.md`)
- plan QC reports (`plan_qc_report_iter*.md`)
- deliberation artifacts (`roundN_claude_thoughts.md`, `roundN_codex_evaluation.md`)
- deliberation summaries (`deliberation_summary.md`)
- continuation cycle plans (`CONTINUATION_CYCLE_*.md`)
- iteration history (`_iteration_history.md`)
- session logs (`qc_log_*.txt`)

Selecting a file loads it into the viewer.

## Event Feed

The event feed shows the structured events written by the PowerShell pipeline and Electron wrapper.

Use it to track:

- startup
- dependency failures
- QC iteration changes
- fix steps
- deliberation round progress
- completion or failure

This is more reliable than interpreting colored terminal output.

## Artifact Preview

The viewer renders the currently selected artifact or help topic.

- Markdown files render as formatted content.
- JSON files render as formatted JSON.
- Text logs render as text blocks.

`Open Externally` opens the current viewer item outside the app.

## Help Tabs

The viewer also hosts in-app help.

- `Quick Start`: first-use setup, flags, examples, and the two-stage workflow
- `Desktop Guide`: screen-by-screen guide to the app (this page)
- `Pipeline & Modes`: deep technical reference for the engine, all parameters, and advanced workflows

When you select a session file, the viewer leaves help mode and returns to artifact mode automatically.

## Good Desktop Workflow

1. Set the workspace to your target project directory and check the environment.
2. Start a run from the command deck.
3. Watch `Run Status` and `Recent Events`.
4. Inspect generated reports in `Session Files`.
5. If a deliberation run fails or is interrupted, select that session and use `Resume`.
6. Use continuation cycle plans for follow-on implementation runs when the workflow produces them.

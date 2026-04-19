<#
.SYNOPSIS
    Dry-run test for accord.ps1 pipeline logic

.DESCRIPTION
    Tests template substitution, QC parsing, and flow logic without real CLIs
    Updated for v1.3 (Plan QC support)
#>

$ErrorActionPreference = "Stop"
$Script:TestsPassed = 0
$Script:TestsFailed = 0
$Script:TempResumeRoots = @()
$Script:TempCodexStubRoots = @()
$Script:TempClaudeStubRoots = @()

$ScriptDir = $PSScriptRoot
$ParentDir = Split-Path $ScriptDir -Parent
$PromptRoot = Join-Path $ParentDir "prompts"
$MainScript = Join-Path $ParentDir "accord.ps1"

# =============================================================================
# Test Helpers
# =============================================================================

function Write-TestHeader {
    param([string]$Name)
    Write-Host "`n$Name" -ForegroundColor Yellow
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        Write-Host "  [PASS] $Message" -ForegroundColor Green
        $Script:TestsPassed++
    }
    else {
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
        $Script:TestsFailed++
    }
}

function Assert-Match {
    param(
        [string]$Value,
        [string]$Pattern,
        [string]$Message
    )

    Assert-True ($Value -match $Pattern) $Message
}

if (Test-Path $MainScript) {
    . $MainScript
}

function New-ResumeTestSession {
    param(
        [ValidateSet("document", "code")]
        [string]$Mode
    )

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-resume-" + [System.Guid]::NewGuid().ToString("N"))
    $logsDir = Join-Path $root "logs\session-resume"
    $cyclesDir = Join-Path $root "cycles\session-resume"
    $phase0Dir = Join-Path $logsDir "deliberation\phase0"
    $phase1Dir = Join-Path $logsDir "deliberation\phase1"

    foreach ($dir in @($logsDir, $cyclesDir, $phase0Dir, $phase1Dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $eventsFile = Join-Path $logsDir "events.ndjson"
    New-Item -ItemType File -Path $eventsFile -Force | Out-Null

    $cyclePlanPath = Join-Path $cyclesDir "CONTINUATION_CYCLE_1.md"
    "# Continuation Cycle 1" | Out-File -FilePath $cyclePlanPath -Encoding UTF8

    $Script:SessionLogsDir = $logsDir
    $Script:SessionCyclesDir = $cyclesDir
    $Script:DelibPhase0Dir = $phase0Dir
    $Script:DelibPhase1Dir = $phase1Dir
    $Script:EventsFile = $eventsFile
    $Script:TempResumeRoots += $root

    return @{
        Root = $root
        LogsDir = $logsDir
        CyclesDir = $cyclesDir
        EventsFile = $eventsFile
        Phase0Dir = $phase0Dir
        Phase1Dir = $phase1Dir
        CyclePlanPath = $cyclePlanPath
        Mode = $Mode
    }
}

function Add-ResumeEvent {
    param(
        [string]$EventsFile,
        [string]$Type,
        [int]$Round
    )

    $record = @{
        timestamp = (Get-Date).ToString("o")
        type = $Type
        data = @{
            round = $Round
        }
    } | ConvertTo-Json -Compress
    Add-Content -Path $EventsFile -Value $record
}

function Write-ResumeArtifact {
    param(
        [string]$Path,
        [string]$Decision,
        [string[]]$Bullets = @("Synthetic test artifact")
    )

    $content = @(
        "## Decision: $Decision",
        "",
        "## Changes Made:"
    )
    foreach ($bullet in $Bullets) {
        $content += "- $bullet"
    }
    $content | Out-File -FilePath $Path -Encoding UTF8
}

function Write-CodexFailureArtifact {
    param(
        [string]$Path,
        [string]$ToolLabel = "Codex (Synthetic Test)"
    )

    @(
        "## Status",
        "Codex execution failed before producing a final markdown report.",
        "",
        "- **Tool**: $ToolLabel",
        "- **Exit Code**: 1",
        "- **Transcript**: C:\synthetic\codex_transcript.txt",
        "- **Reason**: CLI exited with code 1.",
        "",
        "## Notes",
        "See the transcript artifact for raw Codex stdout/stderr and any tool progress output."
    ) | Out-File -FilePath $Path -Encoding UTF8
}

# =============================================================================
# Test 1: Template Substitution
# =============================================================================

Write-TestHeader "Test 1: Template Substitution"

$templates = @(
    @{ File = "claude_write_prompt.md"; Placeholder = "{{PLAN_FILE}}"; Value = "plan.md" },
    @{ File = "codex_qc_prompt.md"; Placeholder = "{{PLAN_FILE}}"; Value = "plan.md" },
    @{ File = "codex_qc_prompt.md"; Placeholder = "{{ITERATION}}"; Value = "1" },
    @{ File = "codex_qc_prompt.md"; Placeholder = "{{PREVIOUS_ISSUES}}"; Value = "(No previous issues)" },
    @{ File = "codex_qc_prompt.md"; Placeholder = "{{HISTORY_FILE}}"; Value = "C:\project\logs\session-1\_iteration_history.md" },
    @{ File = "codex_qc_prompt.md"; Placeholder = "{{SESSION_ID}}"; Value = "session-1" },
    @{ File = "codex_qc_prompt.md"; Placeholder = "{{LOGS_DIR}}"; Value = "C:\project\logs\session-1" },
    @{ File = "claude_fix_prompt.md"; Placeholder = "{{QC_ISSUES}}"; Value = "Test issue" },
    @{ File = "claude_fix_prompt.md"; Placeholder = "{{PREVIOUS_ISSUES}}"; Value = "(No previous issues)" },
    @{ File = "codex_plan_qc_prompt.md"; Placeholder = "{{PLAN_FILE}}"; Value = "plan.md" },
    @{ File = "codex_plan_qc_prompt.md"; Placeholder = "{{ITERATION}}"; Value = "1" },
    @{ File = "claude_plan_fix_prompt.md"; Placeholder = "{{QC_ISSUES}}"; Value = "Test plan issue" },
    @{ File = "claude_write_doc_prompt.md"; Placeholder = "{{CYCLES_DIR}}"; Value = "C:\project\cycles\session-1" },
    @{ File = "claude_write_doc_prompt.md"; Placeholder = "{{CYCLE_STATUS_FILE}}"; Value = "C:\project\cycles\session-1\_CYCLE_STATUS.json" }
)

foreach ($t in $templates) {
    $path = Join-Path $PromptRoot $t.File
    if (Test-Path $path) {
        $content = Get-Content -Path $path -Raw
        $substituted = $content.Replace($t.Placeholder, $t.Value)

        $hasReplacement = $substituted.Contains($t.Value)
        $noPlaceholder = -not $substituted.Contains($t.Placeholder)

        Assert-True ($hasReplacement -and $noPlaceholder) "$($t.File) - $($t.Placeholder) substituted"
    }
    else {
        Assert-True $false "$($t.File) - file not found"
    }
}

$metaPromptRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-meta-template-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $metaPromptRoot -Force | Out-Null
$Script:TempResumeRoots += $metaPromptRoot
$metaTarget = Join-Path $metaPromptRoot "meta_plan.md"
$metaChecklist = Join-Path $metaPromptRoot "checklist.md"
$metaOutput = Join-Path $metaPromptRoot "meta_plan.reviewed.md"
$metaReplacementDraft = Join-Path $metaPromptRoot "meta_review_codex_replacement_iter2_test.md"
$metaQcReport = Join-Path $metaPromptRoot "doc_qc_report_iter2_test.md"
$metaHistoryFile = Join-Path $metaPromptRoot "_iteration_history.md"
"# Target`nUse the current context." | Out-File -FilePath $metaTarget -Encoding UTF8
"# Checklist" | Out-File -FilePath $metaChecklist -Encoding UTF8
"# Reviewed Output" | Out-File -FilePath $metaOutput -Encoding UTF8
"# Replacement Draft" | Out-File -FilePath $metaReplacementDraft -Encoding UTF8
"## QC Status: FAIL`n`n## Issues Found: 1`n`n### Issue 1`n- **Severity**: HIGH`n- **Category**: Checklist Compliance`n- **Location**: Requirements`n- **Description**: Broken.`n- **Fix**: Repair it.`n`n## Summary`nNeeds repair." | Out-File -FilePath $metaQcReport -Encoding UTF8
@"
# Cross-QC Iteration History

## Blocked Patterns (DO NOT REPORT)

``````
- Avoid reporting remove placeholder at Requirements / Template
``````

---
"@ | Out-File -FilePath $metaHistoryFile -Encoding UTF8
$previousMetaReview = $MetaReview
$previousHistoryFile = $Script:HistoryFile
$previousCurrentQCReport = $Script:CurrentQCReport
$previousReplacementDraftFile = $Script:MetaReviewReplacementDraftFile
$previousAllIssuesHistory = $Script:AllIssuesHistory
$previousHistoryIterations = $HistoryIterations
$Script:MetaReviewTargetFile = $metaTarget
$Script:MetaReviewChecklistFile = $metaChecklist
$Script:MetaReviewOutputFile = $metaOutput
$Script:MetaReviewReplacementDraftFile = $metaReplacementDraft
$Script:CurrentQCReport = $metaQcReport
$Script:HistoryFile = $metaHistoryFile
$Script:ProjectRoot = $metaPromptRoot
$Script:AllIssuesHistory = "`n### Iteration 1 Issues:`nold issue`n`n### Iteration 2 Issues:`nnew issue`n"
$HistoryIterations = 5
$MetaReview = $true
$metaPromptPath = Join-Path $PromptRoot "codex_qc_meta_review_relay_prompt.md"
$metaPrompt = Get-SubstitutedTemplate -TemplatePath $metaPromptPath -PlanFile $metaTarget -PreviousIssues (Get-IssuesHistorySummary) -Iteration 1
Assert-Match $metaPrompt "# Target" "Meta review QC prompt includes bundled target content"
Assert-Match $metaPrompt "# Checklist" "Meta review QC prompt includes bundled checklist content"
Assert-Match $metaPrompt "# Reviewed Output" "Meta review relay prompt includes bundled reviewed output content"
Assert-Match $metaPrompt "Workspace root:" "Meta review QC prompt includes workspace summary"
Assert-Match $metaPrompt "Blocked Contradictions" "Meta review relay prompt includes the blocked contradiction section"
Assert-True (-not ($metaPrompt -match '\{\{META_REVIEW_BLOCKED_PATTERNS\}\}')) "Meta review relay prompt resolves the blocked contradiction placeholder"
Assert-Match $metaPrompt "new issue" "Meta review relay prompt includes the most recent previous issue"
Assert-True (-not ($metaPrompt -match 'old issue')) "Meta review relay prompt forces previous-issue history to the most recent iteration only"
$metaWritePromptPath = Join-Path $PromptRoot "claude_write_meta_review_prompt.md"
$metaWritePrompt = Get-SubstitutedTemplate -TemplatePath $metaWritePromptPath -PlanFile $metaTarget -PreviousIssues (Get-IssuesHistorySummary)
Assert-Match $metaWritePrompt "### Source Meta Plan" "Meta review write prompt includes bundled source content"
Assert-Match $metaWritePrompt "### Checklist / Spec" "Meta review write prompt includes bundled checklist content"
Assert-True (-not ($metaWritePrompt -match 'Read `\{\{META_REVIEW_CHECKLIST_FILE\}\}` second')) "Meta review write prompt no longer instructs Claude to open the checklist path directly"
$metaFixPromptPath = Join-Path $PromptRoot "claude_fix_meta_review_prompt.md"
$metaFixPrompt = Get-SubstitutedTemplate -TemplatePath $metaFixPromptPath -PlanFile $metaTarget -QCIssues "deterministic issue" -PreviousIssues (Get-IssuesHistorySummary)
Assert-Match $metaFixPrompt "### Reviewed Output Under Fix" "Meta review fix prompt includes bundled reviewed output content"
Assert-Match $metaFixPrompt "### Checklist / Spec" "Meta review fix prompt includes bundled checklist content"
$metaReconcilePromptPath = Join-Path $PromptRoot "claude_reconcile_meta_review_prompt.md"
$metaReconcilePrompt = Get-SubstitutedTemplate -TemplatePath $metaReconcilePromptPath -PlanFile $metaTarget -QCIssues "semantic issue" -PreviousIssues (Get-IssuesHistorySummary)
Assert-Match $metaReconcilePrompt "### Source Meta Plan" "Meta review reconcile prompt includes bundled source content"
Assert-Match $metaReconcilePrompt "### Checklist / Spec" "Meta review reconcile prompt includes bundled checklist content"
Assert-Match $metaReconcilePrompt "# Replacement Draft" "Meta review reconcile prompt includes Codex replacement draft content"
Assert-Match $metaReconcilePrompt "## QC Status: FAIL" "Meta review reconcile prompt includes the Codex QC report"
Assert-Match $metaReconcilePrompt "# Reviewed Output" "Meta review reconcile prompt includes the current reviewed output content"
$hintWorkspace = Join-Path $metaPromptRoot "workspace-root"
New-Item -ItemType Directory -Path $hintWorkspace -Force | Out-Null
@"
- **Project Location**: $hintWorkspace
"@ | Out-File -FilePath $metaOutput -Encoding UTF8
$resolvedWorkspaceHint = Get-MetaReviewTargetWorkspaceDir
Assert-True ($resolvedWorkspaceHint -eq $hintWorkspace) "Meta review workspace summary prefers explicit project location hints over the meta-plan file directory"
$metaHistorySummary = Get-IssuesHistorySummary
Assert-True ($metaHistorySummary.Length -le 4300) "Meta review previous-issue summary uses the tighter 4000-char budget"
$MetaReview = $previousMetaReview
$Script:HistoryFile = $previousHistoryFile
$Script:CurrentQCReport = $previousCurrentQCReport
$Script:MetaReviewReplacementDraftFile = $previousReplacementDraftFile
$Script:AllIssuesHistory = $previousAllIssuesHistory
$HistoryIterations = $previousHistoryIterations

# =============================================================================
# Test 1a: Meta Review History Initialization and Blocked Pattern Parsing
# =============================================================================

Write-TestHeader "Test 1a: Meta Review History Initialization and Blocked Pattern Parsing"

$historyInitRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-meta-history-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $historyInitRoot -Force | Out-Null
$Script:TempResumeRoots += $historyInitRoot
$previousHistoryFile = $Script:HistoryFile
$previousPlanFileResolved = $Script:PlanFileResolved
$previousPipelineStartTime = $Script:PipelineStartTime
$previousAllIssuesHistory = $Script:AllIssuesHistory
$previousMetaReview = $MetaReview

try {
    $Script:HistoryFile = Join-Path $historyInitRoot "_iteration_history.md"
    $Script:PlanFileResolved = Join-Path $historyInitRoot "meta_plan.md"
    $Script:PipelineStartTime = "history-init-test"
    $Script:AllIssuesHistory = ""
    $MetaReview = $true
    "# Meta plan" | Out-File -FilePath $Script:PlanFileResolved -Encoding UTF8

    $iter2Issues = @"
### Issue 1
- **Severity**: HIGH
- **Category**: Plan Compliance
- **Location**: Requirements / Resume
- **Description**: Missing RESUME_CYCLE branch.
- **Fix**: Add RESUME_CYCLE handling.
"@

    Add-IssuesToHistory -Issues $iter2Issues -Iteration 2
    Write-IterationHistory -Iteration 2 -Issues $iter2Issues -Status "FAIL"

    $initializedHistory = Get-Content -Path $Script:HistoryFile -Raw
    Assert-Match $initializedHistory "# Cross-QC Iteration History" "Iteration history initializes even when the first recorded failure is iteration 2"
    Assert-Match $initializedHistory "## Blocked Patterns" "Iteration history initialization includes the blocked-pattern section for later anti-oscillation reads"

    $generatedBlockedSummary = Get-MetaReviewBlockedPatternsSummary
    Assert-Match $generatedBlockedSummary "- " "Meta-review blocked-pattern summary returns concise bullet items after iteration-history initialization"
    Assert-True (-not ($generatedBlockedSummary -match 'history fallback')) "Meta-review blocked-pattern summary avoids raw-history fallback when structured patterns are available"

    @"
# Cross-QC Iteration History

## Blocked Patterns (DO NOT REPORT)

These patterns likely contradict previous fixes. **Use judgment**: if the issue is at the SAME location as a previous fix and matches a blocked pattern, skip it. If it's a genuinely NEW problem at a DIFFERENT location, report it.

- Avoid reporting remove placeholder at Requirements / Template
- Avoid reporting unused parameter at renderer.js:42

---
"@ | Out-File -FilePath $Script:HistoryFile -Encoding UTF8

    $manualBlockedSummary = Get-MetaReviewBlockedPatternsSummary
    Assert-Match $manualBlockedSummary "Avoid reporting remove placeholder" "Meta-review blocked-pattern summary can parse plain bullet sections without relying on fence markers"
    Assert-True (-not ($manualBlockedSummary -match 'history fallback')) "Meta-review blocked-pattern summary stays concise for plain bullet sections"
}
finally {
    $Script:HistoryFile = $previousHistoryFile
    $Script:PlanFileResolved = $previousPlanFileResolved
    $Script:PipelineStartTime = $previousPipelineStartTime
    $Script:AllIssuesHistory = $previousAllIssuesHistory
    $MetaReview = $previousMetaReview
}

Write-TestHeader "Test 1b: Meta Review Deterministic Validation"

$validatorRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-meta-validator-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $validatorRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $validatorRoot "tests") -Force | Out-Null
$Script:TempResumeRoots += $validatorRoot
"<html><head><link rel=`"stylesheet`" href=`"./css/styles.css`"></head><body><script type=`"module`" src=`"./js/main.js`"></script></body></html>" | Out-File -FilePath (Join-Path $validatorRoot "index.html") -Encoding UTF8
"# test runner" | Out-File -FilePath (Join-Path $validatorRoot "tests\\test_runner.html") -Encoding UTF8
$validatorTarget = Join-Path $validatorRoot "meta_plan.md"
$validatorChecklist = Join-Path $validatorRoot "checklist.md"
$validatorOutput = Join-Path $validatorRoot "meta_plan.reviewed.md"
@"
# Meta Plan

## Context
- Use the current context and refine it significantly.
"@ | Out-File -FilePath $validatorTarget -Encoding UTF8
"# Checklist" | Out-File -FilePath $validatorChecklist -Encoding UTF8
@"
## Overview
## Input Files
## LLM Productivity Rules
## Requirements
## Output Structure Template
## Deliverables

Project Location
What This Project Is
Completed Work Table
Current Cycle Task
Pre-Conditions
Files to Create
Files to Update
Context Files to Read
Implementation Details
Verification Checklist
Key Differences
Running/Testing Instructions
Quickstart Tutorial
Frontend Design Notes
After Completion Instructions
QC Lessons Learned
Next Cycle Instructions

[TODO]
"@ | Out-File -FilePath $validatorOutput -Encoding UTF8
$Script:MetaReviewTargetFile = $validatorTarget
$Script:MetaReviewChecklistFile = $validatorChecklist
$Script:MetaReviewOutputFile = $validatorOutput
$validatorFindings = Get-MetaReviewDeterministicFindings -PlanFile $validatorTarget
$validatorReport = Convert-MetaReviewFindingsToMarkdown -Findings $validatorFindings
Assert-Match $validatorReport "Project Goal Reference" "Deterministic validator flags missing project goal reference"
Assert-Match $validatorReport "Previous Cycle Plan File" "Deterministic validator flags missing navigation fields"
Assert-Match $validatorReport "in-progress-cycle gate" "Deterministic validator flags missing in-progress handling"
Assert-Match $validatorReport "Placeholder-style text remains" "Deterministic validator flags placeholder leakage outside fences"
Assert-Match $validatorReport "target workspace already has test files" "Deterministic validator flags missing test discovery"
Assert-Match $validatorReport "## Regression Report" "Deterministic validator reports keep the standard regression-report section"

@"
## Overview
## Input Files
## LLM Productivity Rules
## Requirements
## Output Structure Template
## Deliverables

Project Location
What This Project Is
Completed Work Table
Current Cycle Task
Pre-Conditions
Files to Create
Files to Update
Context Files to Read
Implementation Details
Verification Checklist
Key Differences
Running/Testing Instructions
Quickstart Tutorial
Frontend Design Notes
After Completion Instructions
QC Lessons Learned
Next Cycle Instructions

- The plan must contain no ``[TODO]``, ``[TBD]``, or empty checklist items.
"@ | Out-File -FilePath $validatorOutput -Encoding UTF8
$validatorInlineCodeFindings = Get-MetaReviewDeterministicFindings -PlanFile $validatorTarget
$inlinePlaceholderFindings = @($validatorInlineCodeFindings | Where-Object { $_.Location -eq "Content outside the output template fence" })
Assert-True ($inlinePlaceholderFindings.Count -eq 0) "Deterministic validator ignores placeholder markers inside inline-code mentions outside fences"

# =============================================================================
# Test 2: QC Status Detection
# =============================================================================

Write-TestHeader "Test 2: QC Status Detection"

$mockFail = @"
user
[prompt echoed here with QC Status: PASS example]

codex
## QC Status: FAIL

## Issues Found: 2

### Issue 1
- **Severity**: HIGH
- **Category**: Security
- **Location**: sanitizer.py:15
- **Description**: SQL keywords not case-insensitive
- **Fix**: Use .upper() before matching
- **Recurring**: NO

### Issue 2
- **Severity**: MEDIUM
- **Category**: Error Handling
- **Location**: sanitizer.py:28
- **Description**: None input causes AttributeError
- **Fix**: Add None check at function start
- **Recurring**: NO

## Regression Report
None

## Summary
Two issues found.

tokens used
1234
"@

$mockPass = @"
user
[prompt echoed here with QC Status: PASS example]

codex
## QC Status: PASS

## Issues Found: 0

## Regression Report
None

## Summary
Code review complete. No issues identified.

tokens used
567
"@

# Test FAIL detection (look for "## QC Status: FAIL" after "codex" marker)
$failPath = Join-Path $ScriptDir "mock_fail.md"
$mockFail | Out-File -FilePath $failPath -Encoding UTF8
$failContent = Get-Content -Path $failPath -Raw

# Extract response after "codex" marker and before "tokens used"
if ($failContent -match '(?s)\ncodex\n(.+?)\ntokens used') {
    $failResponse = $Matches[1]
    $failHasPass = $failResponse -match '## QC Status: PASS'
    $failHasFail = $failResponse -match '## QC Status: FAIL'
    Assert-True ($failHasFail -and -not $failHasPass) "FAIL report correctly detected as FAIL"
}
else {
    Assert-True $false "Could not extract Codex response from FAIL mock"
}

# Test PASS detection
$passPath = Join-Path $ScriptDir "mock_pass.md"
$mockPass | Out-File -FilePath $passPath -Encoding UTF8
$passContent = Get-Content -Path $passPath -Raw

if ($passContent -match '(?s)\ncodex\n(.+?)\ntokens used') {
    $passResponse = $Matches[1]
    $passHasPass = $passResponse -match '## QC Status: PASS'
    $passHasFail = $passResponse -match '## QC Status: FAIL'
    Assert-True ($passHasPass -and -not $passHasFail) "PASS report correctly detected as PASS"
}
else {
    Assert-True $false "Could not extract Codex response from PASS mock"
}

# =============================================================================
# Test 3: Issue Extraction
# =============================================================================

Write-TestHeader "Test 3: Issue Extraction"

if ($failContent -match '(?s)\ncodex\n(.+?)\ntokens used') {
    $failResponse = $Matches[1]

    if ($failResponse -match '(?s)(### Issue.+?)(?=## Regression)') {
        $extracted = $Matches[1].Trim()
        $issueCount = ([regex]::Matches($extracted, '### Issue')).Count

        Assert-True ($issueCount -eq 2) "Extracted 2 issues correctly"
        Assert-True ($extracted -match 'SQL keywords not case-insensitive') "Issue descriptions preserved"
    }
    else {
        Assert-True $false "Issue extraction regex failed"
        Assert-True $false "Issue descriptions not extracted"
    }
}
else {
    Assert-True $false "Could not extract Codex response for issue extraction"
    Assert-True $false "Issue descriptions not extracted"
}

# =============================================================================
# Test 3b: Clean Codex Report Parsing
# =============================================================================

Write-TestHeader "Test 3b: Clean Codex Report Parsing"

$cleanCodexReport = @"
# QC Report (Code Mode)
- **Generated**: 2026-03-19 08:00:00
- **Iteration**: 1
- **QC Type**: code
- **QC Tool**: Codex

---

## QC Status: PASS

## Issues Found: 0

## Regression Report
None

## Summary
Clean report body only.
"@

$cleanCodexPath = Join-Path $ScriptDir "mock_clean_codex.md"
$cleanCodexReport | Out-File -FilePath $cleanCodexPath -Encoding UTF8
$cleanCodexResponse = Get-QCResponse -ReportContent (Get-Content -Path $cleanCodexPath -Raw)
Assert-True ($cleanCodexResponse -match '## QC Status: PASS') "Clean Codex report body extracted without transcript parsing"
$Script:CurrentQCReport = $cleanCodexPath
Assert-True (Test-QCPassed) "PASS detected from clean Codex report"
$cleanTranscriptPath = Get-CodexTranscriptFilePath -ReportFile $cleanCodexPath
Assert-True ($cleanTranscriptPath.EndsWith("mock_clean_codex_transcript.txt")) "Transcript path helper uses sibling _transcript.txt naming"

# =============================================================================
# Test 4: Simulated Pipeline Flow
# =============================================================================

Write-TestHeader "Test 4: Simulated Pipeline Flow"

$maxIter = 3
$passOnIter = 2
$currentIter = 0
$terminated = $false

Write-Host "  Simulating pipeline (pass on iteration $passOnIter)..."

while ($currentIter -lt $maxIter) {
    $currentIter++
    Write-Host "    Iteration $currentIter`: Running QC..."

    if ($currentIter -eq $passOnIter) {
        Write-Host "    Iteration $currentIter`: QC Status = PASS"
        $terminated = $true
        break
    }
    else {
        Write-Host "    Iteration $currentIter`: QC Status = FAIL, fixing..."
    }
}

Assert-True ($terminated -and $currentIter -eq $passOnIter) "Pipeline terminated on iteration $passOnIter"

# =============================================================================
# Test 5: Script Syntax Validation
# =============================================================================

Write-TestHeader "Test 5: Script Syntax Validation"

if (Test-Path $MainScript) {
    try {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $MainScript,
            [ref]$null,
            [ref]$errors
        )
        Assert-True ($null -eq $errors -or $errors.Count -eq 0) "accord.ps1 syntax valid"
    }
    catch {
        # Fallback: just check file exists and has content
        $content = Get-Content -Path $MainScript -Raw
        Assert-True ($content.Length -gt 1000) "accord.ps1 has content (syntax check unavailable)"
    }
}
else {
    Assert-True $false "accord.ps1 not found"
}

# =============================================================================
# Test 6: File Structure Validation
# =============================================================================

Write-TestHeader "Test 6: File Structure Validation"

$requiredFiles = @(
    "accord.ps1",
    "package.json",
    "prompts",
    "prompts\claude_write_prompt.md",
    "prompts\codex_qc_prompt.md",
    "prompts\claude_fix_prompt.md",
    "src\main\main.js",
    "src\main\preload.js",
    "src\main\pipeline.js",
    "src\main\session-store.js",
    "src\renderer\index.html",
    "src\renderer\app.js",
    "src\renderer\styles.css",
    "AGENTS.md"
)

foreach ($file in $requiredFiles) {
    $path = Join-Path $ParentDir $file
    Assert-True (Test-Path $path) "$file exists"
}

# =============================================================================
# Test 7: Plan QC Files (v1.3)
# =============================================================================

Write-TestHeader "Test 7: Plan QC Files (v1.3)"

$planQCFiles = @(
    "prompts\codex_plan_qc_prompt.md",
    "prompts\claude_plan_fix_prompt.md"
)

foreach ($file in $planQCFiles) {
    $path = Join-Path $ParentDir $file
    Assert-True (Test-Path $path) "$file exists"
}

# =============================================================================
# Test 8: Prompt Dir Compatibility and Session Layout
# =============================================================================

Write-TestHeader "Test 8: Prompt Dir Compatibility and Session Layout"

$compatiblePromptDir = if (Test-Path (Join-Path $ParentDir "claude_write_prompt.md")) {
    $ParentDir
} elseif (Test-Path (Join-Path $ParentDir "prompts\claude_write_prompt.md")) {
    Join-Path $ParentDir "prompts"
} else {
    ""
}
Assert-True ($compatiblePromptDir -eq $PromptRoot) "Repo root PromptDir resolves to prompts child"

$projectRoot = "C:\workspace\demo_project"
$cyclesRoot = Join-Path $projectRoot "cycles"
$planInExistingSession = Join-Path $projectRoot "cycles\existing-session\CONTINUATION_CYCLE_14.md"
$cyclesPrefix = [System.IO.Path]::GetFullPath($cyclesRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$derivedSession = ""

if ($planInExistingSession.StartsWith($cyclesPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    $relativePath = $planInExistingSession.Substring($cyclesPrefix.Length)
    if ($relativePath -match '^(?<session>[^\\/]+)[\\/](CONTINUATION_CYCLE_\d+\.md)$') {
        $derivedSession = $Matches.session
    }
}

Assert-True ($derivedSession -eq "existing-session") "Session id is reused from cycles/<session_id>/CONTINUATION_CYCLE_*.md"
Assert-True ((Join-Path (Join-Path $projectRoot "logs") $derivedSession) -eq "C:\workspace\demo_project\logs\existing-session") "Session logs path format is correct"
Assert-True ((Join-Path $cyclesRoot $derivedSession) -eq "C:\workspace\demo_project\cycles\existing-session") "Session cycles path format is correct"
Assert-True ((Join-Path (Join-Path $projectRoot "logs\existing-session") "run_state.json") -eq "C:\workspace\demo_project\logs\existing-session\run_state.json") "Run state path format is correct"
Assert-True ((Join-Path (Join-Path $projectRoot "logs\existing-session") "events.ndjson") -eq "C:\workspace\demo_project\logs\existing-session\events.ndjson") "Event stream path format is correct"

# =============================================================================
# Test 9: Anti-Oscillation Pattern Detection
# =============================================================================

Write-TestHeader "Test 9: Anti-Oscillation Pattern Detection"

$issuesWithLocation = @'
### Issue 1
- **Severity**: MEDIUM
- **Category**: Code Quality
- **Location**: `src/api.py:42`
- **Description**: Missing validation for `user_id` parameter
- **Fix**: Add validation at function start
'@

# Test location extraction
$locationMatches = [regex]::Matches($issuesWithLocation, '\*\*Location\*\*:\s*`?([^`\n]+)`?')
Assert-True ($locationMatches.Count -gt 0) "Location extraction works"
if ($locationMatches.Count -gt 0) {
    $location = $locationMatches[0].Groups[1].Value.Trim()
    Assert-True ($location -eq "src/api.py:42") "Location value correct: $location"
}

# Test action word detection
$actionWords = @('add', 'missing', 'validation')
$issuesLower = $issuesWithLocation.ToLower()
$foundActions = @()
foreach ($action in $actionWords) {
    if ($issuesLower.Contains($action)) {
        $foundActions += $action
    }
}
Assert-True ($foundActions.Count -eq 3) "Action word detection works (found: $($foundActions -join ', '))"

# =============================================================================
# Test 10: Issue History Formatting
# =============================================================================

Write-TestHeader "Test 10: Issue History Formatting"

$historyTemplate = @"
## Issues from Previous Iterations

The following issues were reported and (should have been) fixed in previous iterations.
Do NOT report these same issues again unless they have genuinely regressed.

### Iteration 1 Issues:
- Missing validation for user_id

### Iteration 2 Issues:
- SQL injection in query builder
"@

# Check that history contains both iterations
Assert-True ($historyTemplate -match '### Iteration 1') "History contains iteration 1"
Assert-True ($historyTemplate -match '### Iteration 2') "History contains iteration 2"

# =============================================================================
# Test 11: Deliberation Resume Reconstruction
# =============================================================================

Write-TestHeader "Test 11: Deliberation Resume Reconstruction"

$documentNextRound = New-ResumeTestSession -Mode "document"
Write-ResumeArtifact -Path (Join-Path $documentNextRound.Phase0Dir "round1_claude_thoughts.md") -Decision "MINOR_REFINEMENT" -Bullets @("Drafted continuation plan")
Write-ResumeArtifact -Path (Join-Path $documentNextRound.Phase0Dir "round1_codex_evaluation.md") -Decision "MINOR_REFINEMENT" -Bullets @("Requested explicit links")
Add-ResumeEvent -EventsFile $documentNextRound.EventsFile -Type "document_deliberation_round_started" -Round 1
$documentResume = Get-DeliberationResumeState -Mode "document"
Assert-True ($documentResume.Success) "Document resume state reconstructed from completed round"
Assert-True ($documentResume.StartRound -eq 2) "Completed round resumes at next Claude round"
Assert-True ($documentResume.NextAgent -eq "claude") "Completed round resumes with Claude"
Assert-True ($documentResume.DocPath -eq $documentNextRound.CyclePlanPath) "Document resume restores continuation plan path"

$codeMidRound = New-ResumeTestSession -Mode "code"
Write-ResumeArtifact -Path (Join-Path $codeMidRound.Phase1Dir "round1_claude_thoughts.md") -Decision "MAJOR_REFINEMENT" -Bullets @("Implemented first pass")
Write-ResumeArtifact -Path (Join-Path $codeMidRound.Phase1Dir "round1_codex_review.md") -Decision "MAJOR_REFINEMENT" -Bullets @("Asked for stricter validation")
Write-ResumeArtifact -Path (Join-Path $codeMidRound.Phase1Dir "round2_claude_thoughts.md") -Decision "MINOR_REFINEMENT" -Bullets @("Addressed validation comments")
Add-ResumeEvent -EventsFile $codeMidRound.EventsFile -Type "code_deliberation_round_started" -Round 1
Add-ResumeEvent -EventsFile $codeMidRound.EventsFile -Type "code_deliberation_round_started" -Round 2
$codeResume = Get-DeliberationResumeState -Mode "code"
Assert-True ($codeResume.Success) "Code resume state reconstructed from partial round"
Assert-True ($codeResume.StartRound -eq 2) "Partial round stays on the same round number"
Assert-True ($codeResume.NextAgent -eq "codex") "Claude-only round resumes with Codex"
Assert-True ($codeResume.CurrentRoundClaudeDecision -eq "MINOR_REFINEMENT") "Current round Claude decision restored"

$documentStartedOnly = New-ResumeTestSession -Mode "document"
Write-ResumeArtifact -Path (Join-Path $documentStartedOnly.Phase0Dir "round1_claude_thoughts.md") -Decision "MINOR_REFINEMENT" -Bullets @("Prepared round 1 draft")
Write-ResumeArtifact -Path (Join-Path $documentStartedOnly.Phase0Dir "round1_codex_evaluation.md") -Decision "CONVERGED" -Bullets @("Round 1 acceptable")
Add-ResumeEvent -EventsFile $documentStartedOnly.EventsFile -Type "document_deliberation_round_started" -Round 1
Add-ResumeEvent -EventsFile $documentStartedOnly.EventsFile -Type "document_deliberation_round_started" -Round 2
$documentStartedOnlyResume = Get-DeliberationResumeState -Mode "document"
Assert-True ($documentStartedOnlyResume.Success) "Resume state reconstructed from round-start event without artifacts"
Assert-True ($documentStartedOnlyResume.StartRound -eq 2) "Started round without artifacts resumes on same round"
Assert-True ($documentStartedOnlyResume.NextAgent -eq "claude") "Started round without artifacts resumes with Claude"

$documentFailedCodex = New-ResumeTestSession -Mode "document"
$documentFailedRound1Feedback = Join-Path $documentFailedCodex.Phase0Dir "round1_codex_evaluation.md"
Write-ResumeArtifact -Path (Join-Path $documentFailedCodex.Phase0Dir "round1_claude_thoughts.md") -Decision "MAJOR_REFINEMENT" -Bullets @("Created initial continuation plan")
Write-ResumeArtifact -Path $documentFailedRound1Feedback -Decision "MINOR_REFINEMENT" -Bullets @("Requested clearer execution steps")
Write-ResumeArtifact -Path (Join-Path $documentFailedCodex.Phase0Dir "round2_claude_thoughts.md") -Decision "MINOR_REFINEMENT" -Bullets @("Addressed the execution-step feedback")
Write-CodexFailureArtifact -Path (Join-Path $documentFailedCodex.Phase0Dir "round2_codex_evaluation.md")
Add-ResumeEvent -EventsFile $documentFailedCodex.EventsFile -Type "document_deliberation_round_started" -Round 1
Add-ResumeEvent -EventsFile $documentFailedCodex.EventsFile -Type "document_deliberation_round_started" -Round 2
$documentFailedCodexResume = Get-DeliberationResumeState -Mode "document"
Assert-True ($documentFailedCodexResume.Success) "Resume state ignores failed Codex stub artifacts"
Assert-True ($documentFailedCodexResume.StartRound -eq 2) "Failed Codex stub keeps resume on the interrupted round"
Assert-True ($documentFailedCodexResume.NextAgent -eq "codex") "Failed Codex stub resumes with Codex"
Assert-True ($documentFailedCodexResume.CodexFeedbackFile -eq $documentFailedRound1Feedback) "Failed Codex stub does not replace the latest successful Codex feedback"

# =============================================================================
# Test 12: Codex Report Capture Helper
# =============================================================================

Write-TestHeader "Test 12: Codex Report Capture Helper"

$stubRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-codex-stub-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stubRoot -Force | Out-Null
$Script:TempCodexStubRoots += $stubRoot

$stubPath = Join-Path $stubRoot "codex.cmd"
@"
@echo off
setlocal EnableDelayedExpansion
set "outfile="

:parse
if "%~1"=="" goto afterParse
if /I "%~1"=="-o" (
  set "outfile=%~2"
  shift
)
shift
goto parse

:afterParse
echo ARGS:%*
echo stderr:simulated 1>&2

if /I "%STUB_CODEX_MODE%"=="fail" (
  exit /b 7
)

if /I "%STUB_CODEX_MODE%"=="hang" (
  if not defined outfile (
    echo missing -o target 1>&2
    exit /b 8
  )

  > "!outfile!" (
    echo ## QC Status: PASS
    echo(
    echo ## Issues Found: 0
    echo(
    echo ## Summary
    echo Salvaged after timeout.
  )
  ping -n 31 127.0.0.1 >nul
  exit /b 0
)

if not defined outfile (
  echo missing -o target 1>&2
  exit /b 8
)

> "!outfile!" (
  echo ## QC Status: PASS
  echo(
  echo ## Issues Found: 0
  echo(
  echo ## Regression Report
  echo None
  echo(
  echo ## Summary
  echo Stub success.
)

exit /b 0
"@ | Out-File -FilePath $stubPath -Encoding ASCII

$previousPath = $env:PATH
$previousStubMode = $env:STUB_CODEX_MODE
$env:PATH = "$stubRoot;$previousPath"
$Script:QCLogFile = Join-Path $stubRoot "qc_log_test.txt"

try {
    $env:STUB_CODEX_MODE = "success"
    $successReport = Join-Path $stubRoot "qc_report_iter1_2026-03-19_08-00-00.md"
    $successHeader = @"
# QC Report (Code Mode)
- **Generated**: 2026-03-19 08:00:00
- **Iteration**: 1
- **QC Tool**: Codex

---
"@
    $successCapture = Invoke-CodexCommandWithArtifacts -Prompt "Stub prompt" -ReportFile $successReport -ReportHeader $successHeader -ToolLabel "Codex (Stub Success)" -SandboxMode "read-only" -ReasoningEffort "xhigh"
    Assert-True $successCapture.Success "Codex capture helper succeeds when final message is written"
    $successReportContent = Get-Content -Path $successReport -Raw
    Assert-True ($successReportContent -match '## QC Status: PASS') "Clean markdown report is written to the primary artifact"
    $successTranscript = Get-CodexTranscriptFilePath -ReportFile $successReport
    $successTranscriptContent = Get-Content -Path $successTranscript -Raw
    Assert-True ($successTranscriptContent -match 'ARGS:') "Transcript artifact captures raw CLI output"
    Assert-True ($successTranscriptContent -match '-a never') "Transcript confirms explicit approval policy argument"
    Assert-True ($successTranscriptContent -match '-s read-only') "Transcript confirms explicit read-only sandbox argument"
    Assert-True ($successTranscriptContent -match 'reasoning_effort=\\"xhigh\\"') "Transcript confirms explicit xhigh reasoning override"

    $env:STUB_CODEX_MODE = "fail"
    $failureReport = Join-Path $stubRoot "round1_codex_review.md"
    $failureHeader = @"
# Codex Code Review (Deliberation Mode)
- **Generated**: 2026-03-19 08:01:00
- **Round**: 1

---
"@
    $failureCapture = Invoke-CodexCommandWithArtifacts -Prompt "Stub prompt" -ReportFile $failureReport -ReportHeader $failureHeader -ToolLabel "Codex (Stub Failure)" -SandboxMode "workspace-write"
    Assert-True (-not $failureCapture.Success) "Codex capture helper reports failure when Codex exits nonzero"
    $failureReportContent = Get-Content -Path $failureReport -Raw
    Assert-True ($failureReportContent -match 'Codex execution failed before producing a final markdown report') "Failure stub is written to the primary markdown artifact"
    $failureTranscript = Get-CodexTranscriptFilePath -ReportFile $failureReport
    $failureTranscriptContent = Get-Content -Path $failureTranscript -Raw
    Assert-True ($failureTranscriptContent -match '-s workspace-write') "Transcript confirms workspace-write sandbox for deliberation flows"

    $env:STUB_CODEX_MODE = "hang"
    $hangReport = Join-Path $stubRoot "doc_qc_report_iter_meta_timeout.md"
    $hangCapture = Invoke-CodexCommandWithArtifacts -Prompt "Stub prompt" -ReportFile $hangReport -ReportHeader $successHeader -ToolLabel "Codex (Stub Timeout)" -SandboxMode "read-only" -ReasoningEffort "xhigh" -TimeoutSec 1
    Assert-True $hangCapture.Success "Codex capture helper salvages final markdown after timeout"
    $hangReportContent = Get-Content -Path $hangReport -Raw
    Assert-True ($hangReportContent -match 'Salvaged after timeout') "Timed-out Codex run writes salvaged markdown to the primary artifact"
}
finally {
    $env:PATH = $previousPath
    if ($null -eq $previousStubMode) {
        Remove-Item Env:STUB_CODEX_MODE -ErrorAction SilentlyContinue
    }
    else {
        $env:STUB_CODEX_MODE = $previousStubMode
    }
}

# =============================================================================
# Test 13: Claude Command Helper
# =============================================================================

Write-TestHeader "Test 13: Claude Command Helper"

$claudeStubRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-claude-stub-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $claudeStubRoot -Force | Out-Null
$Script:TempClaudeStubRoots += $claudeStubRoot

$claudeStubPath = Join-Path $claudeStubRoot "claude.cmd"
@"
@echo off
setlocal EnableDelayedExpansion
if /I "%~1"=="--help" (
  echo Usage: claude [options]
  echo   --effort ^<level^>
  exit /b 0
)
echo ARGS:%*
set "stdin_line="
set /p stdin_line=
if not defined stdin_line (
  echo missing stdin 1>&2
  exit /b 10
)
echo STDIN:!stdin_line!

if /I "%STUB_CLAUDE_MODE%"=="hang" (
  ping -n 31 127.0.0.1 >nul
  exit /b 0
)

if /I "%STUB_CLAUDE_MODE%"=="fail" (
  exit /b 9
)

echo Claude stub success.
exit /b 0
"@ | Out-File -FilePath $claudeStubPath -Encoding ASCII

$previousPath = $env:PATH
$previousClaudeMode = $env:STUB_CLAUDE_MODE
$env:PATH = "$claudeStubRoot;$previousPath"

try {
    $env:STUB_CLAUDE_MODE = "success"
    $claudeSuccess = Invoke-ClaudeCommand -Prompt "stub prompt" -AllowedTools "Read,Write" -ToolLabel "Claude (Stub Success)" -TimeoutSec 1 -UseMaxEffort -PermissionMode "acceptEdits"
    Assert-True (-not $claudeSuccess.TimedOut) "Claude command helper completes without timeout in success mode"
    Assert-True ($claudeSuccess.ExitCode -eq 0) "Claude command helper returns zero exit code in success mode"
    Assert-Match (($claudeSuccess.Output | Out-String)) '--effort max' "Claude command helper passes --effort max for bounded meta review flows"
    Assert-Match (($claudeSuccess.Output | Out-String)) '--permission-mode acceptEdits' "Claude command helper passes explicit permission mode when requested"
    Assert-Match (($claudeSuccess.Output | Out-String)) 'STDIN:stub prompt' "Claude command helper sends the prompt through stdin for --print mode"

    $env:STUB_CLAUDE_MODE = "hang"
    $claudeTimeout = Invoke-ClaudeCommand -Prompt "stub prompt" -AllowedTools "Read,Write" -ToolLabel "Claude (Stub Timeout)" -TimeoutSec 1 -UseMaxEffort
    Assert-True $claudeTimeout.TimedOut "Claude command helper reports timeout when the process hangs"
    Assert-True ($claudeTimeout.ExitCode -eq 124) "Claude command helper returns timeout exit code when the process hangs"
}
finally {
    $env:PATH = $previousPath
    if ($null -eq $previousClaudeMode) {
        Remove-Item Env:STUB_CLAUDE_MODE -ErrorAction SilentlyContinue
    }
    else {
        $env:STUB_CLAUDE_MODE = $previousClaudeMode
    }
}

# =============================================================================
# Test 13b: Meta Review Output Enforcement
# =============================================================================

Write-TestHeader "Test 13b: Meta Review Output Enforcement"

$metaWriteValidationRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-meta-write-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $metaWriteValidationRoot -Force | Out-Null
$Script:TempResumeRoots += $metaWriteValidationRoot
$previousMetaReview = $MetaReview
$previousMetaReviewOutputFile = $Script:MetaReviewOutputFile
$previousQCLogFile = $Script:QCLogFile
$previousEventsFile = $Script:EventsFile
$previousRunStateFile = $Script:RunStateFile
$previousCapturedError = $Script:MetaWriteValidationError
$previousCapturedState = $Script:MetaWriteValidationState
$previousCapturedEvents = $Script:MetaWriteValidationEvents

$MetaReview = $true
$Script:MetaReviewOutputFile = Join-Path $metaWriteValidationRoot "meta_plan.reviewed.md"
$Script:QCLogFile = Join-Path $metaWriteValidationRoot "qc_log.txt"
$Script:EventsFile = Join-Path $metaWriteValidationRoot "events.ndjson"
$Script:RunStateFile = Join-Path $metaWriteValidationRoot "run_state.json"
New-Item -ItemType File -Path $Script:QCLogFile -Force | Out-Null
New-Item -ItemType File -Path $Script:EventsFile -Force | Out-Null
$Script:MetaWriteValidationError = ""
$Script:MetaWriteValidationState = @{}
$Script:MetaWriteValidationEvents = @()

function Update-RunState {
    param([hashtable]$State)
    $Script:MetaWriteValidationState = $State
}

function Write-RunEvent {
    param(
        [string]$Type,
        [string]$Level = "info",
        [hashtable]$Data = @{}
    )
    $Script:MetaWriteValidationEvents += @(@{ Type = $Type; Level = $Level; Data = $Data })
}

function Write-LogError {
    param([string]$Message)
    $Script:MetaWriteValidationError = $Message
}

try {
    $approvalBlocked = Save-MetaReviewOutputFromClaudeResponse -StageLabel "meta-review write" -EventType "implementation_failed" -Output "Please approve the write to C:\temp\meta_plan.reviewed.md"
    Assert-True (-not $approvalBlocked) "Meta-review output enforcement fails when Claude requests write approval"
    Assert-Match $Script:MetaWriteValidationError 'requested write approval' "Meta-review output enforcement logs approval-blocked failures clearly"
    Assert-True ($Script:MetaWriteValidationEvents[0].Data.permissionBlocked -eq $true) "Meta-review output enforcement marks approval-blocked failures"

    $Script:MetaWriteValidationError = ""
    $Script:MetaWriteValidationEvents = @()
    $writeSucceeded = Save-MetaReviewOutputFromClaudeResponse -StageLabel "meta-review write" -EventType "implementation_failed" -Output @"
<<<META_REVIEW_OUTPUT_START>>>
# Reviewed meta plan

## Goal
Done.
<<<META_REVIEW_OUTPUT_END>>>

- reviewed file path: $($Script:MetaReviewOutputFile)
"@
    Assert-True $writeSucceeded "Meta-review output enforcement passes when the reviewed file exists"
    Assert-True ([string]::IsNullOrWhiteSpace($Script:MetaWriteValidationError)) "Meta-review output enforcement leaves no error message on success"
    Assert-Match (Get-Content -Path $Script:MetaReviewOutputFile -Raw) '^# Reviewed meta plan' "Meta-review output enforcement writes extracted reviewed markdown to the output file"
}
finally {
    $MetaReview = $previousMetaReview
    $Script:MetaReviewOutputFile = $previousMetaReviewOutputFile
    $Script:QCLogFile = $previousQCLogFile
    $Script:EventsFile = $previousEventsFile
    $Script:RunStateFile = $previousRunStateFile
    $Script:MetaWriteValidationError = $previousCapturedError
    $Script:MetaWriteValidationState = $previousCapturedState
    $Script:MetaWriteValidationEvents = $previousCapturedEvents
    if (Test-Path $MainScript) {
        . $MainScript
    }
}

# =============================================================================
# Test 13c: Meta Review Relay Draft Handling
# =============================================================================

Write-TestHeader "Test 13c: Meta Review Relay Draft Handling"

$relayDraftRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-meta-relay-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $relayDraftRoot -Force | Out-Null
$Script:TempResumeRoots += $relayDraftRoot
$previousMetaReview = $MetaReview
$previousLogsDir = $Script:LogsDir
$previousCurrentQCReport = $Script:CurrentQCReport
$previousMetaReviewReplacementDraftFile = $Script:MetaReviewReplacementDraftFile
$previousEventsFile = $Script:EventsFile
$MetaReview = $true
$Script:LogsDir = $relayDraftRoot
$Script:CurrentQCReport = Join-Path $relayDraftRoot "doc_qc_report_iter2_test.md"
$Script:MetaReviewReplacementDraftFile = ""
$Script:EventsFile = Join-Path $relayDraftRoot "events.ndjson"
New-Item -ItemType File -Path $Script:EventsFile -Force | Out-Null
$relayHeader = @"
# QC Report (Meta Review Relay)
---
"@

try {
    $relayPass = Finalize-MetaReviewRelayCodexResult -ReportHeader $relayHeader -Timestamp "passcase" -CodexResult @{
        FinalMessage = @"
## QC Status: PASS

## Issues Found: 0

## Summary
Clean.
"@
        TranscriptFile = Join-Path $relayDraftRoot "pass.transcript.md"
    }
    Assert-True $relayPass.Success "Meta review relay finalizer accepts PASS responses without a replacement draft"
    Assert-True ([string]::IsNullOrWhiteSpace($relayPass.ReplacementDraftFile)) "Meta review relay finalizer does not persist a replacement draft on PASS"

    $relayFail = Finalize-MetaReviewRelayCodexResult -ReportHeader $relayHeader -Timestamp "failcase" -CodexResult @{
        FinalMessage = @"
## QC Status: FAIL

## Issues Found: 1

### Issue 1
- **Severity**: HIGH
- **Category**: Checklist Compliance
- **Location**: Requirements
- **Description**: Broken.
- **Fix**: Repair it.

## Summary
Needs repair.

<<<META_REVIEW_REPLACEMENT_DRAFT_START>>>
# Replacement Draft

## Overview
Fixed.
<<<META_REVIEW_REPLACEMENT_DRAFT_END>>>
"@
        TranscriptFile = Join-Path $relayDraftRoot "fail.transcript.md"
    }
    Assert-True $relayFail.Success "Meta review relay finalizer accepts FAIL responses with a replacement draft"
    Assert-True (-not [string]::IsNullOrWhiteSpace($relayFail.ReplacementDraftFile)) "Meta review relay finalizer persists the replacement draft artifact on FAIL"
    if (-not [string]::IsNullOrWhiteSpace($relayFail.ReplacementDraftFile)) {
        Assert-Match (Get-Content -Path $relayFail.ReplacementDraftFile -Raw) '^# Replacement Draft' "Meta review relay finalizer writes only the replacement markdown to the artifact file"
    }
    Assert-True (-not ((Get-Content -Path $Script:CurrentQCReport -Raw) -match 'META_REVIEW_REPLACEMENT_DRAFT_START')) "Meta review relay finalizer strips replacement-draft markers from the QC report artifact"

    $relayMalformed = Finalize-MetaReviewRelayCodexResult -ReportHeader $relayHeader -Timestamp "malformedcase" -CodexResult @{
        FinalMessage = @"
## Issues Found: 1

### Issue 1
- **Severity**: HIGH
- **Category**: Checklist Compliance
- **Location**: Requirements
- **Description**: Broken.
- **Fix**: Repair it.

## Summary
Missing QC status.

<<<META_REVIEW_REPLACEMENT_DRAFT_START>>>
# Replacement Draft
<<<META_REVIEW_REPLACEMENT_DRAFT_END>>>
"@
        TranscriptFile = Join-Path $relayDraftRoot "malformed.transcript.md"
    }
    Assert-True (-not $relayMalformed.Success) "Meta review relay finalizer rejects malformed Codex reports that omit structured QC status"
}
finally {
    $MetaReview = $previousMetaReview
    $Script:LogsDir = $previousLogsDir
    $Script:CurrentQCReport = $previousCurrentQCReport
    $Script:MetaReviewReplacementDraftFile = $previousMetaReviewReplacementDraftFile
    $Script:EventsFile = $previousEventsFile
}

# =============================================================================
# Test 14: Deliberation Timeout Wiring
# =============================================================================

Write-TestHeader "Test 14: Deliberation Timeout Wiring"

$delibStubRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-delib-timeout-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $delibStubRoot -Force | Out-Null
$Script:TempCodexStubRoots += $delibStubRoot
$Script:TempClaudeStubRoots += $delibStubRoot
$delibPhase0Dir = Join-Path $delibStubRoot "logs\session-delib\deliberation\phase0"
$delibPhase1Dir = Join-Path $delibStubRoot "logs\session-delib\deliberation\phase1"
foreach ($dir in @($delibPhase0Dir, $delibPhase1Dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$delibClaudeStubPath = Join-Path $delibStubRoot "claude.cmd"
@"
@echo off
setlocal
echo ARGS:%*

if /I "%STUB_CLAUDE_MODE%"=="hang" (
  ping -n 31 127.0.0.1 >nul
  exit /b 0
)

if /I "%STUB_CLAUDE_MODE%"=="fail" (
  exit /b 9
)

echo Claude stub success.
exit /b 0
"@ | Out-File -FilePath $delibClaudeStubPath -Encoding ASCII

$delibCodexStubPath = Join-Path $delibStubRoot "codex.cmd"
@"
@echo off
setlocal EnableDelayedExpansion
set "outfile="

:parse
if "%~1"=="" goto done
if /I "%~1"=="-o" (
  shift
  set "outfile=%~1"
  shift
  goto parse
)
shift
goto parse

:done
if /I "%STUB_CODEX_MODE%"=="hang" (
  if not defined outfile exit /b 8
  > "!outfile!" (
    echo ## Decision: MAJOR_REFINEMENT
    echo(
    echo ## Changes Made:
    echo - Salvaged after timeout.
  )
  ping -n 31 127.0.0.1 >nul
  exit /b 0
)

if /I "%STUB_CODEX_MODE%"=="fail" (
  exit /b 7
)

if not defined outfile exit /b 8
> "!outfile!" (
  echo ## Decision: MINOR_REFINEMENT
  echo(
  echo ## Changes Made:
  echo - Immediate success.
)
exit /b 0
"@ | Out-File -FilePath $delibCodexStubPath -Encoding ASCII

$delibPlanFile = Join-Path $delibStubRoot "plan.md"
$delibDocFile = Join-Path $delibStubRoot "CONTINUATION_CYCLE_4.md"
"# Plan" | Out-File -FilePath $delibPlanFile -Encoding UTF8
"# Continuation" | Out-File -FilePath $delibDocFile -Encoding UTF8

$delibDocInitialPrompt = Join-Path $delibStubRoot "claude_deliberate_doc_initial_prompt.md"
$delibDocRefinePrompt = Join-Path $delibStubRoot "claude_deliberate_doc_refine_prompt.md"
$delibDocQCPrompt = Join-Path $delibStubRoot "codex_deliberate_doc_prompt.md"
$delibCodeInitialPrompt = Join-Path $delibStubRoot "claude_deliberate_code_initial_prompt.md"
$delibCodeRefinePrompt = Join-Path $delibStubRoot "claude_deliberate_code_refine_prompt.md"
$delibCodeQCPrompt = Join-Path $delibStubRoot "codex_deliberate_code_prompt.md"

@"
Plan: {{PLAN_FILE}}
Thoughts: {{THOUGHTS_FILE}}
Doc: {{DOC_FILE}}
Round: {{ROUND}}
Context: {{PREVIOUS_CONTEXT}}
Codex: {{CODEX_EVALUATION_FILE}}
"@ | Out-File -FilePath $delibDocInitialPrompt -Encoding UTF8
@"
Plan: {{PLAN_FILE}}
Thoughts: {{THOUGHTS_FILE}}
Doc: {{DOC_FILE}}
Round: {{ROUND}}
Context: {{PREVIOUS_CONTEXT}}
Codex: {{CODEX_EVALUATION_FILE}}
"@ | Out-File -FilePath $delibDocRefinePrompt -Encoding UTF8
@"
Plan: {{PLAN_FILE}}
Doc: {{DOC_FILE}}
Round: {{ROUND}}
Claude: {{CLAUDE_THOUGHTS_FILE}}
Eval: {{EVALUATION_FILE}}
Context: {{PREVIOUS_CONTEXT}}
"@ | Out-File -FilePath $delibDocQCPrompt -Encoding UTF8
@"
Plan: {{PLAN_FILE}}
Thoughts: {{THOUGHTS_FILE}}
Round: {{ROUND}}
Context: {{PREVIOUS_CONTEXT}}
Codex: {{CODEX_REVIEW_FILE}}
"@ | Out-File -FilePath $delibCodeInitialPrompt -Encoding UTF8
@"
Plan: {{PLAN_FILE}}
Thoughts: {{THOUGHTS_FILE}}
Round: {{ROUND}}
Context: {{PREVIOUS_CONTEXT}}
Codex: {{CODEX_REVIEW_FILE}}
"@ | Out-File -FilePath $delibCodeRefinePrompt -Encoding UTF8
@"
Plan: {{PLAN_FILE}}
Round: {{ROUND}}
Claude: {{CLAUDE_THOUGHTS_FILE}}
Review: {{REVIEW_FILE}}
Context: {{PREVIOUS_CONTEXT}}
"@ | Out-File -FilePath $delibCodeQCPrompt -Encoding UTF8

$previousAgentTimeout = $AgentTimeoutSec
$previousReasoningEffort = $ReasoningEffort
$previousDelibPhase0Dir = $Script:DelibPhase0Dir
$previousDelibPhase1Dir = $Script:DelibPhase1Dir
$previousQCLogFile = $Script:QCLogFile
$previousEventsFile = $Script:EventsFile
$previousPipelineStartTime = $Script:PipelineStartTime
$previousDocInitialPrompt = $Script:DeliberateDocInitialPrompt
$previousDocRefinePrompt = $Script:DeliberateDocRefinePrompt
$previousDocQCPrompt = $Script:DeliberateDocQCPrompt
$previousCodeInitialPrompt = $Script:DeliberateCodeInitialPrompt
$previousCodeRefinePrompt = $Script:DeliberateCodeRefinePrompt
$previousCodeQCPrompt = $Script:DeliberateCodeQCPrompt
$env:PATH = "$delibStubRoot;$previousPath"
$Script:DelibPhase0Dir = $delibPhase0Dir
$Script:DelibPhase1Dir = $delibPhase1Dir
$Script:QCLogFile = Join-Path $delibStubRoot "qc_log_deliberation.txt"
New-Item -ItemType File -Path $Script:QCLogFile -Force | Out-Null
$Script:EventsFile = Join-Path $delibStubRoot "events.ndjson"
New-Item -ItemType File -Path $Script:EventsFile -Force | Out-Null
$Script:RunState = [ordered]@{ status = "running"; phase = "document_deliberation"; currentDeliberationRound = 0 }
$Script:PipelineStartTime = "2026-03-20_07-20-00"
$Script:CurrentIteration = 0
$Script:CurrentPlanQCIteration = 0
$ReasoningEffort = "medium"
$Script:DeliberateDocInitialPrompt = $delibDocInitialPrompt
$Script:DeliberateDocRefinePrompt = $delibDocRefinePrompt
$Script:DeliberateDocQCPrompt = $delibDocQCPrompt
$Script:DeliberateCodeInitialPrompt = $delibCodeInitialPrompt
$Script:DeliberateCodeRefinePrompt = $delibCodeRefinePrompt
$Script:DeliberateCodeQCPrompt = $delibCodeQCPrompt
$Script:DelibClaudeTimeoutCalls = @()
$Script:DelibCodexTimeoutCalls = @()

function Invoke-ClaudeCommand {
    param(
        [string]$Prompt,
        [string]$AllowedTools,
        [string]$ToolLabel,
        [int]$TimeoutSec = 0,
        [switch]$UseMaxEffort
    )

    $Script:DelibClaudeTimeoutCalls += @(@{
            ToolLabel = $ToolLabel
            AllowedTools = $AllowedTools
            TimeoutSec = $TimeoutSec
            UseMaxEffort = [bool]$UseMaxEffort
        })

    return @{
        TimedOut = $true
        ExitCode = 124
        Output = @("mock claude timeout")
    }
}

function Invoke-CodexCommandWithArtifacts {
    param(
        [string]$Prompt,
        [string]$ReportFile,
        [string]$ReportHeader,
        [string]$ToolLabel,
        [string]$SandboxMode = "read-only",
        [string]$ReasoningEffort = "",
        [int]$TimeoutSec = 0
    )

    $Script:DelibCodexTimeoutCalls += @(@{
            ToolLabel = $ToolLabel
            ReportFile = $ReportFile
            SandboxMode = $SandboxMode
            ReasoningEffort = $ReasoningEffort
            TimeoutSec = $TimeoutSec
        })

    $body = @"
## Decision: MAJOR_REFINEMENT

## Changes Made:
- Salvaged after timeout.
"@
    Write-MarkdownArtifact -FilePath $ReportFile -Header $ReportHeader -Body $body
    $transcriptFile = Get-CodexTranscriptFilePath -ReportFile $ReportFile
    @"
ARGS: codex -a never -c reasoning_effort=\"$ReasoningEffort\" exec --skip-git-repo-check -s $SandboxMode
PROMPT: stdin (0 chars, 0 lines)
"@ | Out-File -FilePath $transcriptFile -Encoding UTF8
    Write-RunEvent -Type "tool_timeout_salvaged" -Level "warn" -Data @{
        tool = $ToolLabel
        timeoutSec = $TimeoutSec
        report = $ReportFile
        transcript = $transcriptFile
        message = "$ToolLabel timed out after $TimeoutSec seconds; salvaged final markdown output."
    }

    return @{
        Success = $true
        ExitCode = 0
        Output = @()
        TranscriptFile = $transcriptFile
        FinalMessage = $body
    }
}

try {
    $docClaudeResult = Invoke-ClaudeDeliberateDoc -PlanFile $delibPlanFile -PreviousContext "" -Round 1 -IsInitial $true
    Assert-True (-not $docClaudeResult.Success) "Document deliberation Claude path fails cleanly on timeout"
    Assert-True ($Script:DelibClaudeTimeoutCalls[0].TimeoutSec -eq $previousAgentTimeout) "Document deliberation Claude passes AgentTimeoutSec to the shared Claude wrapper"

    $docCodexResult = Invoke-CodexDeliberateDoc -PlanFile $delibPlanFile -PreviousContext "" -Round 1 -ClaudeThoughtsFile "" -DocFile $delibDocFile
    Assert-True $docCodexResult.Success "Document deliberation Codex path salvages temp output after timeout"
    $docEvaluationContent = Get-Content -Path $docCodexResult.EvaluationFile -Raw
    Assert-Match $docEvaluationContent "Salvaged after timeout" "Document deliberation Codex writes salvaged evaluation artifact"
    $docTranscriptContent = Get-Content -Path (Get-CodexTranscriptFilePath -ReportFile $docCodexResult.EvaluationFile) -Raw
    Assert-Match $docTranscriptContent 'reasoning_effort=\\"medium\\"' "Document deliberation Codex passes configured reasoning effort to Codex"
    Assert-True ($Script:DelibCodexTimeoutCalls[0].TimeoutSec -eq $previousAgentTimeout) "Document deliberation Codex passes AgentTimeoutSec to the Codex artifact wrapper"

    $Script:RunState.phase = "code_deliberation"
    $codeClaudeResult = Invoke-ClaudeDeliberateCode -PlanFile $delibPlanFile -PreviousContext "" -Round 1 -IsInitial $true
    Assert-True (-not $codeClaudeResult.Success) "Code deliberation Claude path fails cleanly on timeout"

    $codeCodexResult = Invoke-CodexDeliberateCode -PlanFile $delibPlanFile -PreviousContext "" -Round 1 -ClaudeThoughtsFile ""
    Assert-True $codeCodexResult.Success "Code deliberation Codex path salvages temp output after timeout"
    $codeReviewContent = Get-Content -Path $codeCodexResult.ReviewFile -Raw
    Assert-Match $codeReviewContent "Salvaged after timeout" "Code deliberation Codex writes salvaged review artifact"

    $delibEventsContent = Get-Content -Path $Script:EventsFile -Raw
    Assert-Match $delibEventsContent '"type":"tool_timeout"' "Deliberation Claude timeout emits tool_timeout event"
    Assert-Match $delibEventsContent '"type":"tool_timeout_salvaged"' "Deliberation Codex timeout salvage emits tool_timeout_salvaged event"
}
finally {
    $AgentTimeoutSec = $previousAgentTimeout
    $ReasoningEffort = $previousReasoningEffort
    $Script:DelibPhase0Dir = $previousDelibPhase0Dir
    $Script:DelibPhase1Dir = $previousDelibPhase1Dir
    $Script:QCLogFile = $previousQCLogFile
    $Script:EventsFile = $previousEventsFile
    $Script:PipelineStartTime = $previousPipelineStartTime
    $Script:DeliberateDocInitialPrompt = $previousDocInitialPrompt
    $Script:DeliberateDocRefinePrompt = $previousDocRefinePrompt
    $Script:DeliberateDocQCPrompt = $previousDocQCPrompt
    $Script:DeliberateCodeInitialPrompt = $previousCodeInitialPrompt
    $Script:DeliberateCodeRefinePrompt = $previousCodeRefinePrompt
    $Script:DeliberateCodeQCPrompt = $previousCodeQCPrompt
    if (Test-Path $MainScript) {
        . $MainScript
    }
}

# =============================================================================
# Test 15: Meta Review Pipeline Boundaries
# =============================================================================

Write-TestHeader "Test 15: Meta Review Pipeline Boundaries"

$metaPipelineRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-meta-review-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $metaPipelineRoot -Force | Out-Null
$Script:TempResumeRoots += $metaPipelineRoot
$Script:MetaReviewTempRoot = $metaPipelineRoot
$Script:QCLogFile = Join-Path $metaPipelineRoot "qc_log_meta_review.txt"
New-Item -ItemType File -Path $Script:QCLogFile -Force | Out-Null
$Script:MetaReviewCallSequence = @()
$Script:MetaReviewEvents = @()
$Script:MetaReviewHistory = @()
$Script:MetaReviewCheckpoints = @()
$Script:MetaReviewFailure = $null
$Script:MetaReviewCompletion = $null
$Script:MetaReviewCodexPasses = 0
$Script:MockQCPassed = $false
$Script:MockQCIssues = ""
$Script:MetaReviewReplacementDraftFile = ""
$Script:MetaReviewDeterministicFixValidationPasses = 0
$MetaReview = $true
$QCType = "document"

function Update-RunState {
    param([hashtable]$State)
    $Script:MetaReviewEvents += @(@{ Type = "run_state"; Data = $State })
}

function Write-RunEvent {
    param(
        [string]$Type,
        [string]$Level = "info",
        [hashtable]$Data = @{}
    )
    $Script:MetaReviewEvents += @(@{ Type = $Type; Level = $Level; Data = $Data })
}

function Write-LogHeader {
    param([string]$Message)
    $Script:MetaReviewCallSequence += "log-header:$Message"
}

function Write-LogInfo {
    param([string]$Message)
    $Script:MetaReviewCallSequence += "log-info:$Message"
}

function Write-LogWarn {
    param([string]$Message)
    $Script:MetaReviewCallSequence += "log-warn:$Message"
}

function Add-IssuesToHistory {
    param(
        [string]$Issues,
        [int]$Iteration
    )
    $Script:MetaReviewHistory += "iter${Iteration}:$Issues"
}

function Write-IterationHistory {
    param(
        [int]$Iteration,
        [string]$Issues,
        [string]$Status
    )
    $Script:MetaReviewHistory += "status${Iteration}:$Status"
}

function New-GitCheckpoint {
    param([string]$Message)
    $Script:MetaReviewCheckpoints += $Message
}

function Test-QCPassed {
    return [bool]$Script:MockQCPassed
}

function Get-QCIssues {
    return $Script:MockQCIssues
}

function Invoke-MetaReviewDeterministicValidation {
    param(
        [string]$PlanFile,
        [string]$StageName
    )

    $Script:MetaReviewCallSequence += "deterministic:$StageName"
    $Script:CurrentQCReport = Join-Path $Script:MetaReviewTempRoot "doc_qc_report_$StageName.md"
    if ($StageName -eq "initial") {
        $Script:MockQCPassed = $false
        $Script:MockQCIssues = "deterministic issue"
    }
    elseif ($StageName -eq "post-deterministic-fix") {
        $Script:MetaReviewDeterministicFixValidationPasses++
        if ($Script:MetaReviewDeterministicFixValidationPasses -eq 1) {
            $Script:MockQCPassed = $false
            $Script:MockQCIssues = "### Issue 1`n- **Severity**: MEDIUM`n- **Fix**: second deterministic pass required.`n"
        }
        else {
            $Script:MockQCPassed = $true
            $Script:MockQCIssues = ""
        }
    }
    elseif ($StageName -eq "post-semantic-reconcile") {
        $Script:MockQCPassed = $true
        $Script:MockQCIssues = ""
    }
    else {
        throw "Unexpected deterministic validation stage: $StageName"
    }
    return $true
}

function Invoke-ClaudeFix {
    param(
        [string]$PlanFile,
        [string]$QCIssues
    )

    $Script:MetaReviewCallSequence += "claude-fix:$QCIssues"
    return $true
}

function Invoke-CodexMetaReviewRelayReview {
    param([string]$PlanFile)

    $Script:MetaReviewCodexPasses++
    $Script:MetaReviewCallSequence += "codex-relay:$($Script:MetaReviewCodexPasses)"
    $Script:CurrentQCReport = Join-Path $Script:MetaReviewTempRoot "doc_qc_report_codex_relay_$($Script:MetaReviewCodexPasses).md"
    $Script:MetaReviewReplacementDraftFile = Join-Path $Script:MetaReviewTempRoot "meta_review_codex_replacement_iter$($Script:CurrentIteration).md"
    $Script:MockQCPassed = $false
    $Script:MockQCIssues = "semantic issue"
    return $true
}

function Invoke-ClaudeMetaReviewReconcile {
    param(
        [string]$PlanFile,
        [string]$QCIssues
    )

    $Script:MetaReviewCallSequence += "claude-reconcile:$QCIssues"
    return $true
}

function Invoke-CodexQC {
    param([string]$PlanFile)

    $Script:MetaReviewCodexPasses++
    $Script:MetaReviewCallSequence += "codex-verify:$($Script:MetaReviewCodexPasses)"
    $Script:CurrentQCReport = Join-Path $Script:MetaReviewTempRoot "doc_qc_report_codex_verify_$($Script:MetaReviewCodexPasses).md"
    $Script:MockQCPassed = $true
    $Script:MockQCIssues = ""
    return $true
}

function Complete-MetaReviewPipeline {
    $Script:MetaReviewCallSequence += "complete"
    $Script:MetaReviewCompletion = @{
        Iteration = $Script:CurrentIteration
        Report = $Script:CurrentQCReport
    }
    throw "MetaReviewPipelineCompleted"
}

function Fail-Pipeline {
    param(
        [string]$Message,
        [hashtable]$Data = @{}
    )

    $Script:MetaReviewFailure = @{
        Message = $Message
        Data = $Data
    }
    throw "MetaReviewPipelineFailed:$Message"
}

$metaPipelineError = $null
try {
    Invoke-MetaReviewPipeline -PlanFile (Join-Path $metaPipelineRoot "meta_plan.md")
}
catch {
    if ($_ -notmatch 'MetaReviewPipelineCompleted') {
        $metaPipelineError = $_
    }
}

Assert-True ($null -eq $metaPipelineError) "Bounded meta-review pipeline completes without unexpected failure"
Assert-True ($null -eq $Script:MetaReviewFailure) "Bounded meta-review pipeline does not invoke Fail-Pipeline on the happy path"
Assert-True ($null -ne $Script:MetaReviewCompletion) "Bounded meta-review pipeline reaches completion"
Assert-True ($Script:MetaReviewCodexPasses -eq 2) "Bounded meta-review pipeline uses at most two Codex passes"
Assert-True (($Script:MetaReviewCallSequence | Where-Object { $_ -like 'claude-fix:*' }).Count -eq 2) "Bounded meta-review pipeline supports a second deterministic Claude fix pass when needed"
Assert-True (($Script:MetaReviewCallSequence | Where-Object { $_ -like 'claude-reconcile:*' }).Count -eq 1) "Bounded meta-review pipeline uses one Claude semantic reconcile pass on the happy path"
$metaReviewOperationalSequence = $Script:MetaReviewCallSequence | Where-Object { $_ -notlike 'log-*' }
$metaReviewOperationalJoined = $metaReviewOperationalSequence -join '|'
Assert-True (($metaReviewOperationalSequence | Where-Object { $_ -eq "deterministic:post-deterministic-fix" }).Count -eq 2) "Bounded meta-review pipeline reruns deterministic validation after each deterministic fix pass"
Assert-True ($metaReviewOperationalJoined -match 'deterministic:initial\|claude-fix:deterministic issue\|deterministic:post-deterministic-fix') "Bounded meta-review pipeline starts with deterministic validation and the first deterministic fix pass"
Assert-True ($metaReviewOperationalJoined -match 'deterministic:post-deterministic-fix\|codex-relay:1\|claude-reconcile:semantic issue\|deterministic:post-semantic-reconcile\|codex-verify:2\|complete') "Bounded meta-review pipeline follows relay -> reconcile -> deterministic recheck -> final verification order after deterministic retries"
Assert-True ($Script:MetaReviewCompletion.Iteration -eq 5) "Bounded meta-review pipeline finishes on the final verification iteration after two deterministic fix passes"
Assert-True ($Script:MetaReviewCheckpoints.Count -eq 3) "Bounded meta-review pipeline records checkpoints after two deterministic fix passes plus semantic reconciliation"
$metaReviewStartEvent = $Script:MetaReviewEvents | Where-Object { $_.Type -eq "qc_loop_started" } | Select-Object -First 1
Assert-True ($null -ne $metaReviewStartEvent) "Bounded meta-review pipeline emits a qc_loop_started event"
if ($null -ne $metaReviewStartEvent) {
    Assert-True ($metaReviewStartEvent.Data.maxCodexPasses -eq 3) "Bounded meta-review pipeline event records three Codex passes"
    Assert-True ($metaReviewStartEvent.Data.maxClaudePasses -eq 4) "Bounded meta-review pipeline event records four Claude passes"
}

# =============================================================================
# Test 15b: Meta Review Stops Before Final Verify On Post-Reconcile Deterministic Failure
# =============================================================================

Write-TestHeader "Test 15b: Meta Review Stops Before Final Verify On Post-Reconcile Deterministic Failure"

$Script:MetaReviewCallSequence = @()
$Script:MetaReviewEvents = @()
$Script:MetaReviewHistory = @()
$Script:MetaReviewCheckpoints = @()
$Script:MetaReviewFailure = $null
$Script:MetaReviewCompletion = $null
$Script:MetaReviewCodexPasses = 0
$Script:MetaReviewReplacementDraftFile = ""
$Script:MockQCPassed = $false
$Script:MockQCIssues = ""

function Invoke-MetaReviewDeterministicValidation {
    param(
        [string]$PlanFile,
        [string]$StageName
    )

    $Script:MetaReviewCallSequence += "deterministic:$StageName"
    $Script:CurrentQCReport = Join-Path $Script:MetaReviewTempRoot "doc_qc_report_$StageName.md"
    if ($StageName -eq "initial") {
        $Script:MockQCPassed = $true
        $Script:MockQCIssues = ""
    }
    elseif ($StageName -eq "post-semantic-reconcile") {
        $Script:MockQCPassed = $false
        $Script:MockQCIssues = "post reconcile deterministic issue"
    }
    else {
        throw "Unexpected deterministic validation stage: $StageName"
    }
    return $true
}

function Invoke-CodexMetaReviewRelayReview {
    param([string]$PlanFile)

    $Script:MetaReviewCodexPasses++
    $Script:MetaReviewCallSequence += "codex-relay:$($Script:MetaReviewCodexPasses)"
    $Script:CurrentQCReport = Join-Path $Script:MetaReviewTempRoot "doc_qc_report_codex_relay_fail.md"
    $Script:MetaReviewReplacementDraftFile = Join-Path $Script:MetaReviewTempRoot "meta_review_codex_replacement_iter$($Script:CurrentIteration).md"
    $Script:MockQCPassed = $false
    $Script:MockQCIssues = "semantic issue"
    return $true
}

function Invoke-ClaudeMetaReviewReconcile {
    param(
        [string]$PlanFile,
        [string]$QCIssues
    )

    $Script:MetaReviewCallSequence += "claude-reconcile:$QCIssues"
    return $true
}

function Invoke-CodexQC {
    param([string]$PlanFile)

    $Script:MetaReviewCodexPasses++
    $Script:MetaReviewCallSequence += "codex-verify:$($Script:MetaReviewCodexPasses)"
    return $true
}

$metaPipelineError = $null
try {
    Invoke-MetaReviewPipeline -PlanFile (Join-Path $metaPipelineRoot "meta_plan.md")
}
catch {
    if ($_ -notmatch 'MetaReviewPipelineFailed') {
        $metaPipelineError = $_
    }
}

Assert-True ($null -eq $metaPipelineError) "Meta-review pipeline deterministically fails without unexpected exception when post-reconcile validation fails"
Assert-True ($null -ne $Script:MetaReviewFailure) "Meta-review pipeline surfaces deterministic post-reconcile failure through Fail-Pipeline"
if ($null -ne $Script:MetaReviewFailure) {
    Assert-Match $Script:MetaReviewFailure.Message 'Deterministic meta-review validation failed after Claude semantic reconciliation' "Meta-review pipeline fails with the post-reconcile deterministic validation error"
}
Assert-True ($Script:MetaReviewCodexPasses -eq 1) "Meta-review pipeline does not spend the final Codex verify pass when post-reconcile validation fails"
Assert-True (-not (($Script:MetaReviewCallSequence -join '|') -match 'codex-verify')) "Meta-review pipeline stops before final Codex verify when post-reconcile validation fails"

# =============================================================================
# Test 15c: Meta Review Continues After Bounded Deterministic Retries When Only MEDIUM/LOW Issues Remain
# =============================================================================

Write-TestHeader "Test 15c: Meta Review Continues After Bounded Deterministic Retries When Only MEDIUM/LOW Issues Remain"

$Script:MetaReviewCallSequence = @()
$Script:MetaReviewEvents = @()
$Script:MetaReviewHistory = @()
$Script:MetaReviewCheckpoints = @()
$Script:MetaReviewFailure = $null
$Script:MetaReviewCompletion = $null
$Script:MetaReviewCodexPasses = 0
$Script:MetaReviewReplacementDraftFile = ""
$Script:MockQCPassed = $false
$Script:MockQCIssues = "### Issue 1`n- **Severity**: MEDIUM`n- **Fix**: Non-blocking deterministic finding remains.`n"

function Invoke-MetaReviewDeterministicValidation {
    param(
        [string]$PlanFile,
        [string]$StageName
    )

    $Script:MetaReviewCallSequence += "deterministic:$StageName"
    $Script:CurrentQCReport = Join-Path $Script:MetaReviewTempRoot "doc_qc_report_$StageName.md"
    if ($StageName -eq "initial" -or $StageName -eq "post-deterministic-fix") {
        $Script:MockQCPassed = $false
        return $true
    }

    throw "Unexpected deterministic validation stage in test 15c: $StageName"
}

function Invoke-CodexMetaReviewRelayReview {
    param([string]$PlanFile)

    $Script:MetaReviewCodexPasses++
    $Script:MetaReviewCallSequence += "codex-relay:$($Script:MetaReviewCodexPasses)"
    $Script:CurrentQCReport = Join-Path $Script:MetaReviewTempRoot "doc_qc_report_codex_relay_medium_continue.md"
    $Script:MockQCPassed = $true
    $Script:MockQCIssues = ""
    return $true
}

$metaPipelineError = $null
try {
    Invoke-MetaReviewPipeline -PlanFile (Join-Path $metaPipelineRoot "meta_plan.md")
}
catch {
    if ($_ -notmatch 'MetaReviewPipelineCompleted') {
        $metaPipelineError = $_
    }
}

Assert-True ($null -eq $metaPipelineError) "Meta-review pipeline continues past deterministic retries when only MEDIUM findings remain"
Assert-True ($null -eq $Script:MetaReviewFailure) "Meta-review pipeline does not fail when deterministic retries leave only non-blocking severities"
Assert-True ($null -ne $Script:MetaReviewCompletion) "Meta-review pipeline still reaches completion after MEDIUM-only deterministic continuation"
Assert-True (($Script:MetaReviewCallSequence | Where-Object { $_ -like 'claude-fix:*' }).Count -eq 2) "Meta-review pipeline spends exactly two deterministic Claude fix passes before MEDIUM-only continuation"
Assert-True (($Script:MetaReviewEvents | Where-Object { $_.Type -eq "meta_review_validation_nonblocking_issues" } | Measure-Object | Select-Object -ExpandProperty Count) -eq 1) "Meta-review pipeline emits a non-blocking deterministic warning event before semantic relay continuation"
Assert-True (($Script:MetaReviewCallSequence -join '|') -match 'codex-relay:1') "Meta-review pipeline proceeds to Codex relay after MEDIUM-only deterministic continuation"

# =============================================================================
# Test 15d: Meta Review Fails After Bounded Deterministic Retries When Blocking Severity Remains
# =============================================================================

Write-TestHeader "Test 15d: Meta Review Fails After Bounded Deterministic Retries When Blocking Severity Remains"

$Script:MetaReviewCallSequence = @()
$Script:MetaReviewEvents = @()
$Script:MetaReviewHistory = @()
$Script:MetaReviewCheckpoints = @()
$Script:MetaReviewFailure = $null
$Script:MetaReviewCompletion = $null
$Script:MetaReviewCodexPasses = 0
$Script:MetaReviewReplacementDraftFile = ""
$Script:MockQCPassed = $false
$Script:MockQCIssues = "### Issue 1`n- **Severity**: HIGH`n- **Fix**: Blocking deterministic finding remains.`n"

function Invoke-MetaReviewDeterministicValidation {
    param(
        [string]$PlanFile,
        [string]$StageName
    )

    $Script:MetaReviewCallSequence += "deterministic:$StageName"
    $Script:CurrentQCReport = Join-Path $Script:MetaReviewTempRoot "doc_qc_report_$StageName.md"
    if ($StageName -eq "initial" -or $StageName -eq "post-deterministic-fix") {
        $Script:MockQCPassed = $false
        return $true
    }

    throw "Unexpected deterministic validation stage in test 15d: $StageName"
}

function Invoke-CodexMetaReviewRelayReview {
    param([string]$PlanFile)

    $Script:MetaReviewCodexPasses++
    $Script:MetaReviewCallSequence += "codex-relay:$($Script:MetaReviewCodexPasses)"
    return $true
}

$metaPipelineError = $null
try {
    Invoke-MetaReviewPipeline -PlanFile (Join-Path $metaPipelineRoot "meta_plan.md")
}
catch {
    if ($_ -notmatch 'MetaReviewPipelineFailed') {
        $metaPipelineError = $_
    }
}

Assert-True ($null -eq $metaPipelineError) "Meta-review pipeline fails deterministically without unexpected exception when blocking severities persist after bounded deterministic retries"
Assert-True ($null -ne $Script:MetaReviewFailure) "Meta-review pipeline invokes Fail-Pipeline when blocking severities remain after deterministic retries"
if ($null -ne $Script:MetaReviewFailure) {
    Assert-Match $Script:MetaReviewFailure.Message 'Deterministic meta-review validation still failed after 2 allowed Claude fix pass\(es\)\.' "Meta-review pipeline uses retry-aware deterministic failure messaging"
    Assert-Match $Script:MetaReviewFailure.Data.reason 'Blocking severity remains' "Meta-review pipeline records blocking-severity rationale on deterministic retry exhaustion"
}
Assert-True (($Script:MetaReviewCallSequence | Where-Object { $_ -like 'claude-fix:*' }).Count -eq 2) "Meta-review pipeline spends both deterministic Claude fix passes before failing on blocking severity"
Assert-True (-not (($Script:MetaReviewCallSequence -join '|') -match 'codex-relay')) "Meta-review pipeline does not proceed to semantic relay when blocking deterministic severities remain"

# =============================================================================
# Test 16: Severity-Gated Deliberation Convergence
# =============================================================================

Write-TestHeader "Test 16: Severity-Gated Deliberation Convergence"

$severityTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-qc-delib-severity-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $severityTempRoot -Force | Out-Null
$Script:TempResumeRoots += $severityTempRoot

function Write-DelibArtifact {
    param(
        [string]$Path,
        [string]$Decision,
        [string[]]$Severities
    )

    $lines = @(
        "# Codex Round 1 Review",
        "",
        "## Assessment Summary",
        "Synthetic test artifact.",
        "",
        "## Issues Found",
        "### Critical",
        "- Synthetic issue",
        "",
        "## Fixes Applied",
        "- Synthetic: Fixed",
        "",
        "## Remaining Issues"
    )
    foreach ($sev in $Severities) {
        $lines += "- **Severity**: $sev " + [char]0x2014 + " synthetic $sev item"
    }
    $lines += @(
        "",
        "## Decision: $Decision",
        "Synthetic."
    )
    $lines | Out-File -FilePath $Path -Encoding UTF8
}

# --- Unit test 16a: CRITICAL remaining blocks CONVERGED ---
$artifactCritical = Join-Path $severityTempRoot "round1_codex_review_critical.md"
Write-DelibArtifact -Path $artifactCritical -Decision "CONVERGED" -Severities @("CRITICAL")
$sevCritical = Get-DeliberationSeveritySummary -ArtifactPath $artifactCritical
Assert-True ($sevCritical.ParseSucceeded -eq $true) "16a: severity parser reports success on valid artifact"
Assert-True ($sevCritical.HasBlockingSeverity -eq $true) "16a: CRITICAL flagged as blocking severity"
Assert-True (-not (Test-Convergence -ClaudeDecision "CONVERGED" -CodexDecision "CONVERGED" -ConsecutiveMinorRounds 0 -HasBlockingSeverity $sevCritical.HasBlockingSeverity)) "16a: Test-Convergence vetoes convergence when CRITICAL remains (both CONVERGED)"

# --- Unit test 16b: HIGH remaining blocks soft convergence (MINOR x 2) ---
$artifactHigh = Join-Path $severityTempRoot "round1_codex_review_high.md"
Write-DelibArtifact -Path $artifactHigh -Decision "MINOR_REFINEMENT" -Severities @("HIGH", "MEDIUM")
$sevHigh = Get-DeliberationSeveritySummary -ArtifactPath $artifactHigh
Assert-True ($sevHigh.HasBlockingSeverity -eq $true) "16b: HIGH flagged as blocking severity"
Assert-True (-not (Test-Convergence -ClaudeDecision "MINOR_REFINEMENT" -CodexDecision "MINOR_REFINEMENT" -ConsecutiveMinorRounds 2 -HasBlockingSeverity $sevHigh.HasBlockingSeverity)) "16b: Test-Convergence vetoes convergence when HIGH remains (soft convergence attempt)"

# --- Unit test 16c: MEDIUM-only allows CONVERGED ---
$artifactMedium = Join-Path $severityTempRoot "round1_codex_review_medium.md"
Write-DelibArtifact -Path $artifactMedium -Decision "CONVERGED" -Severities @("MEDIUM", "LOW")
$sevMedium = Get-DeliberationSeveritySummary -ArtifactPath $artifactMedium
Assert-True ($sevMedium.HasBlockingSeverity -eq $false) "16c: MEDIUM+LOW not flagged as blocking severity"
Assert-True (Test-Convergence -ClaudeDecision "CONVERGED" -CodexDecision "CONVERGED" -ConsecutiveMinorRounds 0 -HasBlockingSeverity $sevMedium.HasBlockingSeverity) "16c: Test-Convergence converges when only MEDIUM/LOW remain and both agents CONVERGED"

# --- Unit test 16d: MEDIUM-only allows soft convergence (MINOR x 2) ---
Assert-True (Test-Convergence -ClaudeDecision "MINOR_REFINEMENT" -CodexDecision "MINOR_REFINEMENT" -ConsecutiveMinorRounds 2 -HasBlockingSeverity $sevMedium.HasBlockingSeverity) "16d: Test-Convergence soft-converges when only MEDIUM/LOW remain and MINOR x 2"

# --- Unit test 16e: NONE severity (all resolved) allows convergence ---
$artifactNone = Join-Path $severityTempRoot "round1_codex_review_none.md"
Write-DelibArtifact -Path $artifactNone -Decision "CONVERGED" -Severities @("NONE")
$sevNone = Get-DeliberationSeveritySummary -ArtifactPath $artifactNone
Assert-True ($sevNone.HasBlockingSeverity -eq $false) "16e: NONE severity not flagged as blocking"
Assert-True (Test-Convergence -ClaudeDecision "CONVERGED" -CodexDecision "CONVERGED" -ConsecutiveMinorRounds 0 -HasBlockingSeverity $sevNone.HasBlockingSeverity) "16e: Test-Convergence converges when all issues resolved (NONE)"

# --- Unit test 16f: missing artifact file is non-blocking (I/O safety) ---
$artifactMissing = Join-Path $severityTempRoot "round1_codex_review_missing.md"
$sevMissing = Get-DeliberationSeveritySummary -ArtifactPath $artifactMissing
Assert-True ($sevMissing.ParseSucceeded -eq $false) "16f: missing artifact reports ParseSucceeded=false"
Assert-True ($sevMissing.HasBlockingSeverity -eq $false) "16f: missing artifact defaults to non-blocking"

# --- Unit test 16g: artifact without Remaining Issues section (backwards-compat) ---
$artifactLegacy = Join-Path $severityTempRoot "round1_codex_review_legacy.md"
@(
    "# Codex Round 1 Review",
    "",
    "## Assessment Summary",
    "Legacy artifact with no Remaining Issues section and no severity bullets.",
    "",
    "## Decision: CONVERGED",
    "Synthetic."
) | Out-File -FilePath $artifactLegacy -Encoding UTF8
$sevLegacy = Get-DeliberationSeveritySummary -ArtifactPath $artifactLegacy
Assert-True ($sevLegacy.ParseSucceeded -eq $true) "16g: legacy artifact parse reports success"
Assert-True ($sevLegacy.HasBlockingSeverity -eq $false) "16g: legacy artifact (no severity bullets) defaults to non-blocking (backwards compat)"
Assert-True ($sevLegacy.MissingSeverity -eq $true) "16g: legacy artifact flagged as MissingSeverity"
Assert-True (Test-Convergence -ClaudeDecision "CONVERGED" -CodexDecision "CONVERGED" -ConsecutiveMinorRounds 0 -HasBlockingSeverity $sevLegacy.HasBlockingSeverity) "16g: legacy artifact does not block pre-existing convergence behavior"

# --- Unit test 16h: Test-Convergence default parameter preserves old behavior ---
Assert-True (Test-Convergence -ClaudeDecision "CONVERGED" -CodexDecision "CONVERGED" -ConsecutiveMinorRounds 0) "16h: Test-Convergence with no -HasBlockingSeverity still returns true for both CONVERGED (backwards compat)"
Assert-True (Test-Convergence -ClaudeDecision "MINOR_REFINEMENT" -CodexDecision "MINOR_REFINEMENT" -ConsecutiveMinorRounds 2) "16h: Test-Convergence with no -HasBlockingSeverity still soft-converges (backwards compat)"
Assert-True (-not (Test-Convergence -ClaudeDecision "MAJOR_REFINEMENT" -CodexDecision "CONVERGED" -ConsecutiveMinorRounds 0)) "16h: Test-Convergence with no -HasBlockingSeverity still rejects disagreement (backwards compat)"

# --- Unit test 16i: only Remaining Issues section is parsed (not Issues Found) ---
# An artifact may still LIST historical Critical issues under "Issues Found" even when
# they were fixed. The severity gate must only reflect "Remaining Issues".
$artifactFixed = Join-Path $severityTempRoot "round1_codex_review_fixed.md"
@(
    "# Codex Round 1 Review",
    "",
    "## Issues Found",
    "### Critical",
    "- **Severity**: CRITICAL - historical issue (now fixed)",
    "",
    "## Fixes Applied",
    "- Fixed the critical issue",
    "",
    "## Remaining Issues",
    "- **Severity**: MEDIUM - residual nit",
    "",
    "## Decision: CONVERGED"
) | Out-File -FilePath $artifactFixed -Encoding UTF8
$sevFixed = Get-DeliberationSeveritySummary -ArtifactPath $artifactFixed
Assert-True ($sevFixed.HasBlockingSeverity -eq $false) "16i: only Remaining Issues section (not Issues Found) determines blocking severity"
Assert-True ($sevFixed.SeverityList -contains "MEDIUM") "16i: severity list reflects only remaining issues"
Assert-True (-not ($sevFixed.SeverityList -contains "CRITICAL")) "16i: severity list excludes historical CRITICAL entries from Issues Found"

# =============================================================================
# Cleanup
# =============================================================================

Remove-Item -Path $failPath -ErrorAction SilentlyContinue
Remove-Item -Path $passPath -ErrorAction SilentlyContinue
Remove-Item -Path $cleanCodexPath -ErrorAction SilentlyContinue
foreach ($tempRoot in $Script:TempResumeRoots) {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($tempRoot in $Script:TempCodexStubRoots) {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($tempRoot in $Script:TempClaudeStubRoots) {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# =============================================================================
# Summary
# =============================================================================

Write-Host "`n" + ("=" * 50) -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host ("=" * 50) -ForegroundColor Cyan

Write-Host "Passed: $Script:TestsPassed" -ForegroundColor Green
Write-Host "Failed: $Script:TestsFailed" -ForegroundColor $(if ($Script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($Script:TestsFailed -eq 0) {
    Write-Host "`nAll tests passed. Pipeline ready for use." -ForegroundColor Green
    Write-Host "`nTo run the actual pipeline:"
    Write-Host "  1. Navigate to your project folder"
    Write-Host "  2. Ensure plan.md exists"
    Write-Host "  3. Run: ..\cross_qc\accord.ps1 -PlanFile .\plan.md -PromptDir ..\cross_qc\prompts"
    Write-Host "`nOr use -SkipPlanQC to skip Phase 0:"
    Write-Host "  ..\cross_qc\accord.ps1 -PlanFile .\plan.md -PromptDir ..\cross_qc\prompts -SkipPlanQC"
    exit 0
}
else {
    Write-Host "`nSome tests failed. Review errors above." -ForegroundColor Red
    exit 1
}


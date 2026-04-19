<#
.SYNOPSIS
    Cross-QC Pipeline - Cross-model code quality assurance

.DESCRIPTION
    Claude Code writes code, Codex QCs it, Claude Code fixes issues, repeat until clean.
    v1.6: Added -DeliberationMode for collaborative Claude+Codex deliberation.
    v1.5: Added -ClaudeQCIterations for hybrid QC mode (Claude first, then Codex).
    v1.4: Added -QCType parameter for document mode (code vs document QC).
    v1.3: Added Phase 0 (Plan QC) to review plans before implementation.
    v1.2: Added anti-oscillation context tracking between iterations.

.PARAMETER PlanFile
    Path to the implementation plan (.md file)

.PARAMETER MaxIterations
    Maximum code QC iterations before giving up (default: 10)

.PARAMETER MaxPlanQCIterations
    Maximum plan QC iterations before giving up (default: 5)

.PARAMETER SkipPlanQC
    Skip Phase 0 (plan review) for trusted plans

.PARAMETER PromptDir
    Directory containing prompt templates (default: script_dir\prompts)

.PARAMETER Help
    Show help message and exit

.PARAMETER QCType
    QC mode: "code" (default) for code implementation, "document" for document generation

.PARAMETER ClaudeQCIterations
    Number of initial QC iterations to use Claude Code before switching to Codex (default: 0)

.PARAMETER DeliberationMode
    Enable deliberation mode where Claude and Codex collaborate through iterative
    "thinking" and "evaluation" until convergence. Replaces standard QC loops.
    - Document mode: Claude writes + thinks, Codex evaluates, alternate until converged
    - Code mode: Claude implements + thinks, Codex reviews, alternate until converged

.PARAMETER MaxDeliberationRounds
    Maximum deliberation rounds before stopping (default: 4, range: 2-10)
    Each round consists of one Claude turn and one Codex turn.

.PARAMETER MetaReview
    Review the selected meta-plan file against the bundled plan_for_meta_plan.md checklist.
    Writes a sibling *.reviewed.md file and keeps the original file unchanged.

.EXAMPLE
    .\accord.ps1 -PlanFile "plan.md"
    # Standard mode: Claude writes, Codex QCs, Claude fixes

.EXAMPLE
    .\accord.ps1 -PlanFile "plan.md" -SkipPlanQC

.EXAMPLE
    .\accord.ps1 -PlanFile "plan.md" -MaxPlanQCIterations 3 -MaxIterations 5

.EXAMPLE
    .\accord.ps1 -PlanFile "meta_plan.md" -QCType document -DeliberationMode
    # Document deliberation: Claude and Codex collaborate on continuation plan

.EXAMPLE
    .\accord.ps1 -PlanFile "cycles\<session_id>\CONTINUATION_CYCLE_14.md" -DeliberationMode
    # Code deliberation: Claude and Codex collaborate on implementation

.EXAMPLE
    .\accord.ps1 -PlanFile "plan.md" -DeliberationMode -MaxDeliberationRounds 6
    # Deliberation with custom max rounds

.EXAMPLE
    .\accord.ps1 -PlanFile "meta_plan.md" -QCType document -MetaReview -SkipPlanQC
    # Review the selected meta plan against the bundled checklist and write meta_plan.reviewed.md

.EXAMPLE
    .\accord.ps1 -Help
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [ValidateScript({
            $resolvedPath = if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path (Get-Location) $_ }
            if (Test-Path $resolvedPath -PathType Leaf) { $true }
            else { throw "Plan file not found: $resolvedPath" }
        })]
    [string]$PlanFile,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MaxIterations = 10,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 20)]
    [int]$MaxPlanQCIterations = 5,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPlanQC,

    [Parameter(Mandatory = $false)]
    [string]$PromptDir = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "prompts" } else { "" }),

    [Parameter(Mandatory = $false)]
    [Alias("?")]
    [switch]$Help,

    [Parameter(Mandatory = $false)]
    [ValidateSet("code", "document")]
    [string]$QCType = "code",

    [Parameter(Mandatory = $false)]
    [switch]$PassOnMediumOnly,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [int]$HistoryIterations = 2,

    [Parameter(Mandatory = $false)]
    [ValidateSet("low", "medium", "high", "xhigh")]
    [string]$ReasoningEffort = "xhigh",

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 20)]
    [int]$ClaudeQCIterations = 0,

    [Parameter(Mandatory = $false)]
    [switch]$DeliberationMode,

    [Parameter(Mandatory = $false)]
    [ValidateRange(2, 10)]
    [int]$MaxDeliberationRounds = 4,

    [Parameter(Mandatory = $false)]
    [switch]$ResumeFromFailure,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 10)]
    [int]$MaxRetries = 3,

    [Parameter(Mandatory = $false)]
    [ValidateRange(5, 300)]
    [int]$RetryDelaySec = 30,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 3600)]
    [int]$AgentTimeoutSec = 900,

    [Parameter(Mandatory = $false)]
    [switch]$MetaReview,

    [Parameter(Mandatory = $false)]
    [string]$MetaReviewTargetFile = "",

    [Parameter(Mandatory = $false)]
    [string]$MetaReviewChecklistFile = "",

    [Parameter(Mandatory = $false)]
    [string]$MetaReviewOutputFile = ""
)

# =============================================================================
# Configuration
# =============================================================================

$Script:CurrentIteration = 0
$Script:CurrentPlanQCIteration = 0
$Script:ProjectRoot = ""
$Script:SessionId = ""
$Script:LogsRoot = ""
$Script:SessionLogsDir = ""
$Script:CyclesRoot = ""
$Script:SessionCyclesDir = ""
$Script:CycleStatusFile = ""
$Script:MetaReviewTargetFile = ""
$Script:MetaReviewChecklistFile = ""
$Script:MetaReviewOutputFile = ""
$Script:ScriptRootDir = if ($PSScriptRoot) {
    $PSScriptRoot
}
elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    (Get-Location).Path
}
$Script:DefaultPromptDir = Join-Path $Script:ScriptRootDir "prompts"
$Script:PromptFileNames = @(
    "claude_write_prompt.md",
    "codex_qc_prompt.md",
    "claude_fix_prompt.md",
    "codex_plan_qc_prompt.md",
    "claude_plan_fix_prompt.md",
    "claude_write_doc_prompt.md",
    "codex_qc_doc_prompt.md",
    "claude_write_meta_review_prompt.md",
    "codex_qc_meta_review_relay_prompt.md",
    "codex_qc_meta_review_prompt.md",
    "claude_fix_meta_review_prompt.md",
    "claude_reconcile_meta_review_prompt.md",
    "claude_deliberate_doc_initial_prompt.md",
    "claude_deliberate_doc_refine_prompt.md",
    "codex_deliberate_doc_prompt.md",
    "claude_deliberate_code_initial_prompt.md",
    "claude_deliberate_code_refine_prompt.md",
    "codex_deliberate_code_prompt.md"
)
$Script:PromptDirResolved = ""

# Prompt template paths - populated after prompt dir resolution in Start-CrossQCPipeline
$Script:WritePrompt = ""
$Script:QCPrompt = ""
$Script:FixPrompt = ""
$Script:PlanQCPrompt = ""
$Script:PlanFixPrompt = ""
$Script:DocWritePrompt = ""
$Script:DocQCPrompt = ""
$Script:MetaReviewWritePrompt = ""
$Script:MetaReviewRelayQCPrompt = ""
$Script:MetaReviewQCPrompt = ""
$Script:MetaReviewFixPrompt = ""
$Script:MetaReviewReconcilePrompt = ""
$Script:DeliberateDocInitialPrompt = ""
$Script:DeliberateDocRefinePrompt = ""
$Script:DeliberateDocQCPrompt = ""
$Script:DeliberateCodeInitialPrompt = ""
$Script:DeliberateCodeRefinePrompt = ""
$Script:DeliberateCodeQCPrompt = ""

# Track issues across iterations for anti-oscillation
$Script:AllIssuesHistory = ""
$Script:AllPlanIssuesHistory = ""
$Script:MetaReviewReplacementDraftFile = ""

# =============================================================================
# Timestamp Functions
# =============================================================================

function Get-Timestamp {
    return Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
}

function Get-TimestampReadable {
    return Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}

# Initialize timestamped file names
$Script:PipelineStartTime = if ($env:CROSS_QC_PIPELINE_START_TIME) { $env:CROSS_QC_PIPELINE_START_TIME } else { Get-Timestamp }
$Script:LogsDir = ""  # Set in Start-CrossQCPipeline after resolving working directory
$Script:QCReportBase = "qc_report"
$Script:PlanQCReportBase = "plan_qc_report"
$Script:QCLogFile = ""
$Script:CurrentQCReport = ""
$Script:CurrentPlanQCReport = ""
$Script:DeliberationDocPath = ""
$Script:RunStateFile = ""
$Script:EventsFile = ""
$Script:RunState = [ordered]@{}
$Script:ClaudeSupportsEffort = $null
$Script:ClaudeSupportsEffortCommandPath = ""

# =============================================================================
# Logging Functions
# =============================================================================

function Write-LogLineToFile {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Script:QCLogFile)) {
        return
    }

    $Line | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8
}

function Get-IsoTimestamp {
    return (Get-Date).ToString("o")
}

function Write-TextFileAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $tempPath = "$Path.tmp"
    [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.Encoding]::UTF8)
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Force
    }
    Move-Item -Path $tempPath -Destination $Path -Force
}

function Save-RunState {
    if ([string]::IsNullOrWhiteSpace($Script:RunStateFile)) {
        return
    }

    try {
        $json = $Script:RunState | ConvertTo-Json -Depth 10
        Write-TextFileAtomic -Path $Script:RunStateFile -Content ($json + [Environment]::NewLine)
    }
    catch {
        # Telemetry failures should never block the pipeline.
    }
}

function Update-RunState {
    param([hashtable]$Updates)

    if (-not $Script:RunState) {
        $Script:RunState = [ordered]@{}
    }

    foreach ($key in $Updates.Keys) {
        $Script:RunState[$key] = $Updates[$key]
    }

    $Script:RunState.updatedAt = Get-IsoTimestamp
    Save-RunState
}

function Write-RunEvent {
    param(
        [string]$Type,
        [string]$Level = "info",
        [hashtable]$Data = @{}
    )

    if ([string]::IsNullOrWhiteSpace($Script:EventsFile)) {
        return
    }

    try {
        $eventRecord = [ordered]@{
            timestamp = Get-IsoTimestamp
            pipelineId = $Script:PipelineStartTime
            sessionId = $Script:SessionId
            type = $Type
            level = $Level
            phase = $(if ($Script:RunState.Contains("phase")) { $Script:RunState.phase } else { "" })
            status = $(if ($Script:RunState.Contains("status")) { $Script:RunState.status } else { "" })
            currentIteration = $Script:CurrentIteration
            currentPlanQCIteration = $Script:CurrentPlanQCIteration
            currentDeliberationRound = $(if ($Script:RunState.Contains("currentDeliberationRound")) { $Script:RunState.currentDeliberationRound } else { 0 })
            data = $Data
        }

        ($eventRecord | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path $Script:EventsFile -Encoding UTF8
    }
    catch {
        # Telemetry failures should never block the pipeline.
    }
}

function Initialize-RunTelemetry {
    $Script:RunStateFile = Join-Path $Script:SessionLogsDir "run_state.json"
    $Script:EventsFile = Join-Path $Script:SessionLogsDir "events.ndjson"

    if (-not (Test-Path $Script:EventsFile -PathType Leaf)) {
        New-Item -ItemType File -Path $Script:EventsFile -Force | Out-Null
    }

    $now = Get-IsoTimestamp
    $Script:RunState = [ordered]@{
        schemaVersion = 1
        pipelineId = $Script:PipelineStartTime
        sessionId = $Script:SessionId
        status = "initializing"
        phase = "startup"
        currentAction = "bootstrapping"
        currentTool = ""
        currentIteration = 0
        currentPlanQCIteration = 0
        currentDeliberationRound = 0
        qcType = $QCType
        metaReview = [bool]$MetaReview
        metaReviewTargetFile = $Script:MetaReviewTargetFile
        metaReviewChecklistFile = $Script:MetaReviewChecklistFile
        metaReviewOutputFile = $Script:MetaReviewOutputFile
        deliberationMode = [bool]$DeliberationMode
        resumeFromFailure = [bool]$ResumeFromFailure
        maxIterations = $MaxIterations
        maxPlanQCIterations = $MaxPlanQCIterations
        maxDeliberationRounds = $MaxDeliberationRounds
        maxRetries = $MaxRetries
        retryDelaySec = $RetryDelaySec
        agentTimeoutSec = $AgentTimeoutSec
        skipPlanQC = [bool]$SkipPlanQC
        passOnMediumOnly = [bool]$PassOnMediumOnly
        historyIterations = $HistoryIterations
        reasoningEffort = $ReasoningEffort
        claudeQCIterations = $ClaudeQCIterations
        planFile = $Script:PlanFileResolved
        planTitle = $(if ($env:CROSS_QC_PLAN_TITLE) { $env:CROSS_QC_PLAN_TITLE } else { "" })
        promptDir = $Script:PromptDirResolved
        logsRoot = $Script:LogsRoot
        logsDir = $Script:SessionLogsDir
        cyclesRoot = $Script:CyclesRoot
        cyclesDir = $Script:SessionCyclesDir
        logFile = $Script:QCLogFile
        historyFile = $Script:HistoryFile
        cycleStatusFile = $Script:CycleStatusFile
        currentQCReport = ""
        currentPlanQCReport = ""
        currentArtifact = ""
        currentArtifactType = ""
        childPid = $PID
        lastMessage = ""
        lastError = ""
        startedAt = $now
        updatedAt = $now
        completedAt = ""
        exitCode = $null
    }

    Save-RunState
}

function Complete-Pipeline {
    param(
        [string]$Message,
        [hashtable]$Data = @{}
    )

    $payload = @{}
    foreach ($key in $Data.Keys) {
        $payload[$key] = $Data[$key]
    }
    $payload.message = $Message

    Update-RunState @{
        status = "completed"
        currentAction = ""
        currentTool = ""
        completedAt = Get-IsoTimestamp
        exitCode = 0
        lastMessage = $Message
    }
    Write-RunEvent -Type "pipeline_completed" -Data $payload
    exit 0
}

function Fail-Pipeline {
    param(
        [string]$Message,
        [hashtable]$Data = @{}
    )

    $payload = @{}
    foreach ($key in $Data.Keys) {
        $payload[$key] = $Data[$key]
    }
    $payload.message = $Message

    $failPhase = if ($Data.ContainsKey("phase") -and $Data.phase) { $Data.phase } elseif ($Script:RunState -and $Script:RunState.Contains("phase")) { $Script:RunState.phase } else { "failed" }
    Update-RunState @{
        status = "failed"
        phase = $failPhase
        currentAction = ""
        currentTool = ""
        completedAt = Get-IsoTimestamp
        exitCode = 1
        lastError = $Message
        lastMessage = $Message
    }
    Write-RunEvent -Type "pipeline_failed" -Level "error" -Data $payload
    exit 1
}

function Write-LogInfo {
    param([string]$Message)
    Write-Host "[INFO] " -ForegroundColor Blue -NoNewline
    Write-Host $Message
    Write-LogLineToFile "[$((Get-TimestampReadable))] [INFO] $Message"
    Update-RunState @{ lastMessage = $Message }
}

function Write-LogSuccess {
    param([string]$Message)
    Write-Host "[SUCCESS] " -ForegroundColor Green -NoNewline
    Write-Host $Message
    Write-LogLineToFile "[$((Get-TimestampReadable))] [SUCCESS] $Message"
    Update-RunState @{ lastMessage = $Message }
}

function Write-LogWarn {
    param([string]$Message)
    Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
    Write-LogLineToFile "[$((Get-TimestampReadable))] [WARN] $Message"
    Update-RunState @{ lastMessage = $Message }
}

function Write-LogError {
    param([string]$Message)
    Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
    Write-Host $Message
    Write-LogLineToFile "[$((Get-TimestampReadable))] [ERROR] $Message"
    Update-RunState @{ lastMessage = $Message; lastError = $Message }
}

function Write-LogHeader {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-LogLineToFile "`n$("=" * 60)`n$Message`n$("=" * 60)"
    Update-RunState @{ lastMessage = $Message }
}

# =============================================================================
# Path and Template Functions
# =============================================================================

function Resolve-PromptDirectory {
    param([string]$RequestedPromptDir)

    $resolveCandidate = {
        param([string]$PathValue)
        if ([System.IO.Path]::IsPathRooted($PathValue)) {
            return [System.IO.Path]::GetFullPath($PathValue)
        }
        return [System.IO.Path]::GetFullPath((Join-Path $Script:ProjectRoot $PathValue))
    }

    $hasAllPromptFiles = {
        param([string]$DirectoryPath)
        if (-not (Test-Path $DirectoryPath -PathType Container)) {
            return $false
        }

        foreach ($promptFile in $Script:PromptFileNames) {
            if (-not (Test-Path (Join-Path $DirectoryPath $promptFile) -PathType Leaf)) {
                return $false
            }
        }

        return $true
    }

    if ([string]::IsNullOrWhiteSpace($RequestedPromptDir)) {
        return $Script:DefaultPromptDir
    }

    $requestedPath = & $resolveCandidate $RequestedPromptDir
    if (& $hasAllPromptFiles $requestedPath) {
        return $requestedPath
    }

    $requestedPromptsChild = Join-Path $requestedPath "prompts"
    if (& $hasAllPromptFiles $requestedPromptsChild) {
        return $requestedPromptsChild
    }

    return $requestedPath
}

function Initialize-PromptPaths {
    param([string]$ResolvedPromptDir)

    $Script:PromptDirResolved = $ResolvedPromptDir
    $PromptDir = $ResolvedPromptDir

    $Script:WritePrompt = Join-Path $PromptDir "claude_write_prompt.md"
    $Script:QCPrompt = Join-Path $PromptDir "codex_qc_prompt.md"
    $Script:FixPrompt = Join-Path $PromptDir "claude_fix_prompt.md"
    $Script:PlanQCPrompt = Join-Path $PromptDir "codex_plan_qc_prompt.md"
    $Script:PlanFixPrompt = Join-Path $PromptDir "claude_plan_fix_prompt.md"
    $Script:DocWritePrompt = Join-Path $PromptDir "claude_write_doc_prompt.md"
    $Script:DocQCPrompt = Join-Path $PromptDir "codex_qc_doc_prompt.md"
    $Script:MetaReviewWritePrompt = Join-Path $PromptDir "claude_write_meta_review_prompt.md"
    $Script:MetaReviewRelayQCPrompt = Join-Path $PromptDir "codex_qc_meta_review_relay_prompt.md"
    $Script:MetaReviewQCPrompt = Join-Path $PromptDir "codex_qc_meta_review_prompt.md"
    $Script:MetaReviewFixPrompt = Join-Path $PromptDir "claude_fix_meta_review_prompt.md"
    $Script:MetaReviewReconcilePrompt = Join-Path $PromptDir "claude_reconcile_meta_review_prompt.md"
    $Script:DeliberateDocInitialPrompt = Join-Path $PromptDir "claude_deliberate_doc_initial_prompt.md"
    $Script:DeliberateDocRefinePrompt = Join-Path $PromptDir "claude_deliberate_doc_refine_prompt.md"
    $Script:DeliberateDocQCPrompt = Join-Path $PromptDir "codex_deliberate_doc_prompt.md"
    $Script:DeliberateCodeInitialPrompt = Join-Path $PromptDir "claude_deliberate_code_initial_prompt.md"
    $Script:DeliberateCodeRefinePrompt = Join-Path $PromptDir "claude_deliberate_code_refine_prompt.md"
    $Script:DeliberateCodeQCPrompt = Join-Path $PromptDir "codex_deliberate_code_prompt.md"
}

function Get-ReviewedMetaPlanOutputPath {
    param([string]$TargetFile)

    $resolvedTarget = [System.IO.Path]::GetFullPath($TargetFile)
    $directory = Split-Path -Parent $resolvedTarget
    $extension = [System.IO.Path]::GetExtension($resolvedTarget)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedTarget)
    $reviewedFileName = if ([string]::IsNullOrWhiteSpace($extension)) {
        "$baseName.reviewed.md"
    }
    else {
        "$baseName.reviewed$extension"
    }

    return Join-Path $directory $reviewedFileName
}

function Initialize-MetaReviewSettings {
    if (-not $MetaReview) {
        $Script:MetaReviewTargetFile = ""
        $Script:MetaReviewChecklistFile = ""
        $Script:MetaReviewOutputFile = ""
        $Script:MetaReviewReplacementDraftFile = ""
        return
    }

    $targetFile = if ([string]::IsNullOrWhiteSpace($MetaReviewTargetFile)) {
        $Script:PlanFileResolved
    }
    else {
        [System.IO.Path]::GetFullPath($MetaReviewTargetFile)
    }

    $checklistFile = if ([string]::IsNullOrWhiteSpace($MetaReviewChecklistFile)) {
        [System.IO.Path]::GetFullPath((Join-Path $Script:ScriptRootDir "plan_for_meta_plan.md"))
    }
    else {
        [System.IO.Path]::GetFullPath($MetaReviewChecklistFile)
    }

    $outputFile = if ([string]::IsNullOrWhiteSpace($MetaReviewOutputFile)) {
        Get-ReviewedMetaPlanOutputPath -TargetFile $targetFile
    }
    else {
        [System.IO.Path]::GetFullPath($MetaReviewOutputFile)
    }

    if ($targetFile.Equals($checklistFile, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Meta review target cannot be the bundled checklist file."
    }

    $Script:MetaReviewTargetFile = $targetFile
    $Script:MetaReviewChecklistFile = $checklistFile
    $Script:MetaReviewOutputFile = $outputFile
    $Script:MetaReviewReplacementDraftFile = ""
}

function Get-SessionIdFromPlanFile {
    param([string]$PlanFilePath)

    if (-not [string]::IsNullOrWhiteSpace($env:CROSS_QC_SESSION_ID)) {
        return $env:CROSS_QC_SESSION_ID.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($Script:CyclesRoot)) {
        return $Script:PipelineStartTime
    }

    $cyclesRootPath = [System.IO.Path]::GetFullPath($Script:CyclesRoot)
    $planFilePath = [System.IO.Path]::GetFullPath($PlanFilePath)
    $cyclesPrefix = $cyclesRootPath.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

    if ($planFilePath.StartsWith($cyclesPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relativePath = $planFilePath.Substring($cyclesPrefix.Length)
        if ($relativePath -match '^(?<session>[^\\/]+)[\\/](CONTINUATION_CYCLE_\d+\.md)$') {
            return $Matches.session
        }
    }

    return $Script:PipelineStartTime
}

function Apply-CommonTemplatePlaceholders {
    param([string]$Content)

    $replacements = [ordered]@{
        '{{SESSION_ID}}' = $(if ($Script:SessionId) { $Script:SessionId } else { "" })
        '{{LOGS_DIR}}' = $(if ($Script:SessionLogsDir) { $Script:SessionLogsDir } else { "" })
        '{{CYCLES_DIR}}' = $(if ($Script:CyclesRoot) { $Script:CyclesRoot } else { "" })
        '{{HISTORY_FILE}}' = $(if ($Script:HistoryFile) { $Script:HistoryFile } else { "" })
        '{{CYCLE_STATUS_FILE}}' = $(if ($Script:CyclesRoot) { Join-Path $Script:CyclesRoot "_CYCLE_STATUS.json" } else { "" })
        '{{META_REVIEW_TARGET_FILE}}' = $(if ($Script:MetaReviewTargetFile) { $Script:MetaReviewTargetFile } else { "" })
        '{{META_REVIEW_CHECKLIST_FILE}}' = $(if ($Script:MetaReviewChecklistFile) { $Script:MetaReviewChecklistFile } else { "" })
        '{{META_REVIEW_OUTPUT_FILE}}' = $(if ($Script:MetaReviewOutputFile) { $Script:MetaReviewOutputFile } else { "" })
        '{{META_REVIEW_REPLACEMENT_DRAFT_FILE}}' = $(if ($Script:MetaReviewReplacementDraftFile) { $Script:MetaReviewReplacementDraftFile } else { "" })
        '{{META_REVIEW_QC_REPORT_FILE}}' = $(if ($Script:CurrentQCReport) { $Script:CurrentQCReport } else { "" })
    }

    foreach ($entry in $replacements.GetEnumerator()) {
        $Content = $Content.Replace($entry.Key, $entry.Value)
    }

    return $Content
}

function Get-MetaReviewTargetWorkspaceDir {
    $candidateContents = @()
    foreach ($path in @($Script:MetaReviewOutputFile, $Script:MetaReviewTargetFile)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path -PathType Leaf)) {
            $candidateContents += Get-Content -Path $path -Raw
        }
    }

    foreach ($content in $candidateContents) {
        if ([string]::IsNullOrWhiteSpace($content)) {
            continue
        }

        foreach ($pattern in @(
                '(?im)^\s*(?:-+\s*)?(?:\*\*)?(?:Project (?:Location|Root|Directory)|Workspace (?:Root|Directory))(?:\*\*)?\s*:\s*`?(?<path>[^`\r\n]+?)`?\s*$',
                '(?im)^\s*\|\s*(?:Project (?:Location|Root|Directory)|Workspace (?:Root|Directory))\s*\|\s*`?(?<path>[^`|]+?)`?\s*\|?\s*$'
            )) {
            $match = [regex]::Match($content, $pattern)
            if (-not $match.Success) {
                continue
            }

            $rawPath = $match.Groups['path'].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($rawPath)) {
                continue
            }

            $rawPath = $rawPath.Trim('"', "'")
            $resolvedPath = if ([System.IO.Path]::IsPathRooted($rawPath)) {
                $rawPath
            }
            elseif (-not [string]::IsNullOrWhiteSpace($Script:MetaReviewTargetFile)) {
                Join-Path (Split-Path -Path $Script:MetaReviewTargetFile -Parent) $rawPath
            }
            else {
                $rawPath
            }

            if (Test-Path $resolvedPath -PathType Container) {
                return [System.IO.Path]::GetFullPath($resolvedPath)
            }

            if (Test-Path $resolvedPath -PathType Leaf) {
                return [System.IO.Path]::GetFullPath((Split-Path -Path $resolvedPath -Parent))
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Script:MetaReviewTargetFile)) {
        return Split-Path -Path $Script:MetaReviewTargetFile -Parent
    }

    return $Script:ProjectRoot
}

function Convert-ToDisplayRelativePath {
    param(
        [string]$RootPath,
        [string]$TargetPath
    )

    if ([string]::IsNullOrWhiteSpace($RootPath) -or [string]::IsNullOrWhiteSpace($TargetPath)) {
        return $TargetPath
    }

    try {
        $relative = [System.IO.Path]::GetRelativePath($RootPath, $TargetPath)
        if ([string]::IsNullOrWhiteSpace($relative)) {
            return "."
        }
        return $relative -replace '\\', '/'
    }
    catch {
        return $TargetPath
    }
}

function Resolve-MetaReviewRepoContext {
    $workspaceDir = Get-MetaReviewTargetWorkspaceDir
    $resolvedWorkspaceDir = if ($workspaceDir) { [System.IO.Path]::GetFullPath($workspaceDir) } else { "" }
    $indexFile = Join-Path $resolvedWorkspaceDir "index.html"

    $topLevelEntries = @()
    if (Test-Path $resolvedWorkspaceDir -PathType Container) {
        $topLevelEntries = Get-ChildItem -Path $resolvedWorkspaceDir -Force -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 20
    }

    $linkedAssets = @{
        styles = @()
        scripts = @()
    }
    if (Test-Path $indexFile -PathType Leaf) {
        $indexContent = Get-Content -Path $indexFile -Raw
        foreach ($match in [regex]::Matches($indexContent, '<link[^>]+href=["'']([^"'']+)["'']', 'IgnoreCase')) {
            $linkedAssets.styles += $match.Groups[1].Value
        }
        foreach ($match in [regex]::Matches($indexContent, '<script[^>]+src=["'']([^"'']+)["'']', 'IgnoreCase')) {
            $linkedAssets.scripts += $match.Groups[1].Value
        }
    }

    $testDirs = @("tests", "test")
    $testFiles = @()
    foreach ($dirName in $testDirs) {
        $dirPath = Join-Path $resolvedWorkspaceDir $dirName
        if (Test-Path $dirPath -PathType Container) {
            $testFiles += Get-ChildItem -Path $dirPath -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            Select-Object -First 20
        }
    }

    return @{
        WorkspaceDir = $resolvedWorkspaceDir
        TopLevelEntries = @($topLevelEntries)
        LinkedStyles = @($linkedAssets.styles | Select-Object -Unique)
        LinkedScripts = @($linkedAssets.scripts | Select-Object -Unique)
        TestFiles = @($testFiles)
        HasTests = ($testFiles.Count -gt 0)
        HasIndexHtml = (Test-Path $indexFile -PathType Leaf)
    }
}

function Get-MetaReviewRepoSummary {
    $context = Resolve-MetaReviewRepoContext
    $workspaceDir = $context.WorkspaceDir
    $lines = @(
        "Workspace root: $workspaceDir",
        ""
    )

    if ($context.TopLevelEntries.Count -gt 0) {
        $lines += "Top-level entries:"
        foreach ($entry in $context.TopLevelEntries) {
            $entryType = if ($entry.PSIsContainer) { "dir" } else { "file" }
            $lines += "- [$entryType] $($entry.Name)"
        }
        $lines += ""
    }

    if ($context.HasIndexHtml) {
        $lines += "HTML entrypoint:"
        $lines += "- index.html"
        if ($context.LinkedStyles.Count -gt 0) {
            $lines += "Linked stylesheets from index.html:"
            foreach ($style in $context.LinkedStyles) {
                $lines += "- $style"
            }
        }
        if ($context.LinkedScripts.Count -gt 0) {
            $lines += "Linked scripts from index.html:"
            foreach ($scriptPath in $context.LinkedScripts) {
                $lines += "- $scriptPath"
            }
        }
        $lines += ""
    }

    if ($context.HasTests) {
        $lines += "Test files:"
        foreach ($file in $context.TestFiles) {
            $lines += "- $(Convert-ToDisplayRelativePath -RootPath $workspaceDir -TargetPath $file.FullName)"
        }
        $lines += ""
    }
    else {
        $lines += "Test files:"
        $lines += "- None detected under ./tests or ./test"
        $lines += ""
    }

    return ($lines -join "`r`n").Trim()
}

function Apply-MetaReviewPromptPlaceholders {
    param([string]$Content)

    $targetContent = if (Test-Path $Script:MetaReviewTargetFile -PathType Leaf) {
        Get-Content -Path $Script:MetaReviewTargetFile -Raw
    }
    else {
        "(Selected meta plan file not found.)"
    }
    $checklistContent = if (Test-Path $Script:MetaReviewChecklistFile -PathType Leaf) {
        Get-Content -Path $Script:MetaReviewChecklistFile -Raw
    }
    else {
        "(Meta-review checklist file not found.)"
    }
    $outputContent = if (Test-Path $Script:MetaReviewOutputFile -PathType Leaf) {
        Get-Content -Path $Script:MetaReviewOutputFile -Raw
    }
    else {
        "(Reviewed output file does not exist yet.)"
    }
    $replacementDraftContent = if (-not [string]::IsNullOrWhiteSpace($Script:MetaReviewReplacementDraftFile) -and (Test-Path $Script:MetaReviewReplacementDraftFile -PathType Leaf)) {
        Get-Content -Path $Script:MetaReviewReplacementDraftFile -Raw
    }
    else {
        "(Codex replacement draft file does not exist yet.)"
    }
    $qcReportContent = if (-not [string]::IsNullOrWhiteSpace($Script:CurrentQCReport) -and (Test-Path $Script:CurrentQCReport -PathType Leaf)) {
        Get-Content -Path $Script:CurrentQCReport -Raw
    }
    else {
        "(Current meta-review QC report does not exist yet.)"
    }
    $repoSummary = Get-MetaReviewRepoSummary
    $blockedPatternsSummary = Get-MetaReviewBlockedPatternsSummary

    $replacements = [ordered]@{
        '{{META_REVIEW_TARGET_CONTENT}}' = $targetContent
        '{{META_REVIEW_CHECKLIST_CONTENT}}' = $checklistContent
        '{{META_REVIEW_OUTPUT_CONTENT}}' = $outputContent
        '{{META_REVIEW_REPLACEMENT_DRAFT_CONTENT}}' = $replacementDraftContent
        '{{META_REVIEW_QC_REPORT_CONTENT}}' = $qcReportContent
        '{{META_REVIEW_REPO_SUMMARY}}' = $repoSummary
        '{{META_REVIEW_BLOCKED_PATTERNS}}' = $blockedPatternsSummary
    }

    foreach ($entry in $replacements.GetEnumerator()) {
        $Content = $Content.Replace($entry.Key, $entry.Value)
    }

    return $Content
}

# =============================================================================
# Help Function
# =============================================================================

function Show-Help {
    $helpText = @"
Cross-QC Pipeline v1.6 - Claude + Codex Code Quality Automation (Deliberation Mode)

USAGE:
    .\accord.ps1 -PlanFile <path> [options]

REQUIRED:
    -PlanFile <path>          Path to implementation plan (.md file)

OPTIONS:
    -MaxIterations <n>        Max code QC iterations (default: 10, range: 1-100)
    -MaxPlanQCIterations <n>  Max plan QC iterations (default: 5, range: 1-20)
    -SkipPlanQC               Skip Phase 0 (plan review) for trusted plans
    -PromptDir <path>         Directory containing prompt templates (default: $($Script:DefaultPromptDir))
    -QCType <code|document>   QC mode: "code" (default) or "document"
    -PassOnMediumOnly         Pass QC if only MEDIUM/LOW severity issues remain (saves tokens)
    -HistoryIterations <n>    Keep only last N iterations in history (default: 2, saves tokens)
    -ReasoningEffort <level>  Codex reasoning: low|medium|high|xhigh (default: xhigh for iter1, high for iter2+)
    -ClaudeQCIterations <n>   Use Claude Code for first N QC iterations, then Codex (default: 0 = Codex only)
    -DeliberationMode         Enable collaborative Claude+Codex deliberation mode
    -AgentTimeoutSec <sec>    Per-agent timeout for bounded flows (default: 900)
    -MaxDeliberationRounds <n> Max deliberation rounds (default: 4, range: 2-10)
    -ResumeFromFailure        Resume a failed deliberation session from the last saved round state
    -MetaReview              Review the selected meta plan with bounded deterministic validation + semantic QC
    -Help, -?                 Show this help message

    DELIBERATION MODE:
    Claude and Codex collaborate through iterative "thinking" and "evaluation":
    - Claude writes/implements + documents its thinking
    - Codex evaluates + provides feedback
    - Claude responds + refines based on feedback
    - Repeat until both agents converge (agree no changes needed)

    Anti-oscillation: Full history is passed to prevent contradicting previous decisions
    Convergence: Achieved when both say CONVERGED or after 2+ MINOR_REFINEMENT rounds.
                 Severity gate: CRITICAL/HIGH issues in Codex's "## Remaining Issues"
                 section veto convergence (MEDIUM/LOW may converge).

    Document deliberation: .\accord.ps1 -PlanFile "meta_plan.md" -QCType document -DeliberationMode
    Code deliberation:     .\accord.ps1 -PlanFile "cycles\<session_id>\CONTINUATION_CYCLE_14.md" -DeliberationMode
    Resume failed session: .\accord.ps1 -PlanFile "meta_plan.md" -QCType document -DeliberationMode -ResumeFromFailure

    HYBRID QC MODE:
    -ClaudeQCIterations 3     Claude does QC for iterations 1-3, Codex for 4+
    -ClaudeQCIterations 5     Claude does QC for iterations 1-5, Codex for 6+

    Why use hybrid mode?
    - Claude Code is faster for initial iterations
    - Codex provides thorough final verification
    - Reduces total iteration count and cost

    TOKEN ECONOMY:
    -PassOnMediumOnly         Exits early if no CRITICAL/HIGH issues (biggest saver)
    -HistoryIterations 2      Keeps only recent context, reduces prompt size ~30%
    -ReasoningEffort high     Uses less compute for iterations 2+ (~20% faster)

    QC TYPES:
    code      (default)       Code implementation QC - Claude writes code, Codex reviews
    document                  Document generation QC - Claude generates documents, Codex reviews

    META REVIEW MODE:
    -MetaReview              Dedicated bounded workflow for reviewed meta plans
                             Claude write/fix runs with --effort max when supported by installed CLI
                             Deterministic validator runs before semantic QC
                             Codex semantic review is capped at 2 passes and forced to xhigh
                             codex review is not automated; use it manually only for optional Git diff checks

    PHASES:
    Phase 0: Plan QC          Codex reviews plan for completeness, clarity, feasibility
    Phase 1: Implementation   Claude implements code/document from plan
    Phase 2: QC Loop          Codex reviews output, Claude fixes issues, repeat until clean

EXAMPLES:
    # Code QC (default)
    .\accord.ps1 -PlanFile "plan.md"
    .\accord.ps1 -PlanFile "plan.md" -SkipPlanQC
    .\accord.ps1 -PlanFile "plan.md" -MaxPlanQCIterations 3 -MaxIterations 5

    # Document QC
    .\accord.ps1 -PlanFile "meta_plan.md" -QCType document -SkipPlanQC

    # Meta-plan review (writes meta_plan.reviewed.md next to the selected file)
    .\accord.ps1 -PlanFile "meta_plan.md" -QCType document -MetaReview -SkipPlanQC

    # Two-stage workflow
    .\accord.ps1 -PlanFile "meta_plan.md" -QCType document      # Stage 1: Generate cycle plan
    .\accord.ps1 -PlanFile "cycles\<session_id>\CONTINUATION_CYCLE_11.md"  # Stage 2: Implement code

    # Hybrid QC mode (Claude first, then Codex)
    .\accord.ps1 -PlanFile "plan.md" -ClaudeQCIterations 3      # Claude QC for 1-3, Codex for 4+
    .\accord.ps1 -PlanFile "meta_plan.md" -QCType document -ClaudeQCIterations 5

PROMPT FILES:
    Code mode:
        prompts\claude_write_prompt.md      - Code implementation prompt
        prompts\codex_qc_prompt.md          - Code QC review prompt
        prompts\claude_fix_prompt.md        - Code fix prompt

    Document mode:
        prompts\claude_write_doc_prompt.md  - Document generation prompt
        prompts\codex_qc_doc_prompt.md      - Document QC review prompt
        prompts\claude_fix_prompt.md        - Document fix prompt (shared)

    Meta review mode:
        prompts\claude_write_meta_review_prompt.md  - Strengthen the selected meta plan using the checklist
        prompts\codex_qc_meta_review_prompt.md      - QC the reviewed meta plan against the checklist
        prompts\claude_fix_meta_review_prompt.md    - Fix the reviewed meta plan in place

    Plan QC (Phase 0):
        prompts\codex_plan_qc_prompt.md     - Plan QC review prompt
        prompts\claude_plan_fix_prompt.md   - Plan fix prompt

OUTPUT:
    logs\<session_id>\qc_log_<timestamp>.txt         - Full pipeline log
    logs\<session_id>\run_state.json                - Machine-readable run status for Electron UI
    logs\<session_id>\events.ndjson                 - Machine-readable event stream for Electron UI
    logs\<session_id>\qc_report_iter<N>_<ts>.md      - Code QC reports
    logs\<session_id>\doc_qc_report_iter<N>_<ts>.md  - Document QC reports
    logs\<session_id>\plan_qc_report_iter<N>_<ts>.md - Plan QC reports (Phase 0)
    logs\<session_id>\_iteration_history.md          - Anti-oscillation tracking
    <selected-plan>.reviewed.md                      - Reviewed meta plan output (MetaReview only)

    Deliberation mode output:
    logs\<session_id>\deliberation\phase0\   - Document deliberation files
        roundN_claude_thoughts.md            - Claude's thinking each round
        roundN_codex_evaluation.md           - Codex's evaluation each round
        deliberation_summary.md              - Final summary
    logs\<session_id>\deliberation\phase1\   - Code deliberation files
        roundN_claude_thoughts.md            - Claude's thinking each round
        roundN_codex_review.md               - Codex's review each round
        deliberation_summary.md              - Final summary
    cycles\<session_id>\CONTINUATION_CYCLE_<N>.md   - Generated continuation plans
    cycles\<session_id>\_CYCLE_STATUS.json          - Session-local cycle numbering state
"@
    Write-Host $helpText
}

# =============================================================================
# Dependency Check
# =============================================================================

function Test-Dependencies {
    param(
        [switch]$IncludePlanQC = $true
    )

    Update-RunState @{
        status = "running"
        phase = "setup"
        currentAction = "dependency_check"
    }
    Write-RunEvent -Type "dependency_check_started" -Data @{
        includePlanQC = [bool]$IncludePlanQC
        qcType = $QCType
        message = "Checking dependencies ($QCType mode)"
    }

    $missing = @()

    # Check claude CLI
    if (-not (Get-Command "claude" -ErrorAction SilentlyContinue)) {
        $missing += "claude CLI not found. Install: https://claude.ai/code"
    }

    # Check codex CLI
    if (-not (Get-Command "codex" -ErrorAction SilentlyContinue)) {
        $missing += "codex CLI not found. Install: npm i -g @openai/codex"
    }

    # Check git (optional, for checkpoints)
    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
        Write-LogWarn "git not found. Git checkpoints will be skipped."
    }

    # Check core prompt templates based on QC type
    if ($QCType -eq "document") {
        $documentPrompts = if ($MetaReview) {
            @(
                $Script:MetaReviewWritePrompt,
                $Script:MetaReviewRelayQCPrompt,
                $Script:MetaReviewQCPrompt,
                $Script:MetaReviewFixPrompt,
                $Script:MetaReviewReconcilePrompt
            )
        }
        else {
            @($Script:DocWritePrompt, $Script:DocQCPrompt, $Script:FixPrompt)
        }

        $documentPrompts | ForEach-Object {
            if (-not (Test-Path $_)) {
                $missing += "Prompt template not found: $_"
            }
        }

        if ($MetaReview -and -not (Test-Path $Script:MetaReviewChecklistFile)) {
            $missing += "Meta review checklist not found: $($Script:MetaReviewChecklistFile)"
        }
    }
    else {
        # Code mode prompts (default)
        @($Script:WritePrompt, $Script:QCPrompt, $Script:FixPrompt) | ForEach-Object {
            if (-not (Test-Path $_)) {
                $missing += "Prompt template not found: $_"
            }
        }
    }

    # Check Plan QC prompt templates (only if Plan QC is enabled)
    if ($IncludePlanQC) {
        @($Script:PlanQCPrompt, $Script:PlanFixPrompt) | ForEach-Object {
            if (-not (Test-Path $_)) {
                $missing += "Plan QC prompt template not found: $_"
            }
        }
    }

    # Check deliberation prompt templates (only if DeliberationMode is enabled)
    if ($DeliberationMode) {
        $deliberationPrompts = @(
            $Script:DeliberateDocInitialPrompt,
            $Script:DeliberateDocRefinePrompt,
            $Script:DeliberateDocQCPrompt,
            $Script:DeliberateCodeInitialPrompt,
            $Script:DeliberateCodeRefinePrompt,
            $Script:DeliberateCodeQCPrompt
        )
        $deliberationPrompts | ForEach-Object {
            if (-not (Test-Path $_)) {
                $missing += "Deliberation prompt template not found: $_"
            }
        }
    }

    if ($missing.Count -gt 0) {
        $missing | ForEach-Object { Write-LogError $_ }
        Update-RunState @{
            status = "failed"
            phase = "setup"
            currentAction = "dependency_check"
            lastError = "Dependency check failed"
        }
        Write-RunEvent -Type "dependency_check_failed" -Level "error" -Data @{
            missing = $missing
            message = "Missing dependencies: $($missing -join ', ')"
        }
        return $false
    }

    Write-LogSuccess "All dependencies found (QC Type: $QCType)"
    Write-RunEvent -Type "dependency_check_passed" -Data @{
        qcType = $QCType
        includePlanQC = [bool]$IncludePlanQC
        message = "All dependencies found ($QCType mode)"
    }
    return $true
}

# =============================================================================
# Git Functions
# =============================================================================

function Test-GitRepository {
    try {
        $null = git rev-parse --git-dir 2>$null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function New-GitCheckpoint {
    param([string]$Message)
    
    if (Test-GitRepository) {
        try {
            git add -A 2>$null
            git commit -m "cross_qc: $Message [$($Script:PipelineStartTime)]" --allow-empty 2>$null | Out-Null
            Write-LogInfo "Git checkpoint: $Message"
            Write-RunEvent -Type "git_checkpoint_created" -Data @{ message = $Message }
        }
        catch {
            Write-LogWarn "Git commit failed: $_"
            Write-RunEvent -Type "git_checkpoint_failed" -Level "warn" -Data @{
                message = $Message
                error = $_.Exception.Message
            }
        }
    }
    else {
        Write-LogWarn "Not a git repository. Skipping checkpoint."
        Write-RunEvent -Type "git_checkpoint_skipped" -Level "warn" -Data @{ message = $Message }
    }
}

# =============================================================================
# Template Functions
# =============================================================================

function Get-SubstitutedTemplate {
    param(
        [string]$TemplatePath,
        [string]$PlanFile,
        [string]$QCIssues = "",
        [string]$PreviousIssues = "",
        [int]$Iteration = 0,
        [hashtable]$AdditionalReplacements = @{}
    )
    
    $content = Get-Content -Path $TemplatePath -Raw
    
    # Substitute placeholders using .Replace() to avoid regex interpretation
    # This prevents issues when content contains $, \, or other regex special chars
    $content = $content.Replace('{{PLAN_FILE}}', $PlanFile)
    $content = $content.Replace('{{ITERATION}}', $Iteration.ToString())
    
    if ($QCIssues) {
        $content = $content.Replace('{{QC_ISSUES}}', $QCIssues)
    }
    else {
        $content = $content.Replace('{{QC_ISSUES}}', "(No issues provided)")
    }
    
    if ($PreviousIssues) {
        $content = $content.Replace('{{PREVIOUS_ISSUES}}', $PreviousIssues)
    }
    else {
        $content = $content.Replace('{{PREVIOUS_ISSUES}}', "(First iteration - no previous issues)")
    }

    foreach ($entry in $AdditionalReplacements.GetEnumerator()) {
        $content = $content.Replace([string]$entry.Key, [string]$entry.Value)
    }

    if ($MetaReview) {
        $content = Apply-MetaReviewPromptPlaceholders -Content $content
    }

    return Apply-CommonTemplatePlaceholders -Content $content
}

# =============================================================================
# QC Type Prompt Selection
# =============================================================================

function Get-ActiveWritePrompt {
    if ($MetaReview) {
        return $Script:MetaReviewWritePrompt
    }
    if ($QCType -eq "document") {
        return $Script:DocWritePrompt
    }
    return $Script:WritePrompt
}

function Get-ActiveQCPrompt {
    if ($MetaReview) {
        return $Script:MetaReviewQCPrompt
    }
    if ($QCType -eq "document") {
        return $Script:DocQCPrompt
    }
    return $Script:QCPrompt
}

function Get-ActiveFixPrompt {
    if ($MetaReview) {
        return $Script:MetaReviewFixPrompt
    }
    return $Script:FixPrompt
}

# =============================================================================
# Issue History Functions
# =============================================================================

# History flow:
# 1. Iteration N: Codex QC runs with history from iterations 1..N-1
# 2. Codex finds issues for iteration N
# 3. Issues added to history (now contains 1..N)
# 4. Claude fixes with history context (knows what was reported)
# 5. Next iteration: Codex sees all previous issues to avoid contradictions

function Add-IssuesToHistory {
    param([string]$Issues, [int]$Iteration)
    
    if ([string]::IsNullOrWhiteSpace($Issues)) {
        return
    }
    
    $header = "`n### Iteration $Iteration Issues:`n"
    $Script:AllIssuesHistory += $header + $Issues + "`n"
    
    Write-LogInfo "Added iteration $Iteration issues to history tracking"
}

function Get-IssuesHistorySummary {
    if ([string]::IsNullOrWhiteSpace($Script:AllIssuesHistory)) {
        return ""
    }

    $effectiveHistoryIterations = if ($MetaReview) { 1 } else { $HistoryIterations }
    $maxHistoryChars = if ($MetaReview) { 4000 } else { 6000 }

    # Truncate by iteration count (more predictable than character count)
    # Keep only the most recent N iterations
    $history = $Script:AllIssuesHistory

    # Find all iteration headers
    $iterationMatches = [regex]::Matches($history, '### Iteration (\d+) Issues:')

    if ($iterationMatches.Count -gt $effectiveHistoryIterations) {
        # Keep only the last N iterations
        $keepFrom = $iterationMatches[$iterationMatches.Count - $effectiveHistoryIterations].Index
        $history = "...(earlier issues truncated - keeping last $effectiveHistoryIterations iterations)...`n" + $history.Substring($keepFrom)
        Write-LogInfo "Truncated history to last $effectiveHistoryIterations iterations"
    }

    # Also apply character limit as safety net
    if ($history.Length -gt $maxHistoryChars) {
        Write-LogWarn "Issue history exceeds $maxHistoryChars chars ($($history.Length)). Truncating."
        $truncateAt = $history.Length - $maxHistoryChars
        $nextHeader = $history.IndexOf("`n### Iteration", $truncateAt)
        if ($nextHeader -gt 0) {
            $history = "...(truncated)..." + $history.Substring($nextHeader)
        }
        else {
            $history = "...(truncated)..." + $history.Substring($truncateAt)
        }
    }

    Write-LogInfo "Issue history size: $($history.Length) chars"
    
    return @"
## Issues from Previous Iterations

The following issues were reported and (should have been) fixed in previous iterations.
Do NOT report these same issues again unless they have genuinely regressed.
Do NOT report the OPPOSITE of these issues (e.g., if "add placeholder" was reported, do not now report "remove placeholder").

$history
"@
}

# =============================================================================
# Iteration History File Functions
# =============================================================================

# The iteration history file provides Codex with:
# 1. Timestamped record of each iteration
# 2. Issue patterns to avoid re-reporting
# 3. Explicit "blocked" contradictions
# Location: logs/<session_id>/_iteration_history.md

$Script:HistoryFile = ""  # Set in Start-CrossQCPipeline

function Get-IssuePatterns {
    param([string]$Issues)
    
    # Extract key patterns from issues for contradiction detection
    # Returns hashtable with: locations, actions (add/remove/missing/unused), subjects
    
    $patterns = @{
        Locations = @()
        Actions = @()
        Subjects = @()
        Keywords = @()
    }
    
    if ([string]::IsNullOrWhiteSpace($Issues)) {
        return $patterns
    }
    
    # Extract file locations
    $locationMatches = [regex]::Matches($Issues, '\*\*Location\*\*:\s*`?([^`\n]+)`?')
    foreach ($match in $locationMatches) {
        $patterns.Locations += $match.Groups[1].Value.Trim()
    }
    
    # Extract action words that indicate what was requested
    $actionWords = @(
        'add', 'added', 'adding',
        'remove', 'removed', 'removing', 
        'missing', 'unused',
        'implement', 'wire', 'wiring',
        'hardcoded', 'static',
        'placeholder', 'placeholders',
        'validation', 'validate',
        'i18n', 'translation', 'translations', 'translate',
        'parameter', 'parameters', 'param', 'params'
    )
    
    $issuesLower = $Issues.ToLower()
    foreach ($action in $actionWords) {
        if ($issuesLower.Contains($action)) {
            $patterns.Actions += $action
        }
    }
    
    # Extract subjects from Description fields
    $descMatches = [regex]::Matches($Issues, '\*\*Description\*\*:\s*([^\n]+)')
    foreach ($match in $descMatches) {
        $desc = $match.Groups[1].Value.Trim()
        # Extract key noun phrases (simplified)
        if ($desc -match '`([^`]+)`') {
            $patterns.Subjects += $Matches[1]
        }
    }
    
    # Build keyword summary
    $patterns.Keywords = ($patterns.Actions | Select-Object -Unique)
    
    return $patterns
}

function Get-BlockedPatterns {
    param([array]$PreviousPatterns)
    
    # Generate "blocked" contradictions based on previous issue patterns
    # If previous said "add X", block "remove X" or "unused X"
    # Returns array of blocked pattern descriptions with context
    
    $contradictions = @{
        'add' = @('remove', 'unused', 'unnecessary', 'dead')
        'adding' = @('remove', 'unused', 'unnecessary')
        'missing' = @('unused', 'unnecessary', 'remove')
        'implement' = @('unused', 'dead code', 'remove')
        'wire' = @('unused', 'unwired')
        'wiring' = @('unused')
        'placeholder' = @('static', 'hardcoded')
        'placeholders' = @('static', 'hardcoded', 'remove')
        'hardcoded' = @('unused')
        'static' = @('unused')
        'validation' = @('over-validation', 'unnecessary check')
        'i18n' = @('unused translation', 'unused key')
        'translation' = @('unused')
        'parameter' = @('unused parameter')
    }
    
    $blocked = @()
    
    foreach ($patternSet in $PreviousPatterns) {
        $locations = $patternSet.Locations -join ", "
        if ([string]::IsNullOrWhiteSpace($locations)) { $locations = "various" }
        
        foreach ($action in $patternSet.Actions) {
            if ($contradictions.ContainsKey($action)) {
                foreach ($contra in $contradictions[$action]) {
                    # Add context: what to avoid and where it came from
                    $blocked += "$contra (contradicts '$action' at $locations)"
                }
            }
        }
    }
    
    # Also add generic combinations that cause oscillation
    $blocked += "DO NOT report 'unused X' if previous iteration said 'add X' or 'missing X'"
    $blocked += "DO NOT report 'remove X' if previous iteration said 'implement X'"
    
    return ($blocked | Select-Object -Unique)
}

function Write-IterationHistory {
    param(
        [int]$Iteration,
        [string]$Issues,
        [string]$Status  # 'FAIL' or 'PASS'
    )
    
    if ([string]::IsNullOrWhiteSpace($Script:HistoryFile)) {
        Write-LogWarn "History file path not set. Skipping history write."
        return
    }
    
    $timestamp = Get-TimestampReadable
    $patterns = Get-IssuePatterns -Issues $Issues
    
    # Initialize file whenever it does not exist yet. Meta-review can legitimately
    # reach its first recorded failure on iteration 2+ after earlier bounded checks pass.
    $needsInitialization = -not (Test-Path $Script:HistoryFile -PathType Leaf)
    if (-not $needsInitialization) {
        try {
            $existingHistoryContent = Get-Content -Path $Script:HistoryFile -Raw
            $needsInitialization = [string]::IsNullOrWhiteSpace($existingHistoryContent)
        }
        catch {
            $needsInitialization = $true
        }
    }

    if ($needsInitialization) {
        @"
# Cross-QC Iteration History

This file tracks QC iterations for anti-oscillation detection.
**Codex: Read this ENTIRE file before reviewing code.**

## Pipeline Info
- **Pipeline ID**: $($Script:PipelineStartTime)
- **Plan File**: $($Script:PlanFileResolved)
- **Started**: $timestamp

---

## Blocked Patterns (DO NOT REPORT)

These patterns likely contradict previous fixes. **Use judgment**: if the issue is at the SAME location as a previous fix and matches a blocked pattern, skip it. If it's a genuinely NEW problem at a DIFFERENT location, report it.

``````
(Updated after each iteration)
``````

---

## Iteration Log

"@ | Out-File -FilePath $Script:HistoryFile -Encoding UTF8
    }
    
    # Append iteration entry
    $issueCount = ([regex]::Matches($Issues, '### Issue')).Count
    $locationList = if ($patterns.Locations.Count -gt 0) { ($patterns.Locations | Select-Object -First 5) -join ", " } else { "(none extracted)" }
    $keywordList = if ($patterns.Keywords.Count -gt 0) { $patterns.Keywords -join ", " } else { "(none)" }
    
    @"

### Iteration $Iteration
- **Timestamp**: $timestamp
- **Status**: $Status
- **Issues Found**: $issueCount
- **Key Locations**: $locationList
- **Keywords**: $keywordList

"@ | Out-File -FilePath $Script:HistoryFile -Append -Encoding UTF8
    
    # Update blocked patterns section by rewriting file header
    # (This is expensive but keeps the blocked section current)
    Update-BlockedPatternsSection
    
    Write-LogInfo "Updated iteration history: $($Script:HistoryFile)"
}

function Update-BlockedPatternsSection {
    if (-not (Test-Path $Script:HistoryFile)) {
        return
    }
    
    # Collect all patterns from history
    $allPatterns = @()
    
    # Parse existing iterations from AllIssuesHistory
    $iterationMatches = [regex]::Matches($Script:AllIssuesHistory, '(?s)### Iteration \d+ Issues:\s*(.+?)(?=### Iteration|\z)')
    foreach ($match in $iterationMatches) {
        $iterIssues = $match.Groups[1].Value
        $allPatterns += Get-IssuePatterns -Issues $iterIssues
    }
    
    $blocked = Get-BlockedPatterns -PreviousPatterns $allPatterns
    
    # Read current file
    $content = Get-Content -Path $Script:HistoryFile -Raw
    
    # Replace blocked patterns section
    $blockedText = if ($blocked.Count -gt 0) {
        ($blocked | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "(none yet)"
    }
    
    $newBlockedSection = @"
## Blocked Patterns (DO NOT REPORT)

These patterns likely contradict previous fixes. **Use judgment**: if the issue is at the SAME location as a previous fix and matches a blocked pattern, skip it. If it's a genuinely NEW problem at a DIFFERENT location, report it.

``````
$blockedText
``````

---
"@
    
    # Match from "## Blocked Patterns" up to and including the "---" separator
    $content = $content -replace '(?s)## Blocked Patterns \(DO NOT REPORT\).+?---\s*\n', ($newBlockedSection + "`n")
    
    $content | Out-File -FilePath $Script:HistoryFile -Encoding UTF8 -NoNewline
}

function Get-MetaReviewBlockedPatternsSummary {
    if (-not $MetaReview) {
        return ""
    }

    $blockedLines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Script:HistoryFile) -and (Test-Path $Script:HistoryFile -PathType Leaf)) {
        $historyContent = Get-Content -Path $Script:HistoryFile -Raw
        $blockedSectionMatch = [regex]::Match($historyContent, '(?s)## Blocked Patterns \(DO NOT REPORT\)\s*(.+?)(?=\r?\n---\s*(?:\r?\n|$))')
        if ($blockedSectionMatch.Success) {
            $blockedSection = $blockedSectionMatch.Groups[1].Value
            $fencedMatch = [regex]::Match($blockedSection, '(?s)``````\s*(.*?)\s*``````')
            $blockedText = if ($fencedMatch.Success) {
                $fencedMatch.Groups[1].Value
            }
            else {
                $blockedSection
            }

            foreach ($line in ($blockedText -split "\r?\n")) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) {
                    continue
                }
                if ($trimmed -match '^``````$' -or
                    $trimmed -match '^\(none yet\)$' -or
                    $trimmed -match '^\(Updated after each iteration\)$' -or
                    $trimmed -match '^These patterns likely contradict previous fixes\.') {
                    continue
                }

                if ($trimmed -notmatch '^- ') {
                    $trimmed = "- $trimmed"
                }
                $blockedLines.Add($trimmed)
            }
        }
    }

    if ($blockedLines.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($Script:AllIssuesHistory)) {
        $patternMatches = [regex]::Matches($Script:AllIssuesHistory, '(?s)### Iteration \d+ Issues:\s*(.+?)(?=### Iteration|\z)')
        $allPatterns = @()
        foreach ($match in $patternMatches) {
            $allPatterns += Get-IssuePatterns -Issues $match.Groups[1].Value
        }
        foreach ($pattern in (Get-BlockedPatterns -PreviousPatterns $allPatterns)) {
            $blockedLines.Add("- $pattern")
        }
    }

    if ($blockedLines.Count -eq 0) {
        return "No blocked contradiction patterns yet."
    }

    $summaryLines = @($blockedLines | Select-Object -First 12)
    $summary = ($summaryLines -join "`n").Trim()
    if ($blockedLines.Count -gt $summaryLines.Count) {
        $summary += "`n- ...(additional blocked patterns omitted)"
    }

    $maxSummaryChars = 2000
    if ($summary.Length -gt $maxSummaryChars) {
        $summary = $summary.Substring(0, $maxSummaryChars).TrimEnd() + "`n- ...(blocked pattern summary truncated)"
    }

    return @"
Use these blocked contradiction patterns to avoid oscillation. Only report a matching issue if it is clearly new at a different location.

$summary
"@
}

# =============================================================================
# Retry and Error Logging Helpers
# =============================================================================

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Runs a CLI command with exponential-backoff retries on transient API errors.
    .DESCRIPTION
        Wraps a command invocation with retry logic. If the command fails with a
        retryable error (rate limit, 429, 503, overloaded), it waits with exponential
        backoff and retries. Returns a hashtable with Output (string array) and ExitCode.
    #>
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$Command,
        [int]$MaxRetries = 0,
        [int]$BaseDelaySec = 0,
        [string]$ToolLabel = "CLI"
    )

    # Resolve defaults from script-level params if not explicitly provided
    if ($MaxRetries -le 0) {
        $MaxRetries = if ($script:MaxRetries) { $script:MaxRetries } else { 3 }
    }
    if ($BaseDelaySec -le 0) {
        $BaseDelaySec = if ($script:RetryDelaySec) { $script:RetryDelaySec } else { 30 }
    }

    for ($attempt = 1; $attempt -le ($MaxRetries + 1); $attempt++) {
        $previousErrorActionPreference = $ErrorActionPreference
        $nativeErrorPreferenceVar = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
        $previousNativeErrorPreference = $null

        try {
            $ErrorActionPreference = "Continue"
            if ($nativeErrorPreferenceVar) {
                $previousNativeErrorPreference = $nativeErrorPreferenceVar.Value
                $PSNativeCommandUseErrorActionPreference = $false
            }

            $output = & $Command 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
            if ($nativeErrorPreferenceVar) {
                $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
            }
        }

        if ($exitCode -eq 0) {
            return @{ Output = $output; ExitCode = 0 }
        }

        # Check if the error is retryable (rate limit, server error, overloaded)
        $outputStr = ($output | Out-String)
        $isRetryable = Test-RetryableCLIOutput -Output $output

        if ($isRetryable -and $attempt -le $MaxRetries) {
            $delay = [math]::Min($BaseDelaySec * [math]::Pow(2, $attempt - 1), 300)
            Write-LogWarn "${ToolLabel}: Retryable API error detected (attempt $attempt of $($MaxRetries + 1)). Waiting ${delay}s before retry..."
            Write-RunEvent -Type "cli_retry" -Level "warn" -Data @{
                tool = $ToolLabel
                attempt = $attempt
                maxRetries = $MaxRetries + 1
                delaySec = $delay
                errorSnippet = ($outputStr.Substring(0, [math]::Min($outputStr.Length, 200))).Trim()
                message = "$ToolLabel retry attempt $attempt after transient error"
            }
            Start-Sleep -Seconds $delay
            continue
        }

        # Non-retryable error or exhausted retries
        return @{ Output = $output; ExitCode = $exitCode }
    }

    # Should not reach here, but return last result as safety
    return @{ Output = $output; ExitCode = $exitCode }
}

function Test-RetryableCLIOutput {
    param($Output)

    $outputStr = ($Output | Out-String)
    return $outputStr -match "(?i)(rate.?limit|rate_limit_error|429|503|overloaded|too.?many.?requests|server.?error|capacity)"
}

function Invoke-ExternalProcessWithRetry {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$InputText = "",
        [int]$TimeoutSec = 0,
        [int]$MaxRetries = 0,
        [int]$BaseDelaySec = 0,
        [string]$ToolLabel = "CLI"
    )

    if ($MaxRetries -le 0) {
        $MaxRetries = if ($script:MaxRetries) { $script:MaxRetries } else { 3 }
    }
    if ($BaseDelaySec -le 0) {
        $BaseDelaySec = if ($script:RetryDelaySec) { $script:RetryDelaySec } else { 30 }
    }

    for ($attempt = 1; $attempt -le ($MaxRetries + 1); $attempt++) {
        $result = Invoke-ExternalProcessWithTimeout -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutSec $TimeoutSec

        if ($result.ExitCode -eq 0 -or $result.TimedOut) {
            return $result
        }

        $outputStr = ($result.Output | Out-String)
        $isRetryable = Test-RetryableCLIOutput -Output $result.Output

        if ($isRetryable -and $attempt -le $MaxRetries) {
            $delay = [math]::Min($BaseDelaySec * [math]::Pow(2, $attempt - 1), 300)
            Write-LogWarn "${ToolLabel}: Retryable API error detected (attempt $attempt of $($MaxRetries + 1)). Waiting ${delay}s before retry..."
            Write-RunEvent -Type "cli_retry" -Level "warn" -Data @{
                tool = $ToolLabel
                attempt = $attempt
                maxRetries = $MaxRetries + 1
                delaySec = $delay
                errorSnippet = ($outputStr.Substring(0, [math]::Min($outputStr.Length, 200))).Trim()
                message = "$ToolLabel retry attempt $attempt after transient error"
            }
            Start-Sleep -Seconds $delay
            continue
        }

        return $result
    }

    return $result
}

function Write-CLIErrorDetails {
    <#
    .SYNOPSIS
        Logs the actual CLI output on failure for diagnostics.
    #>
    param(
        [string]$ToolLabel,
        [int]$ExitCode,
        $Output
    )

    $errorOutput = ($Output | Out-String).Trim()
    if ($errorOutput) {
        # Truncate very long output for the console (full output goes to log file)
        $maxConsoleChars = 500
        $consoleSnippet = if ($errorOutput.Length -gt $maxConsoleChars) {
            $errorOutput.Substring(0, $maxConsoleChars) + "`n... (truncated, see log file for full output)"
        } else {
            $errorOutput
        }
        Write-LogError "$ToolLabel CLI output (exit code $ExitCode):`n$consoleSnippet"
    }
}

function Convert-CLIOutputToText {
    param($Output)

    if ($null -eq $Output) {
        return ""
    }

    if ($Output -is [System.Array]) {
        return (($Output | ForEach-Object {
                    if ($null -eq $_) { "" } else { [string]$_ }
                }) -join [Environment]::NewLine).TrimEnd()
    }

    return ([string]$Output).TrimEnd()
}

function Get-CodexTranscriptFilePath {
    param([string]$ReportFile)

    $directory = Split-Path -Path $ReportFile -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ReportFile)
    return Join-Path $directory "${baseName}_transcript.txt"
}

function Format-CommandArgForTranscript {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    return $Value
}

function Get-CodexTranscriptHeader {
    param(
        [string[]]$CommandArgs,
        [string]$Prompt
    )

    $promptText = if ($null -eq $Prompt) { "" } else { [string]$Prompt }
    $promptLineCount = if ([string]::IsNullOrEmpty($promptText)) {
        0
    }
    else {
        [regex]::Matches($promptText, "\r?\n").Count + 1
    }
    $serializedArgs = ($CommandArgs | ForEach-Object { Format-CommandArgForTranscript -Value $_ }) -join " "

    return @(
        "ARGS: codex $serializedArgs",
        "PROMPT: stdin ($($promptText.Length) chars, $promptLineCount lines)"
    ) -join [Environment]::NewLine
}

function Normalize-CodexFinalMessage {
    param([string]$Content)

    if ($null -eq $Content) {
        return ""
    }

    $normalized = [string]$Content
    $normalized = $normalized -replace "^\uFEFF", ""
    $normalized = [regex]::Replace($normalized, [string][char]27 + '\[[0-?]*[ -/]*[@-~]', "")
    $normalized = [regex]::Replace($normalized, "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", "")
    return $normalized.Trim()
}

function Write-MarkdownArtifact {
    param(
        [string]$FilePath,
        [string]$Header,
        [string]$Body
    )

    $segments = @()
    if (-not [string]::IsNullOrWhiteSpace($Header)) {
        $segments += $Header.TrimEnd()
    }
    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        $segments += $Body.Trim()
    }

    $content = if ($segments.Count -gt 0) {
        ($segments -join "`r`n`r`n") + "`r`n"
    }
    else {
        ""
    }

    $content | Out-File -FilePath $FilePath -Encoding UTF8
}

function Write-CodexFailureReport {
    param(
        [string]$ReportFile,
        [string]$ReportHeader,
        [string]$ToolLabel,
        [int]$ExitCode,
        [string]$TranscriptFile,
        [string]$FailureReason = ""
    )

    $lines = @(
        "## Status",
        "Codex execution failed before producing a final markdown report.",
        "",
        "- **Tool**: $ToolLabel",
        "- **Exit Code**: $ExitCode",
        "- **Transcript**: $TranscriptFile"
    )
    if (-not [string]::IsNullOrWhiteSpace($FailureReason)) {
        $lines += "- **Reason**: $FailureReason"
    }
    $lines += @(
        "",
        "## Notes",
        "See the transcript artifact for raw Codex stdout/stderr and any tool progress output."
    )

    Write-MarkdownArtifact -FilePath $ReportFile -Header $ReportHeader -Body ($lines -join "`n")
}

function Stop-ProcessTree {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return
    }

    try {
        & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
    }
    catch {}

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
    catch {}
}

function Resolve-ExternalCommandPath {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        return $FilePath
    }

    if ([System.IO.Path]::IsPathRooted($FilePath) -or [System.IO.Path]::HasExtension($FilePath)) {
        try {
            $resolvedCommand = Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1
            if ($resolvedCommand -and -not [string]::IsNullOrWhiteSpace($resolvedCommand.Source)) {
                return $resolvedCommand.Source
            }
        }
        catch {}

        return $FilePath
    }

    $resolvedCommands = @()
    try {
        $resolvedCommands = @(Get-Command -Name $FilePath -CommandType Application -All -ErrorAction Stop)
    }
    catch {}

    if ($resolvedCommands.Count -eq 0) {
        return $FilePath
    }

    $usableCommands = @($resolvedCommands | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.Source)
    })

    if ($usableCommands.Count -eq 0) {
        return $FilePath
    }

    $preferredCommand = $usableCommands | Where-Object {
        $_.Source -notmatch '[\\/]+WindowsApps[\\/]'
    } | Select-Object -First 1

    if ($preferredCommand) {
        return $preferredCommand.Source
    }

    return $usableCommands[0].Source
}

function Get-ClaudeCommandPath {
    $resolved = Resolve-ExternalCommandPath -FilePath "claude"
    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
        return $resolved
    }

    return "claude"
}

function Test-ClaudeEffortSupport {
    param([string]$ClaudeCommandPath = "")

    $commandPath = if ([string]::IsNullOrWhiteSpace($ClaudeCommandPath)) {
        Get-ClaudeCommandPath
    }
    else {
        $ClaudeCommandPath
    }

    if ($Script:ClaudeSupportsEffort -ne $null -and
        $Script:ClaudeSupportsEffortCommandPath -eq $commandPath) {
        return [bool]$Script:ClaudeSupportsEffort
    }

    $supportsEffort = $false
    try {
        $helpOutput = & $commandPath --help 2>&1
        $helpText = Convert-CLIOutputToText -Output $helpOutput
        if ($helpText -match '--effort\s+<level>') {
            $supportsEffort = $true
        }
    }
    catch {
        $supportsEffort = $false
    }

    $Script:ClaudeSupportsEffort = [bool]$supportsEffort
    $Script:ClaudeSupportsEffortCommandPath = $commandPath
    return [bool]$supportsEffort
}

function Add-ProcessStartInfoArguments {
    param(
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [string[]]$Arguments = @()
    )

    $argumentList = $StartInfo.ArgumentList
    if ($null -ne $argumentList) {
        foreach ($argument in $Arguments) {
            [void]$argumentList.Add([string]$argument)
        }
        return
    }

    $quotedArguments = foreach ($argument in $Arguments) {
        try {
            [System.Management.Automation.Language.CodeGeneration]::QuoteArgument([string]$argument)
        }
        catch {
            Format-CommandArgForTranscript -Value ([string]$argument)
        }
    }
    $StartInfo.Arguments = ($quotedArguments -join " ")
}

function Set-ProcessStartInfoEncoding {
    param(
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [string]$PropertyName,
        [System.Text.Encoding]$Encoding
    )

    if ($null -eq $StartInfo -or $null -eq $Encoding -or [string]::IsNullOrWhiteSpace($PropertyName)) {
        return
    }

    try {
        $property = $StartInfo.GetType().GetProperty($PropertyName)
        if ($property -and $property.CanWrite) {
            $property.SetValue($StartInfo, $Encoding, $null)
        }
    }
    catch {}
}

function Invoke-ExternalProcessWithTimeout {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$InputText = "",
        [int]$TimeoutSec = 0
    )

    $resolvedCommandPath = Resolve-ExternalCommandPath -FilePath $FilePath

    $isBatchWrapper = $resolvedCommandPath -match '\.(cmd|bat)$'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = if ($isBatchWrapper) { $env:ComSpec } else { $resolvedCommandPath }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Get-Location).Path
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    Set-ProcessStartInfoEncoding -StartInfo $psi -PropertyName "StandardInputEncoding" -Encoding $utf8NoBom
    Set-ProcessStartInfoEncoding -StartInfo $psi -PropertyName "StandardOutputEncoding" -Encoding $utf8NoBom
    Set-ProcessStartInfoEncoding -StartInfo $psi -PropertyName "StandardErrorEncoding" -Encoding $utf8NoBom

    $launchArguments = @()
    if ($isBatchWrapper) {
        $launchArguments += "/d", "/c", [string]$resolvedCommandPath
    }

    $launchArguments += $ArgumentList
    Add-ProcessStartInfoArguments -StartInfo $psi -Arguments $launchArguments

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()

    try {
        if ($null -ne $InputText) {
            $inputPayload = [string]$InputText
            if (-not [string]::IsNullOrEmpty($inputPayload) -and $inputPayload -notmatch "\r?\n$") {
                $inputPayload += [Environment]::NewLine
            }
            $stdinBytes = $utf8NoBom.GetBytes($inputPayload)
            $process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        $process.StandardInput.Close()
    }
    catch {
        try { $process.StandardInput.Close() } catch {}
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $timedOut = $false
    $processExited = $false
    if ($TimeoutSec -gt 0) {
        $processExited = $process.WaitForExit($TimeoutSec * 1000)
        $timedOut = -not $processExited
        if ($timedOut) {
            Stop-ProcessTree -ProcessId $process.Id
            $processExited = $process.WaitForExit(2000)
            if (-not $processExited) {
                try {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
                catch {}
                $processExited = $process.WaitForExit(1000)
            }
        }
    }
    else {
        $null = $process.WaitForExit()
        $processExited = $true
    }

    if ($processExited) {
        $null = $process.WaitForExit()
    }

    $outputDrainTimeoutMs = if ($timedOut -and -not $processExited) { 1000 } else { 5000 }
    try {
        [void][System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), $outputDrainTimeoutMs)
    }
    catch {
        # Best effort: use whatever output has completed.
    }

    $stdout = if ($stdoutTask.IsCompleted) { $stdoutTask.Result } else { "" }
    $stderr = if ($stderrTask.IsCompleted) { $stderrTask.Result } else { "" }
    $output = @()

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $output += ($stdout -split "\r?\n")
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $output += ($stderr -split "\r?\n")
    }

    return @{
        ExitCode = $(if ($timedOut) { 124 } else { $process.ExitCode })
        TimedOut = $timedOut
        ProcessId = $process.Id
        ProcessExited = $processExited
        StdOut = $stdout
        StdErr = $stderr
        Output = @($output)
    }
}

function Invoke-CodexCommandWithArtifacts {
    param(
        [string]$Prompt,
        [string]$ReportFile,
        [string]$ReportHeader,
        [string]$ToolLabel,
        [ValidateSet("read-only", "workspace-write")]
        [string]$SandboxMode = "read-only",
        [ValidateSet("low", "medium", "high", "xhigh", "")]
        [string]$ReasoningEffort = "",
        [int]$TimeoutSec = 0
    )

    $transcriptFile = Get-CodexTranscriptFilePath -ReportFile $ReportFile
    $lastMessageFile = Join-Path (Split-Path -Path $ReportFile -Parent) (".{0}_last_message.tmp" -f [System.IO.Path]::GetFileNameWithoutExtension($ReportFile))

    foreach ($artifactPath in @($transcriptFile, $lastMessageFile)) {
        if (Test-Path $artifactPath) {
            Remove-Item -Path $artifactPath -Force -ErrorAction SilentlyContinue
        }
    }

    $codexArgs = @(
        "-a", "never",
        "exec",
        "--skip-git-repo-check",
        "-s", $SandboxMode,
        "-o", $lastMessageFile,
        "-"
    )
    if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
        $codexArgs = @(
            "-a", "never",
            "-c", "reasoning_effort=""$ReasoningEffort""",
            "exec",
            "--skip-git-repo-check",
            "-s", $SandboxMode,
            "-o", $lastMessageFile,
            "-"
        )
    }
    $promptText = if ($null -eq $Prompt) { "" } else { [string]$Prompt }
    $transcriptHeader = Get-CodexTranscriptHeader -CommandArgs $codexArgs -Prompt $promptText

    $codexCommandPath = Resolve-ExternalCommandPath -FilePath "codex"

    $retryResult = Invoke-ExternalProcessWithRetry -FilePath $codexCommandPath -ArgumentList $codexArgs -InputText $promptText -TimeoutSec $TimeoutSec -ToolLabel $ToolLabel

    $output = $retryResult.Output
    $exitCode = $retryResult.ExitCode
    $transcriptText = Convert-CLIOutputToText -Output $output
    $transcriptContent = if ([string]::IsNullOrWhiteSpace($transcriptText)) {
        $transcriptHeader
    }
    else {
        @($transcriptHeader, "", $transcriptText) -join [Environment]::NewLine
    }
    $transcriptContent | Out-File -FilePath $transcriptFile -Encoding UTF8
    Write-LogInfo "$ToolLabel transcript: $transcriptFile"

    $output | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

    $finalMessage = ""
    if (Test-Path $lastMessageFile) {
        $finalMessage = Normalize-CodexFinalMessage -Content (Get-Content -Path $lastMessageFile -Raw)
        Remove-Item -Path $lastMessageFile -Force -ErrorAction SilentlyContinue
    }

    $failureReason = ""
    if ($retryResult.TimedOut -and -not [string]::IsNullOrWhiteSpace($finalMessage)) {
        Write-LogWarn "$ToolLabel timed out after $TimeoutSec seconds. Salvaging final markdown message."
        Write-RunEvent -Type "tool_timeout_salvaged" -Level "warn" -Data @{
            tool = $ToolLabel
            timeoutSec = $TimeoutSec
            report = $ReportFile
            transcript = $transcriptFile
            message = "$ToolLabel timed out after $TimeoutSec seconds; salvaged final markdown output."
        }
    }
    elseif ($retryResult.TimedOut) {
        Write-RunEvent -Type "tool_timeout" -Level "error" -Data @{
            tool = $ToolLabel
            timeoutSec = $TimeoutSec
            report = $ReportFile
            transcript = $transcriptFile
            message = "$ToolLabel timed out after $TimeoutSec seconds."
        }
        $failureReason = "Timed out after $TimeoutSec seconds and no final markdown message could be salvaged."
    }
    elseif ($exitCode -ne 0) {
        $failureReason = "CLI exited with code $exitCode."
    }
    elseif ([string]::IsNullOrWhiteSpace($finalMessage)) {
        $failureReason = "Codex did not return a final markdown message."
        $exitCode = 1
    }

    if ($failureReason) {
        Write-CodexFailureReport -ReportFile $ReportFile -ReportHeader $ReportHeader -ToolLabel $ToolLabel -ExitCode $exitCode -TranscriptFile $transcriptFile -FailureReason $failureReason
        return @{
            Success = $false
            ExitCode = $exitCode
            Output = $output
            TranscriptFile = $transcriptFile
            FinalMessage = $finalMessage
        }
    }

    Write-MarkdownArtifact -FilePath $ReportFile -Header $ReportHeader -Body $finalMessage
    return @{
        Success = $true
        ExitCode = 0
        Output = $output
        TranscriptFile = $transcriptFile
        FinalMessage = $finalMessage
    }
}

# =============================================================================
# CLI Execution Functions
# =============================================================================

function Get-CurrentQCTool {
    param([int]$Iteration)

    if ($ClaudeQCIterations -gt 0 -and $Iteration -le $ClaudeQCIterations) {
        return "claude"
    }
    return "codex"
}

# =============================================================================
# Deliberation Mode Helper Functions
# =============================================================================

function Test-Convergence {
    param(
        [string]$ClaudeDecision,
        [string]$CodexDecision,
        [int]$ConsecutiveMinorRounds,
        [bool]$HasBlockingSeverity = $false
    )

    # Severity veto (CRITICAL/HIGH remaining) beats any decision-based convergence.
    if ($HasBlockingSeverity) {
        return $false
    }

    # Both agents say CONVERGED
    if ($ClaudeDecision -eq "CONVERGED" -and $CodexDecision -eq "CONVERGED") {
        return $true
    }

    # Soft convergence: 2+ consecutive MINOR_REFINEMENT rounds
    if ($ConsecutiveMinorRounds -ge 2) {
        return $true
    }

    return $false
}

function Get-DeliberationSummary {
    param(
        [array]$AllRounds,
        [int]$MaxChars = 4000
    )

    # Compress history for token economy
    $summary = @()
    foreach ($round in $AllRounds) {
        # Handle null/empty KeyPoints with null-coalescing
        $keyPointsText = if ($round.KeyPoints) { $round.KeyPoints -join "; " } else { "(none)" }
        $summary += @"
## Round $($round.Number) - $($round.Agent)
- Decision: $($round.Decision)
- Key points: $keyPointsText
"@
    }

    $result = $summary -join "`n`n"

    # Truncate if exceeds limit, keeping most recent rounds
    if ($result.Length -gt $MaxChars) {
        # Keep removing oldest rounds until within limit (keep at least 1)
        while ($summary.Count -gt 1 -and ($summary -join "`n`n").Length -gt $MaxChars) {
            $summary = $summary[1..($summary.Count - 1)]
        }
        # Handle single oversized item - truncate the content itself
        if ($summary.Count -eq 1 -and $summary[0].Length -gt $MaxChars) {
            $summary[0] = $summary[0].Substring(0, $MaxChars - 50) + "`n[Content truncated]"
        }
        $result = "[Earlier rounds truncated for token economy]`n`n" + ($summary -join "`n`n")
    }

    return $result
}

function Extract-Decision {
    param([string]$Content)

    # Look for decision marker in agent output
    if ($Content -match '##\s*Decision:\s*(CONVERGED|MINOR_REFINEMENT|MAJOR_REFINEMENT)') {
        return $Matches[1]
    }

    # Fallback: infer from content (using word boundaries to avoid partial matches)
    if ($Content -match '\bno\s+(further\s+)?changes?\s+(needed|required)\b' -or
        $Content -match '\blooks?\s+good\b' -or
        $Content -match '\bapprove[ds]?\b') {
        return "CONVERGED"
    }

    # Fallback: detect MINOR_REFINEMENT patterns
    if ($Content -match '\b(minor|small|slight|few)\s+(changes?|tweaks?|adjustments?|refinements?)\b' -or
        $Content -match '\b(nearly|almost)\s+(complete|done|finished|ready)\b' -or
        $Content -match '\bclose\s+to\s+(convergence|complete)\b') {
        return "MINOR_REFINEMENT"
    }

    return "MAJOR_REFINEMENT"
}

function Extract-KeyPoints {
    param([string]$Content)

    $keyPoints = @()

    # Extract from "Changes Made" section
    if ($Content -match '(?s)##\s*Changes Made:(.+?)(##|$)') {
        $changes = $Matches[1]
        $changes -split '\n' | ForEach-Object {
            if ($_ -match '^\s*-\s*\[?(ADDED|MODIFIED|REMOVED)\]?:?\s*(.+)') {
                $keyPoints += "$($Matches[1]): $($Matches[2].Trim())"
            }
        }
    }

    # Extract from bullet points (limit to 5)
    if ($keyPoints.Count -eq 0) {
        $Content -split '\n' | ForEach-Object {
            if ($keyPoints.Count -lt 5 -and $_ -match '^\s*-\s+(.{10,80})$') {
                $keyPoints += $Matches[1].Trim()
            }
        }
    }

    return $keyPoints
}

function Get-SessionEventRecords {
    param([string]$EventsFilePath = $Script:EventsFile)

    $events = @()
    if ([string]::IsNullOrWhiteSpace($EventsFilePath) -or -not (Test-Path $EventsFilePath)) {
        return $events
    }

    Get-Content -Path $EventsFilePath | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) {
            try {
                $parsed = $_ | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $parsed) {
                    $events += $parsed
                }
            }
            catch {
                # Ignore malformed telemetry lines and keep scanning.
            }
        }
    }

    return $events
}

function Get-LastDeliberationStartedRound {
    param(
        [ValidateSet("document", "code")]
        [string]$Mode,
        [array]$Events = @()
    )

    $eventType = if ($Mode -eq "document") {
        "document_deliberation_round_started"
    }
    else {
        "code_deliberation_round_started"
    }

    $rounds = @(
        $Events |
            Where-Object { $_.type -eq $eventType -and $null -ne $_.data -and $null -ne $_.data.round } |
            ForEach-Object { [int]$_.data.round }
    )

    if ($rounds.Count -eq 0) {
        return 0
    }

    return ($rounds | Measure-Object -Maximum).Maximum
}

function Test-IsCodexFailureArtifact {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $true
    }

    return (
        $Content -match '(?ms)^##\s*Status\s*$' -and
        $Content -match 'Codex execution failed before producing a final markdown report\.'
    )
}

function Get-DeliberationArtifactState {
    param(
        [ValidateSet("document", "code")]
        [string]$Mode
    )

    $phaseDir = if ($Mode -eq "document") { $Script:DelibPhase0Dir } else { $Script:DelibPhase1Dir }
    $feedbackKind = if ($Mode -eq "document") { "codex_evaluation" } else { "codex_review" }
    $state = @{}

    if ([string]::IsNullOrWhiteSpace($phaseDir) -or -not (Test-Path $phaseDir -PathType Container)) {
        return $state
    }

    Get-ChildItem -Path $phaseDir -Filter "round*_*.md" -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^round(?<round>\d+)_(?<kind>claude_thoughts|codex_evaluation|codex_review)\.md$') {
            $round = [int]$Matches.round
            $kind = $Matches.kind

            if ($kind -ne "claude_thoughts" -and $kind -ne $feedbackKind) {
                return
            }

            $key = $round.ToString()
            if (-not $state.ContainsKey($key)) {
                $state[$key] = [ordered]@{
                    Round = $round
                    ClaudeFile = ""
                    ClaudeDecision = ""
                    ClaudeKeyPoints = @()
                    FeedbackFile = ""
                    FeedbackDecision = ""
                    FeedbackKeyPoints = @()
                }
            }

            $content = Get-Content -Path $_.FullName -Raw
            if ($kind -eq "claude_thoughts") {
                $state[$key].ClaudeFile = $_.FullName
                $state[$key].ClaudeDecision = Extract-Decision -Content $content
                $state[$key].ClaudeKeyPoints = Extract-KeyPoints -Content $content
            }
            else {
                if (Test-IsCodexFailureArtifact -Content $content) {
                    return
                }
                $state[$key].FeedbackFile = $_.FullName
                $state[$key].FeedbackDecision = Extract-Decision -Content $content
                $state[$key].FeedbackKeyPoints = Extract-KeyPoints -Content $content
            }
        }
    }

    return $state
}

function Get-DeliberationConvergenceState {
    param([hashtable]$ArtifactState)

    $consecutiveMinor = 0
    $consecutiveMajor = 0
    $lastClaudeDecision = ""
    $lastCodexDecision = ""

    $rounds = @($ArtifactState.Keys | ForEach-Object { [int]$_ } | Sort-Object)
    foreach ($round in $rounds) {
        $entry = $ArtifactState[$round.ToString()]
        if (-not $entry.ClaudeDecision -or -not $entry.FeedbackDecision) {
            continue
        }

        $lastClaudeDecision = $entry.ClaudeDecision
        $lastCodexDecision = $entry.FeedbackDecision

        if ($entry.ClaudeDecision -eq "MINOR_REFINEMENT" -and $entry.FeedbackDecision -eq "MINOR_REFINEMENT") {
            $consecutiveMinor++
        }
        elseif ($entry.ClaudeDecision -eq "MAJOR_REFINEMENT" -or $entry.FeedbackDecision -eq "MAJOR_REFINEMENT") {
            $consecutiveMinor = 0
            $consecutiveMajor++
        }
        else {
            $consecutiveMajor = 0
        }
    }

    return @{
        ConsecutiveMinor = $consecutiveMinor
        ConsecutiveMajor = $consecutiveMajor
        LastClaudeDecision = $lastClaudeDecision
        LastCodexDecision = $lastCodexDecision
    }
}

function Get-DeliberationResumeState {
    param(
        [ValidateSet("document", "code")]
        [string]$Mode
    )

    $artifactState = Get-DeliberationArtifactState -Mode $Mode
    $events = Get-SessionEventRecords
    $startedRound = Get-LastDeliberationStartedRound -Mode $Mode -Events $events
    $rounds = @($artifactState.Keys | ForEach-Object { [int]$_ } | Sort-Object)
    $allRounds = @()
    $highestClaudeRound = 0
    $highestFeedbackRound = 0
    $latestFeedbackFile = ""

    foreach ($round in $rounds) {
        $entry = $artifactState[$round.ToString()]

        if ($entry.ClaudeFile) {
            $highestClaudeRound = [Math]::Max($highestClaudeRound, $round)
            $allRounds += @{
                Number = $round
                Agent = "Claude"
                Decision = $entry.ClaudeDecision
                KeyPoints = $entry.ClaudeKeyPoints
            }
        }

        if ($entry.FeedbackFile) {
            $highestFeedbackRound = [Math]::Max($highestFeedbackRound, $round)
            $latestFeedbackFile = $entry.FeedbackFile
            $allRounds += @{
                Number = $round
                Agent = "Codex"
                Decision = $entry.FeedbackDecision
                KeyPoints = $entry.FeedbackKeyPoints
            }
        }
    }

    if ($startedRound -le 0 -and $highestClaudeRound -eq 0 -and $highestFeedbackRound -eq 0) {
        return @{
            Success = $false
            Message = "No saved deliberation rounds were found for this session."
        }
    }

    $startRound = 1
    $nextAgent = "claude"

    if ($highestClaudeRound -gt $highestFeedbackRound) {
        $startRound = $highestClaudeRound
        $nextAgent = "codex"
    }
    elseif ($startedRound -gt [Math]::Max($highestClaudeRound, $highestFeedbackRound)) {
        $startRound = $startedRound
        $nextAgent = "claude"
    }
    else {
        $startRound = [Math]::Max($highestFeedbackRound + 1, 1)
        $nextAgent = "claude"
    }

    $convergence = Get-DeliberationConvergenceState -ArtifactState $artifactState
    $currentRoundKey = $startRound.ToString()
    $currentRoundState = if ($artifactState.ContainsKey($currentRoundKey)) { $artifactState[$currentRoundKey] } else { $null }
    $previousContext = if ($allRounds.Count -gt 0) { Get-DeliberationSummary -AllRounds $allRounds } else { "" }

    $resumeState = @{
        Success = $true
        Mode = $Mode
        StartRound = $startRound
        NextAgent = $nextAgent
        AllRounds = $allRounds
        PreviousContext = $previousContext
        ConsecutiveMinor = $convergence.ConsecutiveMinor
        ConsecutiveMajor = $convergence.ConsecutiveMajor
        ClaudeDecision = $convergence.LastClaudeDecision
        CodexDecision = $convergence.LastCodexDecision
        CurrentRoundClaudeDecision = $(if ($currentRoundState) { $currentRoundState.ClaudeDecision } else { "" })
        ClaudeThoughtsFile = $(if ($currentRoundState) { $currentRoundState.ClaudeFile } else { "" })
        CodexFeedbackFile = $latestFeedbackFile
        LastStartedRound = $startedRound
        DocPath = $(if ($Mode -eq "document") { Get-ContinuationPlanPath } else { "" })
    }

    if ($Mode -eq "document" -and $startRound -gt 1 -and [string]::IsNullOrWhiteSpace($resumeState.DocPath)) {
        return @{
            Success = $false
            Message = "No continuation plan document was found for the resumed document deliberation session."
        }
    }

    return $resumeState
}

# =============================================================================
# Cycle Completion Tracking Functions
# =============================================================================

function Update-CycleStatus {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PlanFile,
        [string]$Status = "COMPLETED"
    )

    $statusFile = if ($Script:CycleStatusFile) { $Script:CycleStatusFile } else { Join-Path $Script:SessionCyclesDir "_CYCLE_STATUS.json" }

    # Extract cycle number from plan file name
    if ($PlanFile -match "CONTINUATION_CYCLE_(\d+)\.md$") {
        $completedCycle = [int]$Matches[1]
        $nextCycle = $completedCycle + 1

        # Load or create status
        $statusData = if (Test-Path $statusFile) {
            Get-Content $statusFile -Raw | ConvertFrom-Json
        } else {
            [PSCustomObject]@{ currentCycle = 1; completedCycles = @() }
        }

        # Convert to hashtable for easier manipulation
        $statusHash = @{
            currentCycle = $nextCycle
            completedCycles = @($statusData.completedCycles)
            lastCompleted = $completedCycle
            lastCompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            lastStatus = $Status
        }

        # Add to completed cycles if not already present
        if ($completedCycle -notin $statusHash.completedCycles) {
            $statusHash.completedCycles += $completedCycle
        }

        # Save
        $statusHash | ConvertTo-Json -Depth 10 | Out-File $statusFile -Encoding UTF8
        Write-LogInfo "Updated cycle status file: $statusFile"
        return $true
    }
    return $false
}

function Update-CanonicalCycleRegistry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PlanFile
    )

    $statusFile = if ($Script:CyclesRoot) { Join-Path $Script:CyclesRoot "_CYCLE_STATUS.json" } else { "" }
    if ([string]::IsNullOrWhiteSpace($statusFile) -or -not (Test-Path $statusFile -PathType Leaf)) {
        Write-LogWarn "Canonical cycle registry file not found: $statusFile"
        return $false
    }

    if ($PlanFile -notmatch '(?:CONTINUATION|RESUME)_CYCLE_(?<cycle>\d+)(?:r)?\.md$') {
        Write-LogWarn "Could not extract a cycle number from canonical plan file: $PlanFile"
        return $false
    }

    $cycleNumber = [int]$Matches.cycle
    $statusData = Get-Content $statusFile -Raw | ConvertFrom-Json

    $pendingCycles = @($statusData.pendingCycles | ForEach-Object { [int]$_ } | Where-Object { $_ -ne $cycleNumber })
    $inProgressCycles = @($statusData.inProgressCycles | ForEach-Object { [int]$_ })
    if ($cycleNumber -notin $inProgressCycles) {
        $inProgressCycles += $cycleNumber
    }

    $completedCycles = @($statusData.completedCycles | ForEach-Object { [int]$_ })
    $updatedStatus = [ordered]@{
        pendingCycles = @($pendingCycles | Sort-Object -Unique)
        inProgressCycles = @($inProgressCycles | Sort-Object -Unique)
        completedCycles = @($completedCycles | Sort-Object -Unique)
    }

    $updatedStatus | ConvertTo-Json -Depth 10 | Out-File $statusFile -Encoding UTF8
    Write-LogInfo "Updated canonical cycle registry: $statusFile"
    return $true
}

function Mark-PlanCompleted {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PlanFile
    )

    if (Test-Path $PlanFile) {
        $content = Get-Content $PlanFile -Raw
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        # Add completion marker at top if not already present
        if ($content -notmatch "^## Status: COMPLETED") {
            $marker = "## Status: COMPLETED`n> Implementation completed via Code Deliberation at $timestamp`n`n"
            $newContent = $marker + $content
            $newContent | Out-File $PlanFile -Encoding UTF8
            Write-LogInfo "Marked plan as COMPLETED: $PlanFile"
        }
    }
}

# =============================================================================
# Document Deliberation Functions
# =============================================================================

function Invoke-ClaudeDeliberateDoc {
    param(
        [string]$PlanFile,
        [string]$PreviousContext,
        [int]$Round,
        [bool]$IsInitial,
        [string]$CodexEvaluationFile = "",
        [string]$DocFile = ""
    )

    $thoughtsFile = Join-Path $Script:DelibPhase0Dir "round${Round}_claude_thoughts.md"

    # Only get doc file path for refine rounds (initial round creates the doc)
    # Use passed DocFile if provided, otherwise search for it
    $docFile = if ($IsInitial) { "" } elseif ($DocFile) { $DocFile } else { Get-ContinuationPlanPath }

    # Validate docFile for non-initial rounds
    if (-not $IsInitial) {
        if ([string]::IsNullOrWhiteSpace($docFile)) {
            Write-LogError "No continuation plan document found for refine round $Round"
            return @{ Success = $false; Decision = ""; ThoughtsFile = ""; KeyPoints = @() }
        }
        if (-not (Test-Path $docFile)) {
            Write-LogError "Continuation plan document not found at: $docFile"
            return @{ Success = $false; Decision = ""; ThoughtsFile = ""; KeyPoints = @() }
        }
    }

    Write-LogInfo "Claude deliberation round $Round ($(if ($IsInitial) { 'initial' } else { 'refine' }))..."

    # Select appropriate prompt
    $promptTemplate = if ($IsInitial) {
        $Script:DeliberateDocInitialPrompt
    } else {
        $Script:DeliberateDocRefinePrompt
    }

    # Validate prompt template exists
    if (-not (Test-Path $promptTemplate)) {
        Write-LogError "Deliberation prompt template not found: $promptTemplate"
        return @{ Success = $false; Decision = ""; ThoughtsFile = ""; KeyPoints = @() }
    }

    # Read and substitute template (using .Replace() for literal substitution)
    $prompt = Get-Content $promptTemplate -Raw
    $prompt = $prompt.Replace('{{PLAN_FILE}}', $PlanFile)
    $prompt = $prompt.Replace('{{THOUGHTS_FILE}}', $thoughtsFile)
    $prompt = $prompt.Replace('{{DOC_FILE}}', $docFile)
    $prompt = $prompt.Replace('{{ROUND}}', $Round.ToString())
    $prompt = $prompt.Replace('{{PREVIOUS_CONTEXT}}', $(if ($PreviousContext) { $PreviousContext } else { "This is the first round. No previous context." }))
    $prompt = $prompt.Replace('{{CODEX_EVALUATION_FILE}}', $CodexEvaluationFile)
    $prompt = Apply-CommonTemplatePlaceholders -Content $prompt

    $retryResult = Invoke-ClaudeCommand -Prompt $prompt -AllowedTools "Read,Write,Edit,Glob,Grep" -ToolLabel "Claude (Doc Deliberation R$Round)" -TimeoutSec $AgentTimeoutSec
    $output = $retryResult.Output
    $exitCode = $retryResult.ExitCode
    $output | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

    if ($retryResult.TimedOut) {
        Write-LogError "Claude deliberation timed out after $AgentTimeoutSec seconds at round $Round"
        Write-RunEvent -Type "tool_timeout" -Level "error" -Data @{
            tool = "claude"
            phase = "document_deliberation"
            round = $Round
            timeoutSec = $AgentTimeoutSec
            mode = "document"
            message = "Claude document deliberation timed out after $AgentTimeoutSec seconds at round $Round."
        }
        return @{ Success = $false; Decision = ""; ThoughtsFile = ""; KeyPoints = @() }
    }

    if ($exitCode -ne 0) {
        Write-LogError "Claude deliberation failed with exit code $exitCode"
        Write-CLIErrorDetails -ToolLabel "Claude (Doc Deliberation)" -ExitCode $exitCode -Output $output
        return @{ Success = $false; Decision = ""; ThoughtsFile = ""; KeyPoints = @() }
    }

    # Read thoughts file and extract decision
    if (Test-Path $thoughtsFile) {
        $thoughts = Get-Content $thoughtsFile -Raw
        $decision = Extract-Decision -Content $thoughts
        $keyPoints = Extract-KeyPoints -Content $thoughts

        Write-LogSuccess "Claude deliberation round $Round complete - Decision: $decision"
        return @{
            Success = $true
            Decision = $decision
            ThoughtsFile = $thoughtsFile
            KeyPoints = $keyPoints
        }
    } else {
        Write-LogWarn "Thoughts file not created. Inferring decision from output."
        $decision = Extract-Decision -Content ($output -join "`n")
        return @{
            Success = $true
            Decision = $decision
            ThoughtsFile = ""
            KeyPoints = @()
        }
    }
}

function Invoke-CodexDeliberateDoc {
    param(
        [string]$PlanFile,
        [string]$PreviousContext,
        [int]$Round,
        [string]$ClaudeThoughtsFile,
        [string]$DocFile = ""
    )

    $evaluationFile = Join-Path $Script:DelibPhase0Dir "round${Round}_codex_evaluation.md"
    # Use passed DocFile if provided, otherwise search for it
    $docFile = if ($DocFile) { $DocFile } else { Get-ContinuationPlanPath }

    # Validate docFile exists
    if ([string]::IsNullOrWhiteSpace($docFile)) {
        Write-LogError "No continuation plan document found for Codex evaluation round $Round"
        return @{ Success = $false; Decision = ""; EvaluationFile = ""; KeyPoints = @() }
    }
    if (-not (Test-Path $docFile)) {
        Write-LogError "Continuation plan document not found at: $docFile"
        return @{ Success = $false; Decision = ""; EvaluationFile = ""; KeyPoints = @() }
    }

    Write-LogInfo "Codex deliberation round $Round..."

    $promptTemplate = $Script:DeliberateDocQCPrompt

    # Validate prompt template exists
    if (-not (Test-Path $promptTemplate)) {
        Write-LogError "Deliberation prompt template not found: $promptTemplate"
        return @{ Success = $false; Decision = ""; EvaluationFile = ""; KeyPoints = @() }
    }

    # Read and substitute template (using .Replace() for literal substitution)
    $prompt = Get-Content $promptTemplate -Raw
    $prompt = $prompt.Replace('{{PLAN_FILE}}', $PlanFile)
    $prompt = $prompt.Replace('{{DOC_FILE}}', $docFile)
    $prompt = $prompt.Replace('{{ROUND}}', $Round.ToString())
    $prompt = $prompt.Replace('{{CLAUDE_THOUGHTS_FILE}}', $ClaudeThoughtsFile)
    $prompt = $prompt.Replace('{{EVALUATION_FILE}}', $evaluationFile)
    $prompt = $prompt.Replace('{{PREVIOUS_CONTEXT}}', $(if ($PreviousContext) { $PreviousContext } else { "This is the first evaluation round." }))
    $prompt = Apply-CommonTemplatePlaceholders -Content $prompt

    $reportHeader = @"
# Codex Deliberation Report (Document Mode)
- **Generated**: $(Get-TimestampReadable)
- **Round**: $Round
- **Plan File**: $PlanFile
- **Pipeline ID**: $($Script:PipelineStartTime)

---

"@

    $codexResult = Invoke-CodexCommandWithArtifacts -Prompt $prompt -ReportFile $evaluationFile -ReportHeader $reportHeader -ToolLabel "Codex (Doc Deliberation R$Round)" -SandboxMode "workspace-write" -ReasoningEffort $ReasoningEffort -TimeoutSec $AgentTimeoutSec

    if (-not $codexResult.Success) {
        Write-LogError "Codex deliberation failed with exit code $($codexResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Codex (Doc Deliberation)" -ExitCode $codexResult.ExitCode -Output $codexResult.Output
        return @{ Success = $false; Decision = ""; EvaluationFile = ""; KeyPoints = @() }
    }

    # Extract decision from output
    $fullContent = Get-Content $evaluationFile -Raw
    $decision = Extract-Decision -Content $fullContent
    $keyPoints = Extract-KeyPoints -Content $fullContent

    Write-LogSuccess "Codex deliberation round $Round complete - Decision: $decision"
    return @{
        Success = $true
        Decision = $decision
        EvaluationFile = $evaluationFile
        KeyPoints = $keyPoints
    }
}

function Get-ContinuationPlanPath {
    # Prefer canonical root cycle plans, then fall back to the session-local draft directory.
    $searchDirs = @()

    if (-not [string]::IsNullOrWhiteSpace($Script:CyclesRoot) -and (Test-Path $Script:CyclesRoot -PathType Container)) {
        $searchDirs += $Script:CyclesRoot
    }

    if (
        -not [string]::IsNullOrWhiteSpace($Script:SessionCyclesDir) -and
        $Script:SessionCyclesDir -ne $Script:CyclesRoot -and
        (Test-Path $Script:SessionCyclesDir -PathType Container)
    ) {
        $searchDirs += $Script:SessionCyclesDir
    }

    foreach ($searchDir in $searchDirs) {
        $cycleFiles = Get-ChildItem -Path $searchDir -Filter "CONTINUATION_CYCLE_*.md" |
            Sort-Object -Property @(
                @{ Expression = 'LastWriteTime'; Descending = $true },
                @{ Expression = 'Name'; Descending = $true }
            )
        if ($cycleFiles.Count -gt 0) {
            return $cycleFiles[0].FullName
        }
    }

    return ""
}

function Get-CanonicalContinuationPlanPath {
    if ([string]::IsNullOrWhiteSpace($Script:CyclesRoot) -or -not (Test-Path $Script:CyclesRoot -PathType Container)) {
        return ""
    }

    $cycleFiles = Get-ChildItem -Path $Script:CyclesRoot -Filter "CONTINUATION_CYCLE_*.md" |
        Sort-Object -Property @(
            @{ Expression = 'LastWriteTime'; Descending = $true },
            @{ Expression = 'Name'; Descending = $true }
        )

    if ($cycleFiles.Count -gt 0) {
        return $cycleFiles[0].FullName
    }

    return ""
}

function Resume-DeliberationFailure {
    param([string]$PlanFile)

    if (-not $DeliberationMode) {
        Write-LogError "-ResumeFromFailure requires -DeliberationMode."
        return $false
    }

    if ($QCType -notin @("document", "code")) {
        Write-LogError "Resume is only supported for document and code deliberation sessions."
        return $false
    }

    $resumeState = Get-DeliberationResumeState -Mode $QCType
    if (-not $resumeState.Success) {
        Write-LogError $resumeState.Message
        Write-RunEvent -Type "${QCType}_deliberation_resume_failed" -Level "error" -Data @{
            planFile = $PlanFile
            qcType = $QCType
            message = $resumeState.Message
        }
        return $false
    }

    Write-LogInfo "Resume requested from saved deliberation state."
    Write-RunEvent -Type "${QCType}_deliberation_resume_requested" -Data @{
        planFile = $PlanFile
        qcType = $QCType
        startRound = $resumeState.StartRound
        nextAgent = $resumeState.NextAgent
        restoredRounds = @($resumeState.AllRounds).Count
        message = "Resuming $QCType deliberation from round $($resumeState.StartRound) with $($resumeState.NextAgent)."
    }

    if ($QCType -eq "document") {
        return Start-DocumentDeliberation -PlanFile $PlanFile -ResumeState $resumeState
    }

    return Start-CodeDeliberation -PlanFile $PlanFile -ResumeState $resumeState
}

function Start-DocumentDeliberation {
    param(
        [string]$PlanFile,
        [hashtable]$ResumeState = $null
    )

    $isResume = ($null -ne $ResumeState)
    $startRound = 1
    $resumeNextAgent = "claude"
    $roundAlreadyStarted = $false

    Update-RunState @{
        status = "running"
        phase = "document_deliberation"
        currentAction = $(if ($isResume) { "deliberation_resume" } else { "deliberation" })
        currentTool = ""
        currentDeliberationRound = 0
        lastError = ""
    }
    if ($isResume) {
        Write-RunEvent -Type "document_deliberation_resumed" -Data @{
            planFile = $PlanFile
            startRound = $ResumeState.StartRound
            nextAgent = $ResumeState.NextAgent
            restoredRounds = @($ResumeState.AllRounds).Count
            docFile = $ResumeState.DocPath
            message = "Resuming document deliberation from round $($ResumeState.StartRound) with $($ResumeState.NextAgent)."
        }
    }
    else {
        Write-RunEvent -Type "document_deliberation_started" -Data @{
            planFile = $PlanFile
            maxRounds = $MaxDeliberationRounds
            message = "Starting document deliberation ($MaxDeliberationRounds rounds max)"
        }
    }
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Phase 0: Document Deliberation Mode" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-LogInfo "Max deliberation rounds: $MaxDeliberationRounds"
    Write-LogInfo "Plan file: $PlanFile"
    if ($isResume) {
        Write-LogInfo "Resuming document deliberation from round $($ResumeState.StartRound) (next agent: $($ResumeState.NextAgent))"
    }

    $allRounds = if ($isResume) { @($ResumeState.AllRounds) } else { @() }
    $consecutiveMinor = if ($isResume) { [int]$ResumeState.ConsecutiveMinor } else { 0 }
    $consecutiveMajor = if ($isResume) { [int]$ResumeState.ConsecutiveMajor } else { 0 }
    $claudeDecision = if ($isResume) { [string]$ResumeState.ClaudeDecision } else { "" }
    $codexDecision = if ($isResume) { [string]$ResumeState.CodexDecision } else { "" }
    $claudeThoughtsFile = if ($isResume) { [string]$ResumeState.ClaudeThoughtsFile } else { "" }
    $codexEvaluationFile = if ($isResume) { [string]$ResumeState.CodexFeedbackFile } else { "" }
    $previousContext = if ($isResume) { [string]$ResumeState.PreviousContext } else { "" }

    if ($isResume) {
        $startRound = [Math]::Max([int]$ResumeState.StartRound, 1)
        $resumeNextAgent = if ($ResumeState.NextAgent) { $ResumeState.NextAgent.ToString().ToLowerInvariant() } else { "claude" }
        if ($resumeNextAgent -notin @("claude", "codex")) {
            $resumeNextAgent = "claude"
        }
        $roundAlreadyStarted = ([int]$ResumeState.LastStartedRound -eq $startRound)
        if (-not [string]::IsNullOrWhiteSpace($ResumeState.DocPath)) {
            $Script:DeliberationDocPath = $ResumeState.DocPath
        }
        if ($resumeNextAgent -eq "codex") {
            $claudeDecision = [string]$ResumeState.CurrentRoundClaudeDecision
            if ([string]::IsNullOrWhiteSpace($claudeThoughtsFile)) {
                Write-LogError "Resume state is missing Claude thoughts for round $startRound."
                return $false
            }
        }
    }

    # Severity gate: compute from the most recent Codex evaluation on disk (if any).
    # Recomputed each round from the just-written artifact; pre-populated on resume
    # so early exit paths in the first resumed round have a defined value.
    $delibSeverity = $null
    $hasBlockingSeverity = $false
    if ($isResume -and -not [string]::IsNullOrWhiteSpace($codexEvaluationFile) -and (Test-Path -LiteralPath $codexEvaluationFile)) {
        $delibSeverity = Get-DeliberationSeveritySummary -ArtifactPath $codexEvaluationFile
        $hasBlockingSeverity = [bool]$delibSeverity.HasBlockingSeverity
    }

    for ($round = $startRound; $round -le $MaxDeliberationRounds; $round++) {
        $reuseClaudeRound = ($isResume -and $round -eq $startRound -and $resumeNextAgent -eq "codex")
        $skipRoundStartedEvent = ($isResume -and $round -eq $startRound -and $roundAlreadyStarted)

        Update-RunState @{
            phase = "document_deliberation"
            currentAction = "deliberation_round"
            currentDeliberationRound = $round
        }
        if (-not $skipRoundStartedEvent) {
            Write-RunEvent -Type "document_deliberation_round_started" -Data @{
                round = $round
                maxRounds = $MaxDeliberationRounds
                resumed = [bool]$isResume
                message = "Deliberation round $round of $MaxDeliberationRounds"
            }
        }
        Write-LogInfo "--- Deliberation Round $round of $MaxDeliberationRounds ---"

        if ($reuseClaudeRound) {
            Update-RunState @{
                currentTool = "claude"
                currentAction = "claude_document_deliberation_reused"
                currentArtifact = $claudeThoughtsFile
                currentArtifactType = "claude_thoughts"
            }
            Write-LogInfo "Reusing Claude deliberation output from round ${round}: $claudeThoughtsFile"
            $previousContext = Get-DeliberationSummary -AllRounds $allRounds
        }
        else {
            # Claude's turn - pass stored doc path for subsequent rounds
            $isInitial = ($round -eq 1)
            $docPathForClaude = if ($Script:DeliberationDocPath) { $Script:DeliberationDocPath } else { "" }
            Update-RunState @{
                currentTool = "claude"
                currentAction = $(if ($isInitial) { "claude_document_deliberation_initial" } else { "claude_document_deliberation_refine" })
            }
            $claudeResult = Invoke-ClaudeDeliberateDoc -PlanFile $PlanFile -PreviousContext $previousContext -Round $round -IsInitial $isInitial -CodexEvaluationFile $codexEvaluationFile -DocFile $docPathForClaude

            if (-not $claudeResult.Success) {
                Write-LogError "Claude deliberation failed at round $round"
                return $false
            }

            # After round 1, validate that Claude created the continuation plan
            if ($round -eq 1) {
                $createdDocPath = Get-CanonicalContinuationPlanPath
                if ([string]::IsNullOrWhiteSpace($createdDocPath)) {
                    Write-LogError "Claude did not create continuation plan document in round 1."
                    Write-LogError "Expected file matching pattern in the canonical cycle directory $($Script:CyclesRoot): CONTINUATION_CYCLE_*.md"
                    Write-LogInfo "Check Claude's output in the log file for details."
                    return $false
                }
                Write-LogSuccess "Continuation plan created: $createdDocPath"
                # Store the path for subsequent rounds
                $Script:DeliberationDocPath = $createdDocPath
                Update-RunState @{
                    currentArtifact = $createdDocPath
                    currentArtifactType = "continuation_plan"
                }
                Write-RunEvent -Type "continuation_plan_created" -Data @{
                    round = $round
                    path = $createdDocPath
                    message = "Continuation plan created: $(Split-Path $createdDocPath -Leaf)"
                }
            }

            $claudeDecision = $claudeResult.Decision
            $claudeThoughtsFile = $claudeResult.ThoughtsFile
            Update-RunState @{
                currentTool = "claude"
                currentArtifact = $claudeThoughtsFile
                currentArtifactType = "claude_thoughts"
            }
            $allRounds += @{
                Number = $round
                Agent = "Claude"
                Decision = $claudeDecision
                KeyPoints = $claudeResult.KeyPoints
            }

            # Update context for Codex
            $previousContext = Get-DeliberationSummary -AllRounds $allRounds
        }

        # Codex's turn - use stored document path
        $docPathForCodex = if ($Script:DeliberationDocPath) { $Script:DeliberationDocPath } else { Get-ContinuationPlanPath }
        Update-RunState @{
            currentTool = "codex"
            currentAction = "codex_document_deliberation_review"
        }
        $codexResult = Invoke-CodexDeliberateDoc -PlanFile $PlanFile -PreviousContext $previousContext -Round $round -ClaudeThoughtsFile $claudeThoughtsFile -DocFile $docPathForCodex

        if (-not $codexResult.Success) {
            Write-LogError "Codex deliberation failed at round $round"
            return $false
        }

        $codexDecision = $codexResult.Decision
        $codexEvaluationFile = $codexResult.EvaluationFile
        Update-RunState @{
            currentTool = "codex"
            currentArtifact = $codexEvaluationFile
            currentArtifactType = "codex_evaluation"
        }
        $allRounds += @{
            Number = $round
            Agent = "Codex"
            Decision = $codexDecision
            KeyPoints = $codexResult.KeyPoints
        }

        # Severity gate: compute remaining-issue severity from the just-written
        # Codex evaluation (authoritative post-fix state). CRITICAL/HIGH vetoes
        # convergence for this round.
        $delibSeverity = Get-DeliberationSeveritySummary -ArtifactPath $codexEvaluationFile
        $hasBlockingSeverity = [bool]$delibSeverity.HasBlockingSeverity
        if ($hasBlockingSeverity) {
            Write-LogWarn "Document deliberation round ${round}: blocking severity remains ($($delibSeverity.SeverityList -join ', ')); convergence vetoed."
            Write-RunEvent -Type "deliberation_convergence_vetoed" -Level "warn" -Data @{
                phase          = "document"
                round          = $round
                sourceArtifact = $codexEvaluationFile
                severityList   = $delibSeverity.SeverityList
                claudeDecision = $claudeDecision
                codexDecision  = $codexDecision
                message        = "Convergence vetoed at round $round by unresolved CRITICAL/HIGH severity"
            }
        }

        # Update context for next Claude round
        $previousContext = Get-DeliberationSummary -AllRounds $allRounds

        # Early exit: Check convergence on round 1
        if ($round -eq 1 -and (Test-Convergence -ClaudeDecision $claudeDecision -CodexDecision $codexDecision -ConsecutiveMinorRounds 0 -HasBlockingSeverity $hasBlockingSeverity)) {
            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Green
            Write-Host "DOCUMENT DELIBERATION CONVERGED (early exit - round 1)" -ForegroundColor Green
            Write-Host "============================================================" -ForegroundColor Green
            Write-LogInfo "Both agents agreed on first round. Skipping further rounds."

            $summaryFile = Join-Path $Script:DelibPhase0Dir "deliberation_summary.md"
            $previousContext | Out-File -FilePath $summaryFile -Encoding UTF8
            Write-LogInfo "Deliberation summary: $summaryFile"
            Update-RunState @{
                currentArtifact = $summaryFile
                currentArtifactType = "deliberation_summary"
            }
            Write-RunEvent -Type "document_deliberation_converged" -Data @{
                round = $round
                summaryFile = $summaryFile
                earlyExit = $true
                claudeDecision = $claudeDecision
                codexDecision = $codexDecision
                severityList = $delibSeverity.SeverityList
                message = "Document deliberation converged at round $round (early exit)"
            }

            return $true
        }

        # Track consecutive minor refinements (only when BOTH say MINOR_REFINEMENT)
        if ($claudeDecision -eq "MINOR_REFINEMENT" -and $codexDecision -eq "MINOR_REFINEMENT") {
            $consecutiveMinor++
        } elseif ($claudeDecision -eq "MAJOR_REFINEMENT" -or $codexDecision -eq "MAJOR_REFINEMENT") {
            $consecutiveMinor = 0
            $consecutiveMajor++
            # Warn about persistent disagreement
            if ($consecutiveMajor -ge 3) {
                Write-LogWarn "Persistent disagreement detected: $consecutiveMajor consecutive rounds with MAJOR_REFINEMENT"
            }
        } else {
            # Mixed decisions (one CONVERGED, other MINOR) - don't count toward soft convergence
            $consecutiveMajor = 0
        }

        # Check for convergence
        if (Test-Convergence -ClaudeDecision $claudeDecision -CodexDecision $codexDecision -ConsecutiveMinorRounds $consecutiveMinor -HasBlockingSeverity $hasBlockingSeverity) {
            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Green
            Write-Host "DOCUMENT DELIBERATION CONVERGED on round $round" -ForegroundColor Green
            Write-Host "============================================================" -ForegroundColor Green
            Write-LogInfo "Final decisions - Claude: $claudeDecision, Codex: $codexDecision"

            # Save deliberation summary
            $summaryFile = Join-Path $Script:DelibPhase0Dir "deliberation_summary.md"
            $previousContext | Out-File -FilePath $summaryFile -Encoding UTF8
            Write-LogInfo "Deliberation summary: $summaryFile"
            Update-RunState @{
                currentArtifact = $summaryFile
                currentArtifactType = "deliberation_summary"
            }
            Write-RunEvent -Type "document_deliberation_converged" -Data @{
                round = $round
                summaryFile = $summaryFile
                earlyExit = $false
                claudeDecision = $claudeDecision
                codexDecision = $codexDecision
                severityList = $delibSeverity.SeverityList
                message = "Document deliberation converged at round $round (Claude: $claudeDecision, Codex: $codexDecision)"
            }

            return $true
        }

        $resumeNextAgent = "claude"
        $roundAlreadyStarted = $false
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "DOCUMENT DELIBERATION reached max rounds ($MaxDeliberationRounds)" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-LogWarn "Final decisions - Claude: $claudeDecision, Codex: $codexDecision"

    # Save summary anyway
    $summaryFile = Join-Path $Script:DelibPhase0Dir "deliberation_summary.md"
    $previousContext | Out-File -FilePath $summaryFile -Encoding UTF8
    Update-RunState @{
        currentArtifact = $summaryFile
        currentArtifactType = "deliberation_summary"
    }
    $maxRoundsSeverityList = if ($delibSeverity) { $delibSeverity.SeverityList } else { @() }
    $maxRoundsMessage = if ($hasBlockingSeverity) {
        "Document deliberation reached max rounds with unresolved blocking severity ($($maxRoundsSeverityList -join ', '))"
    } else {
        "Document deliberation reached max rounds ($MaxDeliberationRounds) without full convergence"
    }
    Write-RunEvent -Type "document_deliberation_max_rounds_reached" -Level "warn" -Data @{
        maxRounds = $MaxDeliberationRounds
        summaryFile = $summaryFile
        claudeDecision = $claudeDecision
        codexDecision = $codexDecision
        hasBlockingSeverity = $hasBlockingSeverity
        severityList = $maxRoundsSeverityList
        message = $maxRoundsMessage
    }

    return $true  # Continue with what we have
}

# =============================================================================
# Code Deliberation Functions
# =============================================================================

function Invoke-ClaudeDeliberateCode {
    param(
        [string]$PlanFile,
        [string]$PreviousContext,
        [int]$Round,
        [bool]$IsInitial,
        [string]$CodexReviewFile = ""
    )

    $thoughtsFile = Join-Path $Script:DelibPhase1Dir "round${Round}_claude_thoughts.md"

    Write-LogInfo "Claude code deliberation round $Round ($(if ($IsInitial) { 'implement' } else { 'refine' }))..."

    # Select appropriate prompt
    $promptTemplate = if ($IsInitial) {
        $Script:DeliberateCodeInitialPrompt
    } else {
        $Script:DeliberateCodeRefinePrompt
    }

    # Validate prompt template exists
    if (-not (Test-Path $promptTemplate)) {
        Write-LogError "Deliberation prompt template not found: $promptTemplate"
        return @{ Success = $false; Decision = ""; ThoughtsFile = ""; KeyPoints = @() }
    }

    # Read and substitute template (using .Replace() for literal substitution)
    $prompt = Get-Content $promptTemplate -Raw
    $prompt = $prompt.Replace('{{PLAN_FILE}}', $PlanFile)
    $prompt = $prompt.Replace('{{THOUGHTS_FILE}}', $thoughtsFile)
    $prompt = $prompt.Replace('{{ROUND}}', $Round.ToString())
    $prompt = $prompt.Replace('{{PREVIOUS_CONTEXT}}', $(if ($PreviousContext) { $PreviousContext } else { "This is the first round. No previous context." }))
    $prompt = $prompt.Replace('{{CODEX_REVIEW_FILE}}', $CodexReviewFile)
    $prompt = Apply-CommonTemplatePlaceholders -Content $prompt

    $retryResult = Invoke-ClaudeCommand -Prompt $prompt -AllowedTools "Bash(git:*),Read,Write,Edit,Glob,Grep" -ToolLabel "Claude (Code Deliberation R$Round)" -TimeoutSec $AgentTimeoutSec
    $output = $retryResult.Output
    $exitCode = $retryResult.ExitCode
    $output | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

    if ($retryResult.TimedOut) {
        Write-LogError "Claude code deliberation timed out after $AgentTimeoutSec seconds at round $Round"
        Write-RunEvent -Type "tool_timeout" -Level "error" -Data @{
            tool = "claude"
            phase = "code_deliberation"
            round = $Round
            timeoutSec = $AgentTimeoutSec
            mode = "code"
            message = "Claude code deliberation timed out after $AgentTimeoutSec seconds at round $Round."
        }
        return @{ Success = $false; Decision = ""; ThoughtsFile = ""; KeyPoints = @() }
    }

    if ($exitCode -ne 0) {
        Write-LogError "Claude code deliberation failed with exit code $exitCode"
        Write-CLIErrorDetails -ToolLabel "Claude (Code Deliberation)" -ExitCode $exitCode -Output $output
        return @{ Success = $false; Decision = ""; ThoughtsFile = ""; KeyPoints = @() }
    }

    # Read thoughts file and extract decision
    if (Test-Path $thoughtsFile) {
        $thoughts = Get-Content $thoughtsFile -Raw
        $decision = Extract-Decision -Content $thoughts
        $keyPoints = Extract-KeyPoints -Content $thoughts

        Write-LogSuccess "Claude code deliberation round $Round complete - Decision: $decision"
        return @{
            Success = $true
            Decision = $decision
            ThoughtsFile = $thoughtsFile
            KeyPoints = $keyPoints
        }
    } else {
        Write-LogWarn "Thoughts file not created. Inferring decision from output."
        $decision = Extract-Decision -Content ($output -join "`n")
        return @{
            Success = $true
            Decision = $decision
            ThoughtsFile = ""
            KeyPoints = @()
        }
    }
}

function Invoke-CodexDeliberateCode {
    param(
        [string]$PlanFile,
        [string]$PreviousContext,
        [int]$Round,
        [string]$ClaudeThoughtsFile
    )

    $reviewFile = Join-Path $Script:DelibPhase1Dir "round${Round}_codex_review.md"

    Write-LogInfo "Codex code review round $Round..."

    $promptTemplate = $Script:DeliberateCodeQCPrompt

    # Validate prompt template exists
    if (-not (Test-Path $promptTemplate)) {
        Write-LogError "Deliberation prompt template not found: $promptTemplate"
        return @{ Success = $false; Decision = ""; ReviewFile = ""; KeyPoints = @() }
    }

    # Read and substitute template (using .Replace() for literal substitution)
    $prompt = Get-Content $promptTemplate -Raw
    $prompt = $prompt.Replace('{{PLAN_FILE}}', $PlanFile)
    $prompt = $prompt.Replace('{{ROUND}}', $Round.ToString())
    $prompt = $prompt.Replace('{{CLAUDE_THOUGHTS_FILE}}', $ClaudeThoughtsFile)
    $prompt = $prompt.Replace('{{REVIEW_FILE}}', $reviewFile)
    $prompt = $prompt.Replace('{{PREVIOUS_CONTEXT}}', $(if ($PreviousContext) { $PreviousContext } else { "This is the first review round." }))
    $prompt = Apply-CommonTemplatePlaceholders -Content $prompt

    $reportHeader = @"
# Codex Code Review (Deliberation Mode)
- **Generated**: $(Get-TimestampReadable)
- **Round**: $Round
- **Plan File**: $PlanFile
- **Pipeline ID**: $($Script:PipelineStartTime)

---

"@

    $codexResult = Invoke-CodexCommandWithArtifacts -Prompt $prompt -ReportFile $reviewFile -ReportHeader $reportHeader -ToolLabel "Codex (Code Review R$Round)" -SandboxMode "workspace-write" -ReasoningEffort $ReasoningEffort -TimeoutSec $AgentTimeoutSec

    if (-not $codexResult.Success) {
        Write-LogError "Codex code review failed with exit code $($codexResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Codex (Code Review)" -ExitCode $codexResult.ExitCode -Output $codexResult.Output
        return @{ Success = $false; Decision = ""; ReviewFile = ""; KeyPoints = @() }
    }

    # Extract decision from output
    $fullContent = Get-Content $reviewFile -Raw
    $decision = Extract-Decision -Content $fullContent
    $keyPoints = Extract-KeyPoints -Content $fullContent

    Write-LogSuccess "Codex code review round $Round complete - Decision: $decision"
    return @{
        Success = $true
        Decision = $decision
        ReviewFile = $reviewFile
        KeyPoints = $keyPoints
    }
}

function Start-CodeDeliberation {
    param(
        [string]$PlanFile,
        [hashtable]$ResumeState = $null
    )

    $isResume = ($null -ne $ResumeState)
    $startRound = 1
    $resumeNextAgent = "claude"
    $roundAlreadyStarted = $false

    Update-RunState @{
        status = "running"
        phase = "code_deliberation"
        currentAction = $(if ($isResume) { "deliberation_resume" } else { "deliberation" })
        currentTool = ""
        currentDeliberationRound = 0
        lastError = ""
    }
    if ($isResume) {
        Write-RunEvent -Type "code_deliberation_resumed" -Data @{
            planFile = $PlanFile
            startRound = $ResumeState.StartRound
            nextAgent = $ResumeState.NextAgent
            restoredRounds = @($ResumeState.AllRounds).Count
            message = "Resuming code deliberation from round $($ResumeState.StartRound) with $($ResumeState.NextAgent)."
        }
    }
    else {
        Write-RunEvent -Type "code_deliberation_started" -Data @{
            planFile = $PlanFile
            maxRounds = $MaxDeliberationRounds
            message = "Starting code deliberation ($MaxDeliberationRounds rounds max)"
        }
    }
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Phase 1+2: Code Deliberation Mode" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-LogInfo "Max deliberation rounds: $MaxDeliberationRounds"
    Write-LogInfo "Plan file: $PlanFile"
    if ($isResume) {
        Write-LogInfo "Resuming code deliberation from round $($ResumeState.StartRound) (next agent: $($ResumeState.NextAgent))"
    }

    $allRounds = if ($isResume) { @($ResumeState.AllRounds) } else { @() }
    $consecutiveMinor = if ($isResume) { [int]$ResumeState.ConsecutiveMinor } else { 0 }
    $consecutiveMajor = if ($isResume) { [int]$ResumeState.ConsecutiveMajor } else { 0 }
    $claudeDecision = if ($isResume) { [string]$ResumeState.ClaudeDecision } else { "" }
    $codexDecision = if ($isResume) { [string]$ResumeState.CodexDecision } else { "" }
    $claudeThoughtsFile = if ($isResume) { [string]$ResumeState.ClaudeThoughtsFile } else { "" }
    $codexReviewFile = if ($isResume) { [string]$ResumeState.CodexFeedbackFile } else { "" }
    $previousContext = if ($isResume) { [string]$ResumeState.PreviousContext } else { "" }

    if ($isResume) {
        $startRound = [Math]::Max([int]$ResumeState.StartRound, 1)
        $resumeNextAgent = if ($ResumeState.NextAgent) { $ResumeState.NextAgent.ToString().ToLowerInvariant() } else { "claude" }
        if ($resumeNextAgent -notin @("claude", "codex")) {
            $resumeNextAgent = "claude"
        }
        $roundAlreadyStarted = ([int]$ResumeState.LastStartedRound -eq $startRound)
        if ($resumeNextAgent -eq "codex") {
            $claudeDecision = [string]$ResumeState.CurrentRoundClaudeDecision
            if ([string]::IsNullOrWhiteSpace($claudeThoughtsFile)) {
                Write-LogError "Resume state is missing Claude thoughts for round $startRound."
                return $false
            }
        }
    }

    # Severity gate: compute from the most recent Codex review on disk (if any).
    # Recomputed each round from the just-written artifact; pre-populated on resume
    # so early exit paths in the first resumed round have a defined value.
    $delibSeverity = $null
    $hasBlockingSeverity = $false
    if ($isResume -and -not [string]::IsNullOrWhiteSpace($codexReviewFile) -and (Test-Path -LiteralPath $codexReviewFile)) {
        $delibSeverity = Get-DeliberationSeveritySummary -ArtifactPath $codexReviewFile
        $hasBlockingSeverity = [bool]$delibSeverity.HasBlockingSeverity
    }

    for ($round = $startRound; $round -le $MaxDeliberationRounds; $round++) {
        $reuseClaudeRound = ($isResume -and $round -eq $startRound -and $resumeNextAgent -eq "codex")
        $skipRoundStartedEvent = ($isResume -and $round -eq $startRound -and $roundAlreadyStarted)

        Update-RunState @{
            phase = "code_deliberation"
            currentAction = "deliberation_round"
            currentDeliberationRound = $round
        }
        if (-not $skipRoundStartedEvent) {
            Write-RunEvent -Type "code_deliberation_round_started" -Data @{
                round = $round
                maxRounds = $MaxDeliberationRounds
                resumed = [bool]$isResume
                message = "Code deliberation round $round of $MaxDeliberationRounds"
            }
        }
        Write-LogInfo "--- Code Deliberation Round $round of $MaxDeliberationRounds ---"

        if ($reuseClaudeRound) {
            Update-RunState @{
                currentTool = "claude"
                currentAction = "claude_code_deliberation_reused"
                currentArtifact = $claudeThoughtsFile
                currentArtifactType = "claude_thoughts"
            }
            Write-LogInfo "Reusing Claude code deliberation output from round ${round}: $claudeThoughtsFile"
            $previousContext = Get-DeliberationSummary -AllRounds $allRounds
        }
        else {
            # Claude's turn
            $isInitial = ($round -eq 1)
            Update-RunState @{
                currentTool = "claude"
                currentAction = $(if ($isInitial) { "claude_code_deliberation_initial" } else { "claude_code_deliberation_refine" })
            }
            $claudeResult = Invoke-ClaudeDeliberateCode -PlanFile $PlanFile -PreviousContext $previousContext -Round $round -IsInitial $isInitial -CodexReviewFile $codexReviewFile

            if (-not $claudeResult.Success) {
                Write-LogError "Claude code deliberation failed at round $round"
                return $false
            }

            $claudeDecision = $claudeResult.Decision
            $claudeThoughtsFile = $claudeResult.ThoughtsFile
            Update-RunState @{
                currentTool = "claude"
                currentArtifact = $claudeThoughtsFile
                currentArtifactType = "claude_thoughts"
            }
            $allRounds += @{
                Number = $round
                Agent = "Claude"
                Decision = $claudeDecision
                KeyPoints = $claudeResult.KeyPoints
            }

            # Update context for Codex
            $previousContext = Get-DeliberationSummary -AllRounds $allRounds
        }

        # Codex's turn
        Update-RunState @{
            currentTool = "codex"
            currentAction = "codex_code_deliberation_review"
        }
        $codexResult = Invoke-CodexDeliberateCode -PlanFile $PlanFile -PreviousContext $previousContext -Round $round -ClaudeThoughtsFile $claudeThoughtsFile

        if (-not $codexResult.Success) {
            Write-LogError "Codex code review failed at round $round"
            return $false
        }

        $codexDecision = $codexResult.Decision
        $codexReviewFile = $codexResult.ReviewFile
        Update-RunState @{
            currentTool = "codex"
            currentArtifact = $codexReviewFile
            currentArtifactType = "codex_review"
        }
        $allRounds += @{
            Number = $round
            Agent = "Codex"
            Decision = $codexDecision
            KeyPoints = $codexResult.KeyPoints
        }

        # Severity gate: compute remaining-issue severity from the just-written
        # Codex review (authoritative post-fix state). CRITICAL/HIGH vetoes
        # convergence for this round.
        $delibSeverity = Get-DeliberationSeveritySummary -ArtifactPath $codexReviewFile
        $hasBlockingSeverity = [bool]$delibSeverity.HasBlockingSeverity
        if ($hasBlockingSeverity) {
            Write-LogWarn "Code deliberation round ${round}: blocking severity remains ($($delibSeverity.SeverityList -join ', ')); convergence vetoed."
            Write-RunEvent -Type "deliberation_convergence_vetoed" -Level "warn" -Data @{
                phase          = "code"
                round          = $round
                sourceArtifact = $codexReviewFile
                severityList   = $delibSeverity.SeverityList
                claudeDecision = $claudeDecision
                codexDecision  = $codexDecision
                message        = "Convergence vetoed at round $round by unresolved CRITICAL/HIGH severity"
            }
        }

        # Update context for next Claude round
        $previousContext = Get-DeliberationSummary -AllRounds $allRounds

        # Early exit: Check convergence on round 1
        if ($round -eq 1 -and (Test-Convergence -ClaudeDecision $claudeDecision -CodexDecision $codexDecision -ConsecutiveMinorRounds 0 -HasBlockingSeverity $hasBlockingSeverity)) {
            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Green
            Write-Host "CODE DELIBERATION CONVERGED (early exit - round 1)" -ForegroundColor Green
            Write-Host "============================================================" -ForegroundColor Green
            Write-LogInfo "Both agents agreed on first round. Skipping further rounds."

            $summaryFile = Join-Path $Script:DelibPhase1Dir "deliberation_summary.md"
            $completionInfo = @"
$previousContext

---
## Completion Status
- **Status:** COMPLETED
- **Converged on round:** $round
- **Timestamp:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
- **Plan file:** $PlanFile
"@
            $completionInfo | Out-File -FilePath $summaryFile -Encoding UTF8
            Write-LogInfo "Deliberation summary: $summaryFile"
            Update-RunState @{
                currentArtifact = $summaryFile
                currentArtifactType = "deliberation_summary"
            }
            Write-RunEvent -Type "code_deliberation_converged" -Data @{
                round = $round
                summaryFile = $summaryFile
                earlyExit = $true
                claudeDecision = $claudeDecision
                codexDecision = $codexDecision
                severityList = $delibSeverity.SeverityList
                message = "Code deliberation converged at round $round (early exit)"
            }

            return $true
        }

        # Track consecutive minor refinements (only when BOTH say MINOR_REFINEMENT)
        if ($claudeDecision -eq "MINOR_REFINEMENT" -and $codexDecision -eq "MINOR_REFINEMENT") {
            $consecutiveMinor++
        } elseif ($claudeDecision -eq "MAJOR_REFINEMENT" -or $codexDecision -eq "MAJOR_REFINEMENT") {
            $consecutiveMinor = 0
            $consecutiveMajor++
            # Warn about persistent disagreement
            if ($consecutiveMajor -ge 3) {
                Write-LogWarn "Persistent disagreement detected: $consecutiveMajor consecutive rounds with MAJOR_REFINEMENT"
            }
        } else {
            # Mixed decisions (one CONVERGED, other MINOR) - don't count toward soft convergence
            $consecutiveMajor = 0
        }

        # Check for convergence
        if (Test-Convergence -ClaudeDecision $claudeDecision -CodexDecision $codexDecision -ConsecutiveMinorRounds $consecutiveMinor -HasBlockingSeverity $hasBlockingSeverity) {
            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Green
            Write-Host "CODE DELIBERATION CONVERGED on round $round" -ForegroundColor Green
            Write-Host "============================================================" -ForegroundColor Green
            Write-LogInfo "Final decisions - Claude: $claudeDecision, Codex: $codexDecision"

            # Save deliberation summary with completion status
            $summaryFile = Join-Path $Script:DelibPhase1Dir "deliberation_summary.md"
            $completionInfo = @"
$previousContext

---
## Completion Status
- **Status:** COMPLETED
- **Converged on round:** $round
- **Timestamp:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
- **Plan file:** $PlanFile
"@
            $completionInfo | Out-File -FilePath $summaryFile -Encoding UTF8
            Write-LogInfo "Deliberation summary: $summaryFile"
            Update-RunState @{
                currentArtifact = $summaryFile
                currentArtifactType = "deliberation_summary"
            }
            Write-RunEvent -Type "code_deliberation_converged" -Data @{
                round = $round
                summaryFile = $summaryFile
                earlyExit = $false
                claudeDecision = $claudeDecision
                codexDecision = $codexDecision
                severityList = $delibSeverity.SeverityList
                message = "Code deliberation converged at round $round (Claude: $claudeDecision, Codex: $codexDecision)"
            }

            return $true
        }

        $resumeNextAgent = "claude"
        $roundAlreadyStarted = $false
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "CODE DELIBERATION reached max rounds ($MaxDeliberationRounds)" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-LogWarn "Final decisions - Claude: $claudeDecision, Codex: $codexDecision"

    # Save summary anyway
    $summaryFile = Join-Path $Script:DelibPhase1Dir "deliberation_summary.md"
    $previousContext | Out-File -FilePath $summaryFile -Encoding UTF8
    Update-RunState @{
        currentArtifact = $summaryFile
        currentArtifactType = "deliberation_summary"
    }
    $maxRoundsSeverityList = if ($delibSeverity) { $delibSeverity.SeverityList } else { @() }
    $maxRoundsMessage = if ($hasBlockingSeverity) {
        "Code deliberation reached max rounds with unresolved blocking severity ($($maxRoundsSeverityList -join ', '))"
    } else {
        "Code deliberation reached max rounds ($MaxDeliberationRounds) without full convergence"
    }
    Write-RunEvent -Type "code_deliberation_max_rounds_reached" -Level "warn" -Data @{
        maxRounds = $MaxDeliberationRounds
        summaryFile = $summaryFile
        claudeDecision = $claudeDecision
        codexDecision = $codexDecision
        hasBlockingSeverity = $hasBlockingSeverity
        severityList = $maxRoundsSeverityList
        message = $maxRoundsMessage
    }

    return $true  # Continue with what we have
}

function Invoke-ClaudeCommand {
    param(
        [string]$Prompt,
        [string]$AllowedTools,
        [string]$ToolLabel,
        [int]$TimeoutSec = 0,
        [switch]$UseMaxEffort,
        [string]$PermissionMode = ""
    )

    $claudeArgs = @("-p")
    $claudeCommandPath = Get-ClaudeCommandPath
    if ($UseMaxEffort) {
        if (Test-ClaudeEffortSupport -ClaudeCommandPath $claudeCommandPath) {
            $claudeArgs += @("--effort", "max")
        }
        else {
            Write-LogWarn "Claude CLI at '$claudeCommandPath' does not support '--effort'; running without explicit effort level."
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($PermissionMode)) {
        $claudeArgs += @("--permission-mode", $PermissionMode)
    }
    $claudeArgs += @("--allowedTools", $AllowedTools)

    if ($TimeoutSec -gt 0) {
        return Invoke-ExternalProcessWithTimeout -FilePath $claudeCommandPath -ArgumentList $claudeArgs -InputText $Prompt -TimeoutSec $TimeoutSec
    }

    $retryResult = Invoke-WithRetry -ToolLabel $ToolLabel -Command {
        $Prompt | & $claudeCommandPath @claudeArgs
    }
    $retryResult.TimedOut = $false
    return $retryResult
}

function Test-ClaudeOutputRequestsWriteApproval {
    param([object]$Output)

    $outputText = (Convert-CLIOutputToText -Output $Output).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($outputText)) {
        return $false
    }

    $patterns = @(
        'write was denied',
        'write is being blocked',
        'please approve the write',
        'approve the write to',
        'requires user approval',
        'permission settings',
        'blocked by permission',
        'approval to write'
    )

    foreach ($pattern in $patterns) {
        if ($outputText.Contains($pattern)) {
            return $true
        }
    }

    return $false
}

function Test-MetaReviewOutputFileReady {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path $FilePath -PathType Leaf)) {
        return $false
    }

    try {
        $content = Get-Content -Path $FilePath -Raw -ErrorAction Stop
        return -not [string]::IsNullOrWhiteSpace($content)
    }
    catch {
        return $false
    }
}

function Get-MetaReviewOutputContentFromClaudeResponse {
    param([object]$Output)

    $outputText = Convert-CLIOutputToText -Output $Output
    if ([string]::IsNullOrWhiteSpace($outputText)) {
        return ""
    }

    $match = [regex]::Match($outputText, '(?s)<<<META_REVIEW_OUTPUT_START>>>\s*(.*?)\s*<<<META_REVIEW_OUTPUT_END>>>')
    if (-not $match.Success) {
        return ""
    }

    $content = [string]$match.Groups[1].Value
    return ($content -replace "^\uFEFF", "").Trim("`r", "`n")
}

function Save-MetaReviewOutputFromClaudeResponse {
    param(
        [string]$StageLabel,
        [string]$EventType,
        [object]$Output
    )

    if (-not $MetaReview) {
        return $true
    }

    $permissionBlocked = Test-ClaudeOutputRequestsWriteApproval -Output $Output
    $content = Get-MetaReviewOutputContentFromClaudeResponse -Output $Output

    if (-not [string]::IsNullOrWhiteSpace($content)) {
        $outputDirectory = Split-Path -Path $Script:MetaReviewOutputFile -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $content | Out-File -FilePath $Script:MetaReviewOutputFile -Encoding UTF8
        if (Test-MetaReviewOutputFileReady -FilePath $Script:MetaReviewOutputFile) {
            return $true
        }
    }

    $message = if ($permissionBlocked) {
        "Claude $StageLabel requested write approval for $($Script:MetaReviewOutputFile) instead of returning reviewed meta-plan content."
    }
    elseif ([string]::IsNullOrWhiteSpace($content)) {
        "Claude $StageLabel did not return reviewed meta-plan content between the required output markers."
    }
    else {
        "Claude $StageLabel returned reviewed meta-plan content, but the pipeline could not persist it to $($Script:MetaReviewOutputFile)."
    }

    Update-RunState @{
        lastError = $message
    }
    Write-LogError $message
    Write-RunEvent -Type $EventType -Level "error" -Data @{
        tool = "claude"
        metaReview = [bool]$MetaReview
        metaReviewOutputFile = $Script:MetaReviewOutputFile
        permissionBlocked = $permissionBlocked
        message = $message
    }
    return $false
}

function Split-MetaReviewRelayCodexMessage {
    param([string]$Content)

    $text = if ($null -eq $Content) { "" } else { [string]$Content }
    $match = [regex]::Match($text, '(?s)<<<META_REVIEW_REPLACEMENT_DRAFT_START>>>\s*(.*?)\s*<<<META_REVIEW_REPLACEMENT_DRAFT_END>>>')
    $replacementDraft = ""
    if ($match.Success) {
        $replacementDraft = ($match.Groups[1].Value -replace "^\uFEFF", "").Trim("`r", "`n")
        $text = ($text.Remove($match.Index, $match.Length)).Trim()
    }

    return @{
        Report = $text.Trim()
        ReplacementDraft = $replacementDraft
    }
}

function Get-MetaReviewReplacementDraftArtifactPath {
    param(
        [int]$Iteration,
        [string]$Timestamp
    )

    return Join-Path $Script:LogsDir "meta_review_codex_replacement_iter${Iteration}_$Timestamp.md"
}

function Save-MetaReviewReplacementDraftArtifact {
    param(
        [string]$Content,
        [int]$Iteration,
        [string]$Timestamp
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ""
    }

    $draftPath = Get-MetaReviewReplacementDraftArtifactPath -Iteration $Iteration -Timestamp $Timestamp
    $Content | Out-File -FilePath $draftPath -Encoding UTF8
    $Script:MetaReviewReplacementDraftFile = $draftPath
    return $draftPath
}

function Finalize-MetaReviewRelayCodexResult {
    param(
        [string]$ReportHeader,
        [string]$Timestamp,
        [hashtable]$CodexResult
    )

    $split = Split-MetaReviewRelayCodexMessage -Content $CodexResult.FinalMessage
    $reportBody = $split.Report
    $replacementDraft = $split.ReplacementDraft

    if ([string]::IsNullOrWhiteSpace($reportBody)) {
        Write-CodexFailureReport -ReportFile $Script:CurrentQCReport -ReportHeader $ReportHeader -ToolLabel "Codex (Meta Review Relay)" -ExitCode 1 -TranscriptFile $CodexResult.TranscriptFile -FailureReason "Codex relay review did not return a structured QC report body."
        return @{
            Success = $false
            ReplacementDraftFile = ""
        }
    }

    Write-MarkdownArtifact -FilePath $Script:CurrentQCReport -Header $ReportHeader -Body $reportBody

    $hasPass = $reportBody -match '## QC Status: PASS'
    $hasFail = $reportBody -match '## QC Status: FAIL'
    if (($hasPass -and $hasFail) -or (-not $hasPass -and -not $hasFail)) {
        Write-CodexFailureReport -ReportFile $Script:CurrentQCReport -ReportHeader $ReportHeader -ToolLabel "Codex (Meta Review Relay)" -ExitCode 1 -TranscriptFile $CodexResult.TranscriptFile -FailureReason "Codex relay review did not return exactly one structured QC status."
        return @{
            Success = $false
            ReplacementDraftFile = ""
        }
    }

    $replacementDraftFile = ""
    if ($hasFail) {
        if ([string]::IsNullOrWhiteSpace($replacementDraft)) {
            Write-CodexFailureReport -ReportFile $Script:CurrentQCReport -ReportHeader $ReportHeader -ToolLabel "Codex (Meta Review Relay)" -ExitCode 1 -TranscriptFile $CodexResult.TranscriptFile -FailureReason "Codex relay review found semantic issues but did not include a replacement draft."
            return @{
                Success = $false
                ReplacementDraftFile = ""
            }
        }

        $replacementDraftFile = Save-MetaReviewReplacementDraftArtifact -Content $replacementDraft -Iteration $Script:CurrentIteration -Timestamp $Timestamp
        Write-RunEvent -Type "meta_review_replacement_draft_saved" -Data @{
            tool = "codex"
            iteration = $Script:CurrentIteration
            report = $Script:CurrentQCReport
            replacementDraft = $replacementDraftFile
            message = "Codex replacement draft saved for meta-review reconciliation."
        }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($replacementDraft)) {
            Write-LogWarn "Codex relay meta-review returned a replacement draft alongside PASS. Ignoring the unexpected draft."
        }
        $Script:MetaReviewReplacementDraftFile = ""
    }

    return @{
        Success = $true
        ReplacementDraftFile = $replacementDraftFile
    }
}

function Invoke-ClaudeWrite {
    param([string]$PlanFile)

    $action = if ($MetaReview) {
        "review meta plan from"
    }
    elseif ($QCType -eq "document") {
        "generate document from"
    }
    else {
        "implement"
    }
    Update-RunState @{
        status = "running"
        phase = "implementation"
        currentAction = "claude_write"
        currentTool = "claude"
        lastError = ""
    }
    Write-RunEvent -Type "implementation_started" -Data @{
        tool = "claude"
        qcType = $QCType
        planFile = $PlanFile
        metaReview = [bool]$MetaReview
        message = $(if ($MetaReview) { "Claude reviewing selected meta plan" } elseif ($QCType -eq 'document') { "Claude implementing document from plan" } else { "Claude implementing code from plan" })
    }
    Write-LogInfo "Running Claude Code to $action plan..."

    $activeWritePrompt = Get-ActiveWritePrompt
    $prompt = Get-SubstitutedTemplate -TemplatePath $activeWritePrompt -PlanFile $PlanFile

    $allowedTools = if ($MetaReview) { "Read,Glob,Grep" } else { "Bash(git:*),Read,Write,Edit" }
    $retryResult = Invoke-ClaudeCommand -Prompt $prompt -AllowedTools $allowedTools -ToolLabel "Claude (Implementation)" -TimeoutSec $(if ($MetaReview) { $AgentTimeoutSec } else { 0 }) -UseMaxEffort:$MetaReview -PermissionMode $(if ($MetaReview) { "dontAsk" } else { "" })
    $output = $retryResult.Output
    
    # Log output
    $output | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8
    
    if ($retryResult.TimedOut) {
        Write-LogError "Claude Code timed out after $AgentTimeoutSec seconds during implementation."
        Write-RunEvent -Type "tool_timeout" -Level "error" -Data @{
            tool = "claude"
            timeoutSec = $AgentTimeoutSec
            phase = "implementation"
            message = "Claude implementation timed out after $AgentTimeoutSec seconds."
        }
        return $false
    }
    if ($retryResult.ExitCode -ne 0) {
        Write-LogError "Claude Code failed with exit code $($retryResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Claude (Implementation)" -ExitCode $retryResult.ExitCode -Output $output
        Write-RunEvent -Type "implementation_failed" -Level "error" -Data @{
            tool = "claude"
            exitCode = $retryResult.ExitCode
            message = "Claude implementation failed (exit code $($retryResult.ExitCode))"
        }
        return $false
    }
    if (-not (Save-MetaReviewOutputFromClaudeResponse -StageLabel "meta-review write" -EventType "implementation_failed" -Output $output)) {
        return $false
    }
    
    Write-LogSuccess "Claude Code implementation complete"
    Write-RunEvent -Type "implementation_completed" -Data @{
        tool = "claude"
        qcType = $QCType
        message = "Implementation complete"
    }
    return $true
}

function Invoke-CodexQC {
    param([string]$PlanFile)

    $timestamp = Get-Timestamp
    $reportType = if ($QCType -eq "document") { "doc_qc_report" } else { $Script:QCReportBase }
    $Script:CurrentQCReport = Join-Path $Script:LogsDir "${reportType}_iter$($Script:CurrentIteration)_$timestamp.md"

    $reviewType = if ($MetaReview) { "meta review" } elseif ($QCType -eq "document") { "document" } else { "code" }
    Update-RunState @{
        status = "running"
        phase = $(if ($QCType -eq "document") { "document_qc" } else { "qc_loop" })
        currentAction = "qc_review"
        currentTool = "codex"
        currentIteration = $Script:CurrentIteration
        currentQCReport = $Script:CurrentQCReport
        currentArtifact = $Script:CurrentQCReport
        currentArtifactType = "qc_report"
        lastError = ""
    }
    Write-RunEvent -Type "qc_review_started" -Data @{
        tool = "codex"
        iteration = $Script:CurrentIteration
        qcType = $QCType
        report = $Script:CurrentQCReport
        message = "Codex QC review iteration $($Script:CurrentIteration) ($reviewType mode)"
    }
    Write-LogInfo "Running Codex QC review ($reviewType mode)..."
    Write-LogInfo "QC Report: $($Script:CurrentQCReport)"

    $previousContext = Get-IssuesHistorySummary
    $activeQCPrompt = Get-ActiveQCPrompt
    $prompt = Get-SubstitutedTemplate -TemplatePath $activeQCPrompt -PlanFile $PlanFile -PreviousIssues $previousContext -Iteration $Script:CurrentIteration

    $effort = if ($MetaReview) { "xhigh" } else { $(if ($Script:CurrentIteration -eq 1) { "xhigh" } else { $ReasoningEffort }) }
    if (-not $MetaReview -and $Script:CurrentIteration -gt 1 -and $ReasoningEffort -eq "xhigh") {
        $effort = "high"  # Downgrade from xhigh to high after iter 1
    }
    Write-LogInfo "Reasoning effort: $effort (iteration $($Script:CurrentIteration))"
    if ($MetaReview) {
        Write-LogInfo "Meta review overrides Codex reasoning to xhigh."
    }

    $qcModeLabel = if ($MetaReview) { "Meta Review" } elseif ($QCType -eq "document") { "Document" } else { "Code" }
    $header = @"
# QC Report ($qcModeLabel Mode)
- **Generated**: $(Get-TimestampReadable)
- **Iteration**: $($Script:CurrentIteration)
- **QC Type**: $QCType
- **QC Tool**: Codex
- **Plan File**: $PlanFile
- **Pipeline ID**: $($Script:PipelineStartTime)
- **Full Log**: $($Script:QCLogFile)
- **Previous Issues Tracked**: $(if ($previousContext) { "Yes" } else { "No (first iteration)" })

---

"@

    $codexResult = Invoke-CodexCommandWithArtifacts -Prompt $prompt -ReportFile $Script:CurrentQCReport -ReportHeader $header -ToolLabel "Codex (QC Review)" -SandboxMode "read-only" -ReasoningEffort $effort -TimeoutSec $(if ($MetaReview) { $AgentTimeoutSec } else { 0 })

    if (-not $codexResult.Success) {
        Write-LogError "Codex QC failed with exit code $($codexResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Codex (QC Review)" -ExitCode $codexResult.ExitCode -Output $codexResult.Output
        Write-RunEvent -Type "qc_review_failed" -Level "error" -Data @{
            tool = "codex"
            iteration = $Script:CurrentIteration
            exitCode = $codexResult.ExitCode
            report = $Script:CurrentQCReport
            transcript = $codexResult.TranscriptFile
            message = "Codex QC review failed (exit code $($codexResult.ExitCode))"
        }
        return $false
    }

    Write-LogSuccess "Codex QC review complete"
    Write-RunEvent -Type "qc_review_completed" -Data @{
        tool = "codex"
        iteration = $Script:CurrentIteration
        report = $Script:CurrentQCReport
        transcript = $codexResult.TranscriptFile
        message = "Codex QC review complete (iteration $($Script:CurrentIteration))"
    }
    return $true
}

function Invoke-CodexMetaReviewRelayReview {
    param([string]$PlanFile)

    $timestamp = Get-Timestamp
    $Script:CurrentQCReport = Join-Path $Script:LogsDir "doc_qc_report_iter$($Script:CurrentIteration)_$timestamp.md"

    Update-RunState @{
        status = "running"
        phase = "document_qc"
        currentAction = "meta_review_relay_qc"
        currentTool = "codex"
        currentIteration = $Script:CurrentIteration
        currentQCReport = $Script:CurrentQCReport
        currentArtifact = $Script:CurrentQCReport
        currentArtifactType = "qc_report"
        lastError = ""
    }
    Write-RunEvent -Type "qc_review_started" -Data @{
        tool = "codex"
        iteration = $Script:CurrentIteration
        qcType = $QCType
        report = $Script:CurrentQCReport
        message = "Codex relay meta-review iteration $($Script:CurrentIteration)"
    }
    Write-LogInfo "Running Codex relay meta-review (review + replacement draft)..."
    Write-LogInfo "QC Report: $($Script:CurrentQCReport)"

    $previousContext = Get-IssuesHistorySummary
    $prompt = Get-SubstitutedTemplate -TemplatePath $Script:MetaReviewRelayQCPrompt -PlanFile $PlanFile -PreviousIssues $previousContext -Iteration $Script:CurrentIteration
    $header = @"
# QC Report (Meta Review Relay)
- **Generated**: $(Get-TimestampReadable)
- **Iteration**: $($Script:CurrentIteration)
- **QC Type**: $QCType
- **QC Tool**: Codex
- **Plan File**: $PlanFile
- **Pipeline ID**: $($Script:PipelineStartTime)
- **Full Log**: $($Script:QCLogFile)
- **Previous Issues Tracked**: $(if ($previousContext) { "Yes" } else { "No (first iteration)" })

---

"@

    $codexResult = Invoke-CodexCommandWithArtifacts -Prompt $prompt -ReportFile $Script:CurrentQCReport -ReportHeader $header -ToolLabel "Codex (Meta Review Relay)" -SandboxMode "read-only" -ReasoningEffort "xhigh" -TimeoutSec $AgentTimeoutSec
    if (-not $codexResult.Success) {
        Write-LogError "Codex relay meta-review failed with exit code $($codexResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Codex (Meta Review Relay)" -ExitCode $codexResult.ExitCode -Output $codexResult.Output
        Write-RunEvent -Type "qc_review_failed" -Level "error" -Data @{
            tool = "codex"
            iteration = $Script:CurrentIteration
            exitCode = $codexResult.ExitCode
            report = $Script:CurrentQCReport
            transcript = $codexResult.TranscriptFile
            message = "Codex relay meta-review failed (exit code $($codexResult.ExitCode))"
        }
        return $false
    }

    $relayResult = Finalize-MetaReviewRelayCodexResult -ReportHeader $header -Timestamp $timestamp -CodexResult $codexResult
    if (-not $relayResult.Success) {
        Write-LogError "Codex relay meta-review returned an unusable review payload."
        Write-RunEvent -Type "qc_review_failed" -Level "error" -Data @{
            tool = "codex"
            iteration = $Script:CurrentIteration
            report = $Script:CurrentQCReport
            transcript = $codexResult.TranscriptFile
            replacementDraft = $relayResult.ReplacementDraftFile
            message = "Codex relay meta-review returned an unusable review payload."
        }
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($relayResult.ReplacementDraftFile)) {
        Update-RunState @{
            currentArtifact = $relayResult.ReplacementDraftFile
            currentArtifactType = "artifact"
        }
    }

    Write-LogSuccess "Codex relay meta-review complete"
    Write-RunEvent -Type "qc_review_completed" -Data @{
        tool = "codex"
        iteration = $Script:CurrentIteration
        report = $Script:CurrentQCReport
        transcript = $codexResult.TranscriptFile
        replacementDraft = $relayResult.ReplacementDraftFile
        message = "Codex relay meta-review complete (iteration $($Script:CurrentIteration))"
    }
    return $true
}

function Invoke-ClaudeCodeQC {
    param([string]$PlanFile)

    $timestamp = Get-Timestamp
    $reportType = if ($QCType -eq "document") { "doc_qc_report" } else { $Script:QCReportBase }
    $Script:CurrentQCReport = Join-Path $Script:LogsDir "${reportType}_iter$($Script:CurrentIteration)_$timestamp.md"

    $reviewType = if ($MetaReview) { "meta review" } elseif ($QCType -eq "document") { "document" } else { "code" }
    Update-RunState @{
        status = "running"
        phase = $(if ($QCType -eq "document") { "document_qc" } else { "qc_loop" })
        currentAction = "qc_review"
        currentTool = "claude"
        currentIteration = $Script:CurrentIteration
        currentQCReport = $Script:CurrentQCReport
        currentArtifact = $Script:CurrentQCReport
        currentArtifactType = "qc_report"
        lastError = ""
    }
    Write-RunEvent -Type "qc_review_started" -Data @{
        tool = "claude"
        iteration = $Script:CurrentIteration
        qcType = $QCType
        report = $Script:CurrentQCReport
        message = "Claude QC review iteration $($Script:CurrentIteration) ($reviewType mode)"
    }
    Write-LogInfo "Running Claude Code QC review ($reviewType mode)..."
    Write-LogInfo "QC Report: $($Script:CurrentQCReport)"

    $previousContext = Get-IssuesHistorySummary
    $activeQCPrompt = Get-ActiveQCPrompt
    $prompt = Get-SubstitutedTemplate -TemplatePath $activeQCPrompt -PlanFile $PlanFile -PreviousIssues $previousContext -Iteration $Script:CurrentIteration

    # Run Claude Code in non-interactive print mode (read-only for QC, with retry)
    $retryResult = Invoke-ClaudeCommand -Prompt $prompt -AllowedTools "Read,Glob,Grep" -ToolLabel "Claude (QC Review)"
    $output = $retryResult.Output

    $qcModeLabel = if ($MetaReview) { "Meta Review" } elseif ($QCType -eq "document") { "Document" } else { "Code" }
    $header = @"
# QC Report ($qcModeLabel Mode)
- **Generated**: $(Get-TimestampReadable)
- **Iteration**: $($Script:CurrentIteration)
- **QC Type**: $QCType
- **QC Tool**: Claude Code
- **Plan File**: $PlanFile
- **Pipeline ID**: $($Script:PipelineStartTime)
- **Full Log**: $($Script:QCLogFile)
- **Previous Issues Tracked**: $(if ($previousContext) { "Yes" } else { "No (first iteration)" })

---

"@

    $fullReport = $header + ($output -join "`n")
    $fullReport | Out-File -FilePath $Script:CurrentQCReport -Encoding UTF8

    if ($retryResult.ExitCode -ne 0) {
        Write-LogError "Claude Code QC failed with exit code $($retryResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Claude (QC Review)" -ExitCode $retryResult.ExitCode -Output $output
        Write-RunEvent -Type "qc_review_failed" -Level "error" -Data @{
            tool = "claude"
            iteration = $Script:CurrentIteration
            exitCode = $retryResult.ExitCode
            report = $Script:CurrentQCReport
            message = "Claude QC review failed (exit code $($retryResult.ExitCode))"
        }
        return $false
    }

    Write-LogSuccess "Claude Code QC review complete"
    Write-RunEvent -Type "qc_review_completed" -Data @{
        tool = "claude"
        iteration = $Script:CurrentIteration
        report = $Script:CurrentQCReport
        message = "Claude QC review complete (iteration $($Script:CurrentIteration))"
    }
    return $true
}

function Invoke-ClaudeFix {
    param(
        [string]$PlanFile,
        [string]$QCIssues
    )
    
    $issueCount = ([regex]::Matches($QCIssues, '### Issue')).Count
    Update-RunState @{
        status = "running"
        phase = $(if ($MetaReview) { "document_qc" } else { "qc_loop" })
        currentAction = $(if ($MetaReview) { "meta_review_fix" } else { "fix" })
        currentTool = "claude"
        lastError = ""
    }
    Write-RunEvent -Type "fix_started" -Data @{
        tool = "claude"
        iteration = $Script:CurrentIteration
        issueCount = $issueCount
        message = "Claude fixing $issueCount issue(s) (iteration $($Script:CurrentIteration))"
    }
    Write-LogInfo "Running Claude Code to fix issues..."
    
    $previousContext = Get-IssuesHistorySummary
    $activeFixPrompt = Get-ActiveFixPrompt
    $prompt = Get-SubstitutedTemplate -TemplatePath $activeFixPrompt -PlanFile $PlanFile -QCIssues $QCIssues -PreviousIssues $previousContext
    
    $allowedTools = if ($MetaReview) { "Read,Glob,Grep" } else { "Bash(git:*),Read,Write,Edit" }
    $retryResult = Invoke-ClaudeCommand -Prompt $prompt -AllowedTools $allowedTools -ToolLabel "Claude (Fix)" -TimeoutSec $(if ($MetaReview) { $AgentTimeoutSec } else { 0 }) -UseMaxEffort:$MetaReview -PermissionMode $(if ($MetaReview) { "dontAsk" } else { "" })
    $output = $retryResult.Output
    
    # Log output
    $output | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8
    
    if ($retryResult.TimedOut) {
        Write-LogError "Claude Code timed out after $AgentTimeoutSec seconds while fixing issues."
        Write-RunEvent -Type "tool_timeout" -Level "error" -Data @{
            tool = "claude"
            iteration = $Script:CurrentIteration
            timeoutSec = $AgentTimeoutSec
            message = "Claude fix timed out after $AgentTimeoutSec seconds."
        }
        return $false
    }
    if ($retryResult.ExitCode -ne 0) {
        Write-LogError "Claude Code fix failed with exit code $($retryResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Claude (Fix)" -ExitCode $retryResult.ExitCode -Output $output
        Write-RunEvent -Type "fix_failed" -Level "error" -Data @{
            tool = "claude"
            iteration = $Script:CurrentIteration
            exitCode = $retryResult.ExitCode
            message = "Fix failed (exit code $($retryResult.ExitCode))"
        }
        return $false
    }
    if (-not (Save-MetaReviewOutputFromClaudeResponse -StageLabel "meta-review fix" -EventType "fix_failed" -Output $output)) {
        return $false
    }
    
    Write-LogSuccess "Claude Code fixes applied"
    Write-RunEvent -Type "fix_completed" -Data @{
        tool = "claude"
        iteration = $Script:CurrentIteration
        issueCount = $issueCount
        message = "Fixes applied ($issueCount issues, iteration $($Script:CurrentIteration))"
    }
    return $true
}

function Invoke-ClaudeMetaReviewReconcile {
    param(
        [string]$PlanFile,
        [string]$QCIssues
    )

    $issueCount = ([regex]::Matches($QCIssues, '### Issue')).Count
    Update-RunState @{
        status = "running"
        phase = "document_qc"
        currentAction = "meta_review_reconcile"
        currentTool = "claude"
        currentArtifact = $Script:MetaReviewReplacementDraftFile
        currentArtifactType = "artifact"
        lastError = ""
    }
    Write-RunEvent -Type "meta_review_reconcile_started" -Data @{
        tool = "claude"
        iteration = $Script:CurrentIteration
        issueCount = $issueCount
        replacementDraft = $Script:MetaReviewReplacementDraftFile
        message = "Claude reconciling Codex replacement draft for meta-review iteration $($Script:CurrentIteration)"
    }
    Write-LogInfo "Running Claude Code to reconcile the Codex replacement draft..."

    $previousContext = Get-IssuesHistorySummary
    $prompt = Get-SubstitutedTemplate -TemplatePath $Script:MetaReviewReconcilePrompt -PlanFile $PlanFile -QCIssues $QCIssues -PreviousIssues $previousContext
    $retryResult = Invoke-ClaudeCommand -Prompt $prompt -AllowedTools "Read,Glob,Grep" -ToolLabel "Claude (Meta Review Reconcile)" -TimeoutSec $AgentTimeoutSec -UseMaxEffort -PermissionMode "dontAsk"
    $output = $retryResult.Output

    $output | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

    if ($retryResult.TimedOut) {
        Write-LogError "Claude Code timed out after $AgentTimeoutSec seconds while reconciling the Codex replacement draft."
        Write-RunEvent -Type "tool_timeout" -Level "error" -Data @{
            tool = "claude"
            iteration = $Script:CurrentIteration
            timeoutSec = $AgentTimeoutSec
            replacementDraft = $Script:MetaReviewReplacementDraftFile
            message = "Claude meta-review reconcile timed out after $AgentTimeoutSec seconds."
        }
        return $false
    }
    if ($retryResult.ExitCode -ne 0) {
        Write-LogError "Claude meta-review reconcile failed with exit code $($retryResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Claude (Meta Review Reconcile)" -ExitCode $retryResult.ExitCode -Output $output
        Write-RunEvent -Type "meta_review_reconcile_failed" -Level "error" -Data @{
            tool = "claude"
            iteration = $Script:CurrentIteration
            exitCode = $retryResult.ExitCode
            replacementDraft = $Script:MetaReviewReplacementDraftFile
            message = "Claude meta-review reconcile failed (exit code $($retryResult.ExitCode))"
        }
        return $false
    }
    if (-not (Save-MetaReviewOutputFromClaudeResponse -StageLabel "meta-review reconcile" -EventType "meta_review_reconcile_failed" -Output $output)) {
        return $false
    }

    Write-LogSuccess "Claude meta-review reconciliation complete"
    Write-RunEvent -Type "meta_review_reconcile_completed" -Data @{
        tool = "claude"
        iteration = $Script:CurrentIteration
        issueCount = $issueCount
        replacementDraft = $Script:MetaReviewReplacementDraftFile
        message = "Claude reconciled the Codex replacement draft for iteration $($Script:CurrentIteration)"
    }
    return $true
}

# =============================================================================
# QC Parsing Functions
# =============================================================================

function Remove-CodexNoise {
    param([string]$Content)
    
    # Remove PowerShell remoting noise that appears in Codex output
    $cleaned = $Content -replace 'System\.Management\.Automation\.RemoteException\r?\n?', ''
    # Remove multiple consecutive blank lines
    $cleaned = $cleaned -replace '(\r?\n){3,}', "`n`n"
    return $cleaned.Trim()
}

function Get-CodexResponse {
    param([string]$ReportContent)
    
    # Extract only the actual Codex response (after "codex" marker, before "tokens used")
    # This excludes the echoed prompt which contains template examples
    if ($ReportContent -match '(?s)\ncodex\n(.+?)\ntokens used') {
        return Remove-CodexNoise -Content $Matches[1]
    }
    
    # Fallback: try to find response after last "codex" marker
    if ($ReportContent -match '(?s).*\ncodex\n(.+)$') {
        $response = $Matches[1]
        # Remove "tokens used" section if present
        if ($response -match '(?s)(.+?)\ntokens used') {
            return Remove-CodexNoise -Content $Matches[1]
        }
        return Remove-CodexNoise -Content $response
    }
    
    # No marker found, return full content (risky but better than nothing)
    Write-LogWarn "Could not find Codex response marker. Using full report content."
    return Remove-CodexNoise -Content $ReportContent
}

function Get-ReportBody {
    param([string]$ReportContent)

    if ($ReportContent -match '(?s)^.*?\r?\n---\s*\r?\n(.+)$') {
        return $Matches[1].Trim()
    }

    return $ReportContent.Trim()
}

function Get-QCResponse {
    param([string]$ReportContent)

    $body = Get-ReportBody -ReportContent $ReportContent
    $looksLikeLegacyCodexTranscript = (
        $body -match '(?m)^user\s*$' -or
        $body -match '(?m)^codex\s*$' -or
        $body -match '(?m)^tokens used\b'
    )

    if ($looksLikeLegacyCodexTranscript) {
        return Get-CodexResponse -ReportContent $body
    }

    return $body
}

function Test-QCPassed {
    if (-not (Test-Path $Script:CurrentQCReport)) {
        Write-LogWarn "QC report not found: $($Script:CurrentQCReport)"
        return $false
    }

    $content = Get-Content -Path $Script:CurrentQCReport -Raw
    $response = Get-QCResponse -ReportContent $content

    # Check for PASS/FAIL in the QC response
    $hasPass = $response -match '## QC Status: PASS'
    $hasFail = $response -match '## QC Status: FAIL'

    $result = ($hasPass -and (-not $hasFail))

    # If -PassOnMediumOnly is set, also pass if only MEDIUM/LOW severity issues remain
    if (-not $result -and $PassOnMediumOnly -and $Script:CurrentIteration -ge 2) {
        $hasCritical = $response -match '\*\*Severity\*\*:\s*CRITICAL'
        $hasHigh = $response -match '\*\*Severity\*\*:\s*HIGH'

        if (-not $hasCritical -and -not $hasHigh) {
            Write-LogInfo "No CRITICAL or HIGH issues found. Passing with -PassOnMediumOnly flag."
            $result = $true
        }
    }

    # Log detection result
    Write-LogInfo "QC Status Detection - HasPass: $hasPass, HasFail: $hasFail, Result: $result"

    return $result
}

function Get-QCIssues {
    if (-not (Test-Path $Script:CurrentQCReport)) {
        Write-LogWarn "QC report not found for issue extraction"
        return ""
    }
    
    $content = Get-Content -Path $Script:CurrentQCReport -Raw
    $response = Get-QCResponse -ReportContent $content

    # Extract issues from the QC response
    if ($response -match '(?s)(### Issue.+?)(?=## (?:Regression|Summary))') {
        $issues = $Matches[1].Trim()
        $issueCount = ([regex]::Matches($issues, '### Issue')).Count
        Write-LogInfo "Extracted $issueCount issues from QC report"
        return $issues
    }
    
    # Alternative: try to get everything between "Issues Found:" and "## Summary" or "## Regression"
    if ($response -match '(?s)## Issues Found: (\d+).+?(### Issue.+?)(?=## (?:Regression|Summary))') {
        $issues = $Matches[2].Trim()
        Write-LogInfo "Extracted issues (alt pattern) from QC report"
        return $issues
    }
    
    # Final fallback: original pattern
    if ($response -match '(?s)(### Issue.+?)(?=## Summary)') {
        $issues = $Matches[1].Trim()
        Write-LogInfo "Extracted issues (fallback pattern) from QC report"
        return $issues
    }
    
    Write-LogWarn "Could not extract issues from QC report"
    return ""
}

function Get-QCIssueSeveritySummary {
    param([string]$Issues)

    $severities = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($Issues, '(?im)^\s*-\s*\*\*Severity\*\*:\s*([A-Za-z]+)\s*$')) {
        $severity = [string]$match.Groups[1].Value.ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($severity) -and -not $severities.Contains($severity)) {
            $severities.Add($severity)
        }
    }

    $severityList = @($severities)
    $missingSeverity = ($severityList.Count -eq 0)
    $unknownSeverities = @($severityList | Where-Object { $_ -notin @("CRITICAL", "HIGH", "MEDIUM", "LOW") })
    $hasUnknownSeverity = ($unknownSeverities.Count -gt 0)
    $hasBlockingSeverity = ($severityList -contains "CRITICAL" -or $severityList -contains "HIGH")
    $hasBlockingIssues = ($missingSeverity -or $hasUnknownSeverity -or $hasBlockingSeverity)
    $allNonBlocking = ((-not $hasBlockingIssues) -and ($severityList.Count -gt 0))

    return [ordered]@{
        SeverityList = $severityList
        MissingSeverity = $missingSeverity
        UnknownSeverities = $unknownSeverities
        HasUnknownSeverity = $hasUnknownSeverity
        HasBlockingSeverity = $hasBlockingSeverity
        HasBlockingIssues = $hasBlockingIssues
        AllNonBlocking = $allNonBlocking
    }
}

function Get-DeliberationSeveritySummary {
    param(
        [string]$ArtifactPath
    )

    # Safe default: missing artifact => non-blocking, mark ParseSucceeded=$false.
    if ([string]::IsNullOrWhiteSpace($ArtifactPath) -or -not (Test-Path -LiteralPath $ArtifactPath)) {
        Write-LogWarn "Deliberation severity: artifact not found ($ArtifactPath); defaulting to non-blocking."
        return [ordered]@{
            SeverityList        = @()
            MissingSeverity     = $true
            UnknownSeverities   = @()
            HasUnknownSeverity  = $false
            HasBlockingSeverity = $false
            HasBlockingIssues   = $false
            AllNonBlocking      = $false
            SourceArtifact      = $ArtifactPath
            ParseSucceeded      = $false
        }
    }

    $content = Get-Content -LiteralPath $ArtifactPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) {
        Write-LogWarn "Deliberation severity: artifact empty ($ArtifactPath); defaulting to non-blocking."
        return [ordered]@{
            SeverityList        = @()
            MissingSeverity     = $true
            UnknownSeverities   = @()
            HasUnknownSeverity  = $false
            HasBlockingSeverity = $false
            HasBlockingIssues   = $false
            AllNonBlocking      = $false
            SourceArtifact      = $ArtifactPath
            ParseSucceeded      = $false
        }
    }

    # Prefer a dedicated "## Remaining Issues" section. Fall back to whole-doc
    # scan so artifacts written before this feature still parse (bwds compat).
    $issuesBlock = $content
    if ($content -match '(?ims)^##\s*Remaining Issues\s*$(.+?)(?=^##\s|\z)') {
        $issuesBlock = $Matches[1]
    }

    # Deliberation prompts emit inline severity bullets of the form
    # "- **Severity**: CRITICAL - <description>" on a single line for readability.
    # Get-QCIssueSeveritySummary's strict regex expects severity alone on the line,
    # so normalize inline bullets to line-only form before delegating.
    $normalizedIssuesBlock = [regex]::Replace(
        $issuesBlock,
        '(?im)^\s*-\s*\*\*Severity\*\*:\s*([A-Za-z]+)\b.*$',
        '- **Severity**: $1'
    )

    $summary = Get-QCIssueSeveritySummary -Issues $normalizedIssuesBlock

    $result = [ordered]@{}
    foreach ($k in $summary.Keys) {
        $result[$k] = $summary[$k]
    }
    $result['SourceArtifact'] = $ArtifactPath
    $result['ParseSucceeded'] = $true

    # Warn once per round if we parsed non-empty content but found no severity
    # bullets - orchestrator gate is effectively inactive for this artifact.
    if ($result.MissingSeverity -and -not [string]::IsNullOrWhiteSpace($content)) {
        Write-LogWarn "No severity summary emitted by Codex; convergence gate inactive for this artifact ($ArtifactPath)."
    }

    return $result
}

# =============================================================================
# Plan QC Functions
# =============================================================================

function Add-PlanIssuesToHistory {
    param([string]$Issues, [int]$Iteration)

    if ([string]::IsNullOrWhiteSpace($Issues)) {
        return
    }

    $header = "`n### Plan QC Iteration $Iteration Issues:`n"
    $Script:AllPlanIssuesHistory += $header + $Issues + "`n"

    Write-LogInfo "Added plan QC iteration $Iteration issues to history tracking"
}

function Get-PlanQCHistorySummary {
    if ([string]::IsNullOrWhiteSpace($Script:AllPlanIssuesHistory)) {
        return ""
    }

    # Limit history to ~8000 chars to avoid token overflow in LLM context
    $maxHistoryChars = 8000
    $history = $Script:AllPlanIssuesHistory

    if ($history.Length -gt $maxHistoryChars) {
        Write-LogWarn "Plan issue history exceeds $maxHistoryChars chars ($($history.Length)). Truncating older issues."
        $truncateAt = $history.Length - $maxHistoryChars
        $nextHeader = $history.IndexOf("`n### Plan QC Iteration", $truncateAt)
        if ($nextHeader -gt 0) {
            $history = "...(earlier issues truncated)..." + $history.Substring($nextHeader)
        }
        else {
            $history = "...(truncated)..." + $history.Substring($truncateAt)
        }
    }

    Write-LogInfo "Plan issue history size: $($history.Length) chars"

    return @"
## Issues from Previous Plan QC Iterations

The following issues were reported and (should have been) fixed in previous iterations.
Do NOT report these same issues again unless they have genuinely regressed.
Do NOT report the OPPOSITE of these issues (e.g., if "add more detail" was reported, do not now report "too verbose").

$history
"@
}

function Test-PlanQCPassed {
    if (-not (Test-Path $Script:CurrentPlanQCReport)) {
        Write-LogWarn "Plan QC report not found: $($Script:CurrentPlanQCReport)"
        return $false
    }

    $content = Get-Content -Path $Script:CurrentPlanQCReport -Raw
    $response = Get-QCResponse -ReportContent $content

    # Check for PASS/FAIL in the QC response
    $hasPass = $response -match '## QC Status: PASS'
    $hasFail = $response -match '## QC Status: FAIL'

    $result = ($hasPass -and (-not $hasFail))

    # Log detection result
    Write-LogInfo "Plan QC Status Detection - HasPass: $hasPass, HasFail: $hasFail, Result: $result"

    return $result
}

function Get-PlanQCIssues {
    if (-not (Test-Path $Script:CurrentPlanQCReport)) {
        Write-LogWarn "Plan QC report not found for issue extraction"
        return ""
    }

    $content = Get-Content -Path $Script:CurrentPlanQCReport -Raw
    $response = Get-QCResponse -ReportContent $content

    # Extract issues from the QC response
    if ($response -match '(?s)(### Issue.+?)(?=## Summary)') {
        $issues = $Matches[1].Trim()
        $issueCount = ([regex]::Matches($issues, '### Issue')).Count
        Write-LogInfo "Extracted $issueCount issues from Plan QC report"
        return $issues
    }

    # Alternative: try to get everything between "Issues Found:" and "## Summary"
    if ($response -match '(?s)## Issues Found: (\d+).+?(### Issue.+?)(?=## Summary)') {
        $issues = $Matches[2].Trim()
        Write-LogInfo "Extracted plan issues (alt pattern) from Plan QC report"
        return $issues
    }

    Write-LogWarn "Could not extract issues from Plan QC report"
    return ""
}

function Invoke-CodexPlanQC {
    param([string]$PlanFile)

    $timestamp = Get-Timestamp
    $Script:CurrentPlanQCReport = Join-Path $Script:LogsDir "$($Script:PlanQCReportBase)_iter$($Script:CurrentPlanQCIteration)_$timestamp.md"

    Update-RunState @{
        status = "running"
        phase = "plan_qc"
        currentAction = "plan_qc_review"
        currentTool = "codex"
        currentPlanQCIteration = $Script:CurrentPlanQCIteration
        currentPlanQCReport = $Script:CurrentPlanQCReport
        currentArtifact = $Script:CurrentPlanQCReport
        currentArtifactType = "plan_qc_report"
        lastError = ""
    }
    Write-RunEvent -Type "plan_qc_review_started" -Data @{
        tool = "codex"
        iteration = $Script:CurrentPlanQCIteration
        report = $Script:CurrentPlanQCReport
        message = "Codex plan QC review iteration $($Script:CurrentPlanQCIteration)"
    }
    Write-LogInfo "Running Codex Plan QC review..."
    Write-LogInfo "Plan QC Report: $($Script:CurrentPlanQCReport)"

    $previousContext = Get-PlanQCHistorySummary
    $prompt = Get-SubstitutedTemplate -TemplatePath $Script:PlanQCPrompt -PlanFile $PlanFile -PreviousIssues $previousContext -Iteration $Script:CurrentPlanQCIteration

    $header = @"
# Plan QC Report
- **Generated**: $(Get-TimestampReadable)
- **Iteration**: $($Script:CurrentPlanQCIteration)
- **QC Tool**: Codex
- **Plan File**: $PlanFile
- **Pipeline ID**: $($Script:PipelineStartTime)
- **Full Log**: $($Script:QCLogFile)
- **Previous Issues Tracked**: $(if ($previousContext) { "Yes" } else { "No (first iteration)" })

---

"@

    $codexResult = Invoke-CodexCommandWithArtifacts -Prompt $prompt -ReportFile $Script:CurrentPlanQCReport -ReportHeader $header -ToolLabel "Codex (Plan QC)" -SandboxMode "read-only"

    if (-not $codexResult.Success) {
        Write-LogError "Codex Plan QC failed with exit code $($codexResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Codex (Plan QC)" -ExitCode $codexResult.ExitCode -Output $codexResult.Output
        Write-RunEvent -Type "plan_qc_review_failed" -Level "error" -Data @{
            tool = "codex"
            iteration = $Script:CurrentPlanQCIteration
            exitCode = $codexResult.ExitCode
            report = $Script:CurrentPlanQCReport
            transcript = $codexResult.TranscriptFile
            message = "Codex plan QC review failed (exit code $($codexResult.ExitCode))"
        }
        return $false
    }

    Write-LogSuccess "Codex Plan QC review complete"
    Write-RunEvent -Type "plan_qc_review_completed" -Data @{
        tool = "codex"
        iteration = $Script:CurrentPlanQCIteration
        report = $Script:CurrentPlanQCReport
        transcript = $codexResult.TranscriptFile
        message = "Codex plan QC review complete (iteration $($Script:CurrentPlanQCIteration))"
    }
    return $true
}

function Invoke-ClaudeCodePlanQC {
    param([string]$PlanFile)

    $timestamp = Get-Timestamp
    $Script:CurrentPlanQCReport = Join-Path $Script:LogsDir "$($Script:PlanQCReportBase)_iter$($Script:CurrentPlanQCIteration)_$timestamp.md"

    Update-RunState @{
        status = "running"
        phase = "plan_qc"
        currentAction = "plan_qc_review"
        currentTool = "claude"
        currentPlanQCIteration = $Script:CurrentPlanQCIteration
        currentPlanQCReport = $Script:CurrentPlanQCReport
        currentArtifact = $Script:CurrentPlanQCReport
        currentArtifactType = "plan_qc_report"
        lastError = ""
    }
    Write-RunEvent -Type "plan_qc_review_started" -Data @{
        tool = "claude"
        iteration = $Script:CurrentPlanQCIteration
        report = $Script:CurrentPlanQCReport
        message = "Claude plan QC review iteration $($Script:CurrentPlanQCIteration)"
    }
    Write-LogInfo "Running Claude Code Plan QC review..."
    Write-LogInfo "Plan QC Report: $($Script:CurrentPlanQCReport)"

    $previousContext = Get-PlanQCHistorySummary
    $prompt = Get-SubstitutedTemplate -TemplatePath $Script:PlanQCPrompt -PlanFile $PlanFile -PreviousIssues $previousContext -Iteration $Script:CurrentPlanQCIteration

    # Run Claude Code in non-interactive print mode (read-only for QC, with retry)
    $retryResult = Invoke-ClaudeCommand -Prompt $prompt -AllowedTools "Read,Glob,Grep" -ToolLabel "Claude (Plan QC)"
    $output = $retryResult.Output

    $header = @"
# Plan QC Report
- **Generated**: $(Get-TimestampReadable)
- **Iteration**: $($Script:CurrentPlanQCIteration)
- **QC Tool**: Claude Code
- **Plan File**: $PlanFile
- **Pipeline ID**: $($Script:PipelineStartTime)
- **Full Log**: $($Script:QCLogFile)
- **Previous Issues Tracked**: $(if ($previousContext) { "Yes" } else { "No (first iteration)" })

---

"@

    $fullReport = $header + ($output -join "`n")
    $fullReport | Out-File -FilePath $Script:CurrentPlanQCReport -Encoding UTF8

    if ($retryResult.ExitCode -ne 0) {
        Write-LogError "Claude Code Plan QC failed with exit code $($retryResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Claude (Plan QC)" -ExitCode $retryResult.ExitCode -Output $output
        Write-RunEvent -Type "plan_qc_review_failed" -Level "error" -Data @{
            tool = "claude"
            iteration = $Script:CurrentPlanQCIteration
            exitCode = $retryResult.ExitCode
            report = $Script:CurrentPlanQCReport
            message = "Claude plan QC review failed (exit code $($retryResult.ExitCode))"
        }
        return $false
    }

    Write-LogSuccess "Claude Code Plan QC review complete"
    Write-RunEvent -Type "plan_qc_review_completed" -Data @{
        tool = "claude"
        iteration = $Script:CurrentPlanQCIteration
        report = $Script:CurrentPlanQCReport
        message = "Claude plan QC review complete (iteration $($Script:CurrentPlanQCIteration))"
    }
    return $true
}

function Invoke-ClaudePlanFix {
    param(
        [string]$PlanFile,
        [string]$QCIssues
    )

    $issueCount = ([regex]::Matches($QCIssues, '### Issue')).Count
    Update-RunState @{
        status = "running"
        phase = "plan_qc"
        currentAction = "plan_fix"
        currentTool = "claude"
        lastError = ""
    }
    Write-RunEvent -Type "plan_fix_started" -Data @{
        tool = "claude"
        iteration = $Script:CurrentPlanQCIteration
        issueCount = $issueCount
        message = "Claude fixing $issueCount plan issue(s)"
    }
    Write-LogInfo "Running Claude Code to fix plan issues..."

    $previousContext = Get-PlanQCHistorySummary
    $prompt = Get-SubstitutedTemplate -TemplatePath $Script:PlanFixPrompt -PlanFile $PlanFile -QCIssues $QCIssues -PreviousIssues $previousContext

    # Run Claude Code in non-interactive mode (with retry on transient API errors)
    $retryResult = Invoke-ClaudeCommand -Prompt $prompt -AllowedTools "Bash(git:*),Read,Write,Edit" -ToolLabel "Claude (Plan Fix)"
    $output = $retryResult.Output

    # Log output
    $output | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

    if ($retryResult.ExitCode -ne 0) {
        Write-LogError "Claude Code plan fix failed with exit code $($retryResult.ExitCode)"
        Write-CLIErrorDetails -ToolLabel "Claude (Plan Fix)" -ExitCode $retryResult.ExitCode -Output $output
        Write-RunEvent -Type "plan_fix_failed" -Level "error" -Data @{
            tool = "claude"
            iteration = $Script:CurrentPlanQCIteration
            exitCode = $retryResult.ExitCode
            message = "Plan fix failed (exit code $($retryResult.ExitCode))"
        }
        return $false
    }

    Write-LogSuccess "Claude Code plan fixes applied"
    Write-RunEvent -Type "plan_fix_completed" -Data @{
        tool = "claude"
        iteration = $Script:CurrentPlanQCIteration
        issueCount = $issueCount
        message = "Plan fixes applied ($issueCount issues)"
    }
    return $true
}

function Remove-FencedMarkdownBlocks {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ""
    }

    $lines = $Content -split "\r?\n"
    $result = New-Object System.Collections.Generic.List[string]
    $activeFence = ""

    foreach ($line in $lines) {
        if ([string]::IsNullOrEmpty($activeFence)) {
            if ($line -match '^\s*([`~]{3,})') {
                $activeFence = $Matches[1]
                continue
            }
            $result.Add($line)
            continue
        }

        $escapedFence = [regex]::Escape($activeFence)
        if ($line -match "^\s*$escapedFence\s*$") {
            $activeFence = ""
        }
    }

    return ($result -join "`r`n")
}

function Remove-MarkdownInlineCodeSpans {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ""
    }

    # Ignore inline-code mentions like `no [TODO]` when checking for unresolved placeholders.
    return [regex]::Replace($Content, '`{1,3}[^`\r\n]+`{1,3}', '')
}

function Get-MetaReviewOutsideFencePlaceholderEvidence {
    param([string]$ContentOutsideFences)

    if ([string]::IsNullOrWhiteSpace($ContentOutsideFences)) {
        return @()
    }

    $sanitizedContent = Remove-MarkdownInlineCodeSpans -Content $ContentOutsideFences
    $matches = [regex]::Matches($sanitizedContent, '(?im)(\[TODO\]|\[TBD\]|\[placeholder\]|<placeholder>)|^\s*\.\.\.\s*$')
    if ($matches.Count -eq 0) {
        return @()
    }

    $lines = $sanitizedContent -split "\r?\n"
    $evidence = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -notmatch '(?im)(\[TODO\]|\[TBD\]|\[placeholder\]|<placeholder>)' -and $line -notmatch '(?im)^\s*\.\.\.\s*$') {
            continue
        }

        $lineMatch = [regex]::Match($line, '(?im)(\[TODO\]|\[TBD\]|\[placeholder\]|<placeholder>|\.\.\.)')
        $token = if ($lineMatch.Success) { $lineMatch.Value } else { "placeholder token" }
        $snippet = $line.Trim()
        if ($snippet.Length -gt 120) {
            $snippet = $snippet.Substring(0, 117) + "..."
        }
        if (-not [string]::IsNullOrWhiteSpace($snippet) -and -not $evidence.Contains("$token in `"$snippet`"")) {
            $evidence.Add("$token in `"$snippet`"")
        }
    }

    return @($evidence)
}

function Get-FencedOutputTemplateContent {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ""
    }

    $lines = $Content -split "\r?\n"
    $headingIndex = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^\s*##\s+Output Structure Template\s*$') {
            $headingIndex = $i
            break
        }
    }

    if ($headingIndex -lt 0) {
        return ""
    }

    $activeFence = ""
    $result = New-Object System.Collections.Generic.List[string]
    for ($i = $headingIndex + 1; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]

        if ([string]::IsNullOrEmpty($activeFence)) {
            if ($line -match '^\s*([`~]{3,})(?:\s*[A-Za-z0-9_-]+)?\s*$') {
                $activeFence = $Matches[1]
            }
            continue
        }

        $escapedFence = [regex]::Escape($activeFence)
        if ($line -match "^\s*$escapedFence\s*$") {
            break
        }

        $result.Add($line)
    }

    return ($result -join "`r`n")
}

function Test-MetaReviewInProgressGate {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    $hasInProgressCycles = $Content -match '(?i)\binProgressCycles\b'
    $hasStatusDrivenInProgressBranch = $Content -match '(?is)if\s+any\s+cycle\s+has\s+status\s+"?in[_-]?progress"?\s*:'
    $hasResumeInstruction = $Content -match '(?i)(generate|create).{0,120}RESUME_CYCLE_\[(?:NN|NNr)\]\.md'
    $hasNoNewPlanInstruction = $Content -match '(?is)(?:Do\s+NOT|Do\s+not|Do not)\s+generate\s+(?:a\s+new\s+)?(?:cycle\s+plan|continuation\s+plan|`?CONTINUATION_CYCLE_\[NN\]\.md`?)'

    return (($hasInProgressCycles -and $hasNoNewPlanInstruction) -or ($hasStatusDrivenInProgressBranch -and $hasResumeInstruction -and $hasNoNewPlanInstruction))
}

function Test-MetaReviewResumePlanBranch {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    return ($Content -match '(?i)RESUME_CYCLE_\[(?:NN|NNr)\]\.md')
}

function Test-MetaReviewTerminalBranch {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    $hasPendingCyclesLiteral = $Content -match '(?i)\bpendingCycles\b'
    $hasPendingCyclesTerminalCondition = $Content -match '(?i)(all cycles are complete|if `?pendingCycles`? is empty|if pendingcycles is empty)'
    $hasStatusDrivenTerminalBranch = $Content -match '(?is)else\s*:\s*(?:output|return).{0,120}plain-text completion report'
    $hasCompleteStatusTerminalCondition = $Content -match '(?i)all cycles are "?complete"?'
    $hasStopWithoutNewPlan = $Content -match '(?is)(?:stop|do not generate a new (?:cycle|continuation) plan)'

    return (($hasPendingCyclesLiteral -and $hasPendingCyclesTerminalCondition) -or (($hasStatusDrivenTerminalBranch -or $hasCompleteStatusTerminalCondition) -and $hasStopWithoutNewPlan))
}

function Test-MetaReviewConditionalSectionsConsistency {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    $hasConditionalKeyDifferences = $Content -match '(?is)Key Differences.{0,240}(?:only if|only when|when applicable|omit this section otherwise|omit otherwise)'
    $hasConditionalFrontendNotes = $Content -match '(?is)Frontend Design Notes.{0,240}(?:only if|only when|when applicable|omit this section otherwise|omit otherwise)'
    $hasAmbiguousAll17Requirement = $Content -match '(?is)(?:must|should)\s+(?:contain|include|follow).{0,140}(?:all\s+17|these\s+17|17\s+required)\s+(?:required\s+)?(?:output\s+)?sections(?:\s+defined|\s+listed|\s+in\s+this\s+order)?'

    return (-not ($hasAmbiguousAll17Requirement -and ($hasConditionalKeyDifferences -or $hasConditionalFrontendNotes)))
}

function New-MetaReviewFinding {
    param(
        [string]$Severity,
        [string]$Category,
        [string]$Location,
        [string]$Description,
        [string]$Fix
    )

    return [ordered]@{
        Severity = $Severity
        Category = $Category
        Location = $Location
        Description = $Description
        Fix = $Fix
    }
}

function Convert-MetaReviewFindingsToMarkdown {
    param([array]$Findings)

    if ($null -eq $Findings -or $Findings.Count -eq 0) {
        return @"
## QC Status: PASS

## Issues Found: 0

## Regression Report
None

## Summary
Meta-plan review complete. The reviewed file satisfies the checklist, preserves the original intent, and is ready for use.
"@
    }

    $lines = @(
        "## QC Status: FAIL",
        "",
        "## Issues Found: $($Findings.Count)",
        ""
    )

    $index = 1
    foreach ($finding in $Findings) {
        $lines += @(
            "### Issue $index",
            "- **Severity**: $($finding.Severity)",
            "- **Category**: $($finding.Category)",
            "- **Location**: $($finding.Location)",
            "- **Description**: $($finding.Description)",
            "- **Fix**: $($finding.Fix)",
            ""
        )
        $index++
    }

    $lines += @(
        "## Regression Report",
        "None",
        "",
        "## Summary",
        "Deterministic meta-review validation found structural or context-alignment issues that must be fixed before semantic review can pass."
    )

    return ($lines -join "`r`n")
}

function Get-MetaReviewDeterministicFindings {
    param([string]$PlanFile)

    $findings = New-Object System.Collections.Generic.List[object]
    $targetContent = if (Test-Path $Script:MetaReviewTargetFile -PathType Leaf) { Get-Content -Path $Script:MetaReviewTargetFile -Raw } else { "" }
    $reviewedContent = if (Test-Path $Script:MetaReviewOutputFile -PathType Leaf) { Get-Content -Path $Script:MetaReviewOutputFile -Raw } else { "" }
    $contentOutsideFences = Remove-FencedMarkdownBlocks -Content $reviewedContent
    $repoContext = Resolve-MetaReviewRepoContext
    $sourceUsesCurrentContext = ($targetContent -match '(?i)\bcurrent context\b')

    if ([string]::IsNullOrWhiteSpace($reviewedContent)) {
        $findings.Add((New-MetaReviewFinding -Severity "HIGH" -Category "Plan Compliance" -Location "Reviewed output file" -Description "The reviewed meta-plan output file is missing or empty." -Fix "Write the reviewed meta plan to the expected sibling *.reviewed.md path before QC runs."))
        return $findings
    }

    $requiredSections = @(
        @{ Name = "Overview"; Pattern = '(?im)^##\s+Overview\s*$' },
        @{ Name = "Input Files"; Pattern = '(?im)^##\s+Input Files\s*$' },
        @{ Name = "LLM Productivity Rules"; Pattern = '(?im)^##\s+LLM Productivity (Rules|Directives)\s*$' },
        @{ Name = "Requirements"; Pattern = '(?im)^##\s+Requirements\s*$' },
        @{ Name = "Output Structure Template"; Pattern = '(?im)^##\s+Output Structure Template\s*$' },
        @{ Name = "Deliverables"; Pattern = '(?im)^##\s+Deliverables\s*$' }
    )
    foreach ($section in $requiredSections) {
        if ($reviewedContent -notmatch $section.Pattern) {
            $findings.Add((New-MetaReviewFinding -Severity "HIGH" -Category "Plan Compliance" -Location "Top-level sections" -Description "The reviewed meta plan is missing the required `"$($section.Name)`" section." -Fix "Add a `## $($section.Name)` section with complete content that satisfies the checklist."))
        }
    }

    $requiredOutputSections = @(
        "Project Location",
        "What This Project Is",
        "Completed Work Table",
        "Current Cycle Task",
        "Pre-Conditions",
        "Files to Create",
        "Files to Update",
        "Context Files to Read",
        "Implementation Details",
        "Verification Checklist",
        "Key Differences",
        "Running/Testing Instructions",
        "Quickstart Tutorial",
        "Frontend Design Notes",
        "After Completion Instructions",
        "QC Lessons Learned",
        "Next Cycle Instructions"
    )
    $missingOutputSections = @($requiredOutputSections | Where-Object { $reviewedContent -notmatch [regex]::Escape($_) })
    if ($missingOutputSections.Count -gt 0) {
        $findings.Add((New-MetaReviewFinding -Severity "HIGH" -Category "Plan Compliance" -Location "Required Output Sections" -Description "The reviewed meta plan is missing one or more required output section names: $($missingOutputSections -join ', ')." -Fix "Restore every required output section name in the Required Output Sections table and the output template."))
    }

    $quickstartSubsections = @("Prerequisites", "Installation", "Configuration", "First Run", "Verification")
    $missingQuickstartSubsections = @($quickstartSubsections | Where-Object { $reviewedContent -notmatch [regex]::Escape($_) })
    if ($missingQuickstartSubsections.Count -gt 0) {
        $findings.Add((New-MetaReviewFinding -Severity "MEDIUM" -Category "Plan Compliance" -Location "Quickstart Tutorial requirements" -Description "The reviewed meta plan is missing required Quickstart Tutorial subsection names: $($missingQuickstartSubsections -join ', ')." -Fix "Add the missing Quickstart subsection names to the requirements and template so every generated plan includes them."))
    }

    if ($reviewedContent -notmatch 'Project Goal Reference') {
        $findings.Add((New-MetaReviewFinding -Severity "HIGH" -Category "Plan Compliance" -Location "Output Structure Template / Project Location" -Description "The reviewed meta plan does not require an explicit project goal reference in generated plans." -Fix "Add a `Project Goal Reference` field with an explicit file path or URL and state why it must be read."))
    }

    if ($reviewedContent -notmatch 'Previous Cycle Plan File' -or $reviewedContent -notmatch 'Next Cycle Plan File') {
        $findings.Add((New-MetaReviewFinding -Severity "HIGH" -Category "Plan Compliance" -Location "Next Cycle Instructions" -Description "The reviewed meta plan does not require both previous and next cycle plan navigation fields." -Fix "Require `Previous Cycle Plan File` and `Next Cycle Plan File` explicitly in the output template, including edge-case instructions."))
    }

    if (-not (Test-MetaReviewInProgressGate -Content $reviewedContent)) {
        $findings.Add((New-MetaReviewFinding -Severity "HIGH" -Category "Plan Compliance" -Location "Requirements / Verify Previous Cycle Completion" -Description "The reviewed meta plan does not define a full in-progress-cycle gate before generating a new cycle plan." -Fix "Add explicit `inProgressCycles` handling that resumes the active cycle and forbids generating a new continuation plan while a cycle is already in progress."))
    }

    if (-not (Test-MetaReviewResumePlanBranch -Content $reviewedContent)) {
        $findings.Add((New-MetaReviewFinding -Severity "HIGH" -Category "Plan Compliance" -Location "Requirements / Deliverables" -Description "The reviewed meta plan does not explicitly preserve the resume-plan branch in both requirements and deliverables." -Fix "Describe the `RESUME_CYCLE_[NN].md` branch and make its artifact/state behavior explicit."))
    }

    if (-not (Test-MetaReviewTerminalBranch -Content $reviewedContent)) {
        $findings.Add((New-MetaReviewFinding -Severity "HIGH" -Category "Plan Compliance" -Location "Requirements / Identify the Next Cycle" -Description "The reviewed meta plan does not define terminal behavior for the final cycle or for an empty `pendingCycles` list." -Fix "Add an explicit terminal branch that stops without generating a new cycle plan when all cycles are complete, and align the template with that branch."))
    }

    if (-not (Test-MetaReviewConditionalSectionsConsistency -Content $reviewedContent)) {
        $findings.Add((New-MetaReviewFinding -Severity "MEDIUM" -Category "Plan Compliance" -Location "Requirements / Required Output Sections / Output Structure Template" -Description "The reviewed meta plan is internally inconsistent about conditional output sections. It describes generated plans as always containing all 17 sections while also marking `Key Differences` or `Frontend Design Notes` as conditional." -Fix "State that the table defines 17 section entries, but generated plans must include all always-required sections, plus `Key Differences` only for migration/refactor cycles and `Frontend Design Notes` only for UI/canvas/visual cycles. Mirror that wording in Requirements, the Required Output Sections intro, and the Output Structure Template notes."))
    }

    $outsideFencePlaceholderEvidence = Get-MetaReviewOutsideFencePlaceholderEvidence -ContentOutsideFences $contentOutsideFences
    if ($outsideFencePlaceholderEvidence.Count -gt 0) {
        $placeholderEvidence = @($outsideFencePlaceholderEvidence | Select-Object -First 2) -join '; '
        $description = "Placeholder-style text remains outside fenced template content. Evidence: $placeholderEvidence."
        $findings.Add((New-MetaReviewFinding -Severity "MEDIUM" -Category "Documentation" -Location "Content outside the output template fence" -Description $description -Fix "Replace or remove placeholder text outside code fences so only the template contains unresolved placeholders."))
    }

    $templateContent = Get-FencedOutputTemplateContent -Content $reviewedContent
    if (-not [string]::IsNullOrWhiteSpace($templateContent)) {
        $templateContentOutsideInnerFences = Remove-FencedMarkdownBlocks -Content $templateContent
        $allowedTemplateTokens = @('[NN]', '[NN-1]', '[NN+1]', '[NNr]', '[Cycle Title]')
        $instructionalTemplatePlaceholders = New-Object System.Collections.Generic.List[string]
        foreach ($match in [regex]::Matches($templateContentOutsideInnerFences, '\[[^\[\]\r\n]{1,200}\]')) {
            $token = [string]$match.Value
            if ($allowedTemplateTokens -contains $token) {
                continue
            }

            $innerToken = [string]$match.Value.Trim('[', ']')
            if ($innerToken -match '^\s*[xX ]?\s*$') {
                continue
            }

            if (-not $instructionalTemplatePlaceholders.Contains($token)) {
                $instructionalTemplatePlaceholders.Add($token)
            }
        }

        if ($instructionalTemplatePlaceholders.Count -gt 0) {
            $placeholderExamples = @($instructionalTemplatePlaceholders | Select-Object -First 3) -join ', '
            $findings.Add((New-MetaReviewFinding -Severity "MEDIUM" -Category "Completeness" -Location "Output Structure Template" -Description "The fenced output template contains $($instructionalTemplatePlaceholders.Count) instructional placeholder(s) (e.g., $placeholderExamples). Only structural template variables ($($allowedTemplateTokens -join ', ')) may use brackets inside the fence." -Fix "Keep only structural template variables in brackets. Move authoring guidance outside the fence or rewrite each placeholder as concrete non-bracketed template text."))
        }
    }

    if ($sourceUsesCurrentContext -and $repoContext.HasIndexHtml) {
        $hasDiscoveryRule = (
            $reviewedContent -match '(?i)index\.html' -and
            $reviewedContent -match '(?i)(discover|discovered|actual path|linked stylesheet|linked script|<link|<script)'
        )
        if (-not $hasDiscoveryRule) {
            $findings.Add((New-MetaReviewFinding -Severity "HIGH" -Category "Correctness" -Location "Input Files / Context Files to Read" -Description "The source plan says to use the current project context, but the reviewed meta plan does not require discovery of actual source paths from the existing workspace layout." -Fix "Require reading `index.html` first and deriving real stylesheet/script paths from the current workspace instead of assuming root-level filenames."))
        }
    }

    if ($sourceUsesCurrentContext -and $repoContext.HasTests -and $reviewedContent -notmatch '(?i)\btests?\b') {
        $findings.Add((New-MetaReviewFinding -Severity "MEDIUM" -Category "Plan Compliance" -Location "Running/Testing Instructions / Context Files to Read" -Description "The target workspace already has test files, but the reviewed meta plan does not tell the generated plan to read or run them." -Fix "Add test discovery and test-running instructions when relevant test files already exist in the target workspace."))
    }

    return $findings
}

function Invoke-MetaReviewDeterministicValidation {
    param(
        [string]$PlanFile,
        [string]$StageName
    )

    $timestamp = Get-Timestamp
    $Script:CurrentQCReport = Join-Path $Script:LogsDir "doc_qc_report_meta_validation$($Script:CurrentIteration)_$timestamp.md"

    Update-RunState @{
        status = "running"
        phase = "document_qc"
        currentAction = "meta_review_validation"
        currentTool = "validator"
        currentIteration = $Script:CurrentIteration
        currentQCReport = $Script:CurrentQCReport
        currentArtifact = $Script:CurrentQCReport
        currentArtifactType = "qc_report"
        lastError = ""
    }
    Write-RunEvent -Type "meta_review_validation_started" -Data @{
        iteration = $Script:CurrentIteration
        report = $Script:CurrentQCReport
        stage = $StageName
        message = "Deterministic meta-review validation started ($StageName)."
    }
    Write-LogInfo "Running deterministic meta-review validation ($StageName)..."
    Write-LogInfo "QC Report: $($Script:CurrentQCReport)"

    try {
        $findings = Get-MetaReviewDeterministicFindings -PlanFile $PlanFile
        $header = @"
# QC Report (Meta Review Deterministic Validation)
- **Generated**: $(Get-TimestampReadable)
- **Iteration**: $($Script:CurrentIteration)
- **QC Type**: $QCType
- **QC Tool**: Deterministic Validator
- **Plan File**: $PlanFile
- **Pipeline ID**: $($Script:PipelineStartTime)
- **Full Log**: $($Script:QCLogFile)

---

"@
        $body = Convert-MetaReviewFindingsToMarkdown -Findings $findings
        Write-MarkdownArtifact -FilePath $Script:CurrentQCReport -Header $header -Body $body

        Write-LogSuccess "Deterministic meta-review validation complete"
        Write-RunEvent -Type "meta_review_validation_completed" -Data @{
            iteration = $Script:CurrentIteration
            report = $Script:CurrentQCReport
            stage = $StageName
            issueCount = $findings.Count
            message = "Deterministic meta-review validation complete ($StageName)."
        }
        return $true
    }
    catch {
        Write-LogError "Deterministic meta-review validation failed: $($_.Exception.Message)"
        Write-RunEvent -Type "meta_review_validation_failed" -Level "error" -Data @{
            iteration = $Script:CurrentIteration
            report = $Script:CurrentQCReport
            stage = $StageName
            message = "Deterministic meta-review validation failed: $($_.Exception.Message)"
        }
        return $false
    }
}

function Complete-MetaReviewPipeline {
    Write-LogHeader "QC PASSED on iteration $($Script:CurrentIteration)"
    New-GitCheckpoint "qc-passed-iteration-$($Script:CurrentIteration)"
    Write-RunEvent -Type "qc_passed" -Data @{
        iteration = $Script:CurrentIteration
        report = $Script:CurrentQCReport
        qcType = $QCType
        message = "QC passed on iteration $($Script:CurrentIteration) ($QCType mode)"
    }

    @"

================================================================================
PIPELINE COMPLETED SUCCESSFULLY
================================================================================
Completed:           $(Get-TimestampReadable)
QC Type:             $QCType
Plan QC Iterations:  $(if ($SkipPlanQC) { "Skipped" } else { $Script:CurrentPlanQCIteration })
Meta Review QC Reports: $($Script:CurrentIteration)
Final Plan QC:       $(if ($SkipPlanQC) { "Skipped" } else { $Script:CurrentPlanQCReport })
Final Meta Review QC: $($Script:CurrentQCReport)
Log file:            $($Script:QCLogFile)
================================================================================
"@ | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

    Write-LogSuccess "Pipeline complete! Output is QC-verified."
    Write-LogInfo "Final QC report: $($Script:CurrentQCReport)"
    Write-LogInfo "Full log: $($Script:QCLogFile)"
    Complete-Pipeline -Message "Pipeline completed successfully." -Data @{
        phase = "document_qc"
        report = $Script:CurrentQCReport
        qcType = $QCType
    }
}

function Invoke-MetaReviewPipeline {
    param([string]$PlanFile)

    $maxDeterministicFixPasses = 2
    $allowDeterministicMediumContinuation = $true
    $maxCodexPasses = 3
    $maxClaudePasses = $maxDeterministicFixPasses + 2

    Update-RunState @{
        phase = "document_qc"
        currentAction = "meta_review_qc"
    }
    Write-RunEvent -Type "qc_loop_started" -Data @{
        maxCodexPasses = $maxCodexPasses
        maxClaudePasses = $maxClaudePasses
        qcType = $QCType
        message = "Phase 2: Meta Review QC (bounded deterministic + relay semantic reconciliation + 3 Codex passes max, including one recovery pass, and up to $maxDeterministicFixPasses deterministic Claude fix pass(es))"
    }
    Write-LogHeader "Phase 2: Meta Review QC"
    Write-LogInfo "Meta review uses deterministic validation plus relay semantic reconciliation with at most $maxCodexPasses Codex passes, including one bounded recovery pass, and up to $maxDeterministicFixPasses deterministic Claude fix pass(es)."

    $Script:CurrentIteration = 1
    if (-not (Invoke-MetaReviewDeterministicValidation -PlanFile $PlanFile -StageName "initial")) {
        Fail-Pipeline -Message "Deterministic meta-review validation failed to run." -Data @{
            phase = "document_qc"
            report = $Script:CurrentQCReport
        }
    }

    $deterministicPassed = Test-QCPassed
    if (-not $deterministicPassed) {
        $deterministicFixAttempt = 0
        while ($deterministicFixAttempt -lt $maxDeterministicFixPasses -and -not $deterministicPassed) {
            $deterministicFixAttempt++
            Write-LogWarn "Deterministic validation found issues. Applying bounded Claude fix pass $deterministicFixAttempt of $maxDeterministicFixPasses..."
            $issues = Get-QCIssues
            if ([string]::IsNullOrWhiteSpace($issues)) {
                Fail-Pipeline -Message "Deterministic validation failed but no issues could be extracted." -Data @{
                    phase = "document_qc"
                    report = $Script:CurrentQCReport
                }
            }

            Add-IssuesToHistory -Issues $issues -Iteration $Script:CurrentIteration
            Write-IterationHistory -Iteration $Script:CurrentIteration -Issues $issues -Status "FAIL"
            "`n--- Issues to fix (iteration $($Script:CurrentIteration)) ---`n$issues`n" |
            Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

            if (-not (Invoke-ClaudeFix -PlanFile $PlanFile -QCIssues $issues)) {
                Fail-Pipeline -Message "Claude failed to fix deterministic meta-review issues." -Data @{
                    phase = "document_qc"
                    iteration = $Script:CurrentIteration
                }
            }

            New-GitCheckpoint "fixes-iteration-$($Script:CurrentIteration)"
            $Script:CurrentIteration++
            if (-not (Invoke-MetaReviewDeterministicValidation -PlanFile $PlanFile -StageName "post-deterministic-fix")) {
                Fail-Pipeline -Message "Deterministic meta-review validation failed to rerun after Claude fixes." -Data @{
                    phase = "document_qc"
                    report = $Script:CurrentQCReport
                }
            }

            $deterministicPassed = Test-QCPassed
        }

        if (-not $deterministicPassed) {
            $issues = Get-QCIssues
            if ([string]::IsNullOrWhiteSpace($issues)) {
                Fail-Pipeline -Message "Deterministic validation failed but no issues could be extracted after bounded retries." -Data @{
                    phase = "document_qc"
                    report = $Script:CurrentQCReport
                    iteration = $Script:CurrentIteration
                }
            }

            Add-IssuesToHistory -Issues $issues -Iteration $Script:CurrentIteration
            Write-IterationHistory -Iteration $Script:CurrentIteration -Issues $issues -Status "FAIL"

            $severitySummary = Get-QCIssueSeveritySummary -Issues $issues
            if ($allowDeterministicMediumContinuation -and $severitySummary.AllNonBlocking) {
                $severityLabel = ($severitySummary.SeverityList -join ", ")
                Write-LogWarn "Deterministic validation still reports non-blocking severity issue(s) after $maxDeterministicFixPasses fix pass(es) (severity: $severityLabel). Continuing to semantic relay review."
                Write-RunEvent -Type "meta_review_validation_nonblocking_issues" -Level "warn" -Data @{
                    phase = "document_qc"
                    report = $Script:CurrentQCReport
                    iteration = $Script:CurrentIteration
                    deterministicFixAttempts = $maxDeterministicFixPasses
                    severities = @($severitySummary.SeverityList)
                    message = "Continuing after bounded deterministic retries because remaining findings are MEDIUM/LOW only."
                }
            }
            else {
                $severityReason = if ($severitySummary.MissingSeverity) {
                    "Missing severity metadata in deterministic findings."
                }
                elseif ($severitySummary.HasUnknownSeverity) {
                    "Unknown severity value(s): $($severitySummary.UnknownSeverities -join ', ')."
                }
                elseif ($severitySummary.HasBlockingSeverity) {
                    "Blocking severity remains: $($severitySummary.SeverityList -join ', ')."
                }
                else {
                    "Blocking severity determination failed."
                }
                Fail-Pipeline -Message "Deterministic meta-review validation still failed after $maxDeterministicFixPasses allowed Claude fix pass(es)." -Data @{
                    phase = "document_qc"
                    report = $Script:CurrentQCReport
                    iteration = $Script:CurrentIteration
                    reason = $severityReason
                }
            }
        }
    }

    $Script:CurrentIteration++
    if (-not (Invoke-CodexMetaReviewRelayReview -PlanFile $PlanFile)) {
        Fail-Pipeline -Message "Codex relay semantic meta-review execution failed." -Data @{
            phase = "document_qc"
            tool = "codex"
            iteration = $Script:CurrentIteration
        }
    }
    if (Test-QCPassed) {
        Complete-MetaReviewPipeline
    }

    $issues = Get-QCIssues
    if ([string]::IsNullOrWhiteSpace($issues)) {
        Fail-Pipeline -Message "Codex semantic meta-review failed but no issues could be extracted." -Data @{
            phase = "document_qc"
            report = $Script:CurrentQCReport
        }
    }
    Add-IssuesToHistory -Issues $issues -Iteration $Script:CurrentIteration
    Write-IterationHistory -Iteration $Script:CurrentIteration -Issues $issues -Status "FAIL"
    "`n--- Issues to fix (iteration $($Script:CurrentIteration)) ---`n$issues`n" |
    Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

    if (-not (Invoke-ClaudeMetaReviewReconcile -PlanFile $PlanFile -QCIssues $issues)) {
        Fail-Pipeline -Message "Claude failed to reconcile the Codex semantic replacement draft." -Data @{
            phase = "document_qc"
            iteration = $Script:CurrentIteration
        }
    }

    New-GitCheckpoint "fixes-iteration-$($Script:CurrentIteration)"
    if (-not (Invoke-MetaReviewDeterministicValidation -PlanFile $PlanFile -StageName "post-semantic-reconcile")) {
        Fail-Pipeline -Message "Deterministic meta-review validation failed to rerun after Claude semantic reconciliation." -Data @{
            phase = "document_qc"
            report = $Script:CurrentQCReport
            iteration = $Script:CurrentIteration
        }
    }
    if (-not (Test-QCPassed)) {
        $issues = Get-QCIssues
        if (-not [string]::IsNullOrWhiteSpace($issues)) {
            Add-IssuesToHistory -Issues $issues -Iteration $Script:CurrentIteration
            Write-IterationHistory -Iteration $Script:CurrentIteration -Issues $issues -Status "FAIL"
        }
        Fail-Pipeline -Message "Deterministic meta-review validation failed after Claude semantic reconciliation." -Data @{
            phase = "document_qc"
            report = $Script:CurrentQCReport
            iteration = $Script:CurrentIteration
        }
    }

    $Script:CurrentIteration++
    if (-not (Invoke-CodexQC -PlanFile $PlanFile)) {
        Fail-Pipeline -Message "Final Codex semantic verification failed to execute." -Data @{
            phase = "document_qc"
            tool = "codex"
            iteration = $Script:CurrentIteration
        }
    }
    if (Test-QCPassed) {
        Complete-MetaReviewPipeline
    }

    $issues = Get-QCIssues
    if ([string]::IsNullOrWhiteSpace($issues)) {
        Fail-Pipeline -Message "Final Codex verification failed but no issues could be extracted for recovery." -Data @{
            phase = "document_qc"
            report = $Script:CurrentQCReport
            iteration = $Script:CurrentIteration
        }
    }

    Add-IssuesToHistory -Issues $issues -Iteration $Script:CurrentIteration
    Write-IterationHistory -Iteration $Script:CurrentIteration -Issues $issues -Status "FAIL"
    "`n--- Issues to fix (iteration $($Script:CurrentIteration)) ---`n$issues`n" |
    Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8
    Write-LogWarn "Final Codex verification found remaining issues. Running one bounded recovery fix cycle..."

    if (-not (Invoke-ClaudeFix -PlanFile $PlanFile -QCIssues $issues)) {
        Fail-Pipeline -Message "Claude failed to fix final Codex QC issues during the bounded recovery cycle." -Data @{
            phase = "document_qc"
            iteration = $Script:CurrentIteration
            report = $Script:CurrentQCReport
        }
    }

    New-GitCheckpoint "fixes-iteration-$($Script:CurrentIteration)"
    $Script:CurrentIteration++
    if (-not (Invoke-MetaReviewDeterministicValidation -PlanFile $PlanFile -StageName "post-final-codex-fix")) {
        Fail-Pipeline -Message "Deterministic meta-review validation failed to rerun after the bounded recovery fix cycle." -Data @{
            phase = "document_qc"
            report = $Script:CurrentQCReport
            iteration = $Script:CurrentIteration
        }
    }
    if (-not (Test-QCPassed)) {
        $issues = Get-QCIssues
        if (-not [string]::IsNullOrWhiteSpace($issues)) {
            Add-IssuesToHistory -Issues $issues -Iteration $Script:CurrentIteration
            Write-IterationHistory -Iteration $Script:CurrentIteration -Issues $issues -Status "FAIL"
        }
        Fail-Pipeline -Message "Deterministic meta-review validation still failed after the bounded recovery fix cycle." -Data @{
            phase = "document_qc"
            report = $Script:CurrentQCReport
            iteration = $Script:CurrentIteration
        }
    }

    $Script:CurrentIteration++
    if (-not (Invoke-CodexQC -PlanFile $PlanFile)) {
        Fail-Pipeline -Message "Recovery Codex verification failed to execute after the bounded recovery fix cycle." -Data @{
            phase = "document_qc"
            tool = "codex"
            iteration = $Script:CurrentIteration
        }
    }
    if (Test-QCPassed) {
        Complete-MetaReviewPipeline
    }

    $issues = Get-QCIssues
    if (-not [string]::IsNullOrWhiteSpace($issues)) {
        Add-IssuesToHistory -Issues $issues -Iteration $Script:CurrentIteration
        Write-IterationHistory -Iteration $Script:CurrentIteration -Issues $issues -Status "FAIL"
    }
    Fail-Pipeline -Message "Meta-review QC failed: issues persist after the bounded recovery cycle." -Data @{
        phase = "document_qc"
        report = $Script:CurrentQCReport
        iteration = $Script:CurrentIteration
    }
}

# =============================================================================
# Main Execution
# =============================================================================

function Start-CrossQCPipeline {
    # Check for help flag first (exit early)
    if ($Help) {
        Show-Help
        exit 0
    }

    # Validate PlanFile is provided when not showing help
    if ([string]::IsNullOrWhiteSpace($PlanFile)) {
        Write-Host "[ERROR] -PlanFile is required. Use -Help for usage information." -ForegroundColor Red
        exit 1
    }

    # Resolve relative paths to absolute
    $Script:PlanFileResolved = if ([System.IO.Path]::IsPathRooted($PlanFile)) {
        [System.IO.Path]::GetFullPath($PlanFile)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $PlanFile))
    }

    $Script:ProjectRoot = (Get-Location).Path
    $Script:LogsRoot = Join-Path $Script:ProjectRoot "logs"
    $Script:CyclesRoot = Join-Path $Script:ProjectRoot "cycles"
    $PromptDir = Resolve-PromptDirectory -RequestedPromptDir $PromptDir
    Initialize-PromptPaths -ResolvedPromptDir $PromptDir
    try {
        Initialize-MetaReviewSettings
    }
    catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    if ($MetaReview -and $QCType -ne "document") {
        Write-Host "[ERROR] -MetaReview requires -QCType document." -ForegroundColor Red
        exit 1
    }

    if ($MetaReview -and $DeliberationMode) {
        Write-Host "[ERROR] -MetaReview does not support -DeliberationMode." -ForegroundColor Red
        exit 1
    }

    if ($MetaReview) {
        $SkipPlanQC = $true
    }

    $Script:SessionId = Get-SessionIdFromPlanFile -PlanFilePath $Script:PlanFileResolved
    $Script:SessionLogsDir = Join-Path $Script:LogsRoot $Script:SessionId
    $Script:LogsDir = $Script:SessionLogsDir
    $Script:SessionCyclesDir = Join-Path $Script:CyclesRoot $Script:SessionId
    $Script:CycleStatusFile = Join-Path $Script:SessionCyclesDir "_CYCLE_STATUS.json"

    foreach ($dir in @($Script:LogsRoot, $Script:SessionLogsDir, $Script:CyclesRoot, $Script:SessionCyclesDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # Create deliberation subdirectories if deliberation mode is enabled
    if ($DeliberationMode) {
        $Script:DeliberationDir = Join-Path $Script:SessionLogsDir "deliberation"
        $Script:DelibPhase0Dir = Join-Path $Script:DeliberationDir "phase0"
        $Script:DelibPhase1Dir = Join-Path $Script:DeliberationDir "phase1"

        foreach ($dir in @($Script:DeliberationDir, $Script:DelibPhase0Dir, $Script:DelibPhase1Dir)) {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }
        # Initialize deliberation state variables
        $Script:DeliberationDocPath = ""
        Write-Host "[INFO] Created deliberation directories" -ForegroundColor Blue
    }

    # Set log file paths with session-scoped directories
    $Script:QCLogFile = Join-Path $Script:SessionLogsDir "qc_log_$($Script:PipelineStartTime).txt"
    $Script:HistoryFile = Join-Path $Script:SessionLogsDir "_iteration_history.md"
    Initialize-RunTelemetry

    # Initialize log file with header
    @"
================================================================================
Cross-QC Pipeline Log (v1.6 - Deliberation Mode)
================================================================================
Pipeline ID:         $($Script:PipelineStartTime)
Session ID:          $($Script:SessionId)
Started:             $(Get-TimestampReadable)
Project root:        $($Script:ProjectRoot)
Plan file:           $Script:PlanFileResolved
QC Type:             $QCType
Max code iterations: $MaxIterations
Max plan iterations: $MaxPlanQCIterations
Claude QC iters:     $ClaudeQCIterations
Deliberation Mode:   $DeliberationMode
Max Delib Rounds:    $MaxDeliberationRounds
Resume From Failure: $ResumeFromFailure
Skip Plan QC:        $SkipPlanQC
Meta Review:         $MetaReview
Meta Review Target:  $($Script:MetaReviewTargetFile)
Meta Review Check:   $($Script:MetaReviewChecklistFile)
Meta Review Output:  $($Script:MetaReviewOutputFile)
Max Retries:         $MaxRetries
Retry Delay (sec):   $RetryDelaySec
Agent Timeout (sec): $AgentTimeoutSec
Prompt dir:          $($Script:PromptDirResolved)
Logs root:           $($Script:LogsRoot)
Logs dir:            $($Script:SessionLogsDir)
Cycles root:         $($Script:CyclesRoot)
Cycles dir:          $($Script:SessionCyclesDir)
Cycle status file:   $($Script:CycleStatusFile)
History file:        $($Script:HistoryFile)
================================================================================

"@ | Out-File -FilePath $Script:QCLogFile -Encoding UTF8

    Save-RunState

    Write-LogHeader "Cross-QC Pipeline Started (v1.6)"
    Write-LogInfo "Pipeline ID: $($Script:PipelineStartTime)"
    Write-LogInfo "Session ID: $($Script:SessionId)"
    Write-LogInfo "Plan file: $Script:PlanFileResolved"
    Write-LogInfo "QC Type: $QCType"
    Write-LogInfo "Max code iterations: $MaxIterations"
    Write-LogInfo "Max plan iterations: $MaxPlanQCIterations"
    Write-LogInfo "Claude QC iterations: $ClaudeQCIterations (0 = Codex only)"
    Write-LogInfo "Resume from failure: $ResumeFromFailure"
    Write-LogInfo "Skip Plan QC: $SkipPlanQC"
    Write-LogInfo "Meta review: $MetaReview"
    if ($MetaReview) {
        Write-LogInfo "Meta review target: $($Script:MetaReviewTargetFile)"
        Write-LogInfo "Meta review checklist: $($Script:MetaReviewChecklistFile)"
        Write-LogInfo "Meta review output: $($Script:MetaReviewOutputFile)"
    }
    Write-LogInfo "Agent timeout: $AgentTimeoutSec seconds"
    Write-LogInfo "Project root: $($Script:ProjectRoot)"
    Write-LogInfo "Prompt directory: $($Script:PromptDirResolved)"
    Write-LogInfo "Logs root: $($Script:LogsRoot)"
    Write-LogInfo "Logs directory: $($Script:SessionLogsDir)"
    Write-LogInfo "Cycles root: $($Script:CyclesRoot)"
    Write-LogInfo "Cycles directory: $($Script:SessionCyclesDir)"
    Write-LogInfo "Cycle status file: $($Script:CycleStatusFile)"
    Write-LogInfo "Log file: $($Script:QCLogFile)"
    Write-LogInfo "History file: $($Script:HistoryFile)"
    Update-RunState @{
        status = "running"
        phase = "startup"
        currentAction = "initializing"
        lastError = ""
    }
    Write-RunEvent -Type "pipeline_started" -Data @{
        planFile = $Script:PlanFileResolved
        promptDir = $Script:PromptDirResolved
        qcType = $QCType
        metaReview = [bool]$MetaReview
        metaReviewTargetFile = $Script:MetaReviewTargetFile
        metaReviewChecklistFile = $Script:MetaReviewChecklistFile
        metaReviewOutputFile = $Script:MetaReviewOutputFile
        skipPlanQC = [bool]$SkipPlanQC
        passOnMediumOnly = [bool]$PassOnMediumOnly
        historyIterations = $HistoryIterations
        reasoningEffort = $ReasoningEffort
        claudeQCIterations = $ClaudeQCIterations
        deliberationMode = [bool]$DeliberationMode
        maxIterations = $MaxIterations
        maxPlanQCIterations = $MaxPlanQCIterations
        maxDeliberationRounds = $MaxDeliberationRounds
        maxRetries = $MaxRetries
        retryDelaySec = $RetryDelaySec
        agentTimeoutSec = $AgentTimeoutSec
        resumeFromFailure = [bool]$ResumeFromFailure
        message = "Pipeline started ($QCType mode$(if ($MetaReview) { ', meta review' } elseif ($DeliberationMode) { ', deliberation' } else { '' }))"
    }

    if ($ResumeFromFailure -and -not $DeliberationMode) {
        Write-LogError "-ResumeFromFailure is only supported together with -DeliberationMode."
        Fail-Pipeline -Message "Resume from failure requires deliberation mode." -Data @{
            phase = "startup"
        }
    }

    # Check dependencies (conditionally check Plan QC prompts)
    if (-not (Test-Dependencies -IncludePlanQC:(-not $SkipPlanQC))) {
        Write-LogError "Dependency check failed. Exiting."
        Fail-Pipeline -Message "Dependency check failed." -Data @{
            phase = "setup"
        }
    }

    # Create initial checkpoint
    New-GitCheckpoint "pre-implementation"

    # Phase 0: Plan QC / Document Deliberation
    # Document deliberation runs independently of SkipPlanQC
    if ($DeliberationMode -and $QCType -eq "document") {
        Update-RunState @{
            phase = "document_deliberation"
            currentAction = $(if ($ResumeFromFailure) { "deliberation_resume" } else { "deliberation" })
        }
        $documentDeliberationSuccess = if ($ResumeFromFailure) {
            Resume-DeliberationFailure -PlanFile $Script:PlanFileResolved
        }
        else {
            Start-DocumentDeliberation -PlanFile $Script:PlanFileResolved
        }
        if (-not $documentDeliberationSuccess) {
            Write-LogError "Document deliberation failed. Exiting."
            Fail-Pipeline -Message "Document deliberation failed." -Data @{
                phase = "document_deliberation"
            }
        }
        $canonicalPlanPath = if (-not [string]::IsNullOrWhiteSpace($Script:DeliberationDocPath)) {
            $Script:DeliberationDocPath
        }
        else {
            Get-ContinuationPlanPath
        }
        if (-not [string]::IsNullOrWhiteSpace($canonicalPlanPath)) {
            Update-CanonicalCycleRegistry -PlanFile $canonicalPlanPath | Out-Null
        }
        New-GitCheckpoint "document-deliberation-complete"
    }
    elseif ($DeliberationMode -and $QCType -eq "code") {
        # Skip Plan QC when deliberation mode is enabled for code mode
        # Code Deliberation in Phase 1 will handle plan refinement
        Update-RunState @{
            phase = "startup"
            currentAction = $(if ($ResumeFromFailure) { "awaiting_code_deliberation_resume" } else { "awaiting_code_deliberation" })
        }
        Write-LogInfo "Skipping Plan QC (deliberation mode enabled, will use Code Deliberation in Phase 1)"
    }
    elseif (-not $SkipPlanQC) {
        # Standard Plan QC loop
        Update-RunState @{
            phase = "plan_qc"
            currentAction = "plan_qc_loop"
        }
        Write-RunEvent -Type "plan_qc_started" -Data @{
            maxIterations = $MaxPlanQCIterations
            message = "Phase 0: Plan QC started ($MaxPlanQCIterations iterations max)"
        }
        Write-LogHeader "Phase 0: Plan QC"

            while ($Script:CurrentPlanQCIteration -lt $MaxPlanQCIterations) {
            $Script:CurrentPlanQCIteration++
            Update-RunState @{
                phase = "plan_qc"
                currentAction = "plan_qc_iteration"
                currentPlanQCIteration = $Script:CurrentPlanQCIteration
            }
            Write-RunEvent -Type "plan_qc_iteration_started" -Data @{
                iteration = $Script:CurrentPlanQCIteration
                maxIterations = $MaxPlanQCIterations
                message = "Plan QC iteration $($Script:CurrentPlanQCIteration) of $MaxPlanQCIterations"
            }
            Write-LogInfo "--- Plan QC Iteration $($Script:CurrentPlanQCIteration) of $MaxPlanQCIterations ---"

            # Run Plan QC with selected tool (Claude for first N iterations, then Codex)
            $currentTool = Get-CurrentQCTool -Iteration $Script:CurrentPlanQCIteration
            Write-LogInfo "Plan QC Tool for iteration $($Script:CurrentPlanQCIteration): $currentTool"

            $planQCSuccess = if ($currentTool -eq "claude") {
                Invoke-ClaudeCodePlanQC -PlanFile $Script:PlanFileResolved
            } else {
                Invoke-CodexPlanQC -PlanFile $Script:PlanFileResolved
            }

            if (-not $planQCSuccess) {
                Write-LogError "$currentTool Plan QC execution failed. Check logs."
                Fail-Pipeline -Message "$currentTool Plan QC execution failed." -Data @{
                    phase = "plan_qc"
                    tool = $currentTool
                    iteration = $Script:CurrentPlanQCIteration
                }
            }

            # Check if Plan QC passed
            if (Test-PlanQCPassed) {
                Write-LogHeader "PLAN QC PASSED on iteration $($Script:CurrentPlanQCIteration)"
                Write-LogInfo "Final Plan QC report: $($Script:CurrentPlanQCReport)"
                Write-RunEvent -Type "plan_qc_passed" -Data @{
                    iteration = $Script:CurrentPlanQCIteration
                    report = $Script:CurrentPlanQCReport
                    message = "Plan QC passed on iteration $($Script:CurrentPlanQCIteration)"
                }
                New-GitCheckpoint "plan-qc-passed-iteration-$($Script:CurrentPlanQCIteration)"
                break
            }

            # Extract issues and run fixes
            Write-LogWarn "Plan QC found issues. Extracting and fixing..."
            Write-RunEvent -Type "plan_qc_failed" -Level "warn" -Data @{
                iteration = $Script:CurrentPlanQCIteration
                report = $Script:CurrentPlanQCReport
                message = "Plan QC found issues (iteration $($Script:CurrentPlanQCIteration))"
            }

            $planIssues = Get-PlanQCIssues

            if ([string]::IsNullOrWhiteSpace($planIssues)) {
                Write-LogError "Plan QC failed but no issues could be extracted. Check $($Script:CurrentPlanQCReport)"
                Write-LogInfo "This may indicate a parsing problem with Codex output format."
                Fail-Pipeline -Message "Plan QC failed but no issues could be extracted." -Data @{
                    phase = "plan_qc"
                    report = $Script:CurrentPlanQCReport
                }
            }

            # Add current issues to history
            Add-PlanIssuesToHistory -Issues $planIssues -Iteration $Script:CurrentPlanQCIteration

            # Log issues being fixed
            "`n--- Plan issues to fix (iteration $($Script:CurrentPlanQCIteration)) ---`n$planIssues`n" |
            Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

            # Run Claude Code to fix plan issues
            if (-not (Invoke-ClaudePlanFix -PlanFile $Script:PlanFileResolved -QCIssues $planIssues)) {
                Write-LogError "Plan fix application failed. Check logs."
                Fail-Pipeline -Message "Plan fix application failed." -Data @{
                    phase = "plan_qc"
                    iteration = $Script:CurrentPlanQCIteration
                }
            }

            New-GitCheckpoint "plan-fixes-iteration-$($Script:CurrentPlanQCIteration)"
        }

        # Check if we exited due to max iterations
        if ($Script:CurrentPlanQCIteration -ge $MaxPlanQCIterations -and -not (Test-PlanQCPassed)) {
            Write-LogHeader "PLAN QC MAX ITERATIONS REACHED"
            Write-LogError "Plan QC did not pass after $MaxPlanQCIterations iterations"
            Write-LogInfo "Review $($Script:CurrentPlanQCReport) for remaining issues"
            Write-LogInfo "Consider using -SkipPlanQC to bypass plan review if plan is acceptable"

            @"

================================================================================
PIPELINE FAILED - PLAN QC MAX ITERATIONS REACHED
================================================================================
Stopped:             $(Get-TimestampReadable)
Plan QC Iterations:  $($Script:CurrentPlanQCIteration)
Last Plan QC:        $($Script:CurrentPlanQCReport)

Plan Issue History:
$($Script:AllPlanIssuesHistory)
================================================================================
"@ | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

            Fail-Pipeline -Message "Plan QC max iterations reached." -Data @{
                phase = "plan_qc"
                iterations = $Script:CurrentPlanQCIteration
                report = $Script:CurrentPlanQCReport
            }
        }
    }  # End of elseif (-not $SkipPlanQC) - standard Plan QC loop
    else {
        Write-LogInfo "Skipping Phase 0 (Plan QC) as requested"
    }

    # Check if we should skip Phase 1+2 (document mode with deliberation already done)
    if ($DeliberationMode -and $QCType -eq "document") {
        # Document deliberation already completed Phase 0 with full document generation
        # Skip to completion
        Write-LogInfo "Document deliberation complete. Skipping standard Phase 1+2."

        @"

================================================================================
PIPELINE COMPLETED SUCCESSFULLY (Deliberation Mode)
================================================================================
Completed:           $(Get-TimestampReadable)
QC Type:             $QCType
Mode:                Deliberation
Max Rounds:          $MaxDeliberationRounds
Deliberation Dir:    $Script:DelibPhase0Dir
Log file:            $($Script:QCLogFile)
================================================================================
"@ | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

        Write-Host ""
        Write-Host "=================================================================================" -ForegroundColor Green
        Write-Host "PIPELINE COMPLETED SUCCESSFULLY (Deliberation Mode)" -ForegroundColor Green
        Write-Host "=================================================================================" -ForegroundColor Green

        Complete-Pipeline -Message "Document deliberation completed successfully." -Data @{
            phase = "document_deliberation"
            deliberationDir = $Script:DelibPhase0Dir
        }
    }

    # Check for code deliberation mode
    if ($DeliberationMode -and $QCType -eq "code") {
        Update-RunState @{
            phase = "code_deliberation"
            currentAction = $(if ($ResumeFromFailure) { "deliberation_resume" } else { "deliberation" })
        }
        $codeDeliberationSuccess = if ($ResumeFromFailure) {
            Resume-DeliberationFailure -PlanFile $Script:PlanFileResolved
        }
        else {
            Start-CodeDeliberation -PlanFile $Script:PlanFileResolved
        }
        if (-not $codeDeliberationSuccess) {
            Write-LogError "Code deliberation failed. Exiting."
            Fail-Pipeline -Message "Code deliberation failed." -Data @{
                phase = "code_deliberation"
            }
        }

        # Track completion status
        Update-CycleStatus -PlanFile $Script:PlanFileResolved
        Mark-PlanCompleted -PlanFile $Script:PlanFileResolved

        New-GitCheckpoint "code-deliberation-complete"

        @"

================================================================================
PIPELINE COMPLETED SUCCESSFULLY (Code Deliberation Mode)
================================================================================
Completed:           $(Get-TimestampReadable)
QC Type:             $QCType
Mode:                Deliberation
Max Rounds:          $MaxDeliberationRounds
Deliberation Dir:    $Script:DelibPhase1Dir
Log file:            $($Script:QCLogFile)
================================================================================
"@ | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

        Write-Host ""
        Write-Host "=================================================================================" -ForegroundColor Green
        Write-Host "PIPELINE COMPLETED SUCCESSFULLY (Code Deliberation Mode)" -ForegroundColor Green
        Write-Host "=================================================================================" -ForegroundColor Green

        Complete-Pipeline -Message "Code deliberation completed successfully." -Data @{
            phase = "code_deliberation"
            deliberationDir = $Script:DelibPhase1Dir
        }
    }

    # Standard Phase 1: Initial implementation
    Update-RunState @{
        phase = "implementation"
        currentAction = "initial_implementation"
    }
    Write-LogHeader "Phase 1: Initial Implementation"

    if (-not (Invoke-ClaudeWrite -PlanFile $Script:PlanFileResolved)) {
        Write-LogError "Initial implementation failed. Exiting."
        Fail-Pipeline -Message "Initial implementation failed." -Data @{
            phase = "implementation"
        }
    }

    New-GitCheckpoint "initial-implementation"

    if ($MetaReview) {
        Invoke-MetaReviewPipeline -PlanFile $Script:PlanFileResolved
    }

    # Standard Phase 2: QC Loop
    $phase2Label = if ($MetaReview) {
        "Phase 2: Meta Review QC Loop"
    }
    elseif ($QCType -eq "document") {
        "Phase 2: Document QC Loop"
    }
    else {
        "Phase 2: Code QC Loop"
    }
    Update-RunState @{
        phase = $(if ($QCType -eq "document") { "document_qc" } else { "qc_loop" })
        currentAction = "qc_loop"
    }
    Write-RunEvent -Type "qc_loop_started" -Data @{
        maxIterations = $MaxIterations
        qcType = $QCType
        message = "$phase2Label ($MaxIterations iterations max)"
    }
    Write-LogHeader $phase2Label

    while ($Script:CurrentIteration -lt $MaxIterations) {
        $Script:CurrentIteration++
        Update-RunState @{
            phase = $(if ($QCType -eq "document") { "document_qc" } else { "qc_loop" })
            currentAction = "qc_iteration"
            currentIteration = $Script:CurrentIteration
        }
        Write-RunEvent -Type "qc_iteration_started" -Data @{
            iteration = $Script:CurrentIteration
            maxIterations = $MaxIterations
            qcType = $QCType
            message = "QC iteration $($Script:CurrentIteration) of $MaxIterations ($QCType mode)"
        }
        Write-LogInfo "--- Iteration $($Script:CurrentIteration) of $MaxIterations ---"
        
        # Run QC with selected tool (Claude for first N iterations, then Codex)
        $currentTool = Get-CurrentQCTool -Iteration $Script:CurrentIteration
        Write-LogInfo "QC Tool for iteration $($Script:CurrentIteration): $currentTool"

        $qcSuccess = if ($currentTool -eq "claude") {
            Invoke-ClaudeCodeQC -PlanFile $Script:PlanFileResolved
        } else {
            Invoke-CodexQC -PlanFile $Script:PlanFileResolved
        }

        if (-not $qcSuccess) {
            Write-LogError "$currentTool QC execution failed. Check logs."
            Fail-Pipeline -Message "$currentTool QC execution failed." -Data @{
                phase = $(if ($QCType -eq "document") { "document_qc" } else { "qc_loop" })
                tool = $currentTool
                iteration = $Script:CurrentIteration
            }
        }
        
        # Check if QC passed
        if (Test-QCPassed) {
            Write-LogHeader "QC PASSED on iteration $($Script:CurrentIteration)"
            New-GitCheckpoint "qc-passed-iteration-$($Script:CurrentIteration)"
            Write-RunEvent -Type "qc_passed" -Data @{
                iteration = $Script:CurrentIteration
                report = $Script:CurrentQCReport
                qcType = $QCType
                message = "QC passed on iteration $($Script:CurrentIteration) ($QCType mode)"
            }
            
            # Log completion
            $qcTypeLabel = if ($MetaReview) { "Meta Review" } elseif ($QCType -eq "document") { "Document" } else { "Code" }
            @"

================================================================================
PIPELINE COMPLETED SUCCESSFULLY
================================================================================
Completed:           $(Get-TimestampReadable)
QC Type:             $QCType
Plan QC Iterations:  $(if ($SkipPlanQC) { "Skipped" } else { $Script:CurrentPlanQCIteration })
$qcTypeLabel QC Iterations: $($Script:CurrentIteration)
Final Plan QC:       $(if ($SkipPlanQC) { "Skipped" } else { $Script:CurrentPlanQCReport })
Final $qcTypeLabel QC: $($Script:CurrentQCReport)
Log file:            $($Script:QCLogFile)
================================================================================
"@ | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8
            
            Write-LogSuccess "Pipeline complete! Output is QC-verified."
            Write-LogInfo "Final QC report: $($Script:CurrentQCReport)"
            Write-LogInfo "Full log: $($Script:QCLogFile)"
            Complete-Pipeline -Message "Pipeline completed successfully." -Data @{
                phase = $(if ($QCType -eq "document") { "document_qc" } else { "qc_loop" })
                report = $Script:CurrentQCReport
                qcType = $QCType
            }
        }
        
        # Extract issues and run fixes
        Write-LogWarn "QC found issues. Extracting and fixing..."
        Write-RunEvent -Type "qc_failed" -Level "warn" -Data @{
            iteration = $Script:CurrentIteration
            report = $Script:CurrentQCReport
            qcType = $QCType
            message = "QC found issues (iteration $($Script:CurrentIteration))"
        }
        
        $issues = Get-QCIssues
        
        if ([string]::IsNullOrWhiteSpace($issues)) {
            Write-LogError "QC failed but no issues could be extracted. Check $($Script:CurrentQCReport)"
            Write-LogInfo "This may indicate a parsing problem with Codex output format."
            Fail-Pipeline -Message "QC failed but no issues could be extracted." -Data @{
                phase = $(if ($QCType -eq "document") { "document_qc" } else { "qc_loop" })
                report = $Script:CurrentQCReport
            }
        }
        
        # Add current issues to history BEFORE fixing (so Claude knows what was already reported)
        Add-IssuesToHistory -Issues $issues -Iteration $Script:CurrentIteration
        
        # Write iteration history file for Codex to read
        Write-IterationHistory -Iteration $Script:CurrentIteration -Issues $issues -Status "FAIL"
        
        # Log issues being fixed
        "`n--- Issues to fix (iteration $($Script:CurrentIteration)) ---`n$issues`n" | 
        Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8
        
        # Run Claude Code to fix issues
        if (-not (Invoke-ClaudeFix -PlanFile $Script:PlanFileResolved -QCIssues $issues)) {
            Write-LogError "Fix application failed. Check logs."
            Fail-Pipeline -Message "Fix application failed." -Data @{
                phase = $(if ($QCType -eq "document") { "document_qc" } else { "qc_loop" })
                iteration = $Script:CurrentIteration
            }
        }
        
        New-GitCheckpoint "fixes-iteration-$($Script:CurrentIteration)"
    }
    
    # Max iterations reached
    $qcTypeLabel = if ($QCType -eq "document") { "DOCUMENT" } else { "CODE" }
    $qcTypeLabelLower = if ($QCType -eq "document") { "Document" } else { "Code" }
    Write-LogHeader "$qcTypeLabel QC MAX ITERATIONS REACHED"
    Write-LogError "$qcTypeLabelLower QC did not pass after $MaxIterations iterations"
    Write-LogInfo "Review $($Script:CurrentQCReport) for remaining issues"
    Write-LogInfo "Review $($Script:QCLogFile) for full history"

    @"

================================================================================
PIPELINE FAILED - $qcTypeLabel QC MAX ITERATIONS REACHED
================================================================================
Stopped:             $(Get-TimestampReadable)
QC Type:             $QCType
Plan QC Iterations:  $(if ($SkipPlanQC) { "Skipped" } else { $Script:CurrentPlanQCIteration })
$qcTypeLabelLower QC Iterations: $($Script:CurrentIteration)
Last Plan QC:        $(if ($SkipPlanQC) { "Skipped" } else { $Script:CurrentPlanQCReport })
Last $qcTypeLabelLower QC: $($Script:CurrentQCReport)

$qcTypeLabelLower Issue History:
$($Script:AllIssuesHistory)
================================================================================
"@ | Out-File -FilePath $Script:QCLogFile -Append -Encoding UTF8

    Fail-Pipeline -Message "$qcTypeLabelLower QC max iterations reached." -Data @{
        phase = $(if ($QCType -eq "document") { "document_qc" } else { "qc_loop" })
        report = $Script:CurrentQCReport
        iterations = $Script:CurrentIteration
        qcType = $QCType
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    Start-CrossQCPipeline
}


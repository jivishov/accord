import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const {
  getReviewedMetaPlanOutputPath,
  getSessionIdForPlan,
  makeTimestamp,
  resolveMetaReviewConfig,
  serializeConfigToArgs
} = require("../src/main/pipeline.js");
const { finalizeCancelledRun, resolveCancelRequest } = require("../src/main/cancel-run.js");
const {
  formatAbsoluteTimestamp,
  formatEventTimestamp,
  formatRelativeTimestamp
} = require("../src/renderer/time-format.js");
const {
  assertAllowedArtifactPath,
  assertWorkspacePlanPath,
  getResumeRunConfig,
  getSession,
  readSessionConfig,
  getWorkspacePaths,
  listHelpTopics,
  metaPlanChecklistPath,
  readArtifact,
  readHelpTopic,
  writeSessionConfig,
  writeSessionState,
  appendSessionEvent
} = require("../src/main/session-store.js");
const {
  listProjectHistory,
  rememberProjectHistory,
  setProjectHistoryStorePath
} = require("../src/main/project-history-store.js");

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function assertThrows(fn, pattern, message) {
  let thrown = null;
  try {
    fn();
  } catch (error) {
    thrown = error;
  }

  assert(Boolean(thrown), message);
  if (pattern) {
    assert(pattern.test(String(thrown?.message || thrown)), `${message} Got: ${thrown?.message || thrown}`);
  }
}

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, ""));
}

function normalizeStdin(value) {
  return String(value ?? "").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").replace(/\n$/, "");
}

function withEnv(name, value, fn) {
  const hadValue = Object.prototype.hasOwnProperty.call(process.env, name);
  const previousValue = process.env[name];
  if (value === undefined || value === null) {
    delete process.env[name];
  } else {
    process.env[name] = String(value);
  }

  try {
    return fn();
  } finally {
    if (hadValue) {
      process.env[name] = previousValue;
    } else {
      delete process.env[name];
    }
  }
}

function toPowerShellArrayLiteral(values, mapper) {
  return `@(${values.map(mapper).join(", ")})`;
}

function toPowerShellHereString(value) {
  const normalized = String(value ?? "").replace(/\r?\n/g, "\r\n");
  return `@'\n${normalized}\n'@`;
}

function getMetaReviewDeterministicFindings({ targetContent, reviewedContent }) {
  const harnessRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cross-qc-meta-review-validator-"));
  const targetPath = path.join(harnessRoot, "meta_plan.md");
  const reviewedPath = path.join(harnessRoot, "meta_plan.reviewed.md");
  const resultPath = path.join(harnessRoot, "findings.json");
  const harnessPath = path.join(harnessRoot, "validator-harness.ps1");

  fs.writeFileSync(targetPath, targetContent, "utf8");
  fs.writeFileSync(reviewedPath, reviewedContent, "utf8");
  fs.writeFileSync(
    harnessPath,
    `
$ErrorActionPreference = "Stop"
. ${JSON.stringify(path.resolve("accord.ps1"))}
$Script:MetaReviewTargetFile = ${JSON.stringify(targetPath)}
$Script:MetaReviewChecklistFile = ${JSON.stringify(path.resolve("plan_for_meta_plan.md"))}
$Script:MetaReviewOutputFile = ${JSON.stringify(reviewedPath)}
$findings = @(Get-MetaReviewDeterministicFindings -PlanFile $Script:MetaReviewTargetFile)
$json = if ($findings.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject @($findings) -Depth 8 }
[System.IO.File]::WriteAllText(${JSON.stringify(resultPath)}, $json)
`,
    "utf8"
  );

  const harnessRun = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", harnessPath],
    {
      cwd: path.resolve("."),
      encoding: "utf8"
    }
  );
  assert(harnessRun.status === 0, `Expected meta-review deterministic validator harness to pass, stdout: ${harnessRun.stdout}\nstderr: ${harnessRun.stderr}`);
  const parsed = JSON.parse(fs.readFileSync(resultPath, "utf8").replace(/^\uFEFF/, "") || "[]");
  return Array.isArray(parsed) ? parsed : [parsed];
}

function getFencedOutputTemplateContent(reviewedContent) {
  const harnessRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cross-qc-output-template-"));
  const reviewedPath = path.join(harnessRoot, "meta_plan.reviewed.md");
  const resultPath = path.join(harnessRoot, "template.txt");
  const harnessPath = path.join(harnessRoot, "template-harness.ps1");

  fs.writeFileSync(reviewedPath, reviewedContent, "utf8");
  fs.writeFileSync(
    harnessPath,
    `
$ErrorActionPreference = "Stop"
. ${JSON.stringify(path.resolve("accord.ps1"))}
$content = Get-Content -Path ${JSON.stringify(reviewedPath)} -Raw
$template = Get-FencedOutputTemplateContent -Content $content
[System.IO.File]::WriteAllText(${JSON.stringify(resultPath)}, $template)
`,
    "utf8"
  );

  const harnessRun = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", harnessPath],
    {
      cwd: path.resolve("."),
      encoding: "utf8"
    }
  );
  assert(harnessRun.status === 0, `Expected output-template harness to pass, stdout: ${harnessRun.stdout}\nstderr: ${harnessRun.stderr}`);
  return fs.readFileSync(resultPath, "utf8").replace(/^\uFEFF/, "");
}

function runMetaReviewPipelineHarness({
  deterministicResults,
  qcPassResults,
  issues,
  fixResults,
  relayResults = [true],
  reconcileResults = [true],
  codexResults
}) {
  const harnessRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cross-qc-meta-review-pipeline-"));
  const planPath = path.join(harnessRoot, "meta_plan.md");
  const reviewedPath = path.join(harnessRoot, "meta_plan.reviewed.md");
  const logPath = path.join(harnessRoot, "qc_log.txt");
  const resultPath = path.join(harnessRoot, "pipeline-result.json");
  const harnessPath = path.join(harnessRoot, "pipeline-harness.ps1");

  fs.writeFileSync(planPath, "# Meta-Plan: Harness\n", "utf8");
  fs.writeFileSync(reviewedPath, "# Reviewed\n", "utf8");
  fs.writeFileSync(logPath, "", "utf8");

  const harnessScript = `
$ErrorActionPreference = "Stop"
. ${JSON.stringify(path.resolve("accord.ps1"))}
$MetaReview = $true
$QCType = "document"
$PassOnMediumOnly = $false
$Script:QCLogFile = ${JSON.stringify(logPath)}
$Script:LogsDir = ${JSON.stringify(harnessRoot)}
$Script:MetaReviewTargetFile = ${JSON.stringify(planPath)}
$Script:MetaReviewChecklistFile = ${JSON.stringify(path.resolve("plan_for_meta_plan.md"))}
$Script:MetaReviewOutputFile = ${JSON.stringify(reviewedPath)}
$Script:CurrentQCReport = ""
$script:HarnessEvents = New-Object System.Collections.Generic.List[string]
$script:HarnessStatus = "running"
$script:HarnessFail = $null
$script:HarnessSeqDeterministic = ${toPowerShellArrayLiteral(deterministicResults, (value) => (value ? "$true" : "$false"))}
$script:HarnessSeqQCPassed = ${toPowerShellArrayLiteral(qcPassResults, (value) => (value ? "$true" : "$false"))}
$script:HarnessSeqIssues = ${toPowerShellArrayLiteral(issues, (value) => toPowerShellHereString(value))}
$script:HarnessSeqFix = ${toPowerShellArrayLiteral(fixResults, (value) => (value ? "$true" : "$false"))}
$script:HarnessSeqRelay = ${toPowerShellArrayLiteral(relayResults, (value) => (value ? "$true" : "$false"))}
$script:HarnessSeqReconcile = ${toPowerShellArrayLiteral(reconcileResults, (value) => (value ? "$true" : "$false"))}
$script:HarnessSeqCodex = ${toPowerShellArrayLiteral(codexResults, (value) => (value ? "$true" : "$false"))}
$script:HarnessIndexDeterministic = 0
$script:HarnessIndexQCPassed = 0
$script:HarnessIndexIssues = 0
$script:HarnessIndexFix = 0
$script:HarnessIndexRelay = 0
$script:HarnessIndexReconcile = 0
$script:HarnessIndexCodex = 0

function Get-NextHarnessValue {
    param([string]$Name)

    $sequence = Get-Variable -Scope Script -Name ("HarnessSeq" + $Name) -ValueOnly
    $indexName = "HarnessIndex" + $Name
    $index = Get-Variable -Scope Script -Name $indexName -ValueOnly
    if ($index -ge $sequence.Count) {
        throw "Harness sequence exhausted: $Name"
    }

    $value = $sequence[$index]
    Set-Variable -Scope Script -Name $indexName -Value ($index + 1)
    return $value
}

function Update-RunState { param([hashtable]$Data) }
function Write-RunEvent {
    param(
        [string]$Type,
        [string]$Level = "info",
        [hashtable]$Data
    )
    $script:HarnessEvents.Add("event:$Type")
}
function Write-LogHeader { param([string]$Message) $script:HarnessEvents.Add("header:$Message") }
function Write-LogInfo { param([string]$Message) $script:HarnessEvents.Add("info:$Message") }
function Write-LogWarn { param([string]$Message) $script:HarnessEvents.Add("warn:$Message") }
function Write-LogSuccess { param([string]$Message) $script:HarnessEvents.Add("success:$Message") }
function Write-LogError { param([string]$Message) $script:HarnessEvents.Add("error:$Message") }
function Add-IssuesToHistory { param([string]$Issues, [int]$Iteration) $script:HarnessEvents.Add("history:$Iteration") }
function Write-IterationHistory { param([int]$Iteration, [string]$Issues, [string]$Status) $script:HarnessEvents.Add(("iteration:{0}:{1}" -f $Iteration, $Status)) }
function New-GitCheckpoint { param([string]$Name) $script:HarnessEvents.Add("checkpoint:$Name") }
function Get-QCIssues {
    $value = [string](Get-NextHarnessValue -Name "Issues")
    $script:HarnessEvents.Add("issues:$($Script:CurrentIteration)")
    return $value
}
function Test-QCPassed {
    $value = [bool](Get-NextHarnessValue -Name "QCPassed")
    $script:HarnessEvents.Add("pass:$($Script:CurrentIteration):$value")
    return $value
}
function Invoke-MetaReviewDeterministicValidation {
    param([string]$PlanFile, [string]$StageName)
    $script:HarnessEvents.Add(("det:{0}:{1}" -f $StageName, $Script:CurrentIteration))
    $Script:CurrentQCReport = Join-Path ${JSON.stringify(harnessRoot)} ("det_" + $StageName + "_iter" + $Script:CurrentIteration + ".md")
    return [bool](Get-NextHarnessValue -Name "Deterministic")
}
function Invoke-CodexMetaReviewRelayReview {
    param([string]$PlanFile)
    $script:HarnessEvents.Add("relay:$($Script:CurrentIteration)")
    $Script:CurrentQCReport = Join-Path ${JSON.stringify(harnessRoot)} ("relay_iter" + $Script:CurrentIteration + ".md")
    return [bool](Get-NextHarnessValue -Name "Relay")
}
function Invoke-ClaudeMetaReviewReconcile {
    param([string]$PlanFile, [string]$QCIssues)
    $script:HarnessEvents.Add("reconcile:$($Script:CurrentIteration)")
    return [bool](Get-NextHarnessValue -Name "Reconcile")
}
function Invoke-ClaudeFix {
    param([string]$PlanFile, [string]$QCIssues)
    $script:HarnessEvents.Add("fix:$($Script:CurrentIteration)")
    return [bool](Get-NextHarnessValue -Name "Fix")
}
function Invoke-CodexQC {
    param([string]$PlanFile)
    $script:HarnessEvents.Add("codex:$($Script:CurrentIteration)")
    $Script:CurrentQCReport = Join-Path ${JSON.stringify(harnessRoot)} ("codex_iter" + $Script:CurrentIteration + ".md")
    return [bool](Get-NextHarnessValue -Name "Codex")
}
function Complete-MetaReviewPipeline {
    $script:HarnessStatus = "completed"
    $script:HarnessEvents.Add("complete:$($Script:CurrentIteration)")
    throw "__PIPELINE_COMPLETE__"
}
function Fail-Pipeline {
    param([string]$Message, [hashtable]$Data)
    $script:HarnessStatus = "failed"
    $script:HarnessFail = [ordered]@{
        Message = $Message
        Iteration = $Data.iteration
        Report = $Data.report
        Phase = $Data.phase
    }
    $script:HarnessEvents.Add("fail:$Message")
    throw "__PIPELINE_FAIL__"
}

try {
    Invoke-MetaReviewPipeline -PlanFile ${JSON.stringify(planPath)}
}
catch {
    if ($_.Exception.Message -notin @("__PIPELINE_COMPLETE__", "__PIPELINE_FAIL__")) {
        throw
    }
}

$result = [ordered]@{
    Status = $script:HarnessStatus
    Fail = $script:HarnessFail
    Events = @($script:HarnessEvents)
    CurrentIteration = $Script:CurrentIteration
}
[System.IO.File]::WriteAllText(${JSON.stringify(resultPath)}, ($result | ConvertTo-Json -Depth 8))
`;

  fs.writeFileSync(harnessPath, harnessScript, "utf8");
  const harnessRun = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", harnessPath],
    {
      cwd: path.resolve("."),
      encoding: "utf8"
    }
  );
  assert(harnessRun.status === 0, `Expected meta-review pipeline harness to pass, stdout: ${harnessRun.stdout}\nstderr: ${harnessRun.stderr}`);
  return readJsonFile(resultPath);
}

const timestamp = makeTimestamp(new Date("2026-03-16T12:34:56"));
assert(/^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$/.test(timestamp), `Unexpected timestamp format: ${timestamp}`);

const serializedArgs = serializeConfigToArgs({
  planFile: "C:\\work\\plan.md",
  promptDir: "C:\\repo\\prompts",
  qcType: "document",
  maxIterations: 7,
  maxPlanQCIterations: 3,
  skipPlanQC: true,
  passOnMediumOnly: true,
  historyIterations: 4,
  reasoningEffort: "high",
  claudeQCIterations: 2,
  deliberationMode: true,
  maxDeliberationRounds: 6,
  maxRetries: 5,
  retryDelaySec: 45,
  agentTimeoutSec: 1234,
  resumeFromFailure: true
});

assert(serializedArgs.includes("-PlanFile"), "Serialized args should include -PlanFile.");
assert(serializedArgs.includes("-PromptDir"), "Serialized args should include -PromptDir.");
assert(serializedArgs.includes("-SkipPlanQC"), "Serialized args should include -SkipPlanQC.");
assert(serializedArgs.includes("-DeliberationMode"), "Serialized args should include -DeliberationMode.");
assert(serializedArgs.includes("-MaxRetries"), "Serialized args should include -MaxRetries.");
assert(serializedArgs.includes("-RetryDelaySec"), "Serialized args should include -RetryDelaySec.");
assert(serializedArgs.includes("-AgentTimeoutSec"), "Serialized args should include -AgentTimeoutSec.");
assert(serializedArgs.includes("-ResumeFromFailure"), "Serialized args should include -ResumeFromFailure.");

const metaReviewArgs = serializeConfigToArgs({
  planFile: "C:\\work\\meta_plan.md",
  promptDir: "C:\\repo\\prompts",
  qcType: "document",
  skipPlanQC: true,
  metaReview: true,
  metaReviewTargetFile: "C:\\work\\meta_plan.md",
  metaReviewChecklistFile: "C:\\repo\\plan_for_meta_plan.md",
  metaReviewOutputFile: "C:\\work\\meta_plan.reviewed.md"
});
assert(metaReviewArgs.includes("-MetaReview"), "Serialized args should include -MetaReview.");
assert(metaReviewArgs.includes("-MetaReviewTargetFile"), "Serialized args should include -MetaReviewTargetFile.");
assert(metaReviewArgs.includes("-MetaReviewChecklistFile"), "Serialized args should include -MetaReviewChecklistFile.");
assert(metaReviewArgs.includes("-MetaReviewOutputFile"), "Serialized args should include -MetaReviewOutputFile.");

const recentRelativeLabel = formatRelativeTimestamp(
  "2026-03-19T10:47:52.000-05:00",
  { now: new Date("2026-03-19T10:48:52.000-05:00").getTime() }
);
assert(recentRelativeLabel !== "2026-03-19T10:47:52.000-05:00", "Expected recent relative label to differ from raw ISO timestamp.");
assert(!recentRelativeLabel.includes("2026-03-19T"), `Expected recent relative label to be user-friendly, got ${recentRelativeLabel}`);

const olderRelativeLabel = formatRelativeTimestamp(
  "2026-03-12T10:48:52.000-05:00",
  { now: new Date("2026-03-19T10:48:52.000-05:00").getTime() }
);
assert(olderRelativeLabel.length > 0, "Expected older relative label to be non-empty.");
assert(!olderRelativeLabel.includes("2026-03-12T"), `Expected older relative label to avoid raw ISO text, got ${olderRelativeLabel}`);

const absoluteTimestamp = formatAbsoluteTimestamp("2026-03-19T10:48:52.4754566-05:00");
assert(absoluteTimestamp !== "2026-03-19T10:48:52.4754566-05:00", "Expected absolute timestamp to be localized.");
assert(absoluteTimestamp.includes("2026"), `Expected localized absolute timestamp to include year, got ${absoluteTimestamp}`);

const invalidTimestamp = formatEventTimestamp("not-a-date");
assert(invalidTimestamp.label === "not-a-date", `Expected invalid timestamp label fallback, got ${invalidTimestamp.label}`);
assert(invalidTimestamp.title === "not-a-date", `Expected invalid timestamp title fallback, got ${invalidTimestamp.title}`);

const missingTimestamp = formatEventTimestamp("");
assert(missingTimestamp.label === "unknown", `Expected missing timestamp label fallback, got ${missingTimestamp.label}`);
assert(missingTimestamp.title === "", `Expected missing timestamp title fallback, got ${missingTimestamp.title}`);

const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cross-qc-electron-"));
setProjectHistoryStorePath(path.join(workspaceRoot, "project-history.json"));
const { logsRoot, cyclesRoot } = getWorkspacePaths(workspaceRoot);
fs.mkdirSync(path.join(logsRoot, "session-alpha"), { recursive: true });
fs.mkdirSync(path.join(cyclesRoot, "session-alpha"), { recursive: true });
fs.writeFileSync(path.join(cyclesRoot, "session-alpha", "CONTINUATION_CYCLE_4.md"), "# Cycle 4\n", "utf8");
fs.writeFileSync(path.join(logsRoot, "session-alpha", "qc_log_test.txt"), "hello\n", "utf8");
fs.writeFileSync(path.join(logsRoot, "session-alpha", "round1_codex_review.md"), "# Codex Review\n\n## Decision: MINOR_REFINEMENT\n", "utf8");
fs.writeFileSync(path.join(logsRoot, "session-alpha", "round1_codex_review_transcript.txt"), "ARGS: codex -a never exec -s workspace-write\n", "utf8");
fs.writeFileSync(path.join(logsRoot, "session-alpha", "qc_report_iter1_2026-03-16_12-34-56_transcript.txt"), "ARGS: codex -a never exec -s read-only\n", "utf8");

const reusedSessionId = getSessionIdForPlan(
  path.join(cyclesRoot, "session-alpha", "CONTINUATION_CYCLE_4.md"),
  workspaceRoot,
  new Date("2026-03-16T12:34:56Z")
);
assert(reusedSessionId === "session-alpha", `Expected existing session id reuse, got ${reusedSessionId}`);

writeSessionState(workspaceRoot, "session-alpha", {
  status: "running",
  phase: "qc_loop",
  currentAction: "qc_iteration",
  childPid: process.pid,
  planFile: path.join(workspaceRoot, "plan.md")
});
appendSessionEvent(workspaceRoot, "session-alpha", "pipeline_started", "info", { test: true });
fs.writeFileSync(path.join(logsRoot, "session-alpha", "_iteration_history.md"), "# History\n", "utf8");

const session = getSession(workspaceRoot, "session-alpha");
assert(session.sessionId === "session-alpha", "Expected session lookup to return the requested session.");
assert(session.status === "running", `Expected running status, got ${session.status}`);
assert(session.isStalled === false, "Expected fresh running session not to be marked stalled.");
assert(session.artifacts.length >= 3, `Expected artifacts for the session, got ${session.artifacts.length}`);
assert(session.recentEvents.length === 1, `Expected one event, got ${session.recentEvents.length}`);
assert(session.processInfo?.state === "active", `Expected active process state for fresh running session, got ${session.processInfo?.state}`);
assert(session.processInfo?.alive === true, "Expected fresh running session process to be alive.");
const codexReviewArtifact = session.artifacts.find((entry) => entry.name === "round1_codex_review.md");
assert(codexReviewArtifact?.kind === "codex_review", `Expected codex review artifact classification, got ${codexReviewArtifact?.kind}`);
const deliberationTranscriptArtifact = session.artifacts.find((entry) => entry.name === "round1_codex_review_transcript.txt");
assert(deliberationTranscriptArtifact?.kind === "transcript", `Expected deliberation transcript classification, got ${deliberationTranscriptArtifact?.kind}`);
assert(deliberationTranscriptArtifact?.sectionLabel === "Session", `Expected transcript section label Session, got ${deliberationTranscriptArtifact?.sectionLabel}`);
const qcTranscriptArtifact = session.artifacts.find((entry) => entry.name === "qc_report_iter1_2026-03-16_12-34-56_transcript.txt");
assert(qcTranscriptArtifact?.kind === "transcript", `Expected QC transcript classification, got ${qcTranscriptArtifact?.kind}`);

const bomRunStateSessionId = "session-bom-run-state";
const bomRunStateLogsDir = path.join(logsRoot, bomRunStateSessionId);
fs.mkdirSync(bomRunStateLogsDir, { recursive: true });
fs.writeFileSync(
  path.join(bomRunStateLogsDir, "run_state.json"),
  `\uFEFF${JSON.stringify({
    schemaVersion: 1,
    sessionId: bomRunStateSessionId,
    status: "running",
    phase: "document_qc",
    currentAction: "meta_review_fix",
    currentTool: "claude",
    currentIteration: 1,
    currentPlanQCIteration: 0,
    currentDeliberationRound: 0,
    childPid: process.pid,
    planFile: path.join(workspaceRoot, "plan.md"),
    lastMessage: "Review in progress",
    startedAt: new Date(Date.now() - 30 * 1000).toISOString(),
    updatedAt: new Date().toISOString()
  }, null, 2)}\n`,
  "utf8"
);
const bomRunStateSession = getSession(workspaceRoot, bomRunStateSessionId);
assert(bomRunStateSession.runState?.childPid === process.pid, `Expected BOM-prefixed run_state to expose childPid ${process.pid}, got ${bomRunStateSession.runState?.childPid}`);
assert(bomRunStateSession.currentAction === "meta_review_fix", `Expected BOM-prefixed run_state currentAction, got ${bomRunStateSession.currentAction}`);
assert(bomRunStateSession.processInfo?.state === "active", `Expected BOM-prefixed run_state process state active, got ${bomRunStateSession.processInfo?.state}`);
assert(bomRunStateSession.processInfo?.alive === true, "Expected BOM-prefixed run_state process to be alive.");

const pendingQcSessionId = "session-pending-qc";
const pendingQcLogsDir = path.join(logsRoot, pendingQcSessionId);
const pendingQcReportPath = path.join(pendingQcLogsDir, "qc_report_iter2_pending.md");
fs.mkdirSync(pendingQcLogsDir, { recursive: true });
writeSessionState(workspaceRoot, pendingQcSessionId, {
  status: "running",
  phase: "document_qc",
  currentAction: "qc_iteration",
  currentQCReport: pendingQcReportPath,
  currentArtifact: pendingQcReportPath,
  currentArtifactType: "qc_report",
  updatedAt: "2026-03-21T12:00:00.000Z",
  planFile: path.join(workspaceRoot, "plan.md")
});
const pendingQcSession = getSession(workspaceRoot, pendingQcSessionId);
assert(pendingQcSession.artifactCount === pendingQcSession.artifacts.length, "Expected artifactCount to continue tracking only real artifacts.");
assert(pendingQcSession.pendingArtifactCount === 1, `Expected one pending QC artifact, got ${pendingQcSession.pendingArtifactCount}`);
assert(pendingQcSession.pendingArtifacts.length === 1, `Expected one pending QC artifact entry, got ${pendingQcSession.pendingArtifacts.length}`);
assert(pendingQcSession.pendingArtifacts[0].path === pendingQcReportPath, `Expected pending QC path ${pendingQcReportPath}, got ${pendingQcSession.pendingArtifacts[0]?.path}`);
assert(pendingQcSession.pendingArtifacts[0].kind === "qc_report", `Expected pending QC kind qc_report, got ${pendingQcSession.pendingArtifacts[0]?.kind}`);
assert(pendingQcSession.pendingArtifacts[0].source === "pending qc report", `Expected pending QC source label, got ${pendingQcSession.pendingArtifacts[0]?.source}`);
assert(!pendingQcSession.artifacts.some((entry) => entry.path === pendingQcReportPath), "Expected missing QC report to stay out of normal artifacts.");

const pendingArtifactTypeSessionId = "session-pending-artifact-type";
const pendingArtifactTypeLogsDir = path.join(logsRoot, pendingArtifactTypeSessionId);
const pendingSummaryPath = path.join(pendingArtifactTypeLogsDir, "summary.future");
fs.mkdirSync(pendingArtifactTypeLogsDir, { recursive: true });
writeSessionState(workspaceRoot, pendingArtifactTypeSessionId, {
  status: "running",
  phase: "document_deliberation",
  currentAction: "deliberation_round",
  currentArtifact: pendingSummaryPath,
  currentArtifactType: "deliberation_summary",
  updatedAt: "2026-03-21T12:05:00.000Z",
  planFile: path.join(workspaceRoot, "plan.md")
});
const pendingArtifactTypeSession = getSession(workspaceRoot, pendingArtifactTypeSessionId);
assert(pendingArtifactTypeSession.pendingArtifactCount === 1, `Expected one pending artifact-type entry, got ${pendingArtifactTypeSession.pendingArtifactCount}`);
assert(pendingArtifactTypeSession.pendingArtifacts[0].kind === "deliberation_summary", `Expected pending currentArtifactType to drive deliberation_summary kind, got ${pendingArtifactTypeSession.pendingArtifacts[0]?.kind}`);

const aliveIdleSessionId = "session-alive-idle";
const aliveIdleLogsDir = path.join(logsRoot, aliveIdleSessionId);
fs.mkdirSync(aliveIdleLogsDir, { recursive: true });
writeSessionState(workspaceRoot, aliveIdleSessionId, {
  status: "running",
  phase: "document_qc",
  currentAction: "qc_iteration",
  currentTool: "codex",
  childPid: process.pid,
  startedAt: new Date(Date.now() - (10 * 60 * 1000)).toISOString(),
  planFile: path.join(workspaceRoot, "plan.md")
});
const aliveIdleRunStatePath = path.join(aliveIdleLogsDir, "run_state.json");
const aliveIdleRunState = readJsonFile(aliveIdleRunStatePath);
aliveIdleRunState.updatedAt = new Date(Date.now() - (2 * 60 * 1000)).toISOString();
fs.writeFileSync(aliveIdleRunStatePath, `${JSON.stringify(aliveIdleRunState, null, 2)}\n`, "utf8");
const aliveIdleSession = getSession(workspaceRoot, aliveIdleSessionId);
assert(aliveIdleSession.processInfo?.state === "alive_idle", `Expected alive_idle process state, got ${aliveIdleSession.processInfo?.state}`);
assert(aliveIdleSession.processInfo?.alive === true, "Expected alive_idle session process to be alive.");
assert(aliveIdleSession.processInfo?.idleDurationMs >= 60 * 1000, `Expected alive_idle duration above 60s, got ${aliveIdleSession.processInfo?.idleDurationMs}`);

const artifact = readArtifact(workspaceRoot, path.join(cyclesRoot, "session-alpha", "CONTINUATION_CYCLE_4.md"));
assert(artifact.format === "markdown", `Expected markdown format, got ${artifact.format}`);
assert(artifact.content.includes("Cycle 4"), "Expected artifact content to be returned.");
const transcriptArtifact = readArtifact(workspaceRoot, path.join(logsRoot, "session-alpha", "round1_codex_review_transcript.txt"));
assert(transcriptArtifact.format === "text", `Expected transcript artifact to be plain text, got ${transcriptArtifact.format}`);
assert(transcriptArtifact.content.includes("workspace-write"), "Expected transcript content to be returned.");
assert(assertWorkspacePlanPath(workspaceRoot, "meta_plan.md") === path.join(workspaceRoot, "meta_plan.md"), "Expected workspace plan helper to resolve relative plan files inside the workspace.");
const workspaceAbsolutePlanPath = path.join(workspaceRoot, "absolute-plan.md");
assert(assertWorkspacePlanPath(workspaceRoot, workspaceAbsolutePlanPath) === workspaceAbsolutePlanPath, "Expected workspace plan helper to accept absolute plan paths inside the workspace.");
assertThrows(() => assertWorkspacePlanPath(workspaceRoot, "..\\escape-plan.md"), /selected workspace directory/, "Expected workspace plan helper to reject relative plan escapes.");
assertThrows(() => assertWorkspacePlanPath(workspaceRoot, "plans\\..\\..\\escape-plan.md"), /selected workspace directory/, "Expected workspace plan helper to reject nested relative plan escapes.");
assertThrows(() => assertWorkspacePlanPath(workspaceRoot, path.join(workspaceRoot, "..", "external-plan.md")), /selected workspace directory/, "Expected workspace plan helper to reject absolute plan paths outside the workspace.");

const codexHelperDir = path.join(workspaceRoot, "codex-helper");
fs.mkdirSync(codexHelperDir, { recursive: true });
const helperReportPath = path.join(codexHelperDir, "helper-report.md");
const helperLogPath = path.join(codexHelperDir, "helper-qc-log.txt");
const helperTranscriptPath = path.join(codexHelperDir, "helper-report_transcript.txt");
const helperCallLogPath = path.join(codexHelperDir, "codex-calls.json");
const helperStatePath = path.join(codexHelperDir, "codex-state.json");
const helperResultPath = path.join(codexHelperDir, "codex-result.json");
const helperResolveResultPath = path.join(codexHelperDir, "codex-resolve-result.txt");
const helperTimeoutResultPath = path.join(codexHelperDir, "codex-timeout-result.json");
const helperUtf8PromptResultPath = path.join(codexHelperDir, "codex-utf8-result.json");
const helperUtf8PromptCapturePath = path.join(codexHelperDir, "codex-utf8-captured.txt");
const helperShimPath = path.join(codexHelperDir, "fake-codex.js");
const helperCmdPath = path.join(codexHelperDir, "codex.cmd");
const helperPrompt = [
  'Do NOT report the OPPOSITE of these issues (e.g., if "add placeholder" was reported, do not now report "remove placeholder").',
  "- remove (contradicts 'add')",
  "- static (contradicts 'placeholders')",
  "Use RESUME_CYCLE_[NN].md — canvas 1200 × 700."
].join("\n");
const helperPromptBase64 = Buffer.from(helperPrompt, "utf8").toString("base64");
const helperShimScript = `
const fs = require("node:fs");

function readJson(filePath, fallbackValue) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8").replace(/^\\uFEFF/, ""));
  } catch {
    return fallbackValue;
  }
}

const args = process.argv.slice(2);
const stdin = fs.readFileSync(0, "utf8");
const callLogPath = process.env.FAKE_CODEX_CALL_LOG;
const statePath = process.env.FAKE_CODEX_STATE;
const state = readJson(statePath, { count: 0 });
state.count += 1;
fs.writeFileSync(statePath, JSON.stringify(state), "utf8");
const entries = readJson(callLogPath, []);
entries.push({ args, stdin });
fs.writeFileSync(callLogPath, JSON.stringify(entries, null, 2), "utf8");
const outputIndex = args.indexOf("-o");
if (outputIndex < 0 || outputIndex + 1 >= args.length) {
  console.error("missing -o output argument");
  process.exit(1);
}
const lastMessageFile = args[outputIndex + 1];
if (state.count === 1) {
  console.error("rate limit exceeded");
  process.exit(1);
}
fs.writeFileSync(lastMessageFile, \`## QC Status: PASS

## Issues Found: 0

## Summary
Meta-plan review complete. The reviewed file satisfies the checklist, preserves the original intent, and is ready for use.
\`, "utf8");
console.log("codex success");
`;
fs.writeFileSync(helperShimPath, helperShimScript, "utf8");
fs.writeFileSync(helperCmdPath, `@echo off\r\nnode "${helperShimPath}" %*\r\n`, "utf8");
const helperHarnessPath = path.join(codexHelperDir, "invoke-codex-helper-test.ps1");
const helperHarnessScript = `
$ErrorActionPreference = "Stop"
. ${JSON.stringify(path.resolve("accord.ps1"))}
$env:PATH = ${JSON.stringify(`${codexHelperDir};`)} + $env:PATH
$env:FAKE_CODEX_CALL_LOG = ${JSON.stringify(helperCallLogPath)}
$env:FAKE_CODEX_STATE = ${JSON.stringify(helperStatePath)}
$script:QCLogFile = ${JSON.stringify(helperLogPath)}
$script:EventsFile = ""
$script:RunState = @{}
$script:CurrentIteration = 2
$script:CurrentPlanQCIteration = 0
$script:MaxRetries = 1
$script:RetryDelaySec = 5
$reportFile = ${JSON.stringify(helperReportPath)}
$resultPath = ${JSON.stringify(helperResultPath)}
$prompt = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(${JSON.stringify(helperPromptBase64)}))
function global:Start-Sleep {
    param([int]$Seconds)
}

$result = Invoke-CodexCommandWithArtifacts -Prompt $prompt -ReportFile $reportFile -ReportHeader "# Smoke Header" -ToolLabel "Codex (QC Review)" -SandboxMode "read-only"
[System.IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 6))
`;
fs.writeFileSync(helperHarnessPath, helperHarnessScript, "utf8");
const helperHarnessRun = spawnSync(
  "powershell.exe",
  ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", helperHarnessPath],
  {
    cwd: path.resolve("."),
    encoding: "utf8"
  }
);
assert(helperHarnessRun.status === 0, `Expected PowerShell Codex helper harness to pass, stdout: ${helperHarnessRun.stdout}\nstderr: ${helperHarnessRun.stderr}`);
const helperHarnessResult = readJsonFile(helperResultPath);
assert(helperHarnessResult.Success === true, `Expected helper result success, got ${helperHarnessResult.Success}`);
assert(helperHarnessResult.ExitCode === 0, `Expected helper exit code 0, got ${helperHarnessResult.ExitCode}`);
const helperCallLog = readJsonFile(helperCallLogPath);
assert(Array.isArray(helperCallLog), "Expected helper call log to be an array.");
assert(helperCallLog.length === 2, `Expected helper retry to invoke codex twice, got ${helperCallLog.length}`);
assert(helperCallLog.every((entry) => entry.args.at(-1) === "-"), "Expected helper to pass '-' prompt marker to codex.");
assert(helperCallLog.every((entry) => normalizeStdin(entry.stdin) === helperPrompt), "Expected helper to preserve full multiline prompt text via stdin.");
const helperTranscript = fs.readFileSync(helperTranscriptPath, "utf8");
assert(helperTranscript.includes("ARGS: codex -a never exec --skip-git-repo-check -s read-only"), "Expected transcript args header for Codex helper.");
assert(helperTranscript.includes(".helper-report_last_message.tmp -"), "Expected transcript to record stdin prompt marker.");
assert(helperTranscript.includes(`PROMPT: stdin (${helperPrompt.length} chars, ${helperPrompt.split("\n").length} lines)`), "Expected transcript to include prompt stats.");
assert(helperTranscript.includes("codex success"), "Expected transcript to include final CLI output.");

const resolveHarnessPath = path.join(codexHelperDir, "resolve-external-command-test.ps1");
const resolveHarnessScript = `
$ErrorActionPreference = "Stop"
. ${JSON.stringify(path.resolve("accord.ps1"))}
$resultPath = ${JSON.stringify(helperResolveResultPath)}
function global:Get-Command {
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$Name,
        [Parameter(ValueFromRemainingArguments = $true)]
        $Remaining
    )

    if ($Name -eq "codex") {
        return @(
            [pscustomobject]@{ Source = "C:\\shim\\codex.cmd" },
            [pscustomobject]@{ Source = "C:\\preferred\\codex.exe" }
        )
    }

    if ($Name -eq "claude") {
        return @(
            [pscustomobject]@{ Source = "C:\\shim\\claude.cmd" },
            [pscustomobject]@{ Source = "C:\\preferred\\claude.exe" }
        )
    }

    if ($Name -eq "codex-windowsapps") {
        return @(
            [pscustomobject]@{ Source = "C:\\Users\\Test\\AppData\\Local\\Microsoft\\WindowsApps\\codex.exe" },
            [pscustomobject]@{ Source = "C:\\preferred\\codex.cmd" }
        )
    }

    throw "Unexpected Get-Command lookup: $Name"
}

$result = [ordered]@{
    codex = Resolve-ExternalCommandPath -FilePath "codex"
    claude = Resolve-ExternalCommandPath -FilePath "claude"
    codexWindowsApps = Resolve-ExternalCommandPath -FilePath "codex-windowsapps"
}
[System.IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 6))
`;
fs.writeFileSync(resolveHarnessPath, resolveHarnessScript, "utf8");
const resolveHarnessRun = spawnSync(
  "powershell.exe",
  ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", resolveHarnessPath],
  {
    cwd: path.resolve("."),
    encoding: "utf8"
  }
);
assert(resolveHarnessRun.status === 0, `Expected Resolve-ExternalCommandPath harness to pass, stdout: ${resolveHarnessRun.stdout}\nstderr: ${resolveHarnessRun.stderr}`);
const resolveHarnessResult = readJsonFile(helperResolveResultPath);
assert(resolveHarnessResult.codex === "C:\\shim\\codex.cmd", `Expected Resolve-ExternalCommandPath to preserve PATH order for codex, got ${resolveHarnessResult.codex}`);
assert(resolveHarnessResult.claude === "C:\\shim\\claude.cmd", `Expected Resolve-ExternalCommandPath to preserve PATH order for claude, got ${resolveHarnessResult.claude}`);
assert(resolveHarnessResult.codexWindowsApps === "C:\\preferred\\codex.cmd", `Expected Resolve-ExternalCommandPath to skip WindowsApps aliases when a later real command exists, got ${resolveHarnessResult.codexWindowsApps}`);

const timeoutHarnessPath = path.join(codexHelperDir, "invoke-external-timeout-test.ps1");
const timeoutHarnessScript = `
$ErrorActionPreference = "Stop"
. ${JSON.stringify(path.resolve("accord.ps1"))}
$resultPath = ${JSON.stringify(helperTimeoutResultPath)}
function global:Stop-ProcessTree {
    param([int]$ProcessId)
}

$result = Invoke-ExternalProcessWithTimeout -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") -TimeoutSec 1
[System.IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 6))
`;
fs.writeFileSync(timeoutHarnessPath, timeoutHarnessScript, "utf8");
const timeoutHarnessRun = spawnSync(
  "powershell.exe",
  ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", timeoutHarnessPath],
  {
    cwd: path.resolve("."),
    encoding: "utf8",
    timeout: 15000
  }
);
assert(!timeoutHarnessRun.error, `Expected timeout harness to return before spawnSync timeout, error: ${timeoutHarnessRun.error?.message}\nstdout: ${timeoutHarnessRun.stdout}\nstderr: ${timeoutHarnessRun.stderr}`);
assert(timeoutHarnessRun.status === 0, `Expected timeout harness to pass, stdout: ${timeoutHarnessRun.stdout}\nstderr: ${timeoutHarnessRun.stderr}`);
const timeoutHarnessResult = readJsonFile(helperTimeoutResultPath);
assert(timeoutHarnessResult.TimedOut === true, `Expected timeout harness to report TimedOut=true, got ${timeoutHarnessResult.TimedOut}`);
assert(timeoutHarnessResult.ExitCode === 124, `Expected timeout harness exit code 124, got ${timeoutHarnessResult.ExitCode}`);
assert(typeof timeoutHarnessResult.ProcessExited === "boolean", `Expected timeout harness to report ProcessExited boolean state, got ${timeoutHarnessResult.ProcessExited}`);

const utf8CheckScriptPath = path.join(codexHelperDir, "utf8-stdin-check.js");
const utf8CheckScript = `
const fs = require("node:fs");

const input = fs.readFileSync(0);
const decoded = new TextDecoder("utf-8", { fatal: true }).decode(input);
fs.writeFileSync(process.argv[2], decoded, "utf8");
console.log("stdin utf8 ok");
`;
fs.writeFileSync(utf8CheckScriptPath, utf8CheckScript, "utf8");
const utf8HarnessPath = path.join(codexHelperDir, "invoke-external-utf8-test.ps1");
const utf8Prompt = 'Do not generate a new cycle plan — use RESUME_CYCLE_[NN].md and canvas 1200 × 700.';
const utf8PromptBase64 = Buffer.from(utf8Prompt, "utf8").toString("base64");
const utf8HarnessScript = `
$ErrorActionPreference = "Stop"
. ${JSON.stringify(path.resolve("accord.ps1"))}
$resultPath = ${JSON.stringify(helperUtf8PromptResultPath)}
$capturePath = ${JSON.stringify(helperUtf8PromptCapturePath)}
$prompt = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(${JSON.stringify(utf8PromptBase64)}))

$result = Invoke-ExternalProcessWithTimeout -FilePath ${JSON.stringify(process.execPath)} -ArgumentList @(${JSON.stringify(utf8CheckScriptPath)}, $capturePath) -InputText $prompt -TimeoutSec 5
[System.IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 6))
`;
fs.writeFileSync(utf8HarnessPath, utf8HarnessScript, "utf8");
const utf8HarnessRun = spawnSync(
  "powershell.exe",
  ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", utf8HarnessPath],
  {
    cwd: path.resolve("."),
    encoding: "utf8"
  }
);
assert(utf8HarnessRun.status === 0, `Expected UTF-8 stdin harness to pass, stdout: ${utf8HarnessRun.stdout}\nstderr: ${utf8HarnessRun.stderr}`);
const utf8HarnessResult = readJsonFile(helperUtf8PromptResultPath);
assert(utf8HarnessResult.ExitCode === 0, `Expected UTF-8 stdin harness exit code 0, got ${utf8HarnessResult.ExitCode}`);
assert(utf8HarnessResult.TimedOut === false, `Expected UTF-8 stdin harness not to time out, got ${utf8HarnessResult.TimedOut}`);
assert(String(utf8HarnessResult.StdOut || "").includes("stdin utf8 ok"), "Expected UTF-8 stdin harness stdout marker.");
assert(normalizeStdin(fs.readFileSync(helperUtf8PromptCapturePath, "utf8")).includes("— use RESUME_CYCLE_[NN].md"), "Expected captured UTF-8 prompt to preserve the em dash segment.");
assert(normalizeStdin(fs.readFileSync(helperUtf8PromptCapturePath, "utf8")).includes("1200 × 700."), "Expected captured UTF-8 prompt to preserve the multiplication sign segment.");

const metaReviewTargetPath = path.join(workspaceRoot, "meta_plan.md");
fs.writeFileSync(metaReviewTargetPath, "# Meta-Plan: Review Me\n", "utf8");
const reviewedMetaPlanPath = getReviewedMetaPlanOutputPath(metaReviewTargetPath);
assert(reviewedMetaPlanPath.endsWith("meta_plan.reviewed.md"), `Expected reviewed meta-plan naming, got ${reviewedMetaPlanPath}`);
const resolvedMetaReviewConfig = resolveMetaReviewConfig({
  workspaceDir: workspaceRoot,
  promptDir: path.join(workspaceRoot, "prompts"),
  planFile: metaReviewTargetPath,
  qcType: "code",
  skipPlanQC: false,
  deliberationMode: true,
  metaReview: true
}, workspaceRoot, metaReviewTargetPath);
assert(resolvedMetaReviewConfig.qcType === "document", "Expected meta review to force document QC.");
assert(resolvedMetaReviewConfig.skipPlanQC === true, "Expected meta review to force skipPlanQC.");
assert(resolvedMetaReviewConfig.deliberationMode === false, "Expected meta review to disable deliberation.");
assert(resolvedMetaReviewConfig.metaReviewChecklistFile === metaPlanChecklistPath, "Expected bundled checklist path.");
assert(resolvedMetaReviewConfig.metaReviewOutputFile === reviewedMetaPlanPath, "Expected derived reviewed meta-plan path.");

const validatorAcceptedReviewedContent = `# Meta-Plan: Validator Accepted

## Overview
Synthetic reviewed meta plan for deterministic validation coverage.

## Input Files
- cycles/_DEVELOPMENT_CYCLES.md
- cycles/_CYCLE_STATUS.json

## LLM Productivity Rules
1. Keep instructions explicit.

## Requirements
### 1. Read the Development Cycles Document
- Read cycles in order.

### 2. Read the Cycle Status File
- Read statuses in order.

### 3. Verify Previous Cycle Completion
- Collect cycles with status "in-progress" into \`inProgressCycles\`.
- If \`inProgressCycles\` is non-empty:
  - Do NOT generate a new \`CONTINUATION_CYCLE_[NN].md\`.
  - Generate \`cycles/RESUME_CYCLE_[NNr].md\` for the active cycle and stop.

### 4. Identify the Next Cycle to Implement
- Collect \`pendingCycles\`.
- If \`pendingCycles\` is empty, all cycles are complete.

### 5. Generate a Detailed, Self-Contained Plan
- Use the template exactly.

### 6. Update the Status File
- Mark the selected cycle in progress only on the normal branch.

### 7. Generate a Quickstart Tutorial
- Include setup and verification steps.

## Output Structure Template
Project Location
Project Goal Reference
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
Prerequisites
Installation
Configuration
First Run
Verification
Frontend Design Notes
After Completion Instructions
QC Lessons Learned
Next Cycle Instructions
Previous Cycle Plan File
Next Cycle Plan File

## Deliverables
- \`cycles/CONTINUATION_CYCLE_[NN].md\`
- \`cycles/RESUME_CYCLE_[NNr].md\`
`;
const validatorAcceptedFindings = getMetaReviewDeterministicFindings({
  targetContent: "# Meta-Plan: Target\n\nNo current context wording here.\n",
  reviewedContent: validatorAcceptedReviewedContent
});
assert(!validatorAcceptedFindings.some((finding) => finding.Location === "Requirements / Verify Previous Cycle Completion"), "Expected validator to accept alternative in-progress gate wording.");
assert(!validatorAcceptedFindings.some((finding) => finding.Location === "Requirements / Deliverables"), "Expected validator to accept alternative resume-plan placeholder wording.");

const validatorStatusDrivenReviewedContent = `# Meta-Plan: Validator Status Branch

## Overview
Synthetic reviewed meta plan using explicit cycle status branches.

## Input Files
- _DEVELOPMENT_CYCLES.md
- _CYCLE_STATUS.json

## LLM Productivity Rules
1. Keep instructions explicit.

## Requirements
### 1. Read Input Files
- Read both files in order.

### 2. Verify Current Project State
- Confirm whether any cycle has "status": "in_progress".
- Confirm whether any cycle has "status": "pending".

### 3. Verify Previous Cycle Completion
Use this decision tree:

\`\`\`text
if any cycle has status "in_progress":
  generate RESUME_CYCLE_[NN].md for the lowest-numbered in-progress cycle
  do not generate a new continuation plan
else if any cycle has status "pending":
  select the lowest-numbered pending cycle
  verify all earlier cycles are "complete"
  proceed to generate CONTINUATION_CYCLE_[NN].md
else:
  output a plain-text completion report
  stop
\`\`\`

### 4. Identify the Next Cycle to Implement
- Select the lowest-numbered cycle with "status": "pending" when no cycle is already "in_progress".
- Verify all earlier cycles are "complete" before generating the plan.

## Output Structure Template
Project Goal Reference
Previous Cycle Plan File
Next Cycle Plan File
Quickstart Tutorial
Frontend Design Notes
QC Lessons Learned

## Deliverables
- CONTINUATION_CYCLE_[NN].md
- RESUME_CYCLE_[NN].md
- All cycles are "complete" only on the terminal branch.
- Output a plain-text completion report and stop on the terminal branch.
`;
const validatorStatusDrivenFindings = getMetaReviewDeterministicFindings({
  targetContent: "# Meta-Plan: Target\n\nNo current context wording here.\n",
  reviewedContent: validatorStatusDrivenReviewedContent
});
assert(!validatorStatusDrivenFindings.some((finding) => finding.Location === "Requirements / Verify Previous Cycle Completion"), "Expected validator to accept explicit status-driven in-progress branches.");
assert(!validatorStatusDrivenFindings.some((finding) => finding.Location === "Requirements / Identify the Next Cycle"), "Expected validator to accept explicit status-driven terminal branches.");

const validatorConditionalSectionsAcceptedReviewedContent = `# Meta-Plan: Validator Conditional Sections Accepted

## Overview
Synthetic reviewed meta plan with aligned conditional section wording.

## Input Files
- cycles/_DEVELOPMENT_CYCLES.md
- cycles/_CYCLE_STATUS.json

## LLM Productivity Rules
1. Keep instructions explicit.

## Requirements
### 1. Read the Development Cycles Document
- Read cycles in order.

### 2. Read the Cycle Status File
- Read statuses in order.

### 3. Verify Previous Cycle Completion
- Collect cycles with status "in-progress" into \`inProgressCycles\`.
- If \`inProgressCycles\` is non-empty:
  - Do NOT generate a new \`CONTINUATION_CYCLE_[NN].md\`.
  - Generate \`cycles/RESUME_CYCLE_[NN].md\` for the active cycle and stop.

### 4. Identify the Next Cycle to Implement
- Collect \`pendingCycles\`.
- If \`pendingCycles\` is empty, all cycles are complete.

### 5. Generate a Detailed, Self-Contained Plan
- Generated plans must include all always-required sections from the Required Output Sections table.
- Include \`Key Differences\` only for migration/refactor cycles.
- Include \`Frontend Design Notes\` only for UI/canvas/visual cycles.

### 6. Update the Status File
- Mark the selected cycle in progress only on the normal branch.

### 7. Generate a Quickstart Tutorial
- Include setup and verification steps.

## Required Output Sections
The table below defines 17 section entries. Generated plans must include all always-required sections, plus \`Key Differences\` only for migration/refactor cycles and \`Frontend Design Notes\` only for UI/canvas/visual cycles.

## Output Structure Template
- Include all always-required sections below.
- Include \`Key Differences\` only for migration/refactor cycles.
- Include \`Frontend Design Notes\` only for UI/canvas/visual cycles.
Project Location
Project Goal Reference
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
Prerequisites
Installation
Configuration
First Run
Verification
Frontend Design Notes
After Completion Instructions
QC Lessons Learned
Next Cycle Instructions
Previous Cycle Plan File
Next Cycle Plan File

## Deliverables
- \`cycles/CONTINUATION_CYCLE_[NN].md\`
- \`cycles/RESUME_CYCLE_[NN].md\`
`;
const validatorConditionalSectionsAcceptedFindings = getMetaReviewDeterministicFindings({
  targetContent: "# Meta-Plan: Target\n\nNo current context wording here.\n",
  reviewedContent: validatorConditionalSectionsAcceptedReviewedContent
});
assert(!validatorConditionalSectionsAcceptedFindings.some((finding) => finding.Location === "Requirements / Required Output Sections / Output Structure Template"), "Expected validator to accept aligned conditional-section wording.");

const validatorConditionalSectionsRejectedReviewedContent = `# Meta-Plan: Validator Conditional Sections Rejected

## Overview
Synthetic reviewed meta plan with contradictory conditional section wording.

## Input Files
- cycles/_DEVELOPMENT_CYCLES.md
- cycles/_CYCLE_STATUS.json

## LLM Productivity Rules
1. Keep instructions explicit.

## Requirements
### 1. Read the Development Cycles Document
- Read cycles in order.

### 2. Read the Cycle Status File
- Read statuses in order.

### 3. Verify Previous Cycle Completion
- Collect cycles with status "in-progress" into \`inProgressCycles\`.
- If \`inProgressCycles\` is non-empty:
  - Do NOT generate a new \`CONTINUATION_CYCLE_[NN].md\`.
  - Generate \`cycles/RESUME_CYCLE_[NN].md\` for the active cycle and stop.

### 4. Identify the Next Cycle to Implement
- Collect \`pendingCycles\`.
- If \`pendingCycles\` is empty, all cycles are complete.

### 5. Generate a Detailed, Self-Contained Plan
- The plan must include all 17 required output sections defined in the Required Output Sections table.

### 6. Update the Status File
- Mark the selected cycle in progress only on the normal branch.

### 7. Generate a Quickstart Tutorial
- Include setup and verification steps.

### 8. Enforce the Required Output Sections
- \`Key Differences\` is included only when the cycle is a migration or refactor. Omit that section otherwise.
- \`Frontend Design Notes\` is included only when the cycle touches UI, canvas, or visual behavior. Omit that section otherwise.

## Required Output Sections
Every \`CONTINUATION_CYCLE_[NN].md\` must include these 17 sections in this order:
Project Location
Project Goal Reference
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
Previous Cycle Plan File
Next Cycle Plan File

## Output Structure Template
Project Location
Project Goal Reference
What This Project Is
Completed Work Table
Current Cycle Task
Pre-Conditions
Files to Create
Files to Update
Context Files to Read
Implementation Details
Verification Checklist
## 11. Key Differences
> Include this section only if this cycle migrates or refactors existing code. Delete this section entirely otherwise.
Running/Testing Instructions
Quickstart Tutorial
## 14. Frontend Design Notes
> Include this section only when this cycle involves UI, canvas, or visual component work. Delete this section entirely otherwise.
After Completion Instructions
QC Lessons Learned
Next Cycle Instructions
Previous Cycle Plan File
Next Cycle Plan File

## Deliverables
- \`cycles/CONTINUATION_CYCLE_[NN].md\`
- \`cycles/RESUME_CYCLE_[NN].md\`
`;
const validatorConditionalSectionsRejectedFindings = getMetaReviewDeterministicFindings({
  targetContent: "# Meta-Plan: Target\n\nNo current context wording here.\n",
  reviewedContent: validatorConditionalSectionsRejectedReviewedContent
});
assert(validatorConditionalSectionsRejectedFindings.some((finding) => finding.Location === "Requirements / Required Output Sections / Output Structure Template"), "Expected validator to reject contradictory conditional-section wording.");

const validatorRejectedReviewedContent = `# Meta-Plan: Validator Rejected

## Overview
Synthetic reviewed meta plan for deterministic validation coverage.

## Input Files
- cycles/_DEVELOPMENT_CYCLES.md
- cycles/_CYCLE_STATUS.json

## LLM Productivity Rules
1. Keep instructions explicit.

## Requirements
### 1. Read the Development Cycles Document
- Read cycles in order.

### 2. Read the Cycle Status File
- Read statuses in order.

### 3. Verify Previous Cycle Completion
- Collect cycles with status "in-progress" into \`inProgressCycles\`.
- If \`inProgressCycles\` is non-empty, inspect the cycle and continue.

### 4. Identify the Next Cycle to Implement
- Collect \`pendingCycles\`.
- If \`pendingCycles\` is empty, all cycles are complete.

### 5. Generate a Detailed, Self-Contained Plan
- Use the template exactly.

### 6. Update the Status File
- Mark the selected cycle in progress only on the normal branch.

### 7. Generate a Quickstart Tutorial
- Include setup and verification steps.

## Output Structure Template
Project Location
Project Goal Reference
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
Prerequisites
Installation
Configuration
First Run
Verification
Frontend Design Notes
After Completion Instructions
QC Lessons Learned
Next Cycle Instructions
Previous Cycle Plan File
Next Cycle Plan File

## Deliverables
- \`cycles/CONTINUATION_CYCLE_[NN].md\`
`;
const validatorRejectedFindings = getMetaReviewDeterministicFindings({
  targetContent: "# Meta-Plan: Target\n\nNo current context wording here.\n",
  reviewedContent: validatorRejectedReviewedContent
});
assert(validatorRejectedFindings.some((finding) => finding.Location === "Requirements / Verify Previous Cycle Completion"), "Expected validator to keep rejecting missing in-progress hard-stop logic.");
assert(validatorRejectedFindings.some((finding) => finding.Location === "Requirements / Deliverables"), "Expected validator to keep rejecting missing resume-plan branch coverage.");

const extractedOutputTemplate = getFencedOutputTemplateContent(`# Meta-Plan: Template Extraction

## Overview
Extraction fixture.

## Output Structure Template

The first fenced block after this heading is the canonical template.

~~~markdown
# CONTINUATION_CYCLE_[NN]: [Cycle Title]
**Previous Cycle Plan File:** \`cycles/CONTINUATION_CYCLE_[NN-1].md\`
**Next Cycle Plan File:** \`cycles/CONTINUATION_CYCLE_[NN+1].md\`
~~~

## Deliverables
- \`cycles/CONTINUATION_CYCLE_[NN].md\`
`);
assert(extractedOutputTemplate.includes("# CONTINUATION_CYCLE_[NN]: [Cycle Title]"), "Expected fenced output template extractor to return the template body.");
assert(!extractedOutputTemplate.includes("## Output Structure Template"), "Expected fenced output template extractor to omit the heading.");
assert(!extractedOutputTemplate.includes("~~~markdown"), "Expected fenced output template extractor to omit the fence markers.");

const validatorTemplatePlaceholdersAcceptedReviewedContent = `# Meta-Plan: Validator Template Placeholders Accepted

## Overview
Synthetic reviewed meta plan with an output template that only uses structural bracket tokens.

## Input Files
- cycles/_DEVELOPMENT_CYCLES.md
- cycles/_CYCLE_STATUS.json

## LLM Productivity Rules
1. Keep instructions explicit.

## Requirements
### 1. Read the Development Cycles Document
- Read cycles in order.

### 2. Read the Cycle Status File
- Read statuses in order.

### 3. Verify Previous Cycle Completion
- Collect cycles with status "in-progress" into \`inProgressCycles\`.
- If \`inProgressCycles\` is non-empty:
  - Do NOT generate a new \`CONTINUATION_CYCLE_[NN].md\`.
  - Generate \`cycles/RESUME_CYCLE_[NN].md\` for the active cycle and stop.

### 4. Identify the Next Cycle to Implement
- Collect \`pendingCycles\`.
- If \`pendingCycles\` is empty, all cycles are complete.

### 5. Generate a Detailed, Self-Contained Plan
- Generated plans must include all always-required sections from the Required Output Sections table.

## Output Structure Template
~~~markdown
# CONTINUATION_CYCLE_[NN]: [Cycle Title]

**Previous Cycle Plan File:** \`cycles/CONTINUATION_CYCLE_[NN-1].md\`
**Next Cycle Plan File:** \`cycles/CONTINUATION_CYCLE_[NN+1].md\`
**Resume Plan File:** \`cycles/RESUME_CYCLE_[NNr].md\`

## Verification Checklist
- [ ] Confirm the page loads without console errors.
- [x] Confirm the existing scaffold still renders.
~~~

## Deliverables
- \`cycles/CONTINUATION_CYCLE_[NN].md\`
- \`cycles/RESUME_CYCLE_[NN].md\`
`;
const validatorTemplatePlaceholdersAcceptedFindings = getMetaReviewDeterministicFindings({
  targetContent: "# Meta-Plan: Target\n\nNo current context wording here.\n",
  reviewedContent: validatorTemplatePlaceholdersAcceptedReviewedContent
});
assert(!validatorTemplatePlaceholdersAcceptedFindings.some((finding) => finding.Location === "Output Structure Template"), "Expected validator to accept fenced templates that keep only structural bracket tokens.");

const validatorTemplatePlaceholdersRejectedReviewedContent = `# Meta-Plan: Validator Template Placeholders Rejected

## Overview
Synthetic reviewed meta plan with instructional bracket placeholders inside the fenced template.

## Input Files
- cycles/_DEVELOPMENT_CYCLES.md
- cycles/_CYCLE_STATUS.json

## LLM Productivity Rules
1. Keep instructions explicit.

## Requirements
### 1. Read the Development Cycles Document
- Read cycles in order.

### 2. Read the Cycle Status File
- Read statuses in order.

### 3. Verify Previous Cycle Completion
- Collect cycles with status "in-progress" into \`inProgressCycles\`.
- If \`inProgressCycles\` is non-empty:
  - Do NOT generate a new \`CONTINUATION_CYCLE_[NN].md\`.
  - Generate \`cycles/RESUME_CYCLE_[NN].md\` for the active cycle and stop.

### 4. Identify the Next Cycle to Implement
- Collect \`pendingCycles\`.
- If \`pendingCycles\` is empty, all cycles are complete.

### 5. Generate a Detailed, Self-Contained Plan
- Generated plans must include all always-required sections from the Required Output Sections table.

## Output Structure Template
~~~markdown
# CONTINUATION_CYCLE_[NN]: [Cycle Title]

## What This Project Is
[One full paragraph describing the project goal and target audience.]

## Current Cycle Task
[Precise description of what this cycle builds.]
~~~

## Deliverables
- \`cycles/CONTINUATION_CYCLE_[NN].md\`
- \`cycles/RESUME_CYCLE_[NN].md\`
`;
const validatorTemplatePlaceholdersRejectedFindings = getMetaReviewDeterministicFindings({
  targetContent: "# Meta-Plan: Target\n\nNo current context wording here.\n",
  reviewedContent: validatorTemplatePlaceholdersRejectedReviewedContent
});
assert(validatorTemplatePlaceholdersRejectedFindings.some((finding) => finding.Location === "Output Structure Template"), "Expected validator to reject instructional bracket placeholders inside the fenced template.");

const validatorTemplateCheckboxInstructionalReviewedContent = `# Meta-Plan: Validator Template Checkbox Instructional

## Overview
Synthetic reviewed meta plan verifying checkbox handling inside the fenced template.

## Input Files
- cycles/_DEVELOPMENT_CYCLES.md
- cycles/_CYCLE_STATUS.json

## LLM Productivity Rules
1. Keep instructions explicit.

## Requirements
### 1. Read the Development Cycles Document
- Read cycles in order.

### 2. Read the Cycle Status File
- Read statuses in order.

### 3. Verify Previous Cycle Completion
- Collect cycles with status "in-progress" into \`inProgressCycles\`.
- If \`inProgressCycles\` is non-empty:
  - Do NOT generate a new \`CONTINUATION_CYCLE_[NN].md\`.
  - Generate \`cycles/RESUME_CYCLE_[NN].md\` for the active cycle and stop.

### 4. Identify the Next Cycle to Implement
- Collect \`pendingCycles\`.
- If \`pendingCycles\` is empty, all cycles are complete.

### 5. Generate a Detailed, Self-Contained Plan
- Generated plans must include all always-required sections from the Required Output Sections table.

## Output Structure Template
~~~markdown
# CONTINUATION_CYCLE_[NN]: [Cycle Title]

## Verification Checklist
- [ ] [Specific, binary check — pass or fail only.]
- [x] Confirm the prior setup remains intact.
~~~

## Deliverables
- \`cycles/CONTINUATION_CYCLE_[NN].md\`
- \`cycles/RESUME_CYCLE_[NN].md\`
`;
const validatorTemplateCheckboxInstructionalFindings = getMetaReviewDeterministicFindings({
  targetContent: "# Meta-Plan: Target\n\nNo current context wording here.\n",
  reviewedContent: validatorTemplateCheckboxInstructionalReviewedContent
});
assert(validatorTemplateCheckboxInstructionalFindings.some((finding) => finding.Location === "Output Structure Template"), "Expected validator to ignore checkbox markers but still reject the instructional bracket token that follows them.");

const metaReviewPipelineDeterministicSecondPass = runMetaReviewPipelineHarness({
  deterministicResults: [true, true, true],
  qcPassResults: [false, false, true, true],
  issues: [
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: First deterministic fix pass.\n",
    "### Issue 1\n- **Severity**: MEDIUM\n- **Fix**: Second deterministic fix pass.\n"
  ],
  fixResults: [true, true],
  codexResults: [true]
});
assert(metaReviewPipelineDeterministicSecondPass.Status === "completed", `Expected second deterministic pass harness to complete, got ${metaReviewPipelineDeterministicSecondPass.Status}`);
assert(metaReviewPipelineDeterministicSecondPass.Events.includes("fix:2"), "Expected second deterministic pass harness to use the second deterministic Claude fix attempt.");
assert(metaReviewPipelineDeterministicSecondPass.Events.includes("det:post-deterministic-fix:3"), "Expected second deterministic pass harness to rerun deterministic validation after the second fix pass.");
assert(metaReviewPipelineDeterministicSecondPass.Events.includes("relay:4"), "Expected second deterministic pass harness to proceed to semantic relay review after deterministic success.");

const metaReviewPipelineDeterministicMediumContinue = runMetaReviewPipelineHarness({
  deterministicResults: [true, true, true],
  qcPassResults: [false, false, false, true],
  issues: [
    "### Issue 1\n- **Severity**: MEDIUM\n- **Fix**: Deterministic pass 1.\n",
    "### Issue 1\n- **Severity**: MEDIUM\n- **Fix**: Deterministic pass 2.\n",
    "### Issue 1\n- **Severity**: MEDIUM\n- **Fix**: Residual non-blocking deterministic finding.\n"
  ],
  fixResults: [true, true],
  codexResults: [true]
});
assert(metaReviewPipelineDeterministicMediumContinue.Status === "completed", `Expected MEDIUM-only deterministic continuation harness to complete, got ${metaReviewPipelineDeterministicMediumContinue.Status}`);
assert(metaReviewPipelineDeterministicMediumContinue.Events.includes("event:meta_review_validation_nonblocking_issues"), "Expected MEDIUM-only deterministic continuation harness to emit the non-blocking deterministic warning event.");
assert(metaReviewPipelineDeterministicMediumContinue.Events.includes("relay:4"), "Expected MEDIUM-only deterministic continuation harness to continue to semantic relay review.");

const metaReviewPipelineDeterministicBlockingFail = runMetaReviewPipelineHarness({
  deterministicResults: [true, true, true],
  qcPassResults: [false, false, false],
  issues: [
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Deterministic pass 1.\n",
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Deterministic pass 2.\n",
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Blocking deterministic finding remains.\n"
  ],
  fixResults: [true, true],
  codexResults: [true]
});
assert(metaReviewPipelineDeterministicBlockingFail.Status === "failed", "Expected deterministic retry harness to fail when blocking severity remains after the bounded retry budget.");
assert(metaReviewPipelineDeterministicBlockingFail.Fail?.Message === "Deterministic meta-review validation still failed after 2 allowed Claude fix pass(es).", `Unexpected deterministic bounded-retry failure message: ${metaReviewPipelineDeterministicBlockingFail.Fail?.Message}`);
assert(!metaReviewPipelineDeterministicBlockingFail.Events.some((event) => event.startsWith("relay:")), "Expected deterministic bounded-retry blocking failure harness not to proceed to semantic relay review.");

const metaReviewPipelineRecoveryCompleted = runMetaReviewPipelineHarness({
  deterministicResults: [true, true, true, true],
  qcPassResults: [false, true, false, true, false, true, true],
  issues: [
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Initial deterministic fix.\n",
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Relay reconcile fix.\n",
    "### Issue 1\n- **Severity**: MEDIUM\n- **Fix**: Final Codex recovery fix.\n"
  ],
  fixResults: [true, true],
  codexResults: [true, true]
});
assert(metaReviewPipelineRecoveryCompleted.Status === "completed", `Expected bounded recovery harness to complete, got ${metaReviewPipelineRecoveryCompleted.Status}`);
assert(metaReviewPipelineRecoveryCompleted.Events.includes("fix:4"), "Expected bounded recovery harness to invoke Claude fix on the final Codex iteration.");
assert(metaReviewPipelineRecoveryCompleted.Events.includes("det:post-final-codex-fix:5"), "Expected bounded recovery harness to rerun deterministic validation after the final Codex fix.");
assert(metaReviewPipelineRecoveryCompleted.Events.includes("codex:6"), "Expected bounded recovery harness to run one final Codex verification after the recovery fix.");

const metaReviewPipelineRecoveryDeterministicFail = runMetaReviewPipelineHarness({
  deterministicResults: [true, true, true, true],
  qcPassResults: [false, true, false, true, false, false],
  issues: [
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Initial deterministic fix.\n",
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Relay reconcile fix.\n",
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Final Codex recovery fix.\n",
    "### Issue 1\n- **Severity**: MEDIUM\n- **Fix**: Recovery deterministic validation still failed.\n"
  ],
  fixResults: [true, true],
  codexResults: [true]
});
assert(metaReviewPipelineRecoveryDeterministicFail.Status === "failed", "Expected bounded recovery harness to fail when post-final deterministic validation still reports issues.");
assert(metaReviewPipelineRecoveryDeterministicFail.Fail?.Message === "Deterministic meta-review validation still failed after the bounded recovery fix cycle.", `Unexpected deterministic recovery failure message: ${metaReviewPipelineRecoveryDeterministicFail.Fail?.Message}`);

const metaReviewPipelineRecoveryCodexFail = runMetaReviewPipelineHarness({
  deterministicResults: [true, true, true, true],
  qcPassResults: [false, true, false, true, false, true, false],
  issues: [
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Initial deterministic fix.\n",
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Relay reconcile fix.\n",
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Final Codex recovery fix.\n",
    "### Issue 1\n- **Severity**: HIGH\n- **Fix**: Recovery Codex verification still found issues.\n"
  ],
  fixResults: [true, true],
  codexResults: [true, true]
});
assert(metaReviewPipelineRecoveryCodexFail.Status === "failed", "Expected bounded recovery harness to fail when the recovery Codex pass still reports issues.");
assert(metaReviewPipelineRecoveryCodexFail.Fail?.Message === "Meta-review QC failed: issues persist after the bounded recovery cycle.", `Unexpected recovery Codex failure message: ${metaReviewPipelineRecoveryCodexFail.Fail?.Message}`);

const helpTopics = listHelpTopics();
assert(helpTopics.length === 3, `Expected 3 help topics, got ${helpTopics.length}`);
assert(helpTopics[0].id === "quick-start", `Expected quick-start first, got ${helpTopics[0].id}`);

const helpTopic = readHelpTopic("quick-start");
assert(helpTopic.title === "Quick Start", `Expected Quick Start title, got ${helpTopic.title}`);
assert(helpTopic.format === "markdown", `Expected markdown help format, got ${helpTopic.format}`);
assert(helpTopic.content.includes("Accord"), "Expected quick start help content.");

const externalMetaPlanRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cross-qc-meta-review-"));
const externalTargetMetaPlanPath = path.join(externalMetaPlanRoot, "external_meta_plan.md");
const externalReviewedMetaPlanPath = getReviewedMetaPlanOutputPath(externalTargetMetaPlanPath);
fs.writeFileSync(externalTargetMetaPlanPath, "# Meta-Plan: External\n", "utf8");
fs.writeFileSync(externalReviewedMetaPlanPath, "# Meta-Plan: External Reviewed\n\n## Overview\nStrengthened.\n", "utf8");
writeSessionConfig(workspaceRoot, "session-meta-review", {
  workspaceDir: workspaceRoot,
  promptDir: path.join(workspaceRoot, "prompts"),
  planFile: externalTargetMetaPlanPath,
  qcType: "document",
  skipPlanQC: true,
  deliberationMode: false,
  metaReview: true,
  metaReviewTargetFile: externalTargetMetaPlanPath,
  metaReviewChecklistFile: metaPlanChecklistPath,
  metaReviewOutputFile: externalReviewedMetaPlanPath
});
writeSessionState(workspaceRoot, "session-meta-review", {
  status: "completed",
  phase: "document_qc",
  currentAction: "",
  qcType: "document",
  metaReview: true,
  metaReviewTargetFile: externalTargetMetaPlanPath,
  metaReviewChecklistFile: metaPlanChecklistPath,
  metaReviewOutputFile: externalReviewedMetaPlanPath,
  planFile: externalTargetMetaPlanPath
});
const metaReviewSession = getSession(workspaceRoot, "session-meta-review");
assert(metaReviewSession.metaReview === true, "Expected meta review session flag to be exposed.");
assert(metaReviewSession.metaReviewOutputFile === externalReviewedMetaPlanPath, "Expected meta review output file on session summary.");
const reviewedArtifact = metaReviewSession.artifacts.find((entry) => entry.path === externalReviewedMetaPlanPath);
assert(reviewedArtifact?.kind === "meta_review_output", `Expected meta review output artifact classification, got ${reviewedArtifact?.kind}`);
assert(reviewedArtifact?.sectionLabel === "Output", `Expected meta review output in Output section, got ${reviewedArtifact?.sectionLabel}`);
assert(assertAllowedArtifactPath(workspaceRoot, externalReviewedMetaPlanPath, "session-meta-review") === externalReviewedMetaPlanPath, "Expected external reviewed artifact to be allowed for the owning session.");
const reviewedArtifactDoc = readArtifact(workspaceRoot, externalReviewedMetaPlanPath, "session-meta-review");
assert(reviewedArtifactDoc.format === "markdown", `Expected reviewed artifact to be markdown, got ${reviewedArtifactDoc.format}`);
assert(reviewedArtifactDoc.content.includes("Strengthened"), "Expected reviewed artifact content to be readable.");
assert(metaReviewSession.processInfo?.state === "unavailable", `Expected completed meta review session without pid to expose unavailable process state, got ${metaReviewSession.processInfo?.state}`);

const pendingMetaReviewTargetPath = path.join(workspaceRoot, "meta_plan_pending.md");
const pendingMetaReviewOutputPath = getReviewedMetaPlanOutputPath(pendingMetaReviewTargetPath);
fs.writeFileSync(pendingMetaReviewTargetPath, "# Meta-Plan: Pending Review\n", "utf8");
writeSessionConfig(workspaceRoot, "session-meta-review-pending", {
  workspaceDir: workspaceRoot,
  promptDir: path.join(workspaceRoot, "prompts"),
  planFile: pendingMetaReviewTargetPath,
  qcType: "document",
  skipPlanQC: true,
  deliberationMode: false,
  metaReview: true,
  metaReviewTargetFile: pendingMetaReviewTargetPath,
  metaReviewChecklistFile: metaPlanChecklistPath,
  metaReviewOutputFile: pendingMetaReviewOutputPath
});
writeSessionState(workspaceRoot, "session-meta-review-pending", {
  status: "running",
  phase: "document_qc",
  currentAction: "meta_review_reconcile",
  currentIteration: 3,
  metaReview: true,
  metaReviewTargetFile: pendingMetaReviewTargetPath,
  metaReviewChecklistFile: metaPlanChecklistPath,
  metaReviewOutputFile: pendingMetaReviewOutputPath,
  planFile: pendingMetaReviewTargetPath,
  updatedAt: "2026-03-21T12:10:00.000Z"
});
const pendingMetaReviewSession = getSession(workspaceRoot, "session-meta-review-pending");
const pendingMetaArtifact = pendingMetaReviewSession.pendingArtifacts.find((entry) => entry.path === pendingMetaReviewOutputPath);
assert(pendingMetaReviewSession.pendingArtifactCount === 1, `Expected one pending meta-review output, got ${pendingMetaReviewSession.pendingArtifactCount}`);
assert(Boolean(pendingMetaArtifact), "Expected pending meta-review output artifact to be surfaced.");
assert(pendingMetaArtifact?.kind === "meta_review_output", `Expected pending meta-review output kind, got ${pendingMetaArtifact?.kind}`);
assert(pendingMetaArtifact?.source === "meta-review output", `Expected pending meta-review source label, got ${pendingMetaArtifact?.source}`);
assert(pendingMetaReviewSession.artifactCount === pendingMetaReviewSession.artifacts.length, "Expected pending meta-review output not to change real artifact counting.");
fs.writeFileSync(pendingMetaReviewOutputPath, "# Meta-Plan: Pending Review (Materialized)\n", "utf8");
const materializedMetaReviewSession = getSession(workspaceRoot, "session-meta-review-pending");
assert(materializedMetaReviewSession.pendingArtifactCount === 0, `Expected materialized meta-review output to leave pending list, got ${materializedMetaReviewSession.pendingArtifactCount}`);
assert(materializedMetaReviewSession.artifacts.some((entry) => entry.path === pendingMetaReviewOutputPath && entry.kind === "meta_review_output"), "Expected materialized meta-review output to move into normal artifacts.");

const inactivePendingSessionId = "session-pending-inactive";
const inactivePendingLogsDir = path.join(logsRoot, inactivePendingSessionId);
fs.mkdirSync(inactivePendingLogsDir, { recursive: true });
writeSessionState(workspaceRoot, inactivePendingSessionId, {
  status: "completed",
  phase: "document_qc",
  currentAction: "qc_iteration",
  currentQCReport: path.join(inactivePendingLogsDir, "qc_report_iter9_missing.md"),
  currentArtifact: path.join(inactivePendingLogsDir, "qc_report_iter9_missing.md"),
  currentArtifactType: "qc_report",
  updatedAt: "2026-03-21T12:15:00.000Z",
  planFile: path.join(workspaceRoot, "plan.md")
});
const inactivePendingSession = getSession(workspaceRoot, inactivePendingSessionId);
assert(inactivePendingSession.pendingArtifactCount === 0, `Expected non-running session not to expose pending artifacts, got ${inactivePendingSession.pendingArtifactCount}`);

const resumePlanPath = path.join(workspaceRoot, "resume-plan.md");
fs.writeFileSync(resumePlanPath, "# Resume Plan\n", "utf8");
fs.mkdirSync(path.join(logsRoot, "session-resume", "deliberation", "phase0"), { recursive: true });
fs.mkdirSync(path.join(cyclesRoot, "session-resume"), { recursive: true });
fs.writeFileSync(path.join(cyclesRoot, "session-resume", "CONTINUATION_CYCLE_1.md"), "# Continuation\n", "utf8");
fs.writeFileSync(
  path.join(logsRoot, "session-resume", "deliberation", "phase0", "round1_claude_thoughts.md"),
  "## Decision: MINOR_REFINEMENT\n\n- Clarify section links\n",
  "utf8"
);
fs.writeFileSync(
  path.join(logsRoot, "session-resume", "deliberation", "phase0", "round1_codex_evaluation.md"),
  "## Decision: MINOR_REFINEMENT\n\n- Keep links explicit\n",
  "utf8"
);
const storedSessionConfig = writeSessionConfig(workspaceRoot, "session-resume", {
  workspaceDir: workspaceRoot,
  promptDir: path.join(workspaceRoot, "prompts"),
  planFile: resumePlanPath,
  qcType: "document",
  deliberationMode: true,
  maxDeliberationRounds: 4,
  skipPlanQC: false,
  reasoningEffort: "low",
  agentTimeoutSec: 780,
  maxRetries: 3,
  retryDelaySec: 30
});
const loadedSessionConfig = readSessionConfig(workspaceRoot, "session-resume");
assert(loadedSessionConfig.planFile === resumePlanPath, "Expected session config to round-trip.");
assert(loadedSessionConfig.qcType === "document", "Expected stored session config qcType.");
assert(storedSessionConfig.deliberationMode === true, "Expected deliberationMode to persist.");
assert(loadedSessionConfig.agentTimeoutSec === 780, `Expected agentTimeoutSec to persist, got ${loadedSessionConfig.agentTimeoutSec}`);

writeSessionState(workspaceRoot, "session-resume", {
  status: "failed",
  phase: "document_deliberation",
  currentAction: "",
  currentTool: "",
  currentDeliberationRound: 2,
  lastError: "Claude deliberation failed at round 2",
  planFile: resumePlanPath
});
appendSessionEvent(workspaceRoot, "session-resume", "pipeline_started", "info", {
  planFile: resumePlanPath,
  promptDir: storedSessionConfig.promptDir,
  qcType: "document",
  deliberationMode: true,
  maxDeliberationRounds: 4
});
appendSessionEvent(workspaceRoot, "session-resume", "document_deliberation_round_started", "info", {
  round: 2,
  maxRounds: 4
});
appendSessionEvent(workspaceRoot, "session-resume", "pipeline_failed", "error", {
  source: "powershell",
  message: "Claude deliberation failed at round 2"
});

const resumableSession = getSession(workspaceRoot, "session-resume");
assert(resumableSession.canResume === true, "Expected failed deliberation session to be resumable.");
assert(resumableSession.sessionConfig.qcType === "document", "Expected resumable session to keep document qcType.");

const resumeConfig = getResumeRunConfig(workspaceRoot, "session-resume");
assert(resumeConfig.ok === true, "Expected resume config to be available.");
assert(resumeConfig.config.resumeFromFailure === true, "Expected resume config to set resumeFromFailure.");
assert(resumeConfig.config.qcType === "document", "Expected resume config to use stored session qcType.");
assert(resumeConfig.config.planFile === resumePlanPath, "Expected resume config to keep original plan file.");

const metaReviewResumeTargetPath = path.join(workspaceRoot, "meta-review-resume.md");
const metaReviewResumeOutputPath = getReviewedMetaPlanOutputPath(metaReviewResumeTargetPath);
fs.writeFileSync(metaReviewResumeTargetPath, "# Meta Review Resume\n", "utf8");
fs.writeFileSync(metaReviewResumeOutputPath, "# Meta Review Resume (Reviewed)\n", "utf8");
writeSessionConfig(workspaceRoot, "session-meta-review-resume", {
  workspaceDir: workspaceRoot,
  promptDir: path.join(workspaceRoot, "prompts"),
  planFile: metaReviewResumeTargetPath,
  qcType: "document",
  skipPlanQC: true,
  deliberationMode: false,
  metaReview: true,
  metaReviewTargetFile: metaReviewResumeTargetPath,
  metaReviewChecklistFile: metaPlanChecklistPath,
  metaReviewOutputFile: metaReviewResumeOutputPath
});
writeSessionState(workspaceRoot, "session-meta-review-resume", {
  status: "failed",
  phase: "document_qc",
  currentIteration: 2,
  currentAction: "",
  currentTool: "",
  lastError: "codex QC execution failed.",
  planFile: metaReviewResumeTargetPath,
  metaReview: true,
  metaReviewTargetFile: metaReviewResumeTargetPath,
  metaReviewChecklistFile: metaPlanChecklistPath,
  metaReviewOutputFile: metaReviewResumeOutputPath
});
appendSessionEvent(workspaceRoot, "session-meta-review-resume", "pipeline_started", "info", {
  planFile: metaReviewResumeTargetPath,
  promptDir: path.join(workspaceRoot, "prompts"),
  qcType: "document",
  metaReview: true,
  metaReviewTargetFile: metaReviewResumeTargetPath,
  metaReviewChecklistFile: metaPlanChecklistPath,
  metaReviewOutputFile: metaReviewResumeOutputPath,
  message: "Pipeline started (document mode, meta review)"
});
appendSessionEvent(workspaceRoot, "session-meta-review-resume", "pipeline_failed", "error", {
  source: "powershell",
  message: "codex QC execution failed."
});

const metaReviewResumableSession = getSession(workspaceRoot, "session-meta-review-resume");
assert(metaReviewResumableSession.canResume === true, "Expected failed meta review session to be resumable.");
assert(metaReviewResumableSession.resumeReason === "", `Expected no resume reason for resumable meta review session, got ${metaReviewResumableSession.resumeReason}`);

const metaReviewResumeConfig = getResumeRunConfig(workspaceRoot, "session-meta-review-resume");
assert(metaReviewResumeConfig.ok === true, "Expected meta review resume config to be available.");
assert(metaReviewResumeConfig.config.resumeFromFailure === false, "Expected meta review resume config not to use deliberation resume.");
assert(metaReviewResumeConfig.config.metaReview === true, "Expected meta review resume config to keep metaReview enabled.");
assert(metaReviewResumeConfig.config.planFile === metaReviewResumeTargetPath, "Expected meta review resume config to keep original plan file.");
assert(metaReviewResumeConfig.config.metaReviewOutputFile === metaReviewResumeOutputPath, "Expected meta review resume config to keep reviewed output path.");
assert(!serializeConfigToArgs(metaReviewResumeConfig.config).includes("-ResumeFromFailure"), "Expected meta review resume args to omit -ResumeFromFailure.");

fs.mkdirSync(path.join(logsRoot, "session-stale", "deliberation", "phase1"), { recursive: true });
fs.writeFileSync(
  path.join(logsRoot, "session-stale", "deliberation", "phase1", "round2_claude_thoughts.md"),
  "## Decision: MAJOR_REFINEMENT\n\n- Needs another review\n",
  "utf8"
);
writeSessionConfig(workspaceRoot, "session-stale", {
  workspaceDir: workspaceRoot,
  promptDir: path.join(workspaceRoot, "prompts"),
  planFile: resumePlanPath,
  qcType: "code",
  deliberationMode: true,
  maxDeliberationRounds: 4
});
writeSessionState(workspaceRoot, "session-stale", {
  status: "running",
  phase: "code_deliberation",
  currentAction: "deliberation_round",
  currentDeliberationRound: 2,
  childPid: 999999,
  planFile: resumePlanPath
});
appendSessionEvent(workspaceRoot, "session-stale", "code_deliberation_round_started", "info", {
  round: 2,
  maxRounds: 4
});

const staleResumeConfig = getResumeRunConfig(workspaceRoot, "session-stale");
assert(staleResumeConfig.ok === true, "Expected stale deliberation session to be resumable.");
assert(staleResumeConfig.config.qcType === "code", "Expected stale resume to keep code qcType.");

fs.mkdirSync(path.join(logsRoot, "session-live"), { recursive: true });
fs.writeFileSync(
  path.join(logsRoot, "session-live", "run_state.json"),
  `${JSON.stringify({
    schemaVersion: 1,
    sessionId: "session-live",
    pipelineId: "2026-03-18_23-27-27",
    status: "failed",
    phase: "document_deliberation",
    currentDeliberationRound: 2,
    updatedAt: "2026-03-18T23:31:05.579Z",
    completedAt: "2026-03-18T23:31:05.579Z",
    planFile: resumePlanPath
  }, null, 2)}\n`,
  "utf8"
);
fs.writeFileSync(
  path.join(logsRoot, "session-live", "events.ndjson"),
  [
    {
      timestamp: "2026-03-18T23:31:05.579Z",
      sessionId: "session-live",
      pipelineId: "2026-03-18_23-27-27",
      type: "pipeline_failed",
      level: "error",
      phase: "document_deliberation",
      status: "failed",
      currentDeliberationRound: 2,
      data: { message: "Document deliberation failed." }
    },
    {
      timestamp: "2026-03-18T23:34:13.887Z",
      sessionId: "session-live",
      pipelineId: "2026-03-18_23-34-13",
      type: "pipeline_started",
      level: "info",
      phase: "startup",
      status: "running",
      currentDeliberationRound: 0,
      data: { message: "Pipeline started (document mode, deliberation)", planFile: resumePlanPath, qcType: "document", deliberationMode: true }
    },
    {
      timestamp: "2026-03-18T23:41:45.914Z",
      sessionId: "session-live",
      pipelineId: "2026-03-18_23-34-13",
      type: "document_deliberation_round_started",
      level: "info",
      phase: "document_deliberation",
      status: "running",
      currentDeliberationRound: 3,
      data: { message: "Deliberation round 3 of 4", round: 3, resumed: true }
    }
  ].map((entry) => JSON.stringify(entry)).join("\n") + "\n",
  "utf8"
);

const liveSession = getSession(workspaceRoot, "session-live");
assert(liveSession.status === "running", `Expected latest session attempt to be running, got ${liveSession.status}`);
assert(liveSession.phase === "document_deliberation", `Expected live phase from newest events, got ${liveSession.phase}`);
assert(liveSession.currentDeliberationRound === 3, `Expected round 3 from newest events, got ${liveSession.currentDeliberationRound}`);
assert(liveSession.updatedAt === "2026-03-18T23:41:45.914Z", `Expected updatedAt from newest running event, got ${liveSession.updatedAt}`);

fs.mkdirSync(path.join(logsRoot, "session-live-no-state"), { recursive: true });
fs.writeFileSync(
  path.join(logsRoot, "session-live-no-state", "events.ndjson"),
  [
    {
      timestamp: "2026-03-18T23:31:05.579Z",
      sessionId: "session-live-no-state",
      pipelineId: "2026-03-18_23-27-27",
      type: "pipeline_failed",
      level: "error",
      phase: "document_deliberation",
      status: "failed",
      currentDeliberationRound: 2,
      data: { message: "Document deliberation failed." }
    },
    {
      timestamp: "2026-03-18T23:34:13.887Z",
      sessionId: "session-live-no-state",
      pipelineId: "2026-03-18_23-34-13",
      type: "pipeline_started",
      level: "info",
      phase: "startup",
      status: "running",
      currentDeliberationRound: 0,
      data: { message: "Pipeline started (document mode, deliberation)", planFile: resumePlanPath, qcType: "document", deliberationMode: true }
    },
    {
      timestamp: "2026-03-18T23:41:45.914Z",
      sessionId: "session-live-no-state",
      pipelineId: "2026-03-18_23-34-13",
      type: "document_deliberation_round_started",
      level: "info",
      phase: "document_deliberation",
      status: "running",
      currentDeliberationRound: 3,
      data: { message: "Deliberation round 3 of 4", round: 3, resumed: true }
    }
  ].map((entry) => JSON.stringify(entry)).join("\n") + "\n",
  "utf8"
);

const liveNoStateSession = getSession(workspaceRoot, "session-live-no-state");
assert(liveNoStateSession.status === "running", `Expected event fallback to show running, got ${liveNoStateSession.status}`);
assert(liveNoStateSession.updatedAt === "2026-03-18T23:41:45.914Z", `Expected event fallback updatedAt, got ${liveNoStateSession.updatedAt}`);

const stalledHintSessionId = "session-stalled-hint";
const stalledHintLogsDir = path.join(logsRoot, stalledHintSessionId);
const stalledHintPhaseDir = path.join(stalledHintLogsDir, "deliberation", "phase0");
fs.mkdirSync(stalledHintPhaseDir, { recursive: true });
writeSessionConfig(workspaceRoot, stalledHintSessionId, {
  workspaceDir: workspaceRoot,
  promptDir: path.join(workspaceRoot, "prompts"),
  planFile: resumePlanPath,
  qcType: "document",
  deliberationMode: true,
  maxDeliberationRounds: 4,
  reasoningEffort: "xhigh",
  agentTimeoutSec: 900
});
fs.writeFileSync(
  path.join(stalledHintLogsDir, "run_state.json"),
  `${JSON.stringify({
    schemaVersion: 1,
    sessionId: stalledHintSessionId,
    pipelineId: "2020-01-01_23-48-33",
    status: "running",
    phase: "document_deliberation",
    currentAction: "codex_document_deliberation_review",
    currentTool: "codex",
    currentDeliberationRound: 1,
    childPid: process.pid,
    updatedAt: "2020-01-01T23:57:37.000Z",
    startedAt: "2020-01-01T23:48:34.000Z",
    planFile: resumePlanPath,
    agentTimeoutSec: 900
  }, null, 2)}\n`,
  "utf8"
);
fs.writeFileSync(
  path.join(stalledHintLogsDir, "events.ndjson"),
  [
    {
      timestamp: "2020-01-01T23:48:34.000Z",
      sessionId: stalledHintSessionId,
      pipelineId: "2020-01-01_23-48-33",
      type: "pipeline_started",
      level: "info",
      phase: "startup",
      status: "running",
      currentDeliberationRound: 0,
      data: {
        message: "Pipeline started (document mode, deliberation)",
        planFile: resumePlanPath,
        qcType: "document",
        deliberationMode: true,
        agentTimeoutSec: 900
      }
    },
    {
      timestamp: "2020-01-01T23:57:37.000Z",
      sessionId: stalledHintSessionId,
      pipelineId: "2020-01-01_23-48-33",
      type: "document_deliberation_round_started",
      level: "info",
      phase: "document_deliberation",
      status: "running",
      currentDeliberationRound: 1,
      data: {
        message: "Document deliberation round 1 of 4",
        round: 1
      }
    }
  ].map((entry) => JSON.stringify(entry)).join("\n") + "\n",
  "utf8"
);
const stalledTempPath = path.join(stalledHintPhaseDir, ".round1_codex_evaluation_last_message.tmp");
fs.writeFileSync(stalledTempPath, "## Decision: MAJOR_REFINEMENT\n\n- Salvaged from temp.\n", "utf8");
const stalledTempDate = new Date("2020-01-02T00:05:05.000Z");
fs.utimesSync(stalledTempPath, stalledTempDate, stalledTempDate);
const stalledHintSession = getSession(workspaceRoot, stalledHintSessionId);
assert(stalledHintSession.status === "running", `Expected stalled-hint session to remain running, got ${stalledHintSession.status}`);
assert(stalledHintSession.isStalled === true, "Expected stalled-hint session to expose a stalled warning.");
assert(stalledHintSession.lastActivityAt === "2020-01-02T00:05:05.000Z", `Expected lastActivityAt from pending temp output, got ${stalledHintSession.lastActivityAt}`);
assert(stalledHintSession.stallReason.includes("codex_document_deliberation_review"), `Expected stall reason to mention current action, got ${stalledHintSession.stallReason}`);
assert(stalledHintSession.pendingDeliberationTempArtifactCount === 1, `Expected one pending temp artifact, got ${stalledHintSession.pendingDeliberationTempArtifactCount}`);
assert(stalledHintSession.pendingArtifactCount === 1, `Expected stalled session to surface one pending artifact, got ${stalledHintSession.pendingArtifactCount}`);
assert(stalledHintSession.pendingArtifacts.some((entry) => entry.path === path.join(stalledHintPhaseDir, "round1_codex_evaluation.md") && entry.source === "deliberation temp"), "Expected stalled session pending artifacts to expose the deliberation target output.");
assert(!stalledHintSession.artifacts.some((entry) => entry.name === ".round1_codex_evaluation_last_message.tmp"), "Expected pending temp artifact to stay out of the normal artifact list.");
assert(stalledHintSession.canResume === false, "Expected running stalled session not to be resumable before cancellation.");
assert(stalledHintSession.processInfo?.state === "stalled", `Expected stalled session process state stalled, got ${stalledHintSession.processInfo?.state}`);
assert(stalledHintSession.processInfo?.alive === true, "Expected stalled session process to remain alive.");

const staleSessionSummary = getSession(workspaceRoot, "session-stale");
assert(staleSessionSummary.status === "stale", `Expected dead-child running session to resolve as stale, got ${staleSessionSummary.status}`);
assert(staleSessionSummary.isStalled === false, "Expected stale session not to expose the running-stalled hint.");
assert(staleSessionSummary.processInfo?.state === "dead", `Expected stale session process state dead, got ${staleSessionSummary.processInfo?.state}`);
assert(staleSessionSummary.processInfo?.alive === false, "Expected stale session process not to be alive.");

const processQueryFailureSessionId = "session-process-query-failure";
const processQueryFailureLogsDir = path.join(logsRoot, processQueryFailureSessionId);
fs.mkdirSync(processQueryFailureLogsDir, { recursive: true });
writeSessionState(workspaceRoot, processQueryFailureSessionId, {
  status: "running",
  phase: "document_qc",
  currentAction: "qc_iteration",
  currentTool: "codex",
  childPid: process.pid,
  updatedAt: new Date().toISOString(),
  startedAt: new Date(Date.now() - 60 * 1000).toISOString(),
  planFile: path.join(workspaceRoot, "plan.md")
});
const processQueryFailureSession = withEnv("CROSS_QC_PROCESS_QUERY_FAIL", "1", () =>
  getSession(workspaceRoot, processQueryFailureSessionId)
);
assert(processQueryFailureSession.processInfo?.state === "active", `Expected process query failure not to change state derivation, got ${processQueryFailureSession.processInfo?.state}`);
assert(Array.isArray(processQueryFailureSession.processInfo?.children), "Expected process query failure to still expose a children array.");
assert(processQueryFailureSession.processInfo?.children.length === 0, `Expected process query failure to return no children, got ${processQueryFailureSession.processInfo?.children.length}`);

const terminalProcessSessionId = "session-terminal-live-pid";
const terminalProcessLogsDir = path.join(logsRoot, terminalProcessSessionId);
fs.mkdirSync(terminalProcessLogsDir, { recursive: true });
writeSessionState(workspaceRoot, terminalProcessSessionId, {
  status: "completed",
  phase: "document_qc",
  currentAction: "",
  currentTool: "",
  childPid: process.pid,
  updatedAt: new Date().toISOString(),
  completedAt: new Date().toISOString(),
  startedAt: new Date(Date.now() - 90 * 1000).toISOString(),
  planFile: path.join(workspaceRoot, "plan.md")
});
const terminalProcessSession = getSession(workspaceRoot, terminalProcessSessionId);
assert(terminalProcessSession.processInfo?.state === "dead", `Expected terminal session process state dead, got ${terminalProcessSession.processInfo?.state}`);
assert(terminalProcessSession.processInfo?.alive === false, "Expected terminal session process not to report alive state.");
assert(Array.isArray(terminalProcessSession.processInfo?.children), "Expected terminal session children array.");
assert(terminalProcessSession.processInfo?.children.length === 0, `Expected terminal session not to enumerate live descendants, got ${terminalProcessSession.processInfo?.children.length}`);

const relayProcess = spawn(
  "powershell.exe",
  [
    "-NoProfile",
    "-Command",
    "$child = Start-Process -FilePath cmd.exe -ArgumentList '/c ping -n 60 127.0.0.1 > nul' -PassThru -WindowStyle Hidden; Wait-Process -Id $child.Id"
  ],
  {
    windowsHide: true,
    stdio: "ignore"
  }
);
await new Promise((resolve) => setTimeout(resolve, 1200));
const stuckMetaReviewSessionId = "session-stuck-meta-review";
const stuckMetaReviewLogsDir = path.join(logsRoot, stuckMetaReviewSessionId);
fs.mkdirSync(stuckMetaReviewLogsDir, { recursive: true });
writeSessionState(workspaceRoot, stuckMetaReviewSessionId, {
  status: "running",
  phase: "document_qc",
  currentAction: "meta_review_relay_qc",
  currentTool: "codex",
  currentIteration: 3,
  childPid: relayProcess.pid,
  startedAt: "2026-03-21T07:30:53.000Z",
  planFile: metaReviewTargetPath
});
const stuckMetaReviewRunStatePath = path.join(stuckMetaReviewLogsDir, "run_state.json");
const stuckMetaReviewRunState = readJsonFile(stuckMetaReviewRunStatePath);
stuckMetaReviewRunState.updatedAt = "2026-03-21T07:38:50.238Z";
fs.writeFileSync(stuckMetaReviewRunStatePath, `${JSON.stringify(stuckMetaReviewRunState, null, 2)}\n`, "utf8");
const stuckMetaReviewSession = getSession(workspaceRoot, stuckMetaReviewSessionId);
assert(stuckMetaReviewSession.status === "running", `Expected stuck meta-review session to remain running, got ${stuckMetaReviewSession.status}`);
assert(stuckMetaReviewSession.isStalled === true, "Expected stuck meta-review session to be stalled.");
assert(stuckMetaReviewSession.processInfo?.state === "stalled", `Expected stuck meta-review process state stalled, got ${stuckMetaReviewSession.processInfo?.state}`);
assert(stuckMetaReviewSession.processInfo?.alive === true, "Expected stuck meta-review process to remain alive.");
assert(stuckMetaReviewSession.processInfo?.currentAction === "meta_review_relay_qc", `Expected stuck meta-review current action, got ${stuckMetaReviewSession.processInfo?.currentAction}`);
assert(stuckMetaReviewSession.processInfo?.children.some((child) => child.name.toLowerCase() === "cmd.exe"), "Expected stuck meta-review process children to include cmd.exe.");
spawnSync("taskkill.exe", ["/PID", String(relayProcess.pid), "/T", "/F"], {
  windowsHide: true,
  encoding: "utf8"
});

const cancelSessionId = "session-cancel";
const cancelLogsDir = path.join(logsRoot, cancelSessionId);
const cancelCyclesDir = path.join(cyclesRoot, cancelSessionId);
fs.mkdirSync(cancelLogsDir, { recursive: true });
fs.mkdirSync(cancelCyclesDir, { recursive: true });
const cancelLogFile = path.join(cancelLogsDir, "qc_log_2026-03-19_16-20-00.txt");
fs.writeFileSync(cancelLogFile, "[2026-03-19 16:20:00] [INFO] Pipeline started\n", "utf8");
writeSessionState(workspaceRoot, cancelSessionId, {
  status: "running",
  phase: "document_deliberation",
  currentAction: "deliberation_round",
  currentTool: "claude",
  currentIteration: 3,
  currentPlanQCIteration: 1,
  currentDeliberationRound: 2,
  pipelineId: "2026-03-19_16-20-00",
  startedAt: "2026-03-19T16:20:00.000Z",
  updatedAt: "2026-03-19T16:20:30.000Z",
  planFile: resumePlanPath,
  logFile: cancelLogFile,
  currentQCReport: path.join(cancelLogsDir, "qc_report_iter3.md"),
  currentArtifact: path.join(cancelLogsDir, "qc_report_iter3.md")
});
appendSessionEvent(workspaceRoot, cancelSessionId, "pipeline_started", "info", {
  message: "Pipeline started.",
  planFile: resumePlanPath
}, {
  timestamp: "2026-03-19T16:20:00.000Z",
  fields: {
    pipelineId: "2026-03-19_16-20-00",
    phase: "startup",
    status: "running",
    currentIteration: 0,
    currentPlanQCIteration: 0,
    currentDeliberationRound: 0
  }
});
const cancelResult = finalizeCancelledRun({
  workspaceDir: workspaceRoot,
  sessionId: cancelSessionId,
  pid: 46984,
  activeRun: {
    sessionLogsDir: cancelLogsDir,
    sessionCyclesDir: cancelCyclesDir,
    pipelineStartTime: "2026-03-19_16-20-00",
    promptDir: path.join(workspaceRoot, "prompts"),
    planFile: resumePlanPath,
    child: { pid: 46984 }
  },
  timestamp: "2026-03-19T16:21:09.627Z"
});
assert(cancelResult.nextState.status === "cancelled", `Expected cancelled status, got ${cancelResult.nextState.status}`);
assert(cancelResult.nextState.startedAt === "2026-03-19T16:20:00.000Z", `Expected startedAt to be preserved, got ${cancelResult.nextState.startedAt}`);
assert(cancelResult.nextState.completedAt === "2026-03-19T16:21:09.627Z", `Expected completedAt to use cancel timestamp, got ${cancelResult.nextState.completedAt}`);
assert(cancelResult.nextState.updatedAt === "2026-03-19T16:21:09.627Z", `Expected updatedAt to use cancel timestamp, got ${cancelResult.nextState.updatedAt}`);
assert(cancelResult.nextState.currentDeliberationRound === 2, `Expected round preservation on cancel, got ${cancelResult.nextState.currentDeliberationRound}`);
assert(cancelResult.logFile === cancelLogFile, `Expected cancel log path to reuse active log file, got ${cancelResult.logFile}`);
const cancelSession = getSession(workspaceRoot, cancelSessionId);
const cancelEvent = cancelSession.recentEvents[cancelSession.recentEvents.length - 1];
assert(cancelEvent.type === "pipeline_cancelled", `Expected pipeline_cancelled event, got ${cancelEvent.type}`);
assert(cancelEvent.status === "cancelled", `Expected cancelled event status, got ${cancelEvent.status}`);
assert(cancelEvent.phase === "document_deliberation", `Expected cancelled event phase, got ${cancelEvent.phase}`);
assert(cancelEvent.currentIteration === 3, `Expected cancelled event iteration, got ${cancelEvent.currentIteration}`);
assert(cancelEvent.currentPlanQCIteration === 1, `Expected cancelled event plan QC iteration, got ${cancelEvent.currentPlanQCIteration}`);
assert(cancelEvent.currentDeliberationRound === 2, `Expected cancelled event round, got ${cancelEvent.currentDeliberationRound}`);
assert(cancelEvent.data?.message === "Run cancelled from the desktop UI.", `Expected cancelled event message, got ${cancelEvent.data?.message}`);
assert(cancelEvent.data?.source === "electron", `Expected cancelled event source electron, got ${cancelEvent.data?.source}`);
assert(cancelEvent.data?.pid === 46984, `Expected cancelled event pid, got ${cancelEvent.data?.pid}`);
const cancelLogContent = fs.readFileSync(cancelLogFile, "utf8");
assert(cancelLogContent.includes("[WARN] Run cancelled from the desktop UI. PID: 46984"), "Expected cancel warning line in qc_log.");

const cancelBrokenSessionId = "session-cancel-broken";
const cancelBrokenLogsDir = path.join(logsRoot, cancelBrokenSessionId);
const cancelBrokenCyclesDir = path.join(cyclesRoot, cancelBrokenSessionId);
fs.mkdirSync(cancelBrokenLogsDir, { recursive: true });
fs.mkdirSync(cancelBrokenCyclesDir, { recursive: true });
fs.writeFileSync(path.join(cancelBrokenLogsDir, "run_state.json"), "{not-valid-json", "utf8");
const cancelBrokenResult = finalizeCancelledRun({
  workspaceDir: workspaceRoot,
  sessionId: cancelBrokenSessionId,
  pid: 48123,
  activeRun: {
    sessionLogsDir: cancelBrokenLogsDir,
    sessionCyclesDir: cancelBrokenCyclesDir,
    pipelineStartTime: "2026-03-19_16-30-00",
    promptDir: path.join(workspaceRoot, "prompts"),
    planFile: resumePlanPath,
    child: { pid: 48123 }
  },
  timestamp: "2026-03-19T16:31:00.000Z"
});
assert(cancelBrokenResult.nextState.status === "cancelled", `Expected broken-state cancel to still mark cancelled, got ${cancelBrokenResult.nextState.status}`);
assert(!Object.prototype.hasOwnProperty.call(cancelBrokenResult.nextState, "startedAt"), "Expected broken-state cancel not to invent startedAt.");
assert(cancelBrokenResult.nextState.updatedAt === "2026-03-19T16:31:00.000Z", `Expected broken-state updatedAt to use cancel timestamp, got ${cancelBrokenResult.nextState.updatedAt}`);
assert(cancelBrokenResult.nextState.completedAt === "2026-03-19T16:31:00.000Z", `Expected broken-state completedAt to use cancel timestamp, got ${cancelBrokenResult.nextState.completedAt}`);
const cancelBrokenSession = getSession(workspaceRoot, cancelBrokenSessionId);
const cancelBrokenEvent = cancelBrokenSession.recentEvents[cancelBrokenSession.recentEvents.length - 1];
assert(cancelBrokenEvent.type === "pipeline_cancelled", `Expected broken-state pipeline_cancelled event, got ${cancelBrokenEvent.type}`);
assert(cancelBrokenEvent.status === "cancelled", `Expected broken-state cancelled event status, got ${cancelBrokenEvent.status}`);
const cancelBrokenLogPath = path.join(cancelBrokenLogsDir, "qc_log_2026-03-19_16-30-00.txt");
assert(fs.existsSync(cancelBrokenLogPath), "Expected missing qc_log to be created during cancel finalization.");
assert(fs.readFileSync(cancelBrokenLogPath, "utf8").includes("[WARN] Run cancelled from the desktop UI. PID: 48123"), "Expected cancel line in created qc_log file.");

const cancelSalvageSessionId = "session-cancel-salvage";
const cancelSalvageLogsDir = path.join(logsRoot, cancelSalvageSessionId);
const cancelSalvageCyclesDir = path.join(cyclesRoot, cancelSalvageSessionId);
const cancelSalvagePhaseDir = path.join(cancelSalvageLogsDir, "deliberation", "phase0");
fs.mkdirSync(cancelSalvagePhaseDir, { recursive: true });
fs.mkdirSync(cancelSalvageCyclesDir, { recursive: true });
const cancelSalvageLogFile = path.join(cancelSalvageLogsDir, "qc_log_2026-03-20_07-20-00.txt");
fs.writeFileSync(cancelSalvageLogFile, "[2026-03-20 07:20:00] [INFO] Pipeline started\n", "utf8");
writeSessionConfig(workspaceRoot, cancelSalvageSessionId, {
  workspaceDir: workspaceRoot,
  promptDir: path.join(workspaceRoot, "prompts"),
  planFile: resumePlanPath,
  qcType: "document",
  deliberationMode: true,
  maxDeliberationRounds: 4,
  agentTimeoutSec: 900
});
writeSessionState(workspaceRoot, cancelSalvageSessionId, {
  status: "running",
  phase: "document_deliberation",
  currentAction: "codex_document_deliberation_review",
  currentTool: "codex",
  currentDeliberationRound: 1,
  pipelineId: "2026-03-20_07-20-00",
  startedAt: "2026-03-20T07:20:00.000Z",
  updatedAt: "2026-03-20T07:27:00.000Z",
  childPid: 51515,
  planFile: resumePlanPath,
  logFile: cancelSalvageLogFile,
  agentTimeoutSec: 900
});
appendSessionEvent(workspaceRoot, cancelSalvageSessionId, "pipeline_started", "info", {
  message: "Pipeline started.",
  planFile: resumePlanPath,
  deliberationMode: true,
  agentTimeoutSec: 900
}, {
  timestamp: "2026-03-20T07:20:00.000Z",
  fields: {
    pipelineId: "2026-03-20_07-20-00",
    phase: "startup",
    status: "running",
    currentIteration: 0,
    currentPlanQCIteration: 0,
    currentDeliberationRound: 0
  }
});
const cancelSalvageTempPath = path.join(cancelSalvagePhaseDir, ".round1_codex_evaluation_last_message.tmp");
fs.writeFileSync(cancelSalvageTempPath, "## Decision: MAJOR_REFINEMENT\n\n- Salvaged from cancel.\n", "utf8");
const cancelSalvageResult = finalizeCancelledRun({
  workspaceDir: workspaceRoot,
  sessionId: cancelSalvageSessionId,
  pid: 51515,
  activeRun: {
    sessionLogsDir: cancelSalvageLogsDir,
    sessionCyclesDir: cancelSalvageCyclesDir,
    pipelineStartTime: "2026-03-20_07-20-00",
    promptDir: path.join(workspaceRoot, "prompts"),
    planFile: resumePlanPath,
    child: { pid: 51515 }
  },
  timestamp: "2026-03-20T07:28:00.000Z"
});
const cancelSalvageArtifactPath = path.join(cancelSalvagePhaseDir, "round1_codex_evaluation.md");
assert(cancelSalvageResult.nextState.status === "cancelled", `Expected salvaged cancel session to be cancelled, got ${cancelSalvageResult.nextState.status}`);
assert(cancelSalvageResult.salvagedArtifacts.length === 1, `Expected one salvaged artifact during cancel, got ${cancelSalvageResult.salvagedArtifacts.length}`);
assert(fs.existsSync(cancelSalvageArtifactPath), "Expected cancel finalization to materialize the official deliberation artifact.");
assert(!fs.existsSync(cancelSalvageTempPath), "Expected pending temp file to be removed after salvage.");
const cancelSalvageSession = getSession(workspaceRoot, cancelSalvageSessionId);
const salvageEvent = cancelSalvageSession.recentEvents.find((event) => event.type === "deliberation_temp_output_salvaged");
assert(Boolean(salvageEvent), "Expected cancel finalization to append a deliberation_temp_output_salvaged event.");
assert(salvageEvent?.data?.count === 1, `Expected salvage event count 1, got ${salvageEvent?.data?.count}`);
const cancelSalvageResumeConfig = getResumeRunConfig(workspaceRoot, cancelSalvageSessionId);
assert(cancelSalvageResumeConfig.ok === true, "Expected cancelled salvaged session to be resumable.");
assert(cancelSalvageResumeConfig.config.resumeFromFailure === true, "Expected cancelled salvaged session to resume as a deliberation failure.");

const historicalCancelSessionId = "session-cancel-historical";
const historicalCancelLogsDir = path.join(logsRoot, historicalCancelSessionId);
const historicalCancelCyclesDir = path.join(cyclesRoot, historicalCancelSessionId);
fs.mkdirSync(historicalCancelLogsDir, { recursive: true });
fs.mkdirSync(historicalCancelCyclesDir, { recursive: true });
const historicalCancelLogFile = path.join(historicalCancelLogsDir, "qc_log_2026-03-19_16-20-00.txt");
fs.writeFileSync(historicalCancelLogFile, "[2026-03-19 16:20:00] [INFO] Pipeline started\n", "utf8");
fs.writeFileSync(
  path.join(historicalCancelLogsDir, "run_state.json"),
  `${JSON.stringify({
    schemaVersion: 1,
    sessionId: historicalCancelSessionId,
    status: "cancelled",
    startedAt: "2026-03-19T16:20:00.000Z",
    completedAt: "2026-03-19T16:21:09.621Z",
    currentAction: "",
    currentTool: "",
    exitCode: 1,
    lastError: "Run cancelled from the desktop UI.",
    updatedAt: "2026-03-19T16:21:09.623Z",
    logFile: historicalCancelLogFile
  }, null, 2)}\n`,
  "utf8"
);
fs.writeFileSync(
  path.join(historicalCancelLogsDir, "events.ndjson"),
  [
    {
      timestamp: "2026-03-19T16:20:00.000Z",
      sessionId: historicalCancelSessionId,
      type: "pipeline_started",
      level: "info",
      phase: "startup",
      status: "running",
      currentIteration: 0,
      currentPlanQCIteration: 0,
      currentDeliberationRound: 0,
      data: {
        message: "Pipeline started.",
        planFile: resumePlanPath
      }
    },
    {
      timestamp: "2026-03-19T16:20:30.000Z",
      sessionId: historicalCancelSessionId,
      type: "document_deliberation_round_started",
      level: "info",
      phase: "document_deliberation",
      status: "running",
      currentIteration: 3,
      currentPlanQCIteration: 1,
      currentDeliberationRound: 2,
      data: {
        message: "Deliberation round 2 of 4",
        round: 2,
        resumed: false
      }
    },
    {
      timestamp: "2026-03-19T16:21:09.627Z",
      sessionId: historicalCancelSessionId,
      type: "pipeline_cancelled",
      level: "warn",
      data: {
        pid: 46984
      }
    }
  ].map((entry) => JSON.stringify(entry)).join("\n") + "\n",
  "utf8"
);
const historicalCancelSession = getSession(workspaceRoot, historicalCancelSessionId);
assert(historicalCancelSession.status === "cancelled", `Expected historical cancelled session to stay cancelled, got ${historicalCancelSession.status}`);
assert(historicalCancelSession.phase === "document_deliberation", `Expected historical cancelled phase to come from last state event, got ${historicalCancelSession.phase}`);
assert(historicalCancelSession.currentIteration === 3, `Expected historical cancelled iteration to be preserved, got ${historicalCancelSession.currentIteration}`);
assert(historicalCancelSession.currentPlanQCIteration === 1, `Expected historical cancelled plan QC iteration to be preserved, got ${historicalCancelSession.currentPlanQCIteration}`);
assert(historicalCancelSession.currentDeliberationRound === 2, `Expected historical cancelled round to be preserved, got ${historicalCancelSession.currentDeliberationRound}`);
assert(historicalCancelSession.completedAt === "2026-03-19T16:21:09.627Z", `Expected historical completedAt to come from sparse terminal event, got ${historicalCancelSession.completedAt}`);
const historicalCancelDecision = resolveCancelRequest({
  activeRun: null,
  requestedPid: undefined,
  session: historicalCancelSession
});
assert(historicalCancelDecision.pid === 0, `Expected no pid for historical cancelled session, got ${historicalCancelDecision.pid}`);
assert(historicalCancelDecision.alreadyTerminal === true, "Expected historical cancelled session to no-op cancel requests.");
assert(!fs.readFileSync(historicalCancelLogFile, "utf8").includes("[WARN] Run cancelled from the desktop UI."), "Expected historical qc_log to remain unchanged during read-time compatibility handling.");

const manualHistoryWorkspace = workspaceRoot;
const metaHistoryWorkspace = path.join(workspaceRoot, "workspace-meta");
const firstHistory = rememberProjectHistory({
  workspaceDir: manualHistoryWorkspace,
  promptDir: path.join(manualHistoryWorkspace, "prompts"),
  planFile: resumePlanPath,
  qcType: "document",
  deliberationMode: true,
  maxDeliberationRounds: 4
}, {
  sessionId: "session-resume",
  planTitle: "Resume Plan",
  status: "failed",
  updatedAt: "2026-03-19T10:00:00.000Z"
});
assert(firstHistory.length === 1, `Expected one project history entry, got ${firstHistory.length}`);
assert(firstHistory[0].config.qcType === "document", `Expected stored history qcType document, got ${firstHistory[0].config.qcType}`);
assert(firstHistory[0].lastRunMetaReview === false, "Expected normal history entry not to be marked as meta review.");

const metaHistoryPlanPath = path.join(metaHistoryWorkspace, "meta_plan.md");
const metaHistoryOutputPath = getReviewedMetaPlanOutputPath(metaHistoryPlanPath);
fs.mkdirSync(metaHistoryWorkspace, { recursive: true });
fs.writeFileSync(metaHistoryPlanPath, "# Meta-Plan: History\n", "utf8");
const metaHistory = rememberProjectHistory({
  workspaceDir: metaHistoryWorkspace,
  promptDir: path.join(metaHistoryWorkspace, "prompts"),
  planFile: metaHistoryPlanPath,
  qcType: "document",
  skipPlanQC: true,
  deliberationMode: false,
  reasoningEffort: "xhigh",
  metaReview: true,
  metaReviewTargetFile: metaHistoryPlanPath,
  metaReviewChecklistFile: metaPlanChecklistPath,
  metaReviewOutputFile: metaHistoryOutputPath
}, {
  sessionId: "session-meta-history",
  planTitle: "Meta History",
  updatedAt: "2026-03-19T11:00:00.000Z"
});
const metaHistoryEntry = metaHistory.find((entry) => entry.workspaceDir === metaHistoryWorkspace);
assert(Boolean(metaHistoryEntry), "Expected stored meta-review history entry.");
assert(metaHistoryEntry?.lastRunMetaReview === true, "Expected meta-review history entry to be marked.");
assert(metaHistoryEntry?.config.skipPlanQC === false, "Expected meta-review history entry to reset Skip Plan QC.");
assert(metaHistoryEntry?.config.deliberationMode === false, "Expected meta-review history entry to keep deliberation disabled.");
assert(!Object.hasOwn(metaHistoryEntry?.config || {}, "metaReview"), "Expected reusable history config not to expose metaReview.");

const updatedHistory = rememberProjectHistory({
  workspaceDir: manualHistoryWorkspace,
  promptDir: path.join(manualHistoryWorkspace, "prompts-v2"),
  planFile: resumePlanPath,
  qcType: "code",
  maxIterations: 9,
  skipPlanQC: true
}, {
  sessionId: "session-new",
  planTitle: "Resume Plan v2",
  status: "running",
  updatedAt: "2026-03-19T12:00:00.000Z"
});
assert(updatedHistory.length === 2, `Expected deduped history entries, got ${updatedHistory.length}`);
assert(updatedHistory[0].workspaceDir === manualHistoryWorkspace, "Expected latest workspace to sort first.");
assert(updatedHistory[0].sessionId === "session-new", `Expected latest session id for workspaceRoot, got ${updatedHistory[0].sessionId}`);
assert(updatedHistory[0].config.promptDir.endsWith("prompts-v2"), `Expected latest config to overwrite prompt dir, got ${updatedHistory[0].config.promptDir}`);
assert(updatedHistory[0].config.skipPlanQC === true, "Expected manual Skip Plan QC choice to remain persisted.");
assert(updatedHistory[0].lastRunMetaReview === false, "Expected manual history entry not to be marked as meta review.");
assert(updatedHistory[1].workspaceDir === metaHistoryWorkspace, "Expected meta-review workspace to remain in history.");
assert(listProjectHistory().length === 2, `Expected persisted history readback, got ${listProjectHistory().length}`);

const legacyHistoryStorePath = path.join(workspaceRoot, "legacy-project-history.json");
const legacyWorkspace = path.join(workspaceRoot, "legacy-meta-workspace");
const legacyPlanPath = path.join(legacyWorkspace, "meta_plan.md");
const legacyOutputPath = getReviewedMetaPlanOutputPath(legacyPlanPath);
setProjectHistoryStorePath(legacyHistoryStorePath);
fs.mkdirSync(legacyWorkspace, { recursive: true });
fs.writeFileSync(legacyPlanPath, "# Meta-Plan: Legacy\n", "utf8");
writeSessionConfig(legacyWorkspace, "session-legacy-meta", {
  workspaceDir: legacyWorkspace,
  promptDir: path.join(legacyWorkspace, "prompts"),
  planFile: legacyPlanPath,
  qcType: "document",
  skipPlanQC: true,
  deliberationMode: false,
  metaReview: true,
  metaReviewTargetFile: legacyPlanPath,
  metaReviewChecklistFile: metaPlanChecklistPath,
  metaReviewOutputFile: legacyOutputPath
});
fs.writeFileSync(legacyHistoryStorePath, `${JSON.stringify([
  {
    workspaceDir: legacyWorkspace,
    sessionId: "session-legacy-meta",
    planTitle: "Legacy Meta",
    status: "completed",
    updatedAt: "2026-03-19T13:00:00.000Z",
    config: {
      workspaceDir: legacyWorkspace,
      promptDir: path.join(legacyWorkspace, "prompts"),
      planFile: legacyPlanPath,
      qcType: "document",
      skipPlanQC: true,
      deliberationMode: false
    }
  }
], null, 2)}\n`, "utf8");
const legacyHistory = listProjectHistory();
assert(legacyHistory.length === 1, `Expected one legacy history entry, got ${legacyHistory.length}`);
assert(legacyHistory[0].lastRunMetaReview === true, "Expected legacy meta-review entry to infer meta-review marker from session config.");
assert(legacyHistory[0].config.skipPlanQC === false, "Expected legacy meta-review entry to sanitize Skip Plan QC.");
assert(legacyHistory[0].config.deliberationMode === false, "Expected legacy meta-review entry to preserve deliberation off.");

const metaReviewFixPromptSource = fs.readFileSync(path.resolve("prompts/claude_fix_meta_review_prompt.md"), "utf8");
assert(metaReviewFixPromptSource.includes("copy that literal text verbatim"), "Expected meta-review fix prompt to require verbatim literal compliance.");
assert(metaReviewFixPromptSource.includes("Requirements, Output Structure Template, and Deliverables"), "Expected meta-review fix prompt to require branch updates across all relevant sections.");
assert(metaReviewFixPromptSource.includes("`Do not generate a new cycle plan`"), "Expected meta-review fix prompt to include the canonical in-progress hard-stop literal.");
assert(metaReviewFixPromptSource.includes("Do NOT request write approval"), "Expected meta-review fix prompt to forbid write-approval requests.");
assert(metaReviewFixPromptSource.includes("all always-required sections"), "Expected meta-review fix prompt to require canonical conditional-section wording.");
assert(metaReviewFixPromptSource.includes("only `[NN]`, `[NN-1]`, `[NN+1]`, `[NNr]`, and `[Cycle Title]` may remain bracketed"), "Expected meta-review fix prompt to restrict bracketed template tokens.");

const metaReviewWritePromptSource = fs.readFileSync(path.resolve("prompts/claude_write_meta_review_prompt.md"), "utf8");
assert(metaReviewWritePromptSource.includes("preserve those exact strings"), "Expected meta-review write prompt to require exact literal preservation.");
assert(metaReviewWritePromptSource.includes("`RESUME_CYCLE_[NN].md`"), "Expected meta-review write prompt to include the canonical resume-plan literal.");
assert(metaReviewWritePromptSource.includes("Requirements, Output Structure Template, and Deliverables together"), "Expected meta-review write prompt to require branch updates across requirements, template, and deliverables.");
assert(metaReviewWritePromptSource.includes("Do NOT request write approval"), "Expected meta-review write prompt to forbid write-approval requests.");
assert(metaReviewWritePromptSource.includes("all always-required sections"), "Expected meta-review write prompt to require canonical conditional-section wording.");
assert(metaReviewWritePromptSource.includes("only `[NN]`, `[NN-1]`, `[NN+1]`, `[NNr]`, and `[Cycle Title]` may remain bracketed"), "Expected meta-review write prompt to restrict bracketed template tokens.");

const metaReviewReconcilePromptSource = fs.readFileSync(path.resolve("prompts/claude_reconcile_meta_review_prompt.md"), "utf8");
assert(metaReviewReconcilePromptSource.includes("Do NOT request write approval"), "Expected meta-review reconcile prompt to forbid write-approval requests.");
assert(metaReviewReconcilePromptSource.includes("Current Reviewed Output"), "Expected meta-review reconcile prompt to include the current reviewed output as a bundled input.");
assert(metaReviewReconcilePromptSource.includes("deterministic-valid baseline"), "Expected meta-review reconcile prompt to preserve the current reviewed output as the deterministic baseline.");
assert(metaReviewReconcilePromptSource.includes("`inProgressCycles`, `pendingCycles`, `Do not generate a new cycle plan`"), "Expected meta-review reconcile prompt to preserve canonical branch literals.");
assert(metaReviewReconcilePromptSource.includes("all always-required sections"), "Expected meta-review reconcile prompt to require canonical conditional-section wording.");
assert(metaReviewReconcilePromptSource.includes("only `[NN]`, `[NN-1]`, `[NN+1]`, `[NNr]`, and `[Cycle Title]` may remain bracketed"), "Expected meta-review reconcile prompt to restrict bracketed template tokens.");

const codexMetaReviewRelayPromptSource = fs.readFileSync(path.resolve("prompts/codex_qc_meta_review_relay_prompt.md"), "utf8");
assert(codexMetaReviewRelayPromptSource.includes("preserve validator-critical branch semantics"), "Expected Codex relay prompt to preserve validator-critical branch semantics.");
assert(codexMetaReviewRelayPromptSource.includes("`inProgressCycles`, `pendingCycles`, `Do not generate a new cycle plan`"), "Expected Codex relay prompt to preserve canonical branch literals.");
assert(codexMetaReviewRelayPromptSource.includes("all always-required sections"), "Expected Codex relay prompt to require canonical conditional-section wording.");
assert(codexMetaReviewRelayPromptSource.includes("only `[NN]`, `[NN-1]`, `[NN+1]`, `[NNr]`, and `[Cycle Title]` may remain bracketed"), "Expected Codex relay prompt to restrict bracketed template tokens.");

const crossQcSource = fs.readFileSync(path.resolve("accord.ps1"), "utf8");
assert(crossQcSource.includes('-PermissionMode $(if ($MetaReview) { "dontAsk" } else { "" })'), "Expected Claude meta-review write/fix flows to run with dontAsk permission mode.");
assert(crossQcSource.includes('-PermissionMode "dontAsk"'), "Expected Claude meta-review reconcile flow to run with dontAsk permission mode.");
assert(crossQcSource.includes("function Test-MetaReviewTerminalBranch"), "Expected cross_qc to define a dedicated terminal-branch validator helper.");
assert(crossQcSource.includes('$hasStatusDrivenInProgressBranch'), "Expected cross_qc to accept status-driven in-progress branch wording.");
assert(crossQcSource.includes("function Test-MetaReviewConditionalSectionsConsistency"), "Expected cross_qc to define a conditional-section consistency validator helper.");
assert(crossQcSource.includes("function Get-FencedOutputTemplateContent"), "Expected cross_qc to define a fenced output-template extractor.");
assert(crossQcSource.includes("function Remove-MarkdownInlineCodeSpans"), "Expected cross_qc to strip inline-code spans before placeholder detection outside template fences.");
assert(crossQcSource.includes("function Get-QCIssueSeveritySummary"), "Expected cross_qc to parse severity summaries from deterministic findings.");
assert(crossQcSource.includes("$allowedTemplateTokens = @('[NN]', '[NN-1]', '[NN+1]', '[NNr]', '[Cycle Title]')"), "Expected cross_qc to restrict bracketed template tokens in deterministic validation.");
assert(crossQcSource.includes('maxCodexPasses = 3'), "Expected cross_qc to advertise the bounded recovery Codex budget.");
assert(crossQcSource.includes('$maxDeterministicFixPasses = 2'), "Expected cross_qc to define the deterministic bounded-retry budget.");
assert(crossQcSource.includes('meta_review_validation_nonblocking_issues'), "Expected cross_qc to emit a warning event when deterministic retries leave only MEDIUM/LOW findings.");
assert(crossQcSource.includes('post-final-codex-fix'), "Expected cross_qc to rerun deterministic validation after the bounded recovery fix cycle.");

const rendererSource = fs.readFileSync(path.resolve("src/renderer/app.js"), "utf8");
const pendingRendererStart = rendererSource.indexOf("function renderPendingArtifactRow");
const pendingRendererEnd = rendererSource.indexOf("function renderArtifactButton");
assert(rendererSource.includes("Pending Artifacts"), "Expected renderer to label the pending artifacts section.");
assert(rendererSource.includes("artifact-item--pending"), "Expected renderer to include pending artifact rows.");
assert(pendingRendererStart >= 0 && pendingRendererEnd > pendingRendererStart, "Expected dedicated renderer helper for pending artifact rows.");
assert(!rendererSource.slice(pendingRendererStart, pendingRendererEnd).includes("data-artifact-path"), "Expected pending renderer rows to remain non-openable.");
assert(rendererSource.includes("if (pendingArtifactCount || artifactCount)"), "Expected renderer to suppress the empty state when pending items exist.");
assert(rendererSource.includes("function getEffectiveProcessInfo"), "Expected renderer to include a process-info fallback helper.");
assert(rendererSource.includes("detail-card-title\">Process"), "Expected renderer dashboard to include a Process detail card.");
assert(rendererSource.includes("Current step:"), "Expected renderer process card to include the current step line.");
assert(rendererSource.includes("Children:"), "Expected renderer process card to include the child-process summary.");
assert(rendererSource.includes("PID ${processInfo.pid} recorded"), "Expected renderer process card to surface a recorded PID even when telemetry is unavailable.");
assert(rendererSource.includes("renderProcessStatusBadge"), "Expected renderer to use a dedicated process-status badge helper.");

const rendererStylesSource = fs.readFileSync(path.resolve("src/renderer/styles.css"), "utf8");
assert(rendererStylesSource.includes(".artifact-item--pending"), "Expected stylesheet support for pending artifact rows.");
assert(rendererStylesSource.includes(".artifact-pending-badge"), "Expected stylesheet support for pending artifact badges.");
assert(rendererStylesSource.includes(".detail-card-value--inline"), "Expected stylesheet support for inline process-card headings.");

console.log("electron smoke test passed");


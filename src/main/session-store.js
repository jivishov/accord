const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function detectExecutionRoot() {
  const unpackedRoot = process.resourcesPath
    ? path.join(process.resourcesPath, "app.asar.unpacked")
    : "";
  if (unpackedRoot && fs.existsSync(path.join(unpackedRoot, "accord.ps1"))) {
    return unpackedRoot;
  }
  return path.resolve(__dirname, "..", "..");
}

const repoRoot = path.resolve(__dirname, "..", "..");
const executionRoot = detectExecutionRoot();
const defaultPromptDir = path.join(executionRoot, "prompts");
const helpDocsRoot = path.join(executionRoot, "docs", "help");
const metaPlanChecklistPath = path.join(executionRoot, "plan_for_meta_plan.md");
const SESSION_CONFIG_FILE = "session_config.json";
const TERMINAL_EVENT_TYPES = new Set([
  "pipeline_completed",
  "pipeline_failed",
  "pipeline_cancelled"
]);
const TERMINAL_STATUS_BY_EVENT_TYPE = {
  pipeline_completed: "completed",
  pipeline_failed: "failed",
  pipeline_cancelled: "cancelled"
};
const MIN_STALL_THRESHOLD_MS = 20 * 60 * 1000;
const STALL_GRACE_MS = 120 * 1000;
const ALIVE_IDLE_THRESHOLD_MS = 60 * 1000;
const PROCESS_SNAPSHOT_CACHE_TTL_MS = 1000;
const PROCESS_QUERY_TIMEOUT_MS = 2000;
const helpTopics = [
  {
    id: "quick-start",
    title: "Quick Start",
    fileName: "quick-start.md"
  },
  {
    id: "desktop-guide",
    title: "Desktop Guide",
    fileName: "desktop-guide.md"
  },
  {
    id: "pipeline-and-modes",
    title: "Pipeline & Modes",
    fileName: "pipeline-and-modes.md"
  }
];

function resolveWorkspaceDir(workspaceDir) {
  return path.resolve(workspaceDir || repoRoot);
}

function getWorkspacePaths(workspaceDir) {
  const resolvedWorkspaceDir = resolveWorkspaceDir(workspaceDir);
  return {
    workspaceDir: resolvedWorkspaceDir,
    logsRoot: path.join(resolvedWorkspaceDir, "logs"),
    cyclesRoot: path.join(resolvedWorkspaceDir, "cycles")
  };
}

function isPathInside(rootPath, targetPath) {
  const relative = path.relative(path.resolve(rootPath), path.resolve(targetPath));
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function assertAllowedPath(workspaceDir, targetPath) {
  const resolvedWorkspaceDir = resolveWorkspaceDir(workspaceDir);
  const resolvedTargetPath = path.resolve(targetPath);
  if (
    !isPathInside(resolvedWorkspaceDir, resolvedTargetPath) &&
    !isPathInside(repoRoot, resolvedTargetPath) &&
    !isPathInside(executionRoot, resolvedTargetPath)
  ) {
    throw new Error(`Path is outside allowed roots: ${resolvedTargetPath}`);
  }
  return resolvedTargetPath;
}

function assertWorkspacePlanPath(workspaceDir, targetPath) {
  const resolvedWorkspaceDir = resolveWorkspaceDir(workspaceDir);
  const resolvedTargetPath = path.resolve(resolvedWorkspaceDir, targetPath || "");
  if (!isPathInside(resolvedWorkspaceDir, resolvedTargetPath)) {
    throw new Error("Plan files must stay inside the selected workspace directory.");
  }
  return resolvedTargetPath;
}

function pathsEqual(leftPath, rightPath) {
  if (!leftPath || !rightPath) {
    return false;
  }
  return path.resolve(leftPath).toLowerCase() === path.resolve(rightPath).toLowerCase();
}

function getSessionScopedAllowedPaths(workspaceDir, sessionId) {
  if (!sessionId) {
    return [];
  }

  const { logsRoot } = getWorkspacePaths(workspaceDir);
  const sessionLogsDir = path.join(logsRoot, sessionId);
  const runState = readJson(path.join(sessionLogsDir, "run_state.json")) || {};
  const sessionConfig = readSessionConfig(workspaceDir, sessionId) || {};

  return [
    sessionConfig.planFile,
    sessionConfig.metaReviewTargetFile,
    sessionConfig.metaReviewChecklistFile,
    sessionConfig.metaReviewOutputFile,
    runState.planFile,
    runState.metaReviewTargetFile,
    runState.metaReviewChecklistFile,
    runState.metaReviewOutputFile
  ]
    .filter(Boolean)
    .map((filePath) => path.resolve(filePath));
}

function assertAllowedArtifactPath(workspaceDir, targetPath, sessionId) {
  const resolvedTargetPath = path.resolve(targetPath);
  for (const allowedPath of getSessionScopedAllowedPaths(workspaceDir, sessionId)) {
    if (pathsEqual(allowedPath, resolvedTargetPath)) {
      return resolvedTargetPath;
    }
  }
  return assertAllowedPath(workspaceDir, resolvedTargetPath);
}

function safeReadFile(filePath) {
  if (!fs.existsSync(filePath)) {
    return "";
  }
  return fs.readFileSync(filePath, "utf8");
}

function stripUtf8Bom(value) {
  return String(value ?? "").replace(/^\uFEFF/, "");
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) {
    return null;
  }

  try {
    const raw = stripUtf8Bom(fs.readFileSync(filePath, "utf8"));
    return raw.trim() ? JSON.parse(raw) : null;
  } catch (error) {
    return null;
  }
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function writeJsonFileAtomic(filePath, value) {
  ensureDir(path.dirname(filePath));
  const tempPath = `${filePath}.tmp`;
  fs.writeFileSync(tempPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  if (fs.existsSync(filePath)) {
    fs.rmSync(filePath, { force: true });
  }
  fs.renameSync(tempPath, filePath);
}

function readTail(filePath, lineCount = 80) {
  if (!fs.existsSync(filePath)) {
    return "";
  }

  const content = fs.readFileSync(filePath, "utf8");
  const lines = content.split(/\r?\n/);
  return lines.slice(Math.max(lines.length - lineCount, 0)).join("\n");
}

function readNdjson(filePath, limit = 30) {
  if (!fs.existsSync(filePath)) {
    return [];
  }

  return fs
    .readFileSync(filePath, "utf8")
    .replace(/^\uFEFF/, "")
    .split(/\r?\n/)
    .map((line) => stripUtf8Bom(line).trim())
    .filter(Boolean)
    .slice(-limit)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        return null;
      }
    })
    .filter(Boolean);
}

function toTimestampMs(value) {
  const timestamp = Date.parse(value || "");
  return Number.isFinite(timestamp) ? timestamp : 0;
}

function getNewerEvent(left, right) {
  return toTimestampMs(left?.timestamp) >= toTimestampMs(right?.timestamp) ? left : right;
}

function listDirectoryNames(rootPath) {
  if (!fs.existsSync(rootPath)) {
    return [];
  }

  return fs
    .readdirSync(rootPath, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name);
}

function getLatestFile(directoryPath, filterFn) {
  if (!fs.existsSync(directoryPath)) {
    return "";
  }

  const matches = fs
    .readdirSync(directoryPath, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(directoryPath, entry.name))
    .filter((filePath) => filterFn(path.basename(filePath)))
    .sort((left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs);

  return matches[0] || "";
}

function normalizeCodexMarkdown(content) {
  if (content === undefined || content === null) {
    return "";
  }

  return String(content)
    .replace(/^\uFEFF/, "")
    .replace(/\u001B\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "")
    .trim();
}

function toIsoTimestamp(value) {
  if (!Number.isFinite(value) || value <= 0) {
    return null;
  }
  return new Date(value).toISOString();
}

function getNewestTimestamp(...values) {
  let latestMs = 0;
  let latestValue = null;

  for (const value of values.flat()) {
    if (!value) {
      continue;
    }

    const timestampMs = typeof value === "number" ? value : toTimestampMs(value);
    if (!timestampMs || timestampMs < latestMs) {
      continue;
    }

    latestMs = timestampMs;
    latestValue = typeof value === "number" ? toIsoTimestamp(timestampMs) : value;
  }

  return {
    ms: latestMs,
    value: latestValue
  };
}

function getSessionFileTimestamp(filePath) {
  if (!filePath || !fs.existsSync(filePath)) {
    return 0;
  }

  try {
    return fs.statSync(filePath).mtimeMs;
  } catch {
    return 0;
  }
}

let windowsProcessSnapshotCache = {
  fetchedAtMs: 0,
  processes: null
};

function parseProcessSnapshotJson(rawJson) {
  if (!rawJson) {
    return [];
  }

  const parsed = JSON.parse(rawJson);
  const rows = Array.isArray(parsed) ? parsed : [parsed];
  return rows
    .map((entry) => ({
      pid: Number(entry?.ProcessId || 0),
      parentPid: Number(entry?.ParentProcessId || 0),
      name: String(entry?.Name || "").trim(),
      commandLine: String(entry?.CommandLine || "").trim()
    }))
    .filter((entry) => entry.pid > 0);
}

function queryWindowsProcessSnapshot() {
  if (process.platform !== "win32") {
    return null;
  }

  if (process.env.CROSS_QC_PROCESS_QUERY_FAIL === "1") {
    return null;
  }

  if (process.env.CROSS_QC_PROCESS_QUERY_JSON) {
    try {
      return parseProcessSnapshotJson(process.env.CROSS_QC_PROCESS_QUERY_JSON);
    } catch {
      return null;
    }
  }

  const now = Date.now();
  if (
    windowsProcessSnapshotCache.processes &&
    now - windowsProcessSnapshotCache.fetchedAtMs < PROCESS_SNAPSHOT_CACHE_TTL_MS
  ) {
    return windowsProcessSnapshotCache.processes;
  }

  const result = spawnSync(
    "powershell.exe",
    [
      "-NoProfile",
      "-Command",
      "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine | ConvertTo-Json -Compress"
    ],
    {
      windowsHide: true,
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024,
      timeout: PROCESS_QUERY_TIMEOUT_MS
    }
  );

  if (result.error || result.status !== 0) {
    return null;
  }

  try {
    const processes = parseProcessSnapshotJson(result.stdout);
    windowsProcessSnapshotCache = {
      fetchedAtMs: now,
      processes
    };
    return processes;
  } catch {
    return null;
  }
}

function collectProcessDescendants(pid) {
  const rootPid = Number(pid || 0);
  if (!rootPid) {
    return [];
  }

  const snapshot = queryWindowsProcessSnapshot();
  if (!snapshot) {
    return [];
  }

  const childrenByParent = new Map();
  for (const processInfo of snapshot) {
    if (!childrenByParent.has(processInfo.parentPid)) {
      childrenByParent.set(processInfo.parentPid, []);
    }
    childrenByParent.get(processInfo.parentPid).push(processInfo);
  }

  const descendants = [];
  const queue = [...(childrenByParent.get(rootPid) || [])];
  const seen = new Set();

  while (queue.length > 0) {
    const current = queue.shift();
    if (!current || seen.has(current.pid)) {
      continue;
    }
    seen.add(current.pid);
    descendants.push({
      pid: current.pid,
      name: current.name,
      commandLine: current.commandLine
    });
    queue.push(...(childrenByParent.get(current.pid) || []));
  }

  return descendants;
}

function getProcessStateLabel(state) {
  const labels = {
    active: "Active",
    alive_idle: "Alive but idle",
    stalled: "Stalled",
    dead: "Dead",
    unavailable: "Unavailable"
  };
  return labels[state] || "Unavailable";
}

function buildProcessInfo(sessionSummary, runState) {
  const pid = Number(runState?.childPid || 0);
  const sessionStatus = String(sessionSummary?.status || "").toLowerCase();
  const isRunningSession = sessionStatus === "running";
  const actualAlive = pid > 0 ? isProcessAlive(pid) : false;
  const alive = isRunningSession ? actualAlive : false;
  const startedAt = runState?.startedAt || sessionSummary.startedAt || null;
  const lastActivityAt = sessionSummary.lastActivityAt || null;
  const lastActivityMs = toTimestampMs(lastActivityAt);
  const idleDurationMs = lastActivityMs > 0 ? Math.max(0, Date.now() - lastActivityMs) : 0;
  let state = "unavailable";

  if (!pid) {
    state = "unavailable";
  } else if (!isRunningSession) {
    state = "dead";
  } else if (!actualAlive) {
    state = "dead";
  } else if (sessionSummary.isStalled) {
    state = "stalled";
  } else if (idleDurationMs >= ALIVE_IDLE_THRESHOLD_MS) {
    state = "alive_idle";
  } else {
    state = "active";
  }

  return {
    pid,
    alive,
    startedAt,
    currentAction: sessionSummary.currentAction || runState?.currentAction || "",
    currentTool: sessionSummary.currentTool || runState?.currentTool || "",
    lastActivityAt,
    idleDurationMs,
    state,
    stateLabel: getProcessStateLabel(state),
    children: isRunningSession && actualAlive ? collectProcessDescendants(pid) : []
  };
}

function parsePendingDeliberationTempArtifact(filePath) {
  const fileName = path.basename(filePath);
  const match = fileName.match(/^\.?(round\d+_codex_(evaluation|review))_last_message\.tmp$/i);
  if (!match) {
    return null;
  }

  const baseName = match[1];
  const kind = match[2].toLowerCase() === "review" ? "codex_review" : "codex_evaluation";
  const stats = fs.statSync(filePath);

  return {
    path: filePath,
    name: fileName,
    artifactName: `${baseName}.md`,
    artifactPath: path.join(path.dirname(filePath), `${baseName}.md`),
    kind,
    modifiedAt: new Date(stats.mtimeMs).toISOString(),
    size: stats.size
  };
}

function isPendingDeliberationTempFile(filePath) {
  return Boolean(parsePendingDeliberationTempArtifact(filePath));
}

function collectPendingDeliberationTempArtifacts(sessionLogsDir) {
  const deliberationDir = path.join(sessionLogsDir || "", "deliberation");
  if (!fs.existsSync(deliberationDir)) {
    return [];
  }

  return collectFiles(deliberationDir)
    .map((filePath) => parsePendingDeliberationTempArtifact(filePath))
    .filter(Boolean)
    .sort((left, right) => toTimestampMs(right.modifiedAt) - toTimestampMs(left.modifiedAt));
}

function salvagePendingDeliberationOutputs(workspaceDir, sessionId) {
  const { logsRoot } = getWorkspacePaths(workspaceDir);
  const sessionLogsDir = path.join(logsRoot, sessionId);
  const pendingArtifacts = collectPendingDeliberationTempArtifacts(sessionLogsDir);
  const salvagedArtifacts = [];

  for (const pendingArtifact of pendingArtifacts) {
    if (fs.existsSync(pendingArtifact.artifactPath)) {
      continue;
    }

    const normalizedContent = normalizeCodexMarkdown(safeReadFile(pendingArtifact.path));
    if (!normalizedContent) {
      continue;
    }

    ensureDir(path.dirname(pendingArtifact.artifactPath));
    fs.writeFileSync(pendingArtifact.artifactPath, `${normalizedContent}\n`, "utf8");
    fs.rmSync(pendingArtifact.path, { force: true });
    salvagedArtifacts.push({
      ...pendingArtifact,
      salvagedAt: new Date().toISOString()
    });
  }

  return {
    pendingArtifacts,
    salvagedArtifacts
  };
}

function classifyArtifact(filePath) {
  const fileName = path.basename(filePath).toLowerCase();

  if (fileName === "run_state.json") {
    return "run_state";
  }
  if (fileName === "events.ndjson") {
    return "event_stream";
  }
  if (fileName === "_iteration_history.md") {
    return "history";
  }
  if (fileName === "_cycle_status.json") {
    return "cycle_status";
  }
  if (fileName === SESSION_CONFIG_FILE) {
    return "session_config";
  }
  if (fileName.endsWith("_transcript.txt")) {
    return "transcript";
  }
  if (fileName.startsWith("qc_log_")) {
    return "log";
  }
  if (fileName.startsWith("plan_qc_report_")) {
    return "plan_qc_report";
  }
  if (fileName.startsWith("doc_qc_report_") || fileName.startsWith("qc_report_")) {
    return "qc_report";
  }
  if (fileName.startsWith("continuation_cycle_")) {
    return "cycle_plan";
  }
  if (fileName.endsWith(".reviewed.md")) {
    return "meta_review_output";
  }
  if (fileName.includes("deliberation_summary")) {
    return "deliberation_summary";
  }
  if (fileName.includes("thoughts")) {
    return "claude_thoughts";
  }
  if (fileName.includes("review")) {
    return "codex_review";
  }
  if (fileName.includes("evaluation")) {
    return "codex_evaluation";
  }

  return "artifact";
}

// Deliberation round artifacts are sorted together by round number,
// then claude before codex within each round — so the list reads
// like a timeline: round1_claude, round1_codex, round2_claude, ...
const DELIBERATION_KINDS = new Set([
  "claude_thoughts",
  "codex_evaluation",
  "codex_review"
]);

const SECTION_LABELS = {
  cycle_plan: "Output",
  meta_review_output: "Output",
  deliberation_summary: "Deliberation",
  deliberation_round: "Deliberation",
  qc_report: "QC Reports",
  plan_qc_report: "Plan QC",
  transcript: "Session",
  log: "Session",
  event_stream: "Session",
  run_state: "Session",
  history: "Session",
  cycle_status: "Session",
  session_config: "Session",
  artifact: "Other"
};

// Within a deliberation round: claude first, then codex
const DELIB_AGENT_ORDER = { claude_thoughts: 0, codex_evaluation: 1, codex_review: 1 };

// Top-level section order (deliberation rounds sit between summary and QC reports)
const SECTION_ORDER = [
  "cycle_plan",           // 0  — the output plan
  "meta_review_output",   // 1  — reviewed meta-plan sibling output
  "deliberation_summary", // 2  — convergence summary
  "deliberation_round",   // 3  — virtual group for all round artifacts
  "qc_report",            // 4
  "plan_qc_report",       // 5
  "transcript",           // 6
  "log",                  // 7
  "event_stream",         // 8
  "run_state",            // 9
  "history",              // 10
  "cycle_status",         // 11
  "artifact"              // 12
];

function extractArtifactNumber(fileName) {
  const match = fileName.match(/(?:round|iter|cycle_?)(\d+)/i);
  return match ? parseInt(match[1], 10) : 0;
}

function artifactSection(kind) {
  if (DELIBERATION_KINDS.has(kind)) return "deliberation_round";
  return kind;
}

function sectionIndex(section) {
  const idx = SECTION_ORDER.indexOf(section);
  return idx === -1 ? SECTION_ORDER.length : idx;
}

function sortArtifacts(artifacts) {
  return artifacts.slice().sort((a, b) => {
    const secA = sectionIndex(artifactSection(a.kind));
    const secB = sectionIndex(artifactSection(b.kind));
    if (secA !== secB) return secA - secB;

    // Both are deliberation round artifacts — sort by round, then agent
    if (DELIBERATION_KINDS.has(a.kind) && DELIBERATION_KINDS.has(b.kind)) {
      const roundA = extractArtifactNumber(a.name);
      const roundB = extractArtifactNumber(b.name);
      if (roundA !== roundB) return roundA - roundB;

      const agentA = DELIB_AGENT_ORDER[a.kind] ?? 2;
      const agentB = DELIB_AGENT_ORDER[b.kind] ?? 2;
      if (agentA !== agentB) return agentA - agentB;
    }

    // Same section — sort by iteration/number, then mtime
    const numA = extractArtifactNumber(a.name);
    const numB = extractArtifactNumber(b.name);
    if (numA !== numB) return numA - numB;

    return new Date(b.modifiedAt).getTime() - new Date(a.modifiedAt).getTime();
  });
}

function collectFiles(rootPath) {
  if (!fs.existsSync(rootPath)) {
    return [];
  }

  const collected = [];
  for (const entry of fs.readdirSync(rootPath, { withFileTypes: true })) {
    const entryPath = path.join(rootPath, entry.name);
    if (entry.isDirectory()) {
      collected.push(...collectFiles(entryPath));
      continue;
    }
    collected.push(entryPath);
  }
  return collected;
}

function getArtifactRelativePath(workspaceDir, filePath) {
  const resolvedFilePath = path.resolve(filePath);
  return isPathInside(resolveWorkspaceDir(workspaceDir), resolvedFilePath)
    ? path.relative(resolveWorkspaceDir(workspaceDir), resolvedFilePath)
    : resolvedFilePath;
}

function mapArtifactFile(workspaceDir, filePath, kindOverride = "") {
  const resolvedFilePath = path.resolve(filePath);
  const stats = fs.statSync(resolvedFilePath);
  return {
    path: resolvedFilePath,
    name: path.basename(resolvedFilePath),
    kind: kindOverride || classifyArtifact(resolvedFilePath),
    relativePath: getArtifactRelativePath(workspaceDir, resolvedFilePath),
    modifiedAt: new Date(stats.mtimeMs).toISOString(),
    size: stats.size
  };
}

const PENDING_ARTIFACT_TYPE_ALIASES = {
  continuation_plan: "cycle_plan"
};

function normalizePendingArtifactKind(kind, filePath) {
  const normalizedKind = String(kind || "").trim().toLowerCase();
  if (!normalizedKind) {
    return classifyArtifact(filePath);
  }

  const aliasedKind = PENDING_ARTIFACT_TYPE_ALIASES[normalizedKind] || normalizedKind;
  if (
    aliasedKind === "artifact" ||
    SECTION_LABELS[aliasedKind] ||
    DELIBERATION_KINDS.has(aliasedKind)
  ) {
    return aliasedKind;
  }

  return classifyArtifact(filePath);
}

const META_REVIEW_PENDING_ACTIONS = new Set([
  "claude_write",
  "meta_review_fix",
  "meta_review_reconcile"
]);

function collectPendingSessionArtifacts(workspaceDir, sessionId, options = {}) {
  const { logsRoot } = getWorkspacePaths(workspaceDir);
  const sessionLogsDir = options.sessionLogsDir || path.join(logsRoot, sessionId);
  const runState = options.runState || readJson(path.join(sessionLogsDir, "run_state.json")) || {};
  const sessionConfig = options.sessionConfig || readSessionConfig(workspaceDir, sessionId) || {};
  const status = String(options.status || runState.status || "").toLowerCase();

  if (status !== "running") {
    return [];
  }

  const currentAction = String(options.currentAction || runState.currentAction || "").trim();
  const metaReviewOutputFile =
    options.metaReviewOutputFile ||
    runState.metaReviewOutputFile ||
    sessionConfig.metaReviewOutputFile ||
    "";
  const fallbackUpdatedAt =
    options.updatedAt ||
    runState.updatedAt ||
    runState.startedAt ||
    null;
  const realArtifacts = options.artifacts || collectSessionArtifacts(workspaceDir, sessionId);
  const existingArtifactPaths = new Set(realArtifacts.map((artifact) => path.resolve(artifact.path).toLowerCase()));
  const pendingArtifacts = [];
  const seenPendingPaths = new Set();

  function addPendingArtifact(filePath, kind, source, updatedAt, nameOverride = "") {
    if (!filePath) {
      return;
    }

    const resolvedPath = path.resolve(filePath);
    const normalizedPath = resolvedPath.toLowerCase();
    if (
      fs.existsSync(resolvedPath) ||
      existingArtifactPaths.has(normalizedPath) ||
      seenPendingPaths.has(normalizedPath)
    ) {
      return;
    }

    seenPendingPaths.add(normalizedPath);
    pendingArtifacts.push({
      path: resolvedPath,
      name: nameOverride || path.basename(resolvedPath),
      kind: kind || classifyArtifact(resolvedPath),
      relativePath: getArtifactRelativePath(workspaceDir, resolvedPath),
      source,
      status: "pending",
      updatedAt: updatedAt || fallbackUpdatedAt || null
    });
  }

  for (const pendingTempArtifact of collectPendingDeliberationTempArtifacts(sessionLogsDir)) {
    addPendingArtifact(
      pendingTempArtifact.artifactPath,
      pendingTempArtifact.kind,
      "deliberation temp",
      pendingTempArtifact.modifiedAt,
      pendingTempArtifact.artifactName
    );
  }

  if (runState.currentQCReport) {
    addPendingArtifact(runState.currentQCReport, "qc_report", "pending qc report", runState.updatedAt);
  }

  if (runState.currentArtifact) {
    addPendingArtifact(
      runState.currentArtifact,
      normalizePendingArtifactKind(runState.currentArtifactType, runState.currentArtifact),
      "current step",
      runState.updatedAt
    );
  }

  if (metaReviewOutputFile && META_REVIEW_PENDING_ACTIONS.has(currentAction)) {
    addPendingArtifact(metaReviewOutputFile, "meta_review_output", "meta-review output", runState.updatedAt);
  }

  return pendingArtifacts.sort((left, right) => toTimestampMs(right.updatedAt) - toTimestampMs(left.updatedAt));
}

function collectSessionArtifacts(workspaceDir, sessionId) {
  const { logsRoot, cyclesRoot } = getWorkspacePaths(workspaceDir);
  const sessionLogsDir = path.join(logsRoot, sessionId);
  const sessionCyclesDir = path.join(cyclesRoot, sessionId);
  const runState = readJson(path.join(sessionLogsDir, "run_state.json")) || {};
  const sessionConfig = readSessionConfig(workspaceDir, sessionId) || {};
  const canonicalCyclePlan = getLatestFile(cyclesRoot, (name) => /^CONTINUATION_CYCLE_\d+\.md$/i.test(name));

  // Only include the canonical cycle plan if it was produced during or after this session.
  // This prevents a previous session's cycle plan from appearing as "Output" for a new session.
  let effectiveCanonicalPlan = canonicalCyclePlan;
  if (canonicalCyclePlan) {
    try {
      const planMtimeMs = fs.statSync(canonicalCyclePlan).mtimeMs;
      const sessionDirStats = fs.statSync(sessionLogsDir);
      const sessionStartMs = sessionDirStats.birthtimeMs || sessionDirStats.ctimeMs;
      if (Number.isFinite(sessionStartMs) && planMtimeMs < sessionStartMs - 5000) {
        effectiveCanonicalPlan = null;
      }
    } catch { /* keep canonical if stat fails */ }
  }

  const externalArtifacts = [
    runState.currentArtifact,
    effectiveCanonicalPlan,
    runState.metaReviewOutputFile,
    sessionConfig.metaReviewOutputFile
  ]
    .filter(Boolean)
    .filter((filePath) => fs.existsSync(filePath));
  const files = [
    ...collectFiles(sessionLogsDir).filter((filePath) => !isPendingDeliberationTempFile(filePath)),
    ...collectFiles(sessionCyclesDir),
    ...externalArtifacts.map((filePath) => path.resolve(filePath))
  ];
  const uniqueFiles = [...new Set(files.map((filePath) => path.resolve(filePath)))];

  const mapped = uniqueFiles.map((filePath) => mapArtifactFile(workspaceDir, filePath));

  const sorted = sortArtifacts(mapped);
  let prevSection = "";
  let prevRound = -1;
  for (const artifact of sorted) {
    const sec = artifactSection(artifact.kind);
    artifact.section = sec;
    artifact.sectionLabel = SECTION_LABELS[sec] || sec;
    artifact.sectionChanged = (sec !== prevSection);
    prevSection = sec;

    if (DELIBERATION_KINDS.has(artifact.kind)) {
      const round = extractArtifactNumber(artifact.name);
      artifact.round = round;
      artifact.roundChanged = (round !== prevRound);
      prevRound = round;
    } else {
      artifact.round = 0;
      artifact.roundChanged = false;
      if (sec !== "deliberation_round") {
        prevRound = -1;
      }
    }
  }
  return sorted;
}

function isProcessAlive(pid) {
  if (!pid || Number.isNaN(Number(pid))) {
    return false;
  }

  try {
    process.kill(Number(pid), 0);
    return true;
  } catch (error) {
    return false;
  }
}

function getLatestPipelineStartEvent(events) {
  return events
    .slice()
    .reverse()
    .find((event) => ["pipeline_started", "pipeline_spawned"].includes(event?.type)) || null;
}

function eventBelongsToLatestAttempt(event, latestStartEvent) {
  if (!latestStartEvent) {
    return true;
  }

  const startTime = toTimestampMs(latestStartEvent.timestamp);
  const eventTime = toTimestampMs(event?.timestamp);
  if (!startTime || !eventTime) {
    return true;
  }

  return eventTime >= startTime;
}

function getLatestStateEvent(events, latestStartEvent = null) {
  return events
    .slice()
    .reverse()
    .find((event) =>
      eventBelongsToLatestAttempt(event, latestStartEvent) &&
      Boolean(event?.phase || event?.status || event?.currentDeliberationRound || event?.data?.message)
    ) || null;
}

function getLatestTerminalEvent(events, latestStartEvent = null) {
  const reversed = events.slice().reverse();
  return reversed.find((event) =>
    eventBelongsToLatestAttempt(event, latestStartEvent) &&
    TERMINAL_EVENT_TYPES.has(event?.type) &&
    event?.data?.source !== "electron"
  ) || reversed.find((event) =>
    eventBelongsToLatestAttempt(event, latestStartEvent) &&
    TERMINAL_EVENT_TYPES.has(event?.type)
  ) || null;
}

function getTerminalStatusFromEvent(event) {
  if (!event) {
    return "";
  }
  return event.status || TERMINAL_STATUS_BY_EVENT_TYPE[event.type] || "";
}

function deriveEventState(events) {
  const latestStartEvent = getLatestPipelineStartEvent(events);
  const latestStateEvent = getLatestStateEvent(events, latestStartEvent);
  const latestTerminalEvent = getLatestTerminalEvent(events, latestStartEvent);
  const latestTerminalStatus = getTerminalStatusFromEvent(latestTerminalEvent);
  const latestRelevantEvent = getNewerEvent(
    getNewerEvent(latestTerminalEvent, latestStateEvent),
    latestStartEvent
  );

  return {
    latestStartEvent,
    latestStateEvent,
    latestTerminalEvent,
    latestRelevantEvent,
    latestTimestampMs: toTimestampMs(latestRelevantEvent?.timestamp),
    status:
      latestTerminalStatus ||
      latestStateEvent?.status ||
      (latestStartEvent ? "running" : "unknown"),
    phase:
      latestTerminalEvent?.phase ||
      latestStateEvent?.phase ||
      latestStartEvent?.phase ||
      "",
    currentIteration:
      latestTerminalEvent?.currentIteration ||
      latestStateEvent?.currentIteration ||
      0,
    currentPlanQCIteration:
      latestTerminalEvent?.currentPlanQCIteration ||
      latestStateEvent?.currentPlanQCIteration ||
      0,
    currentDeliberationRound:
      latestTerminalEvent?.currentDeliberationRound ||
      latestStateEvent?.currentDeliberationRound ||
      0,
    lastMessage:
      latestTerminalEvent?.data?.message ||
      latestStateEvent?.data?.message ||
      latestStartEvent?.data?.message ||
      "",
    lastError:
      latestTerminalStatus === "failed" || latestTerminalEvent?.level === "error"
        ? (latestTerminalEvent?.data?.message || "")
        : "",
    updatedAt:
      latestRelevantEvent?.timestamp ||
      latestStateEvent?.timestamp ||
      latestStartEvent?.timestamp ||
      null,
    startedAt: latestStartEvent?.timestamp || null,
    completedAt: latestTerminalEvent?.timestamp || null
  };
}

function getSessionSummary(workspaceDir, sessionId) {
  const { logsRoot, cyclesRoot } = getWorkspacePaths(workspaceDir);
  const sessionLogsDir = path.join(logsRoot, sessionId);
  const sessionCyclesDir = path.join(cyclesRoot, sessionId);
  const runStatePath = path.join(sessionLogsDir, "run_state.json");
  const runState = readJson(runStatePath);
  const eventsPath = path.join(sessionLogsDir, "events.ndjson");
  const recentEvents = readNdjson(eventsPath, 200);
  const latestLogFile = getLatestFile(sessionLogsDir, (name) => name.startsWith("qc_log_"));
  const latestCyclePlan =
    getLatestFile(cyclesRoot, (name) => /^CONTINUATION_CYCLE_\d+\.md$/i.test(name)) ||
    getLatestFile(sessionCyclesDir, (name) => /^CONTINUATION_CYCLE_\d+\.md$/i.test(name));
  const artifacts = collectSessionArtifacts(workspaceDir, sessionId);
  const latestArtifact = artifacts[0] || null;
  const newestActivityArtifact = artifacts
    .filter((artifact) => !["event_stream", "run_state", "session_config", "log"].includes(artifact.kind))
    .slice()
    .sort((left, right) => toTimestampMs(right.modifiedAt) - toTimestampMs(left.modifiedAt))[0] || null;
  const pendingDeliberationTempArtifacts = collectPendingDeliberationTempArtifacts(sessionLogsDir);
  const latestPendingDeliberationTempArtifact = pendingDeliberationTempArtifacts[0] || null;
  const eventState = deriveEventState(recentEvents);
  const latestStateEvent = eventState.latestStateEvent;
  const latestTerminalEvent = eventState.latestTerminalEvent;
  const sessionConfig = readSessionConfig(workspaceDir, sessionId) ||
    buildSessionConfigFallback(workspaceDir, {
      runState,
      recentEvents,
      latestStateEvent,
      latestTerminalEvent,
      latestCyclePlan
    });
  const metaReview = Boolean(
    runState?.metaReview ??
    sessionConfig?.metaReview ??
    latestStateEvent?.data?.metaReview ??
    latestTerminalEvent?.data?.metaReview
  );
  const metaReviewTargetFile =
    runState?.metaReviewTargetFile ||
    sessionConfig?.metaReviewTargetFile ||
    latestStateEvent?.data?.metaReviewTargetFile ||
    latestTerminalEvent?.data?.metaReviewTargetFile ||
    "";
  const metaReviewChecklistFile =
    runState?.metaReviewChecklistFile ||
    sessionConfig?.metaReviewChecklistFile ||
    latestStateEvent?.data?.metaReviewChecklistFile ||
    latestTerminalEvent?.data?.metaReviewChecklistFile ||
    "";
  const metaReviewOutputFile =
    runState?.metaReviewOutputFile ||
    sessionConfig?.metaReviewOutputFile ||
    latestStateEvent?.data?.metaReviewOutputFile ||
    latestTerminalEvent?.data?.metaReviewOutputFile ||
    "";
  const agentTimeoutSec = Number(
    runState?.agentTimeoutSec ||
    sessionConfig?.agentTimeoutSec ||
    latestStateEvent?.data?.agentTimeoutSec ||
    latestTerminalEvent?.data?.agentTimeoutSec ||
    900
  );
  const runStateTimestampMs = toTimestampMs(
    runState?.updatedAt || runState?.completedAt || runState?.startedAt
  );
  const runStateMatchesLatestPipeline =
    !runState?.pipelineId ||
    !eventState.latestStartEvent?.pipelineId ||
    runState.pipelineId === eventState.latestStartEvent.pipelineId;
  const eventStateHasExplicitStatus = Boolean(
    latestStateEvent?.status || getTerminalStatusFromEvent(latestTerminalEvent)
  );
  const shouldPreferEventState =
    !runState ||
    !runState.status ||
    !runStateMatchesLatestPipeline ||
    (eventStateHasExplicitStatus && eventState.latestTimestampMs > runStateTimestampMs);
  const fallbackStatus = eventState.status || "unknown";
  const rawStatus = shouldPreferEventState ? fallbackStatus : (runState?.status || fallbackStatus);
  let status = rawStatus;
  if (rawStatus === "running" && runState?.childPid && !isProcessAlive(runState.childPid)) {
    status = getTerminalStatusFromEvent(latestTerminalEvent) || "stale";
  }
  const lastActivity = getNewestTimestamp(
    runState?.updatedAt || runState?.completedAt || runState?.startedAt,
    eventState.updatedAt,
    getSessionFileTimestamp(latestLogFile),
    newestActivityArtifact?.modifiedAt,
    latestPendingDeliberationTempArtifact?.modifiedAt
  );
  const stallThresholdMs = Math.max(
    (Number.isFinite(agentTimeoutSec) ? agentTimeoutSec : 900) * 1000 + STALL_GRACE_MS,
    MIN_STALL_THRESHOLD_MS
  );
  const childPid = Number(runState?.childPid || 0);
  const currentAction = runState?.currentAction || "";
  const currentTool = runState?.currentTool || "";
  const pendingArtifacts = collectPendingSessionArtifacts(workspaceDir, sessionId, {
    sessionLogsDir,
    runState,
    sessionConfig,
    artifacts,
    status,
    currentAction,
    metaReviewOutputFile,
    updatedAt: runState?.updatedAt || eventState.updatedAt || latestArtifact?.modifiedAt || null
  });
  const isStalled = Boolean(
    status === "running" &&
    childPid > 0 &&
    isProcessAlive(childPid) &&
    lastActivity.ms > 0 &&
    Date.now() - lastActivity.ms >= stallThresholdMs
  );
  const stallReason = isStalled
    ? `No session activity was recorded while ${currentAction || "the current step"}${currentTool ? ` (${currentTool})` : ""} remained active.`
    : "";
  const resumeInfo = getResumeRunConfig(workspaceDir, sessionId, {
    runState,
    recentEvents,
    artifacts,
    latestCyclePlan,
    sessionConfig,
    status,
    latestStateEvent,
    latestTerminalEvent
  });

  return {
    sessionId,
    workspaceDir: resolveWorkspaceDir(workspaceDir),
    sessionLogsDir,
    sessionCyclesDir,
    runStatePath,
    status,
    phase: shouldPreferEventState
      ? (eventState.phase || runState?.phase || "")
      : (runState?.phase || eventState.phase || ""),
    currentAction,
    currentTool,
    currentIteration: shouldPreferEventState
      ? (eventState.currentIteration || runState?.currentIteration || 0)
      : (runState?.currentIteration || eventState.currentIteration || 0),
    currentPlanQCIteration: shouldPreferEventState
      ? (eventState.currentPlanQCIteration || runState?.currentPlanQCIteration || 0)
      : (runState?.currentPlanQCIteration || eventState.currentPlanQCIteration || 0),
    currentDeliberationRound: shouldPreferEventState
      ? (eventState.currentDeliberationRound || runState?.currentDeliberationRound || 0)
      : (runState?.currentDeliberationRound || eventState.currentDeliberationRound || 0),
    qcType: runState?.qcType || sessionConfig?.qcType || latestStateEvent?.data?.qcType || "",
    lastMessage: shouldPreferEventState
      ? (eventState.lastMessage || runState?.lastMessage || "")
      : (runState?.lastMessage || eventState.lastMessage || ""),
    lastError: shouldPreferEventState
      ? (eventState.lastError || runState?.lastError || "")
      : (runState?.lastError || eventState.lastError || ""),
    updatedAt: shouldPreferEventState
      ? (eventState.updatedAt || runState?.updatedAt || latestArtifact?.modifiedAt || null)
      : (runState?.updatedAt || eventState.updatedAt || latestArtifact?.modifiedAt || null),
    lastActivityAt: lastActivity.value || null,
    isStalled,
    stallReason,
    startedAt: shouldPreferEventState
      ? (runState?.startedAt || eventState.startedAt || recentEvents[0]?.timestamp || null)
      : (runState?.startedAt || eventState.startedAt || recentEvents[0]?.timestamp || null),
    completedAt: shouldPreferEventState
      ? (eventState.completedAt || runState?.completedAt || null)
      : (runState?.completedAt || eventState.completedAt || null),
    planFile: runState?.planFile || sessionConfig?.planFile || latestStateEvent?.data?.planFile || "",
    planTitle: runState?.planTitle || "",
    logFile: latestLogFile,
    latestCyclePlan,
    artifactCount: artifacts.length,
    pendingArtifactCount: pendingArtifacts.length,
    pendingDeliberationTempArtifactCount: pendingDeliberationTempArtifacts.length,
    agentTimeoutSec,
    metaReview,
    metaReviewTargetFile,
    metaReviewChecklistFile,
    metaReviewOutputFile,
    sessionConfig,
    canResume: resumeInfo.ok,
    resumeReason: resumeInfo.reason,
    hasAuthoritativeTerminalEvent: Boolean(latestTerminalEvent && latestTerminalEvent.data?.source !== "electron")
  };
}

function listSessions(workspaceDir) {
  const { logsRoot, cyclesRoot } = getWorkspacePaths(workspaceDir);
  const sessionIds = new Set([...listDirectoryNames(logsRoot), ...listDirectoryNames(cyclesRoot)]);
  return [...sessionIds]
    .map((sessionId) => getSessionSummary(workspaceDir, sessionId))
    .sort((left, right) => new Date(right.lastActivityAt || right.updatedAt || 0).getTime() - new Date(left.lastActivityAt || left.updatedAt || 0).getTime());
}

function getSession(workspaceDir, sessionId) {
  const summary = getSessionSummary(workspaceDir, sessionId);
  const artifacts = collectSessionArtifacts(workspaceDir, sessionId);
  const runState = readJson(path.join(summary.sessionLogsDir, "run_state.json")) || {};
  const recentEvents = readNdjson(path.join(summary.sessionLogsDir, "events.ndjson"), 40);
  const pendingArtifacts = collectPendingSessionArtifacts(workspaceDir, sessionId, {
    sessionLogsDir: summary.sessionLogsDir,
    runState,
    sessionConfig: summary.sessionConfig,
    artifacts,
    status: summary.status,
    currentAction: summary.currentAction,
    metaReviewOutputFile: summary.metaReviewOutputFile,
    updatedAt: summary.updatedAt
  });
  const processInfo = buildProcessInfo(summary, runState);
  const logTail = summary.logFile ? readTail(summary.logFile, 120) : "";

  return {
    ...summary,
    runState,
    recentEvents,
    artifacts,
    pendingArtifacts,
    processInfo,
    logTail
  };
}

function readArtifact(workspaceDir, artifactPath, sessionId) {
  const resolvedPath = assertAllowedArtifactPath(workspaceDir, artifactPath, sessionId);
  const extension = path.extname(resolvedPath).toLowerCase();
  const content = safeReadFile(resolvedPath);
  const format = [".md", ".markdown"].includes(extension)
    ? "markdown"
    : extension === ".json"
      ? "json"
      : "text";

  return {
    path: resolvedPath,
    format,
    content
  };
}

function listHelpTopics() {
  return helpTopics.map((topic) => ({
    id: topic.id,
    title: topic.title
  }));
}

function readHelpTopic(topicId) {
  const topic = helpTopics.find((entry) => entry.id === topicId);
  if (!topic) {
    throw new Error(`Unknown help topic: ${topicId}`);
  }

  const filePath = path.join(helpDocsRoot, topic.fileName);
  if (!fs.existsSync(filePath)) {
    throw new Error(`Help file is missing: ${filePath}`);
  }
  const resolvedPath = assertAllowedPath(repoRoot, filePath);
  return {
    id: topic.id,
    title: topic.title,
    path: resolvedPath,
    format: "markdown",
    content: safeReadFile(resolvedPath)
  };
}

function writeSessionState(workspaceDir, sessionId, updates, options = {}) {
  const { logsRoot } = getWorkspacePaths(workspaceDir);
  const sessionLogsDir = path.join(logsRoot, sessionId);
  ensureDir(sessionLogsDir);

  const runStatePath = path.join(sessionLogsDir, "run_state.json");
  const timestamp = options.timestamp || new Date().toISOString();
  const current = readJson(runStatePath) || {
    schemaVersion: 1,
    sessionId,
    status: "unknown"
  };
  if (options.allowCreateStartedAt !== false && !current.startedAt && !Object.prototype.hasOwnProperty.call(updates, "startedAt")) {
    current.startedAt = timestamp;
  }
  const nextState = {
    ...current,
    ...updates,
    sessionId,
    updatedAt: timestamp
  };
  writeJsonFileAtomic(runStatePath, nextState);
  return nextState;
}

function getSessionConfigPath(workspaceDir, sessionId) {
  const { logsRoot } = getWorkspacePaths(workspaceDir);
  return path.join(logsRoot, sessionId, SESSION_CONFIG_FILE);
}

function readSessionConfig(workspaceDir, sessionId) {
  return readJson(getSessionConfigPath(workspaceDir, sessionId));
}

function writeSessionConfig(workspaceDir, sessionId, config, options = {}) {
  const filePath = getSessionConfigPath(workspaceDir, sessionId);
  if (!options.overwrite && fs.existsSync(filePath)) {
    return readJson(filePath);
  }

  const nextConfig = {
    workspaceDir: resolveWorkspaceDir(workspaceDir),
    promptDir: path.resolve(config.promptDir || defaultPromptDir),
    planFile: path.resolve(config.planFile),
    qcType: config.qcType || "code",
    maxIterations: Number(config.maxIterations ?? 10),
    maxPlanQCIterations: Number(config.maxPlanQCIterations ?? 5),
    skipPlanQC: Boolean(config.skipPlanQC),
    passOnMediumOnly: Boolean(config.passOnMediumOnly),
    historyIterations: Number(config.historyIterations ?? 2),
    reasoningEffort: config.reasoningEffort || "xhigh",
    claudeQCIterations: Number(config.claudeQCIterations ?? 0),
    deliberationMode: Boolean(config.deliberationMode),
    maxDeliberationRounds: Number(config.maxDeliberationRounds ?? 4),
    maxRetries: Number(config.maxRetries ?? 3),
    retryDelaySec: Number(config.retryDelaySec ?? 30),
    agentTimeoutSec: Number(config.agentTimeoutSec ?? 900),
    metaReview: Boolean(config.metaReview),
    metaReviewTargetFile: config.metaReviewTargetFile ? path.resolve(config.metaReviewTargetFile) : "",
    metaReviewChecklistFile: config.metaReviewChecklistFile ? path.resolve(config.metaReviewChecklistFile) : "",
    metaReviewOutputFile: config.metaReviewOutputFile ? path.resolve(config.metaReviewOutputFile) : ""
  };
  writeJsonFileAtomic(filePath, nextConfig);
  return nextConfig;
}

function appendSessionEvent(workspaceDir, sessionId, eventType, level = "info", data = {}, options = {}) {
  const { logsRoot } = getWorkspacePaths(workspaceDir);
  const sessionLogsDir = path.join(logsRoot, sessionId);
  ensureDir(sessionLogsDir);

  const eventsPath = path.join(sessionLogsDir, "events.ndjson");
  const payload = {
    timestamp: options.timestamp || new Date().toISOString(),
    sessionId,
    type: eventType,
    level,
    data
  };
  if (options.fields && typeof options.fields === "object") {
    for (const [key, value] of Object.entries(options.fields)) {
      if (value !== undefined) {
        payload[key] = value;
      }
    }
  }
  fs.appendFileSync(eventsPath, `${JSON.stringify(payload)}\n`, "utf8");
  return payload;
}

function buildSessionConfigFallback(workspaceDir, context = {}) {
  const {
    runState: rawRunState = {},
    recentEvents = [],
    latestStateEvent = null,
    latestTerminalEvent = null,
    latestCyclePlan = ""
  } = context;
  const runState = rawRunState || {};
  const pipelineStartedEvent = recentEvents
    .slice()
    .reverse()
    .find((event) => event.type === "pipeline_started") || null;

  const planFile =
    runState.planFile ||
    latestStateEvent?.data?.planFile ||
    pipelineStartedEvent?.data?.planFile ||
    latestCyclePlan ||
    "";

  if (!planFile) {
    return null;
  }

  return {
    workspaceDir: resolveWorkspaceDir(workspaceDir),
    promptDir:
      runState.promptDir ||
      latestStateEvent?.data?.promptDir ||
      pipelineStartedEvent?.data?.promptDir ||
      defaultPromptDir,
    planFile,
    qcType: runState.qcType || latestStateEvent?.data?.qcType || pipelineStartedEvent?.data?.qcType || "code",
    maxIterations: Number(runState.maxIterations || latestStateEvent?.data?.maxIterations || pipelineStartedEvent?.data?.maxIterations || 10),
    maxPlanQCIterations: Number(
      runState.maxPlanQCIterations ||
      latestStateEvent?.data?.maxPlanQCIterations ||
      pipelineStartedEvent?.data?.maxPlanQCIterations ||
      5
    ),
    skipPlanQC: Boolean(runState.skipPlanQC ?? latestStateEvent?.data?.skipPlanQC ?? pipelineStartedEvent?.data?.skipPlanQC),
    passOnMediumOnly: Boolean(
      runState.passOnMediumOnly ??
      latestStateEvent?.data?.passOnMediumOnly ??
      pipelineStartedEvent?.data?.passOnMediumOnly
    ),
    historyIterations: Number(
      runState.historyIterations ||
      latestStateEvent?.data?.historyIterations ||
      pipelineStartedEvent?.data?.historyIterations ||
      2
    ),
    reasoningEffort:
      runState.reasoningEffort ||
      latestStateEvent?.data?.reasoningEffort ||
      pipelineStartedEvent?.data?.reasoningEffort ||
      "xhigh",
    claudeQCIterations: Number(
      runState.claudeQCIterations ||
      latestStateEvent?.data?.claudeQCIterations ||
      pipelineStartedEvent?.data?.claudeQCIterations ||
      0
    ),
    metaReview: Boolean(
      runState.metaReview ??
      latestStateEvent?.data?.metaReview ??
      pipelineStartedEvent?.data?.metaReview
    ),
    metaReviewTargetFile:
      runState.metaReviewTargetFile ||
      latestStateEvent?.data?.metaReviewTargetFile ||
      pipelineStartedEvent?.data?.metaReviewTargetFile ||
      "",
    metaReviewChecklistFile:
      runState.metaReviewChecklistFile ||
      latestStateEvent?.data?.metaReviewChecklistFile ||
      pipelineStartedEvent?.data?.metaReviewChecklistFile ||
      "",
    metaReviewOutputFile:
      runState.metaReviewOutputFile ||
      latestStateEvent?.data?.metaReviewOutputFile ||
      pipelineStartedEvent?.data?.metaReviewOutputFile ||
      "",
    deliberationMode: Boolean(
      runState.deliberationMode ??
      latestStateEvent?.data?.deliberationMode ??
      pipelineStartedEvent?.data?.deliberationMode
    ),
    maxDeliberationRounds: Number(
      runState.maxDeliberationRounds ||
      latestStateEvent?.data?.maxDeliberationRounds ||
      pipelineStartedEvent?.data?.maxDeliberationRounds ||
      4
    ),
    maxRetries: Number(
      runState.maxRetries ||
      latestStateEvent?.data?.maxRetries ||
      pipelineStartedEvent?.data?.maxRetries ||
      3
    ),
    retryDelaySec: Number(
      runState.retryDelaySec ||
      latestStateEvent?.data?.retryDelaySec ||
      pipelineStartedEvent?.data?.retryDelaySec ||
      30
    ),
    agentTimeoutSec: Number(
      runState.agentTimeoutSec ||
      latestStateEvent?.data?.agentTimeoutSec ||
      pipelineStartedEvent?.data?.agentTimeoutSec ||
      900
    )
  };
}

function getResumeRunConfig(workspaceDir, sessionId, preloaded = null) {
  const data = preloaded || (() => {
    const { logsRoot, cyclesRoot } = getWorkspacePaths(workspaceDir);
    const sessionLogsDir = path.join(logsRoot, sessionId);
    const sessionCyclesDir = path.join(cyclesRoot, sessionId);
    const runState = readJson(path.join(sessionLogsDir, "run_state.json")) || {};
    const recentEvents = readNdjson(path.join(sessionLogsDir, "events.ndjson"), 200);
    const latestCyclePlan =
      getLatestFile(cyclesRoot, (name) => /^CONTINUATION_CYCLE_\d+\.md$/i.test(name)) ||
      getLatestFile(sessionCyclesDir, (name) => /^CONTINUATION_CYCLE_\d+\.md$/i.test(name));
    const eventState = deriveEventState(recentEvents);
    const latestStateEvent = eventState.latestStateEvent;
    const latestTerminalEvent = eventState.latestTerminalEvent;
    const sessionConfig = readSessionConfig(workspaceDir, sessionId) ||
      buildSessionConfigFallback(workspaceDir, {
        runState,
        recentEvents,
        latestStateEvent,
        latestTerminalEvent,
        latestCyclePlan
      });

    return {
      runState,
      recentEvents,
      artifacts: collectSessionArtifacts(workspaceDir, sessionId),
      latestCyclePlan,
      sessionConfig,
      status: runState.status || eventState.status || "unknown",
      latestStateEvent,
      latestTerminalEvent
    };
  })();

  let status = String(data.status || "").toLowerCase();
  if (status === "running" && data.runState?.childPid && !isProcessAlive(data.runState.childPid)) {
    status = data.latestTerminalEvent?.status || "stale";
  }
  if (!["failed", "stale", "cancelled"].includes(status)) {
    return { ok: false, reason: "Only failed, stale, or cancelled sessions can be resumed." };
  }

  if (!data.sessionConfig) {
    return { ok: false, reason: "This session is missing its launch config and could not be reconstructed." };
  }

  const isDeliberationResume = Boolean(data.sessionConfig.deliberationMode);
  const isMetaReviewRestart = Boolean(data.sessionConfig.metaReview);

  if (!isDeliberationResume && !isMetaReviewRestart) {
    return { ok: false, reason: "Resume is currently limited to deliberation or meta-review sessions." };
  }

  if (!["document", "code"].includes(data.sessionConfig.qcType)) {
    return {
      ok: false,
      reason: isDeliberationResume
        ? "Only document and code deliberation sessions are resumable."
        : "Only document and code sessions are resumable."
    };
  }

  if (isDeliberationResume) {
    const hasArtifacts = (data.artifacts || []).some((artifact) =>
      ["claude_thoughts", "codex_evaluation", "codex_review"].includes(artifact.kind)
    );
    const hasRoundEvent = (data.recentEvents || []).some((event) =>
      ["document_deliberation_round_started", "code_deliberation_round_started"].includes(event.type)
    );
    if (!hasArtifacts && !hasRoundEvent) {
      return { ok: false, reason: "This session has no saved deliberation state to resume from." };
    }
  }

  if (!data.sessionConfig.planFile) {
    return { ok: false, reason: "The original plan file for this session could not be recovered." };
  }

  return {
    ok: true,
    reason: "",
    config: {
      ...data.sessionConfig,
      workspaceDir: resolveWorkspaceDir(workspaceDir),
      sessionId,
      resumeFromFailure: isDeliberationResume
    }
  };
}

module.exports = {
  assertAllowedArtifactPath,
  assertAllowedPath,
  assertWorkspacePlanPath,
  appendSessionEvent,
  defaultPromptDir,
  ensureDir,
  executionRoot,
  getSession,
  getResumeRunConfig,
  getSessionSummary,
  getSessionConfigPath,
  getWorkspacePaths,
  isPathInside,
  listHelpTopics,
  listSessions,
  metaPlanChecklistPath,
  readArtifact,
  readHelpTopic,
  readSessionConfig,
  repoRoot,
  resolveWorkspaceDir,
  SECTION_LABELS,
  salvagePendingDeliberationOutputs,
  writeSessionConfig,
  writeSessionState
};


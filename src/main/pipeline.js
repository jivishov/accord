const fs = require("node:fs");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const {
  defaultPromptDir,
  ensureDir,
  executionRoot,
  getWorkspacePaths,
  metaPlanChecklistPath,
  resolveWorkspaceDir
} = require("./session-store");

const scriptPath = path.join(executionRoot, "accord.ps1");

function pad(value) {
  return String(value).padStart(2, "0");
}

function makeTimestamp(date = new Date()) {
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate())
  ].join("-") + `_${pad(date.getHours())}-${pad(date.getMinutes())}-${pad(date.getSeconds())}`;
}

function extractPlanTitle(planFilePath) {
  try {
    const content = fs.readFileSync(planFilePath, "utf8");
    const match = content.match(/^#\s+(?:Meta-?Plan:\s*)?(.+)/mi);
    return match ? match[1].trim().substring(0, 80) : "";
  } catch {
    return "";
  }
}

function resolvePlanFile(planFile, workspaceDir) {
  if (!planFile) {
    throw new Error("planFile is required.");
  }
  const resolvedPlanFile = path.resolve(resolveWorkspaceDir(workspaceDir), planFile);
  if (!fs.existsSync(resolvedPlanFile)) {
    throw new Error(`Plan file not found: ${resolvedPlanFile}`);
  }
  return resolvedPlanFile;
}

function getSessionIdForPlan(planFile, workspaceDir, fallbackDate = new Date()) {
  const resolvedWorkspaceDir = resolveWorkspaceDir(workspaceDir);
  const { cyclesRoot } = getWorkspacePaths(resolvedWorkspaceDir);
  const resolvedPlanFile = resolvePlanFile(planFile, resolvedWorkspaceDir);
  const relative = path.relative(cyclesRoot, resolvedPlanFile);
  const normalized = relative.replaceAll("/", "\\");
  const match = normalized.match(/^([^\\]+)\\CONTINUATION_CYCLE_\d+\.md$/i);
  if (match && !normalized.startsWith("..\\")) {
    return match[1];
  }
  return makeTimestamp(fallbackDate);
}

function getReviewedMetaPlanOutputPath(targetPlanFile) {
  const resolvedTargetPlanFile = path.resolve(targetPlanFile);
  const extension = path.extname(resolvedTargetPlanFile);
  const baseName = path.basename(resolvedTargetPlanFile, extension);
  const reviewedFileName = extension
    ? `${baseName}.reviewed${extension}`
    : `${baseName}.reviewed.md`;
  return path.join(path.dirname(resolvedTargetPlanFile), reviewedFileName);
}

function resolveMetaReviewConfig(config, workspaceDir, planFile) {
  if (!config.metaReview) {
    return {
      ...config,
      metaReview: false,
      metaReviewTargetFile: "",
      metaReviewChecklistFile: "",
      metaReviewOutputFile: ""
    };
  }

  const metaReviewChecklistFile = path.resolve(config.metaReviewChecklistFile || metaPlanChecklistPath);
  const metaReviewTargetFile = path.resolve(config.metaReviewTargetFile || planFile);
  const metaReviewOutputFile = path.resolve(
    config.metaReviewOutputFile || getReviewedMetaPlanOutputPath(metaReviewTargetFile)
  );

  if (!fs.existsSync(metaReviewChecklistFile)) {
    throw new Error(`Bundled meta-review checklist not found: ${metaReviewChecklistFile}`);
  }

  if (metaReviewTargetFile.toLowerCase() === metaReviewChecklistFile.toLowerCase()) {
    throw new Error("Review Meta Plan cannot use the bundled checklist file as the review target.");
  }

  return {
    ...config,
    qcType: "document",
    skipPlanQC: true,
    deliberationMode: false,
    metaReview: true,
    metaReviewTargetFile,
    metaReviewChecklistFile,
    metaReviewOutputFile
  };
}

function pushFlag(args, flagName, value) {
  if (value === undefined || value === null || value === "" || value === false) {
    return;
  }

  if (value === true) {
    args.push(`-${flagName}`);
    return;
  }

  args.push(`-${flagName}`, String(value));
}

function serializeConfigToArgs(config) {
  const args = [];
  pushFlag(args, "PlanFile", config.planFile);
  pushFlag(args, "PromptDir", config.promptDir);
  pushFlag(args, "QCType", config.qcType);
  pushFlag(args, "MaxIterations", config.maxIterations);
  pushFlag(args, "MaxPlanQCIterations", config.maxPlanQCIterations);
  pushFlag(args, "SkipPlanQC", config.skipPlanQC);
  pushFlag(args, "PassOnMediumOnly", config.passOnMediumOnly);
  pushFlag(args, "HistoryIterations", config.historyIterations);
  pushFlag(args, "ReasoningEffort", config.reasoningEffort);
  pushFlag(args, "ClaudeQCIterations", config.claudeQCIterations);
  pushFlag(args, "DeliberationMode", config.deliberationMode);
  pushFlag(args, "MaxDeliberationRounds", config.maxDeliberationRounds);
  pushFlag(args, "MaxRetries", config.maxRetries);
  pushFlag(args, "RetryDelaySec", config.retryDelaySec);
  pushFlag(args, "AgentTimeoutSec", config.agentTimeoutSec);
  pushFlag(args, "ResumeFromFailure", config.resumeFromFailure);
  pushFlag(args, "MetaReview", config.metaReview);
  pushFlag(args, "MetaReviewTargetFile", config.metaReviewTargetFile);
  pushFlag(args, "MetaReviewChecklistFile", config.metaReviewChecklistFile);
  pushFlag(args, "MetaReviewOutputFile", config.metaReviewOutputFile);
  return args;
}

function startPipelineRun(config) {
  const workspaceDir = resolveWorkspaceDir(config.workspaceDir);
  const planFile = resolvePlanFile(config.planFile, workspaceDir);
  const planTitle = extractPlanTitle(planFile);
  const promptDir = path.resolve(config.promptDir || defaultPromptDir);
  const pipelineStartTime = makeTimestamp();
  const sessionId = config.sessionId || getSessionIdForPlan(planFile, workspaceDir, new Date());
  const { logsRoot, cyclesRoot } = getWorkspacePaths(workspaceDir);
  const sessionLogsDir = path.join(logsRoot, sessionId);
  const sessionCyclesDir = path.join(cyclesRoot, sessionId);

  ensureDir(sessionLogsDir);
  ensureDir(sessionCyclesDir);

  const effectiveConfig = resolveMetaReviewConfig({
    ...config,
    workspaceDir,
    planFile,
    promptDir,
    sessionId
  }, workspaceDir, planFile);

  const args = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    scriptPath,
    ...serializeConfigToArgs(effectiveConfig)
  ];

  const child = spawn("powershell.exe", args, {
    cwd: workspaceDir,
    env: {
      ...process.env,
      CROSS_QC_SESSION_ID: sessionId,
      CROSS_QC_PIPELINE_START_TIME: pipelineStartTime,
      CROSS_QC_PLAN_TITLE: planTitle
    },
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true
  });

  child.stdout?.setEncoding("utf8");
  child.stderr?.setEncoding("utf8");

  return {
    child,
    effectiveConfig,
    pipelineStartTime,
    promptDir,
    planFile,
    sessionId,
    sessionLogsDir,
    sessionCyclesDir,
    workspaceDir
  };
}

function killProcessTree(pid) {
  const result = spawnSync("taskkill.exe", ["/PID", String(pid), "/T", "/F"], {
    windowsHide: true,
    encoding: "utf8"
  });

  return {
    ok: result.status === 0,
    stdout: result.stdout || "",
    stderr: result.stderr || ""
  };
}

module.exports = {
  defaultPromptDir,
  getSessionIdForPlan,
  getReviewedMetaPlanOutputPath,
  killProcessTree,
  makeTimestamp,
  resolveMetaReviewConfig,
  resolvePlanFile,
  scriptPath,
  serializeConfigToArgs,
  startPipelineRun
};


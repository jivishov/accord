const fs = require("node:fs");
const path = require("node:path");

const {
  appendSessionEvent,
  ensureDir,
  getSession,
  getWorkspacePaths,
  salvagePendingDeliberationOutputs,
  writeSessionState
} = require("./session-store");
const TERMINAL_SESSION_STATUSES = new Set(["cancelled", "completed", "failed", "stale"]);

function firstNonEmpty(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      return value;
    }
  }
  return "";
}

function firstFiniteNumber(...values) {
  for (const value of values) {
    const numericValue = Number(value);
    if (Number.isFinite(numericValue)) {
      return numericValue;
    }
  }
  return 0;
}

function padTimestampPart(value) {
  return String(value).padStart(2, "0");
}

function formatReadableLogTimestamp(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }

  return [
    date.getFullYear(),
    padTimestampPart(date.getMonth() + 1),
    padTimestampPart(date.getDate())
  ].join("-") + " " + [
    padTimestampPart(date.getHours()),
    padTimestampPart(date.getMinutes()),
    padTimestampPart(date.getSeconds())
  ].join(":");
}

function getLatestLogFile(sessionLogsDir) {
  if (!sessionLogsDir || !fs.existsSync(sessionLogsDir)) {
    return "";
  }

  return fs
    .readdirSync(sessionLogsDir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.startsWith("qc_log_"))
    .map((entry) => path.join(sessionLogsDir, entry.name))
    .sort((left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs)[0] || "";
}

function resolveCancellationLogFile(session, activeRun) {
  const preferredLogFile = activeRun?.sessionLogsDir && activeRun?.pipelineStartTime
    ? path.join(activeRun.sessionLogsDir, `qc_log_${activeRun.pipelineStartTime}.txt`)
    : "";

  return firstNonEmpty(
    preferredLogFile,
    session?.runState?.logFile,
    session?.logFile,
    getLatestLogFile(session?.sessionLogsDir || "")
  );
}

function appendCancellationLogLine(logFile, timestamp, message, pid) {
  if (!logFile) {
    return "";
  }

  ensureDir(path.dirname(logFile));
  const readableTimestamp = formatReadableLogTimestamp(timestamp);
  const pidSuffix = Number.isFinite(Number(pid)) ? ` PID: ${Number(pid)}` : "";
  fs.appendFileSync(logFile, `[${readableTimestamp}] [WARN] ${message}${pidSuffix}\n`, "utf8");
  return logFile;
}

function resolveCancelRequest({ activeRun, requestedPid, session }) {
  const pid = firstFiniteNumber(
    activeRun?.child?.pid,
    requestedPid,
    session?.runState?.childPid
  );
  return {
    pid: pid > 0 ? pid : 0,
    alreadyTerminal:
      !activeRun &&
      TERMINAL_SESSION_STATUSES.has(String(session?.status || "").trim().toLowerCase())
  };
}

function finalizeCancelledRun({ workspaceDir, sessionId, pid, activeRun, timestamp = new Date() }) {
  const session = getSession(workspaceDir, sessionId);
  const runState = session.runState || {};
  const cancelDate = timestamp instanceof Date ? timestamp : new Date(timestamp);
  const safeCancelDate = Number.isNaN(cancelDate.getTime()) ? new Date() : cancelDate;
  const cancelTimestamp = safeCancelDate.toISOString();
  const message = "Run cancelled from the desktop UI.";
  const logFile = resolveCancellationLogFile(session, activeRun);
  const salvageResult = salvagePendingDeliberationOutputs(workspaceDir, sessionId);
  const salvagedArtifacts = salvageResult.salvagedArtifacts || [];

  if (salvagedArtifacts.length > 0) {
    appendSessionEvent(
      workspaceDir,
      sessionId,
      "deliberation_temp_output_salvaged",
      "warn",
      {
        count: salvagedArtifacts.length,
        artifacts: salvagedArtifacts.map((artifact) => ({
          tempPath: artifact.path,
          artifactPath: artifact.artifactPath,
          artifactName: artifact.artifactName,
          kind: artifact.kind
        })),
        source: "electron",
        message: `Recovered ${salvagedArtifacts.length} pending deliberation Codex artifact(s) from temp output during cancellation.`
      },
      {
        timestamp: cancelTimestamp,
        fields: {
          pipelineId: runState.pipelineId || activeRun?.pipelineStartTime || "",
          phase: runState.phase || session.phase || "",
          status: runState.status || session.status || "running",
          currentIteration: firstFiniteNumber(runState.currentIteration, session.currentIteration),
          currentPlanQCIteration: firstFiniteNumber(runState.currentPlanQCIteration, session.currentPlanQCIteration),
          currentDeliberationRound: firstFiniteNumber(runState.currentDeliberationRound, session.currentDeliberationRound)
        }
      }
    );
  }

  const stateUpdates = {
    status: "cancelled",
    currentAction: "",
    currentTool: "",
    completedAt: cancelTimestamp,
    exitCode: 1,
    lastMessage: message,
    lastError: message
  };

  const phase = firstNonEmpty(runState.phase, session.phase);
  if (phase) {
    stateUpdates.phase = phase;
  }

  const planFile = firstNonEmpty(runState.planFile, session.planFile, activeRun?.planFile);
  if (planFile) {
    stateUpdates.planFile = planFile;
  }

  const promptDir = firstNonEmpty(runState.promptDir, activeRun?.promptDir);
  if (promptDir) {
    stateUpdates.promptDir = promptDir;
  }

  const pipelineId = firstNonEmpty(runState.pipelineId, activeRun?.pipelineStartTime);
  if (pipelineId) {
    stateUpdates.pipelineId = pipelineId;
  }

  const startedAt = firstNonEmpty(runState.startedAt, session.startedAt);
  if (startedAt) {
    stateUpdates.startedAt = startedAt;
  }

  const logsDir = firstNonEmpty(runState.logsDir, activeRun?.sessionLogsDir, session.sessionLogsDir);
  if (logsDir) {
    stateUpdates.logsDir = logsDir;
  }

  const cyclesDir = firstNonEmpty(runState.cyclesDir, activeRun?.sessionCyclesDir, session.sessionCyclesDir);
  if (cyclesDir) {
    stateUpdates.cyclesDir = cyclesDir;
  }

  if (logFile) {
    stateUpdates.logFile = logFile;
  }

  const childPid = firstFiniteNumber(runState.childPid, pid, activeRun?.child?.pid);
  if (childPid > 0) {
    stateUpdates.childPid = childPid;
  }

  stateUpdates.currentIteration = firstFiniteNumber(runState.currentIteration, session.currentIteration);
  stateUpdates.currentPlanQCIteration = firstFiniteNumber(runState.currentPlanQCIteration, session.currentPlanQCIteration);
  stateUpdates.currentDeliberationRound = firstFiniteNumber(runState.currentDeliberationRound, session.currentDeliberationRound);

  const nextState = writeSessionState(workspaceDir, sessionId, stateUpdates, {
    timestamp: cancelTimestamp,
    allowCreateStartedAt: false
  });

  const event = appendSessionEvent(
    workspaceDir,
    sessionId,
    "pipeline_cancelled",
    "warn",
    {
      message,
      pid: childPid > 0 ? childPid : undefined,
      source: "electron"
    },
    {
      timestamp: cancelTimestamp,
      fields: {
        pipelineId: nextState.pipelineId,
        phase: nextState.phase || "",
        status: nextState.status,
        currentIteration: nextState.currentIteration || 0,
        currentPlanQCIteration: nextState.currentPlanQCIteration || 0,
        currentDeliberationRound: nextState.currentDeliberationRound || 0
      }
    }
  );

  const appendedLogFile = appendCancellationLogLine(
    logFile,
    safeCancelDate,
    message,
    childPid > 0 ? childPid : undefined
  );

  return {
    event,
    logFile: appendedLogFile,
    nextState,
    salvagedArtifacts,
    timestamp: cancelTimestamp
  };
}

module.exports = {
  finalizeCancelledRun,
  formatReadableLogTimestamp,
  resolveCancelRequest
};

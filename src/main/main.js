const { app, BrowserWindow, dialog, ipcMain, shell } = require("electron");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const {
  appendSessionEvent,
  assertAllowedArtifactPath,
  assertWorkspacePlanPath,
  defaultPromptDir,
  getSession,
  getResumeRunConfig,
  getWorkspacePaths,
  listHelpTopics,
  listSessions,
  metaPlanChecklistPath,
  readHelpTopic,
  readArtifact,
  writeSessionConfig,
  repoRoot,
  resolveWorkspaceDir,
  writeSessionState
} = require("./session-store");
const {
  killProcessTree,
  scriptPath,
  startPipelineRun
} = require("./pipeline");
const { finalizeCancelledRun, resolveCancelRequest } = require("./cancel-run");
const {
  listProjectHistory,
  rememberProjectHistory,
  setProjectHistoryStorePath
} = require("./project-history-store");

let mainWindow = null;

const requiredPromptFiles = [
  "claude_write_prompt.md",
  "codex_qc_prompt.md",
  "claude_fix_prompt.md",
  "codex_plan_qc_prompt.md",
  "claude_plan_fix_prompt.md",
  "claude_write_doc_prompt.md",
  "codex_qc_doc_prompt.md",
  "claude_write_meta_review_prompt.md",
  "codex_qc_meta_review_prompt.md",
  "claude_fix_meta_review_prompt.md",
  "claude_deliberate_doc_initial_prompt.md",
  "claude_deliberate_doc_refine_prompt.md",
  "codex_deliberate_doc_prompt.md",
  "claude_deliberate_code_initial_prompt.md",
  "claude_deliberate_code_refine_prompt.md",
  "codex_deliberate_code_prompt.md"
];

const activeRuns = new Map();
const sessionWatches = new Map();
const isScreenshotCaptureMode = process.argv.includes("--capture-screenshots");

function getCliFlagValue(flagName) {
  const exactPrefix = `${flagName}=`;
  const inlineMatch = process.argv.find((entry) => entry.startsWith(exactPrefix));
  if (inlineMatch) {
    return inlineMatch.slice(exactPrefix.length);
  }

  const index = process.argv.indexOf(flagName);
  if (index >= 0 && index + 1 < process.argv.length) {
    const nextValue = process.argv[index + 1];
    if (!nextValue.startsWith("--")) {
      return nextValue;
    }
  }

  return "";
}

function resolveScreenshotOutputDir() {
  const cliValue = String(getCliFlagValue("--screenshot-dir") || "").trim();
  if (!cliValue) {
    return path.join(repoRoot, "docs", "screenshots");
  }

  return path.isAbsolute(cliValue)
    ? path.normalize(cliValue)
    : path.resolve(repoRoot, cliValue);
}

function waitForMs(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeCycleStatus(raw) {
  const completedCycles = Array.isArray(raw.completedCycles)
    ? raw.completedCycles.map(Number).filter(Number.isFinite).sort((a, b) => a - b)
    : [];

  const lastCompleted = typeof raw.lastCompleted === "number"
    ? raw.lastCompleted
    : (completedCycles.length > 0 ? Math.max(...completedCycles) : 0);

  const inProgressCycles = Array.isArray(raw.inProgressCycles)
    ? raw.inProgressCycles.map(Number).filter(Number.isFinite).sort((a, b) => a - b)
    : [];
  const pendingCycles = Array.isArray(raw.pendingCycles)
    ? raw.pendingCycles.map(Number).filter(Number.isFinite).sort((a, b) => a - b)
    : [];

  let currentCycle;
  if (typeof raw.currentCycle === "number" && raw.currentCycle > 0) {
    currentCycle = raw.currentCycle;
  } else if (inProgressCycles.length > 0) {
    currentCycle = inProgressCycles[0];
  } else if (pendingCycles.length > 0) {
    currentCycle = pendingCycles[0];
  } else {
    currentCycle = lastCompleted + 1;
  }

  return {
    currentCycle,
    completedCycles,
    lastCompleted,
    lastCompletedAt: raw.lastCompletedAt || null,
    pendingCycles,
    inProgressCycles
  };
}

function hasAllPromptFiles(directoryPath) {
  if (!directoryPath || !fs.existsSync(directoryPath)) {
    return false;
  }
  return requiredPromptFiles.every((fileName) => fs.existsSync(path.join(directoryPath, fileName)));
}

function resolvePromptDirForCheck(promptDir) {
  const requestedDir = path.resolve(promptDir || defaultPromptDir);
  if (hasAllPromptFiles(requestedDir)) {
    return requestedDir;
  }

  const promptsChild = path.join(requestedDir, "prompts");
  if (hasAllPromptFiles(promptsChild)) {
    return promptsChild;
  }

  return requestedDir;
}

function locateCommand(commandName) {
  if (commandName === "node") {
    return {
      name: "node",
      available: true,
      location: process.execPath,
      version: process.version
    };
  }

  const whereResult = spawnSync("where.exe", [commandName], {
    windowsHide: true,
    encoding: "utf8"
  });

  if (whereResult.status !== 0) {
    return {
      name: commandName,
      available: false,
      location: "",
      version: "",
      error: (whereResult.stderr || whereResult.stdout || "Not found.").trim()
    };
  }

  const location = (whereResult.stdout || "").split(/\r?\n/).find(Boolean) || "";
  let version = "";
  if (commandName === "powershell.exe") {
    const versionResult = spawnSync("powershell.exe", ["-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"], {
      windowsHide: true,
      encoding: "utf8"
    });
    version = (versionResult.stdout || "").trim();
  } else {
    const versionResult = spawnSync(commandName, ["--version"], {
      windowsHide: true,
      encoding: "utf8"
    });
    version = (versionResult.stdout || versionResult.stderr || "").trim();
  }

  return {
    name: commandName,
    available: true,
    location,
    version
  };
}

function checkEnvironment(workspaceDir, promptDir) {
  const resolvedWorkspaceDir = resolveWorkspaceDir(workspaceDir);
  const resolvedPromptDir = resolvePromptDirForCheck(promptDir);
  const promptFiles = requiredPromptFiles.map((fileName) => {
    const fullPath = path.join(resolvedPromptDir, fileName);
    return {
      name: fileName,
      path: fullPath,
      exists: fs.existsSync(fullPath)
    };
  });

  return {
    workspaceDir: resolvedWorkspaceDir,
    promptDir: resolvedPromptDir,
    scriptPath,
    commands: [
      locateCommand("powershell.exe"),
      locateCommand("node"),
      locateCommand("claude"),
      locateCommand("codex"),
      locateCommand("git")
    ],
    promptFiles,
    promptDirExists: fs.existsSync(resolvedPromptDir)
  };
}

function emitWatchedSession(workspaceDir, sessionId) {
  for (const watch of sessionWatches.values()) {
    if (watch.workspaceDir !== workspaceDir || watch.sessionId !== sessionId) {
      continue;
    }
    if (watch.sender.isDestroyed()) {
      clearInterval(watch.timer);
      sessionWatches.delete(watch.key);
      continue;
    }
    watch.sender.send("session:watch-update", {
      workspaceDir,
      sessionId,
      session: getSession(workspaceDir, sessionId)
    });
  }
}

function attachRunLifecycle(runInfo) {
  const { child, sessionId, workspaceDir } = runInfo;
  const output = {
    stdout: "",
    stderr: ""
  };

  child.stdout?.on("data", (chunk) => {
    output.stdout += chunk;
  });
  child.stderr?.on("data", (chunk) => {
    output.stderr += chunk;
  });

  child.once("error", (error) => {
    activeRuns.delete(sessionId);
    if (runInfo.cancelRequestedAt) {
      emitWatchedSession(workspaceDir, sessionId);
      return;
    }
    writeSessionState(workspaceDir, sessionId, {
      status: "failed",
      completedAt: new Date().toISOString(),
      currentAction: "",
      currentTool: "",
      exitCode: 1,
      lastError: error.message
    });
    appendSessionEvent(workspaceDir, sessionId, "pipeline_failed", "error", {
      message: error.message,
      source: "electron"
    });
    emitWatchedSession(workspaceDir, sessionId);
  });

  child.once("exit", (code, signal) => {
    activeRuns.delete(sessionId);
    if (runInfo.cancelRequestedAt) {
      emitWatchedSession(workspaceDir, sessionId);
      return;
    }
    const session = getSession(workspaceDir, sessionId);
    const runState = session.runState || {};
    const shouldBackfillStatus =
      !session.hasAuthoritativeTerminalEvent &&
      (!runState.status || runState.status === "running" || session.status === "stale");

    if (shouldBackfillStatus) {
      const success = code === 0;
      writeSessionState(workspaceDir, sessionId, {
        status: success ? "completed" : "failed",
        completedAt: new Date().toISOString(),
        currentAction: "",
        currentTool: "",
        exitCode: code ?? 1,
        lastError: success ? "" : (output.stderr.trim() || `Process exited with code ${code ?? 1}.`)
      });
      appendSessionEvent(workspaceDir, sessionId, success ? "pipeline_completed" : "pipeline_failed", success ? "info" : "error", {
        exitCode: code ?? 1,
        signal: signal || "",
        source: "electron"
      });
    }

    emitWatchedSession(workspaceDir, sessionId);
  });
}

function beginSessionWatch(sender, workspaceDir, sessionId) {
  const key = `${sender.id}:${workspaceDir}:${sessionId}`;
  const existing = sessionWatches.get(key);
  if (existing) {
    clearInterval(existing.timer);
  }

  const watch = {
    key,
    sender,
    sessionId,
    workspaceDir,
    timer: null
  };
  watch.timer = setInterval(() => emitWatchedSession(workspaceDir, sessionId), 1500);
  sessionWatches.set(key, watch);
  emitWatchedSession(workspaceDir, sessionId);
}

function endSessionWatch(sender, workspaceDir, sessionId) {
  const key = `${sender.id}:${workspaceDir}:${sessionId}`;
  const existing = sessionWatches.get(key);
  if (!existing) {
    return;
  }
  clearInterval(existing.timer);
  sessionWatches.delete(key);
}

function registerIpcHandlers() {
  ipcMain.handle("app:get-defaults", async () => ({
    repoRoot,
    defaultPromptDir,
    defaultWorkspaceDir: repoRoot,
    metaPlanChecklistPath,
    scriptPath
  }));

  ipcMain.handle("environment:check", async (_event, payload = {}) =>
    checkEnvironment(payload.workspaceDir, payload.promptDir)
  );

  ipcMain.handle("sessions:list", async (_event, payload = {}) =>
    listSessions(payload.workspaceDir)
  );

  ipcMain.handle("sessions:get", async (_event, payload = {}) =>
    getSession(payload.workspaceDir, payload.sessionId)
  );

  ipcMain.handle("project-history:list", async () =>
    listProjectHistory()
  );

  ipcMain.handle("project-history:remember", async (_event, payload = {}) =>
    rememberProjectHistory(payload.config, payload.metadata)
  );

  ipcMain.handle("run:start", async (_event, payload = {}) => {
    const runInfo = startPipelineRun(payload);
    writeSessionConfig(runInfo.workspaceDir, runInfo.sessionId, runInfo.effectiveConfig, {
      overwrite: false
    });
    writeSessionState(runInfo.workspaceDir, runInfo.sessionId, {
      status: "running",
      phase: "startup",
      currentAction: "spawning_pipeline",
      currentTool: "",
      childPid: runInfo.child.pid,
      pipelineId: runInfo.pipelineStartTime,
      startedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      promptDir: runInfo.promptDir,
      planFile: runInfo.planFile,
      metaReview: Boolean(runInfo.effectiveConfig.metaReview),
      metaReviewTargetFile: runInfo.effectiveConfig.metaReviewTargetFile || "",
      metaReviewChecklistFile: runInfo.effectiveConfig.metaReviewChecklistFile || "",
      metaReviewOutputFile: runInfo.effectiveConfig.metaReviewOutputFile || "",
      agentTimeoutSec: Number(runInfo.effectiveConfig.agentTimeoutSec || 900),
      logsDir: runInfo.sessionLogsDir,
      cyclesDir: runInfo.sessionCyclesDir
    });
    appendSessionEvent(runInfo.workspaceDir, runInfo.sessionId, "pipeline_spawned", "info", {
      pid: runInfo.child.pid,
      pipelineId: runInfo.pipelineStartTime
    });
    rememberProjectHistory(runInfo.effectiveConfig, {
      sessionId: runInfo.sessionId,
      status: "running",
      updatedAt: new Date().toISOString()
    });
    activeRuns.set(runInfo.sessionId, runInfo);
    attachRunLifecycle(runInfo);
    return {
      sessionId: runInfo.sessionId,
      workspaceDir: runInfo.workspaceDir,
      sessionLogsDir: runInfo.sessionLogsDir,
      sessionCyclesDir: runInfo.sessionCyclesDir,
      pipelineStartTime: runInfo.pipelineStartTime,
      pid: runInfo.child.pid
    };
  });

  ipcMain.handle("run:resume", async (_event, payload = {}) => {
    const resumeConfigResult = getResumeRunConfig(payload.workspaceDir, payload.sessionId);
    if (!resumeConfigResult.ok) {
      throw new Error(resumeConfigResult.reason);
    }

    const runInfo = startPipelineRun(resumeConfigResult.config);
    const isTrueResume = Boolean(runInfo.effectiveConfig.resumeFromFailure);
    writeSessionConfig(runInfo.workspaceDir, runInfo.sessionId, runInfo.effectiveConfig, {
      overwrite: false
    });
    writeSessionState(runInfo.workspaceDir, runInfo.sessionId, {
      status: "running",
      phase: "startup",
      currentAction: isTrueResume ? "resuming_pipeline" : "restarting_pipeline",
      currentTool: "",
      childPid: runInfo.child.pid,
      pipelineId: runInfo.pipelineStartTime,
      updatedAt: new Date().toISOString(),
      promptDir: runInfo.promptDir,
      planFile: runInfo.planFile,
      metaReview: Boolean(runInfo.effectiveConfig.metaReview),
      metaReviewTargetFile: runInfo.effectiveConfig.metaReviewTargetFile || "",
      metaReviewChecklistFile: runInfo.effectiveConfig.metaReviewChecklistFile || "",
      metaReviewOutputFile: runInfo.effectiveConfig.metaReviewOutputFile || "",
      agentTimeoutSec: Number(runInfo.effectiveConfig.agentTimeoutSec || 900),
      logsDir: runInfo.sessionLogsDir,
      cyclesDir: runInfo.sessionCyclesDir,
      resumeFromFailure: isTrueResume,
      resumedAt: new Date().toISOString()
    });
    appendSessionEvent(runInfo.workspaceDir, runInfo.sessionId, "pipeline_spawned", "info", {
      pid: runInfo.child.pid,
      pipelineId: runInfo.pipelineStartTime,
      resumed: true,
      resumeFromFailure: isTrueResume
    });
    rememberProjectHistory(runInfo.effectiveConfig, {
      sessionId: runInfo.sessionId,
      status: "running",
      updatedAt: new Date().toISOString()
    });
    activeRuns.set(runInfo.sessionId, runInfo);
    attachRunLifecycle(runInfo);
    return {
      sessionId: runInfo.sessionId,
      workspaceDir: runInfo.workspaceDir,
      sessionLogsDir: runInfo.sessionLogsDir,
      sessionCyclesDir: runInfo.sessionCyclesDir,
      pipelineStartTime: runInfo.pipelineStartTime,
      pid: runInfo.child.pid
    };
  });

  ipcMain.handle("run:cancel", async (_event, payload = {}) => {
    const workspaceDir = resolveWorkspaceDir(payload.workspaceDir);
    const sessionId = payload.sessionId;
    const activeRun = activeRuns.get(sessionId);
    const session = sessionId ? getSession(workspaceDir, sessionId) : null;
    const sessionExists = Boolean(
      sessionId &&
      (
        activeRun ||
        fs.existsSync(session?.sessionLogsDir || "") ||
        fs.existsSync(session?.sessionCyclesDir || "")
      )
    );
    const cancelRequest = resolveCancelRequest({
      activeRun,
      requestedPid: payload.pid,
      session
    });
    const pid = cancelRequest.pid;
    const cancelTimestamp = new Date().toISOString();

    if (!sessionExists) {
      return { ok: false, message: "Session not found." };
    }

    if (!pid) {
      if (cancelRequest.alreadyTerminal) {
        rememberProjectHistory(session?.sessionConfig || { workspaceDir }, {
          sessionId,
          status: session?.status || "cancelled",
          updatedAt: session?.updatedAt || cancelTimestamp
        });
        emitWatchedSession(workspaceDir, sessionId);
        return { ok: true };
      }
      return { ok: false, message: "No running process found for this session." };
    }

    if (activeRun) {
      activeRun.cancelRequestedAt = cancelTimestamp;
    }

    const result = killProcessTree(pid);
    if (!result.ok) {
      if (activeRun) {
        delete activeRun.cancelRequestedAt;
      }
      return { ok: false, message: result.stderr || result.stdout || "Failed to stop process." };
    }

    const finalized = finalizeCancelledRun({
      workspaceDir,
      sessionId,
      pid,
      activeRun,
      timestamp: cancelTimestamp
    });
    rememberProjectHistory(activeRun?.effectiveConfig || getSession(workspaceDir, sessionId).sessionConfig, {
      sessionId,
      status: "cancelled",
      updatedAt: finalized.timestamp
    });
    emitWatchedSession(workspaceDir, sessionId);

    return { ok: true };
  });

  ipcMain.handle("artifact:read", async (_event, payload = {}) =>
    readArtifact(payload.workspaceDir, payload.path, payload.sessionId)
  );

  ipcMain.handle("artifact:open", async (_event, payload = {}) => {
    const allowedPath = assertAllowedArtifactPath(payload.workspaceDir, payload.path, payload.sessionId);
    const errorMessage = await shell.openPath(allowedPath);
    return {
      ok: errorMessage.length === 0,
      message: errorMessage
    };
  });

  ipcMain.handle("help:list", async () => listHelpTopics());

  ipcMain.handle("help:read", async (_event, payload = {}) =>
    readHelpTopic(payload.topicId)
  );

  ipcMain.handle("plan:save", async (_event, payload = {}) => {
    const workspaceDir = resolveWorkspaceDir(payload.workspaceDir);
    const requestedFileName = String(payload.fileName || "meta_plan.md").trim() || "meta_plan.md";
    const fileName = requestedFileName.replace(/[<>:"|?*]/g, "_");
    const content = payload.content || "";

    if (!fileName || fileName === "." || fileName === ".." || path.basename(fileName) !== fileName) {
      return {
        ok: false,
        message: "Plan file names must be a single filename inside the selected workspace directory."
      };
    }

    let targetPath;
    try {
      targetPath = assertWorkspacePlanPath(workspaceDir, fileName);
    } catch (error) {
      return { ok: false, message: error.message };
    }

    if (!fs.existsSync(workspaceDir)) {
      fs.mkdirSync(workspaceDir, { recursive: true });
    }

    fs.writeFileSync(targetPath, content, "utf8");
    return { ok: true, path: targetPath };
  });

  ipcMain.handle("plan:read", async (_event, payload = {}) => {
    const filePath = payload.filePath;
    if (!filePath) return { ok: false, message: "No file path specified." };

    let resolvedPath;
    try {
      resolvedPath = assertWorkspacePlanPath(payload.workspaceDir, filePath);
    } catch (error) {
      return { ok: false, message: error.message };
    }

    if (!fs.existsSync(resolvedPath)) {
      return { ok: false, message: `File not found: ${resolvedPath}` };
    }
    try {
      const content = fs.readFileSync(resolvedPath, "utf8");
      return { ok: true, content, path: resolvedPath };
    } catch (err) {
      return { ok: false, message: err.message };
    }
  });

  ipcMain.handle("plan:write", async (_event, payload = {}) => {
    const absolutePath = payload.absolutePath;
    const content = payload.content || "";
    if (!absolutePath) return { ok: false, message: "No absolute path specified." };
    if (!path.isAbsolute(absolutePath)) {
      return { ok: false, message: "Plan write path must be absolute." };
    }

    try {
      const resolvedPath = assertWorkspacePlanPath(payload.workspaceDir, absolutePath);
      fs.writeFileSync(resolvedPath, content, "utf8");
      return { ok: true, path: resolvedPath };
    } catch (err) {
      return { ok: false, message: err.message };
    }
  });

  ipcMain.handle("dialog:pick-plan", async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
      title: "Select Plan File",
      filters: [
        { name: "Markdown", extensions: ["md"] },
        { name: "All Files", extensions: ["*"] }
      ],
      properties: ["openFile"]
    });
    return result.canceled ? "" : result.filePaths[0];
  });

  ipcMain.handle("dialog:pick-directory", async (_event, payload = {}) => {
    const result = await dialog.showOpenDialog(mainWindow, {
      title: "Select Directory",
      defaultPath: payload.initialPath || repoRoot,
      properties: ["openDirectory"]
    });
    return result.canceled ? "" : result.filePaths[0];
  });

  ipcMain.handle("cycles:read-status", async (_event, payload = {}) => {
    const workspaceDir = resolveWorkspaceDir(payload.workspaceDir);
    const { cyclesRoot } = getWorkspacePaths(workspaceDir);
    const defaults = { currentCycle: 0, completedCycles: [], lastCompleted: 0, lastCompletedAt: null };

    // PowerShell Out-File -Encoding UTF8 writes a BOM; strip it before JSON.parse.
    const readJsonStripBom = (filePath) => {
      const raw = fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "");
      return JSON.parse(raw);
    };

    const candidates = [
      path.join(cyclesRoot, "_CYCLE_STATUS.json"),
      path.join(workspaceDir, "_CYCLE_STATUS.json")
    ];

    for (const statusPath of candidates) {
      if (fs.existsSync(statusPath)) {
        try {
          return normalizeCycleStatus(readJsonStripBom(statusPath));
        } catch {
          continue;
        }
      }
    }

    // Fallback: scan session-local _CYCLE_STATUS.json files (the canonical file
    // may not exist if Update-CanonicalCycleRegistry never created it).
    try {
      const entries = fs.readdirSync(cyclesRoot, { withFileTypes: true });
      let latestPath = null;
      let latestMtime = 0;
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        const statusPath = path.join(cyclesRoot, entry.name, "_CYCLE_STATUS.json");
        try {
          const stat = fs.statSync(statusPath);
          if (stat.mtimeMs > latestMtime) {
            latestMtime = stat.mtimeMs;
            latestPath = statusPath;
          }
        } catch { continue; }
      }
      if (latestPath) {
        return normalizeCycleStatus(readJsonStripBom(latestPath));
      }
    } catch { /* ignore */ }

    return defaults;
  });

  ipcMain.on("session:watch", (event, payload = {}) => {
    beginSessionWatch(event.sender, resolveWorkspaceDir(payload.workspaceDir), payload.sessionId);
  });

  ipcMain.on("session:unwatch", (event, payload = {}) => {
    endSessionWatch(event.sender, resolveWorkspaceDir(payload.workspaceDir), payload.sessionId);
  });
}

async function waitForRendererReady(windowRef) {
  await windowRef.webContents.executeJavaScript(
    `
      new Promise((resolve, reject) => {
        const startedAt = Date.now();
        const timeoutMs = 15000;
        const requiredIds = ["leftTabSessions", "leftTabConfigure", "leftTabWizard", "rightTabDashboard"];

        const checkReady = () => {
          const allPresent = requiredIds.every((id) => Boolean(document.getElementById(id)));
          if (allPresent) {
            resolve(true);
            return;
          }

          if (Date.now() - startedAt > timeoutMs) {
            reject(new Error("Renderer did not reach ready state for screenshot capture."));
            return;
          }

          window.setTimeout(checkReady, 100);
        };

        checkReady();
      });
    `,
    true
  );
}

async function setUiPanelState(windowRef, leftPanelId, rightPanelId) {
  const rightTabId = rightPanelId || "rightTabDashboard";
  await windowRef.webContents.executeJavaScript(
    `
      (() => {
        const leftButton = document.getElementById(${JSON.stringify(leftPanelId)});
        const rightButton = document.getElementById(${JSON.stringify(rightTabId)});
        if (!leftButton) {
          throw new Error("Missing left panel button: " + ${JSON.stringify(leftPanelId)});
        }
        if (!rightButton) {
          throw new Error("Missing right panel button: " + ${JSON.stringify(rightTabId)});
        }
        leftButton.click();
        rightButton.click();
      })();
    `,
    true
  );
}

async function captureWindowPng(windowRef, absoluteOutputPath) {
  const image = await windowRef.webContents.capturePage();
  fs.writeFileSync(absoluteOutputPath, image.toPNG());
}

async function runScreenshotCapture(windowRef) {
  const outputDir = resolveScreenshotOutputDir();
  const outputFiles = [
    {
      fileName: "dashboard.png",
      leftPanelId: "leftTabSessions",
      rightPanelId: "rightTabDashboard"
    },
    {
      fileName: "configure.png",
      leftPanelId: "leftTabConfigure",
      rightPanelId: "rightTabDashboard"
    },
    {
      fileName: "wizard.png",
      leftPanelId: "leftTabWizard",
      rightPanelId: "rightTabDashboard"
    }
  ];

  fs.mkdirSync(outputDir, { recursive: true });
  await waitForRendererReady(windowRef);
  await waitForMs(300);

  for (const captureTarget of outputFiles) {
    await setUiPanelState(windowRef, captureTarget.leftPanelId, captureTarget.rightPanelId);
    await waitForMs(350);
    const outputPath = path.join(outputDir, captureTarget.fileName);
    await captureWindowPng(windowRef, outputPath);
    console.log(`[screenshots] Saved ${outputPath}`);
  }
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1540,
    height: 980,
    minWidth: 1200,
    minHeight: 760,
    show: true,
    backgroundColor: "#efe6d7",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, "preload.js")
    }
  });

  mainWindow.loadFile(path.join(repoRoot, "src", "renderer", "index.html"));
  return mainWindow;
}

app.whenReady().then(() => {
  setProjectHistoryStorePath(path.join(app.getPath("userData"), "project-history.json"));
  registerIpcHandlers();
  createWindow();

  if (isScreenshotCaptureMode) {
    runScreenshotCapture(mainWindow)
      .then(() => {
        app.exit(0);
      })
      .catch((error) => {
        console.error(`[screenshots] Capture failed: ${error?.message || error}`);
        app.exit(1);
      });
    return;
  }

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

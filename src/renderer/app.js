const META_PLAN_TEMPLATE = `# Meta-Plan: [Your Project Title]

## Goal
[One or two sentences describing what you want to build or accomplish.]

## Features
1. [Feature or requirement 1]
2. [Feature or requirement 2]
3. [Feature or requirement 3]

## Constraints
- [Constraint 1, e.g. language, framework, compatibility]
- [Constraint 2, e.g. performance, security requirements]

## Context
- [Relevant existing files or architecture notes]
- [Dependencies or APIs to integrate with]

## Output
[What the generated continuation cycle plan should contain — e.g. file paths, function signatures, test cases.]
`;

const state = {
  defaults: null,
  environment: null,
  helpTopics: [],
  projectHistory: [],
  sessions: [],
  selectedSession: null,
  selectedHelpTopic: null,
  selectedArtifact: null,
  helpReturn: null,
  viewerMode: "artifact",
  leftPanel: "sessions",
  rightPanel: "dashboard",
  unwatchSession: null,
  editorDirty: false,
  editorAbsolutePath: null,
  wizard: {
    currentStep: 1,
    planFilePath: "",
    planReviewed: false,
    reviewSessionId: null,
    reviewedPlanPath: "",
    cycleStatus: null,
    currentCycleFile: "",
    currentCycleNumber: 0,
    lastRunSessionId: null,
    lastRunType: null,
    isRunning: false,
    unwatchWizardSession: null
  }
};

const elements = {};
const THEME_STORAGE_KEY = "crossqc-theme";
const bundledHelpTopics = [
  {
    id: "quick-start",
    title: "Quick Start",
    fileName: "quick-start.md",
    previewContent: "# Quick Start\n\nUse the command deck to pick your target project directory, choose a plan file, and start a run. Review Meta Plan checks the selected meta plan against the bundled checklist and writes a sibling `*.reviewed.md` file."
  },
  {
    id: "desktop-guide",
    title: "Desktop Guide",
    fileName: "desktop-guide.md",
    previewContent: "# Desktop Guide\n\nThe session rail selects runs. The command deck starts runs. Review Meta Plan uses the selected file as the source meta plan and leaves the original unchanged."
  },
  {
    id: "pipeline-and-modes",
    title: "Pipeline & Modes",
    fileName: "pipeline-and-modes.md",
    previewContent: "# Pipeline & Modes\n\nUse `code` mode for implementation tasks and `document` mode for plan or document generation. Failed deliberation sessions can resume from saved round state."
  }
];
const api = window.crossQc || {
  getDefaults: async () => ({
    defaultWorkspaceDir: "Preview mode",
    defaultPromptDir: "Preview mode",
    metaPlanChecklistPath: "Preview mode"
  }),
  checkEnvironment: async (payload) => ({
    workspaceDir: payload.workspaceDir || "Preview mode",
    promptDir: payload.promptDir || "Preview mode",
    commands: [
      { name: "powershell.exe", available: false, error: "Electron preload unavailable." },
      { name: "node", available: true, version: "Preview" },
      { name: "claude", available: false, error: "Electron preload unavailable." },
      { name: "codex", available: false, error: "Electron preload unavailable." },
      { name: "git", available: false, error: "Electron preload unavailable." }
    ],
    promptFiles: [],
    promptDirExists: false
  }),
  listSessions: async () => [],
  getSession: async (_payload) => ({
    sessionId: "",
    artifacts: [],
    pendingArtifacts: [],
    pendingArtifactCount: 0,
    recentEvents: [],
    runState: {},
    processInfo: {
      pid: 0,
      alive: false,
      startedAt: null,
      currentAction: "",
      currentTool: "",
      lastActivityAt: null,
      idleDurationMs: 0,
      state: "unavailable",
      stateLabel: "Unavailable",
      children: []
    }
  }),
  listProjectHistory: async () => [],
  rememberProjectHistory: async () => [],
  startRun: async () => {
    throw new Error("Desktop API unavailable outside Electron.");
  },
  resumeRun: async () => {
    throw new Error("Desktop API unavailable outside Electron.");
  },
  cancelRun: async () => ({ ok: false, message: "Desktop API unavailable outside Electron." }),
  readArtifact: async () => ({ path: "", format: "text", content: "" }),
  openArtifact: async () => ({ ok: false, message: "Desktop API unavailable outside Electron." }),
  listHelpTopics: async () => bundledHelpTopics.map(({ id, title }) => ({ id, title })),
  readHelpTopic: async (topicId) => {
    const topic = bundledHelpTopics.find((entry) => entry.id === topicId) || bundledHelpTopics[0];
    return {
      id: topic.id,
      title: topic.title,
      path: `Preview help/${topic.id}.md`,
      format: "markdown",
      content: topic.previewContent || "# Help\n\nPreview content unavailable."
    };
  },
  savePlan: async () => ({ ok: false, message: "Desktop API unavailable outside Electron." }),
  readPlan: async () => ({ ok: false, message: "Desktop API unavailable outside Electron." }),
  writePlan: async () => ({ ok: false, message: "Desktop API unavailable outside Electron." }),
  pickPlanFile: async () => "",
  pickDirectory: async () => "",
  watchSession: () => () => {}
};

function $(id) {
  return document.getElementById(id);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** Best display title for a session: planTitle → cycle plan name → plan filename → sessionId. */
function getSessionDisplayTitle(session) {
  const title = session.planTitle || "";
  // Use planTitle if it's a real title (not a template with [NN], [Cycle Title] placeholders)
  if (title && !/\[[A-Z][A-Za-z\s]*\]/.test(title)) return title;
  // For document_deliberation sessions, use the generated cycle plan name
  if (session.latestCyclePlan) {
    return session.latestCyclePlan.split(/[/\\]/).pop().replace(/\.md$/i, "");
  }
  // Show the plan filename
  if (session.planFile) {
    return session.planFile.split(/[/\\]/).pop();
  }
  return session.sessionId;
}

function normalizePathValue(value) {
  return String(value || "")
    .trim()
    .replaceAll("/", "\\")
    .replace(/\\+$/, "")
    .toLowerCase();
}

function resolveConfiguredPath(value, baseDir) {
  const raw = String(value || "").trim();
  if (!raw) {
    return "";
  }
  if (/^[a-zA-Z]:[\\/]/.test(raw) || raw.startsWith("\\\\")) {
    return normalizePathValue(raw);
  }
  const separator = baseDir && /[\\/]$/.test(baseDir) ? "" : "\\";
  return normalizePathValue(`${String(baseDir || "").trim()}${separator}${raw}`);
}

function isPathInsideWorkspace(candidatePath, workspaceDir) {
  const normalizedCandidate = normalizePathValue(candidatePath);
  const normalizedWorkspace = normalizePathValue(workspaceDir);
  if (!normalizedCandidate || !normalizedWorkspace) {
    return false;
  }
  return normalizedCandidate === normalizedWorkspace || normalizedCandidate.startsWith(`${normalizedWorkspace}\\`);
}

function padTimestampPart(value) {
  return String(value).padStart(2, "0");
}

function formatCompactTimestamp(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return "unknown";
  }

  const parsed = new Date(raw);
  if (!Number.isNaN(parsed.getTime())) {
    return [
      parsed.getFullYear(),
      padTimestampPart(parsed.getMonth() + 1),
      padTimestampPart(parsed.getDate())
    ].join("-") + " " + [
      padTimestampPart(parsed.getHours()),
      padTimestampPart(parsed.getMinutes()),
      padTimestampPart(parsed.getSeconds())
    ].join(":");
  }

  const isoMatch = raw.match(/^(\d{4}-\d{2}-\d{2})[T_](\d{2}):?(\d{2}):?(\d{2})/);
  if (isoMatch) {
    return `${isoMatch[1]} ${isoMatch[2]}:${isoMatch[3]}:${isoMatch[4]}`;
  }

  return raw;
}

function formatEventTimeDisplay(value) {
  if (window.CrossQcTime?.formatEventTimestamp) {
    return window.CrossQcTime.formatEventTimestamp(value);
  }

  const raw = String(value || "").trim();
  return {
    label: raw || "unknown",
    title: raw
  };
}

function sanitizeViewerText(value) {
  return String(value || "")
    .replace(/^\uFEFF/, "")
    .replace(/\u001B\][^\u0007]*(?:\u0007|\u001B\\)/g, "")
    .replace(/\u001B\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "");
}

function looksLikeTranscriptMarkdown(rawContent) {
  const content = String(rawContent || "");
  if (!content) {
    return false;
  }

  if (/[\u001B\u001A]/.test(content)) {
    return true;
  }

  const transcriptSignals = [
    "OpenAI Codex v",
    "mcp:",
    "exited ",
    "succeeded in ",
    "blocked by policy",
    "NativeCommandError",
    "CategoryInfo",
    "FullyQualifiedErrorId",
    "pwsh.exe",
    "exec\n",
    "exec\r\n"
  ];
  const hits = transcriptSignals.reduce(
    (count, marker) => count + (content.includes(marker) ? 1 : 0),
    0
  );

  return hits >= 3;
}

function getStatusTone(status) {
  const normalized = String(status || "unknown").toLowerCase();
  if (["running", "info", "ready"].includes(normalized)) {
    return "running";
  }
  if (["completed", "pass", "passed"].includes(normalized)) {
    return "completed";
  }
  if (["warn", "warning", "stale"].includes(normalized)) {
    return "warning";
  }
  if (["failed", "missing", "error", "cancelled", "fail"].includes(normalized)) {
    return "failed";
  }
  return "idle";
}

function statusBadge(status) {
  const normalized = String(status || "unknown").toLowerCase();
  return `<span class="status-badge badge-${getStatusTone(normalized)}">${escapeHtml(normalized)}</span>`;
}

function renderStalledHint(session, className = "session-meta") {
  if (!session?.isStalled) {
    return "";
  }

  const activityDisplay = formatEventTimeDisplay(session.lastActivityAt || "");
  const activityTitle = activityDisplay.title ? ` title="${escapeHtml(activityDisplay.title)}"` : "";
  const currentAction = session.currentAction || session.runState?.currentAction || "current step";
  const currentTool = session.currentTool || session.runState?.currentTool || "";
  const toolSuffix = currentTool ? ` (${currentTool})` : "";

  return `<div class="${className}"${activityTitle}>Stalled · no activity ${escapeHtml(activityDisplay.label)} · ${escapeHtml(currentAction)}${escapeHtml(toolSuffix)}</div>`;
}

function eventLevelTone(level) {
  const normalized = String(level || "info").toLowerCase();
  if (["error", "failed"].includes(normalized)) {
    return "error";
  }
  if (["warn", "warning"].includes(normalized)) {
    return "warn";
  }
  return "info";
}

function artifactKindMarker(kind) {
  const map = {
    cycle_plan: "CY",
    meta_review_output: "MR",
    deliberation_summary: "DS",
    claude_thoughts: "CT",
    codex_evaluation: "CE",
    codex_review: "CR",
    qc_report: "QC",
    plan_qc_report: "PQ",
    transcript: "TX",
    log: "LOG",
    event_stream: "EV",
    run_state: "RS",
    history: "HI",
    cycle_status: "CS"
  };
  return map[kind] || "MD";
}

function artifactIconClass(kind) {
  const map = {
    cycle_plan: "artifact-icon--cy",
    meta_review_output: "artifact-icon--cy",
    deliberation_summary: "artifact-icon--ds",
    claude_thoughts: "artifact-icon--ct",
    codex_evaluation: "artifact-icon--ce",
    codex_review: "artifact-icon--cr",
    qc_report: "artifact-icon--qc",
    plan_qc_report: "artifact-icon--pq",
    transcript: "artifact-icon--muted",
    log: "artifact-icon--muted",
    event_stream: "artifact-icon--muted",
    run_state: "artifact-icon--muted",
    history: "artifact-icon--muted",
    cycle_status: "artifact-icon--muted"
  };
  return map[kind] || "";
}

function formatRelativeLabel(value) {
  if (window.CrossQcTime?.formatRelativeTimestamp) {
    return window.CrossQcTime.formatRelativeTimestamp(value);
  }
  return formatCompactTimestamp(value);
}

function formatAbsoluteLabel(value) {
  if (window.CrossQcTime?.formatAbsoluteTimestamp) {
    return window.CrossQcTime.formatAbsoluteTimestamp(value);
  }
  return formatCompactTimestamp(value);
}

function formatDurationMs(value) {
  const ms = Math.max(0, Number(value || 0));
  if (!Number.isFinite(ms) || ms <= 0) {
    return "0s";
  }

  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) {
    return `${hours}h ${minutes}m`;
  }
  if (minutes > 0) {
    return `${minutes}m ${seconds}s`;
  }
  return `${seconds}s`;
}

function processStateTone(state) {
  const normalized = String(state || "").toLowerCase();
  if (normalized === "active") {
    return "completed";
  }
  if (["alive_idle", "stalled"].includes(normalized)) {
    return "warning";
  }
  if (normalized === "dead") {
    return "failed";
  }
  return "idle";
}

function renderProcessStatusBadge(processInfo) {
  return `<span class="status-badge badge-${processStateTone(processInfo?.state)}">${escapeHtml(processInfo?.stateLabel || "Unavailable")}</span>`;
}

function getEffectiveProcessInfo(session) {
  const runState = session?.runState || {};
  const raw = session?.processInfo || {};
  const fallbackPid = Number(raw.pid || runState.childPid || 0);
  const fallbackCurrentAction = raw.currentAction || session?.currentAction || runState.currentAction || "";
  const fallbackCurrentTool = raw.currentTool || session?.currentTool || runState.currentTool || "";
  const fallbackStartedAt = raw.startedAt || session?.startedAt || runState.startedAt || null;
  const fallbackLastActivityAt = raw.lastActivityAt || session?.lastActivityAt || runState.updatedAt || null;
  const fallbackIdleDurationMs = Number(raw.idleDurationMs || 0) > 0
    ? Number(raw.idleDurationMs)
    : (fallbackLastActivityAt ? Math.max(0, Date.now() - new Date(fallbackLastActivityAt).getTime()) : 0);
  const fallbackChildren = Array.isArray(raw.children) ? raw.children : [];
  const normalizedState = raw.state || (fallbackPid ? (String(session?.status || "").toLowerCase() === "running" ? "unavailable" : "dead") : "unavailable");
  const stateLabel = raw.stateLabel || (normalizedState === "dead" ? "Dead" : "Unavailable");

  return {
    pid: fallbackPid,
    alive: Boolean(raw.alive),
    startedAt: fallbackStartedAt,
    currentAction: fallbackCurrentAction,
    currentTool: fallbackCurrentTool,
    lastActivityAt: fallbackLastActivityAt,
    idleDurationMs: fallbackIdleDurationMs,
    state: normalizedState,
    stateLabel,
    children: fallbackChildren
  };
}

function renderPendingArtifactRow(artifact) {
  const iconCls = artifactIconClass(artifact.kind);
  return `
    <div class="artifact-item artifact-item--pending" aria-disabled="true">
      <span class="artifact-icon ${iconCls}">${escapeHtml(artifactKindMarker(artifact.kind))}</span>
      <span class="artifact-info">
        <span class="artifact-name">${escapeHtml(artifact.name)}</span>
        <span class="artifact-kind">${escapeHtml(artifact.kind)} • ${escapeHtml(artifact.relativePath)}</span>
        <span class="artifact-pending-badge">${escapeHtml(`Pending · ${artifact.source || "current step"}`)}</span>
      </span>
    </div>
  `;
}

function renderArtifactButton(artifact) {
  const isDelib = artifact.section === "deliberation_round";
  const activeClass = state.selectedArtifact?.path === artifact.path ? "active" : "";
  const delibClass = isDelib ? "artifact-item--delib" : "";
  const iconCls = artifactIconClass(artifact.kind);
  return `
    <button class="artifact-item ${delibClass} ${activeClass}" data-artifact-path="${escapeHtml(artifact.path)}" type="button">
      <span class="artifact-icon ${iconCls}">${escapeHtml(artifactKindMarker(artifact.kind))}</span>
      <span class="artifact-info">
        <span class="artifact-name">${escapeHtml(artifact.name)}</span>
        <span class="artifact-kind">${escapeHtml(artifact.kind)} • ${escapeHtml(artifact.relativePath)}</span>
      </span>
    </button>
  `;
}

function getCurrentTheme() {
  return document.documentElement.dataset.theme === "light" ? "light" : "dark";
}

function updateThemeToggle() {
  const toggle = elements.themeToggle || $("themeToggle");
  if (!toggle) {
    return;
  }

  const isLight = getCurrentTheme() === "light";
  toggle.innerHTML = isLight ? "&#9728;" : "&#9790;";
  toggle.setAttribute("aria-pressed", String(isLight));
  toggle.setAttribute("aria-label", isLight ? "Switch to dark theme" : "Switch to light theme");
  toggle.title = isLight ? "Switch to dark theme" : "Switch to light theme";
}

function setTheme(theme, options = {}) {
  const skipTransition = options.skipTransition === true;

  if (!skipTransition) {
    document.documentElement.classList.add("theme-transitioning");
  } else {
    document.documentElement.classList.remove("theme-transitioning");
  }

  if (theme === "light") {
    document.documentElement.dataset.theme = "light";
  } else {
    document.documentElement.removeAttribute("data-theme");
  }

  try {
    window.localStorage.setItem(THEME_STORAGE_KEY, theme);
  } catch (error) {
    // Ignore storage failures in preview or restricted contexts.
  }

  updateThemeToggle();

  if (!skipTransition) {
    window.clearTimeout(setTheme.transitionTimer);
    setTheme.transitionTimer = window.setTimeout(() => {
      document.documentElement.classList.remove("theme-transitioning");
    }, 350);
  }
}

function initThemeToggle() {
  let savedTheme = "";
  try {
    savedTheme = window.localStorage.getItem(THEME_STORAGE_KEY) || "";
  } catch (error) {
    savedTheme = "";
  }

  if (savedTheme === "light" && getCurrentTheme() !== "light") {
    setTheme("light", { skipTransition: true });
  } else {
    updateThemeToggle();
  }

  elements.themeToggle?.addEventListener("click", () => {
    const nextTheme = getCurrentTheme() === "light" ? "dark" : "light";
    setTheme(nextTheme);
  });
}

function setLeftPanel(panel) {
  state.leftPanel = panel;
  for (const button of document.querySelectorAll("[data-left-panel]")) {
    button.classList.toggle("active", button.dataset.leftPanel === panel);
  }
  elements.leftPanelSessions?.classList.toggle("active", panel === "sessions");
  elements.leftPanelWizard?.classList.toggle("active", panel === "wizard");
  elements.leftPanelConfigure?.classList.toggle("active", panel === "configure");
  if (panel === "wizard") recoverWizardState();
}

function setRightPanel(panel) {
  state.rightPanel = panel;
  for (const button of document.querySelectorAll("[data-right-panel]")) {
    button.classList.toggle("active", button.dataset.rightPanel === panel);
  }
  elements.rightPanelDashboard?.classList.toggle("active", panel === "dashboard");
  elements.rightPanelArtifacts?.classList.toggle("active", panel === "artifacts");
  elements.rightPanelEvents?.classList.toggle("active", panel === "events");
}

function updateHeaderStatus(session) {
  if (!elements.headerStatusText || !elements.headerStatusDot) {
    return;
  }

  if (!session) {
    elements.headerStatusText.textContent = "No session selected";
    elements.headerStatusDot.className = "status-dot idle";
    return;
  }

  elements.headerStatusText.textContent = `${session.sessionId} · ${session.status || "unknown"}`;
  elements.headerStatusDot.className = `status-dot ${getStatusTone(session.status)}`;
}

function updateTabCounts(session = state.selectedSession) {
  if (elements.dashboardCount) {
    elements.dashboardCount.textContent = session ? "1" : "0";
  }
  if (elements.artifactCount) {
    elements.artifactCount.textContent = String(session?.artifacts?.length || 0);
  }
  if (elements.eventCount) {
    elements.eventCount.textContent = String(session?.recentEvents?.length || 0);
  }
}

function getBundledHelpTopic(topicId) {
  return bundledHelpTopics.find((topic) => topic.id === topicId) || bundledHelpTopics[0];
}

function isMissingHelpHandler(error) {
  const message = String(error?.message || error || "");
  return message.includes("No handler registered for 'help:list'") || message.includes("No handler registered for 'help:read'");
}

function joinRepoPath(...parts) {
  return parts
    .filter(Boolean)
    .map((part, index) => {
      if (index === 0) {
        return String(part).replace(/[\\/]+$/, "");
      }
      return String(part).replace(/^[\\/]+|[\\/]+$/g, "");
    })
    .join("\\");
}

async function safeListHelpTopics() {
  if (typeof api.listHelpTopics === "function") {
    try {
      return await api.listHelpTopics();
    } catch (error) {
      if (!isMissingHelpHandler(error)) {
        throw error;
      }
    }
  }

  return bundledHelpTopics.map(({ id, title }) => ({ id, title }));
}

async function safeReadHelpTopic(topicId) {
  const topic = getBundledHelpTopic(topicId);

  if (typeof api.readHelpTopic === "function") {
    try {
      return await api.readHelpTopic(topic.id);
    } catch (error) {
      if (!isMissingHelpHandler(error)) {
        throw error;
      }
    }
  }

  if (state.defaults?.repoRoot) {
    try {
      const artifact = await api.readArtifact({
        workspaceDir: getWorkspaceDir(),
        path: joinRepoPath(state.defaults.repoRoot, "docs", "help", topic.fileName)
      });
      return {
        id: topic.id,
        title: topic.title,
        path: artifact.path,
        format: artifact.format,
        content: artifact.content
      };
    } catch (error) {
      // Fall through to bundled preview text if reading the local help file fails.
    }
  }

  return {
    id: topic.id,
    title: topic.title,
    path: `Preview help/${topic.fileName}`,
    format: "markdown",
    content: topic.previewContent
  };
}

function getPathLeaf(value) {
  const parts = String(value || "")
    .split(/[\\/]+/)
    .filter(Boolean);
  return parts[parts.length - 1] || String(value || "");
}

function isMissingProjectHistoryHandler(error) {
  const message = String(error?.message || error || "");
  return message.includes("No handler registered for 'project-history:list'") ||
    message.includes("No handler registered for 'project-history:remember'");
}

async function safeListProjectHistory() {
  if (typeof api.listProjectHistory !== "function") {
    return [];
  }

  try {
    const history = await api.listProjectHistory();
    return Array.isArray(history) ? history : [];
  } catch (error) {
    if (!isMissingProjectHistoryHandler(error)) {
      throw error;
    }
    return [];
  }
}

async function safeRememberProjectHistory(config, metadata = {}) {
  if (!config || typeof api.rememberProjectHistory !== "function") {
    return state.projectHistory;
  }

  try {
    const history = await api.rememberProjectHistory({
      config,
      metadata
    });
    return Array.isArray(history) ? history : state.projectHistory;
  } catch (error) {
    if (!isMissingProjectHistoryHandler(error)) {
      throw error;
    }
    return state.projectHistory;
  }
}

function renderViewerPlaceholder(title, description) {
  elements.artifactViewer.classList.add("empty-state");
  elements.artifactViewer.innerHTML = `
    <div class="empty-block">
      <h3>${escapeHtml(title)}</h3>
      <p>${escapeHtml(description)}</p>
    </div>
  `;
}

function focusViewer() {
  setRightPanel("artifacts");
  elements.rightPanelArtifacts?.scrollIntoView({
    behavior: "smooth",
    block: "start"
  });
}

function renderViewerDocument(documentData) {
  elements.artifactViewer.classList.remove("empty-state");
  const rawContent = String(documentData?.content || "");
  const viewerContent = sanitizeViewerText(rawContent);

  if (documentData.format === "markdown") {
    if (looksLikeTranscriptMarkdown(rawContent)) {
      elements.artifactViewer.innerHTML = `<pre>${escapeHtml(viewerContent)}</pre>`;
      elements.artifactViewer.scrollTop = 0;
      return;
    }

    const rendered = window.marked.parse(viewerContent);
    elements.artifactViewer.innerHTML = window.DOMPurify.sanitize(rendered);
    elements.artifactViewer.scrollTop = 0;
    return;
  }

  if (documentData.format === "json") {
    try {
      const formatted = JSON.stringify(JSON.parse(viewerContent), null, 2);
      elements.artifactViewer.innerHTML = `<pre>${escapeHtml(formatted)}</pre>`;
    } catch (error) {
      elements.artifactViewer.innerHTML = `<pre>${escapeHtml(viewerContent)}</pre>`;
    }
    elements.artifactViewer.scrollTop = 0;
    return;
  }

  elements.artifactViewer.innerHTML = `<pre>${escapeHtml(viewerContent)}</pre>`;
  elements.artifactViewer.scrollTop = 0;
}

function openMetaPlanEditor() {
  state.viewerMode = "editor";
  state.selectedArtifact = null;
  state.selectedHelpTopic = null;
  state.editorDirty = false;
  state.editorAbsolutePath = null;

  const defaultName = "meta_plan.md";

  elements.viewerMeta.textContent = "New Meta-Plan";
  elements.helpTabs.hidden = true;
  elements.helpTabs.innerHTML = "";
  elements.closeHelp.hidden = false;
  elements.openArtifact.disabled = true;

  elements.artifactViewer.classList.remove("empty-state");
  elements.artifactViewer.innerHTML = `
    <div class="editor-pane">
      <div class="editor-toolbar">
        <label class="editor-filename-field">
          <span class="label-xs">File name</span>
          <input id="editorFileName" type="text" spellcheck="false" value="${escapeHtml(defaultName)}" placeholder="meta_plan.md">
        </label>
        <button id="editorSave" class="primary-button action-button editor-save-button" type="button">Save to Project</button>
      </div>
      <textarea id="editorTextarea" class="editor-textarea" spellcheck="false" placeholder="Write your meta-plan here...">${escapeHtml(META_PLAN_TEMPLATE)}</textarea>
      <div id="editorStatus" class="editor-status"></div>
    </div>
  `;

  const textarea = $("editorTextarea");
  const saveButton = $("editorSave");

  textarea.addEventListener("input", () => {
    state.editorDirty = true;
  });

  saveButton.addEventListener("click", handleEditorSave);

  setRightPanel("artifacts");
  focusViewer();
  textarea.focus();
}

function openExistingPlanEditor(filePath, content) {
  state.viewerMode = "editor";
  state.selectedArtifact = null;
  state.selectedHelpTopic = null;
  state.editorDirty = false;
  state.editorAbsolutePath = filePath;

  const fileName = filePath.split(/[/\\]/).pop();

  elements.viewerMeta.textContent = `Editing: ${fileName}`;
  elements.helpTabs.hidden = true;
  elements.helpTabs.innerHTML = "";
  elements.closeHelp.hidden = false;
  elements.openArtifact.disabled = true;

  elements.artifactViewer.classList.remove("empty-state");
  elements.artifactViewer.innerHTML = `
    <div class="editor-pane">
      <div class="editor-toolbar">
        <label class="editor-filename-field">
          <span class="label-xs">File name</span>
          <input id="editorFileName" type="text" spellcheck="false" value="${escapeHtml(fileName)}" placeholder="meta_plan.md" readonly title="${escapeHtml(filePath)}">
        </label>
        <button id="editorSave" class="primary-button action-button editor-save-button" type="button">Save</button>
      </div>
      <textarea id="editorTextarea" class="editor-textarea" spellcheck="false">${escapeHtml(content)}</textarea>
      <div id="editorStatus" class="editor-status"></div>
    </div>
  `;

  const textarea = $("editorTextarea");
  const saveButton = $("editorSave");

  textarea.addEventListener("input", () => {
    state.editorDirty = true;
  });

  saveButton.addEventListener("click", handleEditorSave);

  setRightPanel("artifacts");
  focusViewer();
  textarea.focus();
}

async function handleEditorSave() {
  const textarea = $("editorTextarea");
  const fileNameInput = $("editorFileName");
  const statusEl = $("editorStatus");

  if (!textarea || !fileNameInput) {
    return;
  }

  const content = textarea.value;
  const fileName = fileNameInput.value.trim() || "meta_plan.md";

  if (!content.trim()) {
    statusEl.textContent = "Cannot save an empty file.";
    statusEl.className = "editor-status error";
    return;
  }

  statusEl.textContent = "Saving...";
  statusEl.className = "editor-status";

  try {
    let result;
    if (state.editorAbsolutePath) {
      result = await api.writePlan({ absolutePath: state.editorAbsolutePath, content });
    } else {
      const workspaceDir = getWorkspaceDir();
      if (!workspaceDir) {
        statusEl.textContent = "Set the workspace directory to your target project folder first.";
        statusEl.className = "editor-status error";
        return;
      }
      result = await api.savePlan({ workspaceDir, fileName, content });
    }

    if (result.ok) {
      state.editorDirty = false;
      elements.planFile.value = state.editorAbsolutePath ? result.path : fileName;
      elements.planFile.title = result.path;
      statusEl.textContent = `Saved to ${result.path}`;
      statusEl.className = "editor-status success";
    } else {
      statusEl.textContent = result.message || "Save failed.";
      statusEl.className = "editor-status error";
    }
  } catch (error) {
    statusEl.textContent = error.message || "Save failed.";
    statusEl.className = "editor-status error";
  }
}

function renderHelpTabs() {
  if (state.viewerMode !== "help" || state.helpTopics.length === 0) {
    elements.helpTabs.hidden = true;
    elements.helpTabs.innerHTML = "";
    return;
  }

  elements.helpTabs.hidden = false;
  elements.helpTabs.innerHTML = state.helpTopics
    .map((topic) => `
      <button
        class="help-tab ${state.selectedHelpTopic?.id === topic.id ? "active" : ""}"
        data-help-topic="${escapeHtml(topic.id)}"
        type="button"
      >
        ${escapeHtml(topic.title)}
      </button>
    `)
    .join("");

  for (const button of elements.helpTabs.querySelectorAll("[data-help-topic]")) {
    button.addEventListener("click", () => openHelpTopic(button.dataset.helpTopic));
  }
}

function syncViewerControls() {
  renderHelpTabs();
  const currentDocument = state.viewerMode === "help" ? state.selectedHelpTopic : state.selectedArtifact;
  elements.closeHelp.hidden = state.viewerMode !== "help" && state.viewerMode !== "editor";
  elements.openArtifact.disabled = !currentDocument;
}

function getWorkspaceDir() {
  return elements.workspaceDir.value.trim() || state.defaults?.defaultWorkspaceDir || "";
}

function getFormConfig() {
  return {
    workspaceDir: getWorkspaceDir(),
    promptDir: elements.promptDir.value.trim(),
    planFile: elements.planFile.value.trim(),
    qcType: elements.qcType.value,
    maxIterations: Number(elements.maxIterations.value),
    maxPlanQCIterations: Number(elements.maxPlanQCIterations.value),
    skipPlanQC: elements.skipPlanQC.checked,
    passOnMediumOnly: elements.passOnMediumOnly.checked,
    historyIterations: Number(elements.historyIterations.value),
    reasoningEffort: elements.reasoningEffort.value,
    claudeQCIterations: Number(elements.claudeQCIterations.value),
    deliberationMode: elements.deliberationMode.checked,
    maxDeliberationRounds: Number(elements.maxDeliberationRounds.value),
    maxRetries: Number(elements.maxRetries.value),
    retryDelaySec: Number(elements.retryDelaySec.value)
  };
}

function updatePathFieldTitle(input) {
  if (!input) {
    return;
  }
  input.title = input.value.trim();
}

function setTextFieldValue(input, value) {
  if (!input) {
    return;
  }
  input.value = String(value || "");
  updatePathFieldTitle(input);
}

function setNumericFieldValue(input, value, fallback) {
  if (!input) {
    return;
  }
  const numericValue = Number(value);
  input.value = String(Number.isFinite(numericValue) ? numericValue : fallback);
}

function setCheckboxFieldValue(input, value) {
  if (!input) {
    return;
  }
  input.checked = Boolean(value);
}

function applyFormConfig(config = {}) {
  const currentConfig = getFormConfig();
  const nextConfig = {
    ...currentConfig,
    ...config,
    workspaceDir: String(config.workspaceDir || currentConfig.workspaceDir || state.defaults?.defaultWorkspaceDir || "").trim(),
    promptDir: String(config.promptDir || currentConfig.promptDir || state.defaults?.defaultPromptDir || "").trim(),
    planFile: String(config.planFile || "").trim(),
    qcType: config.qcType === "document" ? "document" : "code",
    reasoningEffort: ["xhigh", "high", "medium", "low"].includes(config.reasoningEffort)
      ? config.reasoningEffort
      : currentConfig.reasoningEffort
  };

  setTextFieldValue(elements.workspaceDir, nextConfig.workspaceDir);
  setTextFieldValue(elements.promptDir, nextConfig.promptDir);
  setTextFieldValue(elements.planFile, nextConfig.planFile);
  elements.qcType.value = nextConfig.qcType;
  elements.reasoningEffort.value = nextConfig.reasoningEffort;
  setNumericFieldValue(elements.maxIterations, nextConfig.maxIterations, currentConfig.maxIterations);
  setNumericFieldValue(elements.maxPlanQCIterations, nextConfig.maxPlanQCIterations, currentConfig.maxPlanQCIterations);
  setNumericFieldValue(elements.claudeQCIterations, nextConfig.claudeQCIterations, currentConfig.claudeQCIterations);
  setNumericFieldValue(elements.historyIterations, nextConfig.historyIterations, currentConfig.historyIterations);
  setNumericFieldValue(elements.maxDeliberationRounds, nextConfig.maxDeliberationRounds, currentConfig.maxDeliberationRounds);
  setNumericFieldValue(elements.maxRetries, nextConfig.maxRetries, currentConfig.maxRetries);
  setNumericFieldValue(elements.retryDelaySec, nextConfig.retryDelaySec, currentConfig.retryDelaySec);
  setCheckboxFieldValue(elements.skipPlanQC, nextConfig.skipPlanQC);
  setCheckboxFieldValue(elements.passOnMediumOnly, nextConfig.passOnMediumOnly);
  setCheckboxFieldValue(elements.deliberationMode, nextConfig.deliberationMode);

  if (elements.wizardWorkspaceDir) {
    elements.wizardWorkspaceDir.value = nextConfig.workspaceDir;
    updatePathFieldTitle(elements.wizardWorkspaceDir);
  }
}

function renderProjectHistory() {
  if (!elements.projectHistoryList || !elements.projectHistoryCount) {
    return;
  }

  const entries = Array.isArray(state.projectHistory) ? state.projectHistory : [];
  const activeWorkspaceDir = getWorkspaceDir();
  elements.projectHistoryCount.textContent = String(entries.length);

  if (entries.length === 0) {
    elements.projectHistoryList.innerHTML = `
      <div class="project-history-empty">
        <p>No previous projects saved yet.</p>
      </div>
    `;
    return;
  }

  elements.projectHistoryList.innerHTML = entries
    .map((entry) => {
      const active = activeWorkspaceDir && entry.workspaceDir === activeWorkspaceDir;
      const planLabel = entry.planTitle || getPathLeaf(entry.config?.planFile) || "Latest configuration";
      const qcLabel = entry.config?.qcType === "document" ? "Document" : "Code";
      return `
        <button
          class="project-history-item ${active ? "active" : ""}"
          data-history-workspace="${escapeHtml(entry.workspaceDir)}"
          type="button"
        >
          <div class="project-history-item-header">
            <span class="project-history-item-title">${escapeHtml(getPathLeaf(entry.workspaceDir))}</span>
            <span class="project-history-item-tag">${escapeHtml(qcLabel)}</span>
          </div>
          <div class="project-history-item-meta">${escapeHtml(planLabel)}</div>
          <div class="project-history-item-meta">${escapeHtml(entry.workspaceDir)}</div>
          <div class="project-history-item-meta">Updated ${escapeHtml(formatCompactTimestamp(entry.updatedAt))}</div>
          <span class="project-history-wizard-link" data-wizard-workspace="${escapeHtml(entry.workspaceDir)}">Open in Wizard &rarr;</span>
        </button>
      `;
    })
    .join("");

  for (const button of elements.projectHistoryList.querySelectorAll("[data-history-workspace]")) {
    button.addEventListener("click", () => loadProjectHistoryEntry(button.dataset.historyWorkspace));
  }
  for (const link of elements.projectHistoryList.querySelectorAll(".project-history-wizard-link")) {
    link.addEventListener("click", (e) => {
      e.stopPropagation();
      openProjectInWizard(link.dataset.wizardWorkspace);
    });
  }
}

async function loadProjectHistoryEntry(workspaceDir) {
  const entry = state.projectHistory.find((item) => item.workspaceDir === workspaceDir);
  if (!entry?.config) {
    return;
  }

  applyFormConfig(entry.config);
  renderProjectHistory();
  await checkEnvironment();
  await refreshSessions(entry.sessionId, {
    resetViewerOnSelection: state.viewerMode === "artifact"
  });
  await recoverWizardState();
}

async function startNewProject() {
  const selected = await api.pickDirectory(getWorkspaceDir());
  if (!selected) return;

  elements.workspaceDir.value = selected;
  updatePathFieldTitle(elements.workspaceDir);
  if (elements.wizardWorkspaceDir) {
    elements.wizardWorkspaceDir.value = selected;
    updatePathFieldTitle(elements.wizardWorkspaceDir);
  }
  elements.planFile.value = "";
  updatePathFieldTitle(elements.planFile);

  renderProjectHistory();
  await checkEnvironment();
  await refreshSessions(undefined, { resetViewerOnSelection: true });
  setLeftPanel("wizard");
}

async function openProjectInWizard(workspaceDir) {
  const entry = state.projectHistory.find((item) => item.workspaceDir === workspaceDir);
  if (entry?.config) {
    applyFormConfig(entry.config);
  } else {
    elements.workspaceDir.value = workspaceDir;
    updatePathFieldTitle(elements.workspaceDir);
    if (elements.wizardWorkspaceDir) {
      elements.wizardWorkspaceDir.value = workspaceDir;
      updatePathFieldTitle(elements.wizardWorkspaceDir);
    }
  }

  renderProjectHistory();
  await checkEnvironment();
  await refreshSessions(entry?.sessionId, { resetViewerOnSelection: true });
  setLeftPanel("wizard");
}

function initPanelResizer() {
  const resizer = $("panelResizer");
  const leftPanel = document.querySelector(".left-panel");
  if (!resizer || !leftPanel) return;

  const MIN_WIDTH = 240;
  const MAX_WIDTH = 600;
  const STORAGE_KEY = "crossqc-left-panel-width";

  const saved = localStorage.getItem(STORAGE_KEY);
  if (saved) {
    const w = parseInt(saved, 10);
    if (w >= MIN_WIDTH && w <= MAX_WIDTH) {
      document.documentElement.style.setProperty("--left-panel-width", w + "px");
    }
  }

  let startX = 0;
  let startWidth = 0;

  function onMouseMove(e) {
    const delta = e.clientX - startX;
    const newWidth = Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, startWidth + delta));
    document.documentElement.style.setProperty("--left-panel-width", newWidth + "px");
  }

  function onMouseUp() {
    resizer.classList.remove("is-dragging");
    document.removeEventListener("mousemove", onMouseMove);
    document.removeEventListener("mouseup", onMouseUp);
    const current = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--left-panel-width"), 10);
    if (!isNaN(current)) localStorage.setItem(STORAGE_KEY, String(current));
  }

  resizer.addEventListener("mousedown", (e) => {
    e.preventDefault();
    startX = e.clientX;
    startWidth = leftPanel.getBoundingClientRect().width;
    resizer.classList.add("is-dragging");
    document.addEventListener("mousemove", onMouseMove);
    document.addEventListener("mouseup", onMouseUp);
  });
}

function updateSessionActionButtons(session) {
  if (elements.resumeSelected) {
    const canResume = Boolean(session?.canResume);
    elements.resumeSelected.disabled = !canResume;
    elements.resumeSelected.title = canResume
      ? "Resume ignores current form values and uses the selected session config."
      : (session?.resumeReason || "Select a resumable failed deliberation session.");
  }

  if (elements.cancelSelected) {
    elements.cancelSelected.disabled = !session || getStatusTone(session.status) !== "running";
  }
}

function renderEnvironment(environment) {
  if (!environment) {
    elements.environmentPanel.innerHTML = "";
    return;
  }

  const availableCommands = environment.commands.filter((command) => command.available).length;
  const promptReady = environment.promptFiles.filter((prompt) => prompt.exists).length;

  const commandRows = environment.commands
    .map(
      (command) => `
        <div class="env-row">
          <div class="env-row-header">
            <span class="env-title">${escapeHtml(command.name)}</span>
            ${statusBadge(command.available ? "ready" : "missing")}
          </div>
          <code class="env-meta">${escapeHtml(command.version || command.location || command.error || "")}</code>
        </div>
      `
    )
    .join("");

  const promptRows = environment.promptFiles
    .map(
      (prompt) => `
        <div class="env-row">
          <div class="env-row-header">
            <span class="env-title">${escapeHtml(prompt.name)}</span>
            ${statusBadge(prompt.exists ? "ready" : "missing")}
          </div>
          <code class="env-meta">${escapeHtml(prompt.path)}</code>
        </div>
      `
    )
    .join("");

  elements.environmentPanel.innerHTML = `
    <div class="session-summary">
      <div class="summary-stat">
        <span>Commands</span>
        <strong>${availableCommands}/${environment.commands.length}</strong>
        <span>${availableCommands === environment.commands.length ? "Ready to run" : "Check dependencies"}</span>
      </div>
      <div class="summary-stat">
        <span>Prompt Pack</span>
        <strong>${promptReady}/${environment.promptFiles.length}</strong>
        <span>${escapeHtml(environment.promptDir || "")}</span>
      </div>
    </div>
    <div class="environment-grid">
      <section>
        <h3>Commands</h3>
        ${commandRows || '<div class="empty-block"><p>No command information available.</p></div>'}
      </section>
      <section>
        <h3>Prompt Templates</h3>
        ${promptRows || '<div class="empty-block"><p>No prompt information available.</p></div>'}
      </section>
    </div>
  `;
}

function getSessionProgress(session) {
  const tone = getStatusTone(session.status);
  if (tone === "completed") {
    return { tone: "completed", width: 100 };
  }
  if (tone === "failed") {
    return { tone: "failed", width: 100 };
  }
  if (tone === "running") {
    const iteration = Number(session.currentIteration || session.runState?.currentIteration || 0);
    return {
      tone: "running",
      width: Math.max(18, Math.min(82, 20 + iteration * 12))
    };
  }
  return { tone: "idle", width: 8 };
}

function renderEmptySidePanels() {
  elements.eventsTimeline.innerHTML = `
    <div class="empty-block">
      <h3>No event feed yet</h3>
      <p>The event stream will populate when a session starts writing events.ndjson.</p>
    </div>
  `;
  elements.artifactsList.innerHTML = `
    <div class="empty-block">
      <h3>No artifacts loaded</h3>
      <p>Reports, logs, cycle plans, and deliberation files will appear here for the selected session.</p>
    </div>
  `;
}

function renderSessions() {
  const runningSessions = state.sessions.filter((session) => getStatusTone(session.status) === "running").length;
  elements.sessionSummary.innerHTML = `
    <div class="summary-stat">
      <span>Sessions</span>
      <strong>${state.sessions.length}</strong>
      <span>${escapeHtml(getWorkspaceDir())}</span>
    </div>
    <div class="summary-stat">
      <span>Running</span>
      <strong>${runningSessions}</strong>
      <span>${runningSessions > 0 ? "Active now" : "Idle"}</span>
    </div>
  `;

  if (state.sessions.length === 0) {
    elements.sessionsList.innerHTML = `
      <div class="empty-block">
        <h3>No sessions yet</h3>
        <p>Pick your target project directory and a plan file, then launch a run. Completed and running sessions will appear here for reuse and review.</p>
      </div>
    `;
    return;
  }

  elements.sessionsList.innerHTML = state.sessions
    .map((session) => {
      const selected = state.selectedSession?.sessionId === session.sessionId;
      const progress = getSessionProgress(session);
      return `
        <button class="session-card ${selected ? "active" : ""}" data-session-id="${escapeHtml(session.sessionId)}" type="button">
          <div class="session-card-header">
            <span class="session-card-id">${escapeHtml(getSessionDisplayTitle(session))}</span>
            ${statusBadge(session.status)}
          </div>
          ${getSessionDisplayTitle(session) !== session.sessionId ? `<div class="session-meta">${escapeHtml(session.sessionId)}</div>` : ""}
          <div class="session-meta">${escapeHtml(session.phase || session.runState?.phase || "No phase recorded")}</div>
          <div class="session-meta">Updated ${escapeHtml(formatCompactTimestamp(session.updatedAt))}</div>
          ${renderStalledHint(session)}
          <div class="session-progress">
            <div class="session-progress-fill ${progress.tone}" style="width:${progress.width}%"></div>
          </div>
        </button>
      `;
    })
    .join("");

  for (const button of elements.sessionsList.querySelectorAll("[data-session-id]")) {
    button.addEventListener("click", () => selectSession(button.dataset.sessionId));
  }
}

function renderLiveStatus(session) {
  updateHeaderStatus(session);
  updateTabCounts(session);
  updateSessionActionButtons(session);

  if (!session) {
    elements.liveStatus.innerHTML = `
      <div class="empty-block">
        <h3>Nothing selected</h3>
        <ol>
          <li>Set the workspace directory to your target project folder.</li>
          <li>Start a run from the configure panel.</li>
          <li>Select the session here to inspect status and output.</li>
        </ol>
      </div>
    `;
    renderEmptySidePanels();
    return;
  }

  const runState = session.runState || {};
  const artifactCount = session.artifacts?.length || 0;
  const pendingArtifacts = session.pendingArtifacts || [];
  const pendingArtifactCount = session.pendingArtifactCount || pendingArtifacts.length || 0;
  const eventCount = session.recentEvents?.length || 0;
  const processInfo = getEffectiveProcessInfo(session);
  const processStartedTitle = processInfo.startedAt ? escapeHtml(formatAbsoluteLabel(processInfo.startedAt)) : "";
  const processLastActivityTitle = processInfo.lastActivityAt ? escapeHtml(formatAbsoluteLabel(processInfo.lastActivityAt)) : "";
  const processChildrenLabel = Array.isArray(processInfo.children) && processInfo.children.length > 0
    ? processInfo.children.map((child) => child.name || `PID ${child.pid}`).join(", ")
    : "No child processes";
  const processHeadline = processInfo.alive
    ? `Alive · PID ${processInfo.pid}`
    : processInfo.pid
      ? (processInfo.state === "dead" ? `Dead · PID ${processInfo.pid}` : `PID ${processInfo.pid} recorded`)
      : "Process info unavailable";
  const dashboardClass = getStatusTone(session.status) === "running" ? "status-hero running" : "status-hero";

  elements.liveStatus.innerHTML = `
    <section class="${dashboardClass}">
      <div class="hero-top">
        <div>
          <div class="label-xs">Active Session</div>
          <div class="hero-session">${escapeHtml(getSessionDisplayTitle(session))}</div>
          ${getSessionDisplayTitle(session) !== session.sessionId ? `<div class="hero-session-id">${escapeHtml(session.sessionId)}</div>` : ""}
          <div class="hero-phase">${escapeHtml(session.phase || runState.phase || "unknown")} · ${escapeHtml(session.currentAction || runState.currentAction || "idle")}</div>
          ${renderStalledHint(session, "hero-session-id")}
        </div>
        ${statusBadge(session.status)}
      </div>
      <div class="hero-metrics">
        <div class="metric-card">
          <div class="metric-value accent">${escapeHtml(String(session.currentIteration || runState.currentIteration || 0))}</div>
          <div class="metric-label">QC Iteration</div>
        </div>
        <div class="metric-card">
          <div class="metric-value warning">${escapeHtml(String(session.currentPlanQCIteration || runState.currentPlanQCIteration || 0))}</div>
          <div class="metric-label">Plan QC</div>
        </div>
        <div class="metric-card">
          <div class="metric-value">${escapeHtml(String(session.currentDeliberationRound || runState.currentDeliberationRound || 0))}</div>
          <div class="metric-label">Round</div>
        </div>
        <div class="metric-card">
          <div class="metric-value success">${escapeHtml(String(artifactCount))}</div>
          <div class="metric-label">Artifacts</div>
        </div>
        <div class="metric-card">
          <div class="metric-value">${escapeHtml(String(eventCount))}</div>
          <div class="metric-label">Events</div>
        </div>
      </div>
    </section>
    <section class="detail-cards">
      <div class="detail-card">
        <div class="detail-card-title">Plan File</div>
        <div class="detail-card-value">${escapeHtml(session.planFile || runState.planFile || getFormConfig().planFile || "Not set")}</div>
      </div>
      ${session.metaReview
        ? `
      <div class="detail-card">
        <div class="detail-card-title">Review Output</div>
        <div class="detail-card-value">${escapeHtml(session.metaReviewOutputFile || "Pending")}</div>
        <div class="detail-card-sub">${escapeHtml(session.metaReviewChecklistFile || "")}</div>
      </div>
      `
        : ""}
      <div class="detail-card">
        <div class="detail-card-title">Logs</div>
        <div class="detail-card-value">${escapeHtml(session.sessionLogsDir || "Unavailable")}</div>
      </div>
      <div class="detail-card">
        <div class="detail-card-title">Cycles</div>
        <div class="detail-card-value">${escapeHtml(session.latestCyclePlan || session.sessionCyclesDir || "Unavailable")}</div>
      </div>
      <div class="detail-card">
        <div class="detail-card-title">Last Message</div>
        <div class="detail-card-value">${escapeHtml(session.lastMessage || runState.lastMessage || "No message recorded")}</div>
        <div class="detail-card-sub">${escapeHtml(session.lastError || runState.lastError || "")}</div>
      </div>
      <div class="detail-card">
        <div class="detail-card-title">Process</div>
        <div class="detail-card-value detail-card-value--inline">
          <span>${escapeHtml(processHeadline)}</span>
          ${renderProcessStatusBadge(processInfo)}
        </div>
        <div class="detail-card-sub"${processStartedTitle ? ` title="${processStartedTitle}"` : ""}>Started ${escapeHtml(processInfo.startedAt ? formatRelativeLabel(processInfo.startedAt) : "unknown")}</div>
        <div class="detail-card-sub"${processLastActivityTitle ? ` title="${processLastActivityTitle}"` : ""}>Last activity ${escapeHtml(processInfo.lastActivityAt ? formatRelativeLabel(processInfo.lastActivityAt) : "unknown")}</div>
        <div class="detail-card-sub">Current step: ${escapeHtml(processInfo.currentAction || "idle")}${escapeHtml(processInfo.currentTool ? ` (${processInfo.currentTool})` : "")}</div>
        <div class="detail-card-sub">Idle for ${escapeHtml(formatDurationMs(processInfo.idleDurationMs))}</div>
        <div class="detail-card-sub">Children: ${escapeHtml(processChildrenLabel)}</div>
      </div>
    </section>
  `;

  elements.eventsTimeline.innerHTML = eventCount
    ? (session.recentEvents || [])
        .slice()
        .reverse()
        .map((event) => {
          const timestamp = formatEventTimeDisplay(event.timestamp);
          const eventTimeTitle = timestamp.title ? ` title="${escapeHtml(timestamp.title)}"` : "";
          return `
            <div class="event-item">
              <div class="event-header">
                <span class="event-level-dot ${eventLevelTone(event.level)}"></span>
                <span class="event-type">${escapeHtml(event.type)}</span>
                <span class="event-time"${eventTimeTitle}>${escapeHtml(timestamp.label)}</span>
              </div>
              <div class="event-detail">
                ${event.data?.message
                  ? `<p class="event-message">${escapeHtml(event.data.message)}</p>`
                  : ""}
                ${(() => {
                  const rest = { ...(event.data || {}) };
                  delete rest.message;
                  return Object.keys(rest).length > 0
                    ? `<details class="event-raw"><summary>Details</summary><pre>${escapeHtml(JSON.stringify(rest, null, 2))}</pre></details>`
                    : "";
                })()}
              </div>
            </div>
          `;
        })
        .join("")
    : `
      <div class="empty-block">
        <h3>No recent events</h3>
        <p>This session has not emitted structured events yet.</p>
      </div>
    `;

  if (pendingArtifactCount || artifactCount) {
    let artifactsHtml = "";
    if (pendingArtifactCount) {
      artifactsHtml += `<div class="artifact-section-header"><span>Pending Artifacts</span></div>`;
      for (const artifact of pendingArtifacts) {
        artifactsHtml += renderPendingArtifactRow(artifact);
      }
    }
    for (const artifact of session.artifacts) {
      if (artifact.sectionChanged) {
        const label = escapeHtml(artifact.sectionLabel || artifact.section || "");
        artifactsHtml += `<div class="artifact-section-header"><span>${label}</span></div>`;
      }
      if (artifact.roundChanged && artifact.round > 0) {
        artifactsHtml += `<div class="artifact-round-label">Round ${escapeHtml(String(artifact.round))}</div>`;
      }
      artifactsHtml += renderArtifactButton(artifact);
    }
    elements.artifactsList.innerHTML = artifactsHtml;
  } else {
    elements.artifactsList.innerHTML = `
      <div class="empty-block">
        <h3>No files yet</h3>
        <p>This session has not generated reports or cycle files yet.</p>
      </div>
    `;
  }

  for (const button of elements.artifactsList.querySelectorAll("[data-artifact-path]")) {
    button.addEventListener("click", () => openArtifactInViewer(button.dataset.artifactPath));
  }
}

async function openArtifactInViewer(artifactPath, options = {}) {
  if (!state.selectedSession) {
    return;
  }

  const artifact = await api.readArtifact({
    workspaceDir: getWorkspaceDir(),
    path: artifactPath,
    sessionId: state.selectedSession.sessionId
  });
  state.viewerMode = "artifact";
  state.selectedArtifact = artifact;
  state.selectedHelpTopic = null;
  elements.viewerMeta.textContent = artifact.path;
  syncViewerControls();
  renderViewerDocument(artifact);
  renderLiveStatus(state.selectedSession);

  if (options.activateTab !== false) {
    setRightPanel("artifacts");
  }

  if (options.focus !== false) {
    focusViewer();
  }
}

async function openHelpTopic(topicId = state.helpTopics[0]?.id || "quick-start") {
  try {
    if (state.helpTopics.length === 0) {
      state.helpTopics = await safeListHelpTopics();
    }

    const helpTopic = await safeReadHelpTopic(topicId);
    state.helpReturn = {
      rightPanel: state.rightPanel,
      artifact: state.selectedArtifact,
      viewerMeta: elements.viewerMeta.textContent
    };
    state.viewerMode = "help";
    state.selectedHelpTopic = helpTopic;
    state.selectedArtifact = null;
    elements.viewerMeta.textContent = `Help · ${helpTopic.title}`;
    syncViewerControls();
    renderViewerDocument(helpTopic);
    setRightPanel("artifacts");
    focusViewer();

    if (state.selectedSession) {
      renderLiveStatus(state.selectedSession);
    }
  } catch (error) {
    state.viewerMode = "help";
    state.selectedArtifact = null;
    state.selectedHelpTopic = null;
    elements.viewerMeta.textContent = "Help unavailable";
    syncViewerControls();
    renderViewerPlaceholder("Help could not be loaded", error.message || "The help content could not be opened.");
    setRightPanel("artifacts");
    focusViewer();
    window.alert(error.message || "The help content could not be opened.");
  }
}

function stopWatchingSelectedSession() {
  if (!state.unwatchSession) {
    return;
  }

  state.unwatchSession();
  state.unwatchSession = null;
}

function closeHelpView() {
  if (state.viewerMode === "editor" && state.editorDirty) {
    if (!window.confirm("You have unsaved changes. Discard them?")) {
      return;
    }
  }

  const restore = state.helpReturn || {};

  state.viewerMode = "artifact";
  state.selectedHelpTopic = null;
  state.editorDirty = false;
  state.editorAbsolutePath = null;

  if (restore.artifact) {
    state.selectedArtifact = restore.artifact;
    elements.viewerMeta.textContent = restore.viewerMeta || restore.artifact.path;
    syncViewerControls();
    renderViewerDocument(restore.artifact);
    setRightPanel("artifacts");
    return;
  }

  state.selectedArtifact = null;
  elements.viewerMeta.textContent = restore.viewerMeta || "Choose a report, plan, or log file.";
  syncViewerControls();
  renderViewerPlaceholder("No artifact selected", "Artifact content will appear here when you open a report, plan, or log file.");

  if (restore.rightPanel && restore.rightPanel !== "artifacts") {
    setRightPanel(restore.rightPanel);
  } else if (state.selectedSession) {
    setRightPanel("dashboard");
  }
}

async function refreshSessions(selectSessionId = state.selectedSession?.sessionId, options = {}) {
  const resetViewerOnSelection = options.resetViewerOnSelection === true;
  const workspaceDir = getWorkspaceDir();
  if (state.selectedSession?.workspaceDir && state.selectedSession.workspaceDir !== workspaceDir) {
    stopWatchingSelectedSession();
    state.selectedSession = null;
  }
  state.sessions = await api.listSessions({
    workspaceDir
  });
  renderSessions();

  if (selectSessionId) {
    const matching = state.sessions.find((session) => session.sessionId === selectSessionId);
    if (matching) {
      await selectSession(selectSessionId, resetViewerOnSelection);
      return;
    }
    stopWatchingSelectedSession();
    state.selectedSession = null;
  }

  if (state.sessions.length === 0) {
    stopWatchingSelectedSession();
    state.selectedSession = null;
    state.selectedArtifact = null;
    renderLiveStatus(null);
    if (state.viewerMode === "artifact") {
      elements.viewerMeta.textContent = "Choose a report, plan, or log file.";
      syncViewerControls();
      renderViewerPlaceholder("No artifact selected", "Artifact content will appear here when you open a report, plan, or log file.");
    }
    return;
  }

  if (!state.selectedSession && state.sessions[0]) {
    await selectSession(state.sessions[0].sessionId, resetViewerOnSelection);
  }
}

async function selectSession(sessionId, resetViewer = true) {
  stopWatchingSelectedSession();

  state.selectedSession = await api.getSession({
    workspaceDir: getWorkspaceDir(),
    sessionId
  });
  state.projectHistory = await safeRememberProjectHistory(state.selectedSession.sessionConfig, {
    sessionId: state.selectedSession.sessionId,
    planTitle: state.selectedSession.planTitle,
    status: state.selectedSession.status,
    updatedAt: state.selectedSession.updatedAt
  });
  renderProjectHistory();

  if (resetViewer && state.viewerMode !== "help") {
    state.selectedArtifact = null;
    elements.viewerMeta.textContent = "Choose a report, plan, or log file.";
    syncViewerControls();
    renderViewerPlaceholder("No artifact selected", "Pick a QC report, continuation cycle, or log file from the artifacts tab to load it here.");
  }

  setRightPanel("dashboard");
  renderSessions();
  renderLiveStatus(state.selectedSession);

  if (resetViewer && state.viewerMode !== "help") {
    const preferredArtifact = (state.selectedSession.artifacts || []).find(
      (artifact) => !["run_state", "event_stream"].includes(artifact.kind)
    );
    if (preferredArtifact) {
      await openArtifactInViewer(preferredArtifact.path, { activateTab: false, focus: false });
    }
  }

  state.unwatchSession = api.watchSession(
    {
      workspaceDir: getWorkspaceDir(),
      sessionId
    },
    async (updatedSession) => {
      state.selectedSession = updatedSession;
      renderLiveStatus(state.selectedSession);
      state.sessions = await api.listSessions({
        workspaceDir: getWorkspaceDir()
      });
      renderSessions();
    }
  );
}

async function checkEnvironment() {
  state.environment = await api.checkEnvironment({
    workspaceDir: getWorkspaceDir(),
    promptDir: elements.promptDir.value.trim()
  });
  if (state.environment?.promptDir) {
    elements.promptDir.value = state.environment.promptDir;
    updatePathFieldTitle(elements.promptDir);
  }
  renderEnvironment(state.environment);
}

async function handleStartRun(event) {
  event.preventDefault();
  try {
    const config = getFormConfig();
    const run = await api.startRun(config);
    setLeftPanel("sessions");
    await refreshSessions(run.sessionId);
    await selectSession(run.sessionId);
  } catch (error) {
    window.alert(error.message);
  }
}

async function handleReviewMetaPlan() {
  const planFile = elements.planFile.value.trim();
  const workspaceDir = getWorkspaceDir();
  if (!planFile) {
    window.alert("Set a Plan File first. Review Meta Plan uses the selected meta plan as the source file.");
    return;
  }

  if (resolveConfiguredPath(planFile, workspaceDir) === normalizePathValue(state.defaults?.metaPlanChecklistPath)) {
    window.alert("Select the meta plan you want to strengthen. The bundled checklist file cannot be used as the review target.");
    return;
  }
  try {
    const config = getFormConfig();
    const run = await api.startRun({
      ...config,
      qcType: "document",
      skipPlanQC: true,
      deliberationMode: false,
      metaReview: true
    });
    setLeftPanel("sessions");
    await refreshSessions(run.sessionId);
    await selectSession(run.sessionId);
  } catch (error) {
    window.alert(error.message);
  }
}

async function handleResumeSelected() {
  if (!state.selectedSession) {
    return;
  }

  if (!state.selectedSession.canResume) {
    window.alert(state.selectedSession.resumeReason || "This session cannot be resumed.");
    return;
  }

  try {
    const run = await api.resumeRun({
      workspaceDir: state.selectedSession.workspaceDir,
      sessionId: state.selectedSession.sessionId
    });
    setLeftPanel("sessions");
    await refreshSessions(run.sessionId);
    await selectSession(run.sessionId);
  } catch (error) {
    window.alert(error.message);
  }
}

async function handleCancelSelected() {
  if (!state.selectedSession) {
    return;
  }

  const result = await api.cancelRun({
    workspaceDir: state.selectedSession.workspaceDir,
    sessionId: state.selectedSession.sessionId,
    pid: state.selectedSession.runState?.childPid
  });

  if (!result.ok) {
    window.alert(result.message);
  }

  await refreshSessions(state.selectedSession.sessionId);
}

function bindPanelNavigation() {
  for (const button of document.querySelectorAll("[data-left-panel]")) {
    button.addEventListener("click", () => setLeftPanel(button.dataset.leftPanel));
  }
  for (const button of document.querySelectorAll("[data-right-panel]")) {
    button.addEventListener("click", () => setRightPanel(button.dataset.rightPanel));
  }
}

// =========================================================================
// Wizard
// =========================================================================

function setWizardStep(step) {
  state.wizard.currentStep = step;
  const indicator = document.getElementById("wizardStepIndicator");
  if (!indicator) return;

  const stepEls = indicator.querySelectorAll(".wizard-step");
  const connectors = indicator.querySelectorAll(".wizard-step-connector");

  stepEls.forEach((el) => {
    const s = Number(el.dataset.step);
    el.classList.toggle("active", s === step);
    el.classList.toggle("completed", s < step);
    if (s < step) {
      el.querySelector(".wizard-step-number").textContent = "\u2713";
    } else {
      el.querySelector(".wizard-step-number").textContent = String(s);
    }
  });

  connectors.forEach((c, i) => {
    c.classList.toggle("completed", i + 1 < step);
  });

  for (let i = 1; i <= 4; i++) {
    const content = document.getElementById(`wizardStep${i}`);
    if (content) content.classList.toggle("active", i === step);
  }

  const settingsPanel = $("wizardSettings");
  if (settingsPanel) settingsPanel.hidden = step < 2;

  if (step === 3) {
    refreshWizardCycleStatus();
  }
}

function getWizardSettings() {
  return {
    reasoningEffort: $("wizardReasoningEffort")?.value || "high",
    maxIterations: Number($("wizardMaxIterations")?.value) || 10,
    maxPlanQCIterations: Number($("wizardMaxPlanQCIterations")?.value) || 5,
    historyIterations: Number($("wizardHistoryIterations")?.value) || 2,
    claudeQCIterations: Number($("wizardClaudeQCIterations")?.value) || 0,
    passOnMediumOnly: $("wizardPassOnMediumOnly")?.checked || false
  };
}

function getWizardWorkspaceDir() {
  const wizardInput = elements.wizardWorkspaceDir;
  const dir = wizardInput?.value.trim() || "";
  if (dir && elements.workspaceDir && elements.workspaceDir.value.trim() !== dir) {
    elements.workspaceDir.value = dir;
    updatePathFieldTitle(elements.workspaceDir);
  }
  return dir || getWorkspaceDir();
}

function buildMetaPlanFromForm() {
  const title = ($("wizardProjectTitle")?.value || "").trim() || "My Project";
  const goal = ($("wizardGoal")?.value || "").trim() || "[Describe your project goal]";
  const rawFeatures = ($("wizardFeatures")?.value || "").trim();
  const features = rawFeatures
    ? rawFeatures.split("\n").filter(Boolean).map((f, i) => `${i + 1}. ${f.trim()}`).join("\n")
    : "1. [Feature 1]";
  const rawConstraints = ($("wizardConstraints")?.value || "").trim();
  const constraints = rawConstraints
    ? rawConstraints.split("\n").filter(Boolean).map((c) => `- ${c.trim()}`).join("\n")
    : "- [No constraints specified]";
  const rawContext = ($("wizardContext")?.value || "").trim();
  const context = rawContext
    ? rawContext.split("\n").filter(Boolean).map((c) => `- ${c.trim()}`).join("\n")
    : "- [No additional context]";

  return `# Meta-Plan: ${title}\n\n## Goal\n${goal}\n\n## Features\n${features}\n\n## Constraints\n${constraints}\n\n## Context\n${context}\n\n## Output\nGenerate a detailed CONTINUATION_CYCLE plan for each development phase.\n`;
}

function renderWizardPlanSummary() {
  const el = $("wizardPlanSummary");
  if (!el) return;
  const path = state.wizard.planFilePath;
  const shortPath = path ? path.split(/[/\\]/).slice(-2).join("/") : "";
  const title = !state.wizard.planFilePath
    ? "No plan yet"
    : state.wizard.planReviewed ? "Plan reviewed" : "Plan saved";
  el.innerHTML = `
    <div class="wizard-summary-title">${escapeHtml(title)}</div>
    ${shortPath ? `<div class="wizard-summary-detail">${escapeHtml(shortPath)}</div>` : ""}
  `;
}

function setWizardStatus(step, text, className) {
  const el = $(`wizardStep${step}Status`);
  if (!el) return;
  el.textContent = text;
  el.className = `wizard-status ${className || ""}`.trim();
}

function setWizardButtonRunning(buttonId, running, runningText) {
  const btn = $(buttonId);
  if (!btn) return;
  if (running) {
    btn._originalText = btn.textContent;
    btn.textContent = runningText || "Working...";
    btn.classList.add("running");
    btn.disabled = true;
  } else {
    btn.textContent = btn._originalText || btn.textContent;
    btn.classList.remove("running");
    btn.disabled = false;
  }
}

async function handleWizardSavePlan() {
  const workspaceDir = getWizardWorkspaceDir();
  if (!workspaceDir) {
    setWizardStatus(1, "Please select a project folder first.", "error");
    return;
  }

  const isLoadExisting = $("wizardLoadArea") && !$("wizardLoadArea").hidden;
  let content;
  if (isLoadExisting) {
    const filePath = $("wizardLoadPlanPath")?.value.trim();
    if (!filePath) {
      setWizardStatus(1, "Please select a plan file.", "error");
      return;
    }
    const result = await api.readPlan({ workspaceDir, filePath });
    if (!result.ok) {
      setWizardStatus(1, `Could not read: ${result.message}`, "error");
      return;
    }
    content = result.content;
    state.wizard.planFilePath = result.path;
  } else {
    content = buildMetaPlanFromForm();
    const result = await api.savePlan({ workspaceDir, fileName: "meta_plan.md", content });
    if (!result.ok) {
      setWizardStatus(1, result.message || "Save failed.", "error");
      return;
    }
    state.wizard.planFilePath = result.path;
  }

  setWizardStatus(1, "Plan saved.", "success");
  renderWizardPlanSummary();
  setWizardStep(2);
}

function handleWizardOpenEditor() {
  const isLoadExisting = $("wizardLoadArea") && !$("wizardLoadArea").hidden;
  if (isLoadExisting && state.wizard.planFilePath) {
    api.readPlan({ filePath: state.wizard.planFilePath }).then((result) => {
      if (result.ok) {
        openExistingPlanEditor(result.path, result.content);
      }
    });
  } else {
    openMetaPlanEditor();
  }
}

function stopWatchingWizardSession() {
  if (state.wizard.unwatchWizardSession) {
    state.wizard.unwatchWizardSession();
    state.wizard.unwatchWizardSession = null;
  }
}

function watchWizardSession(sessionId, onComplete) {
  stopWatchingWizardSession();
  const workspaceDir = getWizardWorkspaceDir();
  state.wizard.unwatchWizardSession = api.watchSession(
    { workspaceDir, sessionId },
    (session) => {
      const status = session?.status || "";
      if (["completed", "failed", "cancelled"].includes(status)) {
        stopWatchingWizardSession();
        state.wizard.isRunning = false;
        if (onComplete) onComplete(session);
      }
    }
  );
}

async function handleWizardReviewPlan() {
  if (state.wizard.isRunning) return;
  if (!state.wizard.planFilePath) {
    setWizardStatus(2, "No plan to review. Go back and save a plan first.", "error");
    return;
  }

  state.wizard.isRunning = true;
  state.wizard.lastRunType = "review";
  setWizardButtonRunning("wizardReviewPlan", true, "Reviewing...");
  setWizardStatus(2, "Reviewing your plan...", "running");

  try {
    const settings = getWizardSettings();
    const run = await api.startRun({
      workspaceDir: getWizardWorkspaceDir(),
      planFile: state.wizard.planFilePath,
      promptDir: state.defaults?.defaultPromptDir || "",
      qcType: "document",
      metaReview: true,
      skipPlanQC: true,
      deliberationMode: false,
      reasoningEffort: settings.reasoningEffort,
      maxIterations: settings.maxIterations,
      maxPlanQCIterations: settings.maxPlanQCIterations,
      historyIterations: settings.historyIterations,
      claudeQCIterations: settings.claudeQCIterations,
      passOnMediumOnly: settings.passOnMediumOnly,
      maxRetries: 3,
      retryDelaySec: 30
    });

    state.wizard.reviewSessionId = run.sessionId;
    state.wizard.lastRunSessionId = run.sessionId;
    await refreshSessions(run.sessionId);
    await selectSession(run.sessionId);

    watchWizardSession(run.sessionId, (session) => {
      setWizardButtonRunning("wizardReviewPlan", false);
      const success = session.status === "completed";
      if (success) {
        state.wizard.planReviewed = true;
        const reviewedPath = session.metaReviewOutputFile || "";
        if (reviewedPath) {
          state.wizard.reviewedPlanPath = reviewedPath;
          state.wizard.planFilePath = reviewedPath;
        }
        renderWizardPlanSummary();
        const resultEl = $("wizardReviewResult");
        if (resultEl) {
          resultEl.hidden = false;
          const shortPath = reviewedPath ? reviewedPath.split(/[/\\]/).pop() : "";
          resultEl.innerHTML = `
            <span class="wizard-result-badge pass">Reviewed</span>
            ${shortPath ? ` <span style="font-size:0.74rem;color:var(--text-muted)">${escapeHtml(shortPath)}</span>` : ""}
            <div style="margin-top:8px">
              <button id="wizardContinueToStep3" class="primary-button action-button wizard-continue-btn" type="button">Continue to Cycles</button>
            </div>
          `;
          $("wizardContinueToStep3")?.addEventListener("click", () => setWizardStep(3));
        }
        setWizardStatus(2, "Review complete!", "success");
      } else {
        setWizardStatus(2, "Review failed. Check Dashboard for details, then try again.", "error");
        const resultEl = $("wizardReviewResult");
        if (resultEl) {
          resultEl.hidden = false;
          resultEl.innerHTML = `<span class="wizard-result-badge fail">Failed</span>`;
        }
      }
    });
  } catch (error) {
    state.wizard.isRunning = false;
    setWizardButtonRunning("wizardReviewPlan", false);
    setWizardStatus(2, error.message || "Failed to start review.", "error");
  }
}

async function refreshWizardCycleStatus() {
  const workspaceDir = getWizardWorkspaceDir();
  if (!workspaceDir) return;

  try {
    const status = await api.readCycleStatus({ workspaceDir });
    state.wizard.cycleStatus = status;
  } catch {
    state.wizard.cycleStatus = { currentCycle: 0, completedCycles: [], lastCompleted: 0 };
  }

  const infoEl = $("wizardCycleInfo");
  const historyEl = $("wizardCycleHistory");
  const cs = state.wizard.cycleStatus || {};
  const nextCycle = (cs.lastCompleted || 0) + 1;

  if (infoEl) {
    infoEl.innerHTML = `
      <div class="wizard-summary-title">Ready to generate Cycle ${nextCycle}</div>
      ${cs.lastCompleted ? `<div class="wizard-summary-detail">Last completed: Cycle ${cs.lastCompleted}</div>` : ""}
    `;
  }

  if (historyEl) {
    const completed = cs.completedCycles || [];
    if (completed.length === 0) {
      historyEl.innerHTML = "";
    } else {
      historyEl.innerHTML = completed
        .sort((a, b) => a - b)
        .map((c) => `<div class="wizard-cycle-item"><span class="wizard-cycle-check">\u2713</span> Cycle ${c}</div>`)
        .join("");
    }
  }
}

async function handleWizardGenerateCycle() {
  if (state.wizard.isRunning) return;
  const workspaceDir = getWizardWorkspaceDir();
  const planFile = state.wizard.reviewedPlanPath || state.wizard.planFilePath;
  if (!planFile) {
    setWizardStatus(3, "No plan file available. Go back and create one.", "error");
    return;
  }

  state.wizard.isRunning = true;
  state.wizard.lastRunType = "generate";
  setWizardButtonRunning("wizardGenerateCycle", true, "Generating...");
  setWizardStatus(3, "Generating cycle plan...", "running");

  try {
    const settings = getWizardSettings();
    const run = await api.startRun({
      workspaceDir,
      planFile,
      promptDir: state.defaults?.defaultPromptDir || "",
      qcType: "document",
      deliberationMode: true,
      skipPlanQC: true,
      reasoningEffort: settings.reasoningEffort,
      maxIterations: settings.maxIterations,
      maxPlanQCIterations: settings.maxPlanQCIterations,
      maxDeliberationRounds: 4,
      historyIterations: settings.historyIterations,
      claudeQCIterations: settings.claudeQCIterations,
      passOnMediumOnly: settings.passOnMediumOnly,
      maxRetries: 3,
      retryDelaySec: 30
    });

    state.wizard.lastRunSessionId = run.sessionId;
    await refreshSessions(run.sessionId);
    await selectSession(run.sessionId);

    watchWizardSession(run.sessionId, async (session) => {
      setWizardButtonRunning("wizardGenerateCycle", false);
      const success = session.status === "completed";
      if (success) {
        await refreshWizardCycleStatus();
        const cyclePlan = session.latestCyclePlan || "";
        if (cyclePlan) {
          state.wizard.currentCycleFile = cyclePlan;
          const match = cyclePlan.match(/CONTINUATION_CYCLE_(\d+)/i);
          state.wizard.currentCycleNumber = match ? Number(match[1]) : 0;
        }
        setWizardStatus(3, "Cycle plan generated!", "success");
        setWizardStep(4);
        renderWizardImplementInfo();
      } else {
        setWizardStatus(3, "Generation failed. Check Dashboard for details, then try again.", "error");
      }
    });
  } catch (error) {
    state.wizard.isRunning = false;
    setWizardButtonRunning("wizardGenerateCycle", false);
    setWizardStatus(3, error.message || "Failed to start generation.", "error");
  }
}

function renderWizardImplementInfo() {
  const el = $("wizardImplementInfo");
  if (!el) return;
  const cycleNum = state.wizard.currentCycleNumber;
  const shortPath = state.wizard.currentCycleFile ? state.wizard.currentCycleFile.split(/[/\\]/).pop() : "";
  el.innerHTML = `
    <div class="wizard-summary-title">Cycle ${cycleNum || "?"}</div>
    ${shortPath ? `<div class="wizard-summary-detail">${escapeHtml(shortPath)}</div>` : ""}
  `;
}

async function handleWizardImplementCycle() {
  if (state.wizard.isRunning) return;
  if (!state.wizard.currentCycleFile) {
    setWizardStatus(4, "No cycle plan available. Go back and generate one.", "error");
    return;
  }

  state.wizard.isRunning = true;
  state.wizard.lastRunType = "implement";
  setWizardButtonRunning("wizardImplementCycle", true, "Building...");
  setWizardStatus(4, "Writing code...", "running");

  try {
    const settings = getWizardSettings();
    const run = await api.startRun({
      workspaceDir: getWizardWorkspaceDir(),
      planFile: state.wizard.currentCycleFile,
      promptDir: state.defaults?.defaultPromptDir || "",
      qcType: "code",
      deliberationMode: true,
      skipPlanQC: true,
      reasoningEffort: settings.reasoningEffort,
      maxIterations: settings.maxIterations,
      maxPlanQCIterations: settings.maxPlanQCIterations,
      historyIterations: settings.historyIterations,
      claudeQCIterations: settings.claudeQCIterations,
      passOnMediumOnly: settings.passOnMediumOnly,
      maxRetries: 3,
      retryDelaySec: 30
    });

    state.wizard.lastRunSessionId = run.sessionId;
    await refreshSessions(run.sessionId);
    await selectSession(run.sessionId);

    watchWizardSession(run.sessionId, (session) => {
      setWizardButtonRunning("wizardImplementCycle", false);
      const success = session.status === "completed";
      const resultEl = $("wizardImplementResult");
      if (resultEl) {
        resultEl.hidden = false;
        if (success) {
          resultEl.innerHTML = `<span class="wizard-result-badge pass">Done!</span> Cycle ${state.wizard.currentCycleNumber} implemented.`;
          const nextBtn = $("wizardNextCycle");
          if (nextBtn) nextBtn.hidden = false;
        } else {
          resultEl.innerHTML = `<span class="wizard-result-badge fail">Failed</span> Check Dashboard for details.`;
        }
      }
      setWizardStatus(4, success ? "Implementation complete!" : "Implementation failed. Try again or check Dashboard.", success ? "success" : "error");
    });
  } catch (error) {
    state.wizard.isRunning = false;
    setWizardButtonRunning("wizardImplementCycle", false);
    setWizardStatus(4, error.message || "Failed to start implementation.", "error");
  }
}

async function recoverWizardState() {
  const workspaceDir = getWorkspaceDir();
  if (!workspaceDir) return;

  // Clean up any active session watcher from a previous project
  stopWatchingWizardSession();

  // Reset wizard state for fresh recovery
  state.wizard.planFilePath = "";
  state.wizard.planReviewed = false;
  state.wizard.reviewSessionId = null;
  state.wizard.reviewedPlanPath = "";
  state.wizard.cycleStatus = null;
  state.wizard.currentCycleFile = "";
  state.wizard.currentCycleNumber = 0;
  state.wizard.lastRunSessionId = null;
  state.wizard.lastRunType = null;
  state.wizard.isRunning = false;

  if (elements.wizardWorkspaceDir) {
    elements.wizardWorkspaceDir.value = workspaceDir;
    updatePathFieldTitle(elements.wizardWorkspaceDir);
  }

  // Check for existing cycles
  try {
    const status = await api.readCycleStatus({ workspaceDir });
    state.wizard.cycleStatus = status;
    if (status && status.currentCycle > 0) {
      state.wizard.currentCycleNumber = status.lastCompleted || 0;

      // Find the meta plan file so "Generate Next Cycle" works
      try {
        const reviewed = await api.readPlan({ workspaceDir, filePath: "meta_plan.reviewed.md" });
        if (reviewed.ok) {
          state.wizard.planFilePath = reviewed.path;
          state.wizard.reviewedPlanPath = reviewed.path;
          state.wizard.planReviewed = true;
        }
      } catch { /* ignore */ }
      if (!state.wizard.planFilePath) {
        try {
          const plan = await api.readPlan({ workspaceDir, filePath: "meta_plan.md" });
          if (plan.ok) state.wizard.planFilePath = plan.path;
        } catch { /* ignore */ }
      }

      // Check if the next cycle plan already exists (generated but not yet implemented)
      const nextCycleNum = (status.lastCompleted || 0) + 1;
      const paddedNum = String(nextCycleNum).padStart(2, "0");
      try {
        const cyclePlan = await api.readPlan({ workspaceDir, filePath: `cycles/CONTINUATION_CYCLE_${paddedNum}.md` });
        if (cyclePlan.ok) {
          state.wizard.currentCycleFile = cyclePlan.path;
          state.wizard.currentCycleNumber = nextCycleNum;
          renderWizardPlanSummary();
          renderWizardImplementInfo();
          setWizardStep(4);
          return;
        }
      } catch { /* ignore */ }

      renderWizardPlanSummary();
      setWizardStep(3);
      return;
    }
  } catch {
    // No cycle status, continue checking
  }

  // Check for reviewed plan
  try {
    const reviewed = await api.readPlan({ workspaceDir, filePath: "meta_plan.reviewed.md" });
    if (reviewed.ok) {
      state.wizard.planFilePath = reviewed.path;
      state.wizard.reviewedPlanPath = reviewed.path;
      state.wizard.planReviewed = true;
      renderWizardPlanSummary();
      setWizardStep(3);
      return;
    }
  } catch { /* ignore */ }

  // Check for unreviewed plan
  try {
    const plan = await api.readPlan({ workspaceDir, filePath: "meta_plan.md" });
    if (plan.ok) {
      state.wizard.planFilePath = plan.path;
      renderWizardPlanSummary();
      setWizardStep(2);
      return;
    }
  } catch { /* ignore */ }

  // No plan exists — start fresh
  setWizardStep(1);
}

async function bootstrap() {
  elements.workspaceDir = $("workspaceDir");
  elements.promptDir = $("promptDir");
  elements.planFile = $("planFile");
  elements.qcType = $("qcType");
  elements.reasoningEffort = $("reasoningEffort");
  elements.claudeQCIterations = $("claudeQCIterations");
  elements.maxIterations = $("maxIterations");
  elements.maxPlanQCIterations = $("maxPlanQCIterations");
  elements.historyIterations = $("historyIterations");
  elements.skipPlanQC = $("skipPlanQC");
  elements.passOnMediumOnly = $("passOnMediumOnly");
  elements.deliberationMode = $("deliberationMode");
  elements.maxDeliberationRounds = $("maxDeliberationRounds");
  elements.maxRetries = $("maxRetries");
  elements.retryDelaySec = $("retryDelaySec");
  elements.themeToggle = $("themeToggle");
  elements.runForm = $("runForm");
  elements.environmentPanel = $("environmentPanel");
  elements.projectHistoryList = $("projectHistoryList");
  elements.projectHistoryCount = $("projectHistoryCount");
  elements.sessionsList = $("sessionsList");
  elements.sessionSummary = $("sessionSummary");
  elements.liveStatus = $("liveStatus");
  elements.eventsTimeline = $("eventsTimeline");
  elements.artifactsList = $("artifactsList");
  elements.viewerMeta = $("viewerMeta");
  elements.helpTabs = $("helpTabs");
  elements.rightPanelArtifacts = $("rightPanelArtifacts");
  elements.artifactViewer = $("artifactViewer");
  elements.closeHelp = $("closeHelp");
  elements.openArtifact = $("openArtifact");
  elements.leftPanelSessions = $("leftPanelSessions");
  elements.leftPanelWizard = $("leftPanelWizard");
  elements.leftPanelConfigure = $("leftPanelConfigure");
  elements.wizardWorkspaceDir = $("wizardWorkspaceDir");
  elements.rightPanelDashboard = $("rightPanelDashboard");
  elements.rightPanelEvents = $("rightPanelEvents");
  elements.headerStatusText = $("headerStatusText");
  elements.headerStatusDot = $("headerStatusDot");
  elements.dashboardCount = $("dashboardCount");
  elements.artifactCount = $("artifactCount");
  elements.eventCount = $("eventCount");
  elements.resumeSelected = $("resumeSelected");
  elements.cancelSelected = $("cancelSelected");

  state.defaults = await api.getDefaults();
  elements.workspaceDir.value = state.defaults.defaultWorkspaceDir;
  elements.workspaceDir.title = state.defaults.defaultWorkspaceDir;
  elements.promptDir.value = state.defaults.defaultPromptDir;
  elements.promptDir.title = state.defaults.defaultPromptDir;
  updatePathFieldTitle(elements.planFile);

  initThemeToggle();
  bindPanelNavigation();
  setLeftPanel("sessions");
  setRightPanel("dashboard");
  elements.runForm.addEventListener("submit", handleStartRun);
  $("refreshSessions").addEventListener("click", () => refreshSessions());
  $("newProjectAction")?.addEventListener("click", startNewProject);
  initPanelResizer();
  $("checkEnvironment").addEventListener("click", checkEnvironment);
  $("openHelp").addEventListener("click", () => openHelpTopic(state.helpTopics[0]?.id || "quick-start"));
  elements.closeHelp.addEventListener("click", closeHelpView);
  $("resumeSelected").addEventListener("click", handleResumeSelected);
  $("cancelSelected").addEventListener("click", handleCancelSelected);
  $("reviewMetaPlan").addEventListener("click", handleReviewMetaPlan);
  $("browsePlanFile").addEventListener("click", async () => {
    const selected = await api.pickPlanFile();
    if (selected) {
      const workspaceDir = getWorkspaceDir();
      if (workspaceDir && !isPathInsideWorkspace(selected, workspaceDir)) {
        window.alert("Plan files must be inside the selected workspace directory.");
        return;
      }
      elements.planFile.value = selected;
      updatePathFieldTitle(elements.planFile);
    }
  });
  $("newMetaPlan").addEventListener("click", () => {
    openMetaPlanEditor();
  });
  $("editPlanFile").addEventListener("click", async () => {
    const planFile = elements.planFile.value.trim();
    if (!planFile) {
      window.alert("Set a Plan File first.");
      return;
    }
    const workspaceDir = getWorkspaceDir();
    const result = await api.readPlan({ workspaceDir, filePath: planFile });
    if (!result.ok) {
      window.alert(`Could not read plan file: ${result.message}`);
      return;
    }
    openExistingPlanEditor(result.path, result.content);
  });
  $("browseWorkspace").addEventListener("click", async () => {
    const selected = await api.pickDirectory(elements.workspaceDir.value.trim());
    if (selected) {
      elements.workspaceDir.value = selected;
      updatePathFieldTitle(elements.workspaceDir);
      if (elements.wizardWorkspaceDir) {
        elements.wizardWorkspaceDir.value = selected;
        updatePathFieldTitle(elements.wizardWorkspaceDir);
      }
      renderProjectHistory();
      await checkEnvironment();
      await refreshSessions(undefined, {
        resetViewerOnSelection: state.viewerMode === "artifact"
      });
      await recoverWizardState();
    }
  });
  $("browsePromptDir").addEventListener("click", async () => {
    const selected = await api.pickDirectory(elements.promptDir.value.trim());
    if (selected) {
      elements.promptDir.value = selected;
      updatePathFieldTitle(elements.promptDir);
      await checkEnvironment();
    }
  });
  elements.workspaceDir.addEventListener("input", () => {
    updatePathFieldTitle(elements.workspaceDir);
    renderProjectHistory();
  });
  elements.planFile.addEventListener("input", () => updatePathFieldTitle(elements.planFile));
  elements.promptDir.addEventListener("input", () => updatePathFieldTitle(elements.promptDir));
  elements.openArtifact.addEventListener("click", async () => {
    const documentToOpen = state.viewerMode === "help" ? state.selectedHelpTopic : state.selectedArtifact;
    if (!documentToOpen) {
      return;
    }
    await api.openArtifact({
      workspaceDir: getWorkspaceDir(),
      path: documentToOpen.path,
      sessionId: state.selectedSession?.sessionId
    });
  });

  // ── Wizard event wiring ──────────────────────────────────────────
  $("wizardBrowseWorkspace")?.addEventListener("click", async () => {
    const selected = await api.pickDirectory(elements.wizardWorkspaceDir?.value.trim());
    if (selected) {
      elements.wizardWorkspaceDir.value = selected;
      updatePathFieldTitle(elements.wizardWorkspaceDir);
      elements.workspaceDir.value = selected;
      updatePathFieldTitle(elements.workspaceDir);
      renderProjectHistory();
      await checkEnvironment();
      await refreshSessions(undefined, { resetViewerOnSelection: state.viewerMode === "artifact" });
      await recoverWizardState();
    }
  });

  $("wizardStartFresh")?.addEventListener("click", () => {
    $("wizardStartFresh").classList.add("active");
    $("wizardLoadExisting").classList.remove("active");
    const freshForm = $("wizardFreshForm");
    const loadArea = $("wizardLoadArea");
    if (freshForm) freshForm.hidden = false;
    if (loadArea) loadArea.hidden = true;
  });

  $("wizardLoadExisting")?.addEventListener("click", () => {
    $("wizardLoadExisting").classList.add("active");
    $("wizardStartFresh").classList.remove("active");
    const freshForm = $("wizardFreshForm");
    const loadArea = $("wizardLoadArea");
    if (freshForm) freshForm.hidden = true;
    if (loadArea) loadArea.hidden = false;
  });

  $("wizardSavePlan")?.addEventListener("click", () => handleWizardSavePlan());
  $("wizardOpenEditor")?.addEventListener("click", () => handleWizardOpenEditor());

  $("wizardBrowsePlan")?.addEventListener("click", async () => {
    const selected = await api.pickPlanFile();
    if (selected) {
      const workspaceDir = getWizardWorkspaceDir();
      const loadPath = $("wizardLoadPlanPath");
      const preview = $("wizardLoadPreview");
      if (workspaceDir && !isPathInsideWorkspace(selected, workspaceDir)) {
        state.wizard.planFilePath = "";
        if (loadPath) loadPath.value = "";
        if (preview) {
          preview.textContent = "Plan files must be inside the selected workspace directory.";
        }
        window.alert("Plan files must be inside the selected workspace directory.");
        return;
      }
      if (loadPath) loadPath.value = selected;
      if (preview) {
        try {
          const result = await api.readPlan({ workspaceDir, filePath: selected });
          if (result.ok) {
            state.wizard.planFilePath = result.path;
            preview.textContent = result.content.slice(0, 500) + (result.content.length > 500 ? "…" : "");
          } else {
            state.wizard.planFilePath = "";
            preview.textContent = result.message || "Could not read file.";
          }
        } catch {
          state.wizard.planFilePath = "";
          preview.textContent = "Could not read file.";
        }
      }
    }
  });

  $("wizardReviewPlan")?.addEventListener("click", () => handleWizardReviewPlan());

  $("wizardEditPlan")?.addEventListener("click", async () => {
    if (!state.wizard.planFilePath) return;
    try {
      const result = await api.readPlan({ workspaceDir: getWizardWorkspaceDir(), filePath: state.wizard.planFilePath });
      if (result.ok) openExistingPlanEditor(result.path, result.content);
    } catch { /* ignore */ }
  });

  $("wizardSkipReview")?.addEventListener("click", () => {
    state.wizard.planReviewed = false;
    setWizardStep(3);
  });

  $("wizardGenerateCycle")?.addEventListener("click", () => handleWizardGenerateCycle());
  $("wizardImplementCycle")?.addEventListener("click", () => handleWizardImplementCycle());

  $("wizardNextCycle")?.addEventListener("click", () => {
    const resultEl = $("wizardImplementResult");
    if (resultEl) resultEl.hidden = true;
    const nextBtn = $("wizardNextCycle");
    if (nextBtn) nextBtn.hidden = true;
    setWizardStep(3);
  });

  $("wizardBackToReview")?.addEventListener("click", () => setWizardStep(2));
  $("wizardBackToGenerate")?.addEventListener("click", () => setWizardStep(3));

  // Bidirectional workspace sync: wizard ↔ configure
  elements.wizardWorkspaceDir?.addEventListener("input", () => {
    updatePathFieldTitle(elements.wizardWorkspaceDir);
    elements.workspaceDir.value = elements.wizardWorkspaceDir.value;
    updatePathFieldTitle(elements.workspaceDir);
    renderProjectHistory();
  });
  elements.wizardWorkspaceDir?.addEventListener("change", () => {
    recoverWizardState();
  });
  elements.workspaceDir.addEventListener("change", () => {
    if (elements.wizardWorkspaceDir) {
      elements.wizardWorkspaceDir.value = elements.workspaceDir.value;
      updatePathFieldTitle(elements.wizardWorkspaceDir);
      recoverWizardState();
    }
  });

  state.helpTopics = await safeListHelpTopics();
  state.projectHistory = await safeListProjectHistory();
  syncViewerControls();
  renderProjectHistory();
  renderViewerPlaceholder("No artifact selected", "Artifact content will appear here when you open a report, plan, or log file.");
  renderLiveStatus(null);
  await checkEnvironment();
  await refreshSessions();

  // Recover wizard state after initial load
  await recoverWizardState();
}

window.addEventListener("DOMContentLoaded", bootstrap);

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { readSessionConfig } = require("./session-store");

const PROJECT_HISTORY_LIMIT = 12;
let projectHistoryStorePath = path.join(os.homedir(), ".cross-qc-desktop", "project-history.json");

function setProjectHistoryStorePath(filePath) {
  if (!filePath) {
    return;
  }
  projectHistoryStorePath = path.resolve(filePath);
}

function ensureStoreDirectory() {
  fs.mkdirSync(path.dirname(projectHistoryStorePath), { recursive: true });
}

function coerceNumber(value, fallback) {
  const numericValue = Number(value);
  return Number.isFinite(numericValue) ? numericValue : fallback;
}

function inferMetaReviewFromSessionConfig(workspaceDir, sessionId) {
  const normalizedWorkspaceDir = String(workspaceDir || "").trim();
  const normalizedSessionId = String(sessionId || "").trim();
  if (!normalizedWorkspaceDir || !normalizedSessionId) {
    return false;
  }

  try {
    return Boolean(readSessionConfig(normalizedWorkspaceDir, normalizedSessionId)?.metaReview);
  } catch {
    return false;
  }
}

function normalizeConfig(config = {}) {
  const workspaceDir = String(config.workspaceDir || "").trim();
  if (!workspaceDir) {
    return null;
  }

  return {
    workspaceDir,
    promptDir: String(config.promptDir || "").trim(),
    planFile: String(config.planFile || "").trim(),
    qcType: config.qcType === "document" ? "document" : "code",
    maxIterations: coerceNumber(config.maxIterations, 10),
    maxPlanQCIterations: coerceNumber(config.maxPlanQCIterations, 5),
    skipPlanQC: Boolean(config.skipPlanQC),
    passOnMediumOnly: Boolean(config.passOnMediumOnly),
    historyIterations: coerceNumber(config.historyIterations, 2),
    reasoningEffort: ["xhigh", "high", "medium", "low"].includes(config.reasoningEffort)
      ? config.reasoningEffort
      : "xhigh",
    claudeQCIterations: coerceNumber(config.claudeQCIterations, 0),
    deliberationMode: Boolean(config.deliberationMode),
    maxDeliberationRounds: coerceNumber(config.maxDeliberationRounds, 4),
    maxRetries: coerceNumber(config.maxRetries, 3),
    retryDelaySec: coerceNumber(config.retryDelaySec, 30)
  };
}

function sanitizeHistoryConfig(config, lastRunMetaReview) {
  if (!config) {
    return null;
  }

  if (!lastRunMetaReview) {
    return config;
  }

  return {
    ...config,
    skipPlanQC: false,
    deliberationMode: false
  };
}

function resolveLastRunMetaReview(entry, configSource, normalizedConfig) {
  if (typeof entry.lastRunMetaReview === "boolean") {
    return entry.lastRunMetaReview;
  }

  if (typeof configSource.metaReview === "boolean") {
    return configSource.metaReview;
  }

  if (typeof entry.metaReview === "boolean") {
    return entry.metaReview;
  }

  return inferMetaReviewFromSessionConfig(normalizedConfig.workspaceDir, entry.sessionId);
}

function normalizeProjectHistoryEntry(entry = {}) {
  const configSource = entry.config || entry;
  const normalizedConfig = normalizeConfig(configSource);
  if (!normalizedConfig) {
    return null;
  }

  const lastRunMetaReview = resolveLastRunMetaReview(entry, configSource, normalizedConfig);
  const config = sanitizeHistoryConfig(normalizedConfig, lastRunMetaReview);

  return {
    workspaceDir: config.workspaceDir,
    sessionId: String(entry.sessionId || "").trim(),
    planTitle: String(entry.planTitle || "").trim(),
    status: String(entry.status || "").trim(),
    updatedAt: String(entry.updatedAt || new Date().toISOString()).trim() || new Date().toISOString(),
    lastRunMetaReview,
    config
  };
}

function sortEntries(entries) {
  return entries
    .slice()
    .sort((left, right) => new Date(right.updatedAt || 0).getTime() - new Date(left.updatedAt || 0).getTime())
    .slice(0, PROJECT_HISTORY_LIMIT);
}

function readProjectHistoryStore() {
  if (!fs.existsSync(projectHistoryStorePath)) {
    return [];
  }

  try {
    const parsed = JSON.parse(fs.readFileSync(projectHistoryStorePath, "utf8"));
    if (!Array.isArray(parsed)) {
      return [];
    }
    return sortEntries(parsed.map((entry) => normalizeProjectHistoryEntry(entry)).filter(Boolean));
  } catch {
    return [];
  }
}

function writeProjectHistoryStore(entries) {
  ensureStoreDirectory();
  fs.writeFileSync(projectHistoryStorePath, `${JSON.stringify(sortEntries(entries), null, 2)}\n`, "utf8");
}

function listProjectHistory() {
  return readProjectHistoryStore();
}

function rememberProjectHistory(config, metadata = {}) {
  const nextEntry = normalizeProjectHistoryEntry({
    config,
    sessionId: metadata.sessionId,
    planTitle: metadata.planTitle,
    status: metadata.status,
    updatedAt: metadata.updatedAt,
    lastRunMetaReview: Boolean(config?.metaReview)
  });
  if (!nextEntry) {
    return readProjectHistoryStore();
  }

  const nextEntries = [
    nextEntry,
    ...readProjectHistoryStore().filter((entry) => entry.workspaceDir !== nextEntry.workspaceDir)
  ];
  writeProjectHistoryStore(nextEntries);
  return readProjectHistoryStore();
}

module.exports = {
  PROJECT_HISTORY_LIMIT,
  listProjectHistory,
  rememberProjectHistory,
  setProjectHistoryStorePath
};

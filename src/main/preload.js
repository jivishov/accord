const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("crossQc", {
  getDefaults: () => ipcRenderer.invoke("app:get-defaults"),
  checkEnvironment: (payload) => ipcRenderer.invoke("environment:check", payload),
  listSessions: (payload) => ipcRenderer.invoke("sessions:list", payload),
  getSession: (payload) => ipcRenderer.invoke("sessions:get", payload),
  listProjectHistory: () => ipcRenderer.invoke("project-history:list"),
  rememberProjectHistory: (payload) => ipcRenderer.invoke("project-history:remember", payload),
  startRun: (payload) => ipcRenderer.invoke("run:start", payload),
  resumeRun: (payload) => ipcRenderer.invoke("run:resume", payload),
  cancelRun: (payload) => ipcRenderer.invoke("run:cancel", payload),
  readArtifact: (payload) => ipcRenderer.invoke("artifact:read", payload),
  openArtifact: (payload) => ipcRenderer.invoke("artifact:open", payload),
  listHelpTopics: () => ipcRenderer.invoke("help:list"),
  readHelpTopic: (topicId) => ipcRenderer.invoke("help:read", { topicId }),
  savePlan: (payload) => ipcRenderer.invoke("plan:save", payload),
  readPlan: (payload) => ipcRenderer.invoke("plan:read", payload),
  writePlan: (payload) => ipcRenderer.invoke("plan:write", payload),
  pickPlanFile: () => ipcRenderer.invoke("dialog:pick-plan"),
  pickDirectory: (initialPath) => ipcRenderer.invoke("dialog:pick-directory", { initialPath }),
  readCycleStatus: (payload) => ipcRenderer.invoke("cycles:read-status", payload),
  watchSession: (payload, onUpdate) => {
    const listener = (_event, update) => {
      if (update.sessionId === payload.sessionId && update.workspaceDir === payload.workspaceDir) {
        onUpdate(update.session);
      }
    };
    ipcRenderer.on("session:watch-update", listener);
    ipcRenderer.send("session:watch", payload);
    return () => {
      ipcRenderer.removeListener("session:watch-update", listener);
      ipcRenderer.send("session:unwatch", payload);
    };
  }
});

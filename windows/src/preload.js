const { contextBridge, ipcRenderer, webUtils } = require("electron");

function on(channel, callback) {
  const listener = (_, payload) => callback(payload);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

contextBridge.exposeInMainWorld("ncmBridge", {
  getDefaults: () => ipcRenderer.invoke("app:getDefaults"),
  checkForUpdates: manual => ipcRenderer.invoke("app:checkForUpdates", { manual: Boolean(manual) }),
  chooseFiles: () => ipcRenderer.invoke("dialog:chooseFiles"),
  chooseFolder: recursive => ipcRenderer.invoke("dialog:chooseFolder", recursive),
  chooseOutputDirectory: () => ipcRenderer.invoke("dialog:chooseOutputDirectory"),
  expandPaths: (paths, recursive) => ipcRenderer.invoke("files:expand", paths, recursive),
  openPath: targetPath => ipcRenderer.invoke("shell:openPath", targetPath),
  startConversion: payload => ipcRenderer.invoke("converter:start", payload),
  cancelConversion: () => ipcRenderer.invoke("converter:cancel"),
  minimize: () => ipcRenderer.invoke("window:minimize"),
  maximize: () => ipcRenderer.invoke("window:maximize"),
  close: () => ipcRenderer.invoke("window:close"),
  getPathForFile: file => webUtils.getPathForFile(file),
  onConverterEvent: callback => on("converter:event", callback)
});

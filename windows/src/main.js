const path = require("node:path");
const fs = require("node:fs/promises");
const https = require("node:https");
const { app, BrowserWindow, dialog, ipcMain, shell } = require("electron");
const { convertNcmFile, findFfmpeg } = require("./shared/ncm-core");
const { LATEST_RELEASE_API, isVersionNewer, officialReleaseURL } = require("./shared/update-core");

let mainWindow;
let activeController = null;
let updateCheckPromise = null;

function defaultOutputDirectory() {
  return path.join(app.getPath("music"), "NCM 转换输出");
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1180,
    height: 760,
    minWidth: 940,
    minHeight: 630,
    title: "NCM 批量转 MP3",
    backgroundColor: "#f6f8fb",
    frame: false,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });

  mainWindow.loadFile(path.join(__dirname, "renderer", "index.html"));
  mainWindow.once("ready-to-show", () => {
    mainWindow.show();
    setTimeout(() => {
      void checkForUpdates();
    }, 1200);
  });
}

function fetchLatestRelease() {
  return new Promise((resolve, reject) => {
    const request = https.get(LATEST_RELEASE_API, {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "NCM-Batch-MP3"
      }
    }, response => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`GitHub 返回 HTTP ${response.statusCode || "未知错误"}`));
        return;
      }

      let body = "";
      response.setEncoding("utf8");
      response.on("data", chunk => {
        body += chunk;
      });
      response.once("error", reject);
      response.once("end", () => {
        try {
          resolve(JSON.parse(body));
        } catch {
          reject(new Error("GitHub 返回了无法识别的更新信息"));
        }
      });
    });

    request.setTimeout(7000, () => request.destroy(new Error("检查更新超时")));
    request.once("error", reject);
  });
}

async function showUpdateDialog(options) {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return { response: 1 };
  }
  return dialog.showMessageBox(mainWindow, options);
}

async function checkForUpdates({ manual = false } = {}) {
  if (updateCheckPromise) {
    return updateCheckPromise;
  }

  updateCheckPromise = (async () => {
    try {
      const release = await fetchLatestRelease();
      const downloadURL = officialReleaseURL(release);
      if (!downloadURL) {
        throw new Error("更新下载地址不可信");
      }

      const currentVersion = app.getVersion();
      if (isVersionNewer(release.tag_name, currentVersion)) {
        const result = await showUpdateDialog({
          type: "info",
          title: "发现新版本",
          message: `NCM 批量转 MP3 ${release.tag_name} 已发布。`,
          detail: "前往 GitHub Release 下载最新版。",
          buttons: ["前往下载", "稍后"],
          defaultId: 0,
          cancelId: 1,
          noLink: true
        });
        if (result.response === 0) {
          await shell.openExternal(downloadURL);
        }
        return { updateAvailable: true, version: release.tag_name };
      }

      if (manual) {
        await showUpdateDialog({
          type: "info",
          title: "检查更新",
          message: "当前已是最新版本。",
          buttons: ["好"],
          defaultId: 0,
          noLink: true
        });
      }
      return { updateAvailable: false, version: currentVersion };
    } catch (error) {
      if (manual) {
        await showUpdateDialog({
          type: "warning",
          title: "检查更新失败",
          message: "暂时无法检查更新，请稍后再试。",
          buttons: ["好"],
          defaultId: 0,
          noLink: true
        });
      }
      return { updateAvailable: false, error: error.message || String(error) };
    } finally {
      updateCheckPromise = null;
    }
  })();

  return updateCheckPromise;
}

async function collectNcmFiles(inputPaths, recursive) {
  const results = [];

  async function visit(candidate) {
    const stat = await fs.stat(candidate).catch(() => null);
    if (!stat) {
      return;
    }
    if (stat.isDirectory()) {
      const entries = await fs.readdir(candidate);
      for (const entry of entries) {
        const child = path.join(candidate, entry);
        const childStat = await fs.stat(child).catch(() => null);
        if (childStat?.isDirectory()) {
          if (recursive) {
            await visit(child);
          }
        } else if (childStat?.isFile() && path.extname(child).toLowerCase() === ".ncm") {
          results.push(child);
        }
      }
      return;
    }
    if (stat.isFile() && path.extname(candidate).toLowerCase() === ".ncm") {
      results.push(candidate);
    }
  }

  for (const inputPath of inputPaths) {
    await visit(inputPath);
  }

  return [...new Set(results)];
}

function ffmpegCandidates() {
  const exe = process.platform === "win32" ? "ffmpeg.exe" : "ffmpeg";
  return [
    app.isPackaged ? path.join(process.resourcesPath, "ffmpeg", exe) : null,
    path.join(app.getAppPath(), "resources", "win", "ffmpeg.exe"),
    path.join(app.getAppPath(), "..", "Resources", "ffmpeg")
  ];
}

function send(channel, payload) {
  if (!mainWindow?.isDestroyed()) {
    mainWindow.webContents.send(channel, payload);
  }
}

app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
});

ipcMain.handle("app:getDefaults", () => ({
  outputDirectory: defaultOutputDirectory(),
  ffmpegAvailable: Boolean(findFfmpeg(ffmpegCandidates()))
}));
ipcMain.handle("app:checkForUpdates", (_, options) => checkForUpdates({ manual: Boolean(options?.manual) }));

ipcMain.handle("window:minimize", () => mainWindow?.minimize());
ipcMain.handle("window:maximize", () => {
  if (!mainWindow) return;
  if (mainWindow.isMaximized()) {
    mainWindow.unmaximize();
  } else {
    mainWindow.maximize();
  }
});
ipcMain.handle("window:close", () => mainWindow?.close());

ipcMain.handle("dialog:chooseFiles", async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: "选择 NCM 文件",
    properties: ["openFile", "multiSelections"],
    filters: [{ name: "NetEase Cloud Music NCM", extensions: ["ncm"] }]
  });
  return result.canceled ? [] : result.filePaths;
});

ipcMain.handle("dialog:chooseFolder", async (_, recursive) => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: "选择包含 NCM 的文件夹",
    properties: ["openDirectory"]
  });
  if (result.canceled) {
    return [];
  }
  return collectNcmFiles(result.filePaths, recursive);
});

ipcMain.handle("dialog:chooseOutputDirectory", async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: "选择输出目录",
    properties: ["openDirectory", "createDirectory"]
  });
  return result.canceled ? null : result.filePaths[0];
});

ipcMain.handle("files:expand", async (_, inputPaths, recursive) => collectNcmFiles(inputPaths, recursive));

ipcMain.handle("shell:openPath", async (_, targetPath) => {
  await fs.mkdir(targetPath, { recursive: true });
  return shell.openPath(targetPath);
});

ipcMain.handle("converter:cancel", () => {
  activeController?.abort();
  return true;
});

ipcMain.handle("converter:start", async (_, payload) => {
  if (activeController) {
    return { ok: false, error: "已有转换任务正在运行" };
  }

  activeController = new AbortController();
  const signal = activeController.signal;
  const ffmpegPath = findFfmpeg(ffmpegCandidates());
  const startedAt = Date.now();
  let completed = 0;

  send("converter:event", {
    type: "log",
    level: "info",
    message: `开始转换 ${payload.items.length} 个文件`
  });

  try {
    for (const item of payload.items) {
      if (signal.aborted) break;
      send("converter:event", { type: "item", id: item.id, status: "running", detail: "解密中" });

      try {
        const result = await convertNcmFile(
          item.path,
          payload.options,
          ffmpegPath,
          signal,
          progress => send("converter:event", { type: "progress", id: item.id, fraction: progress.fraction })
        );
        completed += 1;
        send("converter:event", {
          type: "item",
          id: item.id,
          status: "finished",
          detail: result.message,
          outputPath: result.outputPath
        });
        send("converter:event", {
          type: "log",
          level: "success",
          message: `${path.basename(item.path)} -> ${path.basename(result.outputPath)}`
        });
      } catch (error) {
        if (signal.aborted) {
          send("converter:event", { type: "item", id: item.id, status: "queued", detail: "已取消" });
          break;
        }
        send("converter:event", {
          type: "item",
          id: item.id,
          status: "failed",
          detail: error.message || String(error)
        });
        send("converter:event", {
          type: "log",
          level: "error",
          message: `${path.basename(item.path)}：${error.message || error}`
        });
      }
    }

    const seconds = ((Date.now() - startedAt) / 1000).toFixed(1);
    send("converter:event", {
      type: "done",
      cancelled: signal.aborted,
      message: signal.aborted ? "转换已取消" : `完成 ${completed} 个文件，用时 ${seconds}s`
    });
    return { ok: true, cancelled: signal.aborted };
  } finally {
    activeController = null;
  }
});

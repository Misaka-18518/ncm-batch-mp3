const path = require("node:path");
const fs = require("node:fs/promises");
const { app, BrowserWindow, dialog, ipcMain, shell } = require("electron");
const { convertNcmFile, findFfmpeg } = require("./shared/ncm-core");

let mainWindow;
let activeController = null;

function defaultOutputDirectory() {
  return path.join(app.getPath("music"), "NCM 转换输出");
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1180,
    height: 760,
    minWidth: 980,
    minHeight: 660,
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
  mainWindow.once("ready-to-show", () => mainWindow.show());
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

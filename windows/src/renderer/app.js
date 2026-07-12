const mockBridge = {
  async getDefaults() {
    return {
      outputDirectory: "C:\\Users\\You\\Music\\NCM 转换输出",
      ffmpegAvailable: true
    };
  },
  async checkForUpdates() { return { updateAvailable: false }; },
  async chooseFiles() { return []; },
  async chooseFolder() { return []; },
  async chooseOutputDirectory() { return null; },
  async expandPaths(paths) { return paths.filter(Boolean); },
  async openPath() { return ""; },
  async startConversion() { return { ok: true }; },
  async cancelConversion() { return true; },
  getPathForFile(file) { return file.path || file.name; },
  onConverterEvent() { return () => {}; },
  minimize() {},
  maximize() {},
  close() {}
};

const bridge = window.ncmBridge || mockBridge;

const state = {
  items: [],
  selectedId: null,
  outputDirectory: "",
  outputMode: "mp3",
  renameByMetadata: true,
  overwriteExisting: false,
  recursiveFolderSearch: true,
  converting: false
};

const $ = selector => document.querySelector(selector);

const elements = {
  queuedStat: $("#queuedStat"),
  finishedStat: $("#finishedStat"),
  failedStat: $("#failedStat"),
  ffmpegStatus: $("#ffmpegStatus"),
  queueCounter: $("#queueCounter"),
  dropSurface: $("#dropSurface"),
  dropZone: $("#dropZone"),
  queueList: $("#queueList"),
  outputDirectoryInput: $("#outputDirectoryInput"),
  renameToggle: $("#renameToggle"),
  overwriteToggle: $("#overwriteToggle"),
  recursiveToggle: $("#recursiveToggle"),
  progressText: $("#progressText"),
  progressFill: $("#progressFill"),
  logList: $("#logList"),
  addFilesButton: $("#addFilesButton"),
  addFolderButton: $("#addFolderButton"),
  removeButton: $("#removeButton"),
  clearButton: $("#clearButton"),
  openOutputButton: $("#openOutputButton"),
  chooseOutputButton: $("#chooseOutputButton"),
  startButton: $("#startButton"),
  cancelButton: $("#cancelButton"),
  checkUpdateButton: $("#checkUpdateButton"),
  segments: Array.from(document.querySelectorAll(".segment")),
  easterDot: $("#easterDot"),
  easterOverlay: $("#easterOverlay"),
  easterClose: $("#easterClose"),
  easterDays: $("#easterDays")
};

function makeId() {
  if (crypto.randomUUID) {
    return crypto.randomUUID();
  }
  return `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function basename(filePath) {
  return filePath.split(/[\\/]/).filter(Boolean).pop() || filePath;
}

function dirname(filePath) {
  const normalized = filePath.replaceAll("\\", "/");
  const index = normalized.lastIndexOf("/");
  return index >= 0 ? filePath.slice(0, index) : filePath;
}

function statusSymbol(status) {
  if (status === "finished") return "✓";
  if (status === "failed") return "!";
  if (status === "running") return "↻";
  return "♪";
}

function showEasterEgg() {
  elements.easterDays.textContent = window.NCMEasterEgg.message();
  elements.easterOverlay.classList.remove("hidden");
}

function hideEasterEgg() {
  elements.easterOverlay.classList.add("hidden");
}

function counts() {
  return {
    queued: state.items.filter(item => item.status === "queued").length,
    running: state.items.filter(item => item.status === "running").length,
    finished: state.items.filter(item => item.status === "finished").length,
    failed: state.items.filter(item => item.status === "failed").length
  };
}

function addLog(message, level = "info") {
  if (elements.logList.querySelector(".muted")) {
    elements.logList.innerHTML = "";
  }
  const line = document.createElement("p");
  line.className = `log-line ${level}`;
  line.textContent = `[${new Date().toLocaleTimeString()}] ${message}`;
  elements.logList.append(line);
  elements.logList.scrollTop = elements.logList.scrollHeight;
}

function setConverting(value) {
  state.converting = value;
  elements.startButton.classList.toggle("hidden", value);
  elements.cancelButton.classList.toggle("hidden", !value);
  elements.addFilesButton.disabled = value;
  elements.addFolderButton.disabled = value;
  elements.removeButton.disabled = value || !state.selectedId;
  elements.clearButton.disabled = value || state.items.length === 0;
  render();
}

function renderStats() {
  const stat = counts();
  elements.queuedStat.textContent = stat.queued + stat.running;
  elements.finishedStat.textContent = stat.finished;
  elements.failedStat.textContent = stat.failed;
  elements.queueCounter.textContent = `${state.items.length} 个文件`;
  elements.progressText.textContent = `${stat.finished + stat.failed}/${state.items.length}`;
  const fraction = state.items.length ? ((stat.finished + stat.failed) / state.items.length) * 100 : 0;
  elements.progressFill.style.width = `${Math.max(0, Math.min(100, fraction))}%`;
}

function renderQueue() {
  const empty = state.items.length === 0;
  elements.dropZone.classList.toggle("hidden", !empty);
  elements.queueList.classList.toggle("hidden", empty);
  if (empty) {
    elements.queueList.innerHTML = "";
    return;
  }

  elements.queueList.innerHTML = "";
  for (const item of state.items) {
    const row = document.createElement("button");
    row.type = "button";
    row.className = `queue-row ${item.status} ${item.id === state.selectedId ? "selected" : ""}`;
    row.dataset.id = item.id;
    row.innerHTML = `
      <span class="status-dot">${statusSymbol(item.status)}</span>
      <span class="file-cell">
        <span class="file-name">${basename(item.path)}</span>
        <span class="file-path">${item.outputPath || dirname(item.path)}</span>
      </span>
      <span class="row-detail">${item.detail || "等待"}</span>
    `;
    row.addEventListener("click", () => {
      state.selectedId = item.id;
      render();
    });
    elements.queueList.append(row);
  }
}

function renderControls() {
  elements.outputDirectoryInput.value = state.outputDirectory;
  elements.renameToggle.checked = state.renameByMetadata;
  elements.overwriteToggle.checked = state.overwriteExisting;
  elements.recursiveToggle.checked = state.recursiveFolderSearch;
  elements.segments.forEach(segment => {
    segment.classList.toggle("selected", segment.dataset.mode === state.outputMode);
  });
  elements.removeButton.disabled = state.converting || !state.selectedId;
  elements.clearButton.disabled = state.converting || state.items.length === 0;
  elements.startButton.disabled = state.converting || state.items.length === 0;
}

function render() {
  renderStats();
  renderQueue();
  renderControls();
}

async function addInputPaths(paths) {
  const expanded = await bridge.expandPaths(paths, state.recursiveFolderSearch);
  const existing = new Set(state.items.map(item => item.path.toLowerCase()));
  let added = 0;

  for (const filePath of expanded) {
    if (!filePath || existing.has(filePath.toLowerCase())) {
      continue;
    }
    state.items.push({
      id: makeId(),
      path: filePath,
      status: "queued",
      detail: "等待",
      outputPath: "",
      progress: 0
    });
    existing.add(filePath.toLowerCase());
    added += 1;
  }

  if (added) {
    addLog(`已添加 ${added} 个 NCM 文件`, "success");
  }
  render();
}

async function chooseFiles() {
  const paths = await bridge.chooseFiles();
  await addInputPaths(paths);
}

async function chooseFolder() {
  const paths = await bridge.chooseFolder(state.recursiveFolderSearch);
  await addInputPaths(paths);
}

function selectedItem() {
  return state.items.find(item => item.id === state.selectedId);
}

function removeSelected() {
  if (!state.selectedId || state.converting) return;
  state.items = state.items.filter(item => item.id !== state.selectedId);
  state.selectedId = null;
  render();
}

function clearQueue() {
  if (state.converting) return;
  state.items = [];
  state.selectedId = null;
  elements.logList.innerHTML = '<p class="muted">暂无记录</p>';
  render();
}

async function chooseOutputDirectory() {
  const directory = await bridge.chooseOutputDirectory();
  if (directory) {
    state.outputDirectory = directory;
    render();
  }
}

async function startConversion() {
  if (!state.items.length || state.converting) return;
  setConverting(true);

  for (const item of state.items) {
    item.status = "queued";
    item.detail = "等待";
    item.outputPath = "";
    item.progress = 0;
  }
  render();

  const result = await bridge.startConversion({
    items: state.items.map(item => ({ id: item.id, path: item.path })),
    options: {
      outputDirectory: state.outputDirectory,
      outputMode: state.outputMode,
      renameByMetadata: state.renameByMetadata,
      overwriteExisting: state.overwriteExisting
    }
  });

  if (!result?.ok && result?.error) {
    addLog(result.error, "error");
    setConverting(false);
  }
}

function handleConverterEvent(event) {
  if (event.type === "log") {
    addLog(event.message, event.level);
    return;
  }

  if (event.type === "progress") {
    const item = state.items.find(candidate => candidate.id === event.id);
    if (item) {
      item.progress = event.fraction;
      item.detail = event.fraction > 0.88 ? "转码中" : "解密中";
      render();
    }
    return;
  }

  if (event.type === "item") {
    const item = state.items.find(candidate => candidate.id === event.id);
    if (item) {
      item.status = event.status;
      item.detail = event.detail || item.detail;
      item.outputPath = event.outputPath || item.outputPath;
      if (event.status === "finished") {
        item.progress = 1;
      }
      render();
    }
    return;
  }

  if (event.type === "done") {
    addLog(event.message, event.cancelled ? "info" : "success");
    setConverting(false);
  }
}

function wireEvents() {
  $("#minimizeButton").addEventListener("click", () => bridge.minimize());
  $("#maximizeButton").addEventListener("click", () => bridge.maximize());
  $("#closeButton").addEventListener("click", () => bridge.close());
  elements.checkUpdateButton.addEventListener("click", () => bridge.checkForUpdates(true));

  elements.addFilesButton.addEventListener("click", chooseFiles);
  elements.addFolderButton.addEventListener("click", chooseFolder);
  elements.removeButton.addEventListener("click", removeSelected);
  elements.clearButton.addEventListener("click", clearQueue);
  elements.chooseOutputButton.addEventListener("click", chooseOutputDirectory);
  elements.openOutputButton.addEventListener("click", () => bridge.openPath(state.outputDirectory));
  elements.startButton.addEventListener("click", startConversion);
  elements.cancelButton.addEventListener("click", () => bridge.cancelConversion());
  elements.easterDot.addEventListener("click", showEasterEgg);
  elements.easterClose.addEventListener("click", hideEasterEgg);
  elements.easterOverlay.addEventListener("click", event => {
    if (event.target === elements.easterOverlay) {
      hideEasterEgg();
    }
  });
  window.addEventListener("keydown", event => {
    if (event.key === "Escape") {
      hideEasterEgg();
    }
  });

  elements.outputDirectoryInput.addEventListener("change", event => {
    state.outputDirectory = event.target.value.trim();
    render();
  });
  elements.renameToggle.addEventListener("change", event => {
    state.renameByMetadata = event.target.checked;
  });
  elements.overwriteToggle.addEventListener("change", event => {
    state.overwriteExisting = event.target.checked;
  });
  elements.recursiveToggle.addEventListener("change", event => {
    state.recursiveFolderSearch = event.target.checked;
  });
  elements.segments.forEach(segment => {
    segment.addEventListener("click", () => {
      state.outputMode = segment.dataset.mode;
      render();
    });
  });

  for (const target of [document.body, elements.dropSurface]) {
    target.addEventListener("dragover", event => {
      event.preventDefault();
      elements.dropSurface.classList.add("drag-over");
    });
    target.addEventListener("dragleave", event => {
      if (event.target === target) {
        elements.dropSurface.classList.remove("drag-over");
      }
    });
    target.addEventListener("drop", async event => {
      event.preventDefault();
      elements.dropSurface.classList.remove("drag-over");
      const paths = Array.from(event.dataTransfer.files)
        .map(file => bridge.getPathForFile(file))
        .filter(Boolean);
      await addInputPaths(paths);
    });
  }

  bridge.onConverterEvent(handleConverterEvent);
}

async function boot() {
  wireEvents();
  const defaults = await bridge.getDefaults();
  state.outputDirectory = defaults.outputDirectory;
  elements.ffmpegStatus.textContent = defaults.ffmpegAvailable
    ? "转换引擎已就绪"
    : "转换引擎不可用";
  render();

  if (!window.ncmBridge) {
    await addInputPaths([
      "C:\\Music\\网易云\\Codex - Synthetic Track.ncm",
      "C:\\Music\\网易云\\夜间电台.ncm",
      "C:\\Music\\网易云\\GTA Drive Mix.ncm"
    ]);
    const demo = selectedItem();
    if (demo) {
      demo.status = "finished";
      demo.detail = "已导出 MP3";
      demo.outputPath = "C:\\Users\\You\\Music\\NCM 转换输出\\Codex - Synthetic Track.mp3";
      demo.progress = 1;
    }
    addLog("演示截图模式：界面预览数据已载入", "success");
    render();
  }
}

boot();

const fs = require("node:fs");
const path = require("node:path");
const { app, BrowserWindow } = require("electron");

const outputPath = process.argv[2] || path.join(process.cwd(), "windows-ui-preview.png");
const showEaster = process.argv.includes("--easter");

async function main() {
  await app.whenReady();
  const window = new BrowserWindow({
    width: 1280,
    height: 800,
    show: false,
    webPreferences: {
      offscreen: true,
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  await window.loadFile(path.join(__dirname, "..", "src", "renderer", "index.html"));
  await new Promise(resolve => setTimeout(resolve, 1000));
  if (showEaster) {
    await window.webContents.executeJavaScript("document.getElementById('easterDot').click()");
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  const image = await window.capturePage();
  fs.writeFileSync(outputPath, image.toPNG());
  app.quit();
}

main().catch(error => {
  console.error(error);
  app.quit();
  process.exit(1);
});

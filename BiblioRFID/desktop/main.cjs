const { app, BrowserWindow, Menu, shell } = require("electron");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");

const requestedPort = Number(process.env.BIBLIORFID_DESKTOP_PORT) || 0;
let serverPort = requestedPort || 4310;
let serverUrl = `http://127.0.0.1:${serverPort}`;
let mainWindow = null;
let serverProcess = null;

const hasExplicitUserData = process.argv.some((argument) =>
  argument.startsWith("--user-data-dir"),
);
if (app.isPackaged && !hasExplicitUserData) {
  app.setPath("userData", path.join(app.getPath("appData"), "biblio-rfid"));
}

if (!app.requestSingleInstanceLock()) app.quit();

app.on("second-instance", () => {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
});

function appRoot() {
  return app.isPackaged
    ? path.join(process.resourcesPath, "app.asar")
    : path.resolve(__dirname, "..");
}

function prepareDataDirectory() {
  const dataDirectory = path.join(app.getPath("userData"), "data");
  fs.mkdirSync(dataDirectory, { recursive: true });
  if (!app.isPackaged) return dataDirectory;

  const seedDirectory = path.join(process.resourcesPath, "seed-data");
  for (const name of ["library.db", "library.db-wal", "library.db-shm"]) {
    const source = path.join(seedDirectory, name);
    const destination = path.join(dataDirectory, name);
    if (fs.existsSync(source) && !fs.existsSync(destination))
      fs.copyFileSync(source, destination);
  }
  return dataDirectory;
}

function prepareBridgeDirectory() {
  if (!app.isPackaged) return path.join(appRoot(), "bridge");

  const bundledBridge = path.join(appRoot(), "bridge");
  const bridgeDirectory = path.join(
    app.getPath("userData"),
    "native",
    app.getVersion(),
    "bridge",
  );
  const files = [
    "BridgeSettings.cs",
    "build.ps1",
    "ReaderBridge.cs",
    path.join("bin", "GReaderApi.dll"),
    path.join("bin", "ReaderBridge.exe"),
  ];

  for (const relativePath of files) {
    const source = path.join(bundledBridge, relativePath);
    const destination = path.join(bridgeDirectory, relativePath);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    if (!fs.existsSync(destination)) fs.copyFileSync(source, destination);
  }
  return bridgeDirectory;
}

async function serverReady() {
  try {
    const response = await fetch(`${serverUrl}/api/auth/status`, {
      signal: AbortSignal.timeout(700),
    });
    return response.ok;
  } catch {
    return false;
  }
}

function portAvailable(port) {
  return new Promise((resolve) => {
    const probe = net.createServer();
    probe.unref();
    probe.once("error", () => resolve(false));
    probe.listen(port, "127.0.0.1", () =>
      probe.close(() => resolve(true)),
    );
  });
}

async function selectServerPort() {
  if (requestedPort) return;
  while (serverPort < 4320 && !(await portAvailable(serverPort))) serverPort++;
  if (serverPort >= 4320)
    throw new Error("Aucun port local Bibliotèque ZTF n’est disponible.");
  serverUrl = `http://127.0.0.1:${serverPort}`;
}

async function startServer() {
  await selectServerPort();
  if (requestedPort && (await serverReady())) return;
  const root = appRoot();
  serverProcess = spawn(process.execPath, [path.join(root, "server.js")], {
    cwd: app.isPackaged ? process.resourcesPath : root,
    windowsHide: true,
    env: {
      ...process.env,
      ELECTRON_RUN_AS_NODE: "1",
      PORT: String(serverPort),
      BIBLIORFID_DATA_DIR: prepareDataDirectory(),
      BIBLIORFID_BRIDGE_DIR: prepareBridgeDirectory(),
    },
    stdio: "ignore",
  });

  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (await serverReady()) return;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("Le service local Bibliotèque ZTF ne répond pas.");
}

function createWindow() {
  mainWindow = new BrowserWindow({
    title: "Bibliotèque ZTF",
    width: 1440,
    height: 940,
    minWidth: 1040,
    minHeight: 700,
    show: false,
    backgroundColor: "#f4f7fa",
    titleBarStyle: "hidden",
    titleBarOverlay: {
      color: "#ffffff",
      symbolColor: "#153047",
      height: 38,
    },
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith(serverUrl)) return { action: "allow" };
    void shell.openExternal(url);
    return { action: "deny" };
  });
  mainWindow.webContents.on("will-navigate", (event, url) => {
    if (url.startsWith(serverUrl)) return;
    event.preventDefault();
    void shell.openExternal(url);
  });
  mainWindow.once("ready-to-show", () => mainWindow.show());
  mainWindow.on("closed", () => {
    mainWindow = null;
  });
  void mainWindow.loadURL(`${serverUrl}/?desktop=1#station`);
}

Menu.setApplicationMenu(null);
app.setAppUserModelId("com.bibliorfid.desktop");

app.whenReady().then(async () => {
  try {
    await startServer();
    createWindow();
  } catch (error) {
    const { dialog } = require("electron");
    dialog.showErrorBox("Bibliotèque ZTF", error.message || String(error));
    app.quit();
  }
});

app.on("activate", () => {
  if (!mainWindow) createWindow();
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("before-quit", () => {
  if (serverProcess && !serverProcess.killed) serverProcess.kill();
});

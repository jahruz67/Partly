'use strict';
const { app, BrowserWindow, ipcMain, dialog, protocol, net } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { spawn } = require('node:child_process');
const storage = require('../lib/storage-service.cjs');
const { configureFeatures } = require('./feature-ipc.cjs');

protocol.registerSchemesAsPrivileged([{ scheme: 'partly', privileges: { standard: true, secure: true, supportFetchAPI: true } }]);
let mainWindow;
let applying = false;
const userFile = (name) => path.join(app.getPath('userData'), name);
async function readJson(name, fallback) {
  try { return JSON.parse(await fs.readFile(userFile(name), 'utf8')); } catch { return fallback; }
}
async function writeJson(name, value) {
  await fs.mkdir(app.getPath('userData'), { recursive: true });
  const target = userFile(name);
  await fs.writeFile(target + '.tmp', JSON.stringify(value, null, 2), 'utf8');
  await fs.rename(target + '.tmp', target);
}
function handle(channel, fn) {
  ipcMain.handle(channel, async (event, ...args) => {
    if (!mainWindow || event.sender !== mainWindow.webContents || event.senderFrame !== mainWindow.webContents.mainFrame || event.senderFrame.url !== 'partly://app/src/index.html') {
      throw new Error('Untrusted application request.');
    }
    return fn(...args);
  });
}
function configureIpc() {
  const features = configureFeatures({ handle, getWindow: () => mainWindow, readJson, writeJson, isBusy: () => applying, setBusy: (value) => { applying = value; } });
  handle('storage:inventory', () => storage.getInventory());
  handle('storage:limits', (target) => storage.getPartitionLimits(target));
  handle('storage:check', async (target) => {
    if (applying) throw new Error('Wait for the current disk operation to finish.');
    return storage.checkPartition(target);
  });
  handle('storage:apply', (payload) => features.apply(payload));
  handle('settings:get', () => features.getSettings());
  handle('settings:set', (input) => features.saveSettings(input));
  handle('history:get', () => readJson('history.json', []));
  handle('diagnostics:export', async () => {
    const selected = await dialog.showSaveDialog(mainWindow, { title: 'Save Partly 20 diagnostics', defaultPath: 'Partly-20-diagnostics.json', filters: [{ name: 'JSON', extensions: ['json'] }] });
    if (selected.canceled) return { cancelled: true };
    const inventory = await storage.getInventory();
    await fs.writeFile(selected.filePath, JSON.stringify({ app: 'Partly 20', version: app.getVersion(), inventory, history: await readJson('history.json', []) }, null, 2), 'utf8');
    return { path: selected.filePath };
  });
  handle('app:elevate', async () => {
    if (applying) throw new Error('Wait for disk operations to finish.');
    const quote = (value) => "'" + value.replace(/'/g, "''") + "'";
    const args = app.isPackaged ? '' : ' -ArgumentList ' + quote('"' + app.getAppPath() + '"');
    const source = `Start-Process -FilePath ${quote(process.execPath)}${args} -Verb RunAs -WindowStyle Hidden -ErrorAction Stop`;
    app.releaseSingleInstanceLock();
    try { await new Promise((resolve, reject) => {
      const ps = spawn(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(source, 'utf16le').toString('base64')], { windowsHide: true, stdio: 'pipe' });
      let error = '';
      ps.stderr.on('data', (chunk) => { error += chunk; });
      ps.on('error', reject);
      ps.on('exit', (code) => code === 0 ? resolve() : reject(new Error(error || 'Administrator restart was cancelled.')));
    }); } catch (error) { app.requestSingleInstanceLock(); throw error; }
    app.quit();
    return true;
  });
  handle('window:control', (action) => {
    if (action === 'minimize') mainWindow.minimize();
    if (action === 'maximize') mainWindow.isMaximized() ? mainWindow.unmaximize() : mainWindow.maximize();
    if (action === 'close') mainWindow.close();
  });
}
function createWindow() {
  mainWindow = new BrowserWindow({ width: 1440, height: 900, minWidth: 1000, minHeight: 650, show: false, frame: false, title: 'Partly 20', backgroundColor: '#ffffff',
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true }
  });
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (event) => event.preventDefault());
  mainWindow.webContents.on('will-prevent-unload', (event) => {
    if (applying) return;
    const answer = dialog.showMessageBoxSync(mainWindow, { type: 'question', title: 'Close Partly 20?', message: 'Discard pending changes and close?', detail: 'Queued changes have not been written to disk.', buttons: ['Keep open', 'Discard and close'], defaultId: 0, cancelId: 0, noLink: true });
    if (answer === 1) event.preventDefault();
  });
  mainWindow.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  mainWindow.once('ready-to-show', () => mainWindow.show());
  mainWindow.on('close', (event) => {
    if (applying) { event.preventDefault(); dialog.showMessageBox(mainWindow, { message: 'Disk changes are still running.', detail: 'Keep Partly 20 open until Windows finishes the current operation.', buttons: ['OK'] }); }
  });
  mainWindow.loadURL('partly://app/src/index.html');
}
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { if (mainWindow) { if (mainWindow.isMinimized()) mainWindow.restore(); mainWindow.focus(); } });
  app.whenReady().then(() => {
    app.setAppUserModelId('local.partly20.desktop');
    protocol.handle('partly', (request) => {
      const url = new URL(request.url);
      const relative = decodeURIComponent(url.pathname).replace(/^\/+/, '');
      const root = app.getAppPath();
      const file = path.resolve(root, relative);
      if (url.hostname !== 'app' || !file.startsWith(root + path.sep) || !/^(src|assets)[\\/]/.test(relative)) return new Response('Not found', { status: 404 });
      return net.fetch(pathToFileURL(file).href);
    });
    configureIpc();
    createWindow();
  });
  app.on('window-all-closed', () => app.quit());
}

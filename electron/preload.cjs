'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('partly', Object.freeze({
  inventory: () => ipcRenderer.invoke('storage:inventory'),
  limits: (target) => ipcRenderer.invoke('storage:limits', target),
  apply: (payload) => ipcRenderer.invoke('storage:apply', payload),
  check: (target) => ipcRenderer.invoke('storage:check', target),
  getSettings: () => ipcRenderer.invoke('settings:get'),
  setSettings: (settings) => ipcRenderer.invoke('settings:set', settings),
  getHistory: () => ipcRenderer.invoke('history:get'),
  exportDiagnostics: () => ipcRenderer.invoke('diagnostics:export'),
  restartAsAdmin: () => ipcRenderer.invoke('app:elevate'),
  runTool: (action, payload) => ipcRenderer.invoke('features:run', action, payload),
  cancelJob: () => ipcRenderer.invoke('features:cancel'),
  choosePath: (options) => ipcRenderer.invoke('features:choose-path', options),
  capabilities: () => ipcRenderer.invoke('features:capabilities'),
  findOperatingSystems: () => ipcRenderer.invoke('features:find-os'),
  getInfo: () => ipcRenderer.invoke('features:info'),
  copyText: (text) => ipcRenderer.invoke('features:copy-text', text),
  openFolder: (file) => ipcRenderer.invoke('features:open-folder', file),
  openExternal: (url) => ipcRenderer.invoke('features:open-external', url),
  getEmailState: () => ipcRenderer.invoke('features:email-state'),
  saveEmail: (settings) => ipcRenderer.invoke('features:save-email', settings),
  testNotification: () => ipcRenderer.invoke('features:test-notification'),
  testEmail: () => ipcRenderer.invoke('features:test-email'),
  checkUpdates: () => ipcRenderer.invoke('features:check-updates'),
  installUpdate: () => ipcRenderer.invoke('features:install-update'),
  cancelShutdown: () => ipcRenderer.invoke('features:cancel-shutdown'),
  windowControl: (action) => ipcRenderer.invoke('window:control', action),
  onProgress: (callback) => {
    const listener = (_event, value) => callback(value);
    ipcRenderer.on('storage:progress', listener);
    return () => ipcRenderer.removeListener('storage:progress', listener);
  }
}));

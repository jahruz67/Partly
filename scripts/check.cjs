'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.join(__dirname, '..');
let failed = false;
for (const folder of ['src', 'electron', 'lib', 'scripts', 'tests']) {
  if (!fs.existsSync(path.join(root, folder))) continue;
  for (const name of fs.readdirSync(path.join(root, folder))) {
    if (!/\.(js|cjs|mjs)$/.test(name)) continue;
    const result = spawnSync(process.execPath, ['--check', path.join(root, folder, name)], { encoding: 'utf8' });
    if (result.status !== 0) { process.stderr.write(result.stderr); failed = true; }
  }
}
if (failed) process.exit(1);
console.log('JavaScript syntax checks passed.');

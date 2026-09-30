// detached launcher: starts a command outside the caller's job tree so it survives the tool call
import { spawn } from 'node:child_process';
import { openSync, mkdirSync } from 'node:fs';

const logPath = process.argv[2];
const cwd = process.argv[3];
const cmd = process.argv[4];
const args = process.argv.slice(5);

mkdirSync('F:\\deepseek\\.hindsight-home\\tmp', { recursive: true });
const out = openSync(logPath, 'a');
const child = spawn(cmd, args, {
  cwd,
  detached: true,
  windowsHide: true,
  stdio: ['ignore', out, out],
  env: process.env,
});
child.unref();
console.log('spawned pid=' + child.pid + ' -> ' + logPath);

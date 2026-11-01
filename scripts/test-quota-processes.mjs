// Isolated local-filesystem test. No SSH or user credentials are used.
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { strict as assert } from 'node:assert';
import { CommandQuota } from '../build/policy/quota.js';

const dir = mkdtempSync(join(tmpdir(), 'mcp-quota-processes-'));
const file = join(dir, 'quota.json');
const moduleUrl = new URL('../build/policy/quota.js', import.meta.url).href;
const source = `
import { CommandQuota } from ${JSON.stringify(moduleUrl)};
const q = new CommandQuota(undefined, process.argv[1]);
let allowed = 0;
for (let i = 0; i < 10; i++) {
  for (let retry = 0; ; retry++) {
    try { if (q.consume('shared', 17).allowed) allowed++; break; }
    catch (error) {
      if (!String(error).includes('locked') || retry >= 100) throw error;
      await new Promise(r => setTimeout(r, 5));
    }
  }
}
console.log(allowed);
`;
try {
  const results = await Promise.all(Array.from({ length: 6 }, () => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--input-type=module', '-e', source, file], { stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '', errors = '';
    child.stdout.on('data', chunk => output += chunk);
    child.stderr.on('data', chunk => errors += chunk);
    child.on('error', reject);
    child.on('exit', code => code === 0 ? resolve(Number(output.trim())) : reject(new Error(errors)));
  })));
  assert.equal(results.reduce((a, b) => a + b, 0), 17);
  assert.equal(new CommandQuota(undefined, file).consume('shared', 17).allowed, false);
  console.log('PASS: six processes share exactly 17 reservations; new process/store cannot reset the quota');
} finally { rmSync(dir, { recursive: true, force: true }); }

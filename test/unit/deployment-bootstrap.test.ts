import { describe, it, expect } from 'vitest';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// The Python harness rewrites every target path into TemporaryDirectory and
// stubs account/systemd/sshd tools. It never opens SSH or modifies real accounts.
const hasPython = spawnSync('python3', ['--version']).status === 0;
describe.skipIf(process.platform !== 'linux' || !hasPython)('isolated bootstrap transactions', () => {
  it('passes the account, authorization, rollback and concurrency fixtures', () => {
    const script = fileURLToPath(new URL('../scripts/bootstrap-transactions.test.py', import.meta.url));
    const result = spawnSync('python3', [script], { encoding: 'utf8', timeout: 60_000 });
    expect(result.error, result.stderr).toBeUndefined();
    expect(result.status, result.stdout + result.stderr).toBe(0);
    expect(result.stderr).toContain('Ran 14 tests');
  }, 65_000);
});

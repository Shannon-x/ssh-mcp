import { describe, it, expect } from 'vitest';
import { CommandQuota } from '../../../src/policy/quota.js';

const HOUR = 60 * 60 * 1000;

describe('CommandQuota', () => {
  it('treats an absent or zero limit as unlimited', () => {
    const q = new CommandQuota();
    for (let i = 0; i < 100; i++) {
      expect(q.consume('dev', 0).allowed).toBe(true);
      expect(q.consume('dev', undefined).allowed).toBe(true);
    }
    // Unlimited calls are not recorded, so they cannot leak into a later limit.
    expect(q.used('dev')).toBe(0);
  });

  it('allows exactly `limit` commands then refuses', () => {
    const q = new CommandQuota();
    for (let i = 0; i < 3; i++) {
      const d = q.consume('dev', 3);
      expect(d.allowed).toBe(true);
      expect(d.remaining).toBe(2 - i);
    }
    const denied = q.consume('dev', 3);
    expect(denied.allowed).toBe(false);
    expect(denied.remaining).toBe(0);
    expect(denied.retryAt).toBeInstanceOf(Date);
  });

  it('counts each profile separately', () => {
    const q = new CommandQuota();
    q.consume('a', 1);
    expect(q.consume('a', 1).allowed).toBe(false);
    expect(q.consume('b', 1).allowed).toBe(true);
  });

  // A refusal that consumed budget would keep pushing the window forward, so a
  // blocked agent could never recover.
  it('does not consume budget on refusal', () => {
    const now = Date.now();
    const q = new CommandQuota();
    q.consume('dev', 1, now);

    const first = q.consume('dev', 1, now + 1000);
    const second = q.consume('dev', 1, now + 2000);
    expect(first.allowed).toBe(false);
    expect(second.allowed).toBe(false);
    // Both refusals report the same reset moment: the original hit ageing out.
    expect(second.retryAt!.getTime()).toBe(first.retryAt!.getTime());
  });

  it('frees budget as commands age out of the window', () => {
    const now = Date.now();
    const q = new CommandQuota();
    q.consume('dev', 2, now);
    q.consume('dev', 2, now + HOUR);
    expect(q.consume('dev', 2, now + 2 * HOUR).allowed).toBe(false);

    // 24h after the first hit, one slot is free again — but not two.
    expect(q.consume('dev', 2, now + 24 * HOUR + 1).allowed).toBe(true);
    expect(q.consume('dev', 2, now + 24 * HOUR + 2).allowed).toBe(false);
  });

  // A calendar-day reset would let an agent spend the full quota just before
  // midnight and the full quota again just after — twice the intended work.
  it('uses a sliding window, not a calendar day', () => {
    const now = Date.now();
    const q = new CommandQuota();
    for (let i = 0; i < 5; i++) q.consume('dev', 5, now + i);
    expect(q.consume('dev', 5, now + 23 * HOUR).allowed).toBe(false);
    expect(q.consume('dev', 5, now + 24 * HOUR + 10).allowed).toBe(true);
  });

  it('reports usage in the current window', () => {
    const now = Date.now();
    const q = new CommandQuota();
    q.consume('dev', 10, now);
    q.consume('dev', 10, now + HOUR);
    expect(q.used('dev', now + 2 * HOUR)).toBe(2);
    expect(q.used('dev', now + 25 * HOUR)).toBe(0);
  });
});

describe('durable quota', () => {
  it('shares budget across stores and preserves it after restart', async () => {
    const { mkdtempSync, rmSync } = await import('node:fs');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    const dir = mkdtempSync(join(tmpdir(), 'mcp-quota-'));
    try {
      const file = join(dir, 'quota.json');
      const first = new CommandQuota(undefined, file);
      const second = new CommandQuota(undefined, file);
      expect(first.consume('dev', 2, 1000).allowed).toBe(true);
      expect(second.consume('dev', 2, 1001).allowed).toBe(true);
      expect(new CommandQuota(undefined, file).consume('dev', 2, 1002).allowed).toBe(false);
      expect(new CommandQuota(undefined, file).consume('dev', 2, 1000 + 24 * HOUR).allowed).toBe(true);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it('fails closed on corrupt state or a held/crash lock without overwriting evidence', async () => {
    const { mkdtempSync, rmSync, writeFileSync, readFileSync, mkdirSync } = await import('node:fs');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    const dir = mkdtempSync(join(tmpdir(), 'mcp-quota-'));
    try {
      const file = join(dir, 'quota.json');
      writeFileSync(file, 'not json', { mode: 0o600 });
      expect(() => new CommandQuota(undefined, file).consume('dev', 2)).toThrow('QUOTA_UNAVAILABLE');
      expect(readFileSync(file, 'utf8')).toBe('not json');
      mkdirSync(`${file}.lock`);
      expect(() => new CommandQuota(undefined, file).consume('dev', 2)).toThrow('locked');
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it.skipIf(process.platform === 'win32')('rejects symlink state and does not modify the target', async () => {
    const { mkdtempSync, rmSync, writeFileSync, readFileSync, symlinkSync } = await import('node:fs');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    const dir = mkdtempSync(join(tmpdir(), 'mcp-quota-'));
    try {
      const target = join(dir, 'target');
      writeFileSync(target, 'keep');
      symlinkSync(target, join(dir, 'quota.json'));
      expect(() => new CommandQuota(undefined, join(dir, 'quota.json')).consume('dev', 2)).toThrow('QUOTA_UNAVAILABLE');
      expect(readFileSync(target, 'utf8')).toBe('keep');
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});

it('shares quota between HTTP-session pipelines with the same registry', async () => {
  const { createPipeline } = await import('../../../src/tools/pipeline.js');
  const registry = {};
  const deps = { registry } as unknown as import('../../../src/tools/pipeline.js').ToolDeps;
  const first = createPipeline(deps);
  const second = createPipeline(deps);
  expect(first.quota).toBe(second.quota);
  expect(first.quota.consume('dev', 1).allowed).toBe(true);
  expect(second.quota.consume('dev', 1).allowed).toBe(false);
});

it.skipIf(process.platform === 'win32')('refuses a symlink or other-user-writable quota directory', async () => {
  const { mkdtempSync, rmSync, symlinkSync, mkdirSync, chmodSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const dir = mkdtempSync(join(tmpdir(), 'mcp-quota-'));
  try {
    const target = join(dir, 'real');
    mkdirSync(target, { mode: 0o700 });
    symlinkSync(target, join(dir, 'link'));
    expect(() => new CommandQuota(undefined, join(dir, 'link', 'quota.json')).consume('dev', 2)).toThrow('QUOTA_UNAVAILABLE');
    if (process.platform !== 'win32') {
      chmodSync(target, 0o777);
      expect(() => new CommandQuota(undefined, join(target, 'quota.json')).consume('dev', 2)).toThrow('QUOTA_UNAVAILABLE');
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

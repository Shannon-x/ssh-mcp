import { constants, closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync, lstatSync } from 'node:fs';
import { dirname, join, isAbsolute } from 'node:path';
import { randomUUID } from 'node:crypto';
import { getAuditLogPath } from '../audit/store.js';

export function getQuotaPath(): string {
  const path = process.env.SSH_MCP_QUOTA_FILE || join(dirname(getAuditLogPath()), 'quota.json');
  if (!isAbsolute(path)) throw new Error('SSH_MCP_QUOTA_FILE must be an absolute path');
  return path;
}

/**
 * Per-profile command quota — a circuit breaker for runaway agents.
 *
 * The approval gate stops a *destructive* command, and the HTTP rate limiter
 * caps request rate, but neither bounds total work: a prompt-injected agent
 * looping over allowed commands stays under both. The quota bounds the day.
 *
 * Scope is the profile, not the "agent": MCP gives us no stable client
 * identity (a stdio server serves exactly one client anyway), so claiming
 * per-agent accounting would overstate what is actually enforced.
 */

const DAY_MS = 24 * 60 * 60 * 1000;

export interface QuotaDecision {
  allowed: boolean;
  /** Commands still available in the window. */
  remaining: number;
  /** When the oldest counted command falls out of the window. */
  retryAt?: Date;
}

export class CommandQuota {
  /** Timestamps of counted commands, oldest first, per profile. */
  private hits = new Map<string, number[]>();

  /**
   * A sliding 24h window rather than a calendar day: a fixed daily reset lets
   * an agent burn the whole quota, wait for midnight, and immediately burn it
   * again — twice the intended work in minutes.
   */
  constructor(private windowMs: number = DAY_MS, private stateFile?: string) {}

  /**
   * Synchronous read/modify/atomic-replace: no await may separate policy checking
   * from reserving budget. A directory lock coordinates processes using the SAME
   * local state file. Contention, corrupt state, unsafe files and I/O errors fail
   * closed, before a remote command starts. A missing file starts a new store;
   * operators must preserve it across restarts rather than deleting it.
   * A crash while holding the lock requires operator recovery after stopping all
   * instances; guessing that a lock is stale risks admitting concurrent writers.
   */
  private transaction<T>(update: () => T, write: boolean): T {
    if (!this.stateFile) return update();
    const file = this.stateFile;
    const parent = dirname(file);
    mkdirSync(parent, { recursive: true, mode: 0o700 });
    const parentStat = lstatSync(parent);
    const uid = process.getuid?.();
    if (!parentStat.isDirectory() || parentStat.isSymbolicLink()
        || (uid !== undefined && (parentStat.uid !== uid || (parentStat.mode & 0o022) !== 0))) {
      throw new Error('QUOTA_UNAVAILABLE: quota parent must be a service-owned directory not writable by other users');
    }
    const lock = `${file}.lock`;
    try { mkdirSync(lock, { mode: 0o700 }); }
    catch { throw new Error('QUOTA_UNAVAILABLE: quota state is locked; retry or recover the lock after stopping all instances'); }
    let temporary: string | undefined;
    try {
      try {
        const stat = lstatSync(file);
        if (!stat.isFile() || stat.isSymbolicLink()
            || (uid !== undefined && (stat.uid !== uid || (stat.mode & 0o022) !== 0))) {
          throw new Error('unsafe quota state file');
        }
        const fd = openSync(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
        let parsed: unknown;
        try { parsed = JSON.parse(readFileSync(fd, 'utf8')); } finally { closeSync(fd); }
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('invalid quota state');
        const state = parsed as { version?: unknown; hits?: unknown };
        if (state.version !== 1 || !Array.isArray(state.hits)) throw new Error('invalid quota state version');
        const entries: [string, number[]][] = [];
        for (const entry of state.hits) {
          if (!Array.isArray(entry) || entry.length !== 2 || typeof entry[0] !== 'string'
              || !Array.isArray(entry[1]) || !entry[1].every((v: unknown) => typeof v === 'number' && Number.isFinite(v) && v >= 0)) {
            throw new Error('invalid quota state entry');
          }
          entries.push([entry[0], [...entry[1]].sort((a, b) => a - b)]);
        }
        this.hits = new Map(entries);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') this.hits = new Map();
        else throw error;
      }
      const result = update();
      if (write) {
        temporary = `${file}.${randomUUID()}.tmp`;
        const fd = openSync(temporary, 'wx', 0o600);
        try {
          writeFileSync(fd, JSON.stringify({ version: 1, hits: [...this.hits] }));
          fsyncSync(fd);
        } finally { closeSync(fd); }
        renameSync(temporary, file);
        temporary = undefined;
        // Persist the rename on local POSIX filesystems. Windows does not support
        // opening directories this way; file fsync + atomic rename still apply.
        if (process.platform !== 'win32') {
          const directory = openSync(parent, constants.O_RDONLY);
          try { fsyncSync(directory); } finally { closeSync(directory); }
        }
      }
      return result;
    } catch (error) {
      throw new Error('QUOTA_UNAVAILABLE: cannot safely read or persist command quota', { cause: error });
    } finally {
      if (temporary) rmSync(temporary, { force: true });
      rmSync(lock, { recursive: true });
    }
  }

  /**
   * Count one command against the profile's quota.
   * `limit <= 0` (or undefined) means unlimited, and nothing is recorded.
   */
  consume(profile: string, limit: number | undefined, now = Date.now()): QuotaDecision {
    if (!limit || limit <= 0) return { allowed: true, remaining: Infinity };

    return this.transaction(() => {
      const cutoff = now - this.windowMs;
      const recent = (this.hits.get(profile) ?? []).filter((t) => t > cutoff);

      if (recent.length >= limit) {
        // Refusal must not consume budget, otherwise a blocked agent could keep
        // pushing the window forward and never recover.
        this.hits.set(profile, recent);
        return {
          allowed: false,
          remaining: 0,
          retryAt: new Date(recent[0] + this.windowMs),
        };
      }

      recent.push(now);
      this.hits.set(profile, recent);
      return { allowed: true, remaining: limit - recent.length };
    }, true);
  }

  /** Commands used in the current window, for status reporting. */
  used(profile: string, now = Date.now()): number {
    return this.transaction(() => {
      const cutoff = now - this.windowMs;
      return (this.hits.get(profile) ?? []).filter((t) => t > cutoff).length;
    }, false);
  }

  reset(profile?: string): void {
    this.transaction(() => {
      if (profile) this.hits.delete(profile);
      else this.hits.clear();
    }, true);
  }
}

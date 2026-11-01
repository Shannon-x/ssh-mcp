import { describe, it, expect } from 'vitest';
import { PolicyEngine, DEFAULT_RULES } from '../../../src/policy/engine.js';
import { makeProfile } from '../../fixtures/profile.js';

/** No commands in this suite are executed: these are policy decisions only. */
describe('explicit read-only approval fast path', () => {
  const engine = new PolicyEngine(DEFAULT_RULES);
  const operator = makeProfile({ role: 'admin', group: 'dev', approvalPolicy: 'ask-destructive' });

  it.each([
    'ls -la', 'df -h', 'free -m', 'uptime', 'id', 'uname -a',
    'cat /var/log/app.log', 'systemctl status nginx', 'docker ps',
    'sftp:list /srv/logs', 'sftp:download /srv/logs/app.log',
  ])('does not prompt for the proven reader %s', (command) => {
    expect(engine.evaluate(command, operator).decision).toBe('allow');
    expect(engine.evaluate(command, operator).commandClass).toBe('read-only');
  });

  it.each([
    'touch /tmp/mcp-review-proof', 'npm install', 'git pull',
    'unknown-custom-tool status', 'echo hello > /tmp/file',
    'hostname new-hostname', 'systemctl restart nginx',
    'sudo systemctl restart nginx', 'rm /tmp/file',
    'ls; touch /tmp/file', 'cat /etc/hosts | tee /tmp/file',
    "sh -c 'touch /tmp/file'", "python3 -c 'print(1)'",
    'sftp:upload /tmp/file', 'sftp:delete /tmp/file',
  ])('requires approval (or a stricter denial) for %s', (command) => {
    const result = engine.evaluate(command, operator);
    expect(result.decision).not.toBe('allow');
    expect(result.commandClass).not.toBe('read-only');
  });

  it('keeps unclassified commands executable after approval for a configured tester role', () => {
    const custom = new PolicyEngine({
      ...DEFAULT_RULES,
      roleBindings: { ...DEFAULT_RULES.roleBindings, tester: { test: ['read-only', 'safe', 'destructive', 'privileged'] } },
    });
    const tester = makeProfile({ role: 'tester', group: 'test', approvalPolicy: 'ask-destructive' });
    const result = custom.evaluate('touch /tmp/mcp-review-proof', tester);
    expect(result.commandClass).toBe('safe'); // Compatibility label, not a free pass.
    expect(result.decision).toBe('require-approval');
    expect(custom.evaluate('df -h', tester).decision).toBe('allow');
  });

  it('deny mode blocks unclassified writes even when the role allows safe', () => {
    expect(engine.evaluate('touch /tmp/file', { ...operator, approvalPolicy: 'deny' }).decision).toBe('deny');
  });

  it('does not broaden a readOnly profile or a viewer role', () => {
    expect(engine.evaluate('touch /tmp/file', { ...operator, readOnly: true }).decision).toBe('deny');
    expect(engine.evaluate('touch /tmp/file', { ...operator, role: 'viewer', group: 'prod' }).decision).toBe('deny');
  });

  it('preserves an explicitly selected auto policy without weakening role/denylist gates', () => {
    expect(engine.evaluate('touch /tmp/file', { ...operator, approvalPolicy: 'auto' }).decision).toBe('allow');
    expect(engine.evaluate('touch /tmp/file', { ...operator, approvalPolicy: 'auto', readOnly: true }).decision).toBe('deny');
    expect(engine.evaluate('reboot', { ...operator, approvalPolicy: 'auto' }).decision).toBe('deny');
  });
});

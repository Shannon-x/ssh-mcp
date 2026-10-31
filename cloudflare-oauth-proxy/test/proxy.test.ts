import { describe, it, expect, vi } from 'vitest';
import { CLAUDE_CALLBACK, isAllowedRedirectUri, isAllowedUser, missingSettings, type Env } from '../src/config.js';
import { forwardToBackend } from '../src/proxy.js';
import { escapeHtml, consentPage } from '../src/pages.js';
import { fetchGitHubUser, githubAuthorizeUrl, s256 } from '../src/github.js';

const env = {
  PUBLIC_URL: 'https://proxy.example.workers.dev',
  BACKEND_URL: 'https://origin.example.com/',
  BACKEND_BEARER_TOKEN: 'backend-secret',
  GITHUB_CLIENT_ID: 'gh-id',
  GITHUB_CLIENT_SECRET: 'gh-secret',
  ALLOWED_GITHUB_LOGINS: 'Owner',
  ALLOWED_GITHUB_IDS: '42',
  OAUTH_KV: {} as KVNamespace,
} satisfies Env;

const owner = { githubLogin: 'owner', githubId: 42 };

describe('isAllowedUser', () => {
  it('admits the listed login, case-insensitively, with the listed id', () => {
    expect(isAllowedUser(env, 'OWNER', 42)).toBe(true);
  });
  it('refuses a renamed account that took the login but has another id', () => {
    expect(isAllowedUser(env, 'owner', 7)).toBe(false);
  });
  it('refuses everyone when the allowlist is empty', () => {
    expect(isAllowedUser({ ALLOWED_GITHUB_LOGINS: ' , ' }, 'owner', 42)).toBe(false);
  });
  it('checks only the login when no ids are configured', () => {
    expect(isAllowedUser({ ALLOWED_GITHUB_LOGINS: 'a,owner' }, 'owner', 99)).toBe(true);
  });
});

describe('isAllowedRedirectUri', () => {
  it('defaults to claude.ai only', () => {
    expect(isAllowedRedirectUri({}, CLAUDE_CALLBACK)).toBe(true);
    expect(isAllowedRedirectUri({}, 'https://evil.example/api/mcp/auth_callback')).toBe(false);
    expect(isAllowedRedirectUri({}, 'http://localhost:3118/callback')).toBe(false);
  });
  it('matches exactly, not by prefix', () => {
    expect(isAllowedRedirectUri({}, `${CLAUDE_CALLBACK}?x=1`)).toBe(false);
    expect(isAllowedRedirectUri({}, `${CLAUDE_CALLBACK}/../evil`)).toBe(false);
  });
  it('allows any loopback port only when asked to', () => {
    const e = { ALLOWED_REDIRECT_URIS: `${CLAUDE_CALLBACK},loopback` };
    expect(isAllowedRedirectUri(e, 'http://localhost:3118/callback')).toBe(true);
    expect(isAllowedRedirectUri(e, 'http://127.0.0.1:50000/callback')).toBe(true);
    expect(isAllowedRedirectUri(e, 'http://localhost.evil.example:80/callback')).toBe(false);
    expect(isAllowedRedirectUri(e, 'https://localhost:3118/callback')).toBe(false);
    expect(isAllowedRedirectUri(e, 'http://localhost:3118/other')).toBe(false);
  });
  it('refuses something that is not a URL', () => {
    expect(isAllowedRedirectUri({}, 'not a url')).toBe(false);
  });
});

describe('missingSettings', () => {
  it('is empty for a complete configuration', () => {
    expect(missingSettings(env)).toEqual([]);
  });
  it('names what is missing', () => {
    expect(missingSettings({ ...env, BACKEND_BEARER_TOKEN: '' })).toEqual(['BACKEND_BEARER_TOKEN']);
  });
  it('rejects a PUBLIC_URL with a path or trailing slash, which would break the resource match', () => {
    expect(missingSettings({ ...env, PUBLIC_URL: 'https://proxy.example.workers.dev/' })).toHaveLength(1);
    expect(missingSettings({ ...env, PUBLIC_URL: 'http://proxy.example.workers.dev' })).toHaveLength(1);
  });
  it('wants both halves of an Access service token or neither', () => {
    expect(missingSettings({ ...env, CF_ACCESS_CLIENT_ID: 'id' })).toHaveLength(1);
  });
});

function backend(response: Response) {
  return vi.fn<typeof fetch>(async () => response);
}

describe('forwardToBackend', () => {
  it('swaps the client token for the backend bearer and forwards only MCP headers', async () => {
    const fetchImpl = backend(new Response('{"ok":true}', {
      status: 200,
      headers: { 'content-type': 'application/json', 'mcp-session-id': 's1', 'set-cookie': 'x=1' },
    }));
    const request = new Request('https://proxy.example.workers.dev/mcp', {
      method: 'POST',
      headers: {
        Authorization: 'Bearer client-oauth-token',
        'Content-Type': 'application/json',
        Accept: 'application/json, text/event-stream',
        'Mcp-Session-Id': 's1',
        Cookie: 'secret=1',
      },
      body: '{"jsonrpc":"2.0"}',
    });

    const response = await forwardToBackend(request, env, owner, fetchImpl);

    expect(fetchImpl).toHaveBeenCalledOnce();
    const [url, init] = fetchImpl.mock.calls[0];
    expect(url).toBe(env.BACKEND_URL);
    const sent = new Headers(init!.headers);
    expect(sent.get('authorization')).toBe('Bearer backend-secret');
    expect(sent.get('mcp-session-id')).toBe('s1');
    expect(sent.get('cookie')).toBeNull();
    expect(response.status).toBe(200);
    expect(response.headers.get('mcp-session-id')).toBe('s1');
    expect(response.headers.get('set-cookie')).toBeNull();
    expect(await response.text()).toBe('{"ok":true}');
  });

  it('adds the Access service token when configured', async () => {
    const fetchImpl = backend(new Response(null, { status: 202 }));
    await forwardToBackend(
      new Request('https://p/mcp', { method: 'DELETE' }),
      { ...env, CF_ACCESS_CLIENT_ID: 'cid', CF_ACCESS_CLIENT_SECRET: 'csecret' },
      owner,
      fetchImpl,
    );
    const sent = new Headers(fetchImpl.mock.calls[0][1]!.headers);
    expect(sent.get('cf-access-client-id')).toBe('cid');
    expect(sent.get('cf-access-client-secret')).toBe('csecret');
  });

  it('refuses a token whose user has left the allowlist, without calling the backend', async () => {
    const fetchImpl = backend(new Response(null));
    const response = await forwardToBackend(new Request('https://p/mcp', { method: 'POST', body: '{}' }), env, { githubLogin: 'someone', githubId: 1 }, fetchImpl);
    expect(response.status).toBe(403);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('refuses missing props', async () => {
    const fetchImpl = backend(new Response(null));
    expect((await forwardToBackend(new Request('https://p/mcp'), env, undefined, fetchImpl)).status).toBe(403);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('turns a backend 401 into a 502, so the client does not re-authorize in a loop', async () => {
    const response = await forwardToBackend(new Request('https://p/mcp', { method: 'POST', body: '{}' }), env, owner, backend(new Response(null, { status: 401 })));
    expect(response.status).toBe(502);
  });

  it('does not follow an Access login redirect', async () => {
    const response = await forwardToBackend(new Request('https://p/mcp'), env, owner, backend(new Response(null, { status: 302, headers: { Location: 'https://team.cloudflareaccess.com/' } })));
    expect(response.status).toBe(502);
  });

  it('answers 502 when the backend is down', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => { throw new Error('connect ECONNREFUSED'); });
    vi.spyOn(console, 'error').mockImplementation(() => {});
    expect((await forwardToBackend(new Request('https://p/mcp'), env, owner, fetchImpl)).status).toBe(502);
  });

  it('allows only the MCP methods', async () => {
    const response = await forwardToBackend(new Request('https://p/mcp', { method: 'PUT', body: '{}' }), env, owner, backend(new Response(null)));
    expect(response.status).toBe(405);
  });
});

describe('consent page', () => {
  it('escapes everything the client chose', () => {
    const html = consentPage({ clientName: '<script>x</script>', redirectHost: 'claude.ai', redirectIsLoopback: false }, '"><img>');
    expect(html).not.toContain('<script>x');
    expect(html).not.toContain('"><img>');
    expect(html).toContain(escapeHtml('<script>x</script>'));
    expect(html).toContain('claude.ai');
  });
  it('warns when the token goes to a local program', () => {
    expect(consentPage({ clientName: 'c', redirectHost: 'localhost', redirectIsLoopback: true }, 'h')).toContain('class="warn"');
  });
});

describe('GitHub sign-in', () => {
  it('sends PKCE and no scope', async () => {
    const url = new URL(githubAuthorizeUrl({ clientId: 'id', redirectUri: 'https://p/callback', state: 's', codeChallenge: await s256('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk') }));
    expect(url.searchParams.get('code_challenge_method')).toBe('S256');
    expect(url.searchParams.get('code_challenge')).toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM'); // RFC 7636 appendix B
    expect(url.searchParams.has('scope')).toBe(false);
  });

  it('reads the user after exchanging the code', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async (input) => {
      const url = String(input);
      if (url.endsWith('/access_token')) return Response.json({ access_token: 'gho_x' });
      return Response.json({ login: 'Owner', id: 42 });
    });
    const user = await fetchGitHubUser({ clientId: 'id', clientSecret: 's', code: 'c', redirectUri: 'r', codeVerifier: 'v', fetchImpl });
    expect(user).toEqual({ login: 'Owner', id: 42 });
    const body = fetchImpl.mock.calls[0][1]!.body as URLSearchParams;
    expect(body.get('code_verifier')).toBe('v');
  });

  it('fails when GitHub reports an error with HTTP 200', async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => Response.json({ error: 'bad_verification_code' }));
    await expect(fetchGitHubUser({ clientId: 'id', clientSecret: 's', code: 'c', redirectUri: 'r', codeVerifier: 'v', fetchImpl }))
      .rejects.toThrow('bad_verification_code');
  });
});

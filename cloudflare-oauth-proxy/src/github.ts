/**
 * GitHub is used only to learn who is signing in. Its token is used once, to read
 * `/user`, and then dropped: nothing here acts on GitHub for the user.
 */

const USER_AGENT = 'ssh-mcp-oauth-proxy';

export function base64url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = '';
  for (const byte of view) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function randomVerifier(): string {
  return base64url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function s256(verifier: string): Promise<string> {
  return base64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
}

export function githubAuthorizeUrl(opts: {
  clientId: string;
  redirectUri: string;
  state: string;
  codeChallenge: string;
}): string {
  const url = new URL('https://github.com/login/oauth/authorize');
  url.searchParams.set('client_id', opts.clientId);
  url.searchParams.set('redirect_uri', opts.redirectUri);
  // No scope: reading the signed-in user's public profile needs none.
  url.searchParams.set('state', opts.state);
  url.searchParams.set('code_challenge', opts.codeChallenge);
  url.searchParams.set('code_challenge_method', 'S256');
  url.searchParams.set('allow_signup', 'false');
  return url.toString();
}

export interface GitHubUser {
  login: string;
  id: number;
}

/** Exchange GitHub's code and read who signed in. Throws on any failure. */
export async function fetchGitHubUser(opts: {
  clientId: string;
  clientSecret: string;
  code: string;
  redirectUri: string;
  codeVerifier: string;
  fetchImpl?: typeof fetch;
}): Promise<GitHubUser> {
  const doFetch = opts.fetchImpl ?? fetch;
  const tokenResponse = await doFetch('https://github.com/login/oauth/access_token', {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': USER_AGENT,
    },
    body: new URLSearchParams({
      client_id: opts.clientId,
      client_secret: opts.clientSecret,
      code: opts.code,
      redirect_uri: opts.redirectUri,
      code_verifier: opts.codeVerifier,
    }),
  });
  // GitHub reports a bad code with 200 and an `error` field, so the status alone says little.
  const token = await tokenResponse.json() as { access_token?: string; error?: string };
  if (!tokenResponse.ok || !token.access_token) {
    throw new Error(`GitHub token exchange failed: ${token.error ?? `HTTP ${tokenResponse.status}`}`);
  }

  const userResponse = await doFetch('https://api.github.com/user', {
    headers: {
      Authorization: `Bearer ${token.access_token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': USER_AGENT,
    },
  });
  if (!userResponse.ok) throw new Error(`GitHub /user failed: HTTP ${userResponse.status}`);
  const user = await userResponse.json() as Partial<GitHubUser>;
  if (typeof user.login !== 'string' || typeof user.id !== 'number') {
    throw new Error('GitHub /user returned no login or id');
  }
  return { login: user.login, id: user.id };
}

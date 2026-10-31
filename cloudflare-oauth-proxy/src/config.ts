/**
 * Bindings and settings for the proxy, and the checks that read them.
 *
 * Everything here is pure so it can be tested in Node without workerd: the
 * Worker entry point is the only module that imports the OAuth library.
 */

export interface Env {
  /** KV namespace the OAuth library keeps clients, grants and tokens in. */
  OAUTH_KV: KVNamespace;

  /** This Worker's public origin, e.g. `https://ssh-mcp-oauth.example.workers.dev`. No trailing slash. */
  PUBLIC_URL: string;

  /** ssh-mcp's HTTP endpoint as the Worker reaches it, e.g. `https://ssh-mcp-origin.example.com/`. */
  BACKEND_URL: string;
  /** The `--bearerToken` ssh-mcp was started with. Secret. */
  BACKEND_BEARER_TOKEN: string;
  /** Optional Cloudflare Access service token, when the backend hostname sits behind Access. */
  CF_ACCESS_CLIENT_ID?: string;
  CF_ACCESS_CLIENT_SECRET?: string;

  /** GitHub OAuth App used only to learn who is signing in. */
  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;

  /** Comma-separated GitHub logins allowed to sign in. Case-insensitive. Required. */
  ALLOWED_GITHUB_LOGINS: string;
  /**
   * Comma-separated numeric GitHub user IDs. Optional but recommended: a login can be
   * renamed and later re-registered by someone else, the numeric ID cannot.
   */
  ALLOWED_GITHUB_IDS?: string;

  /**
   * Comma-separated redirect URIs MCP clients may send tokens to. Defaults to claude.ai's
   * callback only. Add `loopback` to also allow Claude Code's `http://localhost:<port>/callback`.
   */
  ALLOWED_REDIRECT_URIS?: string;
}

/** What is sealed into every access token, and re-checked on every MCP request. */
export interface Props {
  githubLogin: string;
  githubId: number;
}

export const CLAUDE_CALLBACK = 'https://claude.ai/api/mcp/auth_callback';
export const MCP_PATH = '/mcp';
export const SCOPE = 'ssh';

function list(value: string | undefined): string[] {
  return (value ?? '').split(',').map((v) => v.trim()).filter(Boolean);
}

/**
 * The one place that decides who may use the proxy. Fails closed: an empty allowlist
 * admits nobody, so a deployment that forgot the variable is locked rather than open.
 */
export function isAllowedUser(env: Pick<Env, 'ALLOWED_GITHUB_LOGINS' | 'ALLOWED_GITHUB_IDS'>, login: string, id: number): boolean {
  const logins = list(env.ALLOWED_GITHUB_LOGINS).map((l) => l.toLowerCase());
  if (logins.length === 0 || !logins.includes(login.toLowerCase())) return false;
  const ids = list(env.ALLOWED_GITHUB_IDS);
  if (ids.length > 0 && !ids.includes(String(id))) return false;
  return true;
}

function isLoopbackCallback(uri: URL): boolean {
  return uri.protocol === 'http:'
    && (uri.hostname === 'localhost' || uri.hostname === '127.0.0.1' || uri.hostname === '[::1]')
    && uri.pathname === '/callback'
    && !uri.username && !uri.password && !uri.search && !uri.hash;
}

/**
 * Whether an MCP client may receive tokens at this redirect URI.
 *
 * The GitHub allowlist decides *who* signs in; this decides *where* the resulting token
 * goes. Without it, anyone could register a client pointing at their own server and send
 * the owner a sign-in link: the owner would pass the GitHub check and hand them a token.
 */
export function isAllowedRedirectUri(env: Pick<Env, 'ALLOWED_REDIRECT_URIS'>, redirectUri: string): boolean {
  let uri: URL;
  try {
    uri = new URL(redirectUri);
  } catch {
    return false;
  }
  const allowed = list(env.ALLOWED_REDIRECT_URIS);
  const entries = allowed.length > 0 ? allowed : [CLAUDE_CALLBACK];
  for (const entry of entries) {
    if (entry === 'loopback') {
      if (isLoopbackCallback(uri)) return true;
    } else if (entry === redirectUri) {
      return true;
    }
  }
  return false;
}

/** The settings without which the Worker must not serve anything. */
export function missingSettings(env: Partial<Env>): string[] {
  const required: (keyof Env)[] = [
    'OAUTH_KV', 'PUBLIC_URL', 'BACKEND_URL', 'BACKEND_BEARER_TOKEN',
    'GITHUB_CLIENT_ID', 'GITHUB_CLIENT_SECRET', 'ALLOWED_GITHUB_LOGINS',
  ];
  const missing: string[] = required.filter((key) => !env[key]);
  if (env.PUBLIC_URL && !/^https:\/\/[^/]+$/.test(env.PUBLIC_URL)) missing.push('PUBLIC_URL (https origin, no path or trailing slash)');
  if (Boolean(env.CF_ACCESS_CLIENT_ID) !== Boolean(env.CF_ACCESS_CLIENT_SECRET)) {
    missing.push('CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET (set both or neither)');
  }
  return missing;
}

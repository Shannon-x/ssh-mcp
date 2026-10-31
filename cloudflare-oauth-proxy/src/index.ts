import {
  AuthorizationError,
  CimdFetchError,
  OAuthProvider,
  authorizationErrorRedirect,
  type OAuthHelpers,
} from '@cloudflare/workers-oauth-provider';
import {
  MCP_PATH,
  SCOPE,
  isAllowedRedirectUri,
  isAllowedUser,
  missingSettings,
  type Env,
  type Props,
} from './config.js';
import { fetchGitHubUser, githubAuthorizeUrl, randomVerifier, s256 } from './github.js';
import { consentPage, messagePage } from './pages.js';
import { forwardToBackend } from './proxy.js';

type HandlerEnv = Env & { OAUTH_PROVIDER: OAuthHelpers };

/** Access tokens are short; a grant lasts a week, after which the owner signs in again. */
const ACCESS_TOKEN_TTL = 60 * 60;
const REFRESH_TOKEN_TTL = 7 * 24 * 60 * 60;

function redirect(location: string, headers = new Headers()): Response {
  headers.set('Location', location);
  return new Response(null, { status: 302, headers });
}

async function authorize(request: Request, env: HandlerEnv): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;

  if (request.method === 'GET') {
    const authRequest = await oauth.parseAuthRequest(request);
    // Rendered, never redirected: the redirect URI is exactly what is not trusted.
    if (!isAllowedRedirectUri(env, authRequest.redirectUri)) {
      return messagePage('不允许的回调地址', `这个服务器只把令牌发给已配置的地址，${authRequest.redirectUri} 不在其中。`, 403);
    }
    const details = await oauth.describeConsent(authRequest);
    const consent = await oauth.beginConsent(authRequest);
    consent.headers.set('Content-Type', 'text/html; charset=utf-8');
    return new Response(consentPage(details, consent.handle), { headers: consent.headers });
  }

  if (request.method === 'POST') {
    const form = await request.formData();
    const handle = String(form.get('handle') ?? '');
    if (form.get('decision') !== 'approve') {
      const denied = await oauth.denyConsent(request, handle);
      return redirect(denied.redirectTo, denied.headers);
    }
    // The scope is this server's to choose, not the form's.
    const approved = await oauth.approveConsent(request, handle, { scope: [SCOPE] });
    if (!isAllowedRedirectUri(env, approved.request.redirectUri)) {
      return messagePage('不允许的回调地址', '这个服务器只把令牌发给已配置的地址。', 403);
    }
    const verifier = randomVerifier();
    const { state, headers } = await oauth.beginUpstream(approved.request, {
      data: { verifier },
      headers: approved.headers,
    });
    return redirect(githubAuthorizeUrl({
      clientId: env.GITHUB_CLIENT_ID,
      redirectUri: `${env.PUBLIC_URL}/callback`,
      state,
      codeChallenge: await s256(verifier),
    }), headers);
  }

  return new Response(null, { status: 405, headers: { Allow: 'GET, POST' } });
}

async function callback(request: Request, env: HandlerEnv): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  const { request: original, data, headers } = await oauth.finishUpstream<{ verifier: string }>(request);
  const params = new URL(request.url).searchParams;
  const code = params.get('code');
  if (params.get('error') || !code) {
    return redirect(authorizationErrorRedirect(original, 'access_denied'), headers);
  }

  let user;
  try {
    user = await fetchGitHubUser({
      clientId: env.GITHUB_CLIENT_ID,
      clientSecret: env.GITHUB_CLIENT_SECRET,
      code,
      redirectUri: `${env.PUBLIC_URL}/callback`,
      codeVerifier: data.verifier,
    });
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    return messagePage('GitHub 登录失败', '没能从 GitHub 拿到登录信息，请回到 Claude 重新连接。', 502);
  }

  if (!isAllowedUser(env, user.login, user.id)) {
    console.error(`sign-in refused for GitHub user ${user.login} (${user.id})`);
    return messagePage('账号不在白名单', `GitHub 账号 ${user.login} 不能使用这个服务器。`, 403);
  }

  const props: Props = { githubLogin: user.login, githubId: user.id };
  const { redirectTo } = await oauth.completeAuthorization({
    request: original,
    userId: `github:${user.id}`,
    metadata: { githubLogin: user.login },
    scope: [SCOPE],
    props,
  });
  return redirect(redirectTo, headers);
}

const defaultHandler: ExportedHandler<HandlerEnv> = {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    try {
      if (pathname === '/authorize') return await authorize(request, env);
      if (pathname === '/callback') return await callback(request, env);
    } catch (err) {
      if (err instanceof AuthorizationError && err.redirectTo) return redirect(err.redirectTo);
      if (err instanceof AuthorizationError) return messagePage('授权请求无效', err.description);
      if (err instanceof CimdFetchError) return messagePage('无法验证这个应用', '读取客户端元数据失败，请稍后重试。');
      throw err;
    }
    if (pathname === '/' && request.method === 'GET') {
      return new Response('ssh-mcp OAuth proxy. MCP endpoint: ' + `${env.PUBLIC_URL}${MCP_PATH}\n`, {
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      });
    }
    return new Response('Not found\n', { status: 404 });
  },
};

const apiHandler: ExportedHandler<Env> & Pick<Required<ExportedHandler<Env>>, 'fetch'> = {
  async fetch(request, env, ctx) {
    // The library routes the prefix; only the endpoint itself is served.
    if (new URL(request.url).pathname !== MCP_PATH) return new Response('Not found\n', { status: 404 });
    return forwardToBackend(request, env, ctx.props as Props | undefined);
  },
};

function buildProvider(env: Env): OAuthProvider<Env> {
  return new OAuthProvider<Env>({
    apiRoute: MCP_PATH,
    apiHandler,
    defaultHandler: defaultHandler as ExportedHandler<Env>,
    authorizeEndpoint: '/authorize',
    tokenEndpoint: '/token',
    // claude.ai prefers a Client ID Metadata Document when both are offered, and falls back to DCR.
    clientRegistrationEndpoint: '/register',
    clientIdMetadataDocumentEnabled: true,
    clientRegistrationCallback: ({ clientMetadata }) => {
      const uris = Array.isArray(clientMetadata.redirect_uris) ? clientMetadata.redirect_uris : [];
      if (!uris.some((uri) => typeof uri === 'string' && isAllowedRedirectUri(env, uri))) {
        return { description: 'redirect_uris must include an allowed callback for this server', status: 400 };
      }
    },
    scopesSupported: [SCOPE],
    requiredScopes: [SCOPE],
    resourceMetadata: {
      // claude.ai requires this to equal the URL entered in the connector dialog exactly.
      resource: `${env.PUBLIC_URL}${MCP_PATH}`,
      authorization_servers: [env.PUBLIC_URL],
    },
    accessTokenTTL: ACCESS_TOKEN_TTL,
    refreshTokenTTL: REFRESH_TOKEN_TTL,
  });
}

let provider: OAuthProvider<Env> | undefined;
let providerOrigin: string | undefined;

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const missing = missingSettings(env);
    if (missing.length > 0) {
      // Names only, never values. Refusing everything beats serving half-configured.
      console.error(`refusing requests, missing settings: ${missing.join(', ')}`);
      return new Response('This proxy is not configured yet.\n', { status: 503 });
    }
    // Built on first use because the resource URL comes from the environment.
    if (!provider || providerOrigin !== env.PUBLIC_URL) {
      provider = buildProvider(env);
      providerOrigin = env.PUBLIC_URL;
    }
    return provider.fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;

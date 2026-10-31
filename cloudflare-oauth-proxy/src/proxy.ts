import { isAllowedUser, type Env, type Props } from './config.js';

/** Request headers the MCP Streamable HTTP transport needs. Everything else stays here. */
const FORWARD_REQUEST_HEADERS = ['content-type', 'accept', 'mcp-session-id', 'mcp-protocol-version', 'last-event-id'];
/** Response headers passed back to the client. */
const FORWARD_RESPONSE_HEADERS = ['content-type', 'mcp-session-id', 'mcp-protocol-version', 'cache-control', 'retry-after'];

function jsonRpcError(status: number, code: number, message: string): Response {
  return new Response(JSON.stringify({ jsonrpc: '2.0', error: { code, message }, id: null }), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * Forward one authenticated MCP request to ssh-mcp.
 *
 * The client's own `Authorization` header (this proxy's OAuth token) is never forwarded:
 * ssh-mcp gets the static bearer token, which never leaves the Worker.
 *
 * @param props What was sealed into the access token at sign-in. Re-checked here, so
 *   removing a login from the allowlist cuts off tokens already issued to it.
 */
export async function forwardToBackend(
  request: Request,
  env: Env,
  props: Props | undefined,
  fetchImpl: typeof fetch = fetch,
): Promise<Response> {
  if (
    typeof props?.githubLogin !== 'string'
    || typeof props.githubId !== 'number'
    || !isAllowedUser(env, props.githubLogin, props.githubId)
  ) {
    return jsonRpcError(403, -32001, 'This GitHub account is not allowed to use this server.');
  }
  if (!['POST', 'GET', 'DELETE'].includes(request.method)) {
    return new Response(null, { status: 405, headers: { Allow: 'POST, GET, DELETE' } });
  }

  const headers = new Headers();
  for (const name of FORWARD_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value !== null) headers.set(name, value);
  }
  headers.set('Authorization', `Bearer ${env.BACKEND_BEARER_TOKEN}`);
  if (env.CF_ACCESS_CLIENT_ID && env.CF_ACCESS_CLIENT_SECRET) {
    headers.set('CF-Access-Client-Id', env.CF_ACCESS_CLIENT_ID);
    headers.set('CF-Access-Client-Secret', env.CF_ACCESS_CLIENT_SECRET);
  }

  let upstream: Response;
  try {
    upstream = await fetchImpl(env.BACKEND_URL, {
      method: request.method,
      headers,
      body: request.method === 'POST' ? request.body : undefined,
      redirect: 'manual',
    });
  } catch (err) {
    console.error('backend unreachable:', err instanceof Error ? err.message : String(err));
    return jsonRpcError(502, -32603, 'The SSH MCP backend is unreachable.');
  }

  // A 401 or 403 from the backend means *this proxy's* credentials (bearer token or Access
  // service token) are wrong. Passing it through would tell the client its OAuth token is
  // bad, and it would loop re-authorizing against a proxy that is not the problem.
  if (upstream.status === 401 || upstream.status === 403) {
    console.error(`backend refused the proxy's credentials (HTTP ${upstream.status})`);
    return jsonRpcError(502, -32603, 'The SSH MCP backend refused the proxy. Check BACKEND_BEARER_TOKEN.');
  }
  // A redirect here is almost always Cloudflare Access sending an unauthenticated request
  // to its login page; following it would hand the client an HTML page.
  if (upstream.status >= 300 && upstream.status < 400) {
    console.error(`backend answered with a redirect (HTTP ${upstream.status}); is Access in front of it without a service token?`);
    return jsonRpcError(502, -32603, 'The SSH MCP backend redirected the proxy. Check the Access service token.');
  }

  const responseHeaders = new Headers();
  for (const name of FORWARD_RESPONSE_HEADERS) {
    const value = upstream.headers.get(name);
    if (value !== null) responseHeaders.set(name, value);
  }
  // Streamed through, not buffered, so server-sent events reach the client as they arrive.
  return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
}

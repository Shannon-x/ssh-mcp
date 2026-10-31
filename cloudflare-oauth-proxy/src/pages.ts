/** The few HTML pages the proxy shows a browser. Every client-supplied value is escaped. */

export interface ConsentFacts {
  clientName: string;
  clientDomain?: string;
  redirectHost: string;
  redirectIsLoopback: boolean;
}

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);
}

function page(title: string, body: string): string {
  return `<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
  body { font: 16px/1.6 system-ui, sans-serif; max-width: 34rem; margin: 3rem auto; padding: 0 1rem; color: #1f2328; background: #fff; }
  @media (prefers-color-scheme: dark) { body { color: #e6edf3; background: #0d1117; } }
  .warn { padding: .75rem 1rem; border-left: 4px solid #d29922; background: rgba(210,153,34,.12); }
  button { font: inherit; padding: .5rem 1.25rem; margin-right: .5rem; cursor: pointer; }
  code { font-size: .9em; }
</style>
<body>
${body}
</body>
</html>`;
}

export function consentPage(facts: ConsentFacts, handle: string): string {
  const name = escapeHtml(facts.clientName);
  const origin = facts.clientDomain
    ? `发布方：<strong>${escapeHtml(facts.clientDomain)}</strong>`
    : '这个应用是自行注册的，名字未经验证。';
  const loopback = facts.redirectIsLoopback
    ? '<p class="warn">令牌会发给<strong>你电脑上的一个程序</strong>。只有你刚刚在 Claude Code 里发起连接时才继续。</p>'
    : '';
  return page(`授权 ${facts.clientName}`, `
<h1>允许 ${name} 使用你的 SSH MCP 服务器？</h1>
<p>${origin}</p>
<p>令牌将发送到 <strong>${escapeHtml(facts.redirectHost)}</strong>。</p>
${loopback}
<p>同意后会跳转到 GitHub 登录，只有白名单里的 GitHub 账号能通过。拿到授权的客户端可以通过 ssh-mcp 在你配置的主机上执行命令，具体能做什么由 ssh-mcp 的角色和审批策略决定。</p>
<form method="post">
  <input type="hidden" name="handle" value="${escapeHtml(handle)}">
  <button name="decision" value="approve">允许</button>
  <button name="decision" value="deny">拒绝</button>
</form>`);
}

export function messagePage(title: string, message: string, status = 400): Response {
  return new Response(page(title, `<h1>${escapeHtml(title)}</h1><p>${escapeHtml(message)}</p>`), {
    status,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
      'X-Frame-Options': 'DENY',
      'Cache-Control': 'no-store',
    },
  });
}

# ssh-mcp OAuth 代理（Cloudflare Worker）

让 claude.ai 能以「自定义连接器」的方式连上 ssh-mcp。

claude.ai 的自定义连接器要求 OAuth 2.0（动态注册或 Client ID Metadata Document、PKCE S256、带 `resource_metadata` 的 401）。ssh-mcp 的 HTTP 模式只认一个固定的 bearer token，没有 OAuth。这个 Worker 夹在中间：对 claude.ai 它是完整的 OAuth 服务器，用 GitHub 登录且只放行你本人；对 ssh-mcp 它是唯一持有 bearer token 的客户端。

```
claude.ai ──OAuth 令牌──▶ Cloudflare Worker（本目录）──固定 bearer──▶ Cloudflare Tunnel ──▶ 127.0.0.1:3000 ssh-mcp ──SSH──▶ 你的主机
               ▲                   │
               └── GitHub 登录 ◀───┘（只放行白名单账号）
```

OAuth 部分用的是 Cloudflare 官方的 [`@cloudflare/workers-oauth-provider`](https://github.com/cloudflare/workers-oauth-provider)，自己只写了登录页、GitHub 回调和转发。

## 安全设计

- **只有你能登录**：GitHub 登录后检查 `ALLOWED_GITHUB_LOGINS`，建议同时填 `ALLOWED_GITHUB_IDS`（数字 ID，改名也不会变）。白名单为空时谁都进不来。每次 MCP 请求都会重新核对，把账号移出白名单立刻失效，不用等令牌过期。
- **令牌只发给 claude.ai**：回调地址默认只允许 `https://claude.ai/api/mcp/auth_callback`。别人注册一个指向自己服务器的客户端、再骗你点授权链接，这条路被堵死了。要用 Claude Code 再加 `loopback`。
- **ssh-mcp 的 bearer token 不出 Worker**：存在 Worker secret 里，claude.ai 拿到的只是 Worker 自己签发的 OAuth 令牌（访问令牌 1 小时，授权最长 7 天，之后要重新登录）。
- **服务器不开端口**：ssh-mcp 只监听 127.0.0.1，通过 Cloudflare Tunnel 出站连接。可以再给 Tunnel 主机名套一层 Cloudflare Access 服务令牌，见第 3 步。
- **审批默认拒绝**：见下方「审批与危险命令」。
- **授权页**：显示客户端名称和令牌去向，禁止被嵌入（防点击劫持），表单带浏览器绑定的一次性句柄。

## 审批与危险命令

ssh-mcp 遇到破坏性（destructive）或特权（privileged）命令时，会通过 MCP 的 elicitation 请客户端弹窗确认。

- 客户端**没声明** elicitation 能力，或者问不到、超时：命令被拒绝，返回 `APPROVAL_UNAVAILABLE`，不会执行。这一点有测试覆盖（`test/unit/guard/elicitation.test.ts` 里用真实客户端验证）。
- 客户端支持弹窗：会让你确认，点允许才执行。

两种情况都不会自动执行。要让它「不该做的直接不做」，建议：

- 给 claude.ai 用的 profile 选 `role = "viewer"`（只读）或 `"operator"`，不要用 `admin`。
- `approvalPolicy` 用 `"ask-destructive"`（默认）或 `"deny"`（破坏性命令直接拒，不尝试弹窗）。**绝对不要用 `"auto"`**，它会跳过审批。
- `approvalGrantTtlMs = 0`（默认），不缓存批准。
- 可以设 `commandQuotaPerDay` 作为熔断。

## 部署

下面所有 `<...>` 都是占位符，换成你自己的值，不要把真实的 token、密钥、IP 提交进仓库。

### 第 1 步：在每台目标主机上建低权限 SSH 用户

ssh-mcp 用这个账号登录你的主机。**不要用 root。**

```bash
sudo useradd --create-home --shell /bin/bash mcp-agent
sudo passwd -l mcp-agent           # 禁止密码登录
sudo install -d -m 700 -o mcp-agent -g mcp-agent /home/mcp-agent/.ssh
```

不要把它加进 `sudo`/`wheel` 组。确实需要个别特权命令时，在 `/etc/sudoers.d/` 里只放行具体命令，并在 ssh-mcp 里保持审批。

在 `/etc/ssh/sshd_config` 确认 `PermitRootLogin no`、`PasswordAuthentication no`。

### 第 2 步：在运行 ssh-mcp 的机器上

建议单独一台小机器或你的一台 VPS，用一个专门的系统用户跑：

```bash
sudo useradd --system --create-home --shell /usr/sbin/nologin sshmcp
sudo -u sshmcp ssh-keygen -t ed25519 -N '' -f /home/sshmcp/.ssh/id_ed25519_mcp
```

把公钥加到每台目标主机的 `/home/mcp-agent/.ssh/authorized_keys`，前面加限制：

```
no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA... sshmcp
```

安装 ssh-mcp（用这个分支构建，因为它支持从环境变量读 token）：

```bash
sudo git clone https://github.com/Shannon-x/ssh-mcp /opt/ssh-mcp
cd /opt/ssh-mcp && sudo npm ci && sudo npm run build
```

配置文件 `/home/sshmcp/.config/ssh-mcp/config.toml`（属主必须是 `sshmcp`、权限 600，否则 ssh-mcp 拒绝加载，所以用 `sudo -u sshmcp` 去创建和编辑）：

```toml
[defaults]
approvalMode = "ask-destructive"
approvalGrantTtlMs = 0
commandQuotaPerDay = 500

[[profiles]]
name = "web-1"
host = "<目标主机地址>"
port = 22
user = "mcp-agent"
auth = "key"
keyRef = "/home/sshmcp/.ssh/id_ed25519_mcp"
# 在目标主机上运行 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 得到
trustedHostKey = "SHA256:<主机指纹>"
role = "operator"
readOnly = false
approvalPolicy = "ask-destructive"
```

```bash
sudo -u sshmcp chmod 600 /home/sshmcp/.config/ssh-mcp/config.toml
```

生成 bearer token，放进只有 root 能读的环境文件（不放命令行，免得在进程列表里被看到）：

```bash
sudo install -d -m 700 /etc/ssh-mcp
echo "SSH_MCP_BEARER_TOKEN=$(openssl rand -hex 32)" | sudo tee /etc/ssh-mcp/env >/dev/null
sudo chmod 600 /etc/ssh-mcp/env
sudo cat /etc/ssh-mcp/env   # 记下这个值，第 5 步要用
```

systemd 服务 `/etc/systemd/system/ssh-mcp.service`：

```ini
[Unit]
Description=ssh-mcp (HTTP, localhost only)
After=network-online.target

[Service]
User=sshmcp
EnvironmentFile=/etc/ssh-mcp/env
ExecStart=/usr/bin/node /opt/ssh-mcp/build/index.js --transport=http --httpHost=127.0.0.1 --httpPort=3000 --config=/home/sshmcp/.config/ssh-mcp/config.toml
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now ssh-mcp
curl -s http://127.0.0.1:3000/health    # {"healthy":true,"configured":true}
```

### 第 3 步：Cloudflare Tunnel

在同一台机器装 `cloudflared`，建一个 Tunnel，把一个主机名（例如 `ssh-mcp-origin.<你的域名>`）指到本机 3000 端口。命令行方式的 `/etc/cloudflared/config.yml`：

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json
ingress:
  - hostname: ssh-mcp-origin.<你的域名>
    service: http://127.0.0.1:3000
    originRequest:
      # ssh-mcp 会检查 Host 头防 DNS 重绑定，这里改成它默认接受的值
      httpHostHeader: localhost:3000
  - service: http_status:404
```

也可以在 Zero Trust 面板里建 Tunnel，Public Hostname 的 HTTP Host Header 填 `localhost:3000`。

**推荐再加一层 Access**：在 Zero Trust → Access → Applications 给 `ssh-mcp-origin.<你的域名>` 建一个 Self-hosted 应用，策略只放一个 Service Auth（服务令牌）。这样不知道服务令牌的人连 ssh-mcp 的 401 都看不到。服务令牌的 Client ID 和 Secret 在第 5 步填进 Worker。

### 第 4 步：GitHub OAuth App

GitHub → Settings → Developer settings → OAuth Apps → New OAuth App：

- Homepage URL：`https://ssh-mcp-oauth.<你的 workers 子域>.workers.dev`
- Authorization callback URL：`https://ssh-mcp-oauth.<你的 workers 子域>.workers.dev/callback`

记下 Client ID，生成一个 Client Secret。

查自己的数字 ID：

```bash
curl -s https://api.github.com/users/Shannon-x | grep '"id"'
```

### 第 5 步：部署 Worker

```bash
cd cloudflare-oauth-proxy
npm ci
npx wrangler login
npx wrangler kv namespace create OAUTH_KV     # 把输出的 id 填进 wrangler.jsonc
```

编辑 `wrangler.jsonc` 里的 `vars`：

| 变量 | 填什么 |
| --- | --- |
| `PUBLIC_URL` | Worker 的地址，`https://` 开头，**末尾不带 `/`**。必须和浏览器里实际访问的地址完全一致 |
| `BACKEND_URL` | `https://ssh-mcp-origin.<你的域名>/`（末尾带 `/`，ssh-mcp 的 MCP 端点就是根路径） |
| `ALLOWED_GITHUB_LOGINS` | `Shannon-x` |
| `ALLOWED_GITHUB_IDS` | 第 4 步查到的数字 ID |
| `ALLOWED_REDIRECT_URIS` | 默认只有 claude.ai。要用 Claude Code 就改成 `https://claude.ai/api/mcp/auth_callback,loopback` |

设置 secret（会提示你粘贴值，不会进仓库）：

```bash
npx wrangler secret put BACKEND_BEARER_TOKEN     # 第 2 步 /etc/ssh-mcp/env 里的值
npx wrangler secret put GITHUB_CLIENT_ID
npx wrangler secret put GITHUB_CLIENT_SECRET
# 只有第 3 步加了 Access 服务令牌才需要：
npx wrangler secret put CF_ACCESS_CLIENT_ID
npx wrangler secret put CF_ACCESS_CLIENT_SECRET
```

```bash
npm test          # 单元测试
npx wrangler deploy
```

缺任何必填项时 Worker 对所有请求返回 503，并在日志里列出缺了哪几个（只列名字，不打印值）。

检查发现端点：

```bash
curl -si -X POST https://ssh-mcp-oauth.<子域>.workers.dev/mcp | grep -i www-authenticate
# 应看到 resource_metadata="https://ssh-mcp-oauth.<子域>.workers.dev/.well-known/oauth-protected-resource/mcp"
curl -s https://ssh-mcp-oauth.<子域>.workers.dev/.well-known/oauth-protected-resource/mcp
# "resource" 必须正好是 https://ssh-mcp-oauth.<子域>.workers.dev/mcp
```

### 第 6 步：在 claude.ai 里添加

1. claude.ai → 设置 → Connectors（连接器）→ Add custom connector（添加自定义连接器）。
2. URL 填 `https://ssh-mcp-oauth.<子域>.workers.dev/mcp`。
3. OAuth Client ID / Secret 留空（Worker 支持动态注册和 Client ID Metadata Document，claude.ai 会自己注册）。
4. 点 Connect：先看到本 Worker 的授权页，确认令牌发往 `claude.ai`，点「允许」；再跳到 GitHub 登录。
5. 连上后在对话里打开这个连接器即可。

## 防火墙与出站

- **入站**：用 Tunnel 时，跑 ssh-mcp 的机器不需要为它开任何入站端口。3000 端口只绑 127.0.0.1。SSH 管理端口最好只对你自己的 IP 开放。
- **出站**：这台机器只需要连到 Cloudflare（cloudflared 用 7844 端口，TCP/UDP）和你目标主机的 22 端口。可以用防火墙把其他出站都拒掉，限制一旦被滥用时能波及的范围。
- **Anthropic 出口 IP**：claude.ai 访问连接器的请求来自 `160.79.104.0/21`。它访问的是 Worker，不是你的服务器，所以在服务器防火墙上放行这个网段没有意义。如果 Worker 绑在你自己域名上，可以在 Cloudflare WAF 里限制 `/mcp`、`/token`、`/register`、`/.well-known/*` 只接受这个网段；`/authorize` 和 `/callback` 是你的浏览器访问的，**不能**限制。`*.workers.dev` 地址不能挂 WAF 规则。
- **目标主机**：如果可以，让目标主机的 22 端口只接受跑 ssh-mcp 那台机器的 IP。

## 撤销与轮换

- **立刻断开**：从 `ALLOWED_GITHUB_LOGINS` / `ALLOWED_GITHUB_IDS` 删掉账号并重新部署，所有已发的令牌下一次请求就会被拒。
- **轮换 bearer**：改 `/etc/ssh-mcp/env`，`systemctl restart ssh-mcp`，再 `npx wrangler secret put BACKEND_BEARER_TOKEN`。
- **清掉所有授权**：在 claude.ai 断开连接器；需要彻底清除时可以删掉并重建 `OAUTH_KV`。
- **紧急关停**：`systemctl stop ssh-mcp` 或停掉 Tunnel。

## 排错

| 现象 | 可能原因 |
| --- | --- |
| claude.ai 提示 Couldn't reach the MCP server | `PUBLIC_URL` 和实际地址不一致；或 Worker 返回 503（缺配置，看 `npx wrangler tail`） |
| 授权页显示「不允许的回调地址」 | 客户端不是 claude.ai，或用 Claude Code 但没加 `loopback` |
| GitHub 登录后显示「账号不在白名单」 | 登录名或数字 ID 不匹配 |
| 工具调用返回 502「refused the proxy」 | Worker 里的 `BACKEND_BEARER_TOKEN` 和服务器上的不一致 |
| 502「redirected the proxy」 | Tunnel 主机名有 Access 保护，但 Worker 没配服务令牌 |
| 502「unreachable」 | Tunnel 没连上或 ssh-mcp 没运行 |
| 命令返回 `APPROVAL_UNAVAILABLE` | 正常：这是需要审批的命令，而客户端没法弹窗，所以被拒 |
| ssh-mcp 日志里出现 `X-Forwarded-For` 警告 | 正常：所有请求都经 Tunnel 从本机进来，共用一个限流额度；只有你一个客户端时没影响 |

## 开发

```bash
npm ci
npm test            # vitest，纯函数和转发逻辑
npm run typecheck
npm run build       # wrangler 打包检查，不部署
```

本地跑完整流程需要 https（`npx wrangler dev --local-protocol https`，`PUBLIC_URL` 设成 `https://localhost:8787`）。

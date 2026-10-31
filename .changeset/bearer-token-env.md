---
"ssh-mcp": minor
---

The HTTP transport reads its bearer token from `SSH_MCP_BEARER_TOKEN` when `--bearerToken` is not given, so the token no longer has to sit in the process list where every local account can read it. Adds `cloudflare-oauth-proxy/`, an optional Cloudflare Worker that puts OAuth 2.1 (GitHub sign-in, one allowlisted owner) in front of the HTTP transport so it can be added to claude.ai as a custom connector.

# 主机模板：ssh-mcp 专用账号、sshd、sudoers、引导脚本

这一组文件把“Claude 通过 ssh-mcp 管服务器”在主机这一侧落地：每台机器上一个专用账号（默认 `claudeops`），只接受控制机来的公钥登录；生产机只读、没有 sudo；测试机能操作，sudo 只放行白名单里的几条命令。ssh-mcp 那一侧的配置模板也在这里，按同样的分组写好了。

所有地址、指纹、密钥路径都是占位符。真实值只放在控制机和你自己的电脑上，不要提交回仓库。

## 文件

| 文件 | 放在哪 | 作用 |
| --- | --- | --- |
| `config.toml.example` | 控制机，ssh-mcp 的配置 | 30 台主机，按 prod/test 分组；审批永不 auto；禁用命令、每日额度 |
| `sshd_config.d/10-claudeops.conf` | 每台主机 `/etc/ssh/sshd_config.d/` | 只约束专用账号：只认公钥、只认控制机地址、公钥只从 root 管的文件读、不能转发 |
| `sshd_config.d/05-hardening.conf` | 同上，可选（`--harden`） | 全局禁 root 登录、禁密码登录 |
| `sudoers.d/claudeops` | 测试机 `/etc/sudoers.d/` | sudo 白名单示例，按你的服务改 |
| `bootstrap-hosts.sh` | 你自己的电脑 | 批量建账号、装公钥和上面两份限制，默认只预览 |
| `hosts.txt.example` | 你自己的电脑 | 引导脚本的主机清单格式 |

## 一条命令要过几道关

1. **claude.ai 侧**：只有白名单里的 GitHub 账号能拿到令牌（见 [OAuth 代理](../../cloudflare-oauth-proxy/README.md)）。
2. **ssh-mcp 侧**：命令先分类（只读、安全、破坏性、特权），再按主机的角色决定放行、拒绝还是问你。生产 profile 是 `viewer` + `readOnly` + `deny`，改动和 sudo 直接拒绝；测试 profile 的删改和 sudo 每一条都弹审批，`approvalGrantTtlMs = 0`，同意一次只管一条。另有内置的“永不允许”列表和模板里追加的 `denylist`，每台每天还有命令额度。
3. **主机侧**：`claudeops` 不在 sudo、wheel、docker 这类等同 root 的组里；生产机没有 sudoers；测试机的 sudoers 只列完整命令。公钥带 `from="控制机IP"` 和 `restrict`，sshd 再按来源地址拦一次。

前两层是软件策略，第三层是操作系统权限。就算 ssh-mcp 的分类被绕过，在生产机上它也只是一个没有 sudo、不能转发的普通账号。

命令的输出会进到模型的上下文里。日志、网页、文件内容里可能藏着诱导模型做别的事的文字（提示注入），所以权限要收紧到“被诱导了也闯不了大祸”：生产只读、外传数据的命令在 `denylist` 里、审批不要自动通过。

## 使用步骤

### 1. 在控制机上生成专用密钥

控制机就是跑 ssh-mcp 的那台（[OAuth 代理 README](../../cloudflare-oauth-proxy/README.md) 第 2 步里的 `sshmcp` 账号）。

```bash
sudo -u sshmcp ssh-keygen -t ed25519 -N '' -C claudeops@control -f /home/sshmcp/.ssh/claudeops_ed25519
sudo cat /home/sshmcp/.ssh/claudeops_ed25519.pub     # 复制到你自己的电脑，存成 claudeops_ed25519.pub
```

私钥不离开控制机。再查一下控制机连目标主机时的出口地址，后面的 `--control-ip` 要用：

```bash
# 在控制机上：先登录任意一台目标主机，再看 SSH_CONNECTION 的第一个字段，就是那台主机看到的来源地址
ssh <你的账号>@<任意一台目标主机> 'echo $SSH_CONNECTION'
```

### 2. 写主机清单

```bash
cp hosts.txt.example hosts.txt     # hosts.txt 已被 .gitignore 忽略
```

每行三列：profile 名、你自己登录这台机器用的 ssh 目标、角色（`prod` 或 `test`）。第二列是“你”的登录方式，脚本用它连过去，不是 `claudeops` 的。

### 3. 先预览

```bash
./bootstrap-hosts.sh --hosts hosts.txt --pubkey claudeops_ed25519.pub --control-ip <控制机IP>
```

默认什么都不改，只连上去读一遍，每台机器打印“已有”或“将要”做什么，最后打印每台的主机指纹。你的 sudo 要密码的话，它会在终端里问你。

### 4. 执行

```bash
./bootstrap-hosts.sh --hosts hosts.txt --pubkey claudeops_ed25519.pub --control-ip <控制机IP> --apply
# 想让 claudeops 不用 sudo 就能看日志：
#   --extra-groups systemd-journal
```

可以反复跑。已经和模板一致的东西不会再动；sshd 配置没变时也不会重载 sshd。

**不会把你锁在外面**，靠的是这几件事：

- `10-claudeops.conf` 只有 `Match User claudeops` 段，你的账号怎么登录完全不变。
- 每台机器只用一条主连接干所有事，重载 sshd 不会断开已有连接。
- 改 sshd 前先备份；`sshd -t` 不通过就还原，不重载；装上后再用 `sshd -T` 核对生效值，不对也还原。
- 重载后，脚本用一条**全新的**连接试你还能不能登录，登不上就立刻通过原连接回滚。
- 远端同时挂着一个定时回滚（默认 180 秒，`--confirm-timeout` 可改）：哪怕你这边断网，没收到确认到点也会自动还原。
- sudoers 先在临时文件上 `visudo -cf`，装上后再 `visudo -c` 全量检查，不过就撤回，不会弄坏 sudo。

**全局加固（可选）**：加 `--harden` 会再装 `05-hardening.conf`，禁止 root 登录和所有密码登录。这一项影响机器上的每个账号，所以脚本在两种情况下拒绝：你是用 root 登录的；你的登录账号没有 `authorized_keys`（看起来是密码登录）。先建好带公钥、能 sudo 的普通账号再加固。

### 5. 在控制机上验证

从你自己的电脑用 `claudeops` 是登不上的，这是对的。在控制机上逐台试：

```bash
sudo -u sshmcp ssh -i /home/sshmcp/.ssh/claudeops_ed25519 claudeops@<主机> 'id; sudo -n -l'
```

生产机上 `sudo -n -l` 应该要密码（等于没有 sudo）；测试机上应该只列出白名单里的命令。

### 6. 配 ssh-mcp

```bash
sudo -u sshmcp install -D -m 600 /dev/null /home/sshmcp/.config/ssh-mcp/config.toml
# 把 config.toml.example 的内容粘进去，改成你的主机地址
sudoedit /home/sshmcp/.config/ssh-mcp/config.toml   # 或 sudo -u sshmcp vi ...
```

- 把第 4 步结尾打印的 `trustedHostKey = "SHA256:..."` 逐台粘到对应 profile 里。这些指纹是通过你已经信任的登录连接、直接在主机上读出来的。
- systemd 的 `ExecStart` 加上 `--hostKeyMode=strict --auditTamperEvident`：没钉指纹的主机一律拒连，审计日志带哈希链。再加一行 `ExecReload=/bin/kill -HUP $MAINPID`，以后改配置用 `systemctl reload ssh-mcp` 热加载。
- 配置写错时 ssh-mcp 会拒绝启动或拒绝热加载（旧配置继续生效），不会悄悄忽略。

### 7. 改 sudo 白名单

改 `sudoers.d/claudeops` 里的 `Cmnd_Alias`，再跑一遍第 4 步的命令。写的时候守住模板开头那三条：完整路径加完整参数、不放会翻页或开编辑器的命令（`systemctl status`、`journalctl`、`less`、`vi` 都能敲 `!sh` 拿 root）、不放能写任意文件或跑任意程序的命令。

## 急停

从快到彻底，按需要选一层就行：

1. **claude.ai**：在设置里断开这个连接器。之后的对话用不到它。
2. **OAuth 代理**：把 Worker 的 `ALLOWED_GITHUB_LOGINS` 改成空再部署，已经发出去的令牌下一次请求就会被拒。
3. **控制机**：`sudo systemctl stop ssh-mcp`，所有 SSH 连接随进程一起断；需要的话再停 `cloudflared`。
4. **只收紧不全停**：把配置里的 `approvalMode` 和测试 profile 的 `approvalPolicy` 改成 `"deny"`，再 `systemctl reload ssh-mcp`。已有连接从下一条命令起生效。
5. **主机侧封账号**：控制机本身可能有问题时用这个，它从你自己的电脑直接下手，不经过控制机：

   ```bash
   ./bootstrap-hosts.sh --hosts hosts.txt --control-ip <控制机IP> --lock --apply
   ```

   每台机器上把账号设为已过期（公钥也登不上）、停用它的公钥文件、杀掉它的所有进程。不加 `--apply` 是预览。单台手工做等价于：

   ```bash
   sudo usermod --expiredate 1 claudeops
   sudo mv /etc/ssh/authorized_keys/claudeops /etc/ssh/authorized_keys/claudeops.disabled
   sudo pkill -KILL -u claudeops
   ```

   恢复：确认安全后跑第 4 步的命令并加 `--unlock`。封禁状态下不加 `--unlock` 的话，脚本什么都不改。

## 换钥

控制机的密钥定期换，或者怀疑泄露时马上换。新旧并存一段，中间不断服务：

1. 控制机上生成新钥：`sudo -u sshmcp ssh-keygen -t ed25519 -N '' -C claudeops@control -f /home/sshmcp/.ssh/claudeops_ed25519_new`，把 `.pub` 拿到你的电脑。
2. 新旧一起装：`./bootstrap-hosts.sh ... --pubkey claudeops_ed25519.pub --pubkey claudeops_ed25519_new.pub --apply`
3. 改配置里所有 profile 的 `keyRef` 指向新钥，`systemctl reload ssh-mcp`。`keyRef` 变了的连接会断开重连。在控制机上挑一台验证能登录。
4. 只装新钥：`./bootstrap-hosts.sh ... --pubkey claudeops_ed25519_new.pub --apply`，旧钥从所有主机上删掉。
5. 控制机上删旧私钥：`sudo shred -u /home/sshmcp/.ssh/claudeops_ed25519`。

怀疑泄露时跳过第 2 步，直接只装新钥，或者先急停封账号再换。

相关的几种变化：

- **控制机地址变了**：用新地址重跑 `--control-ip <新IP> --apply`，sshd 的 Match 和公钥的 `from=` 一起更新。地址变了而没重跑，`claudeops` 就登不上，这是故意的。
- **主机重装、指纹变了**：ssh-mcp 会报指纹不符并拒连。先确认是你自己重装的，再用预览模式跑这一台（`--only <profile 名>`）拿新指纹，更新 `trustedHostKey`。
- **OAuth 和 bearer token 的轮换**：见 [OAuth 代理 README](../../cloudflare-oauth-proxy/README.md) 的“撤销与轮换”。

## 审计日志

ssh-mcp 把每条命令、审批结果写进 `/home/sshmcp/.local/share/ssh-mcp/audit.log`（`$XDG_DATA_HOME/ssh-mcp/audit.log`，权限 600）。开了 `--auditTamperEvident` 后每条记录带前一条的哈希，中间被改能看出来，但整份删掉看不出来，所以要定期复制到**另一台**机器上。推荐由另一台机器来拉，这样控制机上不存任何能写备份的凭据：

```bash
# 控制机，root 的 crontab：每小时把日志复制到一个只读目录，给专门的拉取账号读
15 * * * * install -D -m 0640 -o root -g auditpull /home/sshmcp/.local/share/ssh-mcp/audit.log /var/lib/ssh-mcp-audit/audit.log

# 备份机，每小时拉一份，按时间存
20 * * * * rsync -a auditpull@<控制机>:/var/lib/ssh-mcp-audit/audit.log /srv/backup/ssh-mcp/audit-$(date +\%F-\%H).log
```

`auditpull` 是控制机上一个普通账号，只在 `auditpull` 组里，公钥带 `from="<备份机IP>"`。也可以推到开了对象锁定（不可删除）的存储桶里，原则一样：控制机删不掉已经送出去的副本。

## 校验

这些模板在仓库里是这样检查过的：

- `config.toml.example` 由 `test/unit/config/claudeops-template.test.ts` 用 ssh-mcp 自己的加载器加载，并用策略引擎实际判定：生产只放行只读命令；测试机的删改和 sudo 都要审批；追加的禁用命令在测试机上也被拒；`sftp-list` 不被误拦。
- 两份 sshd drop-in 用 `sshd -t` 检查语法，用 `sshd -T -C` 核对了生效值：从控制机来的 `claudeops` 只认公钥、公钥文件在 `/etc/ssh/authorized_keys/`；从别的地址来连公钥都被关掉；其他账号不受影响。
- `sudoers.d/claudeops` 过了 `visudo -cf`。
- `bootstrap-hosts.sh` 过了 `shellcheck`，并在一台本地 sshd 上实跑：预览不改动、执行后 `claudeops` 只能从控制机地址登录、端口转发被拒、自己家目录里的公钥不生效、生产角色拿不到 sudo、重跑不重复修改、加固后管理账号仍能登录、模拟“重载后登不上”时立即回滚、连回滚命令也发不出去时远端定时回滚生效、封账号和解封。

没有在你的真实主机上跑过。第一次用时先 `--only` 挑一台测试机。

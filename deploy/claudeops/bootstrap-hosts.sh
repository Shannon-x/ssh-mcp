#!/usr/bin/env bash
# bootstrap-hosts.sh — 在一批主机上建 ssh-mcp 专用账号，装控制机公钥、sshd 和 sudoers 限制。
#
# 在你自己的电脑上跑，用你现在就能登录这些主机的方式（你的 ~/.ssh/config、你的密钥、你的 sudo）。
# 默认只看不改（dry-run），打印每台机器会改什么；确认无误后加 --apply 才真正执行。
# 可以反复跑：已经是目标状态的东西不会再动，也不会重载 sshd。
#
# 不会把你锁在外面：
#   - sshd 只加 Match 段，只约束专用账号；全局加固（禁 root/禁密码）要另加 --harden，
#     而且你用 root 登录或没有 authorized_keys 时脚本拒绝加固。
#   - 改 sshd 前备份，`sshd -t` 不通过就还原，不重载。
#   - 所有操作走一条复用的主连接；重载 sshd 不会断开已有连接。
#   - 重载后用一条全新的连接测试你还能登录；失败立刻通过主连接回滚。
#   - 远端还挂着一个定时回滚（默认 180 秒）：万一本机断网没来得及确认，到点自动还原。
#   - sudoers 先在临时文件上 `visudo -cf`，装上后再 `visudo -c` 全量检查，不过就撤回。
#
# 本机需要 bash 3.2 以上（macOS 自带的就行）和 OpenSSH；远端需要 Linux、bash、base64、sudo 或 root。
#
# 用法：
#   ./bootstrap-hosts.sh --hosts hosts.txt --pubkey claudeops_ed25519.pub --control-ip 203.0.113.10
#   ./bootstrap-hosts.sh ... --apply                 # 真正执行
#   ./bootstrap-hosts.sh ... --apply --harden        # 同时禁 root 登录和密码登录（全局）
#   ./bootstrap-hosts.sh ... --lock --apply          # 急停：封掉专用账号、踢掉它的会话
#   ./bootstrap-hosts.sh ... --apply --unlock        # 解封后按模板重新装好
#
# hosts 文件每行三列：profile 名  你登录用的 ssh 目标  角色(prod|test)，# 开头是注释。见 hosts.txt.example。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CLAUDEOPS_USER=claudeops
HOSTS_FILE=
CONTROL_IP=
PUBKEYS=()
EXTRA_GROUPS=
LOCK=0
APPLY=0
HARDEN=0
UNLOCK=0
CONFIRM_TIMEOUT=180
SSH_OPTS=()
ONLY=

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  cat <<'EOF'
参数：
  --hosts FILE          主机清单（必填）
  --pubkey FILE         控制机上 ssh-mcp 用的公钥，可以给多次（换钥时新旧一起给）
  --control-ip IP       控制机的出口地址，只有它能用专用账号登录（必填，可写 CIDR）
  --user NAME           专用账号名，默认 claudeops
  --extra-groups G,G    额外加入的组，例如 systemd-journal（让它不用 sudo 就能读 journalctl）
  --only NAME           只处理清单里这一台
  --apply               真正执行；不加就是 dry-run
  --harden              另外安装 05-hardening.conf（全局禁 root、禁密码登录）
  --lock                急停：封账号、删公钥、杀会话（配合 --apply）
  --unlock              解除 --lock 设的账号过期
  --confirm-timeout S   远端定时回滚的秒数，默认 180
  --ssh-option OPT      传给 ssh 的 -o 选项，可以给多次
  -h, --help            显示这段说明
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --hosts) HOSTS_FILE=${2:?}; shift 2 ;;
    --pubkey) PUBKEYS+=("${2:?}"); shift 2 ;;
    --control-ip) CONTROL_IP=${2:?}; shift 2 ;;
    --user) CLAUDEOPS_USER=${2:?}; shift 2 ;;
    --extra-groups) EXTRA_GROUPS=${2:?}; shift 2 ;;
    --only) ONLY=${2:?}; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --lock) LOCK=1; shift ;;
    --unlock) UNLOCK=1; shift ;;
    --harden) HARDEN=1; shift ;;
    --confirm-timeout) CONFIRM_TIMEOUT=${2:?}; shift 2 ;;
    --ssh-option) SSH_OPTS+=(-o "${2:?}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "不认识的参数 $1（--help 看用法）" ;;
  esac
done

# --lock 不带 --apply 时也只是预览。
if [ "$LOCK" = 1 ]; then MODE=lock; elif [ "$APPLY" = 1 ]; then MODE=apply; else MODE=plan; fi

[ -n "$HOSTS_FILE" ] || die "缺 --hosts"
[ -r "$HOSTS_FILE" ] || die "读不了 $HOSTS_FILE"
[ -n "$CONTROL_IP" ] || die "缺 --control-ip"

# 这些值会写进 sshd 配置、sudoers 和 authorized_keys，所以只收严格的格式，杜绝注入。
[[ $CLAUDEOPS_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "--user 只能是小写字母、数字、下划线和连字符"
[ "$CLAUDEOPS_USER" != root ] || die "专用账号不能是 root"
[[ $CONTROL_IP =~ ^[0-9A-Fa-f.:]+(/[0-9]{1,3})?$ ]] || die "--control-ip 要写 IP 或 CIDR，例如 203.0.113.10"
[[ $CONFIRM_TIMEOUT =~ ^[0-9]+$ ]] && [ "$CONFIRM_TIMEOUT" -ge 30 ] || die "--confirm-timeout 至少 30 秒"
[ -z "$EXTRA_GROUPS" ] || [[ $EXTRA_GROUPS =~ ^[a-z_][a-z0-9_-]*(,[a-z_][a-z0-9_-]*)*$ ]] || die "--extra-groups 格式不对"

for f in sshd_config.d/10-claudeops.conf sshd_config.d/05-hardening.conf sudoers.d/claudeops; do
  [ -r "$SCRIPT_DIR/$f" ] || die "模板缺失：$SCRIPT_DIR/$f"
done

# authorized_keys 的每一行：restrict 关掉转发、agent、X11、~/.ssh/rc；pty 留给交互式会话；
# from= 是 sshd Match 之外的第二道来源限制。
KEYS=
if [ "$MODE" != lock ]; then
  [ ${#PUBKEYS[@]} -gt 0 ] || die "缺 --pubkey"
  for pk in "${PUBKEYS[@]}"; do
    [ -r "$pk" ] || die "读不了公钥 $pk"
    case $pk in *.pub) ;; *) die "$pk 不像公钥文件（要 .pub）。千万别把私钥传进来" ;; esac
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      [[ $line =~ ^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] \
        || die "$pk 里有一行不是裸公钥（可能已经带了选项），请只放 'ssh-ed25519 AAAA... 注释' 这种格式"
      printf '%s\n' "$line" | ssh-keygen -lf - >/dev/null 2>&1 || die "$pk 里有一行 ssh-keygen 认不出来"
      KEYS+="restrict,pty,from=\"$CONTROL_IP\" $line"$'\n'
    done < "$pk"
  done
  [ -n "$KEYS" ] || die "公钥文件是空的"
fi

render() { sed -e "s/__CLAUDEOPS_USER__/$CLAUDEOPS_USER/g" -e "s#__CONTROL_IP__#$CONTROL_IP#g" "$SCRIPT_DIR/$1"; }
b64() { base64 | tr -d '\n'; }

KEYS_B64=$(printf '%s' "$KEYS" | b64)
SSHD_B64=$(render sshd_config.d/10-claudeops.conf | b64)
HARDEN_B64=$(render sshd_config.d/05-hardening.conf | b64)
SUDO_B64=$(render sudoers.d/claudeops | b64)

# ---------------------------------------------------------------------------
# 在远端以 root 执行的部分。变量由本机拼进来，全部是上面校验过的值或 base64。
# 退出码：0 完成且 sshd 没变；10 sshd 已重载，等本机确认；其他是失败。
# ---------------------------------------------------------------------------
remote_body() {
  cat <<'REMOTE'
set -euo pipefail
umask 022
APPLY_N=$APPLY
STATE=/run/claudeops-bootstrap
PENDING=$STATE/confirm/pending
ADMIN=${SUDO_USER:-root}
SSHD=$(command -v sshd || echo /usr/sbin/sshd)
KEYDIR=/etc/ssh/authorized_keys
DROPIN=/etc/ssh/sshd_config.d
SSHD_CHANGED=0
FAILED=0

say()  { printf '  %-6s %s\n' "$1" "$2"; }
fail() { say 错误 "$1"; FAILED=1; }
dec()  { printf '%s' "$1" | base64 -d; }
# 计划模式只说不做：CHANGE 行都以“将”开头。
act()  { if [ "$APPLY_N" = 1 ]; then say 修改 "$1"; return 0; else say 将要 "$1"; return 1; fi; }

same_content() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }

# 写到同目录的临时文件再改名，读的一方永远看不到写了一半的文件。
put_file() {
  local path=$1 content=$2 mode=$3 tmp
  tmp=$(mktemp "$(dirname "$path")/.$(basename "$path").XXXXXX")
  printf '%s\n' "$content" > "$tmp"
  chown root:root "$tmp"; chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
}

reload_sshd() {
  local unit
  for unit in ssh sshd; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then systemctl reload "$unit"; return; fi
  done
  if [ -r /run/sshd.pid ]; then kill -HUP "$(cat /run/sshd.pid)"; return; fi
  say 提示 "没找到在跑的 sshd 服务，新配置会在 sshd 下次启动时生效"
}

printf '%s\n' "--- $(hostname)（以 $ADMIN 的身份登录，角色 $ROLE）"

if [ "$MODE" = lock ]; then
  if ! id "$U" >/dev/null 2>&1; then say 跳过 "账号 $U 不存在"; exit 0; fi
  if act "封账号 $U（设为已过期，公钥登录也会被拒），停用它的公钥，杀掉它的所有进程"; then
    usermod --expiredate 1 "$U"
    if [ -f "$KEYDIR/$U" ]; then mv -f "$KEYDIR/$U" "$KEYDIR/$U.disabled-$(date +%Y%m%d%H%M%S)"; fi
    pkill -KILL -u "$U" 2>/dev/null || true
  fi
  exit 0
fi

[ -x "$SSHD" ] || { fail "找不到 sshd"; exit 3; }
if ! grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  fail "/etc/ssh/sshd_config 里没有 Include /etc/ssh/sshd_config.d/*.conf，drop-in 不会生效。先手工加上再跑"
  exit 3
fi

# 1. 账号 -----------------------------------------------------------------
if id "$U" >/dev/null 2>&1; then
  say 已有 "账号 $U"
else
  if act "创建账号 $U（不设密码，只能用公钥登录）"; then
    useradd -m -s /bin/bash -c "ssh-mcp (Claude)" "$U"
  fi
fi
if id "$U" >/dev/null 2>&1; then
  # '!' 开头的密码在 UsePAM no 的机器上会连公钥一起拒掉；'*' 只是“没有密码”。
  if [ "$(getent shadow "$U" | cut -d: -f2)" != '*' ]; then
    act "把 $U 的密码设成不可用（*）" && usermod -p '*' "$U"
  fi
  expiry=$(getent shadow "$U" | cut -d: -f8)
  if [ -n "$expiry" ] && [ "$expiry" -le "$(( $(date +%s) / 86400 ))" ]; then
    if [ "$UNLOCK" = 1 ]; then
      act "解除 $U 的过期（之前急停封过）" && usermod --expiredate '' "$U"
    else
      # 直接停下：封禁状态下连公钥都不该重新装回去。
      fail "$U 处于封禁（过期）状态，这次什么都没改。确认要恢复时加 --unlock"
      exit 3
    fi
  fi
  for g in $(id -nG "$U"); do
    case $g in sudo|wheel|admin|root|docker|lxd|libvirt|disk|shadow)
      fail "$U 在 $g 组里，这个组等于 root 权限。请手工移出：gpasswd -d $U $g" ;;
    esac
  done
  for g in ${EXTRA_GROUPS//,/ }; do
    if ! getent group "$g" >/dev/null; then say 跳过 "组 $g 在这台机器上不存在"; continue; fi
    if ! id -nG "$U" | tr ' ' '\n' | grep -qx "$g"; then
      act "把 $U 加进 $g 组" && usermod -aG "$g" "$U"
    fi
  done
fi

# 2. 公钥：放在 root 管理的目录，账号自己改不了 -------------------------------
KEYS=$(dec "$KEYS_B64")
if [ ! -d "$KEYDIR" ]; then act "创建 $KEYDIR" && install -d -o root -g root -m 0755 "$KEYDIR"; fi
if same_content "$KEYDIR/$U" "$KEYS"; then
  say 已有 "$KEYDIR/$U 和模板一致"
elif act "写入 $KEYDIR/$U（$(printf '%s\n' "$KEYS" | grep -c .) 把控制机公钥，限定来源 $CONTROL_IP）"; then
  put_file "$KEYDIR/$U" "$KEYS" 0644
fi

# 3. sudoers：只有测试机有，生产机确保没有 ------------------------------------
SUDOERS=/etc/sudoers.d/$U
if [ "$ROLE" = test ]; then
  WANT=$(dec "$SUDO_B64")
  if same_content "$SUDOERS" "$WANT"; then
    say 已有 "$SUDOERS 和模板一致"
  else
    command -v visudo >/dev/null || { fail "没有 visudo，装不了 sudoers"; exit 3; }
    check=$(mktemp); printf '%s\n' "$WANT" > "$check"
    if ! visudo -cf "$check" >/dev/null; then
      rm -f "$check"; fail "sudoers 模板没通过 visudo -cf，没安装"
    else
      rm -f "$check"
      if act "安装 $SUDOERS（白名单命令，见模板）"; then
        backup=
        if [ -f "$SUDOERS" ]; then backup=$(mktemp); cp -p "$SUDOERS" "$backup"; fi
        # 带点的文件名会被 #includedir 忽略，所以先写成 .claudeops.XXXX 再改名。
        put_file "$SUDOERS" "$WANT" 0440
        if ! visudo -c >/dev/null 2>&1; then
          if [ -n "$backup" ]; then mv -f "$backup" "$SUDOERS"; else rm -f "$SUDOERS"; fi
          fail "装上后 visudo -c 不通过，已撤回"
        fi
        rm -f "${backup:-/nonexistent}"
      fi
    fi
  fi
else
  if [ -f "$SUDOERS" ]; then
    act "删除 $SUDOERS（生产机不给这个账号 sudo）" && rm -f "$SUDOERS"
  fi
  if id "$U" >/dev/null 2>&1 && sudo -n -l -U "$U" 2>/dev/null | grep -q 'may run the following'; then
    fail "$U 在这台生产机上还能 sudo（来自别的 sudoers 规则），请手工清掉：sudo -l -U $U"
  fi
fi

# 4. sshd drop-in ---------------------------------------------------------
if [ "$HARDEN" = 1 ]; then
  home=$(getent passwd "$ADMIN" | cut -d: -f6)
  if [ "$ADMIN" = root ]; then
    fail "你是用 root 登录的，--harden 会禁止 root 登录，下次就进不来了。先建一个有 sudo 的普通账号再加固"
    HARDEN=0
  elif [ ! -s "$home/.ssh/authorized_keys" ]; then
    fail "$ADMIN 没有 ~/.ssh/authorized_keys，看起来是用密码登录的，--harden 会禁掉密码登录。先配好公钥再加固"
    HARDEN=0
  fi
fi

files=("10-claudeops.conf")
contents=("$(dec "$SSHD_B64")")
if [ "$HARDEN" = 1 ]; then files+=("05-hardening.conf"); contents+=("$(dec "$HARDEN_B64")"); fi

changed=()
for i in "${!files[@]}"; do
  if same_content "$DROPIN/${files[$i]}" "${contents[$i]}"; then
    say 已有 "$DROPIN/${files[$i]} 和模板一致"
  else
    changed+=("$i")
  fi
done

if [ ${#changed[@]} -gt 0 ] && [ "$FAILED" = 0 ]; then
  names=$(for i in "${changed[@]}"; do printf '%s ' "${files[$i]}"; done)
  if act "安装 sshd drop-in：${names}（先 sshd -t 校验，再重载 sshd）"; then
    # backup 和 rollback.sh 只有 root 能动；confirm/ 归你的登录账号，确认时不用再 sudo。
    install -d -m 0755 "$STATE"; install -d -m 0700 "$STATE/backup"
    install -d -m 0700 -o "$ADMIN" "$STATE/confirm"
    rollback="$STATE/rollback.sh"
    { echo '#!/bin/sh'; echo "# 自动生成：还原 $(date '+%F %T') 之前的 sshd drop-in"; } > "$rollback"
    for i in "${changed[@]}"; do
      f=$DROPIN/${files[$i]}
      if [ -f "$f" ]; then
        cp -p "$f" "$STATE/backup/${files[$i]}"
        echo "cp -p '$STATE/backup/${files[$i]}' '$f'" >> "$rollback"
      else
        echo "rm -f '$f'" >> "$rollback"
      fi
      install -d -m 0755 "$DROPIN"
      put_file "$f" "${contents[$i]}" 0644
    done
    cat >> "$rollback" <<EOF2
reloaded=0
for unit in ssh sshd; do
  if systemctl is-active --quiet "\$unit" 2>/dev/null; then systemctl reload "\$unit"; reloaded=1; break; fi
done
if [ "\$reloaded" = 0 ] && [ -r /run/sshd.pid ]; then kill -HUP "\$(cat /run/sshd.pid)"; fi
rm -f '$PENDING'
logger -t claudeops-bootstrap "rolled back sshd drop-ins" 2>/dev/null || true
EOF2
    chmod 0700 "$rollback"

    if ! "$SSHD" -t; then
      sh "$rollback" >/dev/null 2>&1 || true
      fail "sshd -t 没通过，已还原，sshd 没有重载"
    else
      # 生效值检查：从控制机来是公钥 + root 管理的 keys 文件；从别处来公钥被关掉。
      eff_ok=$("$SSHD" -T -C "user=$U,host=probe,addr=$CONTROL_PROBE,laddr=127.0.0.1,lport=22" | grep -ci '^authorizedkeysfile /etc/ssh/authorized_keys/%u$' || true)
      eff_deny=$("$SSHD" -T -C "user=$U,host=probe,addr=192.0.2.254,laddr=127.0.0.1,lport=22" | grep -ci '^pubkeyauthentication no$' || true)
      if [ "$eff_ok" != 1 ] || [ "$eff_deny" != 1 ]; then
        sh "$rollback" >/dev/null 2>&1 || true
        fail "装上后 sshd -T 显示的生效值不对（可能有别的配置抢先生效），已还原"
      else
        # 定时回滚：本机确认前它一直等着；确认就是删掉 pending 文件。
        touch "$PENDING"; chown "$ADMIN" "$PENDING"
        if [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1; then
          systemd-run --quiet --collect --unit "claudeops-rollback-$$" --on-active="$TIMEOUT" \
            /bin/sh -c "[ -e '$PENDING' ] && sh '$rollback'" >/dev/null
        else
          setsid nohup sh -c "sleep $TIMEOUT; [ -e '$PENDING' ] && sh '$rollback'" >/dev/null 2>&1 < /dev/null &
        fi
        reload_sshd
        SSHD_CHANGED=1
        say 等待 "sshd 已重载。${TIMEOUT} 秒内没收到确认会自动还原"
      fi
    fi
  fi
fi

if [ "$HARDEN" = 1 ] && [ "$APPLY_N" = 1 ] && [ "$FAILED" = 0 ]; then
  # 先存下来再 grep：grep -q 提前退出会让 sshd 收到 SIGPIPE，在 pipefail 下被当成失败。
  eff=$("$SSHD" -T -C "user=$ADMIN,host=probe,addr=192.0.2.254,laddr=127.0.0.1,lport=22")
  printf '%s\n' "$eff" | grep -qi '^permitrootlogin no$' \
    || say 提示 "PermitRootLogin 的生效值不是 no，有更早的配置覆盖了 05-hardening.conf，请检查"
fi

# 5. 主机指纹，给 ssh-mcp 的 trustedHostKey 用 ----------------------------------
if [ -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
  printf 'FINGERPRINT %s\n' "$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
fi

[ "$FAILED" = 0 ] || exit 3
[ "$SSHD_CHANGED" = 0 ] || exit 10
exit 0
REMOTE
}

# 用控制机地址里的第一个 IP 去问 sshd -T（CIDR 取网络地址即可，它也在范围内）。
CONTROL_PROBE=${CONTROL_IP%/*}

build_remote() {
  local role=$1
  {
    printf 'U=%s\nROLE=%s\nMODE=%s\nAPPLY=%s\nHARDEN=%s\nUNLOCK=%s\nTIMEOUT=%s\n' \
      "$CLAUDEOPS_USER" "$role" "$MODE" "$APPLY" "$HARDEN" "$UNLOCK" "$CONFIRM_TIMEOUT"
    printf 'CONTROL_IP=%s\nCONTROL_PROBE=%s\nEXTRA_GROUPS=%s\n' "$CONTROL_IP" "$CONTROL_PROBE" "$EXTRA_GROUPS"
    printf 'KEYS_B64=%s\nSSHD_B64=%s\nHARDEN_B64=%s\nSUDO_B64=%s\n' "$KEYS_B64" "$SSHD_B64" "$HARDEN_B64" "$SUDO_B64"
    remote_body
  } | b64
}

# 放在 /tmp 而不是 $TMPDIR：macOS 的 $TMPDIR 很长，主连接的 socket 路径会超过 104 字节的上限。
SOCKDIR=$(mktemp -d /tmp/claudeops-bootstrap.XXXXXX)
cleanup() {
  local s
  for s in "$SOCKDIR"/*.sock; do
    [ -S "$s" ] && ssh -o ControlPath="$s" -O exit placeholder >/dev/null 2>&1 || true
  done
  rm -rf "$SOCKDIR"
}
trap cleanup EXIT

if [ "$APPLY" = 1 ]; then
  echo "== 执行模式：会真正修改主机（$MODE）"
else
  echo "== 预览模式（dry-run）：只读取，不做任何修改。确认后加 --apply"
fi

RESULTS=()
FINGERPRINTS=()
LOG="$SOCKDIR/remote.log"
# 有终端时给远端分配 pty，sudo 才能问密码；没终端（比如在 CI 里）就只能用免密 sudo 或 root。
if [ -t 0 ]; then TTY=-t; else TTY=-T; fi
# shellcheck disable=SC2016 # 故意不展开：这段在远端执行
SUDO_SH='if [ "$(id -u)" -eq 0 ]; then S=; else S=sudo; fi;'
n=0
# 清单走 fd 3，标准输入留给 ssh 和 sudo 问密码。
while read -r name target role extra <&3 || [ -n "${name:-}" ]; do
  case ${name:-} in ''|\#*) continue ;; esac
  [ -z "${extra:-}" ] || die "hosts 文件里 $name 这一行多了列"
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
  case ${role:-} in prod|test) ;; *) die "$name 的角色要写 prod 或 test" ;; esac
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "profile 名 $name 只能用字母、数字、点、下划线和连字符"
  n=$((n + 1))

  sock="$SOCKDIR/$n.sock"
  # 一条主连接走到底：认证一次，后面的检查、修改、回滚都复用它。重载 sshd 不会断开它。
  if ! ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} -o ControlMaster=yes -o ControlPath="$sock" -o ControlPersist=900 -fN "$target"; then
    RESULTS+=("$name  连不上（用你自己的 ssh $target 试试）"); continue
  fi

  payload=$(build_remote "$role")
  # 远端用 POSIX sh 解开再交给 bash；非 root 时走 sudo。
  set +e
  ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} -o ControlPath="$sock" "$TTY" "$target" \
    "$SUDO_SH \$S bash -c \"\$(printf '%s' '$payload' | base64 -d)\"" 2>&1 | tr -d '\r' | tee "$LOG" >&2
  rc=${PIPESTATUS[0]}
  set -e

  fp=$(sed -n 's/^FINGERPRINT \(SHA256:[A-Za-z0-9+/]*\)$/\1/p' "$LOG" | tail -1)
  [ -z "$fp" ] || FINGERPRINTS+=("$name $fp")

  case $rc in
    0) if [ "$APPLY" = 1 ]; then RESULTS+=("$name  完成"); else RESULTS+=("$name  预览完成（只读取，没有修改）"); fi ;;
    10)
      # 用一条全新的连接（不复用主连接）证明你还能登录，再确认；否则马上回滚。
      if ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} -o ControlPath=none -o ControlMaster=no -o ConnectTimeout=20 "$target" true; then
        ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} -o ControlPath="$sock" "$target" 'rm -f /run/claudeops-bootstrap/confirm/pending' </dev/null
        RESULTS+=("$name  完成（sshd 已重载，新连接验证通过）")
      else
        echo "  新连接登录失败，正在通过原连接回滚 sshd ..." >&2
        if ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} -o ControlPath="$sock" "$TTY" "$target" "$SUDO_SH \$S sh /run/claudeops-bootstrap/rollback.sh"; then
          RESULTS+=("$name  已回滚：重载 sshd 后新连接登不上，配置已还原")
        else
          RESULTS+=("$name  回滚命令没跑成，远端会在 ${CONFIRM_TIMEOUT} 秒内自动还原；到点后再试登录，别关掉现在的终端")
        fi
      fi
      ;;
    *) RESULTS+=("$name  失败（见上面的错误行）") ;;
  esac
  ssh -o ControlPath="$sock" -O exit "$target" >/dev/null 2>&1 || true
done 3< "$HOSTS_FILE"

[ "$n" -gt 0 ] || die "hosts 文件里没有要处理的主机"

echo
echo "== 结果"
printf '  %s\n' "${RESULTS[@]}"

if [ ${#FINGERPRINTS[@]} -gt 0 ] && [ "$MODE" != lock ]; then
  echo
  echo "== 主机指纹：复制到控制机 config.toml 里对应 profile 的 trustedHostKey"
  echo "   （通过你已经信任的那条登录连接从主机上读出来的）"
  for entry in "${FINGERPRINTS[@]}"; do
    printf '# %s\ntrustedHostKey = "%s"\n' "${entry%% *}" "${entry#* }"
  done
fi

ok=1
for r in "${RESULTS[@]}"; do
  case $r in *失败*|*回滚*|*连不上*) ok=0 ;; esac
done

if [ "$ok" = 1 ] && [ "$APPLY" = 1 ] && [ "$MODE" = apply ]; then
  cat <<EOF

== 下一步：在控制机上用运行 ssh-mcp 的账号逐台试一次（从你这台电脑是登不上的，这是对的）
   sudo -u sshmcp ssh -i /home/sshmcp/.ssh/claudeops_ed25519 $CLAUDEOPS_USER@<主机> true
EOF
fi

[ "$ok" = 1 ] || exit 1

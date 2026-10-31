#!/usr/bin/env bash
# bootstrap-hosts.sh — 在一批主机上建 ssh-mcp 专用账号，装控制机公钥、sshd 和 sudoers 限制。
#
# 在你自己的电脑上跑，用你现在就能登录这些主机的方式（你的 ~/.ssh/config、你的密钥、你的 sudo）。
# 默认只看不改（dry-run），打印每台机器会改什么；确认无误后加 --apply 才真正执行。
# apply 使用事务备份和定时回滚，不能代替服务商控制台或独立管理员救援入口。
#   - 只约束专用账号；不再接受全局 --harden。
#   - 写入前检查账号、权限组和 sudoers；已有密码或 sudo 授权需先人工审查。
#   - 账号、补充组、过期状态、公钥、sudoers、sshd 一起回滚；每事务独立锁和计时器。
#   - 重载后用全新管理员连接验证，再提交事务；未确认时定时回滚。
#   - 回滚仍可能因系统故障失败：保留救援通道并核查事务结果。
#
# 本机需要 bash 3.2 以上（macOS 自带的就行）和 OpenSSH；远端需要 Linux、bash、base64、sudo 或 root；apply 还需要 flock、systemd 和 visudo。
#
# 用法：
#   ./bootstrap-hosts.sh --hosts hosts.txt --pubkey claudeops_ed25519.pub --control-ip 203.0.113.10
#   ./bootstrap-hosts.sh ... --apply                 # 真正执行
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
  --extra-groups G,G    仅允许 systemd-journal（日志可能包含敏感信息，先核对需要）
  --only NAME           只处理清单里这一台
  --apply               真正执行；不加就是 dry-run
  --harden              已禁用：全局 SSH 加固须独立规划
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
[ "$HARDEN" = 0 ] || die "--harden 已停用；请独立规划全局 SSH 加固，保留管理员入口"
[ -z "$EXTRA_GROUPS" ] || [[ $EXTRA_GROUPS =~ ^[a-z_][a-z0-9_-]*(,[a-z_][a-z0-9_-]*)*$ ]] || die "--extra-groups 格式不对"

for g in ${EXTRA_GROUPS//,/ }; do
  [ "$g" = systemd-journal ] || die "--extra-groups 仅允许 systemd-journal，其他组须独立权限审查"
done

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
umask 077
ADMIN=${SUDO_USER:-root}
SSHD=$(command -v sshd || echo /usr/sbin/sshd)
KEYDIR=/etc/ssh/authorized_keys
DROPIN=/etc/ssh/sshd_config.d
SUDOERS=/etc/sudoers.d/$U
BASE=/run/claudeops-bootstrap
STATE=
ARMED=0
say() { printf '  %-6s %s\n' "$1" "$2"; }
die_remote() { say 错误 "$1"; exit 3; }
dec() { printf '%s' "$1" | base64 -d; }
same_content() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
check_groups() {
  local g
  for g in $1; do
    case $g in sudo|wheel|admin|root|docker|lxd|lxc|incus|libvirt|disk|shadow|kvm)
      die_remote "$U 属于高权限组 $g；没有写入授权，请先人工处理" ;;
    esac
  done
}
reload_sshd() {
  local unit
  for unit in ssh sshd; do
    if systemctl is-active --quiet "$unit"; then systemctl reload "$unit"; return; fi
  done
  die_remote "未找到活动的 ssh/sshd systemd 服务"
}
put_file() {
  local path=$1 content=$2 mode=$3 tmp
  tmp=$(mktemp "$(dirname "$path")/.$(basename "$path").XXXXXX")
  printf '%s\n' "$content" > "$tmp"
  chown root:root "$tmp"; chmod "$mode" "$tmp"; mv -f "$tmp" "$path"
}
printf '%s\n' "--- $(hostname)（以 $ADMIN 的身份登录，角色 $ROLE）"
[ "$ADMIN" != "$U" ] || die_remote "不能修改当前用于救援登录的账号"
[ "$HARDEN" = 0 ] || die_remote "此脚本不再做全局 --harden；请独立规划管理员入口加固"
for g in ${EXTRA_GROUPS//,/ }; do
  [ "$g" = systemd-journal ] || die_remote "额外组只允许 systemd-journal；其他组需独立权限审查"
  getent group "$g" >/dev/null || die_remote "额外组 $g 不存在"
done

# Dry-run does not create locks, accounts, files, or timers on the target.
EXISTED=0
PRE_UID=
if id "$U" >/dev/null 2>&1; then
  EXISTED=1
  PRE_UID=$(id -u "$U")
  [ "$PRE_UID" != 0 ] && [ "$PRE_UID" != "$(id -u "$ADMIN")" ] || die_remote "专用账号不能使用 root 或管理员 UID"
  if [ "$MODE" != lock ]; then check_groups "$(id -nG "$U")"; fi
fi
if [ "$MODE" = lock ] && [ "$APPLY" = 0 ]; then
  say 将要 "使 $U 过期、移走专用公钥并停止该 UID 进程；不会终止已提权的 root/systemd 任务"
  exit 0
fi
if [ "$MODE" != lock ]; then
  [ -x "$SSHD" ] || die_remote "找不到 sshd"
  grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
    || die_remote "主配置缺少 sshd_config.d Include"
  "$SSHD" -t || die_remote "当前 sshd 配置已无效，先人工修复"
  command -v visudo >/dev/null || die_remote "需要 visudo 验证 sudo 权限边界"
  visudo -c >/dev/null || die_remote "当前 sudoers 已无效，先人工修复"
  if [ "$EXISTED" = 1 ]; then
    [ "$(getent shadow "$U" | cut -d: -f2)" = '*' ] \
      || die_remote "已有账号不是无密码专用账号（密码字段须为 *）；不会自动覆盖其密码"
    expiry=$(getent shadow "$U" | cut -d: -f8)
    if [ -n "$expiry" ] && [ "$expiry" -le "$(( $(date +%s) / 86400 ))" ] && [ "$UNLOCK" != 1 ]; then
      die_remote "账号已过期；确认恢复后使用 --unlock"
    fi
    # Existing sudo grants (including a previous test installation) require an
    # independent privilege review before replacing account authorization.
    if LC_ALL=C sudo -n -l -U "$U" >/dev/null 2>&1; then
      die_remote "已有账号具备 sudo 权限；请先独立撤销并核验，不会继续装钥匙"
    fi
  else
    [ ! -e "/home/$U" ] && [ ! -L "/home/$U" ] || die_remote "新账号的 home 已存在，拒绝接管"
    ! getent group "$U" >/dev/null || die_remote "同名组已存在，拒绝隐式复用"
  fi
  for p in "$KEYDIR" "$DROPIN" /etc/sudoers.d; do
    [ ! -L "$p" ] || die_remote "配置目录不可为符号链接：$p"
    if [ -e "$p" ]; then
      [ -d "$p" ] || die_remote "配置路径不是目录：$p"
      [ "$(stat -c %u "$p")" = 0 ] || die_remote "配置目录必须由 root 拥有：$p"
      mode=$(stat -c %a "$p")
      [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die_remote "无法核验配置目录权限：$p"
      (( (8#$mode & 0022) == 0 )) || die_remote "配置目录不能允许组或其他用户写入：$p"
    fi
  done
  for p in "$KEYDIR/$U" "$SUDOERS" "$DROPIN/10-claudeops.conf"; do
    [ ! -L "$p" ] || die_remote "配置文件不可为符号链接：$p"
    [ ! -e "$p" ] || [ -f "$p" ] || die_remote "配置路径不是普通文件：$p"
  done
  KEYS=$(dec "$KEYS_B64"); WANT_SSH=$(dec "$SSHD_B64"); WANT_SUDO=$(dec "$SUDO_B64")
  if [ "$ROLE" = test ]; then
    # stdin validation makes even a preview free of target-file writes.
    printf '%s\n' "$WANT_SUDO" | visudo -cf /dev/stdin >/dev/null \
      || die_remote "sudoers 模板校验失败"
  fi
fi
if [ "$APPLY" = 0 ]; then
  say 将要 "创建/核验专用账号、授权公钥、限定 sshd 和角色 sudoers；任一步失败回滚本事务"
  say 提示 "回滚会终止专用账号已有会话及 UID 进程，不是无中断操作"
  say 提示 "apply 需要 flock、systemd-run、活动 systemd ssh 服务和独立管理员登录"
  exit 0
fi
command -v flock >/dev/null || die_remote "apply 需要 flock"
command -v systemd-run >/dev/null && [ -d /run/systemd/system ] \
  || die_remote "apply 需要 systemd 定时回滚支持；未做更改"
[ ! -L "$BASE" ] || die_remote "事务目录不能为符号链接"
if [ -d "$BASE" ]; then
  [ "$(stat -c %u "$BASE")" = 0 ] || die_remote "事务目录必须由 root 拥有"
fi
[ ! -L "$BASE/lock" ] || die_remote "锁文件不能为符号链接"
install -d -o root -g root -m 0700 "$BASE"
exec 9>"$BASE/lock"
flock -n 9 || die_remote "另一引导/回滚操作正在执行"
if [ -f "$BASE/active" ]; then
  prior=$(cat "$BASE/active")
  [ ! -f "$BASE/$prior/pending" ] || die_remote "上一事务尚未确认或回滚，拒绝覆盖它"
fi
# A different transaction may have completed after our read-only preflight.
# Never act on stale account existence: rollback must not delete its account.
NOW_UID=
if id "$U" >/dev/null 2>&1; then NOW_UID=$(id -u "$U"); fi
[ "$NOW_UID" = "$PRE_UID" ] || die_remote "等待锁期间账号存在性或 UID 已变化；未修改授权，请重新预检"
if [ "$MODE" = lock ]; then
  [ "$EXISTED" = 1 ] || { say 跳过 "账号不存在"; exit 0; }
  usermod --expiredate 1 "$U"
  if [ -f "$KEYDIR/$U" ]; then mv "$KEYDIR/$U" "$KEYDIR/$U.disabled-$(date +%s)-$$"; fi
  pkill -KILL -u "$U" 2>/dev/null || true
  say 完成 "已封禁专用账号；已提权任务需另行核查"
  exit 0
fi
# Repeat account checks under the lock before taking a snapshot. Unrelated
# manual administrator edits must not race this transaction.
if [ "$EXISTED" = 1 ]; then
  check_groups "$(id -nG "$U")"
  [ "$(getent shadow "$U" | cut -d: -f2)" = '*' ] || die_remote "等待锁期间专用账号密码状态变化"
  expiry=$(getent shadow "$U" | cut -d: -f8)
  if [ -n "$expiry" ] && [ "$expiry" -le "$(( $(date +%s) / 86400 ))" ] && [ "$UNLOCK" != 1 ]; then
    die_remote "账号已过期；确认恢复后使用 --unlock"
  fi
  if LC_ALL=C sudo -n -l -U "$U" >/dev/null 2>&1; then die_remote "专用账号已有 sudo 授权；未修改授权"; fi
else
  [ ! -e "/home/$U" ] && [ ! -L "/home/$U" ] || die_remote "等待锁期间 home 出现；拒绝接管"
  ! getent group "$U" >/dev/null || die_remote "等待锁期间同名组出现；拒绝复用"
fi
STATE=$(mktemp -d "$BASE/txn.XXXXXXXX")
TXN=${STATE##*/}
UNIT=claudeops-rollback-${TXN#txn.}
mkdir "$STATE/backup"
printf '%s\n' "$TXN" > "$BASE/active"
printf '%s\n' "$UNIT" > "$STATE/unit"
if [ "$EXISTED" = 1 ]; then
  id -G "$U" > "$STATE/groups"
  getent shadow "$U" | cut -d: -f8 > "$STATE/expiry"
fi
# Generate a root-only transaction controller. Both commit and rollback use
# the global lock, so a delayed timer can never undo a committed/new batch.
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\numask 077\n'
  printf 'STATE=%q\nBASE=%q\nU=%q\nUNIT=%q\nEXISTED=%q\n' "$STATE" "$BASE" "$U" "$UNIT" "$EXISTED"
  printf 'ADMIN=%q\nPRE_UID=%q\n' "$ADMIN" "$PRE_UID"
  cat <<'CONTROL'
if [ "${2:-}" != locked ]; then exec 9>"$BASE/lock"; flock -x 9; fi
[ -f "$STATE/pending" ] || { [ -f "$STATE/committed" ] && [ "${1:-}" = commit ]; exit $?; }
if [ "${1:-}" = commit ]; then
  mv "$STATE/pending" "$STATE/committed"
  systemctl stop "$UNIT.timer" >/dev/null 2>&1 || true
  exit 0
fi
[ "${1:-}" = rollback ] || exit 2
# First disable this account while restoring files and its original state.
if id "$U" >/dev/null 2>&1; then
  uid=$(id -u "$U")
  [ "$uid" != 0 ] && [ "$uid" != "$(id -u "$ADMIN")" ] || exit 3
  [ -z "$PRE_UID" ] || [ "$uid" = "$PRE_UID" ] || exit 3
  usermod --expiredate 1 "$U"
  # Expiry does not terminate established sessions. Kill this dedicated UID
  # before restoring authorization; root/systemd jobs need separate cleanup.
  pkill -KILL -u "$uid" 2>/dev/null || true
fi
CONTROL
  # Restore exactly the managed files, not all of /etc or shared account DBs.
  for f in "$KEYDIR/$U" "$SUDOERS" "$DROPIN/10-claudeops.conf"; do
    key=$(printf '%s' "$f" | tr / _)
    if [ -f "$f" ]; then
      cp -p "$f" "$STATE/backup/$key"
      printf 'cp -p -- %q %q\n' "$STATE/backup/$key" "$f"
    else
      printf 'rm -f -- %q\n' "$f"
    fi
  done
  for d in "$KEYDIR" "$DROPIN" /etc/sudoers.d; do
    if [ ! -d "$d" ]; then printf 'rmdir -- %q 2>/dev/null || true\n' "$d"; fi
  done
  cat <<'CONTROL'
if [ "$EXISTED" = 1 ]; then
  # The primary group was never modified; restore supplementary groups only.
  primary=$(id -g "$U")
  groups=$(tr ' ' '\n' < "$STATE/groups" | grep -vx "$primary" | paste -sd, - || true)
  usermod -G "$groups" "$U"
  expiry=$(cat "$STATE/expiry")
  usermod --expiredate "$expiry" "$U"
else
  if id "$U" >/dev/null 2>&1; then
    userdel -r "$U"
  fi
  # userdel may already remove the private group.
  if getent group "$U" >/dev/null; then groupdel "$U"; fi
fi
for unit in ssh sshd; do
  if systemctl is-active --quiet "$unit"; then systemctl reload "$unit"; break; fi
done
mv "$STATE/pending" "$STATE/rolled-back"
systemctl stop "$UNIT.timer" >/dev/null 2>&1 || true
logger -t claudeops-bootstrap "rolled back transaction ${STATE##*/}" 2>/dev/null || true
CONTROL
} > "$STATE/control.sh"
chmod 0700 "$STATE/control.sh"
touch "$STATE/pending"
# Arm recovery BEFORE the first account/key/sudoers/sshd mutation.
if ! systemd-run --quiet --collect --unit "$UNIT" --on-active="$TIMEOUT" \
  /bin/bash "$STATE/control.sh" rollback; then
  rm -f "$STATE/pending"; die_remote "无法启动回滚定时器；没有修改账号或授权"
fi
ARMED=1
on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$ARMED" = 1 ] && [ "$rc" != 10 ]; then
    if ! bash "$STATE/control.sh" rollback locked; then
      say 错误 "自动回滚失败；已保留事务和定时器，请立即人工核查 $STATE"
    fi
  fi
  exit "$rc"
}
trap on_exit EXIT
if [ "$EXISTED" = 0 ]; then useradd -m -U -s /bin/bash -p '*' -c 'ssh-mcp (Claude)' "$U"; fi
if [ "$UNLOCK" = 1 ]; then usermod --expiredate '' "$U"; fi
[ -z "$EXTRA_GROUPS" ] || usermod -aG "$EXTRA_GROUPS" "$U"
check_groups "$(id -nG "$U")"
for d in "$KEYDIR" "$DROPIN" /etc/sudoers.d; do
  [ -d "$d" ] || install -d -o root -g root -m 0755 "$d"
done
put_file "$KEYDIR/$U" "$KEYS" 0644
if [ "$ROLE" = test ]; then put_file "$SUDOERS" "$WANT_SUDO" 0440; else rm -f "$SUDOERS"; fi
visudo -c >/dev/null
put_file "$DROPIN/10-claudeops.conf" "$WANT_SSH" 0644
"$SSHD" -t
# Validate the effective keys path and authentication constraints, not just syntax.
eff=$("$SSHD" -T -C "user=$U,host=probe,addr=$CONTROL_PROBE,laddr=127.0.0.1,lport=22")
printf '%s\n' "$eff" | grep -qx 'authorizedkeysfile /etc/ssh/authorized_keys/%u'
printf '%s\n' "$eff" | grep -qx 'authenticationmethods publickey'
printf '%s\n' "$eff" | grep -qx 'passwordauthentication no'
eff_deny=$("$SSHD" -T -C "user=$U,host=probe,addr=192.0.2.254,laddr=127.0.0.1,lport=22")
printf '%s\n' "$eff_deny" | grep -qx 'pubkeyauthentication no'
reload_sshd
if [ -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
  printf 'FINGERPRINT %s\n' "$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
fi
printf 'TRANSACTION %s\n' "$TXN"
say 等待 "独立管理员新连接确认；否则定时回滚本事务的账号和授权变更"
exit 10
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
  case $target in -*|'') die "SSH 目标不能为空或以 - 开头" ;; esac
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
      txn=$(sed -n 's/^TRANSACTION \(txn\.[A-Za-z0-9]*\)$/\1/p' "$LOG" | tail -1)
      if [ -z "$txn" ]; then RESULTS+=("$name  失败：缺少事务标识，等待远端定时回滚"); continue; fi
      controller="/run/claudeops-bootstrap/$txn/control.sh"
      # 用一条全新的连接（不复用主连接）证明你还能登录，再确认；否则马上回滚。
      if ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} -o ControlPath=none -o ControlMaster=no -o ConnectTimeout=20 "$target" true; then
        if ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} -o ControlPath="$sock" "$TTY" "$target" "$SUDO_SH \$S bash '$controller' commit"; then
          RESULTS+=("$name  完成（独立管理员连接通过，事务已确认）")
        else
          RESULTS+=("$name  失败：确认未成功，保留定时回滚；请核查事务状态")
        fi
      else
        echo "  新连接登录失败，正在通过原连接回滚本事务 ..." >&2
        if ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} -o ControlPath="$sock" "$TTY" "$target" "$SUDO_SH \$S bash '$controller' rollback"; then
          RESULTS+=("$name  已回滚：重载 sshd 后新连接登不上，配置已还原")
        else
          RESULTS+=("$name  回滚命令没跑成，远端已安排定时回滚；须通过控制台核查结果，别关掉现在的终端")
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

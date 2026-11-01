#!/usr/bin/env bash
# SSH login notifications via Linux-PAM and Telegram. See README.md.
# Do not use errexit: every PAM/file mutation has an explicit error path.

INSTALL_DIR=/etc/ssh-tg-notify
CONFIG_FILE=$INSTALL_DIR/config
NOTIFIER=$INSTALL_DIR/notify.sh
PAM_FILE=/etc/pam.d/sshd
LOCK_FILE=/run/ssh-tg-notify.lock
BEGIN_MARKER='# BEGIN ssh-tg-notify'
END_MARKER='# END ssh-tg-notify'
PAM_ENTRY="session optional pam_exec.so quiet type=open_session $NOTIFIER"
CURL_BIN=
GUARD=$INSTALL_DIR/guard.py
UNIT_NAME=ssh-tg-notify-bruteforce.service
UNIT_FILE=/etc/systemd/system/$UNIT_NAME
STATE_DIR=/var/lib/ssh-tg-notify
UNIT_MARKER='# Managed by ssh-tg-notify/v1'
PYTHON_BIN=
SSHD_CONFIG=/etc/ssh/sshd_config

error() { printf '错误：%s\n' "$*" >&2; }

valid_config() {
    [[ -n $SERVER_NAME && ${#SERVER_NAME} -le 128 &&
       $SERVER_NAME =~ [^[:space:]] && ! $SERVER_NAME =~ [[:cntrl:]] &&
       $TG_BOT_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ &&
       $TG_CHAT_ID =~ ^-?[0-9]+$ ]]
}

# Configuration is data, not shell code. Never source/eval user input.
load_config() {
    local line server_count=0 token_count=0 chat_count=0
    SERVER_NAME= TG_BOT_TOKEN= TG_CHAT_ID=
    [[ -f $CONFIG_FILE && ! -L $CONFIG_FILE && -O $CONFIG_FILE ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            SERVER_NAME=*) SERVER_NAME=${line#*=}; ((server_count+=1)) ;;
            TG_BOT_TOKEN=*) TG_BOT_TOKEN=${line#*=}; ((token_count+=1)) ;;
            TG_CHAT_ID=*) TG_CHAT_ID=${line#*=}; ((chat_count+=1)) ;;
            *) return 1 ;;
        esac
    done < "$CONFIG_FILE"
    [[ $server_count -eq 1 && $token_count -eq 1 && $chat_count -eq 1 ]] && valid_config
}

send_telegram() {
    local message=$1 response
    # Supply the token through stdin, so it is absent from curl's command line.
    # Disable curlrc and do not follow redirects with the bot credential.
    response=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_BOT_TOKEN" |
        env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$CURL_BIN" -q --config - --silent --fail --proto '=https' \
            --connect-timeout 3 --max-time 8 \
            --data-urlencode "chat_id=$TG_CHAT_ID" \
            --data-urlencode "text=$message" 2>/dev/null) || return 1
    [[ $response =~ ^[[:space:]]*\{[[:space:]]*\"ok\"[[:space:]]*:[[:space:]]*true[[:space:]]*[,}] ]]
}

write_notifier() {
    printf '#!/bin/bash -p\n'
    printf 'PATH=/usr/sbin:/usr/bin:/sbin:/bin\nexport PATH\n'
    printf 'CONFIG_FILE=%q\nCURL_BIN=%q\n' "$CONFIG_FILE" "$CURL_BIN"
    declare -f valid_config load_config send_telegram
    cat <<'NOTIFIER_EOF'

log_failure() {
    # Never write the bot token or Telegram response to the system log.
    logger -t ssh-tg-notify -- 'Telegram notification failed; check configuration and network.' 2>/dev/null || :
}

case ${1:-} in
    --test)
        load_config || { echo '通知配置损坏或无法读取。' >&2; exit 1; }
        message=$(printf '✅ SSH 通知测试\n• 服务器: %s\n• 时间: %s' "$SERVER_NAME" "$(date '+%Y-%m-%d %H:%M:%S %z')")
        send_telegram "$message" || { echo '测试失败，请检查 Token、Chat ID、机器人权限和网络。' >&2; exit 1; }
        echo '测试消息已发送。'
        exit 0
        ;;
    --send)
        load_config || { log_failure; exit 0; }
        message=$(printf '⚠️ SSH 登录成功提醒\n• 服务器: %s\n• 用户: %s\n• 来源 IP: %s\n• 时间: %s' \
            "$SERVER_NAME" "${2:-未知}" "${3:-Local / Intranet}" "${4:-未知}")
        send_telegram "$message" || log_failure
        exit 0
        ;;
esac

[[ ${PAM_TYPE:-} == open_session && ${PAM_SERVICE:-} == sshd ]] || exit 0
# Disconnect all standard descriptors and ignore SIGHUP. PAM returns without
# waiting for Telegram; a failed notification never rejects an SSH session.
nohup /bin/bash -p "${BASH_SOURCE[0]}" --send "${PAM_USER:-未知}" \
    "${PAM_RHOST:-Local / Intranet}" "$(date '+%Y-%m-%d %H:%M:%S %z')" \
    </dev/null >/dev/null 2>&1 &
exit 0
NOTIFIER_EOF
}

owned_install() {
    [[ -d $INSTALL_DIR && ! -L $INSTALL_DIR && -O $INSTALL_DIR &&
       -f $INSTALL_DIR/managed && ! -L $INSTALL_DIR/managed &&
       $(cat "$INSTALL_DIR/managed") == ssh-tg-notify/v1 ]]
}

write_guard() {
    cat <<'GUARD_EOF'
#!/usr/bin/env python3
"""SSH authentication log reader and persistent brute-force monitor (stdlib only)."""
import argparse
import collections
import datetime as dt
import gzip
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

AUTH = re.compile(r"^(Failed|Accepted) \S+ for (?:invalid user )?(.*?) from (\S+) port (\d+) ssh2(?:\b|:)")
PREFIX = re.compile(r"\bsshd(?:-session|-auth)?\[\d+\]:\s*(.*)$")
IDENTIFIERS = ("sshd", "sshd-session", "sshd-auth")
MONTHS = {name: n for n, name in enumerate("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)}


def parse_auth(message):
    if not isinstance(message, str):
        return None
    match = AUTH.match(message)
    if not match:
        return None
    try:
        address = ipaddress.ip_address(match[3].strip("[]"))
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
    except ValueError:
        return None
    return {"failed": match[1] == "Failed", "user": match[2], "ip": str(address)}


def journal_command():
    command = ["journalctl", "--no-pager", "--output=json"]
    for identifier in IDENTIFIERS:
        command.extend(["--identifier", identifier])
    return command


def decode_record(line):
    try:
        record = json.loads(line)
        stamp = int(record["__REALTIME_TIMESTAMP"]) / 1_000_000
        if not isinstance(record.get("MESSAGE"), str):
            return None
        return stamp, record
    except (ValueError, TypeError, KeyError):
        return None


def journal_counts(since, until):
    """Return (counts, available SSH records); never combine with syslog copies."""
    counts, records = collections.Counter(), 0
    if not shutil.which("journalctl"):
        return counts, 0
    command = journal_command() + [f"--since=@{since:.6f}", f"--until=@{until:.6f}"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True, encoding="utf-8", errors="replace")
    try:
        for line in process.stdout:
            decoded = decode_record(line)
            if not decoded or not since <= decoded[0] <= until:
                continue
            records += 1
            event = parse_auth(decoded[1]["MESSAGE"])
            if event and event["failed"]:
                counts[event["ip"]] += 1
    finally:
        process.stdout.close()
        result = process.wait()
    if result:
        raise RuntimeError("无法完整读取 systemd 日志，请先检查 journalctl 权限和服务状态。")
    return counts, records


def syslog_time(line, now):
    first = line.split(" ", 1)[0]
    try:
        return dt.datetime.fromisoformat(first.replace("Z", "+00:00")).timestamp()
    except ValueError:
        pass
    match = re.match(r"^([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s", line)
    if not match or match[1] not in MONTHS:
        return None
    # Classic syslog has no year. Choose the nearest local date, including
    # Dec/Jan rotation and DST, instead of treating every line as this year.
    candidates = []
    for year in range(time.localtime(now).tm_year - 1, time.localtime(now).tm_year + 2):
        try:
            value = dt.datetime(year, MONTHS[match[1]], *map(int, match.groups()[1:]))
            candidates.append(time.mktime(value.timetuple()))
        except (ValueError, OverflowError):
            continue
    return min(candidates, key=lambda value: abs(now - value)) if candidates else None


def file_counts(since, until, directory=Path("/var/log")):
    counts = collections.Counter()
    for name in ("auth.log", "secure"):
        paths = [path for path in directory.glob(name + "*")
                 if re.fullmatch(re.escape(name) + r"(?:(?:\.\d+|-\d{8})(?:\.gz)?)?", path.name)
                 and path.is_file() and not path.is_symlink()]
        if not paths:
            continue
        seen = set()
        for path in paths:
            identity = (path.stat().st_dev, path.stat().st_ino)
            if identity in seen:
                continue
            seen.add(identity)
            opener = gzip.open if path.suffix == ".gz" else open
            with opener(path, "rt", encoding="utf-8", errors="replace") as stream:
                for line in stream:
                    prefix = PREFIX.search(line)
                    if not prefix:
                        continue
                    stamp = syslog_time(line, until)
                    if stamp is None or not since <= stamp <= until:
                        continue
                    event = parse_auth(prefix[1])
                    if event and event["failed"]:
                        counts[event["ip"]] += 1
        return counts, True
    return counts, False


def ranking(now=None):
    until = time.time() if now is None else now
    counts, records = journal_counts(until - 86400, until)
    if not records:
        counts, available = file_counts(until - 86400, until)
        if not available and not shutil.which("journalctl"):
            raise RuntimeError("未找到 journalctl 或可读取的 auth.log / secure 日志。")
    return sorted(counts.items(), key=lambda item: (-item[1], item[0]))[:10]


def read_config(path):
    mode = path.lstat()
    if not stat.S_ISREG(mode.st_mode):
        raise ValueError("通知配置必须是普通文件。")
    if os.name == "posix" and mode.st_uid != os.geteuid():
        raise ValueError("通知配置属主不正确。")
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if not separator or key not in ("SERVER_NAME", "TG_BOT_TOKEN", "TG_CHAT_ID") or key in values:
            raise ValueError("通知配置损坏。")
        values[key] = value
    server = values.get("SERVER_NAME", "")
    if (not server.strip() or len(server) > 128 or any(ord(c) < 32 or ord(c) == 127 for c in server)
            or not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", values.get("TG_BOT_TOKEN", ""))
            or not re.fullmatch(r"-?[0-9]+", values.get("TG_CHAT_ID", ""))):
        raise ValueError("通知配置损坏。")
    return values


def send_telegram(config, message):
    data = urllib.parse.urlencode({"chat_id": config["TG_CHAT_ID"], "text": message}).encode()
    request = urllib.request.Request(
        "https://api.telegram.org/bot" + config["TG_BOT_TOKEN"] + "/sendMessage", data=data)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=8) as response:
            return json.load(response).get("ok") is True
    except Exception:
        # urllib errors can contain the credential-bearing URL. Never log them.
        return False


def output_of(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=False)
        return result.stdout if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def ssh_ports():
    ports = set()
    for line in output_of(["ss", "-H", "-ltnp"]).splitlines():
        fields = line.split()
        if len(fields) >= 5 and re.search(r'"sshd(?:-session|-auth)?"', line):
            port = fields[3].rsplit(":", 1)[-1]
            if port.isdigit():
                ports.add(int(port))
    # Socket activation may leave the listener owned by systemd.
    if not ports:
        sockets = "\n\n".join(output_of(["systemctl", "show", unit, "--property=Listen", "--property=ActiveState"])
                              for unit in ("ssh.socket", "sshd.socket"))
        for block in sockets.split("\n\n"):
            if "ActiveState=active" in block.splitlines():
                ports.update(int(port) for port in re.findall(r"(?:^|:|=|\s)(\d+)\s+\(Stream\)", block))
    if not ports:
        settings = output_of(["sshd", "-T"])
        for address in re.findall(r"^listenaddress (\S+)$", settings, re.MULTILINE):
            port = address.rsplit(":", 1)[-1]
            if port.isdigit():
                ports.add(int(port))
        if not ports:
            ports.update(int(port) for port in re.findall(r"^port (\d+)$", settings, re.MULTILINE))
    return "、".join(str(port) for port in sorted(ports) if 0 < port < 65536) or "未知"


def alert_message(config, event, ports, testing=False):
    user = "".join(c if c.isprintable() else "?" for c in event["user"])[:128] or "未知"
    stamp = dt.datetime.fromtimestamp(event["time"]).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    title = "🚨 SSH 爆破提醒（测试）" if testing else "🚨 SSH 爆破提醒"
    return (f'{title}\n• 服务器: {config["SERVER_NAME"]}\n• 用户: {user}\n'
            f'• 来源 IP: {event["ip"]}\n• 失败次数：{event["count"]}\n• 端口：{ports}\n• 时间: {stamp}')


class Store:
    def __init__(self, path):
        self.connection = sqlite3.connect(str(path), timeout=10)
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.executescript("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS streaks (ip TEXT PRIMARY KEY, count INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS outbox (
                id INTEGER PRIMARY KEY, payload TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0, due REAL NOT NULL DEFAULT 0);
        """)
        with self.connection:
            self.connection.execute("INSERT OR IGNORE INTO meta VALUES ('start', ?)", (str(time.time()),))

    def meta(self, key):
        row = self.connection.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def reset_streaks(self):
        with self.connection:
            self.connection.execute("DELETE FROM streaks")
            self.connection.execute("DELETE FROM meta WHERE key='cursor'")
            self.connection.execute("INSERT OR REPLACE INTO meta VALUES ('start', ?)", (str(time.time()),))

    def consume(self, record):
        cursor = record.get("__CURSOR")
        if not isinstance(cursor, str) or not cursor or cursor == self.meta("cursor"):
            return
        event = parse_auth(record.get("MESSAGE"))
        with self.connection:
            if event:
                if not event["failed"]:
                    self.connection.execute("DELETE FROM streaks WHERE ip=?", (event["ip"],))
                else:
                    row = self.connection.execute("SELECT count FROM streaks WHERE ip=?", (event["ip"],)).fetchone()
                    event["count"] = (row[0] if row else 0) + 1
                    self.connection.execute("INSERT OR REPLACE INTO streaks VALUES (?, ?)", (event["ip"], event["count"]))
                    if event["count"] == 11:
                        event["time"] = int(record["__REALTIME_TIMESTAMP"]) / 1_000_000
                        self.connection.execute("INSERT INTO outbox(payload) VALUES (?)", (json.dumps(event),))
            self.connection.execute("INSERT OR REPLACE INTO meta VALUES ('cursor', ?)", (cursor,))

    def deliver_one(self, config, sender=send_telegram, ports=ssh_ports, now=None):
        now = time.time() if now is None else now
        row = self.connection.execute("SELECT id, payload, attempts FROM outbox WHERE due<=? ORDER BY id LIMIT 1", (now,)).fetchone()
        if not row:
            return None
        sent = sender(config, alert_message(config, json.loads(row[1]), ports()))
        with self.connection:
            if sent:
                self.connection.execute("DELETE FROM outbox WHERE id=?", (row[0],))
            else:
                delay = min(300, 5 * 2 ** min(row[2], 6))
                self.connection.execute("UPDATE outbox SET attempts=attempts+1, due=? WHERE id=?", (now + delay, row[0]))
        return sent

    def close(self):
        self.connection.close()


def cursor_exists(cursor):
    output = output_of(journal_command() + ["--cursor=" + cursor, "--lines=1"])
    for line in output.splitlines():
        decoded = decode_record(line)
        if decoded and decoded[1].get("__CURSOR") == cursor:
            return True
    return False


def watch(config_path, state_dir):
    import fcntl
    read_config(config_path)
    # Manager creates and owns this directory; reject unexpected replacements.
    if state_dir.is_symlink() or not state_dir.is_dir():
        raise ValueError("爆破状态目录不存在或不安全。")
    database = state_dir / "state.sqlite3"
    if database.is_symlink():
        raise ValueError("爆破状态文件不应为符号链接。")
    with open(state_dir / "watch.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        store = Store(database)
        cursor = store.meta("cursor")
        if cursor and not cursor_exists(cursor):
            print("SSH journal cursor expired; resetting consecutive failure counts.", flush=True)
            store.reset_streaks()
            cursor = None
        command = journal_command() + ["--follow", "--lines=all"]
        command += ["--after-cursor=" + cursor] if cursor else ["--since=@" + store.meta("start")]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, encoding="utf-8", errors="replace")
        stop = threading.Event()
        sender_failed = threading.Event()

        def shutdown(_number, _frame):
            stop.set()
            if process.poll() is None:
                process.terminate()

        def deliver():
            sender_store = Store(database)
            try:
                while not stop.is_set():
                    result = sender_store.deliver_one(read_config(config_path))
                    if result is False:
                        print("Telegram brute-force notification failed; queued for retry.", flush=True)
                    if result is None or result is False:
                        stop.wait(1)
            except Exception:
                print("Brute-force sender failed; restarting monitor.", flush=True)
                sender_failed.set()
                shutdown(None, None)
            finally:
                sender_store.close()

        signal.signal(signal.SIGTERM, shutdown)
        signal.signal(signal.SIGINT, shutdown)
        thread = threading.Thread(target=deliver, daemon=True)
        thread.start()
        try:
            for line in process.stdout:
                decoded = decode_record(line)
                if decoded:
                    store.consume(decoded[1])
            if sender_failed.is_set() or not stop.is_set():
                raise RuntimeError("journalctl 监控意外退出。")
        finally:
            stop.set()
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
            process.stdout.close()
            thread.join(timeout=10)
            store.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("rank", "test", "watch"))
    parser.add_argument("--config", type=Path, default=Path("/etc/ssh-tg-notify/config"))
    parser.add_argument("--state-dir", type=Path, default=Path("/var/lib/ssh-tg-notify"))
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.action == "rank":
            rows = ranking()
            for address, count in rows:
                print(f"{count}次 {address}")
            if not rows:
                print("近 24 小时没有可统计的 SSH 登录失败记录。")
        elif args.action == "test":
            config = read_config(args.config)
            event = {"user": "root", "ip": "203.0.113.10", "count": 11, "time": time.time()}
            if not send_telegram(config, alert_message(config, event, ssh_ports(), testing=True)):
                raise RuntimeError("爆破测试通知发送失败，请检查配置和网络。")
            print("爆破测试通知已发送（模拟数据，不改变监控状态）。")
        else:
            watch(args.config, args.state_dir)
    except Exception as exc:
        # Only expose our own messages; network/OS exceptions might carry secrets.
        message = str(exc) if type(exc) in (ValueError, RuntimeError) else "日志读取或监控失败，请检查权限、依赖和日志服务。"
        print(message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
GUARD_EOF
}

# Return absent / installed / conflict. Unexpected edits or duplicate hooks
# must not be silently accepted or removed.
pam_state() {
    [[ -f $PAM_FILE && ! -L $PAM_FILE ]] || { echo conflict; return; }
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v hook="$NOTIFIER" -v entry="$PAM_ENTRY" '
        $0 == begin { starts++; if (inside || ends) bad=1; inside=1; next }
        $0 == end { ends++; if (!inside) bad=1; inside=0; next }
        {
            if ($0 !~ /^[[:space:]]*#/ && index($0, hook)) {
                refs++
                if (inside && $0 == entry) valid++; else bad=1
            } else if (inside && NF) bad=1
        }
        END {
            if (!starts && !ends && !refs) print "absent"
            else if (starts==1 && ends==1 && valid==1 && refs==1 && !inside && !bad) print "installed"
            else print "conflict"
        }
    ' "$PAM_FILE"
}

has_legacy_hook() {
    [[ -f $PAM_FILE ]] && awk '
        $0 !~ /^[[:space:]]*#/ && index($0, "/etc/pam.scripts/tg_ssh_alert.sh") { found=1 }
        END { exit !found }
    ' "$PAM_FILE"
}

check_pam_file() {
    [[ -f $PAM_FILE && ! -L $PAM_FILE && -O $PAM_FILE ]] || {
        error "$PAM_FILE 必须是 root 所有的普通文件（不支持符号链接）。"; return 1;
    }
}

check_ssh() {
    local sshd_bin settings module found=0
    check_pam_file || return 1
    sshd_bin=$(command -v sshd) || { error '未找到 sshd，请先安装 OpenSSH Server。'; return 1; }
    if ! settings=$(LC_ALL=C "$sshd_bin" -T 2>/dev/null); then
        error '无法读取有效的 SSH 配置，请先运行 sshd -t 排查。'; return 1
    fi
    if ! grep -Eq '^usepam[[:space:]]+yes$' <<< "$settings"; then
        error 'SSH 尚未启用 UsePAM。请先配置 UsePAM yes，执行 sshd -t 并重载 SSH 服务。'; return 1
    fi
    for module in /lib/security/pam_exec.so /lib64/security/pam_exec.so \
        /lib/*/security/pam_exec.so /usr/lib/security/pam_exec.so \
        /usr/lib64/security/pam_exec.so /usr/lib/*/security/pam_exec.so; do
        [[ -f $module ]] && found=1
    done
    [[ $found -eq 1 ]] || { error '未找到 pam_exec.so，请先安装系统的 PAM 模块包。'; return 1; }
    CURL_BIN=$(command -v curl) || { error '未安装 curl，请先安装（见 README）。'; return 1; }
    command -v nohup >/dev/null 2>&1 || { error '未找到 nohup，请先安装 GNU coreutils。'; return 1; }
}

read_field() {
    local variable=$1 prompt=$2 secret=${3:-0}
    printf '%s' "$prompt" >&2
    if [[ $secret == 1 && -t 3 ]]; then
        IFS= read -rs "$variable" <&3 || return 1
        printf '\n' >&2
    else
        IFS= read -r "$variable" <&3 || return 1
    fi
}

read_install_config() {
    local default_name
    default_name=$(hostname) || return 1
    read_field SERVER_NAME "服务器名称 [$default_name]: " || return 1
    SERVER_NAME=${SERVER_NAME:-$default_name}
    read_field TG_BOT_TOKEN 'TG_BOT_TOKEN（输入时隐藏）: ' 1 || return 1
    read_field TG_CHAT_ID 'TG_CHAT_ID（个人或群组的数字 ID）: ' || return 1
    valid_config || {
        error '名称须为 1–128 个字符且不能含控制字符；Token 须为 数字:密钥；Chat ID 须为整数（群组可为负数）。'
        return 1
    }
}

require_login_notification() {
    owned_install && load_config && [[ $(pam_state) == installed &&
        -f $NOTIFIER && ! -L $NOTIFIER && -x $NOTIFIER ]] || {
        error '请先选择“1. 添加 SSH 登录通知”，完整配置后才能使用爆破通知。'; return 1;
    }
}

require_python() {
    PYTHON_BIN=$(command -v python3) || { error '需要 Python 3，请先安装 python3。'; return 1; }
    "$PYTHON_BIN" -I -c 'import sqlite3, urllib.request, ipaddress; import sys; sys.exit(sys.version_info < (3, 8))' || {
        error '需要 Python 3.8 或更新版本及标准库 sqlite3。'; return 1;
    }
}

check_bruteforce_dependencies() {
    require_python || return 1
    command -v systemctl >/dev/null 2>&1 && command -v journalctl >/dev/null 2>&1 &&
        [[ -d /run/systemd/system ]] || {
        error '爆破通知需要运行中的 systemd 和 journald。'; return 1;
    }
    systemctl is-active --quiet systemd-journald.service || {
        error 'systemd-journald 未运行，无法监控 SSH 日志。'; return 1;
    }
    journalctl --no-pager --lines=0 >/dev/null 2>&1 || {
        error '无法读取 systemd 日志。'; return 1;
    }
}

owned_unit() {
    [[ -f $UNIT_FILE && ! -L $UNIT_FILE && -O $UNIT_FILE ]] && grep -Fxq "$UNIT_MARKER" "$UNIT_FILE"
}

check_monitor_paths() {
    if [[ -e $UNIT_FILE || -L $UNIT_FILE ]] && ! owned_unit; then
        error "$UNIT_FILE 不属于本脚本，拒绝覆盖或删除。"; return 1
    fi
    if [[ -e $STATE_DIR || -L $STATE_DIR ]]; then
        [[ -d $STATE_DIR && ! -L $STATE_DIR && -O $STATE_DIR &&
           -f $STATE_DIR/managed && ! -L $STATE_DIR/managed &&
           $(cat "$STATE_DIR/managed") == ssh-tg-notify-bruteforce/v1 ]] || {
            error "$STATE_DIR 不属于本脚本，拒绝覆盖或删除。"; return 1;
        }
    fi
}

write_guard_unit() {
    cat <<UNIT_EOF
$UNIT_MARKER
[Unit]
Description=SSH brute-force Telegram notifications
Wants=network-online.target
After=network-online.target systemd-journald.service

[Service]
Type=simple
ExecStart="$PYTHON_BIN" -I "$GUARD" watch --config "$CONFIG_FILE" --state-dir "$STATE_DIR"
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$STATE_DIR

[Install]
WantedBy=multi-user.target
UNIT_EOF
}

bruteforce_status() {
    if ! owned_unit; then
        echo '爆破通知: 未开启'
    elif ! command -v systemctl >/dev/null 2>&1; then
        echo '爆破通知: 无法读取服务状态'
    elif systemctl is-active --quiet "$UNIT_NAME"; then
        echo '爆破通知: 运行中'
    elif systemctl is-enabled --quiet "$UNIT_NAME"; then
        echo '爆破通知: 已设为开机启动，但当前未运行（请检查服务日志）'
    else
        echo '爆破通知: 已关闭'
    fi
}

enable_bruteforce() (
    local guard_temp= unit_temp=
    require_login_notification || return 1
    check_bruteforce_dependencies || return 1
    check_monitor_paths || return 1
    if owned_unit && [[ -f $GUARD && ! -L $GUARD ]] && systemctl is-active --quiet "$UNIT_NAME"; then
        systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || { error '设置开机启动失败。'; return 1; }
        echo '爆破通知已开启，跳过重复启用。'; return 0
    fi
    [[ ! -L $GUARD ]] || { error '监控程序不应为符号链接。'; return 1; }
    # Stop any previously installed instance before resetting its state.
    if owned_unit; then
        systemctl stop "$UNIT_NAME" || { error '停止旧监控失败，未修改配置。'; return 1; }
    fi
    umask 077
    if [[ ! -d $STATE_DIR ]]; then
        mkdir -m 700 -- "$STATE_DIR" && printf 'ssh-tg-notify-bruteforce/v1\n' > "$STATE_DIR/managed" || return 1
    fi
    chmod 700 "$STATE_DIR" || return 1
    # Turning monitoring off and on begins a fresh streak, not a replay of
    # attacks that happened while monitoring was disabled.
    rm -f -- "$STATE_DIR/state.sqlite3" "$STATE_DIR/state.sqlite3-wal" \
        "$STATE_DIR/state.sqlite3-shm" "$STATE_DIR/watch.lock" || return 1
    trap '[[ -z $guard_temp ]] || rm -f -- "$guard_temp"; [[ -z $unit_temp ]] || rm -f -- "$unit_temp"' EXIT
    guard_temp=$(mktemp "$INSTALL_DIR/.guard.XXXXXX") || return 1
    unit_temp=$(mktemp "${UNIT_FILE}.XXXXXX") || return 1
    if ! write_guard > "$guard_temp" || ! write_guard_unit > "$unit_temp" ||
       ! "$PYTHON_BIN" -I -c 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' "$guard_temp" ||
       ! chmod 600 "$guard_temp" || ! chmod 644 "$unit_temp" ||
       ! mv -fT -- "$guard_temp" "$GUARD" || ! mv -fT -- "$unit_temp" "$UNIT_FILE"; then
        error '准备爆破监控程序失败，未开启服务。'; return 1
    fi
    guard_temp= unit_temp=
    if ! systemctl daemon-reload || ! systemctl enable --now "$UNIT_NAME" ||
       ! systemctl is-active --quiet "$UNIT_NAME"; then
        systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || :
        error "爆破通知启动失败，已尝试停用。请查看 journalctl -u $UNIT_NAME。"
        return 1
    fi
    echo '爆破通知已开启，并设置为开机启动。'
    echo '同一 IP 连续失败第 11 次时提醒一次，成功认证后清零；本次开启从新日志开始统计。'
)

disable_bruteforce() {
    check_monitor_paths || return 1
    if ! owned_unit; then
        echo '爆破通知尚未开启或已经关闭。'; return 0
    fi
    command -v systemctl >/dev/null 2>&1 || { error '无法找到 systemctl，未修改监控文件。'; return 1; }
    systemctl disable --now "$UNIT_NAME" || { error '关闭爆破通知失败，未删除监控文件。'; return 1; }
    echo '爆破通知已关闭，SSH 登录成功通知继续保留。'
}

run_guard_action() (
    local action=$1 program=
    require_python || return 1
    trap '[[ -z $program ]] || rm -f -- "$program"' EXIT
    umask 077
    program=$(mktemp "${TMPDIR:-/tmp}/ssh-tg-guard.XXXXXX") || return 1
    write_guard > "$program" || return 1
    "$PYTHON_BIN" -I "$program" "$action" --config "$CONFIG_FILE"
)

test_bruteforce() {
    require_login_notification || return 1
    run_guard_action test
}

show_failed_ranking() { run_guard_action rank; }

write_port_tool() {
    cat <<'PORT_TOOL_EOF'
#!/usr/bin/env python3
"""Two-stage SSH port changes, with configuration backups and rollback."""
import argparse
import glob
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

BEGIN = "# BEGIN ssh-tg-notify ports"
END = "# END ssh-tg-notify ports"
SOCKET_MARKER = "# Managed by ssh-tg-notify SSH port changer"


def run(arguments):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("命令执行失败：" + arguments[0]) from exc
    if result.returncode:
        raise RuntimeError("命令失败：" + " ".join(arguments) + "\n" + result.stderr.strip())
    return result.stdout


def parse_ports(text):
    values = text.replace(",", " ").split()
    if not values or len(values) > 16 or any(not re.fullmatch(r"[0-9]{1,5}", value) for value in values):
        raise ValueError("请输入 1–16 个 TCP 端口，用空格或英文逗号分隔。")
    ports = sorted({int(value) for value in values})
    if any(not 1 <= value <= 65535 for value in ports):
        raise ValueError("端口必须在 1–65535 之间。")
    return ports


def directive(line):
    match = re.match(r"^\s*([A-Za-z][A-Za-z0-9]*)(?:\s*=\s*|\s+)(.*?)\s*$", line)
    if not match:
        return "", []
    return match[1].lower(), shlex.split(match[2], comments=True)


def strip_port_block(text):
    lines, result, inside, starts, ends = text.splitlines(keepends=True), [], False, 0, 0
    for line in lines:
        if line.strip() == BEGIN:
            starts += 1
            if inside or starts > 1 or ends:
                raise ValueError("SSH 端口管理标记损坏，请先检查配置。")
            inside = True
        elif line.strip() == END:
            ends += 1
            if not inside:
                raise ValueError("SSH 端口管理标记损坏，请先检查配置。")
            inside = False
        elif inside:
            keyword, _ = directive(line)
            if keyword != "port":
                raise ValueError("SSH 端口标记块内有其他配置，未修改。")
        else:
            result.append(line)
    if inside or starts != ends:
        raise ValueError("SSH 端口管理标记不完整，未修改。")
    return "".join(result)


def listen_host(value):
    if value.startswith("["):
        match = re.fullmatch(r"\[([^]]+)\](?::([0-9]+))?", value)
        if not match:
            raise ValueError("无法识别 ListenAddress：" + value)
        return match[1], int(match[2]) if match[2] else None
    if value.count(":") == 1:
        host, port = value.rsplit(":", 1)
        if port.isdigit():
            return host, int(port)
    return value, None


def endpoint(host, port):
    return f"[{host}]:{port}" if ":" in host else f"{host}:{port}"


def effective_ports(settings):
    ports, defaults = set(), set()
    for line in settings.splitlines():
        keyword, arguments = directive(line)
        if keyword == "port" and arguments:
            defaults.add(int(arguments[0]))
        if keyword == "listenaddress" and arguments:
            _, port = listen_host(arguments[0])
            if port:
                ports.add(port)
    return ports or defaults


class ConfigEditor:
    def __init__(self, main, settings):
        if main.is_symlink() or main.parent.is_symlink():
            raise ValueError("SSH 配置入口不应为符号链接。")
        self.main = main.resolve()
        self.root = self.main.parent.resolve()
        self.originals = {}
        self.defaults = [int(line.split()[1]) for line in settings.splitlines() if line.startswith("port ")]
        self.defaults = self.defaults or [22]
        self._visit(self.main, [False], set())

    def _visit(self, path, matching, ancestors):
        path = path.absolute()
        if path.is_symlink() or not path.is_file() or self.root not in path.resolve().parents:
            raise ValueError("只支持 /etc/ssh 内的普通配置文件，不支持外部 Include 或符号链接：" + str(path))
        path = path.resolve()
        if path in ancestors:
            raise ValueError("SSH Include 存在循环引用。")
        text = path.read_bytes().decode("utf-8", "surrogateescape")
        if path in self.originals:
            # Repeated includes can make Match scope ambiguous. Refuse instead
            # of guessing which occurrence supplies global settings.
            raise ValueError("SSH 配置重复 Include 同一文件，未修改：" + str(path))
        self.originals[path] = text
        for line in text.splitlines():
            keyword, arguments = directive(line)
            if keyword == "match":
                matching[0] = True
            elif keyword == "include" and not matching[0]:
                for pattern in arguments:
                    location = Path(pattern) if Path(pattern).is_absolute() else self.root / pattern
                    for included in sorted(glob.glob(str(location))):
                        self._visit(Path(included), matching, ancestors | {path})

    def plan(self, ports, staged, additions=None):
        outputs, emitted = {}, set()
        for path, original in self.originals.items():
            text = strip_port_block(original) if path == self.main else original
            result, matching = [], False
            for line in text.splitlines(keepends=True):
                keyword, arguments = directive(line)
                if keyword == "match":
                    matching = True
                if keyword == "port" and not matching:
                    result.append("# ssh-tg-notify previous: " + line.rstrip("\r\n") + "\n")
                elif keyword == "listenaddress" and not matching:
                    if not arguments or (len(arguments) != 1 and not (len(arguments) == 3 and arguments[1] == "rdomain")):
                        raise ValueError("无法安全处理 ListenAddress，未修改。")
                    host, old_port = listen_host(arguments[0])
                    suffix = " rdomain " + arguments[2] if len(arguments) == 3 else ""
                    wanted = (set(additions if additions is not None else ports) |
                              set([old_port] if old_port else self.defaults)) if staged else set(ports)
                    for port in sorted(wanted):
                        identity = (host, port, suffix)
                        if identity not in emitted:
                            result.append("ListenAddress " + endpoint(host, port) + suffix + "\n")
                            emitted.add(identity)
                else:
                    result.append(line)
            content = "".join(result)
            if path == self.main:
                block = BEGIN + "\n" + "".join(f"Port {port}\n" for port in sorted(ports)) + END + "\n"
                content = block + content
            outputs[path] = content.encode("utf-8", "surrogateescape")
        return outputs


def listeners():
    rows = []
    for line in run(["ss", "-H", "-ltnp"]).splitlines():
        fields = line.split()
        if len(fields) >= 5:
            host, port = listen_host(fields[3])
            if port:
                rows.append((host, port, bool(re.search(r'"sshd(?:-session|-auth)?"', line)), '"systemd"' in line))
    return rows


class SystemdBackend:
    def __init__(self, defaults_paths=(Path("/etc/default/ssh"), Path("/etc/sysconfig/sshd"))):
        self.socket = None
        self.socket_hosts = []
        self.socket_bindings = set()
        services, sockets = {}, {}
        for name in ("ssh.service", "sshd.service", "ssh.socket", "sshd.socket"):
            try:
                info = self.info(name)
            except RuntimeError:
                continue
            if info.get("ActiveState") == "active":
                (sockets if name.endswith(".socket") else services)[info.get("Id", name)] = info
        if len(sockets) > 1 or len(services) > 1 or not (services or sockets):
            raise ValueError("需要单一、运行中的 systemd OpenSSH 服务；多个实例或非 systemd 部署请手动修改。")
        if sockets:
            self.socket, info = next(iter(sockets.items()))
            if info.get("Accept") != "no":
                raise ValueError("暂不自动修改 Accept=yes 的 SSH socket 部署。")
            targets = [name for name in info.get("Triggers", "").split() if name in ("ssh.service", "sshd.service")]
            if len(targets) != 1:
                raise ValueError("无法识别 SSH socket 对应的服务，未修改。")
            self.service = targets[0]
            service = self.info(self.service)
            if service.get("KillMode") != "process":
                raise ValueError("socket 模式需要服务 KillMode=process 才能保留当前 SSH 会话，未修改。")
            for address in re.findall(r"(\S+) \(Stream\)", info.get("Listen", "")):
                if address.isdigit():
                    self.socket_hosts.append("::")
                    self.socket_bindings.add(("::", int(address)))
                else:
                    host, port = listen_host(address)
                    if not port or not host or address.startswith("/"):
                        raise ValueError("只支持 TCP SSH socket，未修改。")
                    self.socket_hosts.append(host)
                    self.socket_bindings.add((host, port))
            if not self.socket_hosts:
                raise ValueError("无法读取 SSH socket 的监听地址。")
            self.dropin = Path("/etc/systemd/system") / (self.socket + ".d") / "zz-ssh-tg-notify-ports.conf"
        else:
            self.service, service = next(iter(services.items()))
            if service.get("CanReload") != "yes":
                raise ValueError("SSH 服务不支持 reload，未修改；不会自动重启并中断会话。")
        runtime = service.get("ExecStart", "") + " " + service.get("Environment", "")
        pid = service.get("MainPID", "0")
        if pid.isdigit() and int(pid):
            try:
                runtime += " " + Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            except OSError:
                raise ValueError("无法读取 SSH 服务进程信息，未修改。")
        for defaults in defaults_paths:
            if defaults.is_file():
                runtime += " " + " ".join(line for line in defaults.read_text(errors="replace").splitlines()
                                            if line.strip() and not line.lstrip().startswith("#"))
        if re.search(r"(?:^|[\s=\"'])-[fpo]", runtime):
            raise ValueError("SSH 使用 -f/-p/-o 启动参数覆盖配置，未修改；请先按实际服务配置处理。")

    @staticmethod
    def info(name):
        output = run(["systemctl", "show", name, "--property=Id,ActiveState,Accept,Triggers,Listen,KillMode,CanReload,ExecStart,Environment,MainPID"])
        return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)

    def socket_plan(self, ports, staged, additions=None):
        if not self.socket:
            return {}
        if self.dropin.is_symlink() or (self.dropin.exists() and not self.dropin.read_text().startswith(SOCKET_MARKER + "\n")):
            raise ValueError("SSH socket 端口覆盖文件不属于本脚本，未修改。")
        bindings = {(host, port) for host in self.socket_hosts for port in (additions if staged and additions is not None else ports)}
        if staged:
            bindings.update(self.socket_bindings)
        addresses = sorted(endpoint(host, port) for host, port in bindings)
        text = SOCKET_MARKER + "\n[Socket]\nListenStream=\n" + "".join("ListenStream=" + value + "\n" for value in addresses)
        return {self.dropin: text.encode()}

    def apply(self):
        if self.socket:
            run(["systemctl", "daemon-reload"])
            run(["systemctl", "restart", self.socket, self.service])
        else:
            run(["systemctl", "reload", self.service])

    def verify(self, required, removed):
        for _ in range(30):
            rows = listeners()
            active = {port for _, port, ssh, systemd in rows if ssh or (self.socket and systemd)}
            if set(required) <= active and not (set(removed) & active):
                return
            time.sleep(0.2)
        raise RuntimeError("新 SSH 端口未正确监听，可能被 SELinux 拒绝或服务未采用新配置。")


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("配置路径不应为符号链接：" + str(path))
    descriptor, name = tempfile.mkstemp(prefix=".ssh-tg-port-", dir=str(path.parent))
    os.close(descriptor)
    temporary = Path(name)
    try:
        if path.exists():
            run(["cp", "--preserve=all", "--", str(path), str(temporary)])
        else:
            temporary.chmod(0o644)
        temporary.write_bytes(data)
        os.replace(str(temporary), str(path))
    finally:
        if temporary.exists():
            temporary.unlink()


class Transaction:
    def __init__(self, sshd, config, backend, backup_root):
        self.sshd, self.config, self.backend = sshd, config, backend
        backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if backup_root.is_symlink():
            raise ValueError("备份目录不应为符号链接。")
        self.backup = Path(tempfile.mkdtemp(prefix=time.strftime("%Y%m%d-%H%M%S-"), dir=str(backup_root)))

    def apply(self, plan, required, removed=(), previous=None):
        originals, written, reloading = {}, [], False
        phase = self.backup / str(len(list(self.backup.iterdir())) + 1)
        phase.mkdir(mode=0o700)
        for index, path in enumerate(plan):
            if path.is_symlink() or path.parent.is_symlink():
                raise ValueError("配置路径不应为符号链接：" + str(path))
            originals[path] = path.read_bytes() if path.exists() else None
            if path.exists():
                run(["cp", "--preserve=all", "--", str(path), str(phase / str(index))])
        (phase / "manifest.json").write_text(json.dumps({str(path): str(index) if originals[path] is not None else None
                                                        for index, path in enumerate(plan)}, indent=2), encoding="utf-8")
        try:
            for path, data in plan.items():
                if (path.read_bytes() if path.exists() else None) != originals[path]:
                    raise RuntimeError("操作期间配置被其他程序修改，已取消。")
                if originals[path] == data:
                    continue
                atomic_write(path, data)
                written.append(path)
            run([self.sshd, "-t", "-f", str(self.config)])
            settings = run([self.sshd, "-T", "-f", str(self.config)])
            if effective_ports(settings) != set(required):
                raise RuntimeError("有效 SSH 端口与目标不一致，请检查 Include、ListenAddress 或启动参数。")
            reloading = True
            self.backend.apply()
            self.backend.verify(required, removed)
        except BaseException:
            failures = []
            for path in reversed(written):
                try:
                    if not path.exists() or path.read_bytes() != plan[path]:
                        raise RuntimeError("回滚前配置又被其他程序修改")
                    old = originals[path]
                    if old is None:
                        path.unlink()
                    else:
                        atomic_write(path, old)
                except Exception:
                    failures.append(str(path))
            if reloading and not failures:
                try:
                    run([self.sshd, "-t", "-f", str(self.config)])
                    self.backend.apply()
                    if previous is not None:
                        self.backend.verify(previous, ())
                except Exception:
                    failures.append("SSH 服务重新加载")
            if failures:
                print("自动回滚未完成：" + "、".join(failures) + "；备份：" + str(self.backup), file=sys.stderr)
            else:
                print("本阶段修改已回滚；备份：" + str(self.backup), file=sys.stderr)
            raise


def change(config, backup_root, prompt=input):
    for program in ("sshd", "ss", "systemctl", "cp"):
        if not shutil.which(program):
            raise ValueError("缺少依赖：" + program)
    sshd = shutil.which("sshd")
    run([sshd, "-t", "-f", str(config)])
    settings = run([sshd, "-T", "-f", str(config)])
    backend = SystemdBackend()
    old = {port for _, port in backend.socket_bindings} if backend.socket else effective_ports(settings)
    rows = listeners()
    current = {port for _, port, ssh, systemd in rows if ssh or (backend.socket and systemd and port in old)}
    if not old or current != old:
        raise ValueError("SSH 实际监听端口与配置不一致，未修改；请先排查多个实例或 socket 配置覆盖。")
    print("当前 SSH 端口：" + "、".join(map(str, sorted(old))))
    try:
        text = prompt("请输入新的 SSH 端口（多个用空格分隔，留空取消）: ").strip()
    except EOFError:
        return
    if not text:
        print("已取消，未修改配置。")
        return
    desired = set(parse_ports(text))
    if desired == old:
        print("与当前端口相同，无需修改。")
        return
    occupied = {port for _, port, _, _ in rows}
    if (desired - old) & occupied:
        raise ValueError("目标端口已被占用：" + "、".join(map(str, sorted((desired - old) & occupied))))
    editor = ConfigEditor(config, settings)
    transaction = Transaction(sshd, config, backend, backup_root)
    staged = desired | old
    plan = editor.plan(staged, staged=not bool(backend.socket), additions=desired)
    plan.update(backend.socket_plan(staged, staged=True, additions=desired))
    transaction.apply(plan, staged, previous=old)
    print("新端口已监听，旧端口仍保留。备份目录：" + str(transaction.backup))
    print("请先在防火墙和云安全组放行新 TCP 端口，并另开连接验证：")
    for port in sorted(desired):
        print(f"  ssh -p {port} 用户@服务器IP")
    if staged == desired:
        print("已按指定列表设置 SSH 端口。")
        return
    try:
        answer = prompt("确认已通过新端口成功登录？输入 yes 关闭旧端口，其他输入保留双端口: ")
    except (EOFError, KeyboardInterrupt):
        answer = ""
    if answer.strip().lower() != "yes":
        print("已保留旧、新端口。验证完成后可再次选择修改端口，并只输入需要保留的端口。")
        return
    final_plan = editor.plan(desired, staged=False)
    final_plan.update(backend.socket_plan(desired, staged=False))
    transaction.apply(final_plan, desired, old - desired, previous=staged)
    print("SSH 端口修改成功：" + "、".join(map(str, sorted(desired))))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("/etc/ssh/sshd_config"))
    parser.add_argument("--backup-root", type=Path, default=Path("/var/backups/ssh-tg-notify-ports"))
    args = parser.parse_args()
    os.umask(0o077)
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        print("请以 root 身份运行。", file=sys.stderr)
        return 1
    def interrupted(_number, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        change(args.config, args.backup_root)
    except KeyboardInterrupt:
        print("操作已中断，请保留当前连接并检查端口状态。", file=sys.stderr)
        return 130
    except Exception as exc:
        print("修改失败：" + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
PORT_TOOL_EOF
}

change_ssh_port() (
    local program=
    require_python || return 1
    trap '[[ -z $program ]] || rm -f -- "$program"' EXIT
    umask 077
    program=$(mktemp "${TMPDIR:-/tmp}/ssh-tg-port.XXXXXX") || return 1
    write_port_tool > "$program" || return 1
    "$PYTHON_BIN" -I "$program" --config "$SSHD_CONFIG" <&3
)

remove_bruteforce() {
    check_monitor_paths || return 1
    if owned_unit; then
        disable_bruteforce || return 1
        rm -f -- "$UNIT_FILE" || return 1
        systemctl daemon-reload || { error '服务配置重新加载失败，请检查 systemd。'; return 1; }
    fi
    if [[ -d $STATE_DIR ]]; then
        rm -f -- "$STATE_DIR/state.sqlite3" "$STATE_DIR/state.sqlite3-wal" \
            "$STATE_DIR/state.sqlite3-shm" "$STATE_DIR/watch.lock" "$STATE_DIR/managed" || return 1
        rmdir -- "$STATE_DIR" 2>/dev/null || echo "状态目录 $STATE_DIR 含其他文件，已保留目录。"
    fi
}

# Deliberately remove only known filenames, never recurse through /etc.
remove_files() {
    local directory=$1
    rm -f -- "$directory/config" "$directory/notify.sh" \
        "$directory/managed" "$directory/sshd.pam.backup" "$directory/guard.py" || return 1
    if [[ -d $directory ]]; then
        rmdir -- "$directory" 2>/dev/null || {
            printf '目录 %s 内还有其他文件，已保留该目录。\n' "$directory"
        }
    fi
}

prepare_pam_copy() {
    PAM_CHECKSUM=$(cksum < "$PAM_FILE") || return 1
    PAM_TEMP=$(mktemp "${PAM_FILE}.ssh-tg-notify.XXXXXX") || return 1
    # Preserve ownership, permissions, ACLs and SELinux label during replacement.
    cp --preserve=all -- "$PAM_FILE" "$PAM_TEMP" || return 1
}

commit_pam_copy() {
    check_pam_file || return 1
    if [[ $(cksum < "$PAM_FILE") != "$PAM_CHECKSUM" ]]; then
        error '操作期间 PAM 配置被其他程序修改，本次操作已取消，请重试。'
        return 1
    fi
    mv -fT -- "$PAM_TEMP" "$PAM_FILE"
}

install_notification() (
    local state stage= PAM_TEMP= PAM_CHECKSUM= moved=0 committed=0 message
    state=$(pam_state) || return 1
    if [[ $state == installed ]] && owned_install && load_config &&
       [[ -f $NOTIFIER && ! -L $NOTIFIER && -x $NOTIFIER ]]; then
        echo '已添加 SSH 登录通知，跳过安装，不修改现有配置。'
        return 0
    fi
    if [[ $state != absent || -e $INSTALL_DIR || -L $INSTALL_DIR ]]; then
        error '检测到残留文件、重复条目或被修改的配置。请先选择“查看通知”，按 README 排查后卸载重装。'
        return 1
    fi
    if has_legacy_hook; then
        echo '检测到旧版 /etc/pam.scripts/tg_ssh_alert.sh 通知，跳过安装，避免重复通知。'
        echo '如需使用新版，请先按 README 的旧版迁移说明清理。'
        return 0
    fi
    check_ssh || return 1
    read_install_config || { error '安装已取消，尚未修改配置。'; return 1; }
    echo '正在验证 Telegram 配置并发送测试消息……'
    message=$(printf '✅ SSH 通知安装测试\n• 服务器: %s\n• 时间: %s' "$SERVER_NAME" "$(date '+%Y-%m-%d %H:%M:%S %z')")
    send_telegram "$message" || {
        error '测试消息发送失败，未安装。请检查 Token、Chat ID、机器人权限及 Telegram 网络连接。'
        return 1
    }

    cleanup_install() {
        [[ -z $PAM_TEMP ]] || rm -f -- "$PAM_TEMP"
        [[ -z $stage ]] || remove_files "$stage"
        # If interrupted just after the PAM rename, retain the working notifier.
        if [[ $moved == 1 && $committed == 0 && $(pam_state) == absent ]]; then
            remove_files "$INSTALL_DIR"
        fi
    }
    trap cleanup_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    umask 077
    stage=$(mktemp -d "${INSTALL_DIR}.install.XXXXXX") || return 1
    if ! printf 'ssh-tg-notify/v1\n' > "$stage/managed" ||
       ! printf 'SERVER_NAME=%s\nTG_BOT_TOKEN=%s\nTG_CHAT_ID=%s\n' \
            "$SERVER_NAME" "$TG_BOT_TOKEN" "$TG_CHAT_ID" > "$stage/config" ||
       ! write_notifier > "$stage/notify.sh" ||
       ! cp --preserve=all -- "$PAM_FILE" "$stage/sshd.pam.backup" ||
       ! chmod 600 "$stage/config" "$stage/managed" "$stage/sshd.pam.backup" ||
       ! chmod 700 "$stage" "$stage/notify.sh" ||
       ! /bin/bash -n "$stage/notify.sh" || ! prepare_pam_copy; then
        error '准备安装文件失败，PAM 尚未修改。'; return 1
    fi
    # The preceding newline is needed only for a PAM file without a final LF.
    if [[ -s $PAM_TEMP && -n $(tail -c 1 "$PAM_TEMP") ]]; then
        printf '\n' >> "$PAM_TEMP" || return 1
    fi
    printf '%s\n%s\n%s\n' "$BEGIN_MARKER" "$PAM_ENTRY" "$END_MARKER" >> "$PAM_TEMP" || return 1
    # Refuse to overwrite a directory that appeared while collecting input.
    if [[ -e $INSTALL_DIR || -L $INSTALL_DIR ]] || ! mv -T -- "$stage" "$INSTALL_DIR"; then
        error '安装目录创建失败。'; return 1
    fi
    stage= moved=1
    if ! commit_pam_copy; then
        error 'PAM 写入失败，已撤销本次安装文件。'; return 1
    fi
    PAM_TEMP= committed=1
    echo '安装成功，测试消息已发送。无需重启 SSH 服务。'
    echo '请保留当前连接，另开一个 SSH 会话验证实际登录通知。'
)

show_notification() {
    local state
    state=$(pam_state) || return 1
    if ! owned_install; then
        if [[ -e $INSTALL_DIR || -L $INSTALL_DIR || $state != absent ]]; then
            error '存在无法识别的文件或 PAM 条目，请按 README 排查。'; return 1
        fi
        echo '尚未安装本脚本的通知。'
        has_legacy_hook && echo '检测到旧版通知：/etc/pam.scripts/tg_ssh_alert.sh（见 README 迁移说明）。'
        return 0
    fi
    if ! load_config; then
        error '通知配置损坏，可选择卸载后重新安装。'; return 1
    fi
    printf '服务器: %s\nTG_BOT_TOKEN: %s\nTG_CHAT_ID: %s\n' "$SERVER_NAME" "$TG_BOT_TOKEN" "$TG_CHAT_ID"
    if [[ $state == installed && -f $NOTIFIER && ! -L $NOTIFIER && -x $NOTIFIER ]]; then
        echo '状态: 已配置（可选择“发送测试通知”检查 Telegram 连通性）'
    else
        echo '状态: 安装不完整或 PAM 条目被修改，请按 README 排查后重装。'
    fi
    bruteforce_status
}

test_notification() {
    owned_install && [[ -f $NOTIFIER && ! -L $NOTIFIER && -x $NOTIFIER ]] || {
        error '尚未安装完整的通知脚本。'; return 1;
    }
    /bin/bash -p "$NOTIFIER" --test
}

uninstall_notification() (
    local state PAM_TEMP= PAM_CHECKSUM=
    check_pam_file || return 1
    state=$(pam_state) || return 1
    if [[ $state == conflict ]]; then
        error 'PAM 条目存在重复或被修改，未进行删除。请按 README 排查。'; return 1
    fi
    if [[ -e $INSTALL_DIR || -L $INSTALL_DIR ]] && ! owned_install; then
        error "无法确认 $INSTALL_DIR 由本脚本创建，未删除任何内容。"; return 1
    fi
    remove_bruteforce || return 1
    if [[ $state == absent && ! -e $INSTALL_DIR ]]; then
        echo '尚未安装或已经卸载，无需重复操作。'; return 0
    fi
    trap '[[ -z $PAM_TEMP ]] || rm -f -- "$PAM_TEMP"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [[ $state == installed ]]; then
        prepare_pam_copy || { error '无法备份 PAM 配置，未卸载。'; return 1; }
        # Filter the current file instead of restoring the old backup: preserve
        # unrelated PAM changes made after this tool was installed.
        if ! awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
            $0 == begin { inside=1; next }
            $0 == end { inside=0; next }
            !inside { print }
        ' "$PAM_FILE" > "$PAM_TEMP" || ! commit_pam_copy; then
            error '移除 PAM 条目失败，通知文件仍予保留。'; return 1
        fi
        PAM_TEMP=
    fi
    remove_files "$INSTALL_DIR" || { error '通知已停用，但部分文件删除失败。'; return 1; }
    echo '卸载完成，无需重启 SSH 服务。'
)

with_lock() (
    [[ ! -L $LOCK_FILE ]] || { error '锁文件不应为符号链接。'; return 1; }
    umask 077
    exec 9> "$LOCK_FILE" || { error '无法创建操作锁。'; return 1; }
    flock -n 9 || { error '另一个通知管理操作正在运行，请稍后重试。'; return 1; }
    "$@"
)

usage() {
    cat <<'USAGE_EOF'
用法：bash ssh-tg-notify.sh [install|show|test|enable-bruteforce|disable-bruteforce|test-bruteforce|rank|uninstall|change-port]
不带参数时显示菜单。install 交互读取服务器名称、TG_BOT_TOKEN、TG_CHAT_ID。
请以 root 身份在支持 PAM 的 Linux OpenSSH 服务器运行。
USAGE_EOF
}

main() {
    local action=${1:-menu} choice dependency
    case $action in -h|--help|help) usage; return 0 ;; esac
    [[ $# -le 1 ]] || { usage >&2; return 1; }
    case $action in menu|install|show|test|enable-bruteforce|disable-bruteforce|test-bruteforce|rank|uninstall|change-port) ;; *) usage >&2; return 1 ;; esac
    [[ $EUID -eq 0 ]] || { error '请先执行 sudo -i，再运行脚本。'; return 1; }
    [[ $(uname -s) == Linux ]] || { error '本脚本仅适用于 Linux。'; return 1; }
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    export PATH
    [[ -x /bin/bash ]] || { error '需要 /bin/bash，请先安装 Bash。'; return 1; }
    for dependency in awk grep flock mktemp cp mv chmod cat tail rm rmdir mkdir hostname date cksum env; do
        command -v "$dependency" >/dev/null 2>&1 || {
            error "缺少依赖 $dependency，请参考 README 安装依赖。"; return 1;
        }
    done
    if ! { exec 3</dev/tty; } 2>/dev/null; then exec 3<&0; fi
    case $action in
        install) with_lock install_notification; return $? ;;
        show) with_lock show_notification; return $? ;;
        test) with_lock test_notification; return $? ;;
        enable-bruteforce) with_lock enable_bruteforce; return $? ;;
        disable-bruteforce) with_lock disable_bruteforce; return $? ;;
        test-bruteforce) with_lock test_bruteforce; return $? ;;
        rank) with_lock show_failed_ranking; return $? ;;
        uninstall) with_lock uninstall_notification; return $? ;;
        change-port) with_lock change_ssh_port; return $? ;;
    esac
    while true; do
        printf '\nSSH 登录 Telegram 通知\n1. 添加 SSH 登录通知\n2. 查看通知配置\n3. 发送测试通知\n4. 开启爆破通知\n5. 关闭爆破通知\n6. 发送爆破测试通知\n7. 查看失败排名\n8. 卸载全部\n9. 更改 SSH 端口\n0. 退出\n'
        read_field choice '请选择 [0-9]: ' || { printf '\n'; return 0; }
        case $choice in
            1) with_lock install_notification ;;
            2) with_lock show_notification ;;
            3) with_lock test_notification ;;
            4) with_lock enable_bruteforce ;;
            5) with_lock disable_bruteforce ;;
            6) with_lock test_bruteforce ;;
            7) with_lock show_failed_ranking ;;
            8) with_lock uninstall_notification ;;
            9) with_lock change_ssh_port ;;
            0) return 0 ;;
            *) echo '无效选项，请输入 0 到 9。' ;;
        esac
    done
}

# Allow the regression tests to source functions without touching system files.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi

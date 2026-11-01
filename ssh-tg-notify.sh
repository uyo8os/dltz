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

# Deliberately remove only known filenames, never recurse through /etc.
remove_files() {
    local directory=$1
    rm -f -- "$directory/config" "$directory/notify.sh" \
        "$directory/managed" "$directory/sshd.pam.backup" || return 1
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
用法：bash ssh-tg-notify.sh [install|show|test|uninstall]
不带参数时显示菜单。install 交互读取服务器名称、TG_BOT_TOKEN、TG_CHAT_ID。
请以 root 身份在支持 PAM 的 Linux OpenSSH 服务器运行。
USAGE_EOF
}

main() {
    local action=${1:-menu} choice dependency
    case $action in -h|--help|help) usage; return 0 ;; esac
    [[ $# -le 1 ]] || { usage >&2; return 1; }
    case $action in menu|install|show|test|uninstall) ;; *) usage >&2; return 1 ;; esac
    [[ $EUID -eq 0 ]] || { error '请先执行 sudo -i，再运行脚本。'; return 1; }
    [[ $(uname -s) == Linux ]] || { error '本脚本仅适用于 Linux。'; return 1; }
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    export PATH
    [[ -x /bin/bash ]] || { error '需要 /bin/bash，请先安装 Bash。'; return 1; }
    for dependency in awk grep flock mktemp cp mv chmod cat tail rm rmdir hostname date cksum env; do
        command -v "$dependency" >/dev/null 2>&1 || {
            error "缺少依赖 $dependency，请参考 README 安装依赖。"; return 1;
        }
    done
    if ! { exec 3</dev/tty; } 2>/dev/null; then exec 3<&0; fi
    case $action in
        install) with_lock install_notification; return $? ;;
        show) with_lock show_notification; return $? ;;
        test) with_lock test_notification; return $? ;;
        uninstall) with_lock uninstall_notification; return $? ;;
    esac
    while true; do
        printf '\nSSH 登录 Telegram 通知\n1. 添加 SSH 登录通知\n2. 查看通知配置\n3. 卸载通知\n4. 发送测试通知\n0. 退出\n'
        read_field choice '请选择 [0-4]: ' || { printf '\n'; return 0; }
        case $choice in
            1) with_lock install_notification ;;
            2) with_lock show_notification ;;
            3) with_lock uninstall_notification ;;
            4) with_lock test_notification ;;
            0) return 0 ;;
            *) echo '无效选项，请输入 0、1、2、3 或 4。' ;;
        esac
    done
}

# Allow the regression tests to source functions without touching system files.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi

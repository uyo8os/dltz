#!/usr/bin/env bash
# Isolated functional regression tests; no root, real PAM or Telegram required.
set -u

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 1
source "$REPO_ROOT/ssh-tg-notify.sh"
TEST_ROOT=$(mktemp -d "$REPO_ROOT/.ssh-tg-notify-tests.XXXXXX") || exit 1
cleanup() {
    # Verify the resolved absolute target stays inside this workspace before
    # recursively deleting only the directory created by this test run.
    local resolved
    [[ -d $TEST_ROOT && ! -L $TEST_ROOT ]] || return
    resolved=$(cd -- "$TEST_ROOT" && pwd -P) || return
    case $resolved in
        "$REPO_ROOT"/.ssh-tg-notify-tests.*) rm -rf -- "$resolved" ;;
        *) printf 'Refusing to clean unexpected test path: %s\n' "$resolved" >&2 ;;
    esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

fail() { printf '  %s\n' "$*" >&2; exit 1; }
assert_same() { cmp -s -- "$1" "$2" || fail "Files differ: $1, $2"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "Missing '$2' in $1"; }
assert_absent() { [[ ! -e $1 && ! -L $1 ]] || fail "Unexpected path: $1"; }

# Only platform/daemon checks are replaced. File writes, atomic replacements,
# input validation, config parsing, API invocation and notifier code are real.
check_ssh() { CURL_BIN=$FAKE_CURL; }

new_case() {
    CASE_DIR=$(mktemp -d "$TEST_ROOT/case.XXXXXX") || fail 'mktemp failed'
    cd -- "$CASE_DIR" || fail 'cd failed'
    INSTALL_DIR=$CASE_DIR/install
    CONFIG_FILE=$INSTALL_DIR/config
    NOTIFIER=$INSTALL_DIR/notify.sh
    GUARD=$INSTALL_DIR/guard.py
    PAM_FILE=$CASE_DIR/sshd
    LOCK_FILE=$CASE_DIR/lock
    PAM_ENTRY="session optional pam_exec.so quiet type=open_session $NOTIFIER"
    FAKE_CURL=$CASE_DIR/curl
    CURL_BIN=$FAKE_CURL
    mkdir "$CASE_DIR/units"
    UNIT_FILE=$CASE_DIR/units/$UNIT_NAME
    STATE_DIR=$CASE_DIR/state
    printf '# existing PAM settings\nauth required pam_example.so\nsession required pam_other.so\n' > "$PAM_FILE"
    cp -- "$PAM_FILE" "$CASE_DIR/baseline"
    {
        printf '#!/bin/bash\nSTATE=%q\n' "$CASE_DIR"
        cat <<'FAKE_EOF'
cat >> "$STATE/request-config"
printf '%s\n' "$@" >> "$STATE/request-args"
env > "$STATE/request-env"
if [[ -f $STATE/delay ]]; then sleep 2; fi
mode=$(cat "$STATE/api-mode" 2>/dev/null)
case $mode in
    network) exit 28 ;;
    http) exit 22 ;;
    rejected) printf '{"ok":false,"description":"rejected"}' ;;
    malformed) printf 'not JSON' ;;
    *) printf '{"ok":true,"result":{"message_id":1}}' ;;
esac
FAKE_EOF
    } > "$FAKE_CURL"
    chmod 700 "$FAKE_CURL"
    INPUT=$(printf '%s\n' 'Demo & _node' '123456:TEST_token-abc' '-1001234567890')
}

check_bruteforce_dependencies() { PYTHON_BIN=$(command -v python); }

# The real systemctl is never invoked by tests.
systemctl() {
    printf '%s\n' "$*" >> "$CASE_DIR/systemctl-calls"
    case $1 in
        is-active) [[ -f $CASE_DIR/active ]] ;;
        is-enabled) [[ -f $CASE_DIR/enabled ]] ;;
        enable)
            [[ ! -f $CASE_DIR/start-fails ]] || return 1
            : > "$CASE_DIR/enabled"
            [[ ${2:-} != --now ]] || : > "$CASE_DIR/active"
            return 0
            ;;
        stop|disable)
            [[ ! -f $CASE_DIR/stop-fails ]] || return 1
            rm -f -- "$CASE_DIR/active"
            [[ $1 != disable ]] || rm -f -- "$CASE_DIR/enabled"
            return 0
            ;;
        daemon-reload) return 0 ;;
        *) fail "Unexpected systemctl command: $*" ;;
    esac
}

install_ok() {
    install_notification 3<<< "$INPUT" > "$CASE_DIR/install-output" 2>&1 || {
        cat "$CASE_DIR/install-output" >&2; fail 'Installation failed';
    }
    [[ $(pam_state) == installed ]] || fail 'Invalid installed PAM state'
    owned_install && load_config || fail 'Installed config cannot be loaded'
    /bin/bash -n "$NOTIFIER" || fail 'Generated notifier has a syntax error'
}

test_install_and_show() {
    new_case
    install_ok
    assert_same "$CASE_DIR/baseline" "$INSTALL_DIR/sshd.pam.backup"
    show_notification > "$CASE_DIR/show"
    assert_contains "$CASE_DIR/show" '服务器: Demo & _node'
    assert_contains "$CASE_DIR/show" 'TG_BOT_TOKEN: 123456:TEST_token-abc'
    assert_contains "$CASE_DIR/show" 'TG_CHAT_ID: -1001234567890'
    assert_contains "$CASE_DIR/request-args" '--data-urlencode'
    assert_contains "$CASE_DIR/request-args" 'text=✅ SSH 通知安装测试'
    if grep -Fq 'TEST_token-abc' "$CASE_DIR/request-args"; then fail 'Token exposed in argv'; fi
    if [[ $(uname -s) == Linux ]]; then
        [[ $(stat -c %a "$INSTALL_DIR") == 700 ]] || fail 'Wrong directory permissions'
        [[ $(stat -c %a "$CONFIG_FILE") == 600 ]] || fail 'Wrong config permissions'
        [[ $(stat -c %a "$NOTIFIER") == 700 ]] || fail 'Wrong notifier permissions'
    fi
}

test_repeat_install() {
    new_case
    install_ok
    cp "$PAM_FILE" "$CASE_DIR/installed-pam"
    cp "$CONFIG_FILE" "$CASE_DIR/installed-config"
    cp "$CASE_DIR/request-args" "$CASE_DIR/previous-request"
    printf network > "$CASE_DIR/api-mode"
    install_notification 3</dev/null > "$CASE_DIR/repeat-output" 2>&1 || fail 'Repeat install failed'
    assert_contains "$CASE_DIR/repeat-output" '跳过安装'
    assert_same "$PAM_FILE" "$CASE_DIR/installed-pam"
    assert_same "$CONFIG_FILE" "$CASE_DIR/installed-config"
    assert_same "$CASE_DIR/request-args" "$CASE_DIR/previous-request"
}

test_failed_api() {
    local mode
    for mode in network http rejected malformed; do
        new_case
        printf '%s' "$mode" > "$CASE_DIR/api-mode"
        if install_notification 3<<< "$INPUT" > "$CASE_DIR/output" 2>&1; then fail "Accepted API failure: $mode"; fi
        assert_absent "$INSTALL_DIR"
        assert_same "$PAM_FILE" "$CASE_DIR/baseline"
    done
}

test_invalid_input() {
    new_case
    INPUT=$(printf '%s\n' 'demo' 'not-a-token' 'abc')
    if install_notification 3<<< "$INPUT" > "$CASE_DIR/output" 2>&1; then fail 'Accepted invalid input'; fi
    assert_absent "$INSTALL_DIR"
    assert_absent "$CASE_DIR/request-args"
    assert_same "$PAM_FILE" "$CASE_DIR/baseline"
}

test_input_eof() {
    new_case
    if install_notification 3</dev/null > "$CASE_DIR/output" 2>&1; then fail 'Accepted missing input'; fi
    assert_absent "$INSTALL_DIR"
    assert_same "$PAM_FILE" "$CASE_DIR/baseline"
}

test_config_is_data() {
    new_case
    INPUT=$(printf '%s\n' '$(touch injected) & <node> _* "quotes"' '123456:TEST_token-abc' '1234')
    install_ok
    show_notification > "$CASE_DIR/show" || fail 'Show failed'
    assert_contains "$CASE_DIR/show" '$(touch injected) & <node> _* "quotes"'
    assert_absent "$CASE_DIR/injected"
    printf 'touch injected\n' >> "$CONFIG_FILE"
    if load_config; then fail 'Accepted an executable/unknown config line'; fi
    assert_absent "$CASE_DIR/injected"
    uninstall_notification > "$CASE_DIR/output" 2>&1 || fail 'Corrupt config prevents uninstall'
    assert_absent "$INSTALL_DIR"
    assert_same "$PAM_FILE" "$CASE_DIR/baseline"
}

test_duplicate_config_keys() {
    new_case
    install_ok
    printf 'TG_CHAT_ID=9876\n' >> "$CONFIG_FILE"
    if load_config; then fail 'Accepted duplicate config keys'; fi
}

test_uninstall_preserves_changes() {
    new_case
    install_ok
    printf '# added after installation\nsession optional pam_new.so\n' >> "$PAM_FILE"
    cat "$CASE_DIR/baseline" > "$CASE_DIR/expected"
    printf '# added after installation\nsession optional pam_new.so\n' >> "$CASE_DIR/expected"
    uninstall_notification > "$CASE_DIR/output" 2>&1 || fail 'Uninstall failed'
    assert_same "$PAM_FILE" "$CASE_DIR/expected"
    assert_absent "$INSTALL_DIR"
    uninstall_notification >> "$CASE_DIR/output" 2>&1 || fail 'Repeat uninstall failed'
    assert_same "$PAM_FILE" "$CASE_DIR/expected"
}

test_uninstall_preserves_unknown_files() {
    new_case
    install_ok
    printf 'unrelated\n' > "$INSTALL_DIR/keep-me"
    uninstall_notification > "$CASE_DIR/output" 2>&1 || fail 'Uninstall failed'
    assert_contains "$INSTALL_DIR/keep-me" unrelated
    assert_absent "$CONFIG_FILE"
    assert_absent "$NOTIFIER"
    assert_same "$PAM_FILE" "$CASE_DIR/baseline"
}

test_install_rollback() {
    new_case
    commit_pam_copy() { return 1; }
    if install_notification 3<<< "$INPUT" > "$CASE_DIR/output" 2>&1; then fail 'Accepted failed PAM commit'; fi
    assert_absent "$INSTALL_DIR"
    assert_same "$PAM_FILE" "$CASE_DIR/baseline"
    if compgen -G "$PAM_FILE.ssh-tg-notify.*" >/dev/null ||
       compgen -G "$INSTALL_DIR.install.*" >/dev/null; then fail 'Staging files leaked'; fi
}

test_uninstall_write_failure() {
    new_case
    install_ok
    cp "$PAM_FILE" "$CASE_DIR/installed-pam"
    commit_pam_copy() { return 1; }
    if uninstall_notification > "$CASE_DIR/output" 2>&1; then fail 'Accepted failed uninstall'; fi
    assert_same "$PAM_FILE" "$CASE_DIR/installed-pam"
    [[ -f $CONFIG_FILE && -x $NOTIFIER ]] || fail 'Working notifier removed after failed uninstall'
}

test_concurrent_pam_change() {
    new_case
    local PAM_TEMP= PAM_CHECKSUM=
    prepare_pam_copy || fail 'Prepare failed'
    printf '# concurrent modification\n' >> "$PAM_FILE"
    cp "$PAM_FILE" "$CASE_DIR/concurrent-pam"
    if commit_pam_copy > "$CASE_DIR/output" 2>&1; then fail 'Overwrote concurrent change'; fi
    assert_same "$PAM_FILE" "$CASE_DIR/concurrent-pam"
    rm -f -- "$PAM_TEMP"
}

test_conflicting_pam() {
    new_case
    install_ok
    printf '%s\n' "$PAM_ENTRY" >> "$PAM_FILE"
    cp "$PAM_FILE" "$CASE_DIR/conflicting-pam"
    [[ $(pam_state) == conflict ]] || fail 'Duplicate not detected'
    if uninstall_notification > "$CASE_DIR/output" 2>&1; then fail 'Removed conflicting PAM block'; fi
    if install_notification 3<<< "$INPUT" >> "$CASE_DIR/output" 2>&1; then fail 'Accepted conflicting installation'; fi
    assert_same "$PAM_FILE" "$CASE_DIR/conflicting-pam"
    [[ -x $NOTIFIER ]] || fail 'Notifier was deleted'
}

test_unowned_directory() {
    new_case
    mkdir "$INSTALL_DIR"
    printf 'unrelated config\n' > "$CONFIG_FILE"
    if install_notification 3<<< "$INPUT" > "$CASE_DIR/output" 2>&1; then fail 'Overwrote unknown install'; fi
    if uninstall_notification >> "$CASE_DIR/output" 2>&1; then fail 'Removed unknown directory'; fi
    assert_contains "$CONFIG_FILE" 'unrelated config'
    assert_same "$PAM_FILE" "$CASE_DIR/baseline"
}

test_legacy_detection() {
    new_case
    printf 'session optional pam_exec.so /etc/pam.scripts/tg_ssh_alert.sh\n' >> "$PAM_FILE"
    cp "$PAM_FILE" "$CASE_DIR/legacy-pam"
    install_notification 3</dev/null > "$CASE_DIR/output" 2>&1 || fail 'Legacy detection failed'
    assert_contains "$CASE_DIR/output" '跳过安装'
    assert_absent "$INSTALL_DIR"
    assert_absent "$CASE_DIR/request-args"
    assert_same "$PAM_FILE" "$CASE_DIR/legacy-pam"
}

test_commented_legacy_is_ignored() {
    new_case
    printf '# session optional pam_exec.so /etc/pam.scripts/tg_ssh_alert.sh\n' >> "$PAM_FILE"
    install_ok
}

test_notification_filters_and_background() {
    new_case
    install_ok
    rm -f -- "$CASE_DIR/request-args"
    PAM_TYPE=close_session PAM_SERVICE=sshd /bin/bash -p "$NOTIFIER" || fail 'Close-session hook failed'
    PAM_TYPE=open_session PAM_SERVICE=sudo /bin/bash -p "$NOTIFIER" || fail 'Other-service hook failed'
    assert_absent "$CASE_DIR/request-args"
    : > "$CASE_DIR/delay"
    # The simulated HTTP request takes two seconds. The PAM hook must return
    # before timeout(1) kills it, while the detached worker completes later.
    PAM_TYPE=open_session PAM_SERVICE=sshd PAM_USER=test-user PAM_RHOST=2001:db8::1 \
        timeout 1 /bin/bash -p "$NOTIFIER" || fail 'PAM waited for the network request'
    local attempts=0
    until [[ -s $CASE_DIR/request-args ]]; do
        sleep 0.05
        ((attempts+=1))
        [[ $attempts -lt 80 ]] || fail 'No background notification received'
    done
    assert_contains "$CASE_DIR/request-args" '用户: test-user'
    assert_contains "$CASE_DIR/request-args" '来源 IP: 2001:db8::1'
    # Let the worker finish before cleaning up its files.
    sleep 2.1
}

test_saved_config_test() {
    new_case
    install_ok
    test_notification > "$CASE_DIR/output" 2>&1 || fail 'Saved config test failed'
    assert_contains "$CASE_DIR/output" '测试消息已发送'
    printf rejected > "$CASE_DIR/api-mode"
    if test_notification > "$CASE_DIR/output" 2>&1; then fail 'Saved config test ignored rejection'; fi
}

test_pam_without_final_newline() {
    new_case
    printf 'session required pam_other.so' > "$PAM_FILE"
    install_ok
    uninstall_notification > "$CASE_DIR/output" 2>&1 || fail 'Uninstall failed'
    printf 'session required pam_other.so\n' > "$CASE_DIR/expected"
    assert_same "$PAM_FILE" "$CASE_DIR/expected"
}

test_curl_environment() {
    new_case
    export HTTPS_PROXY=https://invalid.invalid CURL_CA_BUNDLE=/does/not/exist
    install_ok
    if grep -Eq '^(HTTPS_PROXY|CURL_CA_BUNDLE)=' "$CASE_DIR/request-env"; then fail 'Inherited unsafe curl environment'; fi
}

test_bruteforce_requires_login() {
    new_case
    if enable_bruteforce > "$CASE_DIR/output" 2>&1; then fail 'Enabled monitoring without login config'; fi
    if test_bruteforce >> "$CASE_DIR/output" 2>&1; then fail 'Tested monitoring without login config'; fi
    assert_absent "$UNIT_FILE"
    assert_absent "$STATE_DIR"
    assert_absent "$CASE_DIR/systemctl-calls"
}

enable_ok() {
    enable_bruteforce > "$CASE_DIR/enable-output" 2>&1 || {
        cat "$CASE_DIR/enable-output" >&2; fail 'Enable failed';
    }
    [[ -f $CASE_DIR/active && -f $CASE_DIR/enabled ]] || fail 'Service not enabled and active'
    owned_unit || fail 'Service ownership marker missing'
    assert_contains "$UNIT_FILE" "--state-dir \"$STATE_DIR\""
    assert_contains "$GUARD" 'def watch('
}

test_bruteforce_lifecycle() {
    new_case
    install_ok
    cp "$CONFIG_FILE" "$CASE_DIR/saved-config"
    enable_ok
    printf 'retained state' > "$STATE_DIR/state.sqlite3"
    enable_ok
    assert_contains "$STATE_DIR/state.sqlite3" 'retained state'
    disable_bruteforce > "$CASE_DIR/output" 2>&1 || fail 'Disable failed'
    assert_absent "$CASE_DIR/active"
    assert_absent "$CASE_DIR/enabled"
    [[ $(pam_state) == installed ]] || fail 'Disable removed login notification'
    assert_same "$CONFIG_FILE" "$CASE_DIR/saved-config"
    enable_ok
    assert_absent "$STATE_DIR/state.sqlite3"
    assert_same "$CONFIG_FILE" "$CASE_DIR/saved-config"
}

test_bruteforce_start_failure() {
    new_case
    install_ok
    : > "$CASE_DIR/start-fails"
    if enable_bruteforce > "$CASE_DIR/output" 2>&1; then fail 'Accepted failed service start'; fi
    assert_absent "$CASE_DIR/active"
    assert_absent "$CASE_DIR/enabled"
    [[ $(pam_state) == installed ]] || fail 'Failed monitor start damaged login hook'
    load_config || fail 'Failed monitor start damaged credentials'
}

test_uninstall_all() {
    new_case
    install_ok
    enable_ok
    uninstall_notification > "$CASE_DIR/output" 2>&1 || fail 'Uninstall all failed'
    assert_absent "$INSTALL_DIR"
    assert_absent "$STATE_DIR"
    assert_absent "$UNIT_FILE"
    assert_absent "$CASE_DIR/active"
    assert_absent "$CASE_DIR/enabled"
    assert_same "$PAM_FILE" "$CASE_DIR/baseline"
    assert_contains "$CASE_DIR/systemctl-calls" "disable --now $UNIT_NAME"
}

test_monitor_stop_failure_preserves_files() {
    new_case
    install_ok
    enable_ok
    : > "$CASE_DIR/stop-fails"
    if uninstall_notification > "$CASE_DIR/output" 2>&1; then fail 'Uninstalled a running monitor'; fi
    [[ $(pam_state) == installed && -f $GUARD && -f $CONFIG_FILE && -f $UNIT_FILE ]] || fail 'Deleted files used by a running service'
}

test_unknown_monitor_files_preserved() {
    new_case
    install_ok
    printf 'unrelated unit\n' > "$UNIT_FILE"
    if enable_bruteforce > "$CASE_DIR/output" 2>&1; then fail 'Overwrote unknown service'; fi
    if uninstall_notification >> "$CASE_DIR/output" 2>&1; then fail 'Deleted unknown service'; fi
    assert_contains "$UNIT_FILE" 'unrelated unit'
    [[ $(pam_state) == installed ]] || fail 'Unknown unit changed PAM state'
}

tests=(
    test_install_and_show test_repeat_install test_failed_api test_invalid_input
    test_input_eof test_config_is_data test_duplicate_config_keys
    test_uninstall_preserves_changes test_uninstall_preserves_unknown_files
    test_install_rollback test_uninstall_write_failure test_concurrent_pam_change
    test_conflicting_pam test_unowned_directory test_legacy_detection
    test_commented_legacy_is_ignored test_notification_filters_and_background
    test_saved_config_test test_pam_without_final_newline test_curl_environment
    test_bruteforce_requires_login test_bruteforce_lifecycle test_bruteforce_start_failure
    test_uninstall_all test_monitor_stop_failure_preserves_files test_unknown_monitor_files_preserved
)
passed=0 failed=0
for test_name in "${tests[@]}"; do
    if ( "$test_name" ); then
        printf 'PASS %s\n' "$test_name"
        ((passed+=1))
    else
        printf 'FAIL %s\n' "$test_name" >&2
        ((failed+=1))
    fi
done
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]

#!/bin/sh
# Standalone POSIX shell; requires adb and standard awk/sed/grep utilities.
# Removes ALL global HTTP/PAC proxies, including Android's in-memory proxy.
# Does not change Wi-Fi profiles, DNS, VPN, mobile data or other adb connections.
# Exit: 0 verified; 1 command/repair failure; 2 offline/unverified; 3 bad arguments.

set -u

usage() {
    cat <<'EOF'
用法：sh fix_android_system_proxy.sh DEVICE [选项]

  --connect       先注册一次无线 ADB 连接，不重启 ADB 服务
  --check-only    只读取代理和联网状态，不修改设置
  --adb PATH      指定 adb（默认使用 PATH 中的 adb）
  --wait SECONDS  等待系统联网验证，0–60 秒，默认 20
  --url HTTPS_URL 自定义 HTTPS 验证地址，可重复指定
  -h, --help      显示帮助

默认清除全部全局 HTTP/PAC 代理；无需 Python 或 root。
示例：sh fix_android_system_proxy.sh 192.168.1.10:5555 --connect
EOF
}

bad_args() { printf '%s\n' "$*" >&2; exit 3; }
adb_bin=adb
device=
connect=no
check_only=no
wait_seconds=20
urls=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --connect) connect=yes ;;
        --check-only) check_only=yes ;;
        --adb|--wait|--url)
            option=$1
            [ "$#" -ge 2 ] || bad_args "$option 缺少参数"
            shift
            case "$option" in
                --adb) adb_bin=$1 ;;
                --wait) wait_seconds=$1 ;;
                --url) urls="${urls}${1}
" ;;
            esac ;;
        -*) bad_args "未知选项：$1" ;;
        *) [ -z "$device" ] || bad_args '只能指定一台设备'; device=$1 ;;
    esac
    shift
done
[ -n "$device" ] || { usage >&2; exit 3; }
case "$wait_seconds" in ''|*[!0-9]*) bad_args '--wait 必须为 0–60 的整数' ;; esac
[ "${#wait_seconds}" -le 2 ] && [ "$wait_seconds" -le 60 ] || bad_args '--wait 必须为 0–60 的整数'
wait_seconds=$(printf '%s' "$wait_seconds" | sed 's/^0*//')
wait_seconds=${wait_seconds:-0}
command -v "$adb_bin" >/dev/null 2>&1 || bad_args '未找到 adb，请安装 Android Platform Tools'
if [ -z "$urls" ]; then
    urls='https://connect.rom.miui.com/generate_204
https://www.baidu.com/'
fi
while IFS= read -r url; do
    [ -n "$url" ] || continue
    case "$url" in https://*) ;; *) bad_args '--url 必须为 HTTPS 地址' ;; esac
    authority=${url#https://}
    authority=${authority%%[/?#]*}
    case "$authority" in ''|*@*) bad_args '--url 需要主机名且不能包含用户名或密码' ;; esac
done <<EOF
$urls
EOF

work=$(mktemp -d "${TMPDIR:-/tmp}/android-proxy-fix.XXXXXXXX") || exit 1
# shellcheck disable=SC2329 # Invoked by EXIT traps.
remove_workspace() {
    find "$1" -type f -exec rm -- {} +
    find "$1" -depth -type d -exec rmdir -- {} \;
}
trap 'remove_workspace "$work"' 0
trap 'exit 130' INT
trap 'exit 143' HUP TERM

# Bound each adb call without depending on GNU timeout (absent on macOS).
# All process IDs belong to this invocation; never stop the shared adb server.
run_adb() (
    call_dir=$(mktemp -d "$work/call.XXXXXXXX") || exit 1
    command_pid=
    timer_pid=
    # shellcheck disable=SC2329 # Invoked by the EXIT trap.
    cleanup_call() {
        [ -z "$timer_pid" ] || kill "$timer_pid" 2>/dev/null || :
        [ -z "$command_pid" ] || kill "$command_pid" 2>/dev/null || :
        remove_workspace "$call_dir"
    }
    trap cleanup_call 0
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    "$adb_bin" "$@" >"$call_dir/output" 2>"$call_dir/error" &
    command_pid=$!
    (
        delay_pid=
        trap '[ -z "$delay_pid" ] || kill "$delay_pid" 2>/dev/null || :; exit 0' HUP INT TERM
        sleep 15 &
        delay_pid=$!
        wait "$delay_pid" || exit 0
        : >"$call_dir/timed-out"
        kill -KILL "$command_pid" 2>/dev/null || :
    ) &
    timer_pid=$!
    wait "$command_pid"
    result=$?
    command_pid=
    kill "$timer_pid" 2>/dev/null || :
    wait "$timer_pid" 2>/dev/null || :
    timer_pid=
    if [ -f "$call_dir/timed-out" ]; then
        printf '%s\n' 'ADB 命令超时' >&2
        exit 1
    fi
    if [ "$result" -ne 0 ]; then
        printf '%s\n' 'ADB 命令失败，请检查设备连接或权限' >&2
        exit 1
    fi
    cat "$call_dir/output"
    cat "$call_dir/error" >&2
)

adb_shell() {
    remote_command=
    for argument do
        # adb joins shell arguments: quote once for the remote shell as well.
        quoted=$(printf '%s' "$argument" | sed "s/'/'\\\\''/g")
        remote_command="$remote_command '$quoted'"
    done
    run_adb -s "$device" shell "$remote_command"
}

settings() {
    settings_output=$(adb_shell settings "$@" 2>&1) || {
        printf '%s\n' "$settings_output" >&2; return 1;
    }
    if printf '%s\n' "$settings_output" | grep -Eiq 'SecurityException|Permission[[:space:]]+(denial|denied)|Error[[:space:]]+while'; then
        printf '%s\n' '设备拒绝读取或修改系统代理设置' >&2
        return 1
    fi
    printf '%s\n' "$settings_output" | tr -d '\r'
}

read_proxy() {
    proxy_clear=yes
    for key in http_proxy global_http_proxy_host global_http_proxy_port \
        global_http_proxy_exclusion_list global_proxy_pac_url http_proxy_pac_url; do
        value=$(settings get global "$key") || return 1
        case "$key:$value" in
            *:|*:null|http_proxy::0|global_http_proxy_port:0) ;;
            *) proxy_clear=no ;;
        esac
    done
}

if [ "$connect" = yes ]; then
    printf '%s\n' "$device" | grep -Eq '^([[:alnum:]_.-]+|\[[[:xdigit:]:]+\]):[0-9]+$' || bad_args '--connect 需要 HOST:PORT'
    run_adb connect "$device" >/dev/null || exit 2
fi
state=$(run_adb -s "$device" get-state) || exit 2
[ "$state" = device ] || { printf '%s\n' '设备未在线；未修改代理' >&2; exit 2; }
read_proxy || exit 1
printf '目标：%s\n' "$device"
printf '代理字段清洁：%s（字段为空仍可能残留运行中的代理）\n' "$proxy_clear"
if [ "$check_only" = no ]; then
    # Force a change even if ':0' is already saved. Deletion alone does not
    # invalidate ProxyTracker's running proxy. Never set a temporary real proxy.
    settings put global http_proxy '' >/dev/null || exit 1
    settings put global http_proxy :0 >/dev/null || exit 1
    settings put global global_http_proxy_host '' >/dev/null || exit 1
    settings put global global_http_proxy_port 0 >/dev/null || exit 1
    settings put global global_http_proxy_exclusion_list '' >/dev/null || exit 1
    settings delete global global_proxy_pac_url >/dev/null || exit 1
    settings delete global http_proxy_pac_url >/dev/null || exit 1
    read_proxy || exit 1
    [ "$proxy_clear" = yes ] || { printf '%s\n' '代理字段未清空，修复失败' >&2; exit 1; }
    printf '%s\n' '已重置运行中的全局代理并清理 HTTP/PAC 配置（http_proxy=:0）。'
fi

deadline=$(( $(date +%s) + wait_seconds ))
validated=no
previous=
while :; do
    raw=$(adb_shell dumpsys connectivity) || exit 1
    summary=$(printf '%s\n' "$raw" | awk '
        /Active default network:/ { default_id=$NF }
        /NetworkAgentInfo\{/ {
            id=$0; sub(/^.*network\{/, "", id); sub(/\}.*$/, "", id)
            if (!index($0, "nc{")) next
            caps=substr($0, index($0, "nc{")+3)
            transport=caps; sub(/^.*Transports: */, "", transport); sub(/ .*/, "", transport)
            gsub(/[^[:alnum:]_]/, " ", caps)
            if (caps !~ /(^| )INTERNET( |$)/) next
            valid=(caps ~ /(^| )VALIDATED( |$)/)
            printf "%s#%s=%s%s\n", transport, id, (valid ? "VALIDATED" : "未验证"), (id==default_id ? "（默认）" : "")
            if (id==default_id && valid) ready=1
        }
        END { printf "DEFAULT_VALIDATED=%d\n", ready }
    ') || exit 1
    if [ "$summary" != "$previous" ]; then
        printf '%s\n' "$summary" | sed '/^DEFAULT_VALIDATED=/d'
        previous=$summary
    fi
    if printf '%s\n' "$summary" | grep -q '^DEFAULT_VALIDATED=1$'; then validated=yes; break; fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 1
done

https_ok=unknown
curl_path=$(adb_shell sh -c 'command -v curl || :') || exit 1
if [ -n "$curl_path" ]; then
    https_ok=no
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        host=${url#https://}; host=${host%%[/?#]*}
        code=$(adb_shell curl --silent --show-error --output /dev/null \
            --write-out '%{http_code}' --connect-timeout 5 --max-time 10 "$url") || code=failed
        case "$code" in [23][0-9][0-9]) https_ok=yes ;; esac
        printf 'HTTPS %s：%s\n' "$host" "$code"
    done <<EOF
$urls
EOF
else
    printf '%s\n' '设备未提供 curl，HTTPS 结果以系统联网验证为准。'
fi
if [ "$proxy_clear" = yes ] && [ "$validated" = yes ] && [ "$https_ok" != no ]; then
    if [ "$check_only" = yes ]; then
        printf '%s\n' '检查完成：代理字段清洁，默认网络联网验证通过；未修改设置。'
    else
        printf '%s\n' '修复完成：全局代理已清除，默认网络联网验证通过。'
    fi
    exit 0
fi
printf '%s\n' '仍有代理配置或联网尚未完全确认；请检查设备连接、网络或 DNS。'
exit 2

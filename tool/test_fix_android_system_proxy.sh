#!/bin/sh
# Offline behavioral tests. Requires only POSIX shell and standard utilities.
set -eu
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repair="$script_dir/fix_android_system_proxy.sh"
shell_bin=${TEST_SHELL:-sh}
fixture=$(mktemp -d "${TMPDIR:-/tmp}/proxy-fix-test.XXXXXXXX")
trap 'find "$fixture" -type f -exec rm -- {} +; rmdir "$fixture"' 0
trap 'exit 130' INT
trap 'exit 143' HUP TERM
export FAKE_PROXY_DIR="$fixture"

cat >"$fixture/adb" <<'MOCK'
#!/bin/sh
set -eu
root=${FAKE_PROXY_DIR:?}
printf '%s\n' "$*" >>"$root/log"
if [ "$1" = connect ]; then printf 'connected to %s\n' "$2"; exit 0; fi
[ "$1" = -s ] || exit 1
shift 2
case "$1" in
    get-state) [ "${FAKE_MODE:-}" != offline ] || exit 1; echo device; exit 0 ;;
    shell) shift ;;
    *) exit 1 ;;
esac
# Decode the repair script's remote shell quoting, as adb's shell would.
eval "set -- $1"
case "$1" in
    settings)
        operation=$2; key=$4
        case "$operation" in
            get) if [ -f "$root/$key" ]; then cat "$root/$key"; else echo null; fi ;;
            put)
                if [ "${FAKE_MODE:-}" = denied ]; then echo 'SecurityException: Permission denial'; exit 0; fi
                previous=$(cat "$root/$key" 2>/dev/null || :)
                printf '%s\n' "$5" >"$root/$key"
                if [ "$key" = http_proxy ] && [ "$5" = :0 ] && [ "$previous" != :0 ]; then
                    printf 'cleared\n' >"$root/runtime"
                fi ;;
            delete) printf 'null\n' >"$root/$key" ;;
            *) exit 1 ;;
        esac ;;
    dumpsys)
        [ "${FAKE_MODE:-}" != missing ] || exit 0
        printf '%s\n' 'Active default network: 110'
        # IMS validation and historical scores must not pass Internet checks.
        printf '%s\n' 'NetworkAgentInfo{network{101} nc{[ Transports: CELLULAR Capabilities: IMS&VALIDATED ]}}'
        if [ "${FAKE_MODE:-}" = unvalidated ]; then caps='INTERNET&NOT_VPN'; else caps='INTERNET&NOT_VPN&VALIDATED'; fi
        printf 'NetworkAgentInfo{network{110} Score(EVER_VALIDATED&IS_VALIDATED) nc{[ Transports: WIFI Capabilities: %s ]}}\n' "$caps" ;;
    sh) [ "${FAKE_MODE:-}" = nocurl ] || echo /system/bin/curl ;;
    curl)
        while [ "$#" -gt 1 ]; do shift; done
        printf '%s\n' "$1" >"$root/url"
        [ "${FAKE_MODE:-}" != httpsfail ] || exit 1
        echo 204 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$fixture/adb"

fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$fixture/output" >&2; exit 1; }
passed=0
run_case() {
    expected=$1; shift
    : >"$fixture/log"
    if "$shell_bin" "$repair" fixture:5555 --adb "$fixture/adb" --wait 0 "$@" >"$fixture/output" 2>&1; then
        actual=0
    else
        actual=$?
    fi
    [ "$actual" -eq "$expected" ] || fail "expected exit $expected; actual $actual"
    if grep -Eq 'kill-server|disconnect|svc data' "$fixture/log"; then fail 'unrelated state modified'; fi
    passed=$((passed + 1))
}

# All saved fields absent, but the runtime proxy is still active.
printf '127.0.0.1:39091\n' >"$fixture/runtime"
run_case 0
[ "$(cat "$fixture/runtime")" = cleared ] || fail 'in-memory proxy remained'

# Idempotence: ':0' already stored must still cause a fresh runtime reset.
printf '127.0.0.1:39091\n' >"$fixture/runtime"
run_case 0
[ "$(cat "$fixture/runtime")" = cleared ] || fail 'repeated repair did not reset runtime'

for key in global_http_proxy_host global_http_proxy_port global_http_proxy_exclusion_list \
    global_proxy_pac_url http_proxy_pac_url; do
    printf 'stale\n' >"$fixture/$key"
done
run_case 0 --connect
grep -q '^connect fixture:5555$' "$fixture/log" || fail 'wireless transport not registered'
[ "$(cat "$fixture/global_proxy_pac_url")" = null ] || fail 'PAC remained'
[ "$(cat "$fixture/http_proxy_pac_url")" = null ] || fail 'vendor PAC remained'
[ "$(cat "$fixture/global_http_proxy_port")" = 0 ] || fail 'port remained'

run_case 0 --check-only
if grep -Eq "'settings' '(put|delete)'" "$fixture/log"; then fail 'check-only modified settings'; fi
printf '127.0.0.1\n' >"$fixture/global_http_proxy_host"
run_case 2 --check-only
run_case 0

FAKE_MODE=offline; export FAKE_MODE
run_case 2
if grep -q 'shell' "$fixture/log"; then fail 'offline device reached settings'; fi
FAKE_MODE=denied
run_case 1
FAKE_MODE=unvalidated
run_case 2
FAKE_MODE=missing
run_case 2
FAKE_MODE=httpsfail
run_case 2
FAKE_MODE=nocurl
run_case 0
FAKE_MODE=

# Shell metacharacters stay literal on the remote side; never evaluated.
url="https://example.test/?a=1&b='literal';touch $fixture/INJECTED"
run_case 0 --url "$url"
[ ! -e "$fixture/INJECTED" ] || fail 'URL caused command injection'
[ "$(cat "$fixture/url")" = "$url" ] || fail 'URL changed during quoting'
run_case 3 --url 'https://user:password@example.test/'
run_case 3 --wait 61
run_case 0 --wait 00
printf 'PASS: %s offline shell cases\n' "$passed"

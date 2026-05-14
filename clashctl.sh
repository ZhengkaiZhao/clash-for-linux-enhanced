#!/usr/bin/env bash

set -u

CLASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CLASH_DIR}/.env"
CONF_FILE="${CLASH_DIR}/conf/config.yaml"
SECRET_FILE="${HOME}/.clash_secret"

if [[ -r "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

CLASH_HTTP_PORT=${CLASH_HTTP_PORT:-7890}
CLASH_SOCKS_PORT=${CLASH_SOCKS_PORT:-7891}
EXTERNAL_CONTROLLER=${EXTERNAL_CONTROLLER:-0.0.0.0:9090}
CLASH_API_PORT="${EXTERNAL_CONTROLLER##*:}"
[[ "$CLASH_API_PORT" =~ ^[0-9]+$ ]] || CLASH_API_PORT=9090
CLASH_API_URL="http://127.0.0.1:${CLASH_API_PORT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

load_secret() {
    if [[ -n "${CLASH_SECRET:-}" ]]; then
        printf '%s\n' "$CLASH_SECRET"
        return 0
    fi

    if [[ -r "$SECRET_FILE" ]]; then
        local saved=""
        saved=$(sed -n -E "s/^export[[:space:]]+CLASH_SECRET=['\"]?([^'\"]*)['\"]?.*$/\1/p" "$SECRET_FILE" | head -1)
        if [[ -n "$saved" ]]; then
            printf '%s\n' "$saved"
            return 0
        fi
    fi

    if [[ -r "$CONF_FILE" ]]; then
        sed -n -E "s/^[[:space:]]*secret:[[:space:]]*['\"]?([^'\"#]+)['\"]?[[:space:]]*(#.*)?$/\1/p" "$CONF_FILE" | head -1
    fi
}

SECRET="$(load_secret)"

need_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}需要 python3 解析 Clash API JSON。${NC}" >&2
        exit 1
    fi
}

api() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    local -a args

    args=(-sS --connect-timeout 3 -m 10 -H "Authorization: Bearer ${SECRET}")
    if [[ "$method" != "GET" ]]; then
        args+=(-X "$method" -H "Content-Type: application/json")
        [[ -n "$data" ]] && args+=(-d "$data")
    fi

    curl "${args[@]}" "${CLASH_API_URL}${path}"
}

api_code() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    local -a args

    args=(-sS -o /dev/null -w "%{http_code}" --connect-timeout 3 -m 10 -H "Authorization: Bearer ${SECRET}")
    if [[ "$method" != "GET" ]]; then
        args+=(-X "$method" -H "Content-Type: application/json")
        [[ -n "$data" ]] && args+=(-d "$data")
    fi

    curl "${args[@]}" "${CLASH_API_URL}${path}" 2>/dev/null || true
}

urlencode() {
    need_python
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

json_string() {
    need_python
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

ensure_api() {
    local response
    response=$(api GET /version 2>/dev/null || true)
    if echo "$response" | grep -q '"version"'; then
        return 0
    fi

    echo -e "${RED}无法连接 Clash API: ${CLASH_API_URL}${NC}" >&2
    echo -e "${YELLOW}请先启动 Clash：source ${CLASH_DIR}/start.sh${NC}" >&2
    [[ -z "$SECRET" ]] && echo -e "${YELLOW}未找到 CLASH_SECRET，检查 ${SECRET_FILE} 或 conf/config.yaml。${NC}" >&2
    exit 1
}

proxies_json() {
    api GET /proxies
}

groups() {
    ensure_api
    need_python
    proxies_json | python3 -c '
import json, sys
payload = json.load(sys.stdin)
proxies = payload.get("proxies", {})
for name, info in proxies.items():
    if isinstance(info, dict) and isinstance(info.get("all"), list) and info["all"]:
        now = info.get("now", "")
        count = len(info.get("all", []))
        print(f"{name}\t{now}\t{count}")
' | awk -F '\t' 'BEGIN { printf "可切换策略组：\n" } { printf "  [%d] %s%s  (%s 个选项)\n", NR, $1, ($2 ? " -> " $2 : ""), $3 }'
}

default_group() {
    need_python
    proxies_json | python3 -c '
import json, sys
payload = json.load(sys.stdin)
proxies = payload.get("proxies", {})
preferred = [
    "Proxies",
    "Proxy",
    "PROXY",
    "节点选择",
    "AI_Services_ChatGPT_Claude",
    "GLOBAL",
    "Final",
]
for name in preferred:
    info = proxies.get(name)
    if isinstance(info, dict) and isinstance(info.get("all"), list) and info["all"]:
        print(name)
        raise SystemExit
for name, info in proxies.items():
    if isinstance(info, dict) and isinstance(info.get("all"), list) and info["all"]:
        print(name)
        raise SystemExit
'
}

nodes() {
    ensure_api
    need_python
    local group="${1:-}"
    [[ -z "$group" ]] && group="$(default_group)"
    if [[ -z "$group" ]]; then
        echo -e "${RED}未找到可切换策略组。${NC}" >&2
        return 1
    fi

    proxies_json | GROUP="$group" python3 -c '
import json, os, sys
group = os.environ["GROUP"]
payload = json.load(sys.stdin)
proxies = payload.get("proxies", {})
info = proxies.get(group)
if not isinstance(info, dict) or not isinstance(info.get("all"), list):
    print(f"策略组不存在或不可切换: {group}", file=sys.stderr)
    raise SystemExit(1)
print(f"策略组: {group}")
print("当前: " + str(info.get("now", "")))
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
for idx, name in enumerate(info.get("all", []), 1):
    node = proxies.get(name, {})
    history = node.get("history") if isinstance(node, dict) else None
    delay = ""
    if history:
        try:
            value = history[-1].get("delay")
            if isinstance(value, int) and value > 0:
                delay = f"  ({value}ms)"
        except Exception:
            pass
    marker = " *" if name == info.get("now") else ""
    print(f"[{idx}] {name}{delay}{marker}")
'
}

switch_node() {
    ensure_api
    need_python
    local group="${1:-}"
    local node="${2:-}"

    if [[ -z "$group" ]]; then
        group="$(default_group)"
    fi

    if [[ -z "$node" ]]; then
        nodes "$group" || return 1
        local selection
        printf "请选择节点编号或完整节点名: "
        IFS= read -r selection
        [[ -z "$selection" ]] && return 1
        node=$(proxies_json | GROUP="$group" SELECTION="$selection" python3 -c '
import json, os, sys
payload = json.load(sys.stdin)
group = os.environ["GROUP"]
selection = os.environ["SELECTION"]
items = payload.get("proxies", {}).get(group, {}).get("all", [])
if selection.isdigit():
    idx = int(selection)
    if 1 <= idx <= len(items):
        print(items[idx - 1])
        raise SystemExit
print(selection)
')
    fi

    local group_path code node_json
    group_path="$(urlencode "$group")"
    node_json="$(json_string "$node")"
    code=$(api_code PUT "/proxies/${group_path}" "{\"name\":${node_json}}")
    if echo "$code" | grep -Eq '^2[0-9]{2}$'; then
        echo -e "${GREEN}✓ 节点切换成功: ${group} -> ${node}${NC}"
        return 0
    fi

    echo -e "${RED}✗ 节点切换失败: HTTP ${code}${NC}" >&2
    return 1
}

mode() {
    ensure_api
    local value="${1:-}"
    case "${value,,}" in
        rule|rules) value="Rule" ;;
        global) value="Global" ;;
        direct) value="Direct" ;;
        "")
            local current
            current=$(api GET /configs 2>/dev/null | sed -n -E 's/.*"mode"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')
            echo "当前模式: ${current:-未知}"
            return 0
            ;;
        *)
            echo -e "${RED}模式只能是 rule、global 或 direct。${NC}" >&2
            return 1
            ;;
    esac

    local code
    code=$(api_code PATCH /configs "{\"mode\":\"${value}\"}")
    if echo "$code" | grep -Eq '^2[0-9]{2}$'; then
        echo -e "${GREEN}✓ 代理模式已切换为 ${value}${NC}"
        return 0
    fi

    echo -e "${RED}✗ 代理模式切换失败: HTTP ${code}${NC}" >&2
    return 1
}

strategy() {
    echo "可用代理策略："
    echo "[1] 系统代理 - Rule 模式"
    echo "[2] 全局代理 - Global 模式"
    echo "[3] 直连模式 - Direct 模式"
    printf "请选择 [1-3] (默认 1): "
    local choice
    IFS= read -r choice
    [[ -z "$choice" ]] && choice=1
    case "$choice" in
        1) mode rule ;;
        2) mode global ;;
        3) mode direct ;;
        *) echo -e "${RED}无效选择。${NC}" >&2; return 1 ;;
    esac
}

print_env() {
    local state="${1:-on}"
    if [[ "$state" == "off" ]]; then
        cat <<'EOF'
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
EOF
        return 0
    fi

    cat <<EOF
export http_proxy="http://127.0.0.1:${CLASH_HTTP_PORT}"
export https_proxy="http://127.0.0.1:${CLASH_HTTP_PORT}"
export HTTP_PROXY="http://127.0.0.1:${CLASH_HTTP_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${CLASH_HTTP_PORT}"
export all_proxy="socks5h://127.0.0.1:${CLASH_SOCKS_PORT}"
export ALL_PROXY="socks5h://127.0.0.1:${CLASH_SOCKS_PORT}"
export no_proxy="127.0.0.1,localhost,::1"
export NO_PROXY="127.0.0.1,localhost,::1"
EOF
}

status() {
    local running="否"
    pgrep -f "${CLASH_DIR}/bin/clash-linux" >/dev/null 2>&1 && running="是"
    echo "Clash 运行中: ${running}"
    echo "HTTP 代理: http://127.0.0.1:${CLASH_HTTP_PORT}"
    echo "SOCKS 代理: socks5h://127.0.0.1:${CLASH_SOCKS_PORT}"
    echo "Dashboard: ${CLASH_API_URL}/ui"
    if api GET /version >/dev/null 2>&1; then
        mode
        local group
        group="$(default_group 2>/dev/null || true)"
        [[ -n "$group" ]] && nodes "$group" | sed -n '1,2p'
    else
        echo "API 状态: 不可用"
    fi
}

test_url() {
    local name="$1"
    local url="$2"
    local expect="${3:-}"
    local success_msg="${4:-HTTP 可达}"
    local warn_403="${5:-false}"
    local output code time err_file ms retry_reason
    err_file=$(mktemp) || return 1
    output=$(curl -sS -o /dev/null -w "%{http_code} %{time_total}" \
        --connect-timeout 8 --max-time 15 \
        -x "http://127.0.0.1:${CLASH_HTTP_PORT}" "$url" 2>"$err_file" || true)
    if [[ "$output" =~ ^([0-9]{3})[[:space:]]+([0-9.]+)$ ]]; then
        code="${BASH_REMATCH[1]}"
        time="${BASH_REMATCH[2]}"
        retry_reason=""
        if ! [[ -z "$expect" || "$code" =~ $expect ]] && grep -Eqi 'SSL|TLS|unexpected eof|decode error' "$err_file"; then
            retry_reason="TLS 1.2 fallback"
            : > "$err_file"
            output=$(curl -sS -o /dev/null -w "%{http_code} %{time_total}" \
                --tls-max 1.2 \
                --connect-timeout 8 --max-time 15 \
                -x "http://127.0.0.1:${CLASH_HTTP_PORT}" "$url" 2>"$err_file" || true)
            if [[ "$output" =~ ^([0-9]{3})[[:space:]]+([0-9.]+)$ ]]; then
                code="${BASH_REMATCH[1]}"
                time="${BASH_REMATCH[2]}"
            else
                code="000"
                time="0"
            fi
        fi

        ms=$(awk "BEGIN {printf \"%d\", $time * 1000}" 2>/dev/null || echo "?")
        if [[ -z "$expect" || "$code" =~ $expect ]]; then
            if [[ -n "$retry_reason" ]]; then
                echo -e "${GREEN}✓ ${name}: HTTP ${code}, ${ms}ms，${success_msg}（${retry_reason}）${NC}"
            else
                echo -e "${GREEN}✓ ${name}: HTTP ${code}, ${ms}ms，${success_msg}${NC}"
            fi
            rm -f "$err_file"
            return 0
        fi

        if [[ "$warn_403" == "true" && "$code" == "403" ]]; then
            echo -e "${YELLOW}! ${name}: HTTP 403, ${ms}ms，网络可达但当前节点被服务拒绝${NC}"
            rm -f "$err_file"
            return 2
        fi

        echo -e "${YELLOW}! ${name}: HTTP ${code}, ${ms}ms${NC}"
        rm -f "$err_file"
        return 2
    fi

    if [[ -s "$err_file" ]]; then
        echo -e "${RED}✗ ${name}: $(tail -1 "$err_file")${NC}"
    else
        echo -e "${RED}✗ ${name}: curl failed${NC}"
    fi
    rm -f "$err_file"
    return 1
}

test_proxy() {
    echo "测试本地代理端口..."
    if ! (echo >"/dev/tcp/127.0.0.1/${CLASH_HTTP_PORT}") >/dev/null 2>&1; then
        echo -e "${RED}✗ HTTP 代理端口不可用: 127.0.0.1:${CLASH_HTTP_PORT}${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ HTTP 代理端口可用${NC}"

    local failed=0
    test_url "OpenAI API" "https://api.openai.com/v1/models" '^(200|401)$' "OpenAI API 可达（未带 API Key 返回 401 属正常）" true || failed=1
    test_url "ChatGPT Web" "https://chatgpt.com/cdn-cgi/trace" '^(200)$' "ChatGPT Web 可达" true || failed=1
    test_url "Google 204" "https://www.gstatic.com/generate_204" '^(204|200)$' "Google 204 探针可达" false || failed=1

    if [[ "$failed" -ne 0 ]]; then
        echo -e "${YELLOW}提示：HTTP 000 通常是节点不可用、DNS 未经代理、或远端主动断开。Codex/AI CLI 请确保新终端已 source shell_proxy.sh，或执行 eval \"\$(${CLASH_DIR}/clashctl.sh env)\"。${NC}"
        echo -e "${YELLOW}OpenAI/ChatGPT 返回 403 则多半是当前节点地区/IP 被服务端拒绝，建议切到 TW/JP/SG/US 中可用节点。${NC}"
    fi
}

usage() {
    cat <<EOF
用法:
  ./clashctl.sh status
  ./clashctl.sh groups
  ./clashctl.sh nodes [策略组]
  ./clashctl.sh switch [策略组] [节点名]
  ./clashctl.sh mode [rule|global|direct]
  ./clashctl.sh strategy
  ./clashctl.sh test
  ./clashctl.sh env [on|off]

常用:
  ./clashctl.sh switch AI_Services_ChatGPT_Claude "🇨🇳 Taiwan | 01"
  ./clashctl.sh mode global
  eval "\$(./clashctl.sh env)"
EOF
}

cmd="${1:-status}"
shift || true

case "$cmd" in
    status) status "$@" ;;
    groups) groups "$@" ;;
    nodes|list) nodes "$@" ;;
    switch|node) switch_node "$@" ;;
    mode) mode "$@" ;;
    strategy) strategy "$@" ;;
    test) test_proxy "$@" ;;
    env) print_env "${1:-on}" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac

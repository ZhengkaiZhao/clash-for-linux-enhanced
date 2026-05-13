#!/bin/bash
# 使用方式: source ./start.sh  或  . ./start.sh
# 直接执行 ./start.sh 将报错，必须通过 source 让代理变量在当前 Shell 生效

#################### 必须通过 source 执行 ####################

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo -e "\033[31m[ERROR] 请使用 source 命令执行此脚本，否则代理环境变量无法在当前终端生效：\033[0m"
    echo -e "  source ${0}"
    echo -e "  或: . ${0}"
    exit 1
fi

#################### 脚本初始化任务 ####################

export Server_Dir=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

# 确保 .env 可读（可能由 root 创建导致权限不足）
if [[ -f "$Server_Dir/.env" && ! -r "$Server_Dir/.env" ]]; then
    sudo chmod 644 "$Server_Dir/.env" 2>/dev/null || {
        echo -e "\033[31m[ERROR] .env 文件无读取权限，请执行: sudo chmod 644 $Server_Dir/.env\033[0m"
        return 1
    }
fi
source $Server_Dir/.env

chmod +x $Server_Dir/bin/* 2>/dev/null
chmod +x $Server_Dir/scripts/* 2>/dev/null
chmod +x $Server_Dir/tools/subconverter/subconverter 2>/dev/null

Conf_Dir="$Server_Dir/conf"
Temp_Dir="$Server_Dir/temp"
Log_Dir="$Server_Dir/logs"
DOT_ENV_FILE="$Server_Dir/.env"
SECRET_FILE="$HOME/.clash_secret"
SUBSCRIPTION_FILE="$HOME/.clash_subscriptions"

URL=${CLASH_URL:?Error: CLASH_URL variable is not set or empty}
Secret=${CLASH_SECRET:-$(openssl rand -hex 32)}
Secret=${Secret//$'\r'/}
Secret=${Secret//$'\n'/}
CLASH_HTTP_PORT=${CLASH_HTTP_PORT:-7890}
CLASH_SOCKS_PORT=${CLASH_SOCKS_PORT:-7891}
CLASH_REDIR_PORT=${CLASH_REDIR_PORT:-7892}
CLASH_LISTEN_IP=${CLASH_LISTEN_IP:-0.0.0.0}
CLASH_ALLOW_LAN=${CLASH_ALLOW_LAN:-true}
EXTERNAL_CONTROLLER_ENABLED=${EXTERNAL_CONTROLLER_ENABLED:-true}
EXTERNAL_CONTROLLER=${EXTERNAL_CONTROLLER:-0.0.0.0:9090}

CLASH_API_PORT="${EXTERNAL_CONTROLLER##*:}"
[[ "$CLASH_API_PORT" =~ ^[0-9]+$ ]] || CLASH_API_PORT=9090
CLASH_API_URL="http://127.0.0.1:${CLASH_API_PORT}"

SELECTED_PROXY=""
PROXY_MODE=""
SELECTOR_GROUP=""
SYSTEM_PROXY_STATE="未设置"

#################### 颜色定义 ####################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

#################### 函数定义 ####################

success() {
    echo -en "\\033[60G[\\033[1;32m  OK  \\033[0;39m]\r"
    return 0
}

failure() {
    local rc=$?
    echo -en "\\033[60G[\\033[1;31mFAILED\\033[0;39m]\r"
    return $rc
}

action() {
    local STRING rc
    STRING=$1
    echo -n "$STRING "
    shift
    "$@" && success "$STRING" || failure "$STRING"
    rc=$?
    echo
    return $rc
}

if_success() {
    local ReturnStatus=$3
    if [ $ReturnStatus -eq 0 ]; then
        action "$1" /bin/true
    else
        action "$2" /bin/false
        return 1
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}[!] 注意：部分操作（如清除 /etc/profile.d/clash.sh）需要 sudo 权限${NC}"
        echo -e "${YELLOW}    若遇到权限问题，请以 sudo 环境执行: sudo -E bash -c 'source ${BASH_SOURCE[0]}'${NC}"
    fi
}

# 通过 /dev/tty 读取输入，兼容 source 执行
read_tty() {
    local __var_name="$1"
    local __prompt="${2:-}"

    if [[ ! -r /dev/tty ]]; then
        echo -e "\033[31m[ERROR] 当前会话不可交互，无法读取输入\033[0m"
        return 1
    fi

    printf "%b" "$__prompt" > /dev/tty
    IFS= read -r "$__var_name" < /dev/tty
}

extract_clash_url_from_env() {
    if [[ -f "$DOT_ENV_FILE" ]]; then
        grep -E '^export[[:space:]]+CLASH_URL=' "$DOT_ENV_FILE" | head -1 | sed -E 's/^export[[:space:]]+CLASH_URL=["'"'"']?([^"'"'"']*)["'"'"']?$/\1/'
    fi
}

update_env_clash_url() {
    local new_url="$1"
    local escaped_url tmp_file

    escaped_url=${new_url//\\/\\\\}
    escaped_url=${escaped_url//\"/\\\"}
    tmp_file=$(mktemp) || return 1

    if [[ -f "$DOT_ENV_FILE" ]]; then
        if ! awk -v url="$escaped_url" '
            BEGIN { found = 0 }
            /^export[[:space:]]+CLASH_URL=/ {
                print "export CLASH_URL=\"" url "\""
                found = 1
                next
            }
            { print }
            END {
                if (!found) {
                    print "export CLASH_URL=\"" url "\""
                }
            }
        ' "$DOT_ENV_FILE" > "$tmp_file"; then
            rm -f "$tmp_file"
            return 1
        fi
    else
        cat > "$tmp_file" << EOF
export CLASH_URL="$escaped_url"
export CLASH_SECRET=""
export CLASH_HEADERS="User-Agent: ClashforWindows/0.20.39"
export CLASH_HTTP_PORT=7890
export CLASH_SOCKS_PORT=7891
export CLASH_REDIR_PORT=7892
export CLASH_LISTEN_IP=0.0.0.0
export CLASH_ALLOW_LAN=true
export EXTERNAL_CONTROLLER_ENABLED=true
export EXTERNAL_CONTROLLER=0.0.0.0:9090
EOF
    fi

    if ! command mv -f "$tmp_file" "$DOT_ENV_FILE"; then
        rm -f "$tmp_file"
        return 1
    fi
    chmod 644 "$DOT_ENV_FILE" 2>/dev/null || true
}

extract_secret_from_config() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 1

    sed -n -E "s/^[[:space:]]*secret:[[:space:]]*['\"]?([^'\"#]+)['\"]?[[:space:]]*(#.*)?$/\1/p" "$config_file" | head -1
}

ensure_config_secret() {
    local config_file="$1"
    local secret_value="$2"
    local tmp_file

    [[ -z "$config_file" || -z "$secret_value" ]] && return 1
    tmp_file=$(mktemp) || return 1

    if ! awk -v sec="$secret_value" '
        BEGIN { found = 0 }
        /^[[:space:]]*secret:[[:space:]]*/ {
            print "secret: \"" sec "\""
            found = 1
            next
        }
        { print }
        END {
            if (!found) {
                print "secret: \"" sec "\""
            }
        }
    ' "$config_file" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    if ! command mv -f "$tmp_file" "$config_file"; then
        rm -f "$tmp_file"
        return 1
    fi
}

get_subscription_info() {
    local url="$1"
    local temp_file http_code userinfo
    local upload download total expire used
    local traffic_info="未知"
    local expire_info="未知"
    local -a header_args

    temp_file=$(mktemp) || return 1

    if [[ -n "$CLASH_HEADERS" ]]; then
        header_args=(-H "$CLASH_HEADERS")
    else
        header_args=(-H "User-Agent: ClashforWindows/0.20.39")
    fi

    http_code=$(curl -sS -L -o /dev/null -D "$temp_file" --connect-timeout 10 -m 15 -w "%{http_code}" "${header_args[@]}" "$url" 2>/dev/null || true)

    if ! echo "$http_code" | grep -Eq '^[23][0-9]{2}$'; then
        rm -f "$temp_file"
        return 1
    fi

    userinfo=$(grep -i '^subscription-userinfo:' "$temp_file" | head -1 | cut -d: -f2- | tr -d '\r\n')
    rm -f "$temp_file"

    if [[ -n "$userinfo" ]]; then
        upload=$(echo "$userinfo" | sed -n 's/.*upload=\([0-9][0-9]*\).*/\1/p')
        download=$(echo "$userinfo" | sed -n 's/.*download=\([0-9][0-9]*\).*/\1/p')
        total=$(echo "$userinfo" | sed -n 's/.*total=\([0-9][0-9]*\).*/\1/p')
        expire=$(echo "$userinfo" | sed -n 's/.*expire=\([0-9][0-9]*\).*/\1/p')

        upload=${upload:-0}
        download=${download:-0}
        total=${total:-0}
        expire=${expire:-0}
        used=$((upload + download))

        if [[ "$total" -gt 0 ]]; then
            traffic_info=$(awk -v u="$used" -v t="$total" 'BEGIN { printf "%.2f GB / %.2f GB", u/1024/1024/1024, t/1024/1024/1024 }')
        fi

        if [[ "$expire" -gt 0 ]]; then
            expire_info=$(date -d "@$expire" "+%Y-%m-%d" 2>/dev/null || echo "未知")
        fi
    fi

    echo "${traffic_info}|${expire_info}"
    return 0
}

save_subscription_info() {
    local url="$1"
    local name="$2"
    local traffic="$3"
    local expire="$4"
    local temp_file

    if [[ ! -f "$SUBSCRIPTION_FILE" ]]; then
        echo "# Clash subscriptions" > "$SUBSCRIPTION_FILE"
    fi

    temp_file=$(mktemp) || return 1
    grep -vF "URL=${url}|" "$SUBSCRIPTION_FILE" > "$temp_file" 2>/dev/null || true
    echo "URL=${url}|NAME=${name}|TRAFFIC=${traffic}|EXPIRE=${expire}" >> "$temp_file"

    command mv -f "$temp_file" "$SUBSCRIPTION_FILE"
    chmod 600 "$SUBSCRIPTION_FILE" 2>/dev/null || true
}

add_new_subscription() {
    local new_url sub_name info traffic expire retry

    echo -e "\n\033[36m添加新订阅\033[0m"
    echo -e "\033[36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

    while true; do
        read_tty new_url "\033[35m请输入订阅地址(URL): \033[0m" || return 1

        if [[ -z "$new_url" ]]; then
            echo -e "\033[31m订阅地址不能为空\033[0m"
            continue
        fi

        echo -e "\033[33m正在验证订阅地址...\033[0m"
        info=$(get_subscription_info "$new_url" 2>/dev/null || true)
        if [[ -z "$info" ]]; then
            echo -e "\033[31m✗ 订阅地址验证失败\033[0m"
            read_tty retry "\033[35m是否重试? [Y/n]: \033[0m" || return 1
            [[ "$retry" =~ ^[Nn]$ ]] && return 1
            continue
        fi

        traffic="${info%%|*}"
        expire="${info##*|}"

        read_tty sub_name "\033[35m请为该订阅命名(默认: Clash订阅): \033[0m" || return 1
        sub_name=${sub_name:-Clash订阅}

        if ! update_env_clash_url "$new_url"; then
            echo -e "\033[31m✗ 更新 .env 失败\033[0m"
            return 1
        fi

        URL="$new_url"
        save_subscription_info "$new_url" "$sub_name" "$traffic" "$expire"

        echo -e "\033[32m✓ 已设置订阅: $sub_name\033[0m"
        echo -e "\033[32m  流量: $traffic\033[0m"
        echo -e "\033[32m  过期: $expire\033[0m"
        return 0
    done
}

manage_subscriptions() {
    local current_url current_info current_valid=false
    local current_traffic="未知" current_expire="未知"
    local selection del_idx confirm

    declare -a sub_urls
    declare -a sub_names
    declare -a sub_traffics
    declare -a sub_expires

    current_url=$(extract_clash_url_from_env)
    [[ -z "$current_url" ]] && current_url="$URL"

    if [[ -n "$current_url" ]]; then
        current_info=$(get_subscription_info "$current_url" 2>/dev/null || true)
        if [[ -n "$current_info" ]]; then
            current_valid=true
            current_traffic="${current_info%%|*}"
            current_expire="${current_info##*|}"
        fi
    fi

    if [[ -f "$SUBSCRIPTION_FILE" ]]; then
        local line url name traffic expire idx
        idx=1
        while IFS= read -r line; do
            [[ "$line" =~ ^URL= ]] || continue

            url=$(echo "$line" | sed -n 's/^URL=\([^|]*\).*/\1/p')
            name=$(echo "$line" | sed -n 's/.*|NAME=\([^|]*\).*/\1/p')
            traffic=$(echo "$line" | sed -n 's/.*|TRAFFIC=\([^|]*\).*/\1/p')
            expire=$(echo "$line" | sed -n 's/.*|EXPIRE=\([^|]*\).*/\1/p')

            [[ -z "$url" ]] && continue
            [[ -z "$name" ]] && name="订阅${idx}"
            [[ -z "$traffic" ]] && traffic="未知"
            [[ -z "$expire" ]] && expire="未知"

            sub_urls[$idx]="$url"
            sub_names[$idx]="$name"
            sub_traffics[$idx]="$traffic"
            sub_expires[$idx]="$expire"
            ((idx++))
        done < "$SUBSCRIPTION_FILE"
    fi

    echo -e "\n\033[33m[3/8] 订阅管理（可选）...\033[0m"

    if [[ ${#sub_urls[@]} -eq 0 ]]; then
        if [[ "$current_valid" == true ]]; then
            echo -e "  \033[32m[√] 使用当前订阅\033[0m"
            echo -e "  流量: ${current_traffic}"
            echo -e "  过期: ${current_expire}"
            save_subscription_info "$current_url" "当前订阅" "$current_traffic" "$current_expire"
            URL="$current_url"
            return 0
        fi

        echo -e "  [33m[!] 当前未发现可用订阅记录[0m"
        export USE_LOCAL_CONFIG=false
        if [[ -f "$Conf_Dir/config.yaml" ]]; then
            read_tty use_local "[35m检测到本地已存在 config.yaml，是否直接使用？ [Y/n]: [0m" || return 1
            if [[ -z "$use_local" || "$use_local" =~ ^[Yy]$ ]]; then
                export USE_LOCAL_CONFIG=true
                echo -e "  [32m[√] 已选择使用本地 config.yaml[0m"
                return 0
            fi
        fi
        add_new_subscription || return 1
        return 0
    fi

    echo -e "\033[36m可用订阅列表：\033[0m"
    echo -e "\033[36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

    local i
    for ((i = 1; i <= ${#sub_urls[@]}; i++)); do
        [[ -z "${sub_urls[$i]}" ]] && continue
        echo -e "[${i}] ${sub_names[$i]}"
        echo -e "    流量: ${sub_traffics[$i]}"
        echo -e "    过期: ${sub_expires[$i]}"
        if [[ "${sub_urls[$i]}" == "$current_url" ]]; then
            echo -e "    \033[32m[当前使用]\033[0m"
        fi
    done

    echo -e "\033[36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "[0] 添加新订阅"
    echo -e "[dN] 删除订阅（例如 d1）"
    if [[ -f "$Conf_Dir/config.yaml" ]]; then
        echo -e "[L] 本地模式：跳过在线获取，直接使用本地 config.yaml"
    fi

    while true; do
        read_tty selection "[35m请选择订阅 [1-${#sub_urls[@]}] / 0 / dN / L (回车保持当前): [0m" || return 1

        if [[ -z "$selection" ]]; then
            if [[ "$current_valid" == true ]]; then
                URL="$current_url"
                echo -e "\033[32m✓ 保持当前订阅\033[0m"
                return 0
            fi
            echo -e "\033[31m当前订阅不可用，请选择其他订阅或添加新订阅\033[0m"
            continue
        fi

        if [[ "$selection" == "0" ]]; then
            add_new_subscription || return 1
            return 0
        fi

        if [[ "${selection,,}" == "l" ]] && [[ -f "$Conf_Dir/config.yaml" ]]; then
            export USE_LOCAL_CONFIG=true
            echo -e "[32m✓ 切换为本地模式，将使用现有的 config.yaml[0m"
            return 0
        fi

        if [[ "$selection" =~ ^d[0-9]+$ ]]; then
            del_idx="${selection#d}"
            if [[ -n "${sub_urls[$del_idx]}" ]]; then
                read_tty confirm "\033[35m确认删除 ${sub_names[$del_idx]} ? [y/N]: \033[0m" || return 1
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    local tmp_file
                    tmp_file=$(mktemp) || return 1
                    grep -vF "URL=${sub_urls[$del_idx]}|" "$SUBSCRIPTION_FILE" > "$tmp_file" 2>/dev/null || true
                    command mv -f "$tmp_file" "$SUBSCRIPTION_FILE"
                    chmod 600 "$SUBSCRIPTION_FILE" 2>/dev/null || true
                    echo -e "\033[32m✓ 已删除订阅 ${sub_names[$del_idx]}\033[0m"
                    manage_subscriptions
                    return $?
                fi
                echo -e "\033[33m已取消删除\033[0m"
                continue
            fi
            echo -e "\033[31m无效的删除编号\033[0m"
            continue
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ -n "${sub_urls[$selection]}" ]]; then
            local selected_url selected_name selected_info selected_traffic selected_expire
            selected_url="${sub_urls[$selection]}"
            selected_name="${sub_names[$selection]}"

            selected_info=$(get_subscription_info "$selected_url" 2>/dev/null || true)
            if [[ -z "$selected_info" ]]; then
                echo -e "\033[31m✗ 订阅 ${selected_name} 验证失败，请重新选择\033[0m"
                continue
            fi

            selected_traffic="${selected_info%%|*}"
            selected_expire="${selected_info##*|}"

            if ! update_env_clash_url "$selected_url"; then
                echo -e "\033[31m✗ 更新 .env 失败\033[0m"
                return 1
            fi

            URL="$selected_url"
            save_subscription_info "$selected_url" "$selected_name" "$selected_traffic" "$selected_expire"
            echo -e "\033[32m✓ 已切换到订阅: ${selected_name}\033[0m"
            echo -e "\033[32m  流量: ${selected_traffic}\033[0m"
            echo -e "\033[32m  过期: ${selected_expire}\033[0m"
            return 0
        fi

        echo -e "\033[31m无效输入，请重试\033[0m"
    done
}

save_secret_persist() {
    echo -e "\n\033[33m[附加] 正在保存 Secret...\033[0m"

    printf "export CLASH_SECRET='%s'\n" "$Secret" > "$SECRET_FILE" || return 1
    chmod 600 "$SECRET_FILE" 2>/dev/null || true
    export CLASH_SECRET="$Secret"

    local shell_rc
    for shell_rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        touch "$shell_rc"
        if ! grep -Fq "[ -f \"$SECRET_FILE\" ] && source \"$SECRET_FILE\"" "$shell_rc"; then
            echo "" >> "$shell_rc"
            echo "# Clash Secret (auto generated)" >> "$shell_rc"
            echo "[ -f \"$SECRET_FILE\" ] && source \"$SECRET_FILE\"" >> "$shell_rc"
        fi
    done

    echo -e "  \033[32m[√] Secret 已保存到 ${SECRET_FILE}\033[0m"
}

test_clash_api() {
    local response body version attempt max_attempts=5 wait_secs=2
    local switched_secret=false config_secret

    echo -e "\n\033[33m[附加] 正在测试 Clash API 连接...\033[0m"

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        response=$(curl -sS --connect-timeout 3 -m 8 \
            -H "Authorization: Bearer ${Secret}" \
            "${CLASH_API_URL}/version" 2>/dev/null || true)
        body="$response"

        if echo "$body" | grep -q '"version"'; then
            version=$(echo "$body" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            version=${version:-未知}
            echo -e "  \033[32m[√] API 连接成功（第 ${attempt} 次），Clash 版本: ${version}\033[0m"
            return 0
        fi

        if echo "$body" | grep -qi 'Unauthorized' && [[ "$switched_secret" == false ]]; then
            config_secret=$(extract_secret_from_config "$Conf_Dir/config.yaml" 2>/dev/null || true)
            if [[ -n "$config_secret" && "$config_secret" != "$Secret" ]]; then
                echo -e "  \033[33m[!] 检测到 API 鉴权失败，改用 config.yaml 中的 secret 重试\033[0m"
                Secret="$config_secret"
                export CLASH_SECRET="$Secret"
                printf "export CLASH_SECRET='%s'\n" "$Secret" > "$SECRET_FILE" 2>/dev/null || true
                switched_secret=true
                continue
            fi
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            echo -e "  \033[33m[!] 第 ${attempt}/${max_attempts} 次 API 连接失败，${wait_secs}s 后重试...\033[0m"
            sleep "$wait_secs"
            ((wait_secs++))
        fi
    done

    echo -e "  \033[31m[✗] API 连接失败（已重试 ${max_attempts} 次），开始诊断...\033[0m"
    echo -e "  \033[33m  目标 URL: ${CLASH_API_URL}/version\033[0m"
    echo -e "  \033[33m  Secret 前8位: ${Secret:0:8}...\033[0m"
    if ss -tlnp 2>/dev/null | grep -q ":${CLASH_API_PORT}"; then
        echo -e "  \033[32m  端口 ${CLASH_API_PORT} 已监听（external-controller 已绑定）\033[0m"
    else
        echo -e "  \033[31m  端口 ${CLASH_API_PORT} 未监听 — external-controller 未启动，请检查配置\033[0m"
    fi
    local raw_resp
    raw_resp=$(curl -s --connect-timeout 3 -m 5 \
        -H "Authorization: Bearer ${Secret}" \
        "${CLASH_API_URL}/version" 2>&1 | head -5 || true)
    [[ -n "$raw_resp" ]] && echo -e "  \033[33m  API 原始响应: ${raw_resp}\033[0m"
    return 1
}

extract_selector_and_nodes() {
    local proxies_json="$1"
    local parsed=""

    if command -v python3 >/dev/null 2>&1; then
        parsed=$(printf '%s' "$proxies_json" | python3 - << 'PY' 2>/dev/null
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

proxies = payload.get("proxies", {})
if not isinstance(proxies, dict):
    sys.exit(0)

prefer_groups = ["GLOBAL", "Proxy", "PROXY", "Final", "final", "节点选择"]
group = None

for name in prefer_groups:
    info = proxies.get(name)
    if isinstance(info, dict) and isinstance(info.get("all"), list) and info["all"]:
        group = name
        break

if group is None:
    for name, info in proxies.items():
        if isinstance(info, dict) and isinstance(info.get("all"), list) and info["all"]:
            group = name
            break

if group is None:
    sys.exit(0)

print("__GROUP__=" + group)
for node in proxies[group].get("all", []):
    if not isinstance(node, str):
        continue
    node = node.strip()
    if not node or node in {"DIRECT", "REJECT"}:
        continue
    print(node)
PY
)
    fi

    if [[ -z "$parsed" ]]; then
        if echo "$proxies_json" | grep -q '"GLOBAL"'; then
            SELECTOR_GROUP="GLOBAL"
            parsed=$(echo "$proxies_json" | grep -oP '"GLOBAL".*?"all"\s*:\s*\[\K[^\]]+' | sed 's/"//g' | sed 's/,/\n/g')
        elif echo "$proxies_json" | grep -q '"Proxy"'; then
            SELECTOR_GROUP="Proxy"
            parsed=$(echo "$proxies_json" | grep -oP '"Proxy".*?"all"\s*:\s*\[\K[^\]]+' | sed 's/"//g' | sed 's/,/\n/g')
        fi

        if [[ -n "$SELECTOR_GROUP" ]]; then
            parsed="__GROUP__=${SELECTOR_GROUP}"$'\n'"${parsed}"
        fi
    fi

    echo "$parsed"
}

apply_proxy_selection() {
    local proxy_name="$1"
    local group_path http_code

    [[ -z "$SELECTOR_GROUP" ]] && return 1

    if command -v python3 >/dev/null 2>&1; then
        group_path=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$SELECTOR_GROUP" 2>/dev/null)
    else
        group_path="${SELECTOR_GROUP// /%20}"
    fi

    http_code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
        -H "Authorization: Bearer ${Secret}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${proxy_name}\"}" \
        "${CLASH_API_URL}/proxies/${group_path}" 2>/dev/null || true)

    if echo "$http_code" | grep -Eq '^2[0-9]{2}$'; then
        echo -e "✓ 节点切换成功"
        return 0
    fi

    echo -e "\033[31m✗ 节点切换失败 (HTTP ${http_code})\033[0m"
    return 1
}

get_and_select_proxy() {
    local proxies_json parsed proxy_names selection
    local idx
    declare -a proxy_array

    echo -e "\n\033[33m[6/8] 正在获取代理节点列表...\033[0m"
    proxies_json=$(curl -sS --connect-timeout 5 -m 10 -H "Authorization: Bearer ${Secret}" "${CLASH_API_URL}/proxies" 2>/dev/null || true)

    if [[ -z "$proxies_json" ]]; then
        echo -e "\033[33m[!] 无法获取代理列表，已跳过节点选择\033[0m"
        return 1
    fi

    parsed=$(extract_selector_and_nodes "$proxies_json")
    SELECTOR_GROUP=$(echo "$parsed" | sed -n 's/^__GROUP__=//p' | head -1)
    proxy_names=$(echo "$parsed" | sed '/^__GROUP__=/d' | sed '/^[[:space:]]*$/d')

    if [[ -z "$SELECTOR_GROUP" || -z "$proxy_names" ]]; then
        echo -e "\033[33m[!] 未找到可切换节点，已跳过节点选择\033[0m"
        return 1
    fi

    echo -e "\n可用的代理节点："
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    idx=1
    while IFS= read -r node; do
        node=$(echo "$node" | xargs)
        [[ -z "$node" ]] && continue
        proxy_array[$idx]="$node"
        # 从 proxies_json 中提取该节点的延迟
        local delay
        delay=$(printf '%s' "$proxies_json" | python3 -c "
import json,sys
d=json.load(sys.stdin).get('proxies',{}).get(sys.argv[1],{}).get('history',[])
print(d[-1]['delay'] if d else 0)
" "$node" 2>/dev/null || echo "0")
        if [[ "$delay" =~ ^[0-9]+$ ]] && [[ "$delay" -gt 0 ]]; then
            echo "[$idx] $node  (${delay}ms)"
        else
            echo "[$idx] $node"
        fi
        ((idx++))
    done <<< "$proxy_names"

    if [[ ${#proxy_array[@]} -eq 0 ]]; then
        echo -e "\033[33m[!] 无可用节点，已跳过节点选择\033[0m"
        return 1
    fi

    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ${#proxy_array[@]} -eq 1 ]]; then
        echo -e "\033[32m[自动选择] 仅有一个可用节点，自动选择: ${proxy_array[1]}\033[0m"
        SELECTED_PROXY="${proxy_array[1]}"
        echo -e "\n正在应用节点选择..."
        apply_proxy_selection "$SELECTED_PROXY"
        return $?
    fi

    while true; do
        read_tty selection "\033[35m请选择代理节点编号 [1-${#proxy_array[@]}]（必须选择，不可跳过）: \033[0m" || return 1
        if [[ -z "$selection" ]]; then
            echo -e "\033[31m  请输入节点编号，不可跳过\033[0m"
            continue
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ -n "${proxy_array[$selection]}" ]]; then
            SELECTED_PROXY="${proxy_array[$selection]}"
            echo -e "✓ 已选择: ${SELECTED_PROXY}"
            echo -e "\n正在应用节点选择..."
            apply_proxy_selection "$SELECTED_PROXY"
            return $?
        fi

        echo -e "\033[31m无效输入，请重试\033[0m"
    done
}

apply_proxy_mode() {
    local mode="$1"
    local http_code

    http_code=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH \
        -H "Authorization: Bearer ${Secret}" \
        -H "Content-Type: application/json" \
        -d "{\"mode\":\"${mode}\"}" \
        "${CLASH_API_URL}/configs" 2>/dev/null || true)

    if echo "$http_code" | grep -Eq '^2[0-9]{2}$'; then
        echo -e "✓ 代理模式设置成功"
        return 0
    fi

    echo -e "\033[31m✗ 代理模式设置失败 (HTTP ${http_code})\033[0m"
    return 1
}

enable_system_proxy_env() {
    export http_proxy="http://127.0.0.1:${CLASH_HTTP_PORT}"
    export https_proxy="http://127.0.0.1:${CLASH_HTTP_PORT}"
    export no_proxy="127.0.0.1,localhost"
    export HTTP_PROXY="http://127.0.0.1:${CLASH_HTTP_PORT}"
    export HTTPS_PROXY="http://127.0.0.1:${CLASH_HTTP_PORT}"
    export NO_PROXY="127.0.0.1,localhost"

    SYSTEM_PROXY_STATE="已启用"
    echo -e "✓ 系统代理环境变量已启用: http://127.0.0.1:${CLASH_HTTP_PORT}"
}

disable_system_proxy_env() {
    unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
    SYSTEM_PROXY_STATE="已关闭"
    echo -e "✓ 系统代理环境变量已关闭"
}

select_proxy_strategy() {
    local strategy_selection

    echo -e "\n\033[33m[7/8] 选择代理策略\033[0m"
    echo -e "\n可用的代理策略："
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "[1] 系统代理 - 启用系统代理 + Rule 模式"
    echo -e "[2] 全局代理 - 启用系统代理 + Global 模式"
    echo -e "[3] 直连模式 - 关闭系统代理 + Direct 模式"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    while true; do
        read_tty strategy_selection "\033[35m请选择代理策略 [1-3] (直接回车默认系统代理): \033[0m" || return 1
        [[ -z "$strategy_selection" ]] && strategy_selection=1

        case "$strategy_selection" in
            1)
                PROXY_MODE="Rule"
                enable_system_proxy_env
                ;;
            2)
                PROXY_MODE="Global"
                enable_system_proxy_env
                ;;
            3)
                PROXY_MODE="Direct"
                disable_system_proxy_env
                ;;
            *)
                echo -e "\033[31m无效输入，请输入 1-3\033[0m"
                continue
                ;;
        esac
        break
    done

    echo -e "✓ 已选择: ${PROXY_MODE} 模式"
    echo -e "\n正在应用代理模式..."
    apply_proxy_mode "$PROXY_MODE"
}

select_proxy_mode() {
    local mode_selection

    echo -e "\n\033[33m[7/8] 选择代理模式\033[0m"
    echo -e "\n可用的代理模式："
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "[1] Rule   - 规则模式（根据规则自动选择）"
    echo -e "[2] Global - 全局代理（所有流量走代理）"
    echo -e "[3] Direct - 直连模式（所有流量直连）"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    while true; do
        read_tty mode_selection "\033[35m请选择代理模式 [1-3] (直接回车默认Rule): \033[0m" || return 1
        [[ -z "$mode_selection" ]] && mode_selection=1

        case "$mode_selection" in
            1)
                PROXY_MODE="Rule"
                ;;
            2)
                PROXY_MODE="Global"
                ;;
            3)
                PROXY_MODE="Direct"
                ;;
            *)
                echo -e "\033[31m无效输入，请输入 1-3\033[0m"
                continue
                ;;
        esac
        break
    done

    echo -e "✓ 已选择: ${PROXY_MODE} 模式"
    echo -e "\n正在应用代理模式..."
    apply_proxy_mode "$PROXY_MODE"
}

test_proxy_connection() {
    local test_url="https://www.google.com"
    local timeout=10
    local http_code time_total retry
    local content_snippet

    echo -e "\n\033[33m[8/8] 正在测试代理连接...\033[0m"
    echo -e "\n测试 Google 访问："

    read -r http_code time_total < <(curl -s -o /dev/null \
        -w "%{http_code} %{time_total}" \
        --connect-timeout "$timeout" --max-time "$timeout" \
        -x "http://127.0.0.1:${CLASH_HTTP_PORT}" "$test_url" 2>/dev/null || echo "000 0")

    if [[ "$http_code" == "200" || "$http_code" == "301" || "$http_code" == "302" ]]; then
        local ms
        ms=$(awk "BEGIN {printf \"%d\", $time_total * 1000}" 2>/dev/null || echo "?")
        content_snippet=$(curl -sL --connect-timeout "$timeout" --max-time "$timeout" \
            -x "http://127.0.0.1:${CLASH_HTTP_PORT}" "$test_url" 2>/dev/null | head -c 2048)

        if echo "$content_snippet" | grep -Eqi '<title>[^<]*google[^<]*</title>|Google'; then
            echo -e "✓ 代理连接成功！HTTP ${http_code}，响应时间: ${ms}ms，内容判定: Google 页面特征匹配"
        else
            echo -e "✓ 代理连接成功！HTTP ${http_code}，响应时间: ${ms}ms，内容判定: HTTP 可达（未匹配到 Google 标题）"
        fi
        return 0
    fi

    echo -e "\033[33m[!] 代理连接测试未通过（状态: ${http_code}）\033[0m"
    read_tty retry "\033[35m是否重试测试? [y/N]: \033[0m" || return 1
    if [[ "$retry" =~ ^[Yy]$ ]]; then
        sleep 2
        test_proxy_connection
        return $?
    fi

    return 1
}

# 退出清理函数（幂等，可由信号或正常流程调用）
_clash_cleanup() {
    # 防止重复执行
    [[ "${_CLASH_CLEANUP_DONE:-0}" == "1" ]] && return
    _CLASH_CLEANUP_DONE=1

    # 立即移除信号捕获，防止递归触发
    trap - INT TERM HUP

    echo -e "\n\033[33m正在退出 Clash 并清除代理环境...\033[0m"

    # 终止 Clash 进程
    if [[ -n "${_CLASH_PID:-}" ]] && kill -0 "$_CLASH_PID" 2>/dev/null; then
        kill "$_CLASH_PID" 2>/dev/null
        sleep 1
        kill -9 "$_CLASH_PID" 2>/dev/null
    fi
    # 兜底：清理所有 clash-linux 残留进程（包括其他用户/root 启动的）
    pkill -f 'clash-linux' 2>/dev/null
    sudo pkill -f 'clash-linux' 2>/dev/null

    # 清除当前 Shell 的代理环境变量
    unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY

    # 清空 /etc/profile.d/clash.sh，避免新终端自动继承代理配置
    [[ -f /etc/profile.d/clash.sh ]] && { sudo tee /etc/profile.d/clash.sh < /dev/null > /dev/null 2>/dev/null || true; }

    # 清理内部变量
    unset _CLASH_PID

    echo -e "\033[31m[×] Clash 已退出，代理环境已完全清除\033[0m"
}

#################### 任务执行 ####################

echo -e "\n\033[36m============================================================\033[0m"
echo -e "\033[36m              Clash for Linux — 启动初始化\033[0m"
echo -e "\033[36m============================================================\033[0m"

check_root


## 步骤 1: 环境初始化清理（清除遗留代理状态）
echo -e "\n\033[33m[1/8] 初始化：清理遗留代理配置...\033[0m"

# 清除当前 Shell 可能残留的代理环境变量
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
echo -e "  已重置当前 Shell 代理环境变量"

# 清空 /etc/profile.d/clash.sh 中残留的代理定义
if [[ -f /etc/profile.d/clash.sh ]]; then
    sudo tee /etc/profile.d/clash.sh < /dev/null > /dev/null 2>/dev/null || true
    echo -e "  已清空 /etc/profile.d/clash.sh"
fi

# 关闭已有的 Clash 进程（防止端口冲突或配置冲突，包括其他用户/root 启动的进程）
_existing_pids=$(pgrep -f 'clash-linux' 2>/dev/null)
if [[ -n "$_existing_pids" ]]; then
    echo -e "  发现残留 Clash 进程 (PID: $_existing_pids)，正在关闭..."
    pkill -f 'clash-linux' 2>/dev/null
    sudo pkill -f 'clash-linux' 2>/dev/null
    sleep 1
    pkill -9 -f 'clash-linux' 2>/dev/null
    sudo pkill -9 -f 'clash-linux' 2>/dev/null
    echo -e "  已关闭残留 Clash 进程"
fi
unset _existing_pids

echo -e "  \033[32m[√] 环境初始化完成\033[0m"


## 步骤 2: 基础网络检测（无代理直连验证）
echo -e "\n\033[33m[2/8] 检测基础网络连通性（直连，无代理）...\033[0m"
_net_code=$(curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" https://www.baidu.com 2>/dev/null)
if echo "$_net_code" | grep -qE '^[23]'; then
    echo -e "  \033[32m[√] 基础网络正常，可直连 (HTTP $_net_code)\033[0m"
else
    echo -e "  \033[33m[!] 直连检测未通过 (HTTP $_net_code)，将尝试继续启动 Clash...\033[0m"
fi
unset _net_code


## 步骤 3: 订阅管理（保存/切换/删除）
manage_subscriptions || return 1


## 步骤 4: 获取 CPU 架构
source $Server_Dir/scripts/get_cpu_arch.sh
if [[ -z "$CpuArch" ]]; then
    echo -e "\033[31m[ERROR] 无法获取 CPU 架构信息\033[0m"
    return 1
fi


## 步骤 4: 下载 Clash 订阅配置并生成配置文件
if [[ "$USE_LOCAL_CONFIG" == "true" ]]; then
    echo -e "\n\033[33m[4/8] 使用本地代理配置...\033[0m"
    echo -e "  \033[32m[√] 已跳过订阅下载，直接加载 Conf_Dir/config.yaml\033[0m"
    
    if [[ "$EXTERNAL_CONTROLLER_ENABLED" == "true" ]]; then
        Work_Dir=$(cd $(dirname ${BASH_SOURCE[0]}); pwd)
        Dashboard_Dir="${Work_Dir}/dashboard/public"
        sed -ri "s@^# external-ui:.*@external-ui: ${Dashboard_Dir}@g" $Conf_Dir/config.yaml
    fi
    if ! ensure_config_secret "$Conf_Dir/config.yaml" "$Secret"; then
        echo -e "\033[31m[ERROR] 写入 config.yaml 的 secret 失败\033[0m"
        return 1
    fi
else
echo -e "\n\033[33m[4/8] 检测订阅地址并下载配置...\033[0m"
Text1="Clash 订阅地址可访问！"
Text2="Clash 订阅地址不可访问！"

if [[ -n "$CLASH_HEADERS" ]]; then
    HTTP_CODE=$(curl -o /dev/null -L -k -sS --retry 5 -m 10 --connect-timeout 10 \
        -w "%{http_code}" -H "$CLASH_HEADERS" "$URL")
else
    HTTP_CODE=$(curl -o /dev/null -L -k -sS --retry 5 -m 10 --connect-timeout 10 \
        -w "%{http_code}" "$URL")
fi
echo "$HTTP_CODE" | grep -E '^[23][0-9]{2}$' &>/dev/null
ReturnStatus=$?
if_success "$Text1" "$Text2" $ReturnStatus || return 1

Text3="配置文件 config.yaml 下载成功！"
Text4="配置文件 config.yaml 下载失败，退出启动！"

if [[ -n "$CLASH_HEADERS" ]]; then
    curl -L -k -sS --retry 5 -m 10 -H "$CLASH_HEADERS" -o "$Temp_Dir/clash.yaml" "$URL"
else
    curl -L -k -sS --retry 5 -m 10 -o "$Temp_Dir/clash.yaml" "$URL"
fi
ReturnStatus=$?

if [[ $ReturnStatus -ne 0 ]]; then
    for i in {1..10}; do
        if [[ -n "$CLASH_HEADERS" ]]; then
            wget -q --no-check-certificate --header="$CLASH_HEADERS" -O "$Temp_Dir/clash.yaml" "$URL"
        else
            wget -q --no-check-certificate -O "$Temp_Dir/clash.yaml" "$URL"
        fi
        ReturnStatus=$?
        [[ $ReturnStatus -eq 0 ]] && break
    done
fi
if_success "$Text3" "$Text4" $ReturnStatus || return 1

\cp -a $Temp_Dir/clash.yaml $Temp_Dir/clash_config.yaml

if [[ $CpuArch =~ "x86_64" || $CpuArch =~ "amd64" ]]; then
    echo -e '\n判断订阅内容是否符合 Clash 配置文件标准:'
    bash $Server_Dir/scripts/clash_profile_conversion.sh
    sleep 3
fi

sed -n '/^proxies:/,$p' $Temp_Dir/clash_config.yaml > $Temp_Dir/proxy.txt
cat $Temp_Dir/templete_config.yaml > $Temp_Dir/config.yaml
cat $Temp_Dir/proxy.txt >> $Temp_Dir/config.yaml

sed -i "s/CLASH_HTTP_PORT_PLACEHOLDER/${CLASH_HTTP_PORT}/g"   $Temp_Dir/config.yaml
sed -i "s/CLASH_SOCKS_PORT_PLACEHOLDER/${CLASH_SOCKS_PORT}/g" $Temp_Dir/config.yaml
sed -i "s/CLASH_REDIR_PORT_PLACEHOLDER/${CLASH_REDIR_PORT}/g" $Temp_Dir/config.yaml
sed -i "s/CLASH_LISTEN_IP_PLACEHOLDER/${CLASH_LISTEN_IP}/g"   $Temp_Dir/config.yaml
sed -i "s/CLASH_ALLOW_LAN_PLACEHOLDER/${CLASH_ALLOW_LAN}/g"   $Temp_Dir/config.yaml

if [[ "$EXTERNAL_CONTROLLER_ENABLED" == "true" ]]; then
    sed -i "s/EXTERNAL_CONTROLLER_PLACEHOLDER/${EXTERNAL_CONTROLLER}/g" $Temp_Dir/config.yaml
else
    sed -i "s/external-controller: 'EXTERNAL_CONTROLLER_PLACEHOLDER'/# external-controller: disabled/g" $Temp_Dir/config.yaml
fi

\cp $Temp_Dir/config.yaml $Conf_Dir/

Work_Dir=$(cd $(dirname ${BASH_SOURCE[0]}); pwd)
Dashboard_Dir="${Work_Dir}/dashboard/public"
if [[ "$EXTERNAL_CONTROLLER_ENABLED" == "true" ]]; then
    sed -ri "s@^# external-ui:.*@external-ui: ${Dashboard_Dir}@g" $Conf_Dir/config.yaml
fi

if ! ensure_config_secret "$Conf_Dir/config.yaml" "$Secret"; then
    echo -e "\033[31m[ERROR] 写入 config.yaml 的 secret 失败\033[0m"
    return 1
fi



fi

## 步骤 5: 启动 Clash 进程
echo -e "\n\033[33m[5/8] 启动 Clash 服务...\033[0m"

if [[ $CpuArch =~ "x86_64" || $CpuArch =~ "amd64" ]]; then
    $Server_Dir/bin/clash-linux-amd64 -d $Conf_Dir &>> $Log_Dir/clash.log &
elif [[ $CpuArch =~ "aarch64" || $CpuArch =~ "arm64" ]]; then
    $Server_Dir/bin/clash-linux-arm64 -d $Conf_Dir &>> $Log_Dir/clash.log &
elif [[ $CpuArch =~ "armv7" ]]; then
    $Server_Dir/bin/clash-linux-armv7 -d $Conf_Dir &>> $Log_Dir/clash.log &
else
    echo -e "\033[31m[ERROR] 不支持的 CPU 架构: $CpuArch\033[0m"
    return 1
fi
_CLASH_PID=$!

# 等待 Clash 完成初始化
sleep 2

# 验证 Clash 是否成功运行
if ! kill -0 "$_CLASH_PID" 2>/dev/null; then
    echo -e "\033[31m[ERROR] Clash 进程已意外退出，请查看日志：\033[0m"
    echo -e "  tail -30 $Log_Dir/clash.log"
    unset _CLASH_PID
    return 1
fi
echo -e "  \033[32m[√] Clash 服务启动成功 (PID: $_CLASH_PID)\033[0m"


## 注册信号处理：Ctrl+C (INT)、kill (TERM)、终端关闭 (HUP) 均触发清理
_CLASH_CLEANUP_DONE=0
trap '_clash_cleanup' INT TERM HUP


## 步骤 6: 设置代理环境变量（使用 127.0.0.1 本地回环地址）
echo -e "\n\033[33m[6/8] 准备代理配置...\033[0m"
echo -e "  \033[32m[√] Clash 已启动，稍后将按你的选择应用系统代理或全局代理\033[0m"
echo ''
if [[ "$EXTERNAL_CONTROLLER_ENABLED" == "true" ]]; then
    echo -e "  Clash Dashboard: http://${EXTERNAL_CONTROLLER}/ui"
    echo -e "  Secret:          ${Secret}"
fi

save_secret_persist || return 1

if [[ "$EXTERNAL_CONTROLLER_ENABLED" == "true" ]]; then
    if test_clash_api; then
        get_and_select_proxy || true
        select_proxy_strategy || true
    fi
    test_proxy_connection || true
else
    # 即便禁用 external-controller，也保留本地代理可达性检测。
    test_proxy_connection || true
fi
if [[ "$EXTERNAL_CONTROLLER_ENABLED" != "true" ]]; then
    echo -e "\n\033[33m[!] 已禁用 External Controller，跳过节点与模式自动配置\033[0m"
fi

if ! ensure_config_secret "$Conf_Dir/config.yaml" "$Secret"; then
    echo -e "\033[31m[ERROR] 写入 config.yaml 的 secret 失败\033[0m"
    return 1
fi
echo -e "\n\033[36m========================================\033[0m"
echo -e "\033[36m    配置完成\033[0m"
echo -e "\033[36m========================================\033[0m"
echo -e "\033[32m✓ Clash Dashboard:\033[0m http://127.0.0.1:${CLASH_API_PORT}/ui"
echo -e "\033[32m✓ Secret:\033[0m ${Secret}"
if [[ -n "$SELECTED_PROXY" ]]; then
    echo -e "\033[32m✓ 当前节点:\033[0m ${SELECTED_PROXY}"
fi
if [[ -n "$PROXY_MODE" ]]; then
    echo -e "\033[32m✓ 代理模式:\033[0m ${PROXY_MODE}"
fi
if [[ -n "$SYSTEM_PROXY_STATE" ]]; then
    echo -e "\033[32m✓ 系统代理:\033[0m ${SYSTEM_PROXY_STATE}"
fi

echo -e "\n\033[33m提示：\033[0m"
echo -e "  - 使用 \033[36mproxy_on\033[0m  开启系统代理（若已定义）"
echo -e "  - 使用 \033[36mproxy_off\033[0m 关闭系统代理（若已定义）"
echo -e "  - 手动测试: \033[36mcurl -x http://127.0.0.1:${CLASH_HTTP_PORT} https://www.google.com\033[0m"

echo -e "\n\033[36m============================================================\033[0m"
echo -e "\033[32m  Clash 运行中，代理已激活\033[0m"
echo -e "\033[32m  关闭此终端 或 按 Ctrl+C  →  退出 Clash + 自动清除代理\033[0m"
echo -e "\033[36m============================================================\033[0m"

## 前台等待 Clash 进程（阻塞当前终端，终端即进程生命周期）
wait "$_CLASH_PID"

# wait 返回后（Clash 自行退出或被信号中断），执行收尾清理
_clash_cleanup

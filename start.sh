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
if [[ -r "$Server_Dir/.env" ]]; then
    source "$Server_Dir/.env"
fi

chmod +x $Server_Dir/bin/* 2>/dev/null
chmod +x $Server_Dir/scripts/* 2>/dev/null
chmod +x $Server_Dir/tools/subconverter/subconverter 2>/dev/null

Conf_Dir="$Server_Dir/conf"
Temp_Dir="$Server_Dir/temp"
Log_Dir="$Server_Dir/logs"
DOT_ENV_FILE="$Server_Dir/.env"
SECRET_FILE="$HOME/.clash_secret"
SUBSCRIPTION_FILE="$HOME/.clash_subscriptions"

URL=${CLASH_URL:-}
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
LOCAL_CONFIG_SOURCE=""

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

ensure_runtime_dirs() {
    mkdir -p "$Conf_Dir" "$Temp_Dir" "$Log_Dir" || {
        echo -e "\033[31m[ERROR] 创建运行目录失败: $Conf_Dir / $Temp_Dir / $Log_Dir\033[0m"
        return 1
    }
}

list_local_config_candidates() {
    local -a candidates=()
    local path dir

    for dir in "$Conf_Dir" "$Server_Dir/config" "$Server_Dir"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r path; do
            [[ -f "$path" ]] && candidates+=("$path")
        done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.yaml' -o -iname '*.yml' \) 2>/dev/null | sort)
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 0
    fi

    printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++'
}

validate_local_config_file() {
    local source_file="$1"
    local target_file="$2"
    local clash_bin
    local config_dir

    [[ -f "$source_file" ]] || return 1

    case "$CpuArch" in
        *x86_64*|*amd64*)
            clash_bin="$Server_Dir/bin/clash-linux-amd64"
            ;;
        *aarch64*|*arm64*)
            clash_bin="$Server_Dir/bin/clash-linux-arm64"
            ;;
        *armv7*)
            clash_bin="$Server_Dir/bin/clash-linux-armv7"
            ;;
        *)
            echo -e "\033[31m[ERROR] 不支持的 CPU 架构: $CpuArch\033[0m"
            return 1
            ;;
    esac

    [[ -x "$clash_bin" ]] || {
        echo -e "\033[31m[ERROR] Clash 可执行文件不存在: $clash_bin\033[0m"
        return 1
    }

    if [[ "$(cd "$(dirname "$source_file")" && pwd)/$(basename "$source_file")" != "$(cd "$(dirname "$target_file")" && pwd)/$(basename "$target_file")" ]]; then
        if ! \cp "$source_file" "$target_file"; then
            echo -e "\033[31m[ERROR] 复制本地配置文件失败: $source_file\033[0m"
            return 1
        fi
    fi

    config_dir=$(dirname "$target_file")
    if ! "$clash_bin" -d "$config_dir" -t >"$Log_Dir/config-check.log" 2>&1; then
        echo -e "\033[31m[ERROR] 本地配置校验失败: $source_file\033[0m"
        echo -e "\033[33m  tail -30 $Log_Dir/config-check.log\033[0m"
        return 1
    fi

    return 0
}

select_local_config_file() {
    local selection choice
    local -a config_candidates=()

    while IFS= read -r selection; do
        [[ -n "$selection" ]] && config_candidates+=("$selection")
    done < <(list_local_config_candidates)

    if [[ ${#config_candidates[@]} -eq 0 ]]; then
        echo -e "\033[31m[ERROR] 未找到可用本地配置文件。支持位置: conf/、config/ 或仓库根目录下的 .yaml/.yml 文件\033[0m"
        return 1
    fi

    if [[ ${#config_candidates[@]} -eq 1 ]]; then
        LOCAL_CONFIG_SOURCE="${config_candidates[0]}"
        echo -e "  \033[32m[√] 已自动选择本地配置: ${LOCAL_CONFIG_SOURCE#$Server_Dir/}\033[0m"
        return 0
    fi

    echo -e "\033[36m检测到多个本地配置文件：\033[0m"
    local i
    for ((i = 0; i < ${#config_candidates[@]}; i++)); do
        echo -e "[$((i + 1))] ${config_candidates[$i]#$Server_Dir/}"
    done

    while true; do
        read_tty choice "\033[35m请选择本地配置编号 [1-${#config_candidates[@]}]（回车默认 1）: \033[0m" || return 1
        [[ -z "$choice" ]] && choice=1

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#config_candidates[@]} )); then
            LOCAL_CONFIG_SOURCE="${config_candidates[$((choice - 1))]}"
            echo -e "  \033[32m[√] 已选择本地配置: ${LOCAL_CONFIG_SOURCE#$Server_Dir/}\033[0m"
            return 0
        fi

        echo -e "\033[31m无效输入，请重试\033[0m"
    done
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
        if [[ -n "$(list_local_config_candidates)" ]]; then
            read_tty use_local "[35m检测到本地 .yaml/.yml 配置文件，是否直接使用？ [Y/n]: [0m" || return 1
            if [[ -z "$use_local" || "$use_local" =~ ^[Yy]$ ]]; then
                export USE_LOCAL_CONFIG=true
                echo -e "  [32m[√] 已选择使用本地配置文件[0m"
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
    if [[ -n "$(list_local_config_candidates)" ]]; then
        echo -e "[L] 本地模式：选择本地 .yaml/.yml 配置并校验后启动"
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

        if [[ "${selection,,}" == "l" ]] && [[ -n "$(list_local_config_candidates)" ]]; then
            export USE_LOCAL_CONFIG=true
            echo -e "[32m✓ 切换为本地模式，将选择本地配置文件启动[0m"
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
        parsed=$(printf '%s' "$proxies_json" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

proxies = payload.get("proxies", {})
if not isinstance(proxies, dict):
    sys.exit(0)

prefer_groups = ["Proxies", "Proxy", "PROXY", "节点选择", "GLOBAL", "Final", "final"]
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
' 2>/dev/null)
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
    local group_path http_code proxy_json escaped_proxy

    [[ -z "$SELECTOR_GROUP" ]] && return 1

    if command -v python3 >/dev/null 2>&1; then
        group_path=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$SELECTOR_GROUP" 2>/dev/null)
        proxy_json=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$proxy_name" 2>/dev/null)
    else
        group_path="${SELECTOR_GROUP// /%20}"
        escaped_proxy="${proxy_name//\\/\\\\}"
        escaped_proxy="${escaped_proxy//\"/\\\"}"
        proxy_json="\"${escaped_proxy}\""
    fi

    http_code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
        -H "Authorization: Bearer ${Secret}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":${proxy_json}}" \
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
    export HTTP_PROXY="http://127.0.0.1:${CLASH_HTTP_PORT}"
    export HTTPS_PROXY="http://127.0.0.1:${CLASH_HTTP_PORT}"
    export all_proxy="socks5h://127.0.0.1:${CLASH_SOCKS_PORT}"
    export ALL_PROXY="socks5h://127.0.0.1:${CLASH_SOCKS_PORT}"
    export no_proxy="127.0.0.1,localhost,::1"
    export NO_PROXY="127.0.0.1,localhost,::1"

    SYSTEM_PROXY_STATE="已启用"
    echo -e "✓ 系统代理环境变量已启用: http://127.0.0.1:${CLASH_HTTP_PORT} / socks5h://127.0.0.1:${CLASH_SOCKS_PORT}"
}

disable_system_proxy_env() {
    unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY all_proxy ALL_PROXY
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
    local timeout=10
    local retry test_selection failed=0
    local attempts="${CLASH_TEST_ATTEMPTS:-3}"
    local delay="${CLASH_TEST_DELAY:-1}"

    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=3
    (( attempts >= 1 )) || attempts=1
    [[ "$delay" =~ ^[0-9]+$ ]] || delay=1

    run_proxy_test_url() {
        local name="$1"
        local url="$2"
        local expected_re="$3"
        local success_msg="${4:-HTTP 可达}"
        local warn_403="${5:-false}"
        local tmp_err curl_result http_code time_total ms retry_reason
        local success_count=0 warn_403_count=0
        local last_code="000" last_ms="0" last_err="" last_retry=""
        local i

        for ((i = 1; i <= attempts; i++)); do
            tmp_err=$(mktemp) || return 1
            curl_result=$(curl -sS -o /dev/null \
                -w "%{http_code} %{time_total}" \
                --connect-timeout "$timeout" --max-time "$timeout" \
                -x "http://127.0.0.1:${CLASH_HTTP_PORT}" "$url" 2>"$tmp_err" || true)

            if [[ "$curl_result" =~ ^([0-9]{3})[[:space:]]+([0-9.]+)$ ]]; then
                http_code="${BASH_REMATCH[1]}"
                time_total="${BASH_REMATCH[2]}"
            else
                http_code="000"
                time_total="0"
            fi

            retry_reason=""
            if ! [[ "$http_code" =~ $expected_re ]] && grep -Eqi 'SSL|TLS|unexpected eof|decode error' "$tmp_err"; then
                retry_reason="TLS 1.2 fallback"
                : > "$tmp_err"
                curl_result=$(curl -sS -o /dev/null \
                    -w "%{http_code} %{time_total}" \
                    --tls-max 1.2 \
                    --connect-timeout "$timeout" --max-time "$timeout" \
                    -x "http://127.0.0.1:${CLASH_HTTP_PORT}" "$url" 2>"$tmp_err" || true)

                if [[ "$curl_result" =~ ^([0-9]{3})[[:space:]]+([0-9.]+)$ ]]; then
                    http_code="${BASH_REMATCH[1]}"
                    time_total="${BASH_REMATCH[2]}"
                else
                    http_code="000"
                    time_total="0"
                fi
            fi

            ms=$(awk "BEGIN {printf \"%d\", $time_total * 1000}" 2>/dev/null || echo "?")
            last_code="$http_code"
            last_ms="$ms"
            last_retry="$retry_reason"
            last_err=""
            [[ -s "$tmp_err" ]] && last_err=$(tail -1 "$tmp_err")

            if [[ "$http_code" =~ $expected_re ]]; then
                ((success_count++))
            elif [[ "$warn_403" == "true" && "$http_code" == "403" ]]; then
                ((warn_403_count++))
            fi

            rm -f "$tmp_err"
            (( i < attempts )) && sleep "$delay"
        done

        local suffix=""
        [[ -n "$last_retry" ]] && suffix="（${last_retry}）"

        if (( success_count == attempts )); then
            echo -e "✓ ${name} 探测通过：${success_count}/${attempts} 次成功，最后一次 HTTP ${last_code}，响应时间: ${last_ms}ms，${success_msg}${suffix}"
            return 0
        fi

        if (( success_count > 0 )); then
            echo -e "\033[33m[!] ${name} 部分探测通过：${success_count}/${attempts} 次成功，最后一次 HTTP ${last_code}，响应时间: ${last_ms}ms；链路有过可达，但当前节点可能存在波动${suffix}\033[0m"
            return 0
        fi

        if (( warn_403_count > 0 )); then
            echo -e "\033[33m[!] ${name} ${warn_403_count}/${attempts} 次返回 HTTP 403：网络链路有响应，但当前节点被服务拒绝。\033[0m"
            echo -e "\033[33m    这通常不是代理没走通，而是当前节点 IP/地区被 ChatGPT/OpenAI 拒绝。\033[0m"
            return 2
        fi

        echo -e "\033[33m[!] ${name} ${attempts}/${attempts} 次探测未通过：最后一次 HTTP ${last_code}，响应时间: ${last_ms}ms\033[0m"
        if [[ -n "$last_err" ]]; then
            echo -e "\033[33m    curl 错误: ${last_err}\033[0m"
        elif [[ "$last_code" == "000" ]]; then
            echo -e "\033[33m    curl 未返回具体错误，常见原因是节点临时不可用、远端断开或 DNS 未经代理。\033[0m"
        fi
        echo -e "\033[33m    这只是当前采样窗口内的结果，不能证明目标永久不可达；Clash 节点和外网服务都可能短时波动。\033[0m"
        return 1
    }

    echo -e "\n\033[33m[8/8] 正在测试代理连接...\033[0m"
    echo -e "\033[33m说明：以下是 ${attempts} 次采样探测，不是“外网一定可达/不可达”的证明。可用 CLASH_TEST_ATTEMPTS 调整次数。\033[0m"

    echo -e "\n可用测试目标："
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "[1] GPT/Codex 测试 - api.openai.com + chatgpt.com（推荐）"
    echo -e "[2] Google 204 测试 - www.gstatic.com/generate_204"
    echo -e "[3] 全部测试"
    echo -e "[0] 跳过测试"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read_tty test_selection "\033[35m请选择测试目标 [0-3] (直接回车默认 GPT/Codex): \033[0m" || return 1
    [[ -z "$test_selection" ]] && test_selection=1

    case "$test_selection" in
        0)
            echo -e "\033[33m已跳过代理连接测试\033[0m"
            return 0
            ;;
        1)
            echo -e "\n测试 GPT/Codex 访问："
            run_proxy_test_url "OpenAI API" "https://api.openai.com/v1/models" '^(200|401)$' "OpenAI API 可达（未带 API Key 返回 401 属正常）" true || failed=1
            run_proxy_test_url "ChatGPT Web" "https://chatgpt.com/cdn-cgi/trace" '^(200)$' "ChatGPT Web 可达" true || failed=1
            ;;
        2)
            echo -e "\n测试 Google 204 访问："
            run_proxy_test_url "Google 204" "https://www.gstatic.com/generate_204" '^(204|200)$' "Google 204 探针可达" false || failed=1
            ;;
        3)
            echo -e "\n测试全部目标："
            run_proxy_test_url "OpenAI API" "https://api.openai.com/v1/models" '^(200|401)$' "OpenAI API 可达（未带 API Key 返回 401 属正常）" true || failed=1
            run_proxy_test_url "ChatGPT Web" "https://chatgpt.com/cdn-cgi/trace" '^(200)$' "ChatGPT Web 可达" true || failed=1
            run_proxy_test_url "Google 204" "https://www.gstatic.com/generate_204" '^(204|200)$' "Google 204 探针可达" false || failed=1
            ;;
        *)
            echo -e "\033[31m无效输入，请输入 0-3\033[0m"
            test_proxy_connection
            return $?
            ;;
    esac

    if [[ "$failed" -eq 0 ]]; then
        return 0
    fi

    echo -e "\033[33m    可运行: ${Server_Dir}/clashctl.sh test 查看 Google/OpenAI/ChatGPT 分项诊断\033[0m"
    echo -e "\033[33m    若 OpenAI/ChatGPT 返回 403，请切换到 TW/JP/SG/US 等非香港节点后重试\033[0m"
    read_tty retry "\033[35m是否重试测试? [y/N]: \033[0m" || return 1
    if [[ "$retry" =~ ^[Yy]$ ]]; then
        sleep 2
        test_proxy_connection
        return $?
    fi

    return 1
}

runtime_control_loop() {
    local runtime_choice

    while true; do
        if [[ -z "${_CLASH_PID:-}" ]] || ! kill -0 "$_CLASH_PID" 2>/dev/null; then
            echo -e "\n\033[31m[ERROR] Clash 进程已退出，请查看日志：tail -30 $Log_Dir/clash.log\033[0m"
            _clash_cleanup
            return 1
        fi

        echo -e "\n\033[36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo -e "\033[36m运行中控制台\033[0m"
        echo -e "\033[36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo -e "[1] 重新选择代理节点"
        echo -e "[2] 切换代理策略（Rule / Global / Direct）"
        echo -e "[3] 重新测试 GPT/Codex / Google 连接"
        echo -e "[4] 查看当前状态"
        echo -e "[5] 查看可用策略组"
        echo -e "[6] 查看当前策略组节点"
        echo -e "[q] 退出 Clash 并清理代理"
        echo -e "\033[36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

        read_tty runtime_choice "\033[35m请选择操作 [1-6/q] (回车刷新菜单): \033[0m" || {
            _clash_cleanup
            return 1
        }

        case "$runtime_choice" in
            "")
                continue
                ;;
            1)
                if [[ "$EXTERNAL_CONTROLLER_ENABLED" == "true" ]]; then
                    get_and_select_proxy || true
                else
                    echo -e "\033[33m[!] External Controller 已禁用，无法运行中切换节点\033[0m"
                fi
                ;;
            2)
                if [[ "$EXTERNAL_CONTROLLER_ENABLED" == "true" ]]; then
                    select_proxy_strategy || true
                else
                    echo -e "\033[33m[!] External Controller 已禁用，无法运行中切换模式\033[0m"
                fi
                ;;
            3)
                test_proxy_connection || true
                ;;
            4)
                if [[ -x "$Server_Dir/clashctl.sh" ]]; then
                    "$Server_Dir/clashctl.sh" status || true
                else
                    echo -e "PID: $_CLASH_PID"
                    echo -e "HTTP 代理: http://127.0.0.1:${CLASH_HTTP_PORT}"
                    echo -e "SOCKS 代理: socks5h://127.0.0.1:${CLASH_SOCKS_PORT}"
                    echo -e "Dashboard: http://127.0.0.1:${CLASH_API_PORT}/ui"
                fi
                ;;
            5)
                if [[ -x "$Server_Dir/clashctl.sh" ]]; then
                    "$Server_Dir/clashctl.sh" groups || true
                else
                    echo -e "\033[33m[!] clashctl.sh 不存在，无法查看策略组\033[0m"
                fi
                ;;
            6)
                if [[ -x "$Server_Dir/clashctl.sh" ]]; then
                    "$Server_Dir/clashctl.sh" nodes "${SELECTOR_GROUP:-}" || true
                else
                    echo -e "\033[33m[!] clashctl.sh 不存在，无法查看节点\033[0m"
                fi
                ;;
            q|Q|quit|exit)
                _clash_cleanup
                return 0
                ;;
            *)
                echo -e "\033[31m无效输入，请输入 1-6 或 q\033[0m"
                ;;
        esac
    done
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
    # 兜底：只清理当前项目目录下的 Clash 进程，避免影响系统上的其他 Clash 实例。
    pkill -f "${Server_Dir}/bin/clash-linux" 2>/dev/null
    sudo pkill -f "${Server_Dir}/bin/clash-linux" 2>/dev/null

    # 清除当前 Shell 的代理环境变量
    unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY all_proxy ALL_PROXY

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

ensure_runtime_dirs || return 1
echo -e "  已确认运行目录: conf / temp / logs"

# 清除当前 Shell 可能残留的代理环境变量
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY all_proxy ALL_PROXY
echo -e "  已重置当前 Shell 代理环境变量"

# 清空 /etc/profile.d/clash.sh 中残留的代理定义
if [[ -f /etc/profile.d/clash.sh ]]; then
    sudo tee /etc/profile.d/clash.sh < /dev/null > /dev/null 2>/dev/null || true
    echo -e "  已清空 /etc/profile.d/clash.sh"
fi

# 关闭已有的本项目 Clash 进程（防止端口冲突或配置冲突）
_existing_pids=$(pgrep -f "${Server_Dir}/bin/clash-linux" 2>/dev/null)
if [[ -n "$_existing_pids" ]]; then
    echo -e "  发现残留 Clash 进程 (PID: $_existing_pids)，正在关闭..."
    pkill -f "${Server_Dir}/bin/clash-linux" 2>/dev/null
    sudo pkill -f "${Server_Dir}/bin/clash-linux" 2>/dev/null
    sleep 1
    pkill -9 -f "${Server_Dir}/bin/clash-linux" 2>/dev/null
    sudo pkill -9 -f "${Server_Dir}/bin/clash-linux" 2>/dev/null
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
    select_local_config_file || return 1
    if ! validate_local_config_file "$LOCAL_CONFIG_SOURCE" "$Conf_Dir/config.yaml"; then
        return 1
    fi
    echo -e "  \033[32m[√] 已跳过订阅下载，已校验并加载本地配置: ${LOCAL_CONFIG_SOURCE#$Server_Dir/}\033[0m"

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

if [[ -z "$URL" ]]; then
    echo -e "\033[31m[ERROR] 未设置 CLASH_URL，无法进入在线订阅模式。\033[0m"
    echo -e "\033[33m  可将本地 .yaml/.yml 放入 conf/、config/ 或仓库根目录，然后选择 L 本地模式。\033[0m"
    return 1
fi

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

if [[ -r "$Server_Dir/shell_proxy.sh" ]]; then
    for shell_rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        touch "$shell_rc" 2>/dev/null || continue
        if ! grep -Fq "source \"$Server_Dir/shell_proxy.sh\"" "$shell_rc" 2>/dev/null; then
            {
                echo ""
                echo "# Clash terminal proxy auto sync"
                echo "[ -f \"$Server_Dir/shell_proxy.sh\" ] && source \"$Server_Dir/shell_proxy.sh\""
            } >> "$shell_rc"
        fi
    done
    echo -e "  \033[32m[√] 已安装 shell_proxy.sh 到 ~/.bashrc 和 ~/.zshrc，新终端会自动同步代理变量\033[0m"
fi

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
echo -e "  - 使用 \033[36mclashctl status\033[0m 查看状态，\033[36mclashctl switch\033[0m 运行中切节点，\033[36mclashctl mode global\033[0m 切全局模式"
echo -e "  - 若当前终端未加载函数: \033[36msource $Server_Dir/shell_proxy.sh\033[0m"
echo -e "  - 手动测试: \033[36m${Server_Dir}/clashctl.sh test\033[0m"
echo -e "  - 单项测试: \033[36mcurl -x http://127.0.0.1:${CLASH_HTTP_PORT} https://api.openai.com/v1/models\033[0m"

echo -e "\n\033[36m============================================================\033[0m"
echo -e "\033[32m  Clash 运行中，代理已激活\033[0m"
echo -e "\033[32m  可在下方菜单中重新切节点/切模式；按 q 或 Ctrl+C 退出并清理代理\033[0m"
echo -e "\033[36m============================================================\033[0m"

runtime_control_loop

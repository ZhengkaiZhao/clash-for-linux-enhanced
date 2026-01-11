#!/bin/bash

# Clash 自动配置脚本 - 交互式版本
# 功能：订阅管理、自动重启、保存Secret、选择节点和代理模式

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置文件路径
CLASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_FILE="$HOME/.clash_secret"
ENV_FILE="/etc/profile.d/clash.sh"
DOT_ENV_FILE="$CLASH_DIR/.env"
SUBSCRIPTION_FILE="$HOME/.clash_subscriptions"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}    Clash 自动配置脚本${NC}"
echo -e "${CYAN}========================================${NC}\n"

# 检查是否以 root 权限运行（启动服务需要）
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${YELLOW}注意：部分操作需要 root 权限${NC}"
        echo -e "${YELLOW}如果启动失败，请使用: sudo bash $0${NC}\n"
    fi
}

# 保存订阅信息到文件
save_subscription_info() {
    local url="$1"
    local name="$2"
    local traffic="$3"
    local expire="$4"
    
    # 创建或更新订阅文件
    if [ ! -f "$SUBSCRIPTION_FILE" ]; then
        echo "# Clash 订阅信息" > "$SUBSCRIPTION_FILE"
        chmod 600 "$SUBSCRIPTION_FILE"
    fi
    
    # 转义 URL 中的特殊字符用于 grep
    local escaped_url=$(echo "$url" | sed 's/[]\/$*.^[]/\\&/g')
    
    # 检查是否已存在该订阅（使用更安全的方法）
    local temp_file=$(mktemp)
    local found=false
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^URL= ]] && echo "$line" | grep -qF "URL=$url"; then
            # 更新现有订阅
            echo "URL=$url|NAME=$name|TRAFFIC=$traffic|EXPIRE=$expire"
            found=true
        else
            echo "$line"
        fi
    done < "$SUBSCRIPTION_FILE" > "$temp_file"
    
    # 如果没找到，添加新订阅
    if [ "$found" = false ]; then
        echo "URL=$url|NAME=$name|TRAFFIC=$traffic|EXPIRE=$expire" >> "$temp_file"
    fi
    
    mv "$temp_file" "$SUBSCRIPTION_FILE"
    chmod 600 "$SUBSCRIPTION_FILE"
}

# 从响应头获取订阅信息
get_subscription_info() {
    local url="$1"
    local temp_file=$(mktemp)
    
    # 下载订阅并保存响应头
    local http_code=$(curl -s -w "%{http_code}" \
        -H "User-Agent: ClashforWindows/0.20.39" \
        -o /dev/null \
        -D "$temp_file" \
        --connect-timeout 10 \
        "$url" 2>/dev/null)
    
    if [ "$http_code" != "200" ]; then
        rm -f "$temp_file"
        return 1
    fi
    
    # 提取信息
    local traffic_info=""
    local expire_info=""
    
    # 尝试提取流量信息 (subscription-userinfo)
    if grep -qi "subscription-userinfo:" "$temp_file"; then
        local userinfo=$(grep -i "subscription-userinfo:" "$temp_file" | cut -d: -f2- | tr -d '\r\n')
        
        # 解析上传、下载和总量
        local upload=$(echo "$userinfo" | grep -oP 'upload=\K[0-9]+' || echo "0")
        local download=$(echo "$userinfo" | grep -oP 'download=\K[0-9]+' || echo "0")
        local total=$(echo "$userinfo" | grep -oP 'total=\K[0-9]+' || echo "0")
        local expire=$(echo "$userinfo" | grep -oP 'expire=\K[0-9]+' || echo "0")
        
        # 转换为可读格式
        if [ "$total" != "0" ]; then
            local used=$((upload + download))
            local used_gb=$(awk "BEGIN {printf \"%.2f\", $used/1024/1024/1024}")
            local total_gb=$(awk "BEGIN {printf \"%.2f\", $total/1024/1024/1024}")
            local remaining_gb=$(awk "BEGIN {printf \"%.2f\", ($total-$used)/1024/1024/1024}")
            traffic_info="${used_gb}GB/${total_gb}GB (剩余${remaining_gb}GB)"
        fi
        
        # 转换过期时间
        if [ "$expire" != "0" ]; then
            expire_info=$(date -d "@$expire" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "未知")
        fi
    fi
    
    rm -f "$temp_file"
    
    # 输出结果
    echo "${traffic_info:-未知}|${expire_info:-未知}"
    return 0
}

# 安全地更新 .env 文件中的 CLASH_URL
update_env_file() {
    local new_url="$1"
    
    if [ ! -f "$DOT_ENV_FILE" ]; then
        # 创建新的 .env 文件
        cat > "$DOT_ENV_FILE" << EOF
# Clash 订阅地址
export CLASH_URL='$new_url'
export CLASH_SECRET=''
export CLASH_HEADERS='User-Agent: ClashforWindows/0.20.39'

# Clash 监听配置
export CLASH_HTTP_PORT=7890
export CLASH_SOCKS_PORT=7891
export CLASH_REDIR_PORT=7892
export CLASH_LISTEN_IP=0.0.0.0
export CLASH_ALLOW_LAN=true

# External Controller (RESTful API) 配置
export EXTERNAL_CONTROLLER_ENABLED=true
export EXTERNAL_CONTROLLER=0.0.0.0:9090
EOF
    else
        # 备份原文件
        cp "$DOT_ENV_FILE" "$DOT_ENV_FILE.backup"
        
        # 使用临时文件安全地替换
        local temp_file=$(mktemp)
        local url_found=false
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^export\ CLASH_URL= ]]; then
                echo "export CLASH_URL='$new_url'"
                url_found=true
            else
                echo "$line"
            fi
        done < "$DOT_ENV_FILE" > "$temp_file"
        
        # 如果没找到 CLASH_URL 行，添加它
        if [ "$url_found" = false ]; then
            echo "export CLASH_URL='$new_url'" >> "$temp_file"
        fi
        
        # 替换原文件
        mv "$temp_file" "$DOT_ENV_FILE"
    fi
    
    # 验证更新是否成功
    local saved_url=$(grep "^export CLASH_URL=" "$DOT_ENV_FILE" | cut -d"'" -f2)
    if [ "$saved_url" == "$new_url" ]; then
        echo -e "${GREEN}✓ .env 文件已更新${NC}"
        return 0
    else
        echo -e "${RED}✗ .env 文件更新失败${NC}"
        echo -e "${YELLOW}预期: $new_url${NC}"
        echo -e "${YELLOW}实际: $saved_url${NC}"
        # 恢复备份
        [ -f "$DOT_ENV_FILE.backup" ] && mv "$DOT_ENV_FILE.backup" "$DOT_ENV_FILE"
        return 1
    fi
}

# 管理订阅地址
manage_subscriptions() {
    echo -e "${BLUE}[步骤 0] 订阅地址管理${NC}\n"
    
    # 读取当前 .env 中的订阅地址
    local current_url=""
    if [ -f "$DOT_ENV_FILE" ]; then
        current_url=$(grep "^export CLASH_URL=" "$DOT_ENV_FILE" | cut -d"'" -f2)
    fi
    
    # 检查当前订阅是否有效
    local has_valid_subscription=false
    if [ ! -z "$current_url" ] && [ "$current_url" != "更改为你的clash订阅地址" ]; then
        echo -e "${CYAN}正在检查当前订阅地址...${NC}"
        if curl -s --connect-timeout 10 -H "User-Agent: ClashforWindows/0.20.39" \
            --head "$current_url" > /dev/null 2>&1; then
            has_valid_subscription=true
            echo -e "${GREEN}✓ 当前订阅地址有效${NC}\n"
        else
            echo -e "${YELLOW}! 当前订阅地址无效或无法访问${NC}\n"
        fi
    fi
    
    # 显示已保存的订阅列表
    if [ -f "$SUBSCRIPTION_FILE" ] && [ -s "$SUBSCRIPTION_FILE" ]; then
        echo -e "${CYAN}已保存的订阅列表：${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        declare -a subscription_urls
        declare -a subscription_names
        local index=1
        
        while IFS='|' read -r line; do
            if [[ "$line" =~ ^URL= ]]; then
                local url=$(echo "$line" | grep -oP 'URL=\K[^|]+')
                local name=$(echo "$line" | grep -oP 'NAME=\K[^|]+')
                local traffic=$(echo "$line" | grep -oP 'TRAFFIC=\K[^|]+')
                local expire=$(echo "$line" | grep -oP 'EXPIRE=\K[^|]+')
                
                subscription_urls[$index]="$url"
                subscription_names[$index]="$name"
                
                echo -e "${GREEN}[$index]${NC} ${YELLOW}$name${NC}"
                if [ ! -z "$traffic" ] && [ "$traffic" != "未知" ]; then
                    echo -e "    流量: $traffic"
                fi
                if [ ! -z "$expire" ] && [ "$expire" != "未知" ]; then
                    echo -e "    过期: $expire"
                fi
                
                # 检查是否是当前使用的订阅
                if [ "$url" == "$current_url" ]; then
                    echo -e "    ${GREEN}[当前使用]${NC}"
                fi
                echo ""
                
                ((index++))
            fi
        done < "$SUBSCRIPTION_FILE"
        
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}[0]${NC} 添加新的订阅地址"
        echo -e "${RED}[d]${NC} 删除订阅（输入 d[编号]，如 d1）\n"
        
        # 让用户选择
        while true; do
            echo -e -n "${PURPLE}请选择订阅 [0-$((index-1))] 或 d[编号]删除 或直接回车: ${NC}"
            read -r selection
            
            # 直接回车使用当前订阅
            if [ -z "$selection" ]; then
                if [ "$has_valid_subscription" = true ]; then
                    echo -e "${GREEN}✓ 使用当前订阅${NC}\n"
                    return 0
                else
                    echo -e "${RED}当前订阅无效，请选择其他订阅或添加新订阅${NC}"
                    continue
                fi
            fi
            
            # 删除订阅
            if [[ "$selection" =~ ^d[0-9]+$ ]]; then
                local del_index="${selection:1}"
                if [ "$del_index" -ge 1 ] && [ "$del_index" -lt "$index" ]; then
                    local del_url="${subscription_urls[$del_index]}"
                    local del_name="${subscription_names[$del_index]}"
                    
                    echo -e "${YELLOW}确认删除订阅: $del_name? [y/N]: ${NC}"
                    read -r confirm
                    
                    if [ "$confirm" == "y" ] || [ "$confirm" == "Y" ]; then
                        # 从文件中删除
                        grep -v "URL=$del_url" "$SUBSCRIPTION_FILE" > "$SUBSCRIPTION_FILE.tmp"
                        mv "$SUBSCRIPTION_FILE.tmp" "$SUBSCRIPTION_FILE"
                        echo -e "${GREEN}✓ 已删除订阅: $del_name${NC}\n"
                        
                        # 如果删除的是当前使用的订阅，需要重新选择
                        if [ "$del_url" == "$current_url" ]; then
                            echo -e "${YELLOW}! 已删除当前使用的订阅，请重新选择${NC}\n"
                            manage_subscriptions
                            return 0
                        fi
                        
                        # 重新显示列表
                        manage_subscriptions
                        return 0
                    else
                        echo -e "${YELLOW}取消删除${NC}\n"
                        continue
                    fi
                else
                    echo -e "${RED}无效的订阅编号${NC}"
                    continue
                fi
            fi
            
            # 添加新订阅
            if [ "$selection" == "0" ]; then
                add_new_subscription
                return 0
            fi
            
            # 选择已有订阅
            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -lt "$index" ]; then
                local selected_url="${subscription_urls[$selection]}"
                local selected_name="${subscription_names[$selection]}"
                
                echo -e "${CYAN}正在验证订阅: $selected_name${NC}"
                
                # 验证订阅并获取最新信息
                local info=$(get_subscription_info "$selected_url")
                if [ $? -eq 0 ]; then
                    local traffic=$(echo "$info" | cut -d'|' -f1)
                    local expire=$(echo "$info" | cut -d'|' -f2)
                    
                    echo -e "${GREEN}✓ 订阅验证成功${NC}"
                    [ "$traffic" != "未知" ] && echo -e "${GREEN}  流量: $traffic${NC}"
                    [ "$expire" != "未知" ] && echo -e "${GREEN}  过期: $expire${NC}"
                    
                    # 更新到 .env 文件
                    update_env_file "$selected_url"
                    
                    # 保存订阅信息
                    save_subscription_info "$selected_url" "$selected_name" "$traffic" "$expire"
                    
                    echo -e "${GREEN}✓ 订阅地址已更新${NC}\n"
                    return 0
                else
                    echo -e "${RED}✗ 订阅验证失败，请选择其他订阅${NC}\n"
                    continue
                fi
            else
                echo -e "${RED}无效输入，请重新选择${NC}"
            fi
        done
    else
        # 没有保存的订阅，直接添加新订阅
        if [ "$has_valid_subscription" = true ]; then
            echo -e "${YELLOW}检测到当前订阅地址有效${NC}"
            echo -e -n "${PURPLE}是否使用当前订阅? [Y/n]: ${NC}"
            read -r use_current
            
            if [ -z "$use_current" ] || [ "$use_current" == "y" ] || [ "$use_current" == "Y" ]; then
                echo -e "${GREEN}✓ 使用当前订阅${NC}\n"
                return 0
            fi
        fi
        
        add_new_subscription
    fi
}

# 添加新订阅
add_new_subscription() {
    echo -e "\n${CYAN}添加新订阅${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    while true; do
        echo -e -n "${PURPLE}请输入订阅地址 (URL): ${NC}"
        read -r new_url
        
        if [ -z "$new_url" ]; then
            echo -e "${RED}订阅地址不能为空${NC}"
            continue
        fi
        
        echo -e "${CYAN}正在验证订阅地址...${NC}"
        
        # 验证订阅地址
        local info=$(get_subscription_info "$new_url")
        if [ $? -eq 0 ]; then
            local traffic=$(echo "$info" | cut -d'|' -f1)
            local expire=$(echo "$info" | cut -d'|' -f2)
            
            echo -e "${GREEN}✓ 订阅地址验证成功！${NC}"
            [ "$traffic" != "未知" ] && echo -e "${GREEN}  流量: $traffic${NC}"
            [ "$expire" != "未知" ] && echo -e "${GREEN}  过期: $expire${NC}"
            
            # 询问订阅名称
            echo -e -n "\n${PURPLE}请为此订阅起个名称 (默认: Clash订阅): ${NC}"
            read -r sub_name
            sub_name=${sub_name:-"Clash订阅"}
            
            # 更新到 .env 文件（使用更安全的方法）
            update_env_file "$new_url"
            
            # 保存订阅信息
            save_subscription_info "$new_url" "$sub_name" "$traffic" "$expire"
            
            echo -e "${GREEN}✓ 订阅已添加并设置为当前使用${NC}\n"
            break
        else
            echo -e "${RED}✗ 订阅地址验证失败${NC}"
            echo -e "${YELLOW}可能的原因：${NC}"
            echo -e "  1. URL 格式不正确"
            echo -e "  2. 网络连接问题"
            echo -e "  3. 订阅服务器无响应\n"
            
            echo -e -n "${PURPLE}是否重新输入? [Y/n]: ${NC}"
            read -r retry
            if [ "$retry" == "n" ] || [ "$retry" == "N" ]; then
                echo -e "${RED}取消添加订阅${NC}\n"
                exit 1
            fi
        fi
    done
}

# 步骤1: 关闭现有服务
stop_clash() {
    echo -e "${BLUE}[1/7] 正在关闭现有 Clash 服务...${NC}"
    if [ -f "$CLASH_DIR/shutdown.sh" ]; then
        bash "$CLASH_DIR/shutdown.sh" > /dev/null 2>&1 || true
        sleep 1
        echo -e "${GREEN}✓ 服务已关闭${NC}\n"
    else
        echo -e "${YELLOW}! shutdown.sh 未找到，跳过关闭步骤${NC}\n"
    fi
}

# 步骤2: 启动服务并捕获 Secret
start_clash_and_get_secret() {
    echo -e "${BLUE}[2/7] 正在启动 Clash 服务...${NC}"
    
    if [ ! -f "$CLASH_DIR/start.sh" ]; then
        echo -e "${RED}✗ 错误：start.sh 未找到${NC}"
        exit 1
    fi
    
    # 启动服务并捕获输出
    local output=$(bash "$CLASH_DIR/start.sh" 2>&1)
    echo "$output"
    
    # 从输出中提取 Secret
    SECRET=$(echo "$output" | grep -oP 'Secret[：:]\s*\K[a-zA-Z0-9]+' | head -1)
    
    if [ -z "$SECRET" ]; then
        echo -e "${RED}✗ 错误：无法获取 Secret${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ 服务启动成功${NC}"
    echo -e "${GREEN}✓ Secret: ${SECRET}${NC}\n"
}

# 步骤3: 保存 Secret 到文件和环境变量
save_secret() {
    echo -e "${BLUE}[3/7] 正在保存 Secret...${NC}"
    
    # 保存到用户目录
    echo "export CLASH_SECRET='$SECRET'" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    
    # 加载到当前会话
    export CLASH_SECRET="$SECRET"
    
    # 添加到 ~/.bashrc（如果还没有）
    if ! grep -q "CLASH_SECRET" "$HOME/.bashrc" 2>/dev/null; then
        echo "" >> "$HOME/.bashrc"
        echo "# Clash Secret (自动生成)" >> "$HOME/.bashrc"
        echo "[ -f $SECRET_FILE ] && source $SECRET_FILE" >> "$HOME/.bashrc"
    fi
    
    echo -e "${GREEN}✓ Secret 已保存到 $SECRET_FILE${NC}"
    echo -e "${GREEN}✓ 下次登录将自动加载${NC}\n"
}

# 步骤4: 加载代理环境变量
load_proxy_env() {
    echo -e "${BLUE}[4/7] 正在加载代理环境变量...${NC}"
    
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        proxy_on > /dev/null 2>&1 || true
        echo -e "${GREEN}✓ 代理环境变量已加载${NC}\n"
    else
        echo -e "${YELLOW}! 警告：$ENV_FILE 未找到${NC}\n"
    fi
}

# 步骤5: 测试 API 连接
test_api() {
    echo -e "${BLUE}[5/7] 正在测试 Clash API 连接...${NC}"
    
    sleep 2  # 等待服务完全启动
    
    local response=$(curl -s -H "Authorization: Bearer $CLASH_SECRET" \
        http://127.0.0.1:9090/version 2>&1)
    
    if echo "$response" | grep -q "version" 2>/dev/null; then
        local version=$(echo "$response" | grep -oP '"version"\s*:\s*"\K[^"]+' || echo "未知")
        echo -e "${GREEN}✓ API 连接成功${NC}"
        echo -e "${GREEN}✓ Clash 版本: $version${NC}\n"
        return 0
    else
        echo -e "${RED}✗ API 连接失败${NC}"
        echo -e "${YELLOW}Response: $response${NC}\n"
        return 1
    fi
}

# 步骤6: 获取并显示代理节点
get_and_select_proxy() {
    echo -e "${BLUE}[6/8] 正在获取代理节点列表...${NC}\n"
    
    # 获取所有代理
    local proxies_json=$(curl -s -H "Authorization: Bearer $CLASH_SECRET" \
        http://127.0.0.1:9090/proxies)
    
    if [ -z "$proxies_json" ]; then
        echo -e "${RED}✗ 无法获取代理列表${NC}"
        return 1
    fi
    
    # 尝试多种方式获取节点列表
    local proxy_names=""
    
    # 方法1: 从 GLOBAL 组获取
    if echo "$proxies_json" | grep -q "GLOBAL"; then
        proxy_names=$(echo "$proxies_json" | \
            grep -oP '"GLOBAL".*?"all"\s*:\s*\[\K[^\]]+' | \
            sed 's/"//g' | sed 's/,/\n/g' | grep -v "^$")
    fi
    
    # 方法2: 如果方法1失败，尝试从 Proxy 组获取
    if [ -z "$proxy_names" ] && echo "$proxies_json" | grep -q '"Proxy"'; then
        proxy_names=$(echo "$proxies_json" | \
            grep -oP '"Proxy".*?"all"\s*:\s*\[\K[^\]]+' | \
            sed 's/"//g' | sed 's/,/\n/g' | grep -v "^$")
    fi
    
    # 方法3: 如果还是失败，获取所有 Shadowsocks/Vmess/Trojan 类型的节点
    if [ -z "$proxy_names" ]; then
        proxy_names=$(echo "$proxies_json" | \
            grep -oP '"[^"]+"\s*:\s*\{[^}]*"type"\s*:\s*"(Shadowsocks|ShadowsocksR|Vmess|Trojan|Snell)"' | \
            grep -oP '^"[^"]+' | sed 's/"//g')
    fi
    
    # 方法4: 最后尝试获取所有非 DIRECT/REJECT/Selector/URLTest 的节点
    if [ -z "$proxy_names" ]; then
        proxy_names=$(echo "$proxies_json" | \
            grep -oP '"[^"]+"\s*:\s*\{[^}]*"type"\s*:\s*"[^"]+' | \
            grep -v -E '(DIRECT|REJECT|Selector|URLTest|LoadBalance|Fallback|Compatible)' | \
            grep -oP '^"[^"]+' | sed 's/"//g')
    fi
    
    if [ -z "$proxy_names" ]; then
        echo -e "${YELLOW}! 未找到可用节点，可能配置文件有问题${NC}"
        echo -e "${YELLOW}! 请检查 conf/config.yaml 文件${NC}\n"
        return 1
    fi
    
    # 显示节点列表
    echo -e "${CYAN}可用的代理节点：${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    local index=1
    declare -a proxy_array
    
    while IFS= read -r proxy; do
        proxy=$(echo "$proxy" | xargs)  # 去除空格
        if [ ! -z "$proxy" ] && [ "$proxy" != "DIRECT" ] && [ "$proxy" != "REJECT" ]; then
            proxy_array[$index]="$proxy"
            
            # 获取节点延迟信息
            local delay=$(echo "$proxies_json" | \
                grep -oP "\"$proxy\".*?\"delay\"\s*:\s*\K[0-9]+" | head -1)
            
            if [ ! -z "$delay" ] && [ "$delay" != "0" ]; then
                echo -e "${GREEN}[$index]${NC} $proxy ${YELLOW}(${delay}ms)${NC}"
            else
                echo -e "${GREEN}[$index]${NC} $proxy"
            fi
            ((index++))
        fi
    done <<< "$proxy_names"
    
    if [ ${#proxy_array[@]} -eq 0 ]; then
        echo -e "${YELLOW}! 没有找到有效的代理节点${NC}"
        echo -e "${YELLOW}! 只有 DIRECT 和 REJECT 通常说明配置文件格式有问题${NC}\n"
        return 1
    fi
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    # 让用户选择节点
    while true; do
        echo -e -n "${PURPLE}请选择代理节点编号 [1-${#proxy_array[@]}] (直接回车跳过): ${NC}"
        read -r selection
        
        # 如果直接回车，跳过选择
        if [ -z "$selection" ]; then
            echo -e "${YELLOW}跳过节点选择${NC}\n"
            return 0
        fi
        
        # 验证输入
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#proxy_array[@]}" ]; then
            SELECTED_PROXY="${proxy_array[$selection]}"
            echo -e "${GREEN}✓ 已选择: $SELECTED_PROXY${NC}\n"
            
            # 应用节点选择
            apply_proxy_selection "$SELECTED_PROXY"
            break
        else
            echo -e "${RED}无效输入，请输入 1-${#proxy_array[@]} 之间的数字${NC}"
        fi
    done
}

# 应用代理节点选择
apply_proxy_selection() {
    local proxy_name="$1"
    
    echo -e "${BLUE}正在应用节点选择...${NC}"
    
    local response=$(curl -s -X PUT \
        -H "Authorization: Bearer $CLASH_SECRET" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$proxy_name\"}" \
        http://127.0.0.1:9090/proxies/GLOBAL)
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 节点切换成功${NC}\n"
    else
        echo -e "${RED}✗ 节点切换失败${NC}\n"
    fi
}

# 步骤7: 选择代理模式
select_proxy_mode() {
    echo -e "${BLUE}[7/8] 选择代理模式${NC}\n"
    
    echo -e "${CYAN}可用的代理模式：${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}[1]${NC} Rule   - 规则模式（根据规则自动选择）"
    echo -e "${GREEN}[2]${NC} Global - 全局代理（所有流量走代理）"
    echo -e "${GREEN}[3]${NC} Direct - 直连模式（所有流量直连）"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    while true; do
        echo -e -n "${PURPLE}请选择代理模式 [1-3] (直接回车默认Rule): ${NC}"
        read -r mode_selection
        
        # 默认选择 Rule
        if [ -z "$mode_selection" ]; then
            mode_selection=1
        fi
        
        case "$mode_selection" in
            1)
                MODE="Rule"
                break
                ;;
            2)
                MODE="Global"
                break
                ;;
            3)
                MODE="Direct"
                break
                ;;
            *)
                echo -e "${RED}无效输入，请输入 1-3${NC}"
                ;;
        esac
    done
    
    echo -e "${GREEN}✓ 已选择: $MODE 模式${NC}\n"
    
    # 应用模式选择
    apply_mode_selection "$MODE"
}

# 应用代理模式
apply_mode_selection() {
    local mode="$1"
    
    echo -e "${BLUE}正在应用代理模式...${NC}"
    
    local response=$(curl -s -X PATCH \
        -H "Authorization: Bearer $CLASH_SECRET" \
        -H "Content-Type: application/json" \
        -d "{\"mode\":\"$mode\"}" \
        http://127.0.0.1:9090/configs)
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 代理模式设置成功${NC}\n"
    else
        echo -e "${RED}✗ 代理模式设置失败${NC}\n"
    fi
}

# 测试代理连接
test_proxy_connection() {
    echo -e "\n${BLUE}[8/8] 正在测试代理连接...${NC}\n"
    
    echo -e "${CYAN}测试 Google 访问：${NC}"
    
    # 测试 HTTP 代理
    local test_url="https://www.google.com"
    local timeout=10
    
    # 使用代理测试
    local response=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout $timeout \
        --max-time $timeout \
        -x http://127.0.0.1:7890 \
        "$test_url" 2>&1)
    
    if [ "$response" = "200" ] || [ "$response" = "301" ] || [ "$response" = "302" ]; then
        echo -e "${GREEN}✓ 代理连接成功！${NC}"
        echo -e "${GREEN}  HTTP 状态码: $response${NC}"
        
        # 测试访问速度
        local start_time=$(date +%s%N)
        curl -s -o /dev/null \
            --connect-timeout $timeout \
            --max-time $timeout \
            -x http://127.0.0.1:7890 \
            "$test_url" 2>/dev/null
        local end_time=$(date +%s%N)
        local duration=$(( (end_time - start_time) / 1000000 ))
        
        echo -e "${GREEN}  响应时间: ${duration}ms${NC}\n"
        return 0
    else
        echo -e "${RED}✗ 代理连接失败${NC}"
        echo -e "${YELLOW}  返回状态: $response${NC}"
        echo -e "${YELLOW}  可能原因：${NC}"
        echo -e "${YELLOW}    1. 代理节点不可用${NC}"
        echo -e "${YELLOW}    2. 网络连接问题${NC}"
        echo -e "${YELLOW}    3. 需要等待代理启动完成${NC}\n"
        
        echo -e -n "${PURPLE}是否重新测试? [y/N]: ${NC}"
        read -r retry
        if [ "$retry" == "y" ] || [ "$retry" == "Y" ]; then
            sleep 2
            test_proxy_connection
        fi
        return 1
    fi
}

# 显示最终状态
show_final_status() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}    配置完成！${NC}"
    echo -e "${CYAN}========================================${NC}\n"
    
    echo -e "${GREEN}✓ Clash Dashboard: ${NC}http://127.0.0.1:9090/ui"
    echo -e "${GREEN}✓ Secret: ${NC}$CLASH_SECRET"
    
    if [ ! -z "$SELECTED_PROXY" ]; then
        echo -e "${GREEN}✓ 当前节点: ${NC}$SELECTED_PROXY"
    fi
    
    if [ ! -z "$MODE" ]; then
        echo -e "${GREEN}✓ 代理模式: ${NC}$MODE"
    fi
    
    echo -e "\n${YELLOW}提示：${NC}"
    echo -e "  - Secret 已保存，下次登录自动加载"
    echo -e "  - 使用 ${CYAN}proxy_on${NC} 开启系统代理"
    echo -e "  - 使用 ${CYAN}proxy_off${NC} 关闭系统代理"
    echo -e "  - 重新运行此脚本: ${CYAN}sudo bash $0${NC}"
    echo -e "  - 手动测试: ${CYAN}curl -x http://127.0.0.1:7890 https://www.google.com${NC}\n"
}

# 主函数
main() {
    check_root
    manage_subscriptions  # 新增：订阅管理
    stop_clash
    start_clash_and_get_secret
    save_secret
    load_proxy_env
    
    if test_api; then
        get_and_select_proxy
        select_proxy_mode
        test_proxy_connection  # 新增：测试代理连接
        show_final_status
    else
        echo -e "${RED}配置失败，请检查 Clash 服务${NC}"
        exit 1
    fi
}

# 运行主函数
main

#!/usr/bin/env bash

set -u

Server_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Profile_Env="/etc/profile.d/clash.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear_current_shell_proxy() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
}

clear_profile_proxy() {
    [[ -f "$Profile_Env" ]] || return 0

    if [[ -w "$Profile_Env" ]]; then
        : > "$Profile_Env"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo tee "$Profile_Env" < /dev/null > /dev/null 2>&1 || {
            echo -e "${YELLOW}[!] 无法清空 ${Profile_Env}，可稍后手动检查。${NC}"
            return 1
        }
    else
        echo -e "${YELLOW}[!] 当前用户无法写入 ${Profile_Env}，且未找到 sudo。${NC}"
        return 1
    fi
}

stop_clash_processes() {
    local pids
    pids="$(pgrep -f "${Server_Dir}/bin/clash-linux" 2>/dev/null || true)"

    if [[ -z "$pids" ]]; then
        echo -e "${YELLOW}[!] 未发现本项目 Clash 进程。${NC}"
        return 0
    fi

    echo "正在关闭 Clash 进程: ${pids}"
    pkill -f "${Server_Dir}/bin/clash-linux" 2>/dev/null || true
    sleep 1

    if pgrep -f "${Server_Dir}/bin/clash-linux" >/dev/null 2>&1; then
        pkill -9 -f "${Server_Dir}/bin/clash-linux" 2>/dev/null || true
    fi
}

stop_clash_processes
clear_profile_proxy || true

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    clear_current_shell_proxy
    echo -e "${GREEN}Clash 已关闭，当前 Shell 代理变量已清理。${NC}"
else
    echo -e "${GREEN}Clash 已关闭。${NC}"
    echo -e "${YELLOW}如果当前终端仍有代理变量，请执行: source ${Server_Dir}/shutdown.sh 或 proxy_off${NC}"
fi

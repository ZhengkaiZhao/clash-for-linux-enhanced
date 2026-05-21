#!/usr/bin/env bash

set -u

Server_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Conf_Dir="${Server_Dir}/conf"
Log_Dir="${Server_Dir}/logs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

detect_clash_bin() {
    local arch
    arch="$(uname -m 2>/dev/null || arch 2>/dev/null || true)"

    case "$arch" in
        x86_64|amd64)
            printf '%s\n' "${Server_Dir}/bin/clash-linux-amd64"
            ;;
        aarch64|arm64)
            printf '%s\n' "${Server_Dir}/bin/clash-linux-arm64"
            ;;
        armv7*|armv7l)
            printf '%s\n' "${Server_Dir}/bin/clash-linux-armv7"
            ;;
        *)
            echo -e "${RED}[ERROR] 不支持的 CPU 架构: ${arch:-unknown}${NC}" >&2
            return 1
            ;;
    esac
}

stop_clash_processes() {
    local pids
    pids="$(pgrep -f "${Server_Dir}/bin/clash-linux" 2>/dev/null || true)"

    if [[ -n "$pids" ]]; then
        echo "正在关闭 Clash 进程: ${pids}"
        pkill -f "${Server_Dir}/bin/clash-linux" 2>/dev/null || true
        sleep 1
        pkill -9 -f "${Server_Dir}/bin/clash-linux" 2>/dev/null || true
    else
        echo -e "${YELLOW}[!] 未发现本项目 Clash 进程，将直接启动。${NC}"
    fi
}

mkdir -p "$Log_Dir"

clash_bin="$(detect_clash_bin)" || exit 1
if [[ ! -x "$clash_bin" ]]; then
    echo -e "${RED}[ERROR] Clash 可执行文件不存在或不可执行: ${clash_bin}${NC}" >&2
    exit 1
fi

if [[ ! -f "${Conf_Dir}/config.yaml" ]]; then
    echo -e "${RED}[ERROR] 缺少配置文件: ${Conf_Dir}/config.yaml${NC}" >&2
    echo -e "${YELLOW}请先执行: source ${Server_Dir}/start.sh${NC}" >&2
    exit 1
fi

stop_clash_processes

nohup "$clash_bin" -d "$Conf_Dir" > "${Log_Dir}/clash.log" 2>&1 &
new_pid=$!
sleep 1

if kill -0 "$new_pid" 2>/dev/null; then
    echo -e "${GREEN}Clash 重启成功 (PID: ${new_pid})${NC}"
else
    echo -e "${RED}Clash 启动失败，请查看日志: tail -30 ${Log_Dir}/clash.log${NC}" >&2
    exit 1
fi

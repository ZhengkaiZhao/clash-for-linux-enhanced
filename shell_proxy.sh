#!/usr/bin/env bash
# Source this file from ~/.bashrc to keep terminal proxy variables in sync
# with the local Clash process.

_CLASH_AUTO_DIR="/mnt/ssd3/hjh/clash-for-linux-enhanced"
_CLASH_AUTO_ENV="${_CLASH_AUTO_DIR}/.env"

_clash_proxy_port() {
    local port="7890"

    if [[ -r "$_CLASH_AUTO_ENV" ]]; then
        port="$(sed -n -E 's/^[[:space:]]*export[[:space:]]+CLASH_HTTP_PORT=["'"'"']?([0-9]+)["'"'"']?.*$/\1/p' "$_CLASH_AUTO_ENV" | head -n 1)"
    fi

    [[ "$port" =~ ^[0-9]+$ ]] || port="7890"

    printf '%s\n' "$port"
}

_clash_proxy_is_running() {
    pgrep -f "${_CLASH_AUTO_DIR}/bin/clash-linux" >/dev/null 2>&1
}

proxy_on() {
    local port proxy
    port="$(_clash_proxy_port)"
    proxy="http://127.0.0.1:${port}"

    export http_proxy="$proxy"
    export https_proxy="$proxy"
    export HTTP_PROXY="$proxy"
    export HTTPS_PROXY="$proxy"
    export no_proxy="127.0.0.1,localhost"
    export NO_PROXY="127.0.0.1,localhost"

    [[ "${1:-}" == "--quiet" ]] || echo "[OK] proxy on: ${proxy}"
}

proxy_off() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY
    [[ "${1:-}" == "--quiet" ]] || echo "[OK] proxy off"
}

clash_auto_proxy() {
    [[ "${CLASH_AUTO_PROXY:-1}" == "0" ]] && return 0

    if _clash_proxy_is_running; then
        proxy_on --quiet
    else
        proxy_off --quiet
    fi
}

clash_auto_proxy

if [[ $- == *i* && -z "${CLASH_AUTO_PROXY_PROMPT_INSTALLED:-}" ]]; then
    export CLASH_AUTO_PROXY_PROMPT_INSTALLED=1
    case ";${PROMPT_COMMAND:-};" in
        *";clash_auto_proxy;"*) ;;
        *) PROMPT_COMMAND="clash_auto_proxy${PROMPT_COMMAND:+; ${PROMPT_COMMAND}}" ;;
    esac
fi

#!/usr/bin/env bash
# Source this file from ~/.bashrc or ~/.zshrc to keep terminal proxy variables
# in sync with the local Clash process.

if [[ -n "${ZSH_VERSION:-}" ]]; then
    _CLASH_AUTO_SOURCE="${(%):-%x}"
else
    _CLASH_AUTO_SOURCE="${BASH_SOURCE[0]:-$0}"
fi

_CLASH_AUTO_DIR="$(cd "$(dirname "$_CLASH_AUTO_SOURCE")" && pwd)"
_CLASH_AUTO_ENV="${_CLASH_AUTO_DIR}/.env"

_clash_proxy_port() {
    local port="7890"

    if [[ -r "$_CLASH_AUTO_ENV" ]]; then
        port="$(sed -n -E 's/^[[:space:]]*export[[:space:]]+CLASH_HTTP_PORT=["'"'"']?([0-9]+)["'"'"']?.*$/\1/p' "$_CLASH_AUTO_ENV" | head -n 1)"
    fi

    [[ "$port" =~ ^[0-9]+$ ]] || port="7890"

    printf '%s\n' "$port"
}

_clash_socks_port() {
    local port="7891"

    if [[ -r "$_CLASH_AUTO_ENV" ]]; then
        port="$(sed -n -E 's/^[[:space:]]*export[[:space:]]+CLASH_SOCKS_PORT=["'"'"']?([0-9]+)["'"'"']?.*$/\1/p' "$_CLASH_AUTO_ENV" | head -n 1)"
    fi

    [[ "$port" =~ ^[0-9]+$ ]] || port="7891"

    printf '%s\n' "$port"
}

_clash_proxy_is_running() {
    pgrep -f "${_CLASH_AUTO_DIR}/bin/clash-linux" >/dev/null 2>&1
}

proxy_on() {
    local port socks_port proxy socks_proxy
    port="$(_clash_proxy_port)"
    socks_port="$(_clash_socks_port)"
    proxy="http://127.0.0.1:${port}"
    socks_proxy="socks5h://127.0.0.1:${socks_port}"

    export http_proxy="$proxy"
    export https_proxy="$proxy"
    export HTTP_PROXY="$proxy"
    export HTTPS_PROXY="$proxy"
    export all_proxy="$socks_proxy"
    export ALL_PROXY="$socks_proxy"
    export no_proxy="127.0.0.1,localhost,::1"
    export NO_PROXY="127.0.0.1,localhost,::1"

    [[ "${1:-}" == "--quiet" ]] || echo "[OK] proxy on: ${proxy} / ${socks_proxy}"
}

proxy_off() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    [[ "${1:-}" == "--quiet" ]] || echo "[OK] proxy off"
}

clashctl() {
    "${_CLASH_AUTO_DIR}/clashctl.sh" "$@"
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

if [[ $- == *i* && -n "${BASH_VERSION:-}" && -z "${CLASH_AUTO_PROXY_PROMPT_INSTALLED:-}" ]]; then
    export CLASH_AUTO_PROXY_PROMPT_INSTALLED=1
    case ";${PROMPT_COMMAND:-};" in
        *";clash_auto_proxy;"*) ;;
        *) PROMPT_COMMAND="clash_auto_proxy${PROMPT_COMMAND:+; ${PROMPT_COMMAND}}" ;;
    esac
fi

if [[ $- == *i* && -n "${ZSH_VERSION:-}" && -z "${CLASH_AUTO_PROXY_ZSH_INSTALLED:-}" ]]; then
    export CLASH_AUTO_PROXY_ZSH_INSTALLED=1
    autoload -Uz add-zsh-hook 2>/dev/null || true
    if typeset -f add-zsh-hook >/dev/null 2>&1; then
        add-zsh-hook precmd clash_auto_proxy
    else
        case " ${precmd_functions[*]-} " in
            *" clash_auto_proxy "*) ;;
            *) precmd_functions+=(clash_auto_proxy) ;;
        esac
    fi
fi

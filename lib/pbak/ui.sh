#!/bin/bash

if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    UI_RED=$(tput setaf 1)
    UI_GREEN=$(tput setaf 2)
    UI_YELLOW=$(tput setaf 3)
    UI_BLUE=$(tput setaf 4)
    UI_CYAN=$(tput setaf 6)
    UI_BOLD=$(tput bold)
    UI_DIM=$(tput dim)
    UI_RESET=$(tput sgr0)
else
    UI_RED="" UI_GREEN="" UI_YELLOW="" UI_BLUE="" UI_CYAN=""
    UI_BOLD="" UI_DIM="" UI_RESET=""
fi

ui_header() {
    [[ "${QUIET:-0}" -eq 1 ]] && return
    echo
    echo "${UI_BOLD}${UI_BLUE}▸ $*${UI_RESET}"
    echo "${UI_DIM}$(printf '%.0s─' $(seq 1 60))${UI_RESET}"
}

ui_success() { [[ "${QUIET:-0}" -eq 1 ]] && return; echo "${UI_GREEN}✓${UI_RESET} $*"; }
ui_error()   { echo "${UI_RED}✗${UI_RESET} $*" >&2; }
ui_warn()    { echo "${UI_YELLOW}!${UI_RESET} $*" >&2; }
ui_info()    { [[ "${QUIET:-0}" -eq 1 ]] && return; echo "${UI_BLUE}·${UI_RESET} $*"; }
ui_dim()     { [[ "${QUIET:-0}" -eq 1 ]] && return; echo "${UI_DIM}$*${UI_RESET}"; }

ui_prompt() {
    local question="$1"
    local default="${2:-}"
    local answer

    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$question" "$default" >&2
    else
        printf '%s: ' "$question" >&2
    fi

    read -r answer
    echo "${answer:-$default}"
}

ui_prompt_secret() {
    local question="$1"
    local answer
    printf '%s: ' "$question" >&2
    read -rs answer
    echo >&2
    echo "$answer"
}

ui_confirm() {
    local question="$1"
    local default="${2:-n}"
    local hint

    if [[ "$default" == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi

    local answer
    printf '%s %s ' "$question" "$hint" >&2
    read -r answer
    answer="${answer:-$default}"

    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

ui_select() {
    local prompt="$1"; shift
    local options=("$@")
    local count="${#options[@]}"

    echo >&2
    echo "${UI_BOLD}${prompt}${UI_RESET}" >&2
    echo >&2

    local i
    for ((i = 0; i < count; i++)); do
        printf '  %s%d)%s %s\n' "$UI_CYAN" "$((i + 1))" "$UI_RESET" "${options[$i]}" >&2
    done

    echo >&2
    local choice
    while true; do
        printf '  Choice [1-%d]: ' "$count" >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $count ]]; then
            echo "${options[$((choice - 1))]}"
            return 0
        fi
        ui_warn "  Invalid selection. Enter a number between 1 and ${count}." >&2
    done
}

ui_select_optional() {
    local prompt="$1"; shift
    local options=("$@")
    local count="${#options[@]}"

    echo >&2
    echo "${UI_BOLD}${prompt}${UI_RESET}" >&2
    echo >&2

    local i
    for ((i = 0; i < count; i++)); do
        printf '  %s%d)%s %s\n' "$UI_CYAN" "$((i + 1))" "$UI_RESET" "${options[$i]}" >&2
    done

    echo >&2
    local choice
    while true; do
        printf '  Choice [1-%d, Enter to skip]: ' "$count" >&2
        read -r choice
        if [[ -z "$choice" ]]; then
            echo ""
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $count ]]; then
            echo "${options[$((choice - 1))]}"
            return 0
        fi
        ui_warn "  Invalid selection. Enter a number between 1 and ${count}, or press Enter to skip." >&2
    done
}

ui_select_multi() {
    local prompt="$1"; shift
    local options=("$@")
    local count="${#options[@]}"

    echo >&2
    echo "${UI_BOLD}${prompt}${UI_RESET}" >&2
    echo >&2

    local i
    for ((i = 0; i < count; i++)); do
        printf '  %s%d)%s %s\n' "$UI_CYAN" "$((i + 1))" "$UI_RESET" "${options[$i]}" >&2
    done

    echo >&2
    printf '  Enter numbers separated by spaces, or "all": ' >&2
    local input
    read -r input

    if [[ "$input" == "all" ]]; then
        printf '%s\n' "${options[@]}"
        return 0
    fi

    local num
    for num in $input; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le $count ]]; then
            echo "${options[$((num - 1))]}"
        fi
    done
}

ui_progress() {
    [[ "${QUIET:-0}" -eq 1 ]] && return
    local current="$1"
    local total="$2"
    local label="$3"
    printf '\r  %s[%d/%d]%s %s' "$UI_DIM" "$current" "$total" "$UI_RESET" "$label" >&2
    printf '\033[K' >&2  # clear rest of line
}

ui_progress_done() {
    printf '\r\033[K' >&2
}

_UI_SPINNER_PID=""

ui_spinner_start() {
    [[ "${QUIET:-0}" -eq 1 ]] && return
    local msg="$1"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    (
        local i=0
        while true; do
            printf '\r  %s %s' "${chars:$((i % ${#chars})):1}" "$msg" >&2
            i=$((i + 1))
            sleep 0.1
        done
    ) &
    _UI_SPINNER_PID=$!
    disown "$_UI_SPINNER_PID" 2>/dev/null
}

ui_spinner_stop() {
    if [[ -n "${_UI_SPINNER_PID:-}" ]]; then
        kill "$_UI_SPINNER_PID" 2>/dev/null || true
        wait "$_UI_SPINNER_PID" 2>/dev/null || true
        _UI_SPINNER_PID=""
        printf '\r\033[K' >&2
    fi
}

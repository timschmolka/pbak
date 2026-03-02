#!/bin/bash

config_dir() {
    local dir="${XDG_CONFIG_HOME:-${HOME}/.config}/pbak"
    mkdir -p "$dir"
    echo "$dir"
}

config_file() {
    echo "$(config_dir)/config"
}

config_load() {
    local cf
    cf="$(config_file)"
    if [[ ! -f "$cf" ]]; then
        return 1
    fi
    source "$cf"

    # Migrate old volume-name config to root-path config
    if [[ -n "${PBAK_SD_VOLUME:-}" && -z "${PBAK_SD_ROOT:-}" ]]; then
        PBAK_SD_ROOT="/Volumes/${PBAK_SD_VOLUME}/${PBAK_SD_PATH:-DCIM}"
    fi
    if [[ -n "${PBAK_SSD_VOLUME:-}" && -z "${PBAK_SSD_ROOT:-}" ]]; then
        PBAK_SSD_ROOT="/Volumes/${PBAK_SSD_VOLUME}/${PBAK_SSD_PATH:-full_dump}"
    fi
    if [[ -n "${PBAK_MIRROR_VOLUME:-}" && -z "${PBAK_MIRROR_ROOT:-}" ]]; then
        PBAK_MIRROR_ROOT="/Volumes/${PBAK_MIRROR_VOLUME}/${PBAK_SSD_PATH:-full_dump}"
    fi
}

config_save() {
    local cf
    cf="$(config_file)"

    cat > "$cf" <<CONF
# pbak configuration — generated $(date '+%Y-%m-%d %H:%M:%S')

PBAK_IMMICH_SERVER="${PBAK_IMMICH_SERVER:-}"
PBAK_IMMICH_API_KEY="${PBAK_IMMICH_API_KEY:-}"

PBAK_SD_ROOT="${PBAK_SD_ROOT:-}"
PBAK_SSD_ROOT="${PBAK_SSD_ROOT:-}"
PBAK_MIRROR_ROOT="${PBAK_MIRROR_ROOT:-}"

PBAK_DUMP_EXTENSIONS_INCLUDE="${PBAK_DUMP_EXTENSIONS_INCLUDE:-}"
PBAK_DUMP_EXTENSIONS_EXCLUDE="${PBAK_DUMP_EXTENSIONS_EXCLUDE:-}"

PBAK_UPLOAD_EXTENSIONS_INCLUDE="${PBAK_UPLOAD_EXTENSIONS_INCLUDE:-}"
PBAK_UPLOAD_EXTENSIONS_EXCLUDE="${PBAK_UPLOAD_EXTENSIONS_EXCLUDE:-}"

PBAK_CONCURRENT_TASKS="${PBAK_CONCURRENT_TASKS:-4}"
PBAK_UPLOAD_PAUSE_JOBS="${PBAK_UPLOAD_PAUSE_JOBS:-true}"

PBAK_LRC_CATALOG="${PBAK_LRC_CATALOG:-}"
CONF

    chmod 600 "$cf"
    utils_log INFO "Config saved to ${cf}"
}

config_validate() {
    local errors=0

    if [[ -z "${PBAK_IMMICH_SERVER:-}" ]]; then
        ui_error "PBAK_IMMICH_SERVER is not set."
        ((errors++))
    fi
    if [[ -z "${PBAK_IMMICH_API_KEY:-}" ]]; then
        ui_error "PBAK_IMMICH_API_KEY is not set."
        ((errors++))
    fi

    [[ $errors -eq 0 ]]
}

config_require() {
    if ! config_load; then
        ui_error "No configuration found. Run 'pbak setup' first."
        exit 1
    fi
}

# Interactive path picker: shows mounted volumes + custom path option.
# Returns a full path (volume + subfolder, or custom).
_config_pick_path() {
    local label="$1"
    local current="$2"
    local default_subfolder="$3"
    local allow_skip="${4:-0}"

    # If there's a current value, offer to keep it
    if [[ -n "$current" ]]; then
        local hint=""
        [[ "$allow_skip" -eq 1 ]] && hint=', "none" to clear'
        local answer
        answer=$(ui_prompt "  ${label}${hint}" "$current")
        if [[ "$answer" == "none" || "$answer" == "-" ]]; then
            echo ""
        else
            echo "$answer"
        fi
        return 0
    fi

    local volumes
    volumes=($(utils_list_volumes))

    if [[ ${#volumes[@]} -eq 0 ]]; then
        ui_prompt "  ${label} (full path)" ""
        return 0
    fi

    local options=()
    local v
    for v in "${volumes[@]}"; do
        options+=("$(_utils_volume_prefix)/${v}")
    done
    options+=("Custom path...")

    local choice
    if [[ "$allow_skip" -eq 1 ]]; then
        choice=$(ui_select_optional "  ${label}:" "${options[@]}")
        if [[ -z "$choice" ]]; then
            echo ""
            return 0
        fi
    else
        choice=$(ui_select "  ${label}:" "${options[@]}")
    fi

    if [[ "$choice" == "Custom path..." ]]; then
        ui_prompt "  Full path" ""
    else
        local sub
        sub=$(ui_prompt "  Subfolder within ${choice}" "$default_subfolder")
        if [[ -n "$sub" ]]; then
            echo "${choice}/${sub}"
        else
            echo "$choice"
        fi
    fi
}

pbak_setup() {
    case "${1:-}" in
        -h|--help)
            cat <<EOF
${UI_BOLD}pbak setup${UI_RESET} — Configure pbak for first use

Walks through an interactive wizard to set Immich server details,
storage paths, and file extension preferences.

Configuration is saved to $(config_file)
EOF
            return 0 ;;
    esac

    ui_header "pbak Setup"

    if [[ -f "$(config_file)" ]]; then
        source "$(config_file)"
        # Run migration so current values are available as defaults
        if [[ -n "${PBAK_SD_VOLUME:-}" && -z "${PBAK_SD_ROOT:-}" ]]; then
            PBAK_SD_ROOT="/Volumes/${PBAK_SD_VOLUME}/${PBAK_SD_PATH:-DCIM}"
        fi
        if [[ -n "${PBAK_SSD_VOLUME:-}" && -z "${PBAK_SSD_ROOT:-}" ]]; then
            PBAK_SSD_ROOT="/Volumes/${PBAK_SSD_VOLUME}/${PBAK_SSD_PATH:-full_dump}"
        fi
        if [[ -n "${PBAK_MIRROR_VOLUME:-}" && -z "${PBAK_MIRROR_ROOT:-}" ]]; then
            PBAK_MIRROR_ROOT="/Volumes/${PBAK_MIRROR_VOLUME}/${PBAK_SSD_PATH:-full_dump}"
        fi
        ui_info "Existing config found at $(config_file)"
        if ! ui_confirm "  Reconfigure?"; then
            ui_info "Setup cancelled."
            return 0
        fi
    fi

    echo

    ui_info "${UI_BOLD}Immich Server${UI_RESET}"
    PBAK_IMMICH_SERVER=$(ui_prompt "  Server URL (e.g. https://immich.example.com)" "${PBAK_IMMICH_SERVER:-}")
    if [[ ! "$PBAK_IMMICH_SERVER" =~ ^https?:// ]]; then
        PBAK_IMMICH_SERVER="https://${PBAK_IMMICH_SERVER}"
        ui_dim "  Assuming https: ${PBAK_IMMICH_SERVER}"
    fi

    PBAK_IMMICH_API_KEY=$(ui_prompt_secret "  API key")
    echo

    ui_info "${UI_BOLD}Storage Paths${UI_RESET}"
    ui_dim "  Pick a mounted volume or enter any path."
    echo

    PBAK_SD_ROOT=$(_config_pick_path "SD card source" "${PBAK_SD_ROOT:-}" "DCIM")
    PBAK_SSD_ROOT=$(_config_pick_path "SSD dump root" "${PBAK_SSD_ROOT:-}" "full_dump")
    PBAK_MIRROR_ROOT=$(_config_pick_path "Mirror root (empty to skip)" "${PBAK_MIRROR_ROOT:-}" "full_dump" 1)
    echo

    ui_info "${UI_BOLD}File Extensions${UI_RESET}"
    ui_dim "  Comma-separated, with dots. e.g. .arw,.jpg,.mp4"
    echo

    PBAK_DUMP_EXTENSIONS_INCLUDE=$(ui_prompt "  Dump — include extensions" \
        "${PBAK_DUMP_EXTENSIONS_INCLUDE:-.arw,.cr3,.cr2,.nef,.raf,.dng,.tif,.jpg,.jpeg,.heic,.mp4,.mov}")
    PBAK_DUMP_EXTENSIONS_EXCLUDE=$(ui_prompt "  Dump — exclude extensions (leave empty for none)" \
        "${PBAK_DUMP_EXTENSIONS_EXCLUDE:-}")

    PBAK_UPLOAD_EXTENSIONS_INCLUDE=$(ui_prompt "  Upload — include extensions" \
        "${PBAK_UPLOAD_EXTENSIONS_INCLUDE:-.arw,.cr3,.cr2,.nef,.raf,.dng,.tif,.jpg,.jpeg,.heic,.mp4,.mov,.xmp}")
    PBAK_UPLOAD_EXTENSIONS_EXCLUDE=$(ui_prompt "  Upload — exclude extensions (leave empty for none)" \
        "${PBAK_UPLOAD_EXTENSIONS_EXCLUDE:-}")
    echo

    ui_info "${UI_BOLD}Upload Settings${UI_RESET}"
    PBAK_CONCURRENT_TASKS=$(ui_prompt "  Concurrent upload tasks (1-20)" \
        "${PBAK_CONCURRENT_TASKS:-4}")
    if ! [[ "$PBAK_CONCURRENT_TASKS" =~ ^[0-9]+$ ]] || \
       [[ "$PBAK_CONCURRENT_TASKS" -lt 1 ]] || [[ "$PBAK_CONCURRENT_TASKS" -gt 20 ]]; then
        ui_warn "  Invalid value, defaulting to 4."
        PBAK_CONCURRENT_TASKS=4
    fi

    if ui_confirm "  Pause Immich background jobs during upload?" "y"; then
        PBAK_UPLOAD_PAUSE_JOBS="true"
    else
        PBAK_UPLOAD_PAUSE_JOBS="false"
    fi

    echo
    ui_info "${UI_BOLD}Lightroom Classic${UI_RESET}"
    PBAK_LRC_CATALOG=$(ui_prompt "  Catalog path (.lrcat file, \"none\" to clear)" \
        "${PBAK_LRC_CATALOG:-}")
    [[ "$PBAK_LRC_CATALOG" == "none" || "$PBAK_LRC_CATALOG" == "-" ]] && PBAK_LRC_CATALOG=""
    if [[ -n "$PBAK_LRC_CATALOG" && ! -f "$PBAK_LRC_CATALOG" ]]; then
        ui_warn "  Catalog not found: ${PBAK_LRC_CATALOG}"
        ui_dim "  You can update the path later with 'pbak setup'."
    fi

    echo
    ui_header "Summary"
    printf '  %-28s %s\n' "Immich server:" "$PBAK_IMMICH_SERVER"
    printf '  %-28s %s\n' "API key:" "${PBAK_IMMICH_API_KEY:0:8}..."
    printf '  %-28s %s\n' "SD source:" "${PBAK_SD_ROOT:-(not set)}"
    printf '  %-28s %s\n' "SSD dump root:" "${PBAK_SSD_ROOT:-(not set)}"
    printf '  %-28s %s\n' "Mirror root:" "${PBAK_MIRROR_ROOT:-(not set)}"
    printf '  %-28s %s\n' "Dump include:" "$PBAK_DUMP_EXTENSIONS_INCLUDE"
    printf '  %-28s %s\n' "Dump exclude:" "${PBAK_DUMP_EXTENSIONS_EXCLUDE:-(none)}"
    printf '  %-28s %s\n' "Upload include:" "$PBAK_UPLOAD_EXTENSIONS_INCLUDE"
    printf '  %-28s %s\n' "Upload exclude:" "${PBAK_UPLOAD_EXTENSIONS_EXCLUDE:-(none)}"
    printf '  %-28s %s\n' "Concurrent tasks:" "$PBAK_CONCURRENT_TASKS"
    printf '  %-28s %s\n' "Pause Immich jobs:" "$PBAK_UPLOAD_PAUSE_JOBS"
    printf '  %-28s %s\n' "LrC catalog:" "${PBAK_LRC_CATALOG:-(not set)}"
    echo

    if ui_confirm "  Save configuration?" "y"; then
        config_save
        ui_success "Configuration saved to $(config_file)"
    else
        ui_warn "Setup cancelled — nothing saved."
    fi
}

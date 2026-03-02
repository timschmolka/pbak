#!/bin/bash

_sync_usage() {
    cat <<EOF
${UI_BOLD}pbak sync${UI_RESET} — Sync primary SSD to a mirror SSD

One-way additive sync using rsync. New files on the primary are copied
to the mirror. Nothing is ever deleted from the mirror.

${UI_BOLD}Flags:${UI_RESET}
  --from <path>     Primary SSD root (path or volume name)
  --to <path>       Mirror SSD root (path or volume name)
  -h, --help        Show this help

${UI_BOLD}Global flags also apply:${UI_RESET}  --dry-run, --verbose
EOF
}

pbak_sync() {
    local from_override=""
    local to_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)    from_override="$2"; shift 2 ;;
            --to)      to_override="$2"; shift 2 ;;
            -h|--help) _sync_usage; return 0 ;;
            *) ui_error "Unknown flag: $1"; _sync_usage; return 1 ;;
        esac
    done

    config_require

    ui_header "SSD Sync: Primary -> Mirror"

    # Resolve source path
    local src=""
    if [[ -n "$from_override" ]]; then
        src=$(utils_resolve_override "$from_override")
    elif [[ -n "${PBAK_SSD_ROOT:-}" ]]; then
        src="$PBAK_SSD_ROOT"
    else
        local volumes
        volumes=($(utils_list_volumes))
        if [[ ${#volumes[@]} -eq 0 ]]; then
            ui_error "No SSD configured and no volumes found. Use --from <path>."
            exit 1
        fi
        local vol
        vol=$(ui_select "Select PRIMARY SSD (source):" "${volumes[@]}")
        src="$(_utils_volume_prefix)/${vol}"
    fi
    utils_require_path "$src" "Primary SSD" || exit 1

    # Resolve destination path
    local dst=""
    if [[ -n "$to_override" ]]; then
        dst=$(utils_resolve_override "$to_override")
    elif [[ -n "${PBAK_MIRROR_ROOT:-}" ]]; then
        dst="$PBAK_MIRROR_ROOT"
    else
        local volumes
        volumes=($(utils_list_volumes))
        local filtered=()
        local v
        for v in "${volumes[@]}"; do
            [[ "$(_utils_volume_prefix)/${v}" != "$src" ]] && filtered+=("$v")
        done
        if [[ ${#filtered[@]} -eq 0 ]]; then
            ui_error "No mirror configured and no other volumes found. Use --to <path>."
            exit 1
        fi
        local vol
        vol=$(ui_select "Select MIRROR SSD (destination):" "${filtered[@]}")
        dst="$(_utils_volume_prefix)/${vol}"
    fi
    utils_require_path "$dst" "Mirror SSD" || exit 1
    utils_path_is_writable "$dst" || exit 1

    # Trailing slash on src is critical — rsync copies contents, not the directory itself
    local src_trail="${src%/}/"
    local dst_trail="${dst%/}/"

    ui_info "Source: ${src_trail}"
    ui_info "Mirror: ${dst_trail}"
    echo

    local rsync_args=(
        -av
        --ignore-existing
        --progress
    )

    if utils_is_dry_run; then
        rsync_args+=(--dry-run)
        ui_warn "[DRY RUN] No files will be copied."
        echo
    fi

    rsync "${rsync_args[@]}" "$src_trail" "$dst_trail"
    local exit_code=$?

    echo
    if [[ $exit_code -eq 0 ]]; then
        ui_success "Sync complete."
    else
        ui_error "rsync exited with code ${exit_code}"
        return "$exit_code"
    fi
}

#!/bin/bash

_doctor_usage() {
    cat <<EOF
${UI_BOLD}pbak doctor${UI_RESET} — Run health checks on your pbak setup

Checks configuration, storage paths, hash database integrity,
upload state consistency, dependencies, and Immich connectivity.

${UI_BOLD}Flags:${UI_RESET}
  -h, --help    Show this help
EOF
}

pbak_doctor() {
    case "${1:-}" in
        -h|--help) _doctor_usage; return 0 ;;
    esac

    ui_header "pbak doctor"

    local issues=0 warnings=0

    # ── Config ────────────────────────────────────────────────
    ui_info "${UI_BOLD}Configuration${UI_RESET}"

    local cf
    cf="$(config_file)"
    if [[ -f "$cf" ]]; then
        ui_success "Config file exists: ${cf}"
        config_load
    else
        ui_error "No config file found. Run 'pbak setup'."
        ((issues++))
        # Can't continue without config
        echo
        ui_header "Result"
        ui_error "${issues} issue(s) found."
        return 1
    fi

    if [[ -z "${PBAK_IMMICH_SERVER:-}" ]]; then
        ui_error "PBAK_IMMICH_SERVER is not set."
        ((issues++))
    else
        ui_success "Immich server: ${PBAK_IMMICH_SERVER}"
    fi

    if [[ -z "${PBAK_IMMICH_API_KEY:-}" ]]; then
        ui_error "PBAK_IMMICH_API_KEY is not set."
        ((issues++))
    else
        ui_success "API key: ${PBAK_IMMICH_API_KEY:0:8}..."
    fi

    echo

    # ── Connectivity ──────────────────────────────────────────
    ui_info "${UI_BOLD}Immich Connectivity${UI_RESET}"

    if [[ -n "${PBAK_IMMICH_SERVER:-}" && -n "${PBAK_IMMICH_API_KEY:-}" ]]; then
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -H "x-api-key: ${PBAK_IMMICH_API_KEY}" \
            "${PBAK_IMMICH_SERVER}/api/server/ping" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            ui_success "Server reachable, API key valid."
        elif [[ "$http_code" == "401" ]]; then
            ui_error "Server reachable but API key is invalid (HTTP 401)."
            ((issues++))
        elif [[ "$http_code" == "000" ]]; then
            ui_warn "Server unreachable — may be offline or URL wrong."
            ((warnings++))
        else
            ui_warn "Server returned HTTP ${http_code}."
            ((warnings++))
        fi
    else
        ui_dim "  Skipped (server not configured)."
    fi

    echo

    # ── Dependencies ──────────────────────────────────────────
    ui_info "${UI_BOLD}Dependencies${UI_RESET}"

    local deps=("immich-go" "exiftool" "openssl" "rsync" "python3")
    local dep
    for dep in "${deps[@]}"; do
        if command -v "$dep" &>/dev/null; then
            ui_success "${dep}: $(command -v "$dep")"
        else
            if [[ "$dep" == "python3" ]]; then
                ui_warn "${dep}: not found (needed for albums/stacking)"
                ((warnings++))
            else
                ui_error "${dep}: not found"
                ((issues++))
            fi
        fi
    done

    echo

    # ── Storage Paths ─────────────────────────────────────────
    ui_info "${UI_BOLD}Storage Paths${UI_RESET}"

    if [[ -n "${PBAK_SD_ROOT:-}" ]]; then
        if [[ -d "$PBAK_SD_ROOT" ]]; then
            ui_success "SD source: ${PBAK_SD_ROOT}"
        else
            ui_dim "  SD source: ${PBAK_SD_ROOT} (not mounted)"
        fi
    else
        ui_dim "  SD source: not configured"
    fi

    if [[ -n "${PBAK_SSD_ROOT:-}" ]]; then
        if [[ -d "$PBAK_SSD_ROOT" ]]; then
            ui_success "SSD root: ${PBAK_SSD_ROOT}"
            if [[ ! -w "$PBAK_SSD_ROOT" ]]; then
                ui_warn "  SSD root is not writable!"
                ((warnings++))
            fi
        else
            ui_warn "SSD root: ${PBAK_SSD_ROOT} (not accessible)"
            ((warnings++))
        fi
    else
        ui_error "SSD root: not configured"
        ((issues++))
    fi

    if [[ -n "${PBAK_MIRROR_ROOT:-}" ]]; then
        if [[ -d "$PBAK_MIRROR_ROOT" ]]; then
            ui_success "Mirror root: ${PBAK_MIRROR_ROOT}"
        else
            ui_dim "  Mirror root: ${PBAK_MIRROR_ROOT} (not mounted)"
        fi
    else
        ui_dim "  Mirror root: not configured"
    fi

    echo

    # ── Hash Database ─────────────────────────────────────────
    ui_info "${UI_BOLD}Hash Database${UI_RESET}"

    local db
    db="$(hash_db_file)"
    if [[ ! -s "$db" ]]; then
        ui_warn "Hash database is empty."
        ((warnings++))
    else
        local db_lines
        db_lines=$(wc -l < "$db" | tr -d ' ')
        local db_size
        db_size=$(utils_human_size "$(hash_db_size)")
        ui_success "Database: ${db_lines} entries (${db_size})"

        # Check for malformed lines (not 6 columns)
        local bad_lines
        bad_lines=$(awk -F '\t' 'NF != 6' "$db" | wc -l | tr -d ' ')
        if [[ $bad_lines -gt 0 ]]; then
            ui_error "${bad_lines} malformed line(s) in hash DB (expected 6 columns)."
            ((issues++))
        else
            ui_success "All lines have correct column count."
        fi

        # Check for orphaned DB entries (files in DB but missing from disk)
        if [[ -n "${PBAK_SSD_ROOT:-}" && -d "${PBAK_SSD_ROOT}" ]]; then
            local orphaned
            orphaned=$(awk -F '\t' -v prefix="${PBAK_SSD_ROOT}/" '
                substr($3, 1, length(prefix)) == prefix {
                    print $3
                }
            ' "$db" | while IFS= read -r fp; do
                [[ ! -f "$fp" ]] && echo "$fp"
            done | wc -l | tr -d ' ')

            if [[ $orphaned -gt 0 ]]; then
                ui_warn "${orphaned} DB entries point to missing files. Consider 'pbak rehash'."
                ((warnings++))
            else
                ui_success "All DB file paths exist on disk."
            fi

            # Check for untracked files (on SSD but not in DB)
            local tracked_count
            tracked_count=$(awk -F '\t' -v prefix="${PBAK_SSD_ROOT}/" '
                substr($3, 1, length(prefix)) == prefix { count++ }
                END { print count+0 }
            ' "$db")

            local disk_count
            disk_count=$(find "${PBAK_SSD_ROOT}" -type f 2>/dev/null | wc -l | tr -d ' ')

            if [[ $disk_count -gt $tracked_count ]]; then
                local diff=$((disk_count - tracked_count))
                ui_warn "${diff} files on SSD not in hash DB. Consider 'pbak rehash'."
                ((warnings++))
            else
                ui_success "All SSD files tracked in DB."
            fi
        fi

        # Upload status consistency
        local uploaded_in_hash uploaded_in_log
        uploaded_in_hash=$(hash_total_uploaded)
        uploaded_in_log=$(upload_files_by_status "uploaded")
        ui_dim "  Upload tracking: ${uploaded_in_hash} hashes, ${uploaded_in_log} files (by log)"
    fi

    echo

    # ── LrC Catalog ───────────────────────────────────────────
    ui_info "${UI_BOLD}Lightroom Classic${UI_RESET}"

    if [[ -n "${PBAK_LRC_CATALOG:-}" ]]; then
        if [[ -f "$PBAK_LRC_CATALOG" ]]; then
            ui_success "Catalog: ${PBAK_LRC_CATALOG}"
        else
            ui_warn "Catalog not found: ${PBAK_LRC_CATALOG}"
            ((warnings++))
        fi
    else
        ui_dim "  Catalog: not configured"
    fi

    echo

    # ── Result ────────────────────────────────────────────────
    ui_header "Result"

    if [[ $issues -eq 0 && $warnings -eq 0 ]]; then
        ui_success "All checks passed. No issues found."
    elif [[ $issues -eq 0 ]]; then
        ui_success "No critical issues. ${warnings} warning(s)."
    else
        ui_error "${issues} issue(s), ${warnings} warning(s)."
    fi

    [[ $issues -eq 0 ]]
}

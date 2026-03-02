#!/bin/bash
# Upload state format (tab-separated):
# <status>\t<folder_path>\t<timestamp>\t<file_count>\t<exit_code>

_upload_usage() {
    cat <<EOF
${UI_BOLD}pbak upload${UI_RESET} — Upload photos from SSD to Immich

Uploads date-organized folders from the SSD to your Immich server using
immich-go. Tracks which folders have been uploaded to avoid re-uploading.

${UI_BOLD}Flags:${UI_RESET}
  --ssd <path>      Override SSD root (path or volume name)
  --date <YY/MM/DD> Upload a specific date folder only
  --all             Upload all pending (un-uploaded) folders
  --retry-failed    Retry previously failed uploads
  --force           Re-upload all folders (immich-go skips server-side dupes)
  -h, --help        Show this help

${UI_BOLD}Global flags also apply:${UI_RESET}  --dry-run, --verbose
EOF
}

upload_state_file() {
    local f="$(config_dir)/uploads.log"
    [[ -f "$f" ]] || touch "$f"
    echo "$f"
}

upload_log_dir() {
    local d="$(config_dir)/logs"
    mkdir -p "$d"
    echo "$d"
}

upload_is_uploaded() {
    local folder="$1"
    local sf
    sf="$(upload_state_file)"
    grep -qF "uploaded	${folder}	" "$sf" 2>/dev/null
}

upload_mark() {
    local folder="$1"
    local status="$2"
    local count="$3"
    local exit_code="$4"
    local sf
    sf="$(upload_state_file)"
    local ts
    ts="$(utils_timestamp)"

    # Remove-then-append to upsert the folder's state
    local tmp="${sf}.tmp"
    grep -vF "	${folder}	" "$sf" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$folder" "$ts" "$count" "$exit_code" >> "$tmp"
    mv "$tmp" "$sf"
}

upload_list_folders() {
    local ssd_root="$1"
    local db
    db="$(hash_db_file)"
    # Derive folder list from hash DB (single awk pass, no filesystem scan)
    awk -F '\t' -v prefix="$ssd_root/" '
        substr($3, 1, length(prefix)) == prefix {
            path = $3
            sub(/\/[^\/]+$/, "", path)
            if (!(path in seen)) { seen[path] = 1; print path }
        }
    ' "$db" | sort
}

upload_folder_file_count() {
    local folder="$1"
    local db
    db="$(hash_db_file)"
    awk -F '\t' -v prefix="$folder/" '
        substr($3, 1, length(prefix)) == prefix {
            rest = substr($3, length(prefix) + 1)
            if (index(rest, "/") == 0) count++
        }
        END { print count+0 }
    ' "$db"
}

upload_list_pending() {
    local ssd_root="$1"
    local db
    db="$(hash_db_file)"
    # Single awk pass: find folders with at least one un-uploaded file
    awk -F '\t' -v prefix="$ssd_root/" '
        substr($3, 1, length(prefix)) == prefix && ($6 == "" || $6 == "0") {
            path = $3
            sub(/\/[^\/]+$/, "", path)
            if (!(path in seen)) { seen[path] = 1; print path }
        }
    ' "$db" | sort
}

upload_list_failed() {
    local sf
    sf="$(upload_state_file)"
    grep "^failed	" "$sf" 2>/dev/null | cut -f 2
}

upload_count_by_status() {
    local status="$1"
    local sf
    sf="$(upload_state_file)"
    grep -c "^${status}	" "$sf" 2>/dev/null || echo 0
}

upload_files_by_status() {
    local status="$1"
    local sf
    sf="$(upload_state_file)"
    local total=0
    while IFS=$'\t' read -r _ _ _ count _; do
        total=$((total + count))
    done < <(grep "^${status}	" "$sf" 2>/dev/null)
    echo "$total"
}

# --- Upload dedup helpers (uses hash DB column 6) ---

# One-time migration: seed upload status in hash DB from uploads.log
_upload_migrate_to_hash_db() {
    local marker="$(config_dir)/.upload_status_migrated"
    [[ -f "$marker" ]] && return 0

    local sf
    sf="$(upload_state_file)"
    local db
    db="$(hash_db_file)"

    if ! grep -q "^uploaded	" "$sf" 2>/dev/null || [[ ! -s "$db" ]]; then
        touch "$marker"
        return 0
    fi

    # Build prefix file from uploaded folders
    local prefixes
    prefixes=$(mktemp)
    grep "^uploaded	" "$sf" | while IFS=$'\t' read -r _ folder _; do
        echo "${folder}/"
    done > "$prefixes"

    local ts
    ts="$(utils_timestamp)"
    local tmp
    tmp=$(mktemp)

    awk -F '\t' -v OFS='\t' -v ts="$ts" '
        NR == FNR { prefixes[NR] = $0; n = NR; next }
        {
            for (i = 1; i <= n; i++) {
                if (substr($3, 1, length(prefixes[i])) == prefixes[i]) {
                    $6 = ts
                    break
                }
            }
            print
        }
    ' "$prefixes" "$db" > "$tmp"

    mv "$tmp" "$db"
    rm -f "$prefixes"
    touch "$marker"

    local count
    count=$(hash_total_uploaded)
    if [[ $count -gt 0 ]]; then
        ui_dim "  Migrated upload status for ${count} files in hash database."
    fi
}

# Stage only un-uploaded files into a temp dir on the same volume.
# Uses hardlinks so there's no disk usage or copying.
_upload_stage_new_files() {
    local ssd_root="$1"
    local staging="$2"
    shift 2
    local folders=("$@")

    local db
    db="$(hash_db_file)"

    # Build prefix filter from selected folders
    local prefix_file
    prefix_file=$(mktemp)
    local f
    for f in "${folders[@]}"; do
        echo "${f}/"
    done > "$prefix_file"

    # Find files not yet uploaded (column 6 empty) under selected folders
    awk -F '\t' '
        NR == FNR { prefixes[NR] = $0; n = NR; next }
        ($6 == "" || $6 == "0") {
            for (i = 1; i <= n; i++) {
                if (substr($3, 1, length(prefixes[i])) == prefixes[i]) {
                    print $3
                    break
                }
            }
        }
    ' "$prefix_file" "$db" | while IFS= read -r filepath; do
        if [[ -f "$filepath" ]]; then
            local rel="${filepath#${ssd_root}/}"
            local dest="${staging}/${rel}"
            mkdir -p "$(dirname "$dest")"
            ln "$filepath" "$dest" 2>/dev/null || cp -p "$filepath" "$dest"
        fi
    done

    rm -f "$prefix_file"
    find "$staging" -type f 2>/dev/null | wc -l | tr -d ' '
}

upload_run() {
    # Accepts one or more folder paths as arguments
    local log_file
    log_file="$(upload_log_dir)/upload-$(date '+%Y%m%d-%H%M%S').log"

    local cmd=(
        immich-go upload from-folder
        --server="${PBAK_IMMICH_SERVER}"
        --api-key="${PBAK_IMMICH_API_KEY}"
        --recursive
    )

    if [[ -n "${PBAK_UPLOAD_EXTENSIONS_INCLUDE:-}" ]]; then
        cmd+=(--include-extensions="${PBAK_UPLOAD_EXTENSIONS_INCLUDE}")
    fi
    if [[ -n "${PBAK_UPLOAD_EXTENSIONS_EXCLUDE:-}" ]]; then
        cmd+=(--exclude-extensions="${PBAK_UPLOAD_EXTENSIONS_EXCLUDE}")
    fi
    if [[ "${PBAK_UPLOAD_PAUSE_JOBS:-true}" == "true" ]]; then
        cmd+=(--pause-immich-jobs)
    fi
    cmd+=(--concurrent-tasks="${PBAK_CONCURRENT_TASKS:-4}")
    cmd+=(--log-file="$log_file")

    if utils_is_dry_run; then
        cmd+=(--dry-run)
    fi

    cmd+=("$@")

    utils_log DEBUG "Running: ${cmd[*]}"

    local exit_code=0
    "${cmd[@]}" || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        ui_warn "  Log file: ${log_file}"
    fi

    return "$exit_code"
}

upload_select_folders() {
    local ssd_root="$1"

    local pending=()
    while IFS= read -r folder; do
        pending+=("$folder")
    done < <(upload_list_pending "$ssd_root")

    if [[ ${#pending[@]} -eq 0 ]]; then
        return 1
    fi

    local display=()
    local i
    for ((i = 0; i < ${#pending[@]}; i++)); do
        local folder="${pending[$i]}"
        local rel_path="${folder#${ssd_root}/}"
        [[ "$folder" == "$ssd_root" ]] && rel_path="(root)"
        local total_count new_count
        total_count=$(upload_folder_file_count "$folder")
        new_count=$(hash_folder_new_count "$folder")
        if [[ $new_count -lt $total_count ]]; then
            display+=("${rel_path} (${new_count} new / ${total_count} total)")
        else
            display+=("${rel_path} (${total_count} files)")
        fi
    done

    local selected
    selected=$(ui_select_multi "Select folders to upload:" "${display[@]}")

    if [[ -z "$selected" ]]; then
        return 1
    fi

    # Strip " (N files)" suffix to recover relative path
    while IFS= read -r line; do
        local rel="${line%% (*}"
        if [[ "$rel" == "(root)" ]]; then
            echo "$ssd_root"
        else
            echo "${ssd_root}/${rel}"
        fi
    done <<< "$selected"
}

# Resolve SSD root from override or config
_upload_resolve_ssd_root() {
    local override="$1"

    if [[ -n "$override" ]]; then
        utils_resolve_override "$override" "full_dump"
        return 0
    fi

    if [[ -n "${PBAK_SSD_ROOT:-}" ]]; then
        echo "$PBAK_SSD_ROOT"
        return 0
    fi

    # Fallback: interactive volume picker
    local volumes
    volumes=($(utils_list_volumes))
    if [[ ${#volumes[@]} -eq 0 ]]; then
        ui_error "No SSD configured and no volumes found. Use --ssd <path>."
        exit 1
    fi
    local vol
    vol=$(ui_select "Select SSD volume:" "${volumes[@]}")
    echo "$(_utils_volume_prefix)/${vol}/full_dump"
}

pbak_upload() {
    local ssd_override=""
    local date_filter=""
    local upload_all=0
    local retry_failed=0
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssd)          ssd_override="$2"; shift 2 ;;
            --date)         date_filter="$2"; shift 2 ;;
            --all)          upload_all=1; shift ;;
            --retry-failed) retry_failed=1; shift ;;
            --force)        force=1; shift ;;
            -h|--help)      _upload_usage; return 0 ;;
            *) ui_error "Unknown flag: $1"; _upload_usage; return 1 ;;
        esac
    done

    config_require
    if ! config_validate; then
        ui_error "Immich server details missing. Run 'pbak setup'."
        exit 1
    fi
    utils_check_deps

    ui_header "Photo Upload: SSD -> Immich"

    _upload_migrate_to_hash_db

    if utils_is_dry_run; then
        ui_warn "[DRY RUN] immich-go will run in dry-run mode."
    fi

    local ssd_root
    ssd_root=$(_upload_resolve_ssd_root "$ssd_override")
    utils_require_path "$ssd_root" "SSD dump directory" || exit 1

    # Quick size-based check for overwritten files (re-exports, re-edits)
    hash_detect_changed "$ssd_root"

    local folders=()

    if [[ $force -eq 1 ]]; then
        ui_warn "Force mode: ignoring upload state, immich-go will skip server-side dupes."
    fi

    if [[ -n "$date_filter" ]]; then
        local target="${ssd_root}/${date_filter}"
        if [[ ! -d "$target" ]]; then
            ui_error "Folder not found: ${target}"
            exit 1
        fi
        folders+=("$target")

    elif [[ $retry_failed -eq 1 ]]; then
        while IFS= read -r folder; do
            if [[ -d "$folder" ]]; then
                folders+=("$folder")
            fi
        done < <(upload_list_failed)

    elif [[ $upload_all -eq 1 || $force -eq 1 ]]; then
        # --all or bare --force: all pending (or all folders if force)
        while IFS= read -r folder; do
            folders+=("$folder")
        done < <(if [[ $force -eq 1 ]]; then upload_list_folders "$ssd_root"; else upload_list_pending "$ssd_root"; fi)

    else
        while IFS= read -r folder; do
            folders+=("$folder")
        done < <(upload_select_folders "$ssd_root" || true)
    fi

    if [[ ${#folders[@]} -eq 0 ]]; then
        ui_info "Nothing to upload."
        return 0
    fi

    # Pre-compute file counts
    local counts=() new_counts=()
    local i
    for ((i = 0; i < ${#folders[@]}; i++)); do
        counts+=("$(upload_folder_file_count "${folders[$i]}")")
        new_counts+=("$(hash_folder_new_count "${folders[$i]}")")
    done

    # Display folder summary
    echo
    local skipped=0
    for ((i = 0; i < ${#folders[@]}; i++)); do
        local rel_path="${folders[$i]#${ssd_root}/}"
        [[ "${folders[$i]}" == "$ssd_root" ]] && rel_path="(root)"

        if [[ ${new_counts[$i]} -eq 0 && $force -eq 0 ]]; then
            ui_dim "  ${rel_path}: ${counts[$i]} files (all uploaded)"
            skipped=$((skipped + 1))
        elif [[ ${new_counts[$i]} -lt ${counts[$i]} ]]; then
            ui_info "  ${rel_path}: ${new_counts[$i]} new / ${counts[$i]} total"
        else
            ui_info "  ${rel_path}: ${counts[$i]} files"
        fi
    done

    # Filter to folders with new files (unless --force)
    local upload_folders=() upload_counts=()
    for ((i = 0; i < ${#folders[@]}; i++)); do
        if [[ ${new_counts[$i]} -gt 0 || $force -eq 1 ]]; then
            upload_folders+=("${folders[$i]}")
            upload_counts+=("${counts[$i]}")
        fi
    done

    if [[ ${#upload_folders[@]} -eq 0 ]]; then
        echo
        ui_info "All files already uploaded."
        return 0
    fi

    echo
    ui_info "Uploading ${UI_BOLD}${#upload_folders[@]}${UI_RESET} folder(s) to ${PBAK_IMMICH_SERVER}"
    echo

    # Mark all as in_progress
    for ((i = 0; i < ${#upload_folders[@]}; i++)); do
        upload_mark "${upload_folders[$i]}" "in_progress" "${upload_counts[$i]}" ""
    done

    local exit_code=0
    if [[ $force -eq 1 ]]; then
        # Force mode: send all files, let immich-go handle server-side dedup
        upload_run "${upload_folders[@]}" || exit_code=$?
    else
        # Stage only new files into a temp directory so immich-go only
        # processes files not yet uploaded (per hash DB column 6).
        local staging="${ssd_root}/.pbak-upload-staging"
        rm -rf "$staging"
        local staged_count
        staged_count=$(_upload_stage_new_files "$ssd_root" "$staging" "${upload_folders[@]}")

        if [[ $staged_count -eq 0 ]]; then
            rm -rf "$staging"
            echo
            ui_info "All files already uploaded (per hash DB)."
            return 0
        fi

        ui_info "Staging ${staged_count} new files for upload..."
        echo
        upload_run "$staging" || exit_code=$?
        rm -rf "$staging"
    fi

    # Mark results
    for ((i = 0; i < ${#upload_folders[@]}; i++)); do
        if [[ $exit_code -eq 0 ]]; then
            upload_mark "${upload_folders[$i]}" "uploaded" "${upload_counts[$i]}" "0"
            hash_mark_uploaded "${upload_folders[$i]}" "$ssd_root"
        else
            upload_mark "${upload_folders[$i]}" "failed" "${upload_counts[$i]}" "$exit_code"
        fi
    done

    # Stack related files (TIF/DNG/ARW) on successful upload
    if [[ $exit_code -eq 0 ]]; then
        echo
        ui_dim "  Waiting for Immich to index new assets..."
        sleep 3
        ui_info "Stacking related files on Immich..."
        PBAK_DRY_RUN="${DRY_RUN}" \
        PBAK_VERBOSE="${VERBOSE}" \
        PBAK_IMMICH_SERVER="${PBAK_IMMICH_SERVER}" \
        PBAK_IMMICH_API_KEY="${PBAK_IMMICH_API_KEY}" \
            python3 "${PBAK_LIB}/immich.py" stack || \
            ui_warn "Stacking failed (non-fatal)"
    fi

    # Summary
    echo
    ui_header "Summary"
    if [[ $exit_code -eq 0 ]]; then
        ui_success "Uploaded: ${#upload_folders[@]} folder(s)"
    else
        ui_error "Upload failed (exit code ${exit_code})"
        ui_dim "  Retry with: pbak upload --retry-failed"
    fi
    if [[ $skipped -gt 0 ]]; then
        ui_dim "  Skipped: ${skipped} (already uploaded)"
    fi
    ui_dim "  Tracked uploads: $(hash_total_uploaded) file hashes"
}

pbak_status() {
    case "${1:-}" in
        -h|--help)
            cat <<EOF
${UI_BOLD}pbak status${UI_RESET} — Show backup status and configuration
EOF
            return 0 ;;
    esac

    config_require

    ui_header "pbak v${PBAK_VERSION} — Status"

    printf '  %-24s %s\n' "Immich server:" "${PBAK_IMMICH_SERVER:-<not set>}"
    printf '  %-24s %s\n' "API key:" "${PBAK_IMMICH_API_KEY:+${PBAK_IMMICH_API_KEY:0:8}...}"

    # Connectivity check
    if [[ -n "${PBAK_IMMICH_SERVER:-}" && -n "${PBAK_IMMICH_API_KEY:-}" ]]; then
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -H "x-api-key: ${PBAK_IMMICH_API_KEY}" \
            "${PBAK_IMMICH_SERVER}/api/server/ping" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            printf '  %-24s %b\n' "Server status:" "${UI_GREEN}connected${UI_RESET}"
        elif [[ "$http_code" == "401" ]]; then
            printf '  %-24s %b\n' "Server status:" "${UI_RED}invalid API key${UI_RESET}"
        elif [[ "$http_code" == "000" ]]; then
            printf '  %-24s %b\n' "Server status:" "${UI_RED}unreachable${UI_RESET}"
        else
            printf '  %-24s %b\n' "Server status:" "${UI_YELLOW}HTTP ${http_code}${UI_RESET}"
        fi
    fi

    local sd_status="not accessible"
    if [[ -n "${PBAK_SD_ROOT:-}" ]] && [[ -d "${PBAK_SD_ROOT}" ]]; then
        sd_status="${UI_GREEN}accessible${UI_RESET}"
    fi
    local ssd_status="not accessible"
    if [[ -n "${PBAK_SSD_ROOT:-}" ]] && [[ -d "${PBAK_SSD_ROOT}" ]]; then
        ssd_status="${UI_GREEN}accessible${UI_RESET}"
    fi
    local mirror_status="not accessible"
    if [[ -n "${PBAK_MIRROR_ROOT:-}" ]] && [[ -d "${PBAK_MIRROR_ROOT}" ]]; then
        mirror_status="${UI_GREEN}accessible${UI_RESET}"
    fi
    printf '  %-24s %s (%b)\n' "SD source:" "${PBAK_SD_ROOT:-<not set>}" "$sd_status"
    printf '  %-24s %s (%b)\n' "SSD root:" "${PBAK_SSD_ROOT:-<not set>}" "$ssd_status"
    printf '  %-24s %s (%b)\n' "Mirror root:" "${PBAK_MIRROR_ROOT:-<not set>}" "$mirror_status"
    echo

    local hcount
    hcount=$(hash_count)
    local hsize
    hsize=$(utils_human_size "$(hash_db_size)")
    printf '  %-24s %s files (%s)\n' "Backup database:" "$hcount" "$hsize"

    local up_count up_files fail_count fail_files
    up_count=$(upload_count_by_status "uploaded")
    up_files=$(upload_files_by_status "uploaded")
    fail_count=$(upload_count_by_status "failed")
    fail_files=$(upload_files_by_status "failed")

    local hash_uploaded
    hash_uploaded=$(hash_total_uploaded)

    echo
    printf '  %-24s %s folder(s), %s files\n' "Uploaded:" "$up_count" "$up_files"
    printf '  %-24s %s folder(s), %s files\n' "Failed:" "$fail_count" "$fail_files"
    printf '  %-24s %s unique file hashes\n' "Tracked (by hash):" "$hash_uploaded"

    if [[ -n "${PBAK_SSD_ROOT:-}" ]] && [[ -d "${PBAK_SSD_ROOT}" ]]; then
        local pending_count=0
        while IFS= read -r _; do
            pending_count=$((pending_count + 1))
        done < <(upload_list_pending "${PBAK_SSD_ROOT}")
        printf '  %-24s %s folder(s)\n' "Pending upload:" "$pending_count"
    fi
    echo
}

pbak_rehash() {
    case "${1:-}" in
        -h|--help)
            cat <<EOF
${UI_BOLD}pbak rehash${UI_RESET} — Rebuild hash database from SSD contents

Scans all files in the SSD dump directory and rebuilds the hash
database. Useful if the database was lost or corrupted.

${UI_BOLD}Flags:${UI_RESET}
  --ssd <path>    Override SSD root (path or volume name)
  -h, --help      Show this help

${UI_BOLD}Global flags also apply:${UI_RESET}  --dry-run, --verbose
EOF
            return 0 ;;
    esac

    config_require

    local ssd_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssd) ssd_override="$2"; shift 2 ;;
            *) ui_error "Unknown flag: $1"; return 1 ;;
        esac
    done

    local ssd_root
    ssd_root=$(_upload_resolve_ssd_root "$ssd_override")
    utils_require_path "$ssd_root" "SSD dump directory" || exit 1

    hash_rebuild "$ssd_root"
}

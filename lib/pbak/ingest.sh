#!/bin/bash

_ingest_usage() {
    cat <<EOF
${UI_BOLD}pbak ingest${UI_RESET} — Register untracked files or import from external folder

${UI_BOLD}Scan mode (default):${UI_RESET}
  Scans the SSD for files not yet tracked in the hash database and
  registers them in-place. Use after exporting from Lightroom, DxO,
  or any app that places files directly on the SSD.

${UI_BOLD}Import mode (--from):${UI_RESET}
  Imports files from an external folder into the SSD date structure.
  Files are organized by EXIF date into YYYY/MM/DD folders and
  registered in the hash database.

${UI_BOLD}Flags:${UI_RESET}
  --from <path>     Import from this folder (omit to scan SSD)
  --ssd <path>      Override SSD dump root (path or volume name)
  --move            Move files instead of copy (import mode only)
  --no-sidecars     Skip sidecar detection (.xmp, .dop, .pp3)
  -h, --help        Show this help

${UI_BOLD}Global flags also apply:${UI_RESET}  --dry-run, --verbose

${UI_BOLD}Recommended LrC workflow:${UI_RESET}
  1. Export from Lightroom with destination "Same folder as original photo"
  2. Run: pbak ingest
  3. Run: pbak upload --all
EOF
}

pbak_ingest() {
    local from_path=""
    local ssd_override=""
    local do_move=0
    local no_sidecars=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)        from_path="$2"; shift 2 ;;
            --ssd)         ssd_override="$2"; shift 2 ;;
            --move)        do_move=1; shift ;;
            --no-sidecars) no_sidecars=1; shift ;;
            -h|--help)     _ingest_usage; return 0 ;;
            *)             ui_error "Unknown flag: $1"; _ingest_usage; return 1 ;;
        esac
    done

    config_require

    # Resolve SSD root
    local ssd_root=""
    if [[ -n "$ssd_override" ]]; then
        ssd_root=$(utils_resolve_override "$ssd_override" "full_dump")
    elif [[ -n "${PBAK_SSD_ROOT:-}" ]]; then
        ssd_root="$PBAK_SSD_ROOT"
    else
        ui_error "No SSD configured. Use --ssd <path> or run 'pbak setup'."
        return 1
    fi
    utils_require_path "$ssd_root" "SSD dump root" || return 1

    if [[ -n "$from_path" ]]; then
        _ingest_import "$from_path" "$ssd_root" "$do_move" "$no_sidecars"
    else
        if [[ "$do_move" -eq 1 ]]; then
            ui_warn "--move is only used with --from. Ignoring."
        fi
        _ingest_scan "$ssd_root" "$no_sidecars"
    fi
}

# ── Scan mode: discover untracked files already on SSD ───────────────

_ingest_scan() {
    local ssd_root="$1"
    local no_sidecars="$2"

    ui_header "Ingest: Scan SSD for untracked files"
    ui_info "SSD root: ${ssd_root}"

    # Scan SSD for media files
    ui_spinner_start "Scanning files..."
    local all_files
    all_files=$(mktemp)
    dump_scan_files "$ssd_root" \
        "${PBAK_DUMP_EXTENSIONS_INCLUDE:-}" \
        "${PBAK_DUMP_EXTENSIONS_EXCLUDE:-}" > "$all_files"
    ui_spinner_stop

    local total_on_ssd
    total_on_ssd=$(wc -l < "$all_files" | tr -d ' ')

    if [[ $total_on_ssd -eq 0 ]]; then
        rm -f "$all_files"
        ui_info "No matching files found on SSD."
        return 0
    fi

    # Build set of paths already tracked in hash DB (column 3 = dest_path)
    local db
    db="$(hash_db_file)"
    local tracked_set
    tracked_set=$(mktemp)
    if [[ -s "$db" ]]; then
        awk -F '\t' '{ print $3 }' "$db" | sort > "$tracked_set"
    fi

    # Find untracked files
    local untracked
    untracked=$(mktemp)
    if [[ -s "$tracked_set" ]]; then
        sort "$all_files" | comm -23 - "$tracked_set" > "$untracked"
    else
        sort "$all_files" > "$untracked"
    fi
    rm -f "$all_files" "$tracked_set"

    local total
    total=$(wc -l < "$untracked" | tr -d ' ')

    if [[ $total -eq 0 ]]; then
        rm -f "$untracked"
        ui_success "All ${total_on_ssd} files on SSD are already tracked."
        return 0
    fi

    ui_info "Found ${UI_BOLD}${total}${UI_RESET} untracked files (of ${total_on_ssd} total)"
    echo

    if utils_is_dry_run; then
        ui_warn "[DRY RUN] No files will be registered."
        while IFS= read -r f; do
            ui_info "[dry-run] Would register: ${f}"
        done < "$untracked"
        rm -f "$untracked"
        return 0
    fi

    # Hash all untracked files in parallel
    ui_info "Hashing ${total} files (${HASH_WORKERS} workers)..."
    local hash_output
    hash_output=$(mktemp)
    ui_spinner_start "Hashing..."
    hash_compute_batch "$untracked" "$hash_output"
    ui_spinner_stop

    # Register each file (src=dest since already in place)
    local registered=0 skipped=0 sidecar_count=0
    local count=0

    while IFS= read -r line; do
        local hash filepath
        hash="${line%% *}"
        # shasum format: "hash  filepath" — extract after "hash  "
        filepath="${line#*  }"

        count=$((count + 1))
        ui_progress "$count" "$total" "$(basename "$filepath")"

        if [[ -z "$hash" || ${#hash} -ne 64 ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        if hash_exists "$hash"; then
            skipped=$((skipped + 1))
            continue
        fi

        local size
        size=$(utils_file_size "$filepath")
        hash_add "$hash" "$filepath" "$filepath" "$size"
        registered=$((registered + 1))

        # Process sidecars
        if [[ "$no_sidecars" -eq 0 ]]; then
            local dest_dir
            dest_dir="$(dirname "$filepath")"
            while IFS= read -r sidecar; do
                utils_process_sidecar "$sidecar" "$dest_dir" 0
                sidecar_count=$((sidecar_count + 1))
            done < <(utils_find_sidecars "$filepath")
        fi
    done < "$hash_output"

    ui_progress_done
    rm -f "$untracked" "$hash_output"

    echo
    ui_header "Summary"
    ui_success "Registered: ${registered} files"
    if [[ $skipped -gt 0 ]]; then
        ui_dim "  Skipped: ${skipped} (already tracked by hash)"
    fi
    if [[ $sidecar_count -gt 0 ]]; then
        ui_dim "  Sidecars: ${sidecar_count}"
    fi
    echo
    ui_info "Hash DB: $(hash_count) total files tracked"
}

# ── Import mode: bring files from external folder to SSD ─────────────

_ingest_import() {
    local from_path="$1"
    local ssd_root="$2"
    local do_move="$3"
    local no_sidecars="$4"

    ui_header "Ingest: Import files to SSD"

    utils_require_path "$from_path" "Source folder" || return 1
    utils_path_is_writable "$ssd_root" || return 1

    local action="Copy"
    [[ "$do_move" -eq 1 ]] && action="Move"

    ui_info "Source: ${from_path}"
    ui_info "Target: ${ssd_root}"
    ui_info "Mode:   ${action}"

    if utils_is_dry_run; then
        ui_warn "[DRY RUN] No files will be ${action,,}d."
    fi

    echo
    ui_info "Scanning source..."

    local tmpfile
    tmpfile=$(mktemp)
    dump_scan_files "$from_path" \
        "${PBAK_DUMP_EXTENSIONS_INCLUDE:-}" \
        "${PBAK_DUMP_EXTENSIONS_EXCLUDE:-}" > "$tmpfile"

    local total
    total=$(wc -l < "$tmpfile" | tr -d ' ')

    if [[ $total -eq 0 ]]; then
        rm -f "$tmpfile"
        ui_info "No matching files found in source."
        return 0
    fi

    # Get source file sizes
    local src_info
    src_info=$(mktemp)
    tr '\n' '\0' < "$tmpfile" | utils_bulk_stat > "$src_info"

    local total_bytes
    total_bytes=$(awk -F '\t' '{ s += $1 } END { print s+0 }' "$src_info")

    ui_info "Found ${UI_BOLD}${total}${UI_RESET} files ($(utils_human_size "$total_bytes"))"

    # Space check (only for copy, not move on same filesystem)
    if [[ "$do_move" -eq 0 ]]; then
        local avail_kb
        avail_kb=$(utils_path_available_kb "$ssd_root")
        local avail_bytes=$((avail_kb * 1024))
        if [[ $total_bytes -gt $avail_bytes ]]; then
            ui_warn "Files require $(utils_human_size "$total_bytes") but target has $(utils_human_size "$avail_bytes") free."
            if ! ui_confirm "  Continue anyway?"; then
                rm -f "$tmpfile" "$src_info"
                return 1
            fi
        fi
    fi

    echo

    # Pre-hash all source files
    local hash_cache
    hash_cache=$(mktemp)
    local files_to_hash
    files_to_hash=$(mktemp)

    local db
    db="$(hash_db_file)"

    if [[ -s "$db" ]]; then
        ui_info "Checking hash database for known files..."
        local db_lookup
        db_lookup=$(mktemp)
        awk -F '\t' '{
            n = split($3, a, "/")
            printf "%s\t%s\t%s\n", a[n], $5, $1
        }' "$db" > "$db_lookup"

        awk -F '\t' -v out_known="$hash_cache" -v out_unknown="$files_to_hash" '
            NR == FNR {
                key = $1 "\t" $2
                if (!(key in db)) db[key] = $3
                next
            }
            {
                size = $1
                path = substr($0, index($0, "\t") + 1)
                n = split(path, a, "/")
                key = a[n] "\t" size
                if (key in db)
                    printf "%s  %s\n", db[key], path > out_known
                else
                    print path > out_unknown
            }
        ' "$db_lookup" "$src_info"

        local known_count
        known_count=$(wc -l < "$hash_cache" 2>/dev/null | tr -d ' ')
        if [[ $known_count -gt 0 ]]; then
            ui_dim "  ${known_count} files matched in hash DB (skipping re-hash)"
        fi
        rm -f "$db_lookup"
    else
        awk -F '\t' '{ print substr($0, index($0, "\t") + 1) }' "$src_info" > "$files_to_hash"
    fi
    rm -f "$src_info"

    local to_hash
    to_hash=$(wc -l < "$files_to_hash" 2>/dev/null | tr -d ' ')
    local pre_skipped=$((total - to_hash))

    if [[ $to_hash -gt 0 ]]; then
        ui_info "Pre-hashing ${to_hash} new files (${HASH_WORKERS} workers)..."
        local new_hashes
        new_hashes=$(mktemp)
        ui_spinner_start "Hashing..."
        hash_compute_batch "$files_to_hash" "$new_hashes"
        ui_spinner_stop
        cat "$new_hashes" >> "$hash_cache"
        rm -f "$new_hashes"
        ui_success "Hashing complete."
    else
        rm -f "$tmpfile" "$files_to_hash" "$hash_cache"
        echo
        ui_header "Summary"
        ui_success "${action}d: 0 files"
        ui_dim "  Skipped: ${pre_skipped} (already backed up)"
        echo
        ui_info "Hash DB: $(hash_count) total files tracked"
        return 0
    fi

    # Build SSD index for collision/dedup detection
    local ssd_index
    ssd_index=$(mktemp)
    ui_spinner_start "Indexing SSD files..."
    find "$ssd_root" -type f -print0 2>/dev/null | \
        utils_bulk_stat | \
        awk -F '\t' '{
            n = split($2, a, "/")
            printf "%s\t%s\t%s\n", a[n], $1, $2
        }' | sort > "$ssd_index" || true
    ui_spinner_stop
    echo

    # Main processing loop — only iterate new files, not already-tracked ones
    local copied=0 skipped=0 errors=0 sidecar_count=0
    local count=0
    local copied_bytes=0

    while IFS= read -r filepath; do
        count=$((count + 1))
        ui_progress "$count" "$to_hash" "$(basename "$filepath")"

        # Use dump_process_file for the heavy lifting (hash dedup, EXIF date, copy)
        local status=0
        dump_process_file "$filepath" "$ssd_root" "$hash_cache" "$ssd_index" || status=$?

        case $status in
            0)
                copied=$((copied + 1))
                copied_bytes=$((copied_bytes + $(utils_file_size "$filepath")))

                # Move: remove source after successful copy
                if [[ "$do_move" -eq 1 ]] && ! utils_is_dry_run; then
                    rm -f "$filepath"
                fi

                # Process sidecars
                if [[ "$no_sidecars" -eq 0 ]]; then
                    local date_path dest_dir
                    date_path=$(dump_extract_date "$filepath")
                    dest_dir="${ssd_root}/${date_path}"
                    while IFS= read -r sidecar; do
                        utils_process_sidecar "$sidecar" "$dest_dir" "$do_move"
                        sidecar_count=$((sidecar_count + 1))
                    done < <(utils_find_sidecars "$filepath")
                fi
                ;;
            1) skipped=$((skipped + 1)) ;;
            *) errors=$((errors + 1)) ;;
        esac
    done < "$files_to_hash"

    ui_progress_done
    echo

    rm -f "$tmpfile" "$files_to_hash" "$hash_cache" "$ssd_index"
    skipped=$((skipped + pre_skipped))

    ui_header "Summary"
    ui_success "${action}d: ${copied} files ($(utils_human_size "$copied_bytes"))"
    if [[ $skipped -gt 0 ]]; then
        ui_dim "  Skipped: ${skipped} (already backed up)"
    fi
    if [[ $sidecar_count -gt 0 ]]; then
        ui_dim "  Sidecars: ${sidecar_count}"
    fi
    if [[ $errors -gt 0 ]]; then
        ui_error "Errors: ${errors}"
    fi
    echo
    ui_info "Hash DB: $(hash_count) total files tracked"

    # Mirror sync if configured
    if [[ -n "${PBAK_MIRROR_ROOT:-}" && -d "$PBAK_MIRROR_ROOT" ]]; then
        echo
        ui_info "Mirror '${PBAK_MIRROR_ROOT}' detected — syncing..."
        pbak_sync --from "$ssd_root" --to "$PBAK_MIRROR_ROOT"
    fi
}

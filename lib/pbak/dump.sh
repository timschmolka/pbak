#!/bin/bash

_dump_usage() {
    cat <<EOF
${UI_BOLD}pbak dump${UI_RESET} — Copy photos from SD card to SSD

Scans the SD card source folder, extracts dates from EXIF data, and copies
files into a YYYY/MM/DD folder structure on the SSD. Uses SHA-256 hashes
to skip files that have already been backed up.

${UI_BOLD}Flags:${UI_RESET}
  --sd <path>     Override SD card source (path or volume name)
  --ssd <path>    Override SSD target (path or volume name)
  -h, --help      Show this help

${UI_BOLD}Global flags also apply:${UI_RESET}  --dry-run, --verbose
EOF
}

dump_extract_date() {
    local filepath="$1"
    local date

    date=$(exiftool -DateTimeOriginal -d '%Y/%m/%d' -s3 -f "$filepath" 2>/dev/null)
    if [[ "$date" != "-" && -n "$date" && "$date" != *"0000"* ]]; then
        echo "$date"; return 0
    fi

    date=$(exiftool -CreateDate -d '%Y/%m/%d' -s3 -f "$filepath" 2>/dev/null)
    if [[ "$date" != "-" && -n "$date" && "$date" != *"0000"* ]]; then
        echo "$date"; return 0
    fi

    date=$(exiftool -FileModifyDate -d '%Y/%m/%d' -s3 -f "$filepath" 2>/dev/null)
    if [[ "$date" != "-" && -n "$date" && "$date" != *"0000"* ]]; then
        echo "$date"; return 0
    fi

    date=$(utils_fs_date "$filepath")
    if [[ -n "$date" ]]; then
        echo "$date"; return 0
    fi

    date -u '+%Y/%m/%d'
}

dump_scan_files() {
    local dcim_path="$1"
    local include_exts="$2"
    local exclude_exts="$3"

    local find_args=()
    find_args+=("$dcim_path" "-type" "f" "-not" "-name" "._*")

    if [[ -n "$include_exts" ]]; then
        find_args+=("(")
        local first=1
        local IFS=','
        for ext in $include_exts; do
            ext="${ext# }"
            [[ "$ext" != .* ]] && ext=".${ext}"
            if [[ $first -eq 1 ]]; then
                first=0
            else
                find_args+=("-o")
            fi
            find_args+=("-iname" "*${ext}")
        done
        find_args+=(")")
    fi

    # Exclude filter runs as a second pass — simpler than nested find predicates
    if [[ -n "$exclude_exts" ]]; then
        find "${find_args[@]}" 2>/dev/null | while IFS= read -r f; do
            local fname fext
            fname="$(basename "$f")"
            fext=".${fname##*.}"
            fext="$(echo "$fext" | tr '[:upper:]' '[:lower:]')"

            local skip=0
            local IFS=','
            for eext in $exclude_exts; do
                eext="${eext# }"
                [[ "$eext" != .* ]] && eext=".${eext}"
                eext="$(echo "$eext" | tr '[:upper:]' '[:lower:]')"
                if [[ "$fext" == "$eext" ]]; then
                    skip=1
                    break
                fi
            done
            [[ $skip -eq 0 ]] && echo "$f"
        done
    else
        find "${find_args[@]}" 2>/dev/null
    fi
}

# Resolve SD card source root path.
# Returns a full path (e.g. /Volumes/T7/DCIM or /home/user/photos).
dump_select_sd() {
    local override="$1"

    if [[ -n "$override" ]]; then
        local path
        path=$(utils_resolve_override "$override" "DCIM")
        utils_require_path "$path" "SD source" || exit 1
        echo "$path"
        return 0
    fi

    if [[ -n "${PBAK_SD_ROOT:-}" ]]; then
        if [[ -d "$PBAK_SD_ROOT" ]]; then
            if ui_confirm "  Use SD source '${PBAK_SD_ROOT}'?"; then
                echo "$PBAK_SD_ROOT"
                return 0
            fi
        else
            ui_warn "Default SD source '${PBAK_SD_ROOT}' is not accessible."
        fi
    fi

    local volumes
    volumes=($(utils_list_volumes))
    if [[ ${#volumes[@]} -eq 0 ]]; then
        ui_error "No external volumes found. Use --sd <path> to specify a source."
        exit 1
    fi

    local choice
    choice=$(ui_select "Select SD card volume:" "${volumes[@]}")
    echo "$(_utils_volume_prefix)/${choice}/DCIM"
}

# Resolve SSD dump root path.
# Returns a full path (e.g. /Volumes/Samsung/full_dump or /mnt/nas/backup).
dump_select_ssd() {
    local override="$1"

    if [[ -n "$override" ]]; then
        local path
        path=$(utils_resolve_override "$override" "full_dump")
        utils_require_path "$path" "SSD target" || exit 1
        echo "$path"
        return 0
    fi

    if [[ -n "${PBAK_SSD_ROOT:-}" ]]; then
        if [[ -d "$PBAK_SSD_ROOT" ]]; then
            if ui_confirm "  Use SSD '${PBAK_SSD_ROOT}'?"; then
                echo "$PBAK_SSD_ROOT"
                return 0
            fi
        else
            ui_warn "Default SSD '${PBAK_SSD_ROOT}' is not accessible."
        fi
    fi

    local volumes
    volumes=($(utils_list_volumes))
    if [[ ${#volumes[@]} -eq 0 ]]; then
        ui_error "No external volumes found. Use --ssd <path> to specify a target."
        exit 1
    fi

    local choice
    choice=$(ui_select "Select SSD volume:" "${volumes[@]}")
    echo "$(_utils_volume_prefix)/${choice}/full_dump"
}

# Returns: 0=copied, 1=skipped (dup), 2=error
dump_process_file() {
    local src_file="$1"
    local ssd_dump_root="$2"
    local precomputed_hashes="${3:-}"
    local ssd_index="${4:-}"

    local hash
    if [[ -n "$precomputed_hashes" ]]; then
        hash=$(hash_lookup_precomputed "$src_file" "$precomputed_hashes")
    fi
    if [[ -z "${hash:-}" ]]; then
        hash=$(hash_compute "$src_file") || return 2
    fi

    if hash_exists "$hash"; then
        utils_log DEBUG "Skipping (duplicate): ${src_file}"
        return 1
    fi

    # Safety net: check if file already exists on SSD but is missing from hash DB
    if [[ -n "$ssd_index" ]]; then
        local src_name src_size
        src_name=$(basename "$src_file")
        src_size=$(utils_file_size "$src_file")

        local match
        match=$(grep -F "$src_name" "$ssd_index" | \
            awk -F '\t' -v fn="$src_name" -v sz="$src_size" \
                '$1 == fn && $2 == sz { print $3; exit }')

        if [[ -n "$match" ]]; then
            local match_hash
            match_hash=$(hash_compute "$match")
            if [[ "$hash" == "$match_hash" ]]; then
                hash_add "$hash" "$src_file" "$match" "$src_size"
                utils_log DEBUG "Skipping (found on SSD): ${src_file} -> ${match}"
                return 1
            fi
        fi
    fi

    local date_path
    date_path=$(dump_extract_date "$src_file")

    local dest_dir="${ssd_dump_root}/${date_path}"
    local filename
    filename="$(basename "$src_file")"
    local name_no_ext="${filename%.*}"
    local ext=".${filename##*.}"

    local dest_file
    dest_file=$(hash_resolve_collision "$dest_dir" "$name_no_ext" "$ext") || return 2

    if utils_is_dry_run; then
        local size
        size=$(utils_file_size "$src_file")
        ui_info "[dry-run] Would copy: ${src_file} -> ${dest_file} ($(utils_human_size "$size"))"
        return 0
    fi

    utils_ensure_dir "$dest_dir"

    if ! cp -p "$src_file" "$dest_file" 2>/dev/null; then
        ui_error "Failed to copy: ${src_file}"
        return 2
    fi

    local dest_hash
    dest_hash=$(hash_compute "$dest_file")
    if [[ "$hash" != "$dest_hash" ]]; then
        ui_error "Hash mismatch after copy! ${src_file}"
        rm -f "$dest_file"
        return 2
    fi

    local size
    size=$(utils_file_size "$src_file")
    hash_add "$hash" "$src_file" "$dest_file" "$size"

    utils_log DEBUG "Copied: ${src_file} -> ${dest_file}"
    return 0
}

pbak_dump() {
    local sd_override=""
    local ssd_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sd)  sd_override="$2"; shift 2 ;;
            --ssd) ssd_override="$2"; shift 2 ;;
            -h|--help) _dump_usage; return 0 ;;
            *) ui_error "Unknown flag: $1"; _dump_usage; return 1 ;;
        esac
    done

    config_require
    utils_check_deps

    ui_header "Photo Dump: SD -> SSD"

    # Offer to rebuild hash DB if empty but SSD has files
    local db
    db="$(hash_db_file)"
    if [[ ! -s "$db" ]]; then
        local check_root=""
        if [[ -n "$ssd_override" ]]; then
            check_root=$(utils_resolve_override "$ssd_override" "full_dump")
        elif [[ -n "${PBAK_SSD_ROOT:-}" ]]; then
            check_root="$PBAK_SSD_ROOT"
        fi
        if [[ -n "$check_root" && -d "$check_root" ]]; then
            local existing
            existing=$(find "$check_root" -type f 2>/dev/null | head -1)
            if [[ -n "$existing" ]]; then
                ui_warn "Hash database is empty but SSD has existing files."
                if ui_confirm "  Rebuild hash database from SSD first?"; then
                    hash_rebuild "$check_root"
                    echo
                fi
            fi
        fi
    fi

    # Resolve source and target paths
    local sd_dcim ssd_dump_root
    sd_dcim=$(dump_select_sd "$sd_override")
    ssd_dump_root=$(dump_select_ssd "$ssd_override")

    if [[ ! -d "$sd_dcim" ]]; then
        ui_error "Source directory not found at ${sd_dcim}"
        exit 1
    fi

    utils_ensure_dir "$ssd_dump_root"
    utils_path_is_writable "$ssd_dump_root" || exit 1

    echo
    ui_info "Source: ${sd_dcim}"
    ui_info "Target: ${ssd_dump_root}"

    if utils_is_dry_run; then
        ui_warn "[DRY RUN] No files will be copied."
    fi

    echo
    ui_info "Scanning files..."

    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'" RETURN

    dump_scan_files "$sd_dcim" \
        "${PBAK_DUMP_EXTENSIONS_INCLUDE:-}" \
        "${PBAK_DUMP_EXTENSIONS_EXCLUDE:-}" > "$tmpfile"

    local total
    total=$(wc -l < "$tmpfile" | tr -d ' ')

    if [[ $total -eq 0 ]]; then
        ui_info "No matching files found on SD card."
        return 0
    fi

    # Get source file sizes in bulk (reused for total, DB matching, and space check)
    local src_info
    src_info=$(mktemp)
    tr '\n' '\0' < "$tmpfile" | utils_bulk_stat > "$src_info"

    local total_bytes
    total_bytes=$(awk -F '\t' '{ s += $1 } END { print s+0 }' "$src_info")

    ui_info "Found ${UI_BOLD}${total}${UI_RESET} files ($(utils_human_size "$total_bytes"))"

    local avail_kb
    avail_kb=$(utils_path_available_kb "$ssd_dump_root")
    local avail_bytes=$((avail_kb * 1024))
    if [[ $total_bytes -gt $avail_bytes ]]; then
        ui_warn "Files require $(utils_human_size "$total_bytes") but target has $(utils_human_size "$avail_bytes") free."
        if ! ui_confirm "  Continue anyway?"; then
            rm -f "$src_info"
            return 1
        fi
    fi

    echo

    # Match source files against hash DB by filename + size to skip re-hashing
    local hash_cache
    hash_cache=$(mktemp)
    local files_to_hash
    files_to_hash=$(mktemp)
    local db
    db="$(hash_db_file)"

    if [[ -s "$db" ]]; then
        ui_info "Checking hash database for known files..."

        # Build DB lookup: filename\tsize\thash
        local db_lookup
        db_lookup=$(mktemp)
        awk -F '\t' '{
            n = split($3, a, "/")
            printf "%s\t%s\t%s\n", a[n], $5, $1
        }' "$db" > "$db_lookup"

        # Join: source files matched by name+size get pre-filled hash,
        # unmatched files go to files_to_hash for actual hashing
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
        # No DB — all files need hashing
        awk -F '\t' '{ print substr($0, index($0, "\t") + 1) }' "$src_info" > "$files_to_hash"
    fi
    rm -f "$src_info"

    # Only hash files not already known
    local to_hash
    to_hash=$(wc -l < "$files_to_hash" 2>/dev/null | tr -d ' ')
    # Files matched by name+size in the DB are already tracked — their
    # hashes exist in the DB so dump_process_file would just grep and skip.
    # Only process the truly new files (files_to_hash).
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
        ui_success "All files already known — no hashing needed."
        rm -f "$files_to_hash" "$hash_cache"
        echo
        ui_header "Summary"
        ui_success "Copied:  0 files"
        ui_dim "  Skipped: ${pre_skipped} (already backed up)"
        echo
        ui_info "Hash DB: $(hash_count) total files tracked"
        # Skip to mirror sync / eject (no early return)
        _dump_post "$ssd_dump_root" "$sd_dcim" 0 0
        return 0
    fi

    # Build SSD file index for detecting duplicates not in hash DB
    local ssd_index
    ssd_index=$(mktemp)
    ui_spinner_start "Indexing SSD files..."
    find "$ssd_dump_root" -type f -print0 2>/dev/null | \
        utils_bulk_stat | \
        awk -F '\t' '{
            n = split($2, a, "/")
            printf "%s\t%s\t%s\n", a[n], $1, $2
        }' | sort > "$ssd_index" || true
    ui_spinner_stop
    echo

    local copied=0 skipped=0 errors=0
    local count=0
    local copied_bytes=0

    while IFS= read -r filepath; do
        count=$((count + 1))
        ui_progress "$count" "$to_hash" "$(basename "$filepath")"

        local status=0
        dump_process_file "$filepath" "$ssd_dump_root" "$hash_cache" "$ssd_index" || status=$?

        case $status in
            0) copied=$((copied + 1))
               copied_bytes=$((copied_bytes + $(utils_file_size "$filepath")))
               # Copy sidecars alongside the primary file
               local date_path_sc dest_dir_sc
               date_path_sc=$(dump_extract_date "$filepath")
               dest_dir_sc="${ssd_dump_root}/${date_path_sc}"
               while IFS= read -r sidecar; do
                   utils_process_sidecar "$sidecar" "$dest_dir_sc" 0
                   utils_log DEBUG "Sidecar copied: ${sidecar}"
               done < <(utils_find_sidecars "$filepath")
               ;;
            1) skipped=$((skipped + 1)) ;;
            *) errors=$((errors + 1)) ;;
        esac
    done < "$files_to_hash"
    rm -f "$files_to_hash"
    skipped=$((skipped + pre_skipped))

    ui_progress_done
    echo

    ui_header "Summary"
    ui_success "Copied:  ${copied} files ($(utils_human_size "$copied_bytes"))"
    if [[ $skipped -gt 0 ]]; then
        ui_dim "  Skipped: ${skipped} (already backed up)"
    fi
    if [[ $errors -gt 0 ]]; then
        ui_error "Errors:  ${errors}"
    fi
    echo
    rm -f "$hash_cache" "$ssd_index"
    ui_info "Hash DB: $(hash_count) total files tracked"

    _dump_post "$ssd_dump_root" "$sd_dcim" "$copied" "$errors"
}

_dump_post() {
    local ssd_dump_root="$1"
    local sd_dcim="$2"
    local copied="$3"
    local errors="$4"

    if [[ -n "${PBAK_MIRROR_ROOT:-}" ]]; then
        if [[ -d "$PBAK_MIRROR_ROOT" ]]; then
            echo
            ui_info "Mirror '${PBAK_MIRROR_ROOT}' detected — syncing..."
            pbak_sync --from "$ssd_dump_root" --to "$PBAK_MIRROR_ROOT"
        else
            echo
            ui_dim "Mirror '${PBAK_MIRROR_ROOT}' not accessible — skipping sync."
        fi
    fi

    # Offer to eject SD card after successful dump (only for mounted volumes)
    if [[ $errors -eq 0 && $copied -gt 0 ]]; then
        local _vol_prefix
        _vol_prefix=$(_utils_volume_prefix)
        if [[ "$sd_dcim" == "${_vol_prefix}"/* ]]; then
            local sd_label="${sd_dcim#${_vol_prefix}/}"
            sd_label="${sd_label%%/*}"
            echo
            if ui_confirm "  Eject SD card '${sd_label}'?"; then
                if utils_eject "$sd_dcim"; then
                    ui_success "SD card '${sd_label}' ejected."
                else
                    ui_warn "Could not eject '${sd_label}'. It may be in use."
                fi
            fi
        fi
    fi
}

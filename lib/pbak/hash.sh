#!/bin/bash
# DB format: tab-separated, one line per file
# <sha256>\t<source_path>\t<dest_path>\t<timestamp>\t<file_size_bytes>\t<uploaded_ts>
# Column 6 (uploaded_ts) is empty for files not yet uploaded to Immich.

HASH_WORKERS=$(_utils_cpu_count)

hash_db_file() {
    local f="$(config_dir)/hashes.db"
    [[ -f "$f" ]] || touch "$f"
    echo "$f"
}

# Convert openssl dgst output "SHA256(filepath)= hash" to shasum format "hash  filepath"
_hash_openssl_to_shasum() {
    awk '{
        start = index($0, "(") + 1
        end = index($0, ")= ")
        print substr($0, end + 3) "  " substr($0, start, end - start)
    }'
}

hash_compute() {
    local filepath="$1"
    openssl dgst -sha256 "$filepath" 2>/dev/null | awk -F '= ' '{print $NF}'
}

hash_compute_batch() {
    local file_list="$1"
    local output="$2"
    local count
    count=$(wc -l < "$file_list" | tr -d ' ')
    local batch=$(( count / (HASH_WORKERS * 4) ))
    [[ $batch -lt 10 ]] && batch=10
    tr '\n' '\0' < "$file_list" \
        | xargs -0 -n "$batch" -P "$HASH_WORKERS" openssl dgst -sha256 2>/dev/null \
        | _hash_openssl_to_shasum > "$output" || true
}

hash_exists() {
    local hash="$1"
    local db
    db="$(hash_db_file)"
    # Tab after hash prevents prefix matches
    grep -qF "${hash}	" "$db" 2>/dev/null
}

hash_lookup_precomputed() {
    local filepath="$1"
    local cache="$2"
    grep -F "$filepath" "$cache" 2>/dev/null | head -1 | cut -d ' ' -f 1
}

hash_add() {
    local hash="$1"
    local src_path="$2"
    local dest_path="$3"
    local size="$4"
    local ts
    ts="$(utils_timestamp)"
    printf '%s\t%s\t%s\t%s\t%s\t\n' "$hash" "$src_path" "$dest_path" "$ts" "$size" >> "$(hash_db_file)"
}

hash_get_dest() {
    local hash="$1"
    local db
    db="$(hash_db_file)"
    grep -F "${hash}	" "$db" 2>/dev/null | head -1 | cut -f 3
}

hash_count() {
    local db
    db="$(hash_db_file)"
    local count
    count=$(wc -l < "$db" 2>/dev/null)
    # macOS wc adds leading spaces
    echo "${count// /}"
}

hash_db_size() {
    utils_file_size "$(hash_db_file)"
}

hash_dest_exists() {
    local dest_path="$1"
    local db
    db="$(hash_db_file)"
    grep -qF "	${dest_path}	" "$db" 2>/dev/null
}

hash_resolve_collision() {
    local dest_dir="$1"
    local basename="$2"
    local ext="$3"

    local candidate="${dest_dir}/${basename}${ext}"

    if ! hash_dest_exists "$candidate" && [[ ! -f "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi

    local counter=2
    while true; do
        candidate="${dest_dir}/${basename}_${counter}${ext}"
        if ! hash_dest_exists "$candidate" && [[ ! -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
        ((counter++))
        if [[ $counter -gt 9999 ]]; then
            ui_error "Too many filename collisions for ${basename}${ext}"
            return 1
        fi
    done
}

hash_rebuild() {
    local ssd_root="$1"
    local include_exts="${2:-${PBAK_DUMP_EXTENSIONS_INCLUDE:-}}"
    local db
    db="$(hash_db_file)"

    ui_header "Rebuilding hash database"
    ui_info "Scanning: ${ssd_root}"
    if [[ -n "$include_exts" ]]; then
        ui_dim "  Extensions: ${include_exts}"
    fi

    # Build find with extension filter
    local find_args=("$ssd_root" "-type" "f")
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

    local file_list
    file_list=$(mktemp)
    find "${find_args[@]}" 2>/dev/null > "$file_list"
    local total
    total=$(wc -l < "$file_list" | tr -d ' ')

    if [[ $total -eq 0 ]]; then
        rm -f "$file_list"
        ui_warn "No files found in ${ssd_root}"
        return 0
    fi

    ui_info "Found ${total} files to hash (${HASH_WORKERS} workers)"

    if utils_is_dry_run; then
        ui_warn "[DRY RUN] Would rebuild hash database from ${total} files."
        if [[ "${VERBOSE:-0}" -eq 1 ]]; then
            while IFS= read -r f; do
                ui_info "[dry-run] Would hash: ${f}"
            done < "$file_list"
        fi
        rm -f "$file_list"
        return 0
    fi

    # Preserve upload status from existing DB before overwriting
    local old_uploaded
    old_uploaded=$(mktemp)
    if [[ -s "$db" ]]; then
        cp "$db" "${db}.bak"
        ui_dim "  Existing DB backed up to ${db}.bak"
        awk -F '\t' '$6 != "" && $6 != "0" { print $1 "\t" $6 }' "$db" > "$old_uploaded"
    fi

    # Hash all files in parallel batches with progress
    local hash_output
    hash_output=$(mktemp)
    local batch=$(( total / (HASH_WORKERS * 4) ))
    [[ $batch -lt 10 ]] && batch=10
    tr '\n' '\0' < "$file_list" \
        | xargs -0 -n "$batch" -P "$HASH_WORKERS" openssl dgst -sha256 2>/dev/null \
        | awk -v total="$total" -v verbose="${VERBOSE:-0}" '
            {
                # Parse openssl output: SHA256(filepath)= hash
                start = index($0, "(") + 1
                end = index($0, ")= ")
                hash = substr($0, end + 3)
                fp = substr($0, start, end - start)

                count++
                if (verbose)
                    printf "\r\033[K  [%d/%d] %s\n", count, total, fp > "/dev/stderr"
                else if (count == 1 || count % 100 == 0 || count == total)
                    printf "\r  [%d/%d] Hashing files...", count, total > "/dev/stderr"

                # Output in shasum format for downstream compatibility
                print hash "  " fp
            }
            END { printf "\r\033[K" > "/dev/stderr" }
        ' > "$hash_output" || true

    local hashed
    hashed=$(wc -l < "$hash_output" | tr -d ' ')
    ui_success "Hashed ${hashed} / ${total} files"

    if [[ $hashed -eq 0 ]]; then
        rm -f "$file_list" "$hash_output" "$old_uploaded"
        ui_error "No files were hashed successfully. Database unchanged."
        return 1
    fi

    # Abort if too many files failed to hash (>50% loss)
    if [[ $hashed -lt $((total / 2)) ]]; then
        rm -f "$file_list" "$hash_output" "$old_uploaded"
        ui_error "Only ${hashed}/${total} files hashed — too many failures. Database unchanged."
        ui_dim "  Old database preserved. Check disk and retry."
        return 1
    fi

    # Collect file sizes in bulk
    utils_log DEBUG "Collecting file sizes..."
    local size_map
    size_map=$(mktemp)
    tr '\n' '\0' < "$file_list" | utils_bulk_stat > "$size_map" || true

    # Build new DB in temp file: join hashes with sizes
    local ts
    ts=$(utils_timestamp)
    local tmp_db
    tmp_db=$(mktemp)

    awk -v ts="$ts" '
        NR == FNR {
            tab = index($0, "\t")
            if (tab > 0)
                sizes[substr($0, tab + 1)] = substr($0, 1, tab - 1)
            next
        }
        {
            hash = substr($0, 1, 64)
            fp = substr($0, 67)
            sz = (fp in sizes) ? sizes[fp] : 0
            printf "%s\t%s\t%s\t%s\t%s\t\n", hash, "(rebuilt)", fp, ts, sz
        }
    ' "$size_map" "$hash_output" > "$tmp_db"

    # Validate the new DB has content
    local new_count
    new_count=$(wc -l < "$tmp_db" | tr -d ' ')
    if [[ $new_count -eq 0 ]]; then
        rm -f "$file_list" "$hash_output" "$size_map" "$tmp_db" "$old_uploaded"
        ui_error "Built database is empty. Database unchanged."
        return 1
    fi

    # Restore upload status from old DB
    if [[ -s "$old_uploaded" ]]; then
        awk -F '\t' -v OFS='\t' '
            NR == FNR { uploaded[$1] = $2; next }
            { if ($1 in uploaded) $6 = uploaded[$1]; print }
        ' "$old_uploaded" "$tmp_db" > "${tmp_db}.joined"
        mv "${tmp_db}.joined" "$tmp_db"
        local restored
        restored=$(awk -F '\t' '$6 != "" && $6 != "0" { c++ } END { print c+0 }' "$tmp_db")
        if [[ $restored -gt 0 ]]; then
            ui_dim "  Restored upload status for ${restored} files"
        fi
    fi
    rm -f "$old_uploaded"

    # Atomically replace the database only after successful rebuild
    mv "$tmp_db" "$db"

    rm -f "$file_list" "$hash_output" "$size_map"
    ui_success "Hash database rebuilt: ${new_count} files indexed."
    if [[ $hashed -lt $total ]]; then
        ui_warn "  ${hashed}/${total} files hashed ($(( total - hashed )) failed)"
    fi

    # Check upload status against Immich (if configured)
    if [[ -n "${PBAK_IMMICH_SERVER:-}" && -n "${PBAK_IMMICH_API_KEY:-}" ]] && \
       command -v python3 &>/dev/null; then
        ui_info "Verifying upload status against Immich..."
        PBAK_IMMICH_SERVER="${PBAK_IMMICH_SERVER}" \
        PBAK_IMMICH_API_KEY="${PBAK_IMMICH_API_KEY}" \
        PBAK_VERBOSE="${VERBOSE:-0}" \
            python3 "${PBAK_LIB}/immich.py" mark-uploaded "$db" || \
            ui_warn "Immich verification failed (non-fatal)"
    else
        ui_dim "  Immich not configured — skipping upload status verification."
        ui_dim "  Run 'pbak setup' to configure, then 'pbak rehash' again."
    fi
}

# --- Verify (bit rot detection) ---

_verify_usage() {
    cat <<EOF
${UI_BOLD}pbak verify${UI_RESET} — Check SSD file integrity against hash database

Re-hashes files on the SSD and compares to stored SHA-256 hashes.
Reports any files that have changed (possible bit rot or corruption).

${UI_BOLD}Flags:${UI_RESET}
  --ssd <path>    Override SSD root (path or volume name)
  -h, --help      Show this help

${UI_BOLD}Global flags also apply:${UI_RESET}  --verbose
EOF
}

pbak_verify() {
    local ssd_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssd) ssd_override="$2"; shift 2 ;;
            -h|--help) _verify_usage; return 0 ;;
            *) ui_error "Unknown flag: $1"; _verify_usage; return 1 ;;
        esac
    done

    config_require

    local db
    db="$(hash_db_file)"
    if [[ ! -s "$db" ]]; then
        ui_error "Hash database is empty. Run 'pbak rehash' first."
        return 1
    fi

    ui_header "Verify: SSD File Integrity"

    # Resolve SSD root (reuse upload helper if available, else inline)
    local ssd_root=""
    if [[ -n "$ssd_override" ]]; then
        ssd_root=$(utils_resolve_override "$ssd_override")
    elif [[ -n "${PBAK_SSD_ROOT:-}" ]]; then
        ssd_root="$PBAK_SSD_ROOT"
    else
        ui_error "No SSD configured. Use --ssd <path> or run 'pbak setup'."
        return 1
    fi
    utils_require_path "$ssd_root" "SSD dump directory" || return 1

    # Extract file paths from DB that live under ssd_root
    local file_list
    file_list=$(mktemp)
    awk -F '\t' -v prefix="$ssd_root/" '
        substr($3, 1, length(prefix)) == prefix { print $3 }
    ' "$db" > "$file_list"

    local total
    total=$(wc -l < "$file_list" | tr -d ' ')

    if [[ $total -eq 0 ]]; then
        rm -f "$file_list"
        ui_warn "No tracked files found under ${ssd_root}"
        return 0
    fi

    ui_info "Checking ${total} files (${HASH_WORKERS} workers)..."

    # Hash all tracked files in parallel
    local hash_output
    hash_output=$(mktemp)
    hash_compute_batch "$file_list" "$hash_output"

    # Build lookup: filepath → computed hash
    local computed_map
    computed_map=$(mktemp)
    awk '{ print substr($0, 67) "\t" substr($0, 1, 64) }' "$hash_output" > "$computed_map"

    # Compare against DB
    local corrupt=0 missing=0 verified=0
    local result_file
    result_file=$(mktemp)

    awk -F '\t' -v prefix="$ssd_root/" '
        NR == FNR { computed[$1] = $2; next }
        substr($3, 1, length(prefix)) == prefix {
            fp = $3
            expected = $1
            if (!(fp in computed)) {
                print "MISSING\t" fp
            } else if (computed[fp] != expected) {
                print "CORRUPT\t" fp "\t" expected "\t" computed[fp]
            } else {
                print "OK\t" fp
            }
        }
    ' "$computed_map" "$db" > "$result_file"

    corrupt=$(grep -c "^CORRUPT	" "$result_file" 2>/dev/null || echo 0)
    missing=$(grep -c "^MISSING	" "$result_file" 2>/dev/null || echo 0)
    verified=$(grep -c "^OK	" "$result_file" 2>/dev/null || echo 0)

    echo

    # Report problems
    if [[ $corrupt -gt 0 ]]; then
        ui_error "CORRUPTED FILES (hash mismatch):"
        grep "^CORRUPT	" "$result_file" | while IFS=$'\t' read -r _ fp expected got; do
            ui_error "  ${fp}"
            ui_dim "    expected: ${expected}"
            ui_dim "    actual:   ${got}"
        done
        echo
    fi

    if [[ $missing -gt 0 ]]; then
        ui_warn "MISSING FILES (in DB but not on disk):"
        grep "^MISSING	" "$result_file" | while IFS=$'\t' read -r _ fp; do
            ui_warn "  ${fp}"
        done
        echo
    fi

    # Summary
    ui_header "Summary"
    ui_success "Verified: ${verified} files OK"
    if [[ $corrupt -gt 0 ]]; then
        ui_error "Corrupted: ${corrupt} files"
    fi
    if [[ $missing -gt 0 ]]; then
        ui_warn "Missing: ${missing} files"
    fi
    if [[ $corrupt -eq 0 && $missing -eq 0 ]]; then
        ui_success "All files intact."
    fi

    rm -f "$file_list" "$hash_output" "$computed_map" "$result_file"

    [[ $corrupt -eq 0 ]]
}

# --- Changed file detection (size-based, fast) ---

# Quick scan for files whose size on disk differs from the hash DB.
# Re-hashes changed files and clears their upload timestamp so they
# get picked up by the next upload.  Runs in ~1-2s for typical DBs.
hash_detect_changed() {
    local ssd_root="$1"
    local db
    db="$(hash_db_file)"
    [[ -s "$db" ]] || return 0

    # 1. Bulk-stat every file under ssd_root → size<TAB>path
    local disk_sizes
    disk_sizes=$(mktemp)
    find "$ssd_root" -type f -not -name "._*" -print0 2>/dev/null \
        | utils_bulk_stat > "$disk_sizes" 2>/dev/null || true

    # 2. awk: compare DB size (col 5) with disk size for uploaded files
    local changed_paths
    changed_paths=$(mktemp)
    awk -F '\t' '
        NR == FNR { disk[$2] = $1; next }
        $6 != "" && $6 != "0" && $3 in disk && disk[$3] != $5 {
            print $3
        }
    ' "$disk_sizes" "$db" > "$changed_paths"

    local n_changed
    n_changed=$(wc -l < "$changed_paths" | tr -d ' ')

    if [[ $n_changed -eq 0 ]]; then
        rm -f "$disk_sizes" "$changed_paths"
        return 0
    fi

    ui_info "Detected ${n_changed} changed file(s) on disk — re-hashing..."

    # 3. Re-hash only the changed files
    local new_hashes
    new_hashes=$(mktemp)
    hash_compute_batch "$changed_paths" "$new_hashes"

    # 4. Update DB: new hash, new size, clear upload timestamp
    local tmp
    tmp=$(mktemp)
    awk -F '\t' -v OFS='\t' '
        FILENAME == ARGV[1] { disk[$2] = $1; next }
        FILENAME == ARGV[2] { newhash[substr($0, 67)] = substr($0, 1, 64); next }
        {
            if ($3 in newhash) {
                $1 = newhash[$3]
                $5 = disk[$3]
                $6 = ""
            }
            print
        }
    ' "$disk_sizes" "$new_hashes" "$db" > "$tmp"
    mv "$tmp" "$db"

    # Report
    while IFS= read -r f; do
        local rel="${f#${ssd_root}/}"
        ui_dim "  Changed: ${rel}"
    done < "$changed_paths"
    ui_success "Queued ${n_changed} file(s) for re-upload"

    rm -f "$disk_sizes" "$changed_paths" "$new_hashes"
}

# --- Upload status tracking (column 6) ---

# Mark all file hashes in a folder as uploaded
hash_mark_uploaded() {
    local folder="$1"
    local ssd_root="${2:-}"
    local db
    db="$(hash_db_file)"
    local ts
    ts="$(utils_timestamp)"
    local tmp
    tmp=$(mktemp)

    if [[ -n "$ssd_root" && "$folder" == "$ssd_root" ]]; then
        # Root: only direct files (no subdirectory after prefix)
        awk -F '\t' -v OFS='\t' -v prefix="$folder/" -v ts="$ts" '{
            if (substr($3, 1, length(prefix)) == prefix) {
                rest = substr($3, length(prefix) + 1)
                if (index(rest, "/") == 0) $6 = ts
            }
            print
        }' "$db" > "$tmp"
    else
        awk -F '\t' -v OFS='\t' -v prefix="$folder/" -v ts="$ts" '{
            if (substr($3, 1, length(prefix)) == prefix) $6 = ts
            print
        }' "$db" > "$tmp"
    fi

    mv "$tmp" "$db"
}

# Count files in a folder NOT yet marked as uploaded (column 6 empty).
# Only counts direct children (not subdirectories).
hash_folder_new_count() {
    local folder="$1"
    local db
    db="$(hash_db_file)"

    awk -F '\t' -v prefix="$folder/" '
        substr($3, 1, length(prefix)) == prefix && ($6 == "" || $6 == "0") {
            rest = substr($3, length(prefix) + 1)
            if (index(rest, "/") == 0) count++
        }
        END { print count+0 }
    ' "$db"
}

# Total number of unique hashes marked as uploaded
hash_total_uploaded() {
    local db
    db="$(hash_db_file)"
    awk -F '\t' '$6 != "" && $6 != "0" { c++ } END { print c+0 }' "$db"
}

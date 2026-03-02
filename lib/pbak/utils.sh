#!/bin/bash

# ── Platform detection ────────────────────────────────────────────────
PBAK_OS="$(uname -s)"

# CPU count for parallel hashing
_utils_cpu_count() {
    case "$PBAK_OS" in
        Darwin) sysctl -n hw.ncpu 2>/dev/null || echo 4 ;;
        *)      nproc 2>/dev/null || echo 4 ;;
    esac
}

# Portable stat wrappers
utils_file_size() {
    case "$PBAK_OS" in
        Darwin) stat -f '%z' "$1" 2>/dev/null || echo 0 ;;
        *)      stat -c '%s' "$1" 2>/dev/null || echo 0 ;;
    esac
}

# Portable bulk stat: outputs "size\tpath" lines for a null-delimited file list on stdin
utils_bulk_stat() {
    case "$PBAK_OS" in
        Darwin) xargs -0 stat -f $'%z\t%N' 2>/dev/null ;;
        *)      xargs -0 stat -c $'%s\t%n' 2>/dev/null ;;
    esac
}

# Portable fallback date from filesystem (for dump_extract_date)
utils_fs_date() {
    case "$PBAK_OS" in
        Darwin) stat -f '%Sm' -t '%Y/%m/%d' "$1" 2>/dev/null ;;
        *)      date -r "$1" '+%Y/%m/%d' 2>/dev/null ;;
    esac
}

# Portable SD/volume eject
utils_eject() {
    local path="$1"
    case "$PBAK_OS" in
        Darwin)
            local volume="${path#/Volumes/}"
            volume="${volume%%/*}"
            diskutil eject "/Volumes/${volume}" 2>/dev/null
            ;;
        *)
            umount "$path" 2>/dev/null || udisksctl unmount -b "$path" 2>/dev/null
            ;;
    esac
}

# List mounted external volumes/media
utils_list_volumes() {
    case "$PBAK_OS" in
        Darwin)
            local vol
            for vol in /Volumes/*/; do
                vol="${vol%/}"
                local name="${vol##*/}"
                [[ "$name" == "Macintosh HD" ]] && continue
                [[ "$name" == "Macintosh HD - Data" ]] && continue
                echo "$name"
            done
            ;;
        *)
            # Linux: check /media/$USER and /mnt for mounted devices
            local dir
            for dir in /media/"${USER}"/*/ /mnt/*/; do
                [[ -d "$dir" ]] || continue
                dir="${dir%/}"
                echo "${dir##*/}"
            done
            ;;
    esac
}

# Resolve volume name → mount path (platform-aware)
_utils_volume_prefix() {
    case "$PBAK_OS" in
        Darwin) echo "/Volumes" ;;
        *)
            # Prefer /media/$USER if it exists, else /mnt
            if [[ -d "/media/${USER}" ]]; then
                echo "/media/${USER}"
            else
                echo "/mnt"
            fi
            ;;
    esac
}

# ── Logging ───────────────────────────────────────────────────────────

utils_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    case "$level" in
        DEBUG) [[ "${VERBOSE:-0}" -eq 1 ]] && printf '%s [DEBUG] %s\n' "$ts" "$msg" >&2 ;;
        INFO)  printf '%s [INFO]  %s\n' "$ts" "$msg" >&2 ;;
        WARN)  printf '%s [WARN]  %s\n' "$ts" "$msg" >&2 ;;
        ERROR) printf '%s [ERROR] %s\n' "$ts" "$msg" >&2 ;;
    esac
}

# ── Dependency checking ───────────────────────────────────────────────

utils_check_deps() {
    local missing=0

    # "command:package_hint" — empty hint means system tool, skip install offer
    local deps=(
        "immich-go:immich-go"
        "exiftool:exiftool"
        "openssl:"
    )

    for entry in "${deps[@]}"; do
        local cmd="${entry%%:*}"
        local pkg="${entry#*:}"

        if ! command -v "$cmd" &>/dev/null; then
            if [[ -n "$pkg" ]]; then
                ui_warn "'${cmd}' is not installed."
                if command -v brew &>/dev/null && ui_confirm "  Install '${cmd}' via Homebrew?"; then
                    ui_info "Running: brew install ${pkg}"
                    if brew install "$pkg"; then
                        if command -v "$cmd" &>/dev/null; then
                            ui_success "'${cmd}' installed successfully."
                        else
                            ui_error "'${cmd}' still not found after install."
                            ((missing++))
                        fi
                    else
                        ui_error "Failed to install '${cmd}'."
                        ((missing++))
                    fi
                else
                    ui_error "'${cmd}' is required. Install it and try again."
                    ((missing++))
                fi
            else
                ui_error "Required system tool '${cmd}' is not available."
                ((missing++))
            fi
        fi
    done

    if [[ $missing -gt 0 ]]; then
        ui_error "Cannot continue: ${missing} missing dependency(ies)."
        exit 1
    fi
}

# ── Path helpers ──────────────────────────────────────────────────────

utils_require_path() {
    local path="$1"
    local label="${2:-Path}"
    if [[ ! -d "$path" ]]; then
        ui_error "${label} not accessible: ${path}"
        return 1
    fi
}

utils_path_is_writable() {
    local path="$1"
    if [[ ! -w "$path" ]]; then
        ui_error "Not writable: ${path}"
        return 1
    fi
}

utils_path_available_kb() {
    local path="$1"
    df -k "$path" 2>/dev/null | tail -1 | awk '{print $4}'
}

# Resolve a CLI override that may be a full path or a bare volume name.
# Usage: utils_resolve_override <override> <default_subfolder>
utils_resolve_override() {
    local override="$1"
    local default_sub="${2:-}"
    if [[ "$override" == /* ]]; then
        echo "$override"
    else
        local prefix
        prefix=$(_utils_volume_prefix)
        if [[ -n "$default_sub" ]]; then
            echo "${prefix}/${override}/${default_sub}"
        else
            echo "${prefix}/${override}"
        fi
    fi
}

utils_ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            utils_log DEBUG "Would create directory: ${dir}"
        else
            mkdir -p "$dir"
        fi
    fi
}

utils_is_dry_run() {
    [[ "${DRY_RUN:-0}" -eq 1 ]]
}

utils_timestamp() {
    date '+%Y-%m-%dT%H:%M:%S'
}

# ── Sidecar detection ────────────────────────────────────────────────

PBAK_SIDECAR_EXTENSIONS=".xmp .dop .pp3"

# Find sidecar files associated with a primary file.
# Checks for <stem>.<sidecar_ext> and <filename>.<sidecar_ext>
# Outputs one sidecar path per line.
utils_find_sidecars() {
    local filepath="$1"
    local dir basename stem

    dir="$(dirname "$filepath")"
    basename="$(basename "$filepath")"
    stem="${basename%.*}"

    local ext
    for ext in $PBAK_SIDECAR_EXTENSIONS; do
        # stem.xmp (e.g. DSC00123.xmp for DSC00123.ARW)
        [[ -f "${dir}/${stem}${ext}" ]] && echo "${dir}/${stem}${ext}"
        # filename.xmp (e.g. DSC00123.ARW.xmp)
        [[ -f "${dir}/${basename}${ext}" ]] && echo "${dir}/${basename}${ext}"
    done
}

# Copy or move a sidecar from source dir to destination dir, register in hash DB.
# Usage: utils_process_sidecar <sidecar_path> <dest_dir> <move:0|1>
utils_process_sidecar() {
    local sidecar="$1"
    local dest_dir="$2"
    local do_move="${3:-0}"
    local sidecar_name dest_file

    sidecar_name="$(basename "$sidecar")"
    dest_file="${dest_dir}/${sidecar_name}"

    # Skip if already at destination
    if [[ "$sidecar" == "$dest_file" ]]; then
        # Just register if not tracked
        if ! hash_dest_exists "$dest_file"; then
            local h s
            h=$(hash_compute "$sidecar") || return
            s=$(utils_file_size "$sidecar")
            hash_add "$h" "$sidecar" "$dest_file" "$s"
        fi
        return 0
    fi

    if utils_is_dry_run; then
        utils_log DEBUG "[dry-run] Would copy sidecar: ${sidecar} -> ${dest_file}"
        return 0
    fi

    utils_ensure_dir "$dest_dir"

    if [[ "$do_move" -eq 1 ]]; then
        mv "$sidecar" "$dest_file" 2>/dev/null || return
    else
        cp -p "$sidecar" "$dest_file" 2>/dev/null || return
    fi

    local h s
    h=$(hash_compute "$dest_file") || return
    s=$(utils_file_size "$dest_file")
    hash_add "$h" "$sidecar" "$dest_file" "$s"
    utils_log DEBUG "Sidecar: ${sidecar} -> ${dest_file}"
}

utils_human_size() {
    local bytes="$1"
    if [[ $bytes -ge 1073741824 ]]; then
        printf '%d.%d GB' "$((bytes / 1073741824))" "$(( (bytes % 1073741824) * 10 / 1073741824 ))"
    elif [[ $bytes -ge 1048576 ]]; then
        printf '%d.%d MB' "$((bytes / 1048576))" "$(( (bytes % 1048576) * 10 / 1048576 ))"
    elif [[ $bytes -ge 1024 ]]; then
        printf '%d.%d KB' "$((bytes / 1024))" "$(( (bytes % 1024) * 10 / 1024 ))"
    else
        printf '%d B' "$bytes"
    fi
}

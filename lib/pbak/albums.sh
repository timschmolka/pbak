#!/bin/bash

pbak_albums() {
    # Absorb global flags that may appear after the subcommand
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  DRY_RUN=1; shift ;;
            --verbose)  VERBOSE=1; shift ;;
            --quiet|-q) QUIET=1; shift ;;
            *)          args+=("$1"); shift ;;
        esac
    done
    set -- ${args[@]+"${args[@]}"}

    case "${1:-}" in
        -h|--help)
            cat <<EOF
${UI_BOLD}pbak albums${UI_RESET} — Sync Lightroom Classic collections to Immich albums

Reads collections from the LrC catalog, matches files to Immich assets,
creates/updates albums, syncs metadata (picks/ratings), and stacks
related files (TIF/DNG/ARW).

${UI_BOLD}Flags:${UI_RESET}
  --collection <name>  Sync a single collection by name
  --no-metadata        Skip pick/rating metadata sync
  --no-stacks          Skip file stacking
  --prune              Remove assets from Immich albums not in LrC collection
  -h, --help           Show this help

${UI_BOLD}Global flags also apply:${UI_RESET}  --dry-run, --verbose, --quiet
EOF
            return 0 ;;
    esac

    if ! command -v python3 &>/dev/null; then
        ui_error "python3 is required for 'pbak albums'."
        ui_info "Install via: brew install python3"
        return 1
    fi

    config_require
    if ! config_validate; then
        ui_error "Immich server details missing. Run 'pbak setup'."
        exit 1
    fi

    # Pass config + flags to Python via environment
    PBAK_DRY_RUN="${DRY_RUN}" \
    PBAK_VERBOSE="${VERBOSE}" \
    PBAK_QUIET="${QUIET}" \
    PBAK_IMMICH_SERVER="${PBAK_IMMICH_SERVER}" \
    PBAK_IMMICH_API_KEY="${PBAK_IMMICH_API_KEY}" \
    PBAK_LRC_CATALOG="${PBAK_LRC_CATALOG:-}" \
        python3 "${PBAK_LIB}/albums.py" "$@"
}

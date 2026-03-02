#compdef pbak

# Complete with mounted volumes (excluding system volumes) and arbitrary paths.
_pbak_path_or_volume() {
    local -a vols
    if [[ "$(uname -s)" == "Darwin" ]]; then
        for v in /Volumes/*/; do
            v="${v%/}"; v="${v##*/}"
            [[ "$v" == "Macintosh HD" || "$v" == "Macintosh HD - Data" ]] && continue
            vols+=("$v")
        done
    else
        for v in /media/"${USER}"/*/ /mnt/*/; do
            [[ -d "$v" ]] || continue
            v="${v%/}"; v="${v##*/}"
            vols+=("$v")
        done
    fi
    _alternative \
        "volumes:volume:compadd -a vols" \
        "files:path:_files -/"
}

_pbak_date_folders() {
    local ssd_root="${PBAK_SSD_ROOT:-}"
    [[ -z "$ssd_root" ]] && return
    [[ -d "$ssd_root" ]] || return
    local -a dates
    for d in "$ssd_root"/*/*/; do
        d="${d%/}"
        d="${d#${ssd_root}/}"
        dates+=("$d")
    done
    _describe 'date folder' dates
}

_pbak() {
    local -a commands=(
        'setup:Configure Immich server, storage paths, and extensions'
        'dump:Copy photos from SD card to SSD'
        'upload:Upload photos from SSD to Immich'
        'status:Show backup status and configuration'
        'sync:Sync primary SSD to a mirror SSD'
        'albums:Sync LrC collections to Immich albums'
        'ingest:Register untracked files or import to SSD'
        'rehash:Rebuild hash database from SSD'
        'verify:Check SSD file integrity against hash database'
        'doctor:Run health checks on your pbak setup'
    )

    local -a global_flags=(
        '--dry-run[Show what would be done without changes]'
        '--verbose[Enable verbose output]'
        '(-q --quiet)'{-q,--quiet}'[Suppress informational output]'
        '--version[Print version]'
        '(-h --help)'{-h,--help}'[Show help]'
    )

    _arguments -C \
        $global_flags \
        '1:command:->command' \
        '*::arg:->args'

    case $state in
        command)
            _describe 'command' commands
            ;;
        args)
            case ${words[1]} in
                dump)
                    _arguments \
                        '--sd[SD card source (path or volume name)]:path:_pbak_path_or_volume' \
                        '--ssd[SSD dump root (path or volume name)]:path:_pbak_path_or_volume' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                upload)
                    _arguments \
                        '--ssd[SSD dump root (path or volume name)]:path:_pbak_path_or_volume' \
                        '--date[Specific date folder]:date:_pbak_date_folders' \
                        '--all[Upload all pending folders]' \
                        '--retry-failed[Retry failed uploads]' \
                        '--force[Re-upload all (immich-go skips server-side dupes)]' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                sync)
                    _arguments \
                        '--from[Primary SSD root (path or volume name)]:path:_pbak_path_or_volume' \
                        '--to[Mirror SSD root (path or volume name)]:path:_pbak_path_or_volume' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                albums)
                    _arguments \
                        '--collection[Sync a single collection by name]:name:' \
                        '--no-metadata[Skip pick/rating metadata sync]' \
                        '--no-stacks[Skip file stacking]' \
                        '--prune[Remove assets not in LrC collection]' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                ingest)
                    _arguments \
                        '--from[Source folder to import from]:path:_files -/' \
                        '--ssd[SSD dump root (path or volume name)]:path:_pbak_path_or_volume' \
                        '--move[Move files instead of copy (import mode)]' \
                        '--no-sidecars[Skip sidecar detection]' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                rehash)
                    _arguments \
                        '--ssd[SSD dump root (path or volume name)]:path:_pbak_path_or_volume' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                verify)
                    _arguments \
                        '--ssd[SSD dump root (path or volume name)]:path:_pbak_path_or_volume' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                setup|status|doctor)
                    _arguments '(-h --help)'{-h,--help}'[Show help]'
                    ;;
            esac
            ;;
    esac
}

_pbak "$@"

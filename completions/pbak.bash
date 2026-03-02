# bash completion for pbak

_pbak_volumes() {
    local vols=()
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local v
        for v in /Volumes/*/; do
            v="${v%/}"; v="${v##*/}"
            [[ "$v" == "Macintosh HD" || "$v" == "Macintosh HD - Data" ]] && continue
            vols+=("$v")
        done
    else
        local v
        for v in /media/"${USER}"/*/ /mnt/*/; do
            [[ -d "$v" ]] || continue
            v="${v%/}"; v="${v##*/}"
            vols+=("$v")
        done
    fi
    printf '%s\n' "${vols[@]}"
}

_pbak() {
    local cur prev words cword
    _init_completion || return

    local commands="setup dump upload status sync albums ingest rehash verify doctor help"
    local global_flags="--dry-run --verbose --quiet --version --help -h"

    # Find the subcommand
    local cmd=""
    local i
    for ((i = 1; i < cword; i++)); do
        case "${words[i]}" in
            --*|-*) ;;
            *) cmd="${words[i]}"; break ;;
        esac
    done

    # No subcommand yet — complete commands and global flags
    if [[ -z "$cmd" ]]; then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=($(compgen -W "$global_flags" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        fi
        return
    fi

    # Subcommand-specific completions
    case "$cmd" in
        dump)
            case "$prev" in
                --sd|--ssd)
                    COMPREPLY=($(compgen -W "$(_pbak_volumes)" -- "$cur"))
                    _filedir -d
                    return ;;
            esac
            COMPREPLY=($(compgen -W "--sd --ssd --help -h" -- "$cur"))
            ;;
        upload)
            case "$prev" in
                --ssd)
                    COMPREPLY=($(compgen -W "$(_pbak_volumes)" -- "$cur"))
                    _filedir -d
                    return ;;
                --date)
                    # Complete date folders from SSD
                    if [[ -n "${PBAK_SSD_ROOT:-}" && -d "$PBAK_SSD_ROOT" ]]; then
                        local dates=()
                        local d
                        for d in "$PBAK_SSD_ROOT"/*/*/; do
                            d="${d%/}"; d="${d#${PBAK_SSD_ROOT}/}"
                            dates+=("$d")
                        done
                        COMPREPLY=($(compgen -W "${dates[*]}" -- "$cur"))
                    fi
                    return ;;
            esac
            COMPREPLY=($(compgen -W "--ssd --date --all --retry-failed --force --help -h" -- "$cur"))
            ;;
        sync)
            case "$prev" in
                --from|--to)
                    COMPREPLY=($(compgen -W "$(_pbak_volumes)" -- "$cur"))
                    _filedir -d
                    return ;;
            esac
            COMPREPLY=($(compgen -W "--from --to --help -h" -- "$cur"))
            ;;
        albums)
            COMPREPLY=($(compgen -W "--collection --no-metadata --no-stacks --prune --help -h" -- "$cur"))
            ;;
        ingest)
            case "$prev" in
                --from)
                    _filedir -d
                    return ;;
                --ssd)
                    COMPREPLY=($(compgen -W "$(_pbak_volumes)" -- "$cur"))
                    _filedir -d
                    return ;;
            esac
            COMPREPLY=($(compgen -W "--from --ssd --move --no-sidecars --help -h" -- "$cur"))
            ;;
        rehash)
            case "$prev" in
                --ssd)
                    COMPREPLY=($(compgen -W "$(_pbak_volumes)" -- "$cur"))
                    _filedir -d
                    return ;;
            esac
            COMPREPLY=($(compgen -W "--ssd --help -h" -- "$cur"))
            ;;
        verify)
            case "$prev" in
                --ssd)
                    COMPREPLY=($(compgen -W "$(_pbak_volumes)" -- "$cur"))
                    _filedir -d
                    return ;;
            esac
            COMPREPLY=($(compgen -W "--ssd --help -h" -- "$cur"))
            ;;
        setup|status|doctor)
            COMPREPLY=($(compgen -W "--help -h" -- "$cur"))
            ;;
    esac
}

complete -F _pbak pbak

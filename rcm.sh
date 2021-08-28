#!/bin/bash
# Convenience functions for determining how RCM-managed dotfiles should be
# symlinked

declare -r HOST="${HOST:-macbook}"
declare -r BACKUPS="${BACKUPS:-$HOME/.backups}"
declare -r LOGFILE="${RCM_LOGFILE:-$HOME/.rcm.log}"
declare -i DRY_RUN=0
mkdir -p "$BACKUPS"

_start_logentry() {
    touch "$LOGFILE" || {
        echo "Cannot write logfile '$LOGFILE'" >&2
        exit 2
    }
    printf '%s\n' "" "[`date -u`]"
    printf '%s ' "Global options:" \
        "HOST=${HOST}" \
        "BACKUPS=${BACKUPS}" \
        "LOGFILE=${LOGFILE}" \
        "DRY_RUN=${DRY_RUN}"
    echo
} >>"$LOGFILE"

_log() {
    printf '    %s' "$@"
    echo
} >>"$LOGFILE"

_safe_move() {
    local src="$(realpath "$src")" dest="$2"
    _log "'${src}' --> '${dest}'"
    if [ $DRY_RUN -eq 0 ]; then
        if [ -e "$dest" ]; then
            mv "$dest" "$BACKUPS" && {
                _log "" "Backed up '$dest'"
            } || {
                _log "" "Failed to backup '$dest'"
            }
        fi
        cp -r "$src" "$dest" && {
            _log "" "Copied '$src' to '$dest'"
        } || {
            _log "" "Failed to copy '$src' to '$dest'"
        }
    fi
    return $?
}
    

main() {
    local src=
    local dest=
    if ! command -v lsrc >/dev/null 2>&1; then
        echo "Command 'lsrc' not found!" >&2
        exit 23
    fi
    while getopts ":l:b:dh" opt; do
        case "$opt" in
            l)
                LOGFILE="$OPTARG"
                ;;
            d)
                let DRY_RUN=1
                ;;
            h)
                _rcm_usage
                exit 0
                ;;
            *)
                _rcm_usage >&2
                exit -1
                ;;
        esac
    done
    shift $(( OPTIND - 1 )) && OPTIND=1

    _start_logentry
    while read -r line; do
        src="${line#*:}"    
        dest="${line%%:*}"
        _safe_move "$src" "$dest"
    done < <(lsrc -B "${HOST}")
    exit $?
}

main "$@"

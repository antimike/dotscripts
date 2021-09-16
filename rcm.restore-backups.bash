#!/bin/bash
# Restores backups from .rcm script

declare BACKUPS="${BACKUPS:-$HOME/.backups}"
declare RCM_LOG=~/.rcm.log
declare BACKUP_LOG="${BACKUPS}/.backup.log"
if ! [ -r "$RCM_LOG" ]; then
    echo "Could not locate RCM logfile" >&2
    exit 1
fi

declare ind="    "
declare -a BACKED_UP=( $(tac "$RCM_LOG" | sed -n '1,/^\[/p' | tac |
    grep "^${ind}${ind}Backed up" | awk '{print $3;}' |
    sed -e "s/^'//" -e "s/'$//") )
declare -a COPIED=( $(tac "$RCM_LOG" | sed -n '1,/^\[/p' | tac |
    grep "^${ind}${ind}Copied" $RCM_LOG | awk -v FS="'" -v ind="$ind" '
    {print $4;}') )

_start_logentry() {
    touch "$BACKUP_LOG" || {
        echo "Cannot write logfile '$BACKUP_LOG'" >&2
        exit 2
    }
    printf '%s\n' "" "[`date -u`]"
    printf '%s ' "Global options:" \
        "BACKUPS=${BACKUPS}" \
        "RCM_LOG=${RCM_LOG}" \
        "BACKUP_LOG=${BACKUP_LOG}"
    echo
} >>"$BACKUP_LOG"

_log() {
    { printf "${ind}%s" "$@" && echo; } | tee -a "$BACKUP_LOG"
}

_fail() {
    _log "FAILED: $*"; exit -1;
}

_confirm() {
    # Make sure the user understands what's about to happen
    cat <<-MSG
		This script will remove all files copied to ~ by the last invocation of the
		script rcm.sh.  Prior to doing so, it will re-backup all files copied to
		~/.backups, overwriting any contents of ~/.backups in the process.
		
		The following ${#BACKED_UP[@]} files will be backed up: `
		printf "\n${ind}- %s" "${BACKED_UP[@]}"`
		The following ${#COPIED[@]} files will be removed: `
		printf "\n${ind}- %s" "${COPIED[@]}"`
		
		Do you wish to proceed?
		MSG
    read -r -n 1 -s
    case "$REPLY" in
        y|Y) ;;
        *) _fail "Aborting!" ;;
    esac
}

main() {
    _start_logentry
    _confirm

    for file in "${BACKED_UP[@]}"; do
        dest="${BACKUPS}/${file#$HOME}"
        mkdir -p "$(dirname "$dest")" &&
            cp "$file" "$dest" &&
            _log "" "Backed up '$file' to '$dest'" ||
            _fail "Failed to backup '$file'"
    done

    for file in "${COPIED[@]}"; do
        rm -rf "$file" &&
            _log "" "Removed '$file'" ||
            _fail "Failed to remove '$file'"
    done

    exit $?
}

main "$@"

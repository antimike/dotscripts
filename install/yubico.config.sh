#!/bin/bash
# Configure PAM modules to use YubiKey

declare -a YUBI_DEPS=( pam_yubico pam-u2f pamu2fcfg )
declare -a PAM_MODS=( sudo login )
declare -A YUBI_PAM_ARGS=(
    [chalresp_path]="/etc/yubico"
    [debug_file]="/var/log/pam_yubico.log"
    [mode]="challenge-response"
)
declare -r YUBI_SO_FILE="pam_yubico.so"
declare -r PAM_DIR="/etc/pam.d"

# Taken from `pass`
_yesno() {
    # First test to see if we're on a TTY
    [ -t 0 ] || return 0
    local response
    read -r -p "$1 [y/N] " response && echo
    [ "${response^^}" == Y ] && return 0 || return 1
}

_warning() {
    # Remind user to open up a root shell
    cat <<-WARNING >&2

		** IMPORTANT **
		You should open a terminal window with a root shell and keep it open while this
		script is running (i.e., \`sudo -s\`).  This is to allow you to revert any
		changes should anything unexpected happen.

		WARNING
    _yesno "Continue?" || exit 23
}

_die() {
    local -i status=$1 && shift || local -i status=-1
    echo "$*"
    exit $status
} >&2

_require_command() {
    local -a notfound=( )
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 ||
            notfound+=( "$cmd" )
    done
    if [ ${#notfound[@]} -eq 0 ]; then
        return 0
    else
        local msg="The following ${#notfound[@]} commands were not found:"
        msg+="$(printf " '%s'" "${notfound[@]}")"
        _die 1 "$msg"
    fi
}

_generate_user_response() {
    ykamcfg -2 | cut -d "'" -f2
}

_install_deps() {
    local -a failed=( )
    for dep in "${YUBI_DEPS[@]}"; do
        dnf list --installed | grep "$dep" >/dev/null 2>&1 ||
            sudo dnf install "$dep" ||
            failed+=( "$dep" )
    done
    if [ ${#failed[@]} -eq 0 ]; then
        return 0
    else
        local msg="Failed to install dependencies:"
        msg+="$(printf " '%s'" "${failed[@]}")"
        _die 2 "$msg"
    fi
}

_get_kv_pairs() {
    local -n ref="$1"
    for key in "${!ref[@]}"; do
        printf '%s=%s ' "$key" "${ref[$key]}"
    done | sed 's/[[:space:]]*$//'
}

_backup() {
    local -a failed=( )
    echo "Backing up files to ${BACKUP_DIR}:"
    for arg in "$@"; do
        cp -r "$arg" "$BACKUP_DIR" && echo "$arg" ||
            failed+=( "$arg" )
    done
    if [ ${#failed[@]} -gt 0 ]; then
        echo "Failed to backup:"
        printf ' "%s"' "${failed[@]}"
    fi >&2
    return ${#failed[@]}
}

_choose() {
    local -n ref="$1" && shift || return -1
    while :; do
        echo "$*" >&2
        select opt in "${!ref[@]}"; do
            [ -n "${ref[$opt]+x}" ] && echo "$opt" && return 0 ||
                echo "Invalid choice." >&2
            break
        done
    done
}

main() {
    _install_deps
    _require_command ykpamcfg
    _warning

    # Backup current PAM modules in case anything goes south
    _backup "${PAM_DIR}/sudo" "${PAM_DIR}/login" || exit $?
    _backup \
        "${PAM_DIR}/{$(awk -v OFS=',' '{$1=$1; print;}' <<<"${PAM_MODS[@]}")}"

    # Keys --> auth options
    # Vals --> sed addresses and command prefixes
    local -A opts=( 
        [sufficient]='/^[^#]/i\'
        [required]='$a\'
    )

    # Add PAM modules which can be included in others
    for opt in "${!opts[@]}"; do
        local fname="${PAM_DIR}/yubico_${opt}"
        ! [ -e "$fname" ] || 
            _yesno "'$fname' already exists.  Overwrite it?" >&2 &&
            sudo tee "${fname}" <<-PAM >/dev/null
				auth ${opt} ${so_file} debug `_get_kv_pairs YUBI_PAM_ARGS`
				PAM
    done

    local opt=
    for mod in "${PAM_MODS[@]}"; do
        opt="$(_choose opts "Choose auth option for PAM module ${mod}:")"
        sudo sed -i "${opts[$opt]}auth include yubico_${opt}" \
            "${PAM_DIR}/${mod}"
    done
    exit 0
}

main "$@"

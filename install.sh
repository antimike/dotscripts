#!/bin/bash

# TODO: Implement query history / results caching

# Useful for usage (helptext) and debugging
__FILE__="$(readlink -m "${BASH_SOURCE[0]}")"
__DIR__="$(dirname "${__FILE__}")"
__NAME__="$(basename "${__FILE__}")"

# Some basic IO
error() {
	printf '%s\n' "$@" >&2 && return 1 || return -1
}

die() {
    error "$@" && exit $?
}

debug() {
	if [ -n "${DEBUG+x}" ]; then
		local -i offset=0		# Useful with other debug fns to correct stack
								# trace
		if [[ "$1" = --offset* ]]; then
			let offset+="${1#--offset=}" && shift || return -1
		fi
		case "$1" in
			--offset=*)
				let offset+="${1#--offset=}" && shift || return -1
				;;
			*) ;;
		esac
		local source="${BASH_SOURCE[$(( 0 + offset ))]}"
		local func="${FUNCNAME[$(( 1 + offset ))]}"
		local lineno="${BASH_LINENO[$(( 0 + offset ))]}"
		echo "DEBUG: ${source} --> ${func} @${lineno}:"
		printf '    %s\n' "$@"
	fi
	return 0
} >&2

debug_vars() {
	if [ -n "${DEBUG+x}" ]; then
		local -a lines=( )
		for var in "$@"; do
			lines+=( "$var = ${!var}" )
		done
		debug --offset=1 "${lines[@]}"
	fi
	return $?
} >&2

usage() {
    :
}

# Set globals with defaults
INSTALL="${INSTALL:-${HOME}/.install}"
[ -d "${INSTALL=${HOME}/.install}" ] ||
	die "Can't find directory '${INSTALL}'"
_LOGFILE="${INSTALL}/.log"
_TAGDIR="${INSTALL}/.tags"
_UPSTREAM_DIRNAME="upstream"
_DOWNSTREAM_DIRNAME="downstream"
_ALL_TAGGED="${_TAGDIR}/*"  # List of all tagged files
							# Filename = literal '*'
_QUERY="${_TAGDIR}/.query"	# To store the results of searches

# Filesystem helper functions
get_fifo() {
	local path="$(mktemp "fifo-$$-XXXX")" &&
		rm -f "$path" &&
		mkfifo "$path" && echo "$path" ||
			die "Could not create FIFO"
	trap "rm -f '${path}'" EXIT 2>/dev/null
	return $?
}

get_path() {
	if command -v realpath; then
		echo $(realpath "$1")
	elif command -v readlink; then
		echo $(readlink -m "$1")
	else
		die "Unable to follow symlinks using either 'readlink' or 'realpath'"
	fi
	return $?
}

ensure_dir() {
    # Attempt to create directory if it doesn't exist
    # Returns successfully if dir exists or was created
    [ -d "$1" ] || mkdir -p "$1" &>/dev/null
    return $?
}

ensure_repo() {
    # Validates that the passed path is a git repo
    [ -d "$1" ] && (cd "$1" && git status) &>/dev/null
    return $?
}

# Functions for querying and queuing packages to be installed based on tags and
# directory structure
query_tags() {
	# Tag strategy: Tags are stored in two places: In individual packages'
	# ".tags" files, and in files under the root-level directory ".tags" (one
	# file per tag).  This is redundant but simplifies lookups---if one
	# discovers that the package "foo" is tagged with "bar", one can simply
	# `cat` the contents of the file ".tags/bar" to find all of foo's
	# "siblings."  On the other hand, consistency is not checked on read or
	# write operations (but an option is provided to traverse the entire "tag
	# tree" to check its consistency).
    # TODO: Implement query history (currently, previous query is discarded)
    # TODO: Add better handling of fat-finger mistakes (currently, a file is
    # `touched` for every passed tag, potentially creating unwanted "typo
    # tagfiles")
	# TODO: Add support for metatags

    local op="&"		# Default is logical "and"
    local -a query=( )
    local tagfile=		# Loop variable (used below)

    while [ $# -gt 0 ]; do
        case "$1" in
            -a|--and|\&)
                op="&"
                ;;
            -o|--or|\|)
                op="|"
                ;;
            *)
                query+=( "${op}${1}" )
                ;;
        esac
        shift
    done

    sort "${_ALL_TAGGED}" >"${_QUERY}"	# Resultset is initially maximal
    for tag in "${query[@]}"; do
		# If tagfile doesn't exist, create empty one
		# TODO: Better handling for this edge case
        tagfile="${_TAGDIR}/${tag:1}" && touch "$tagfile"
        case "$tag" in
            \&*)        # Logical AND (set intersection)
                join "${_QUERY}" <(sort "$tagfile") >"${_QUERY}"
                ;;
            \|*)        # Logical OR (set union)
                sort -u -m "${_QUERY}" "$tagfile" >"${_QUERY}"	# Merge-sort
                ;;
            *)          # WTF?
                exit 23
                ;;
        esac
    done

    # Print query results
    cat "${_QUERY}"
	debug $(diff <(sort -u "${_QUERY}") "${_QUERY}")
    exit $?
}

queue_linked_dirs() {
	# Searches recursively for symlinked directories under a particular parent
	# directory name (e.g., "next" or "prev"), in order to simulate traversing a
	# linked list

	queue_linked_dirs_usage() {
		local title="${__NAME__}: ${FUNCNAME[1]}()"
		cat <<-USAGE
			
			${title}
			$(tr [:print:] [-*] <<< "${title}")
			
			OPTIONS:
			    -r recurse_dir      Recurse through directories named \${recurse_dir}		
			    -b base_dir         Base dir for recursive search
			    -d                  Order results by depth (shallow-first)
			    -D                  Order results by reverse depth (deep-first; default)
			    -h                  Show this message and exit
			
		USAGE
	}

	local recurse_dir="${_UPSTREAM_DIRNAME}"	# Default = upstream deps
	local prune_dir="${_DOWNSTREAM_DIRNAME}"	# Default = prune downstream
    local base_dir="$INSTALL"
	debug_vars recurse_dir prune_dir base_dir

	# Options for `sort` commands
	local depth="-k1"
	local name="-k2"
	local order="--reverse"

	while getopts ":r:p:b:dDh" opt; do
		case "$opt" in
			r)	# Name of directory to recurse into
				# Functions as a "next" pointer in a linked list
				recurse_dir="$OPTARG"
				;;
			p)	# Name of directory to prune whenever encountered
				# Functions as a "prev" pointer in a linked list
				prune_dir="$OPTARG"
				;;
			b)	# Base directory for the recursive search
				# Should be taken relative to root $INSTALL dir
				# TODO: Add support for an array of base_dirs
				base_dir+="/$OPTARG"
				;;
			d)	# Sort results based on depth (i.e., "shallow" first)
				# Appropriate for listing "downstream" dependencies
				order=
				;;
			D)	# Reverse-sort based on depth ("deep" first)
				# Appropritate for listing "upstream" dependencies
				reverse_sort=1
				order="--reverse"
				;;
			h)
				queue_linked_dirs_usage
				return 0
				;;
			*)
				queue_linked_dirs_usage >&2
				return 23
				;;
		esac
	done
	debug_vars recurse_dir prune_dir base_dir order name depth

	# Set positional args.  Nothing is done with them at this point.
	shift $(( OPTIND - 1 )) && OPTIND=1
	debug "Positional args:" "$@"

	# Find root-level dir corresponding to passed package name
	# TODO: Expand this using existing `query` functions to allow queuing
	# dependencies for arbitrary resultsets
	if [ ! -d "${base_dir}" ]; then
		debug_vars base_dir
		error "Could not find directory '${base_dir}'"
		return 1
	fi

	# Traverse directory tree using `find` and sort the results by depth.
	# Explanation of command by line:
	#	1:		Descend symlinked directories, but still print symlink paths
	#	2:		Prune directories named ${prune_dir}
	#	3-4:	Print the depth of dirs named ${recurse_dir}, followed by a
	#			newline and all immediate children (one per line)
	#	5-7:	Awk script: 
	#				- On lines consisting of a single number, assign that
	#				number to variable "depth"
	#				- On every other line, print depth followed by line contents
	#	8:		For each duplicate name in resultset, leave the one with the
	#			higher or lower depth (depending on sort order)
	#	9:		Apply sort options inferred from passed opts
	#	10:		Only print package names, not depths
	# set -x
	find -L "${base_dir}" \
		-name "${prune_dir}" -prune \
		-o -name "${recurse_dir}" -printf '%d\n' \
		-exec ls -1 \{\} \; |
		awk '
			/^[0-9]+$/ { depth = $0; next; } 
			{ printf "%s %s\n", depth, $0; }
		' | sort $order $name $depth | sort -u $name |
		sort $order $depth |
		cut -d ' ' $(tr k f <<< $name)-
	return $?
}

edit_package() {
    # Create and / or edit metadata file for package
    # Upstream and downstream dependencies are handled via symlinks (hard
    # links?)

    # local timestamp=`date -u`     # Unnecessary: git + filesystem takes care
                                    # of this for us
    local -a comments=( )
    local -a tags=( )
    local -a deps=( )
    local -a children=( )

    # Opts (added packages):
    # -c    Comments
    # -t    Tags
    # -p    Path.  Specify a directory tree relative to 
    #       repository root (basically another form of tagging).
    #       Unsupported for now, add in later (TODO)
    # -d    Dependencies (upstream): Must be installed first
    # -D    Children (downstream): Can install after
    # -h    Help: Display usage information
    while getopts ":c:t:d:D:h" opt; do
        case "$opt" in
            c)
                comments+=( "$OPTARG" )
                ;;
            t)
                tags+=( "$OPTARG" )
                ;;
            p)
                path="$OPTARG"
                ;;
            d)
                deps+=( $OPTARG )
                ;;
            D)
                children+=( $OPTARG )
                ;;
            h)
                usage; exit 0;
                ;;
            *)
                usage >&2; exit 2;
                ;;
		esac
    done

    shift $(( OPTIND - 1 )) && OPTIND=1
    ensure_dir "${repo}/${directory}" || 
        die "Directory '%s/%s' could not be created" \
            "$repo" "$directory"
}

log_subcmd() {
    # Args: command to run (verbatim) + args
    :
}

summary() {
    # Args: array of errors
    :
}

main() {
    local -A subcommands=( )
    local -a errors=( )

    # Opts (global):
    # -r    Repository root
    # -v    Increase verbosity
    # -q    Decrease verbosity
    # -l    Logfile
    # -n    No changes to repo (dry run)
    # -i    Interactive: Confirm changes
    # -b    Branch: Specify git branch name
    # -h    Global help text
    while [ $# -gt 0 ]; do
        case "$1" in
            r)      # "Repo"
                INSTALL="$OPTARG"
                ;;
            a)      # "Add"
                shift; subcommand="add_package"; break;
                ;;
            m)      # "Modify"
                ;;
            --)     # Passed through to subcommand
                break
                ;;
            *)
                usage >&2; exit 2;
                ;;
        esac
        shift
    done
    
    # "Plugin" subcommands (`cheat`, e.g.) should be in separate script files
    # Subcommands are separated by the word "--then"
    # Subcommands (global):
    # edit (default):
    # schedule:
    # config:
    # alias:
    # cheat:
    # snippet:
    # upstream:
    # downstream:
    # status:
    # history:
    # summary:
    # grep:
    # search:
    # query:
    # refresh:
    # update:

    # Validate globals and execute subcommands
    ensure_repo "${INSTALL}"
    for cmd in "${!subcommands[@]}"; do
        errors+=( "$(log_subcmd "$cmd" "${subcommands[$cmd]}")" )
    done
    summary "${errors[@]}"
    exit ${#errors}
}

if [ -n "${DEBUG+x}" ]; then
	$@		# This allows testing of individual functions by passing them as
			# args
else
	main "$@"
fi

##################################################################
###	Graveyard of bad ideas
##################################################################

collect() {
    # Poor man's YAML parser and writer for installed packages
    # Better strategy: Just have a separate file for each installed package,
    # worry about markup later
    local -a category=( )
    local package=
    local -i line=1
    while getopts ":c:" opt; do
        case "$opt" in
            c)
                category+=( "$OPTARG" )
                ;;
            *)
                return -1
                ;;
        esac
    done
    shift $(( OPTIND - 1 )) && OPTIND=1
    package="$1"
    # local idx=0 && while (( idx < ${#category} )); do
        # until [[ "$(sed -n '${line}p' "${_LOGFILE}")" =~ ^\ {$(( 2*idx ))}${category[$idx]}:$ ]] ||
        #   [ $line -gt $( wc -l "${_LOGFILE}" ) ]; do
            
}

trim() {
    sed -i -e '/^\s*$/d' "${_LOGFILE}"
    return $?
}

get_upstream() {
    # Prints a list of directories corresponding to upstream dependencies
	# Should preserve the order in which they appear in the dependency tree
	# Not sure if `find` can be configured to do this...

    local base_dir="${_INSTALL}/$1"
	if [ ! -f "${base_dir}" ]; then
		error "Could not find directory corresponding to package '$1'"
		return 1
	fi

    local -a upstream=( )
	local -a queue=( "$base_dir" )

	# This is really inefficient, but I'm not planning on using this on
	# directory trees of any appreciable size.
	# TODO: Rewrite this in C
	# while [ ${#queue} -gt 0 ]; do
		# get_downstream
	# done

    # Best `find`-based solution: prunes "downstream" directories immediately
    # find "${_INSTALL}/${package}" -path "**/${_DOWNSTREAM_DIRNAME}" \
    #    -prune -o -type l -print
	# Better:
	find -L "${_INSTALL}/${package}" -path "**/${_DOWNSTREAM_DIRNAME}" -prune \
		-o -name "${_UPSTREAM_DIRNAME}" \
		-o \( -type l -o -type d \) -print
}

query_recursive() {
	local queue="$(get_fifo)"
	# while [ ${#queue} -gt 0 ]; do
}

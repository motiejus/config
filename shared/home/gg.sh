# shellcheck shell=bash
_GG_MAXDEPTH=5

gg() {
    local _gopath
    _gopath=$(git rev-parse --show-toplevel)
	local paths=($(g "$@"))
	local path_index=0

	if [ ${#paths[@]} -gt 1 ]; then
		local c=1
		for path in "${paths[@]}"; do
			echo "[$c]: cd ${_gopath}/${path}"
			c=$((c+1))
		done
		echo -n "Go to which path: "
		read -r path_index

		path_index=$((path_index-1))
	fi

	local path=${paths[$path_index]}
	cd "$_gopath/$path" || {
        >&2 echo "?"
        exit 1
    }
}

#
# Print the directories of the specified Go package name.
#
g() {
    local pkg_candidates
    pkg_candidates="$( (cd "$_gopath" && find . -mindepth 1 -maxdepth ${_GG_MAXDEPTH} -type d -path "*/$1" -and -not -path '*/vendor/*' -print) | sed 's/^\.\///g')"
	echo "$pkg_candidates" | awk '{print length, $0 }' | sort -n | awk '{print $2}'
}
#
# Bash autocomplete for g and gg functions.
#
_g_complete()
{
    COMPREPLY=()
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=( $(compgen -W "$(for f in $(find "$_gopath" -mindepth 1 -maxdepth ${_GG_MAXDEPTH} -type d -name "${cur}*" ! -name '.*' ! -path '*/.git/*' ! -path '*/test/*' ! -path '*/vendor/*'); do echo "${f##*/}"; done)" --  "$cur") )
    return 0
}
complete -F _g_complete g
complete -F _g_complete gg

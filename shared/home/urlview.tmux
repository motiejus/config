# shellcheck shell=bash
get_tmux_option() {
  local option=$1
  local default_value=$2
  local option_value
  option_value=$(tmux show-option -gqv "$option")
  if [ -z "$option_value" ]; then
    echo "$default_value"
  else
    echo "$option_value"
  fi
}

tmux bind-key "$(get_tmux_option "@urlview-key" "u")" capture-pane -J \\\; \
  save-buffer "${TMPDIR:-/tmp}/tmux-buffer" \\\; \
  delete-buffer \\\; \
  split-window -l 10 "@extract_url@/bin/extract_url '${TMPDIR:-/tmp}/tmux-buffer'"

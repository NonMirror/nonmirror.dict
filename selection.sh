#!/usr/bin/env bash
# Print the word the dictionary plugin should look up: the user's most recent
# selection or copy, normalized to a single lookup term.
#
# This reuses the shared helper that the ~/.local/bin/dict-* scripts rely on,
# so the plugin and any remaining terminal tooling agree on whether the primary
# selection or the clipboard was touched last. When that library is missing we
# fall back to a plain primary-then-clipboard preference.

set -uo pipefail

if [[ -n ${1:-} ]]; then
  printf '%s' "$1"
  exit 0
fi

lib="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-dict/lib.sh"
if [[ -r $lib ]]; then
  # shellcheck disable=SC1090
  source "$lib"
  dict_term
  exit 0
fi

text="$(timeout 1 wl-paste --type text --primary --no-newline 2>/dev/null || true)"
if [[ -z ${text//[[:space:]]/} ]]; then
  text="$(timeout 1 wl-paste --type text --no-newline 2>/dev/null || true)"
fi
text="${text%%$'\n'*}"
text="$(printf '%s' "$text" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
text="$(printf '%s' "$text" | sed -E 's/^[^[:alnum:]]+//; s/[^[:alnum:]]+$//')"
printf '%s' "$text"

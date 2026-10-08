#!/usr/bin/env bash
# nixos-anywhere's extra_files_script: run in an empty directory that becomes
# the installed host's /, it writes there each file of EXTRA_FILES, a JSON
# object of absolute path to content (variable extra_files).
set -euo pipefail

jq -r 'keys[]' <<<"$EXTRA_FILES" | while IFS= read -r path; do
  rel=${path#/}
  # The directories are copied onto the host's own, permissions and all, so
  # they must not come out more private than /etc or /var are.
  (umask 022 && mkdir -p "$(dirname "$rel")")
  (umask 077 && jq -j --arg path "$path" '.[$path]' <<<"$EXTRA_FILES" >"$rel")
done

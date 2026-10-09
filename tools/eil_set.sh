#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# eil_set.sh -- re-derive the EIL app set from a ra8-firmware tree, the way
# scripts/emu/eil_all.sh discovers it, and print the count plus the HIL_MODE
# histogram over exactly that set.
#
# The EIL parity article in the knowledge base (RA8EMU-A-12) quotes numbers produced by this script. Quoting a count
# that cannot be re-derived is how the "83 of 122" figure outlived the tree it
# was measured on, so the numbers in that document carry this command.
#
# A count is only re-derivable against the tree it was taken from, and this set
# moves: it was 122 when the document was written and 125 a few days later. So
# the revision is printed with the numbers, and --list prints the app names, so
# a later drift is a diff rather than a discrepancy nobody can place.
#
# Usage: tools/eil_set.sh <path-to-ra8-firmware> [--list]

set -u

root="${1:?usage: eil_set.sh <path-to-ra8-firmware> [--list]}"
list_names="${2:-}"
hil="${root}/examples/ek_ra8d2/hw_validated/hil"
ra8p1="${root}/examples/ra8p1_foundation"

[ -d "$hil" ] || { echo "no HIL root at ${hil}" >&2; exit 2; }

# eil_all.sh discovers every directory directly under the HIL root (README.md
# is a file, so it falls out on its own), plus every ra8p1_foundation app that
# carries a hil.conf. Those RA8P1 apps are EIL-only: no HIL rig exists for them.
apps=()
while IFS= read -r d; do apps+=("$d"); done < <(find "$hil" -mindepth 1 -maxdepth 1 -type d | sort)
if [ -d "$ra8p1" ]; then
  while IFS= read -r d; do
    [ -f "${d}/hil.conf" ] && apps+=("$d")
  done < <(find "$ra8p1" -mindepth 1 -maxdepth 1 -type d | sort)
fi

total=0
no_conf=0
for d in "${apps[@]}"; do
  total=$((total + 1))
  [ -f "${d}/hil.conf" ] || { no_conf=$((no_conf + 1)); echo "no hil.conf: $(basename "$d")"; }
done

rev="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "tree ${root} at ${rev} (${branch})"
echo "discovered ${total} app(s), ${no_conf} without a hil.conf"
echo "modes:"
for d in "${apps[@]}"; do
  [ -f "${d}/hil.conf" ] && grep -E '^HIL_MODE=' "${d}/hil.conf" | head -1 | cut -d= -f2 | tr -d '"'
done | sort | uniq -c | sort -rn | sed 's/^/  /'

if [ "$list_names" = "--list" ]; then
  echo "apps:"
  for d in "${apps[@]}"; do basename "$d"; done | sort | sed 's/^/  /'
fi

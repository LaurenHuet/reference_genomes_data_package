#!/usr/bin/env bash
set -euo pipefail

# Stage HiFi reads from HIFI_BUCKET into:
#   ${STAGING_BASE_DIR}/${og_id}_{species_id}/hifi/
#
# Reads OG IDs and species names from hic_transfer_map_${PROJECT_ID}_*.csv
# (produced by pull_genome_statistics_by_project.py).
#
# Usage:
#   bash 02_get_hifi_from_config.sh refgenomes_data_package.conf

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <config.conf>" >&2
  exit 1
fi

CONFIG_FILE="$1"
[[ -f "$CONFIG_FILE" ]] || { echo "Config not found: $CONFIG_FILE" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

USER_REAL="${USER:-$(whoami)}"
expand_user() { printf '%s' "${1//\{user\}/$USER_REAL}"; }
clean() { printf '%s' "$1" | tr -d '\r' | xargs; }

safe_name() {
  LC_ALL=C printf '%s' "$1" \
    | sed -e 's/[[:space:]]\+/_/g' \
          -e 's,/,_,g' \
          -e 's/[^A-Za-z0-9_.+-]/_/g' \
          -e 's/__\+/_/g' \
          -e 's/^_//; s/_$//'
}

HIFI_BUCKET="${HIFI_BUCKET:?Missing HIFI_BUCKET in config}"
STAGING_BASE_DIR="${STAGING_BASE_DIR:?Missing STAGING_BASE_DIR in config}"
RCLONE_FLAGS="${RCLONE_FLAGS:-}"

PROJECT_ID="${PROJECT_ID:-}"
OG_ID="${OG_ID:-}"
PACKAGE_NAME="${PACKAGE_NAME:-}"
if [[ -n "$OG_ID" ]]; then
  DATA_ID="${PACKAGE_NAME:?PACKAGE_NAME must be set in config when using OG_ID mode}"
elif [[ -n "$PROJECT_ID" ]]; then
  DATA_ID="$PROJECT_ID"
else
  echo "Either PROJECT_ID or OG_ID must be set in config" >&2; exit 1
fi

STAGING_BASE_DIR="$(expand_user "$STAGING_BASE_DIR")"

HIC_MAP="$(ls -1t "${STAGING_BASE_DIR}/hic_transfer_map_${DATA_ID}_"*.csv 2>/dev/null | head -n 1 || true)"
[[ -n "$HIC_MAP" ]] || { echo "Hi-C map CSV not found in ${STAGING_BASE_DIR} (expected hic_transfer_map_${DATA_ID}_*.csv)" >&2; exit 1; }

echo "Using Hi-C transfer map: $HIC_MAP"
echo "Using HIFI_BUCKET:       $HIFI_BUCKET"

# Build og_id -> target_dir (unique OG IDs from hic_transfer_map, same naming as 01)
declare -A OG_TO_TARGET

while IFS=$'\t' read -r og species _tube; do
  og="$(clean "$og")"
  species="$(clean "$species")"
  [[ -z "$og" ]] && continue
  [[ -n "${OG_TO_TARGET[$og]:-}" ]] && continue  # already seen this OG

  dir="$(safe_name "$og")"
  sp="$(safe_name "$species")"
  [[ -n "$sp" ]] && dir="${dir}_${sp}"

  OG_TO_TARGET["$og"]="${STAGING_BASE_DIR}/${dir}/hifi"
done < <(awk -F, 'NR>1 { gsub(/\r/,"",$1); gsub(/\r/,"",$2); gsub(/\r/,"",$3); print $1 "\t" $2 "\t" $3 }' "$HIC_MAP")

[[ ${#OG_TO_TARGET[@]} -gt 0 ]] || { echo "No OG IDs found in $HIC_MAP" >&2; exit 1; }

tmp_list="$(mktemp)"
trap 'rm -f "$tmp_list"' EXIT

# Include filters: OG##_*hifi_reads* — underscore after ID prevents OG64 matching OG645
include=()
for og in "${!OG_TO_TARGET[@]}"; do
  include+=( --include "*${og}_*hifi_reads*" )
done

rclone ls ${RCLONE_FLAGS:+$RCLONE_FLAGS} "$HIFI_BUCKET" "${include[@]}" > "$tmp_list"

copied=0

while IFS= read -r line || [[ -n "$line" ]]; do
  path="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//; s/\r$//')"
  [[ -n "$path" ]] || continue

  base="$(basename "$path")"

  # Extract OG ID: strip everything from first non-digit after OG (e.g. OG748_... or OG1G_... -> OG748, OG1)
  og="$(printf '%s' "$base" | sed -E 's/^(OG[0-9]+)[^0-9].*/\1/')"
  [[ -n "$og" ]] || continue
  [[ -n "${OG_TO_TARGET[$og]:-}" ]] || continue

  target="${OG_TO_TARGET[$og]}"
  mkdir -p "$target"

  echo "Copying ${HIFI_BUCKET}/${path} -> ${target}/"
  rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} "${HIFI_BUCKET}/${path}" "${target}/"
  ((++copied))
done < "$tmp_list"

echo ""
echo "Done. OG IDs: ${#OG_TO_TARGET[@]} | Files copied: ${copied}"

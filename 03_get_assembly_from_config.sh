#!/usr/bin/env bash
set -euo pipefail

# Stage curated assembly files from ASSEMBLY_BUCKET into:
#   ${STAGING_BASE_DIR}/${og_id}_{species_id}/assembly/
#
# Reads OG IDs from hic_transfer_map and draft_transfer_map CSVs
# (produced by pull_genome_statistics_by_project.py).
#
# For each OG, tries stage-3 first (${og}*curated.hap1/hap2.chr_level.fa*).
# Falls back to stage-2 (${og}*2.tiara*.fa*) if no stage-3 files found.
#
# Usage:
#   bash 03_get_assembly_from_config.sh refgenomes_data_package.conf

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

ASSEMBLY_BUCKET="${ASSEMBLY_BUCKET:?Missing ASSEMBLY_BUCKET in config}"
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
DRAFT_MAP="$(ls -1t "${STAGING_BASE_DIR}/draft_transfer_map_${DATA_ID}_"*.csv 2>/dev/null | head -n 1 || true)"

[[ -n "$HIC_MAP" || -n "$DRAFT_MAP" ]] || {
  echo "No transfer map CSV found in ${STAGING_BASE_DIR}" >&2; exit 1
}

echo "Using ASSEMBLY_BUCKET: $ASSEMBLY_BUCKET"
[[ -n "$HIC_MAP"   ]] && echo "Using Hi-C transfer map:   $HIC_MAP"
[[ -n "$DRAFT_MAP" ]] && echo "Using draft transfer map:  $DRAFT_MAP"

# Build og_id -> target_dir from HiC map (ref genomes)
declare -A OG_TO_TARGET

if [[ -n "$HIC_MAP" ]]; then
  while IFS=$'\t' read -r og species _tube; do
    og="$(clean "$og")"
    species="$(clean "$species")"
    [[ -z "$og" ]] && continue
    [[ -n "${OG_TO_TARGET[$og]:-}" ]] && continue

    dir="$(safe_name "$og")"
    sp="$(safe_name "$species")"
    [[ -n "$sp" ]] && dir="${dir}_${sp}"

    OG_TO_TARGET["$og"]="${STAGING_BASE_DIR}/${dir}/assembly"
  done < <(awk -F, 'NR>1 { gsub(/\r/,"",$1); gsub(/\r/,"",$2); gsub(/\r/,"",$3); print $1 "\t" $2 "\t" $3 }' "$HIC_MAP")
fi

# Add OG IDs from draft map (draft genomes not in HiC map)
if [[ -n "$DRAFT_MAP" ]]; then
  while IFS=$'\t' read -r og species _nominal; do
    og="$(clean "$og")"
    species="$(clean "$species")"
    [[ -z "$og" ]] && continue
    [[ -n "${OG_TO_TARGET[$og]:-}" ]] && continue

    dir="$(safe_name "$og")"
    sp="$(safe_name "$species")"
    [[ -n "$sp" ]] && dir="${dir}_${sp}"

    OG_TO_TARGET["$og"]="${STAGING_BASE_DIR}/${dir}/assembly"
  done < <(awk -F, 'NR>1 { gsub(/\r/,"",$1); gsub(/\r/,"",$2); gsub(/\r/,"",$3); print $1 "\t" $2 "\t" $3 }' "$DRAFT_MAP")
fi

[[ ${#OG_TO_TARGET[@]} -gt 0 ]] || { echo "No OG IDs found in transfer maps" >&2; exit 1; }

tmp_list="$(mktemp)"
trap 'rm -f "$tmp_list"' EXIT

copied=0
declare -A HAS_STAGE3

# --- Pass 1: stage-3 curated chromosome-level assemblies ---
echo ""
echo "=== Pass 1: stage-3 (curated chr-level) ==="
stage3_include=()
for og in "${!OG_TO_TARGET[@]}"; do
  stage3_include+=( --include "${og}*curated.hap1.chr_level.fa*" )
  stage3_include+=( --include "${og}*curated.hap2.chr_level.fa*" )
done

rclone ls ${RCLONE_FLAGS:+$RCLONE_FLAGS} "$ASSEMBLY_BUCKET" "${stage3_include[@]}" > "$tmp_list"

while IFS= read -r line || [[ -n "$line" ]]; do
  path="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//; s/\r$//')"
  [[ -n "$path" ]] || continue

  og="$(printf '%s' "$path" | grep -o -E '^OG[0-9]+' || true)"
  [[ -n "$og" ]] || continue
  [[ -n "${OG_TO_TARGET[$og]:-}" ]] || continue

  HAS_STAGE3["$og"]=1
  target="${OG_TO_TARGET[$og]}"
  mkdir -p "$target"

  echo "Copying (stage 3) ${ASSEMBLY_BUCKET}/${path} -> ${target}/"
  rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} "${ASSEMBLY_BUCKET}/${path}" "${target}/"
  ((++copied))
done < "$tmp_list"

# --- Pass 2: stage-2 fallback (2.tiara) for OGs with no stage-3 hit ---
stage2_ogs=()
for og in "${!OG_TO_TARGET[@]}"; do
  [[ -n "${HAS_STAGE3[$og]:-}" ]] || stage2_ogs+=("$og")
done

if [[ ${#stage2_ogs[@]} -gt 0 ]]; then
  echo ""
  echo "=== Pass 2: stage-2 fallback (2.tiara) for ${#stage2_ogs[@]} OG(s) ==="
  stage2_include=()
  for og in "${stage2_ogs[@]}"; do
    stage2_include+=( --include "${og}*2.tiara*.fa*" )
  done

  rclone ls ${RCLONE_FLAGS:+$RCLONE_FLAGS} "$ASSEMBLY_BUCKET" "${stage2_include[@]}" > "$tmp_list"

  while IFS= read -r line || [[ -n "$line" ]]; do
    path="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//; s/\r$//')"
    [[ -n "$path" ]] || continue

    og="$(printf '%s' "$path" | grep -o -E '^OG[0-9]+' || true)"
    [[ -n "$og" ]] || continue
    [[ -n "${OG_TO_TARGET[$og]:-}" ]] || continue

    target="${OG_TO_TARGET[$og]}"
    mkdir -p "$target"

    echo "Copying (stage 2) ${ASSEMBLY_BUCKET}/${path} -> ${target}/"
    rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} "${ASSEMBLY_BUCKET}/${path}" "${target}/"
    ((++copied))
  done < "$tmp_list"
fi

echo ""
echo "Done. OG IDs: ${#OG_TO_TARGET[@]} | Stage-3 hits: ${#HAS_STAGE3[@]} | Files copied: ${copied}"

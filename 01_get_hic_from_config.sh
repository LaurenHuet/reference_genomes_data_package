#!/usr/bin/env bash
set -euo pipefail

# Stage Hi-C FASTQ.gz using hic_transfer_map_${PROJECT_ID}_*.csv into:
#   ${STAGING_BASE_DIR}/${og_id}_${species_id}/hic/
#
# It copies ONLY files where:
#   - path ends with .fastq.gz
#   - basename starts with the tube id, e.g. OG40G-2_HICL_...
#
# Usage:
#   bash 01_get_hic_from_config.sh refgenomes_data_package.conf

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

HIC_BUCKET="${HIC_BUCKET:?Missing HIC_BUCKET in config}"
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
[[ -f "$HIC_MAP" ]] || { echo "Hi-C map CSV not found: $HIC_MAP" >&2; exit 1; }

echo "Using Hi-C transfer map: $HIC_MAP"
echo "Using HIC_BUCKET:        $HIC_BUCKET"

# tube_id -> target_dir (deduped by associative array)
declare -A TUBE_TO_TARGET

while IFS=$'\t' read -r og species tube; do
  og="$(clean "$og")"
  species="$(clean "$species")"
  tube="$(clean "$tube")"
  [[ -z "$og" || -z "$tube" ]] && continue

  dir="$(safe_name "$og")"
  sp="$(safe_name "$species")"
  [[ -n "$sp" ]] && dir="${dir}_${sp}"

  TUBE_TO_TARGET["$tube"]="${STAGING_BASE_DIR}/${dir}/hic"
done < <(awk -F, 'NR>1 { gsub(/\r/,"",$1); gsub(/\r/,"",$2); gsub(/\r/,"",$3); print $1 "\t" $2 "\t" $3 }' "$HIC_MAP")

[[ ${#TUBE_TO_TARGET[@]} -gt 0 ]] || { echo "No tube IDs found in $HIC_MAP" >&2; exit 1; }

copied=0
tubes=0
tubes_with_hits=0

for tube in "${!TUBE_TO_TARGET[@]}"; do
  ((++tubes))
  target="${TUBE_TO_TARGET[$tube]}"
  mkdir -p "$target"

  echo ""
  echo "== Tube: $tube"
  echo "   -> $target"

  # List ALL fastq.gz under bucket, but only those starting with the tube id in the filename.
  # Example expected basename: OG40G-2_HICL_S1_L001_R1_001.fastq.gz
  mapfile -t paths < <(
    rclone lsf "$HIC_BUCKET" ${RCLONE_FLAGS:+$RCLONE_FLAGS} --recursive \
      --include "*fastq.gz" \
    | awk -v tube="$tube" -F/ '
        {
          n=split($0,a,"/");
          base=a[n];
          if (index(base, tube) == 1) print $0;  # basename starts with tube
        }'
  )

  if [[ ${#paths[@]} -eq 0 ]]; then
    echo "   (no fastq.gz matches for this tube)"
    continue
  fi

  ((++tubes_with_hits))

  for p in "${paths[@]}"; do
    echo "Copying ${HIC_BUCKET}/${p} -> ${target}/"
    rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} "${HIC_BUCKET}/${p}" "${target}/"
    ((++copied))
  done
done

echo ""
echo "Done. Tubes: ${tubes} | Tubes with hits: ${tubes_with_hits} | FASTQ copied: ${copied}"

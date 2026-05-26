#!/usr/bin/env bash
set -euo pipefail

# Stage draft genome assemblies and Illumina reads from DRAFT_BUCKET into:
#   ${STAGING_BASE_DIR}/${og_id}_{species_id}/assembly/   <- .fna file
#   ${STAGING_BASE_DIR}/${og_id}_{species_id}/reads/      <- R1/R2 .fastq.gz
#
# Reads OG IDs from draft_transfer_map_${PROJECT_ID}_*.csv
# (produced by pull_genome_statistics_by_project.py).
#
# Remote structure assumed:
#   DRAFT_BUCKET/{og}/assemblies/genome/{og}.*.fna
#   DRAFT_BUCKET/{og}/fastp/{og}.*.R1.fastq.gz
#   DRAFT_BUCKET/{og}/fastp/{og}.*.R2.fastq.gz
#
# Usage:
#   bash 05_get_draft_from_config.sh refgenomes_data_package.conf

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

DRAFT_BUCKET="${DRAFT_BUCKET:?Missing DRAFT_BUCKET in config}"
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

DRAFT_MAP="$(ls -1t "${STAGING_BASE_DIR}/draft_transfer_map_${DATA_ID}_"*.csv 2>/dev/null | head -n 1 || true)"
[[ -n "$DRAFT_MAP" ]] || { echo "Draft map CSV not found in ${STAGING_BASE_DIR} (expected draft_transfer_map_${DATA_ID}_*.csv)" >&2; exit 1; }

echo "Using draft transfer map: $DRAFT_MAP"
echo "Using DRAFT_BUCKET:       $DRAFT_BUCKET"

# Build og_id -> (assembly_target, reads_target)
declare -A OG_TO_ASSEMBLY
declare -A OG_TO_READS

while IFS=$'\t' read -r og species nominal; do
  og="$(clean "$og")"
  species="$(clean "$species")"
  nominal="$(clean "$nominal")"
  [[ -z "$og" ]] && continue

  dir="$(safe_name "$og")"
  # Use nominal_species_id if available (more specific), fall back to species_id
  label="${nominal:-$species}"
  sp="$(safe_name "$label")"
  [[ -n "$sp" ]] && dir="${dir}_${sp}"

  OG_TO_ASSEMBLY["$og"]="${STAGING_BASE_DIR}/${dir}/assembly"
  OG_TO_READS["$og"]="${STAGING_BASE_DIR}/${dir}/reads"
done < <(awk -F, 'NR>1 { gsub(/\r/,"",$1); gsub(/\r/,"",$2); gsub(/\r/,"",$3); print $1 "\t" $2 "\t" $3 }' "$DRAFT_MAP")

[[ ${#OG_TO_ASSEMBLY[@]} -gt 0 ]] || { echo "No draft OG IDs found in $DRAFT_MAP" >&2; exit 1; }

echo "Draft OGs to process: ${!OG_TO_ASSEMBLY[*]}"

assembly_copied=0
reads_copied=0
ogs=0
ogs_with_hits=0

for og in "${!OG_TO_ASSEMBLY[@]}"; do
  ((++ogs))
  asm_target="${OG_TO_ASSEMBLY[$og]}"
  reads_target="${OG_TO_READS[$og]}"

  echo ""
  echo "== OG: $og"
  echo "   assembly -> $asm_target"
  echo "   reads    -> $reads_target"

  # --- Assembly: .fna file from assemblies/genome/ ---
  mapfile -t fna_paths < <(
    rclone lsf "${DRAFT_BUCKET}/${og}/assemblies/genome" ${RCLONE_FLAGS:+$RCLONE_FLAGS} \
      --include "*.fna" 2>/dev/null || true
  )

  if [[ ${#fna_paths[@]} -eq 0 ]]; then
    echo "   (no .fna found for $og)"
  else
    mkdir -p "$asm_target"
    for f in "${fna_paths[@]}"; do
      echo "Copying ${DRAFT_BUCKET}/${og}/assemblies/genome/${f} -> ${asm_target}/"
      rclone copyto ${RCLONE_FLAGS:+$RCLONE_FLAGS} \
        "${DRAFT_BUCKET}/${og}/assemblies/genome/${f}" \
        "${asm_target}/${f}"
      ((++assembly_copied))
      ((++ogs_with_hits))
    done
  fi

  # --- Reads: R1/R2 .fastq.gz from fastp/ ---
  mapfile -t fq_paths < <(
    rclone lsf "${DRAFT_BUCKET}/${og}/fastp" ${RCLONE_FLAGS:+$RCLONE_FLAGS} \
      --include "*.fastq.gz" 2>/dev/null || true
  )

  if [[ ${#fq_paths[@]} -eq 0 ]]; then
    echo "   (no .fastq.gz found for $og)"
  else
    mkdir -p "$reads_target"
    for f in "${fq_paths[@]}"; do
      echo "Copying ${DRAFT_BUCKET}/${og}/fastp/${f} -> ${reads_target}/"
      rclone copyto ${RCLONE_FLAGS:+$RCLONE_FLAGS} \
        "${DRAFT_BUCKET}/${og}/fastp/${f}" \
        "${reads_target}/${f}"
      ((++reads_copied))
    done
  fi
done

echo ""
echo "Done. OGs: ${ogs} | OGs with hits: ${ogs_with_hits} | Assemblies copied: ${assembly_copied} | Reads copied: ${reads_copied}"

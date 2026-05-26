#!/usr/bin/env bash
set -euo pipefail

# Run the mitogenome pipeline (steps 01-07) for this project's OG IDs,
# then distribute the compiled output into:
#   ${STAGING_BASE_DIR}/${og_id}_{species_id}/mitogenome/FA/
#   ${STAGING_BASE_DIR}/${og_id}_{species_id}/mitogenome/GENES/
#   ${STAGING_BASE_DIR}/${og_id}_{species_id}/mitogenome/GFF/
#
# OG IDs are taken from BOTH hic_transfer_map (ref genomes) AND
# draft_transfer_map (draft genomes) so all project OGs get mitogenomes.
#
# Requires:
#   MITO_PIPELINE_DIR — path to Data_Package_Pipeline_Mitogenomes
#   SING              — path to Singularity container directory (or set in environment)
#   POSTGRES_CFG      — path to PostgreSQL credentials file
#
# Usage:
#   bash 04_get_mito_from_config.sh refgenomes_data_package.conf

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

MITO_PIPELINE_DIR="${MITO_PIPELINE_DIR:?Missing MITO_PIPELINE_DIR in config}"
POSTGRES_CFG="${POSTGRES_CFG:?Missing POSTGRES_CFG in config}"
STAGING_BASE_DIR="${STAGING_BASE_DIR:?Missing STAGING_BASE_DIR in config}"
SING="${SING:-}"

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
[[ -n "$SING" ]] || { echo "SING is not set — add it to config or export it in your environment" >&2; exit 1; }
RCLONE_FLAGS="${RCLONE_FLAGS:-}"

STAGING_BASE_DIR="$(expand_user "$STAGING_BASE_DIR")"
POSTGRES_CFG="$(expand_user "$POSTGRES_CFG")"
MITO_PIPELINE_DIR="$(expand_user "$MITO_PIPELINE_DIR")"
SING="$(expand_user "$SING")"

[[ -d "$MITO_PIPELINE_DIR" ]] || { echo "MITO_PIPELINE_DIR not found: $MITO_PIPELINE_DIR" >&2; exit 1; }
[[ -f "$POSTGRES_CFG" ]]      || { echo "POSTGRES_CFG not found: $POSTGRES_CFG" >&2; exit 1; }

HIC_MAP="$(ls -1t "${STAGING_BASE_DIR}/hic_transfer_map_${DATA_ID}_"*.csv 2>/dev/null | head -n 1 || true)"
[[ -n "$HIC_MAP" ]] || { echo "Hi-C map CSV not found in ${STAGING_BASE_DIR}" >&2; exit 1; }

DRAFT_MAP="$(ls -1t "${STAGING_BASE_DIR}/draft_transfer_map_${DATA_ID}_"*.csv 2>/dev/null | head -n 1 || true)"

echo "Using Hi-C transfer map:   $HIC_MAP"
[[ -n "$DRAFT_MAP" ]] && echo "Using draft transfer map:  $DRAFT_MAP" || echo "No draft transfer map found — only ref genome OGs will be processed"
echo "Using MITO_PIPELINE_DIR:   $MITO_PIPELINE_DIR"

# Build og_id -> mitogenome target dir
# Sources: hic_transfer_map (ref genomes) + draft_transfer_map (draft genomes)
declare -A OG_TO_TARGET

# --- Ref genome OGs from hic_transfer_map ---
while IFS=$'\t' read -r og species _tube; do
  og="$(clean "$og")"
  species="$(clean "$species")"
  [[ -z "$og" ]] && continue
  [[ -n "${OG_TO_TARGET[$og]:-}" ]] && continue

  dir="$(safe_name "$og")"
  sp="$(safe_name "$species")"
  [[ -n "$sp" ]] && dir="${dir}_${sp}"

  OG_TO_TARGET["$og"]="${STAGING_BASE_DIR}/${dir}/mitogenome"
done < <(awk -F, 'NR>1 { gsub(/\r/,"",$1); gsub(/\r/,"",$2); gsub(/\r/,"",$3); print $1 "\t" $2 "\t" $3 }' "$HIC_MAP")

# --- Draft genome OGs from draft_transfer_map ---
if [[ -n "$DRAFT_MAP" ]]; then
  while IFS=$'\t' read -r og species nominal; do
    og="$(clean "$og")"
    species="$(clean "$species")"
    nominal="$(clean "$nominal")"
    [[ -z "$og" ]] && continue
    [[ -n "${OG_TO_TARGET[$og]:-}" ]] && continue

    dir="$(safe_name "$og")"
    label="${nominal:-$species}"
    sp="$(safe_name "$label")"
    [[ -n "$sp" ]] && dir="${dir}_${sp}"

    OG_TO_TARGET["$og"]="${STAGING_BASE_DIR}/${dir}/mitogenome"
  done < <(awk -F, 'NR>1 { gsub(/\r/,"",$1); gsub(/\r/,"",$2); gsub(/\r/,"",$3); print $1 "\t" $2 "\t" $3 }' "$DRAFT_MAP")
fi

[[ ${#OG_TO_TARGET[@]} -gt 0 ]] || { echo "No OG IDs found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Write list.txt and project.txt for the mitogenome pipeline
# ---------------------------------------------------------------------------
echo "Writing list.txt (${#OG_TO_TARGET[@]} OGs) and project.txt in $MITO_PIPELINE_DIR"
printf '%s\n' "${!OG_TO_TARGET[@]}" | sort > "${MITO_PIPELINE_DIR}/list.txt"
printf '%s\n' "$DATA_ID"            > "${MITO_PIPELINE_DIR}/project.txt"

# ---------------------------------------------------------------------------
# Run mitogenome pipeline steps 01-07 from within the pipeline directory
# ---------------------------------------------------------------------------
pushd "$MITO_PIPELINE_DIR" > /dev/null

# Clean up stale outputs from any previous run so each run starts fresh
rm -f output/metadata.csv \
      output/metadata_latlon_cleaned.csv \
      output/metadata_latlon_cleaned.csv.bak \
      output/file_check_report.csv \
      output/staging_plan.csv \
      output/staging_warnings_log.csv \
      output/staging_skipped_log.csv \
      output/mitogenome_structure_check.csv
rm -rf output/staging mitogenome_package

echo ""
echo "=== Step 01: build source modifiers ==="
singularity run "${SING}/psycopg2:0.1.sif" \
  python 01_build_source_modifiers.py list.txt "$POSTGRES_CFG"

echo ""
echo "=== Step 02: validate remote mitogenome files ==="
python 02_mitogenome_filechecker.py

echo ""
echo "=== Step 03: generate staging plan ==="
singularity run "${SING}/psycopg2:0.1.sif" \
  python 03_generate_staging_plan.py "$POSTGRES_CFG"

echo ""
echo "=== Step 04: run staging plan (copy & normalise) ==="
python 04_run_staging_plan.py

echo ""
echo "=== Step 05: extract gene sequences ==="
singularity run "${SING}/psycopg2:0.1.sif" \
  python 05_pull_cds_from_fasta_using_gff.py

echo ""
echo "=== Step 06: mitogenome structure QC ==="
singularity run "${SING}/psycopg2:0.1.sif" \
  python 06_mitogenome_structure_check_from_gff.py

echo ""
echo "=== Step 07: compile delivery package ==="
python 07_compile_files.py

popd > /dev/null

# ---------------------------------------------------------------------------
# Distribute compiled output into per-OG staging directories
# Files go into mitogenome/FA/, mitogenome/GENES/, mitogenome/GFF/
# ---------------------------------------------------------------------------
MITO_PKG="${MITO_PIPELINE_DIR}/mitogenome_package"

[[ -d "$MITO_PKG" ]] || { echo "mitogenome_package/ not found after pipeline run: $MITO_PKG" >&2; exit 1; }

echo ""
echo "=== Distributing mitogenome_package/ into staging tree ==="

copied=0

for subdir in FA GENES GFF; do
  src_dir="${MITO_PKG}/${subdir}"
  [[ -d "$src_dir" ]] || { echo "Warning: ${subdir}/ not found in mitogenome_package, skipping" >&2; continue; }

  for f in "${src_dir}"/*; do
    [[ -f "$f" ]] || continue
    fname="$(basename "$f")"

    og="$(printf '%s' "$fname" | grep -o -E '^OG[0-9]+' || true)"
    [[ -n "$og" ]] || { echo "Warning: could not extract OG ID from $fname, skipping" >&2; continue; }
    [[ -n "${OG_TO_TARGET[$og]:-}" ]] || { echo "Warning: $og not in project OG list, skipping $fname" >&2; continue; }

    target="${OG_TO_TARGET[$og]}/${subdir}"
    mkdir -p "$target"

    echo "Copying ${subdir}/${fname} -> ${target}/"
    cp "$f" "${target}/"
    ((++copied))
  done
done

# Copy shared metadata CSV to staging base dir
metadata="${MITO_PKG}/mitogenome_metadata.csv"
if [[ -f "$metadata" ]]; then
  echo "Copying mitogenome_metadata.csv -> ${STAGING_BASE_DIR}/"
  cp "$metadata" "${STAGING_BASE_DIR}/mitogenome_metadata_${DATA_ID}.csv"
fi

echo ""
echo "Done. Files distributed: ${copied}"

#!/usr/bin/env bash
set -euo pipefail

# 06_compile_package.sh
#
# Compile the final data package into the standard structure:
#
#   {Species}_reference/                   <- stage-3 curated assembly + gfastats (flat)
#   {Species}_draft/{og}/                  <- .fna + R1/R2 reads
#   {Species}_hifi_assembly/
#     assembly/                            <- .fasta + .gfa
#     gfastats/                            <- assembly_summary.txt
#     hifi_reads_raw/                      <- .bam
#
# Type is determined per OG:
#   reference    — OG appears in the assembly stats CSV (stage-3 chr-level assembly)
#   hifi_assembly — OG has a hifiasm assembly in ASSEMBLY_BUCKET but no .fna in DRAFT_BUCKET
#   draft        — OG has illumina .fna + reads in DRAFT_BUCKET
#
# Reuses already-staged files (mv) where possible; rclone-copies only what is missing.
#
# Usage:
#   bash 06_compile_package.sh refgenomes_data_package.conf

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <config.conf>" >&2; exit 1
fi

CONFIG_FILE="$1"
[[ -f "$CONFIG_FILE" ]] || { echo "Config not found: $CONFIG_FILE" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

USER_REAL="${USER:-$(whoami)}"
expand_user() { printf '%s' "${1//\{user\}/$USER_REAL}"; }
clean()       { printf '%s' "$1" | tr -d '\r' | xargs; }

safe_name() {
  LC_ALL=C printf '%s' "$1" \
    | sed -e 's/[[:space:]]\+/_/g' \
          -e 's,/,_,g' \
          -e 's/[^A-Za-z0-9_.+-]/_/g' \
          -e 's/__\+/_/g' \
          -e 's/^_//; s/_$//'
}

# ---- resolve config vars -----------------------------------------------
STAGING_BASE_DIR="$(expand_user "${STAGING_BASE_DIR:?Missing STAGING_BASE_DIR}")"
ASSEMBLY_BUCKET="${ASSEMBLY_BUCKET:?Missing ASSEMBLY_BUCKET}"
DRAFT_BUCKET="${DRAFT_BUCKET:?Missing DRAFT_BUCKET}"
HIFI_BUCKET="${HIFI_BUCKET:?Missing HIFI_BUCKET}"
RCLONE_FLAGS="${RCLONE_FLAGS:-}"

PROJECT_ID="${PROJECT_ID:-}"
OG_ID="${OG_ID:-}"
PACKAGE_NAME="${PACKAGE_NAME:-}"
if [[ -n "$OG_ID" ]]; then
  DATA_ID="${PACKAGE_NAME:?PACKAGE_NAME must be set when using OG_ID mode}"
elif [[ -n "$PROJECT_ID" ]]; then
  DATA_ID="$PROJECT_ID"
else
  echo "Either PROJECT_ID or OG_ID must be set in config" >&2; exit 1
fi

# ---- find transfer maps + stats ----------------------------------------
STATS_CSV="$(ls -1t "${STAGING_BASE_DIR}/refgenomes_assembly_stats_${DATA_ID}_"*.csv 2>/dev/null | head -1 || true)"
DRAFT_MAP="$(ls -1t "${STAGING_BASE_DIR}/draft_transfer_map_${DATA_ID}_"*.csv 2>/dev/null | head -1 || true)"

[[ -n "$STATS_CSV" ]] || { echo "Assembly stats CSV not found in ${STAGING_BASE_DIR}" >&2; exit 1; }
[[ -n "$DRAFT_MAP" ]] || echo "No draft transfer map found — draft/hifi_assembly OGs will not be included"

echo "Stats CSV:  $STATS_CSV"
[[ -n "$DRAFT_MAP" ]] && echo "Draft map:  $DRAFT_MAP"

# ---- build OG → species mapping ----------------------------------------
declare -A OG_SPECIES OG_TYPE

# reference OGs come from the assembly stats CSV (Sample column = og_id, Species ID column)
while IFS=, read -r og species _rest; do
  og="$(clean "$og")"; species="$(clean "$species")"
  [[ "$og" == "Sample" || -z "$og" ]] && continue
  OG_SPECIES["$og"]="$species"
  OG_TYPE["$og"]="reference"
done < "$STATS_CSV"

# draft/hifi OGs from draft map
while IFS=, read -r og species _rest; do
  og="$(clean "$og")"; species="$(clean "$species")"
  [[ "$og" == "og_id" || -z "$og" ]] && continue
  [[ -n "${OG_SPECIES[$og]:-}" ]] || OG_SPECIES["$og"]="$species"

  if [[ -n "${OG_TYPE[$og]:-}" ]]; then continue; fi  # already reference

  # Determine hifi_assembly vs draft: check if DRAFT_BUCKET has a .fna for this OG
  if rclone lsf "${DRAFT_BUCKET}/${og}/assemblies/genome/" ${RCLONE_FLAGS:+$RCLONE_FLAGS} 2>/dev/null \
       | grep -q '\.fna$'; then
    OG_TYPE["$og"]="draft"
  else
    OG_TYPE["$og"]="hifi_assembly"
  fi
done < "$DRAFT_MAP"

# Handle OG IDs from config that may not yet be in the transfer maps (e.g. OG861)
if [[ -n "$OG_ID" ]]; then
  IFS=',' read -ra _extra_ogs <<< "$OG_ID"
  for og in "${_extra_ogs[@]}"; do
    og="$(clean "$og")"
    [[ -z "$og" || -n "${OG_TYPE[$og]:-}" ]] && continue
    if rclone lsf "${DRAFT_BUCKET}/${og}/assemblies/genome/" ${RCLONE_FLAGS:+$RCLONE_FLAGS} 2>/dev/null \
         | grep -q '\.fna$'; then
      OG_TYPE["$og"]="draft"
      # Look up species from DB if not already known
      if [[ -z "${OG_SPECIES[$og]:-}" || "${OG_SPECIES[$og]}" == "unknown" ]]; then
        species="$(singularity run "${SING}/psycopg2:0.1.sif" python3 - <<PYEOF 2>/dev/null
import configparser, psycopg2, os
p = configparser.ConfigParser()
p.read(os.path.expanduser("${POSTGRES_CFG}"))
s = p["postgres"]
conn = psycopg2.connect(dbname=s["dbname"], user=s["user"], password=s["password"], host=s["host"])
cur = conn.cursor()
cur.execute("SELECT COALESCE(MAX(nominal_species_id)::text,'') FROM sample WHERE og_id=%s", ("${og}",))
print(cur.fetchone()[0])
conn.close()
PYEOF
        )" || true
        OG_SPECIES["$og"]="${species:-unknown}"
      fi
    fi
  done
fi

# ---- print classification ----------------------------------------------
echo ""
echo "OG classification:"
for og in $(printf '%s\n' "${!OG_TYPE[@]}" | sort); do
  printf "  %-10s  %-15s  %s\n" "$og" "${OG_TYPE[$og]}" "${OG_SPECIES[$og]:-}"
done
echo ""

# ---- helper: move file if staged locally, else rclone copy -------------
move_or_copy() {
  local src_local="$1"   # existing local path (may not exist)
  local src_remote="$2"  # rclone remote path (fallback)
  local dest_dir="$3"    # destination directory

  mkdir -p "$dest_dir"
  if [[ -f "$src_local" ]]; then
    echo "  mv  $(basename "$src_local") -> ${dest_dir}/"
    mv "$src_local" "${dest_dir}/"
  else
    echo "  rclone copy  ${src_remote} -> ${dest_dir}/"
    rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} "$src_remote" "${dest_dir}/"
  fi
}

# ---- compile reference OGs ---------------------------------------------
for og in "${!OG_TYPE[@]}"; do
  [[ "${OG_TYPE[$og]}" == "reference" ]] || continue

  sp="$(safe_name "${OG_SPECIES[$og]}")"
  target="${STAGING_BASE_DIR}/${sp}_reference"
  mkdir -p "$target"

  echo "=== ${og} → ${sp}_reference ==="

  # chr-level assembly files: look in old staging first, then bucket
  for hap in hap1 hap2; do
    # find the versioned assembly dir in the bucket
    fa_path="$(rclone lsf "${ASSEMBLY_BUCKET}/${og}" --recursive \
                 --include "*curated.${hap}.chr_level.fa" \
                 ${RCLONE_FLAGS:+$RCLONE_FLAGS} 2>/dev/null | head -1 || true)"
    [[ -n "$fa_path" ]] || { echo "  WARNING: no curated.${hap}.chr_level.fa found"; continue; }

    local_src="${STAGING_BASE_DIR}/${og}_${sp}/assembly/$(basename "$fa_path")"
    move_or_copy "$local_src" "${ASSEMBLY_BUCKET}/${og}/${fa_path}" "$target"

    # assembly_summary.txt in gfastats/ subdir
    # Strip .chr_level suffix: summary file is named without it
    fa_base="$(basename "$fa_path" .fa)"
    asm_base="${fa_base%.chr_level}"
    asm_path="$(rclone lsf "${ASSEMBLY_BUCKET}/${og}" --recursive \
                  --include "${asm_base}.assembly_summary.txt" \
                  ${RCLONE_FLAGS:+$RCLONE_FLAGS} 2>/dev/null \
                | grep -v '/$' | head -1 || true)"
    if [[ -n "$asm_path" ]]; then
      move_or_copy "" "${ASSEMBLY_BUCKET}/${og}/${asm_path}" "$target"
    fi
  done
done

# ---- compile draft OGs -------------------------------------------------
for og in "${!OG_TYPE[@]}"; do
  [[ "${OG_TYPE[$og]}" == "draft" ]] || continue

  sp="$(safe_name "${OG_SPECIES[$og]}")"
  target="${STAGING_BASE_DIR}/${sp}_draft/${og}"
  mkdir -p "$target"

  echo "=== ${og} → ${sp}_draft/${og} ==="

  # .fna assembly
  fna_name="$(rclone lsf "${DRAFT_BUCKET}/${og}/assemblies/genome/" \
                ${RCLONE_FLAGS:+$RCLONE_FLAGS} 2>/dev/null \
              | grep '\.fna$' | head -1 || true)"
  if [[ -n "$fna_name" ]]; then
    local_src="${STAGING_BASE_DIR}/${og}_${sp}/assembly/${fna_name}"
    move_or_copy "$local_src" "${DRAFT_BUCKET}/${og}/assemblies/genome/${fna_name}" "$target"
  else
    echo "  WARNING: no .fna found for ${og}"
  fi

  # R1 / R2 reads from filtered-reads bucket (fastp)
  for rn in R1 R2; do
    read_name="$(rclone lsf "${DRAFT_BUCKET}/${og}/fastp/" \
                   ${RCLONE_FLAGS:+$RCLONE_FLAGS} 2>/dev/null \
                 | grep -E "\.${rn}\.fastq\.gz$" | head -1 || true)"
    [[ -n "$read_name" ]] || read_name="$(rclone lsf "${DRAFT_BUCKET}/${og}/fastp/" \
                   ${RCLONE_FLAGS:+$RCLONE_FLAGS} 2>/dev/null \
                 | grep -E "\.${rn}\.fq\.gz$" | head -1 || true)"
    if [[ -n "$read_name" ]]; then
      local_src="${STAGING_BASE_DIR}/${og}_${sp}/reads/${read_name}"
      move_or_copy "$local_src" "${DRAFT_BUCKET}/${og}/fastp/${read_name}" "$target"
    else
      echo "  WARNING: no ${rn} reads found for ${og}"
    fi
  done
done

# ---- compile hifi_assembly OGs -----------------------------------------
for og in "${!OG_TYPE[@]}"; do
  [[ "${OG_TYPE[$og]}" == "hifi_assembly" ]] || continue

  sp="$(safe_name "${OG_SPECIES[$og]}")"
  target_base="${STAGING_BASE_DIR}/${sp}_hifi_assembly"

  echo "=== ${og} → ${sp}_hifi_assembly ==="

  # Find the versioned assembly subdir in the refassembly bucket
  # Match pattern: {OG}_v{digits}... to avoid matching nested OG dirs
  version_dir="$(rclone lsf "${ASSEMBLY_BUCKET}/${og}/" \
                   ${RCLONE_FLAGS:+$RCLONE_FLAGS} 2>/dev/null \
                 | grep -E "^${og}_v[0-9]+" | grep '/' | head -1 || true)"
  version_dir="${version_dir%/}"

  if [[ -z "$version_dir" ]]; then
    echo "  WARNING: no version subdir found for ${og} in ${ASSEMBLY_BUCKET}"; continue
  fi

  echo "  version dir: ${version_dir}"

  # assembly/ files (.fasta, .gfa)
  mkdir -p "${target_base}/assembly"
  rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} \
    "${ASSEMBLY_BUCKET}/${og}/${version_dir}/assembly/" \
    "${target_base}/assembly/" \
    --include "*.fasta" --include "*.gfa"

  # gfastats/ .txt files
  mkdir -p "${target_base}/gfastats"
  rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} \
    "${ASSEMBLY_BUCKET}/${og}/${version_dir}/gfastats/" \
    "${target_base}/gfastats/" \
    --include "*.txt"

  # hifi BAM files from s3 hifi bucket (each BAM lives in its own subdir)
  mkdir -p "${target_base}/hifi_reads_raw"
  mapfile -t bam_dirs < <(rclone lsf "${HIFI_BUCKET}/${og}/hifi/" \
                             ${RCLONE_FLAGS:+$RCLONE_FLAGS} 2>/dev/null \
                           | grep '\.bam/$' | grep -v 'unassigned' || true)
  for bd in "${bam_dirs[@]}"; do
    bd="${bd%/}"
    bam_name="$bd"
    echo "  rclone copy  ${HIFI_BUCKET}/${og}/hifi/${bd}/${bam_name}"
    rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} \
      "${HIFI_BUCKET}/${og}/hifi/${bd}/${bam_name}" \
      "${target_base}/hifi_reads_raw/"
  done
done

# ---- copy mitogenome files into compiled dirs --------------------------
echo ""
echo "=== Copying mitogenome files ==="

for og in "${!OG_TYPE[@]}"; do
  sp="$(safe_name "${OG_SPECIES[$og]}")"

  mito_src="${STAGING_BASE_DIR}/${og}_${sp}/mitogenome"
  [[ -d "$mito_src" ]] || { echo "  WARNING: no mitogenome staging dir for ${og}, skipping"; continue; }

  case "${OG_TYPE[$og]}" in
    reference)     mito_dest="${STAGING_BASE_DIR}/${sp}_reference/mitogenome" ;;
    draft)         mito_dest="${STAGING_BASE_DIR}/${sp}_draft/${og}/mitogenome" ;;
    hifi_assembly) mito_dest="${STAGING_BASE_DIR}/${sp}_hifi_assembly/mitogenome" ;;
    *) continue ;;
  esac

  for sub in FA GENES GFF; do
    [[ -d "${mito_src}/${sub}" ]] || continue
    mkdir -p "${mito_dest}/${sub}"
    cp -r "${mito_src}/${sub}/." "${mito_dest}/${sub}/"
    echo "  ${og} mitogenome/${sub}/ -> ${mito_dest}/${sub}/"
  done
done

# ---- remove old wrong-structure staging dirs ---------------------------
echo ""
echo "Cleaning up old staging directories..."
for d in "${STAGING_BASE_DIR}"/OG*_*/; do
  [[ -d "$d" ]] || continue
  # only remove if it's one of our per-og dirs (not a species_type dir)
  base="$(basename "$d")"
  if [[ "$base" =~ ^OG[0-9]+_ ]]; then
    echo "  rm -rf ${d}"
    rm -rf "$d"
  fi
done

echo ""
echo "Done. Final package:"
find "${STAGING_BASE_DIR}" -not -path "*/\.*" \
  -not -name "*.csv" \
  \( -type d -o -type f \) \
  | sort \
  | sed "s|${STAGING_BASE_DIR}/||" \
  | head -60

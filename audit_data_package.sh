#!/usr/bin/env bash
# audit_data_package.sh — audit the final compiled data package
# Run after 06_compile_package.sh
# Usage: bash audit_data_package.sh <config_file>
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <config_file>" >&2
    exit 1
fi
source "$1"

expand_user() { echo "${1/\{user\}/$(whoami)}"; }
STAGING_BASE_DIR=$(expand_user "$STAGING_BASE_DIR")

PASS=0; WARN=0; FAIL=0

check_dir_nonempty() {
    local label="$1" dir="$2"
    if [[ ! -d "$dir" ]]; then
        echo "  MISSING dir  : $label"
        (( FAIL++ )) || true
    elif [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
        echo "  EMPTY dir    : $label"
        (( FAIL++ )) || true
    else
        local n; n=$(ls "$dir" | wc -l)
        echo "  OK ($n files) : $label"
        (( PASS++ )) || true
    fi
}

check_pattern() {
    local label="$1" dir="$2" pattern="$3"
    local count
    count=$( { find "$dir" -maxdepth 1 -name "$pattern" 2>/dev/null || true; } | wc -l )
    if [[ "$count" -eq 0 ]]; then
        echo "  MISSING      : $label ($pattern)"
        (( FAIL++ )) || true
    else
        echo "  OK ($count)      : $label ($pattern)"
        (( PASS++ )) || true
    fi
}

check_mito() {
    local dir="$1"
    if [[ ! -d "${dir}/mitogenome/FA" ]]; then
        echo "  MISSING dir  : mitogenome/FA/"
        (( FAIL++ )) || true
    else
        check_dir_nonempty "mitogenome/FA/" "${dir}/mitogenome/FA"
    fi
    for sub in GENES GFF; do
        if [[ -d "${dir}/mitogenome/${sub}" ]]; then
            check_dir_nonempty "mitogenome/${sub}/" "${dir}/mitogenome/${sub}"
        else
            echo "  NOTE         : mitogenome/${sub}/ absent (no annotation)"
            (( WARN++ )) || true
        fi
    done
}

# ---- reference dirs ----
for d in "${STAGING_BASE_DIR}"/*_reference/; do
    [[ -d "$d" ]] || continue
    base="$(basename "$d")"
    echo "========================================"
    echo "$base  [reference]"
    echo "========================================"
    check_pattern "hap1 assembly" "$d" "*hap1*.fa"
    check_pattern "hap2 assembly" "$d" "*hap2*.fa"
    check_pattern "hap1 gfastats" "$d" "*hap1*assembly_summary.txt"
    check_pattern "hap2 gfastats" "$d" "*hap2*assembly_summary.txt"
    check_mito "$d"
    echo
done

# ---- draft dirs ----
for d in "${STAGING_BASE_DIR}"/*_draft/; do
    [[ -d "$d" ]] || continue
    base="$(basename "$d")"
    echo "========================================"
    echo "$base  [draft]"
    echo "========================================"
    for og_dir in "$d"OG*/; do
        [[ -d "$og_dir" ]] || continue
        og="$(basename "$og_dir")"
        echo "  -- $og --"
        check_pattern "${og} assembly" "$og_dir" "*.fna"
        check_pattern "${og} R1 reads" "$og_dir" "*R1*"
        check_pattern "${og} R2 reads" "$og_dir" "*R2*"
        check_mito "$og_dir"
    done
    echo
done

# ---- hifi_assembly dirs ----
for d in "${STAGING_BASE_DIR}"/*_hifi_assembly/; do
    [[ -d "$d" ]] || continue
    base="$(basename "$d")"
    echo "========================================"
    echo "$base  [hifi_assembly]"
    echo "========================================"
    check_dir_nonempty "assembly/"       "${d}assembly"
    check_dir_nonempty "gfastats/"       "${d}gfastats"
    check_dir_nonempty "hifi_reads_raw/" "${d}hifi_reads_raw"
    check_mito "$d"
    echo
done

# ---- top-level metadata ----
echo "========================================"
echo "Top-level metadata"
echo "========================================"

PROJECT_ID="${PROJECT_ID:-}"
OG_ID="${OG_ID:-}"
PACKAGE_NAME="${PACKAGE_NAME:-}"
if [[ -n "$OG_ID" ]]; then
    DATA_ID="${PACKAGE_NAME:-${OG_ID//,/_}}"
elif [[ -n "$PROJECT_ID" ]]; then
    DATA_ID="$PROJECT_ID"
else
    echo "  WARNING: Neither PROJECT_ID nor OG_ID set" >&2
    DATA_ID="*"
fi

for pattern in \
    "refgenomes_assembly_stats_${DATA_ID}_*.csv" \
    "hic_transfer_map_${DATA_ID}_*.csv" \
    "draft_transfer_map_${DATA_ID}_*.csv" \
    "mitogenome_metadata_${DATA_ID}.csv"
do
    count=$(find "${STAGING_BASE_DIR}" -maxdepth 1 -name "$pattern" 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
        echo "  OK           : $pattern"
        (( PASS++ )) || true
    else
        echo "  MISSING      : $pattern"
        (( FAIL++ )) || true
    fi
done

echo
echo "========================================"
printf "SUMMARY:  OK %-4s  WARN %-4s  FAIL %s\n" "$PASS" "$WARN" "$FAIL"
echo "========================================"

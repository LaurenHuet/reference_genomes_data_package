#!/usr/bin/env bash
set -euo pipefail

# run_all.sh — end-to-end data package pipeline
#
# Usage:
#   bash run_all.sh [config.conf] [--skip-db] [--skip-mito] [--dry-run]
#
# Flags:
#   --skip-db     Skip step 0 (DB query / transfer map generation)
#   --skip-mito   Skip step 04 (mitogenome pipeline)
#   --dry-run     Pass --dry-run to all rclone calls (sets RCLONE_FLAGS)
#
# Steps 01–05 (HiC, HiFi, assemblies, mito, drafts) run in parallel.
# Steps 06 (compile), audit, and 07 (package + backup) run sequentially after.
#
# Logs: logs/{step}_{YYYYMMDD_HHMMSS}.log

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/refgenomes_data_package.conf"
SKIP_DB=false
SKIP_MITO=false

for arg in "$@"; do
  case "$arg" in
    --skip-db)   SKIP_DB=true ;;
    --skip-mito) SKIP_MITO=true ;;
    --dry-run)   export RCLONE_FLAGS="${RCLONE_FLAGS:+$RCLONE_FLAGS }--dry-run" ;;
    *.conf)      CONFIG="$arg" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 1; }

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)

echo "=== Data Package Pipeline ==="
echo "Config : $CONFIG"
echo "Logs   : $LOG_DIR"
echo ""

# ── Step 0: generate transfer maps ─────────────────────────────────────────
if [[ "$SKIP_DB" == false ]]; then
  echo "[0/3] Generating transfer maps from database..."
  SING="${SING:-/software/projects/pawsey0964/singularity}"
  singularity run "$SING/psycopg2:0.1.sif" python \
    "$SCRIPT_DIR/pull_genome_statistics_by_project.py" "$CONFIG" \
    2>&1 | tee "$LOG_DIR/step0_db_${STAMP}.log"
  echo ""
else
  echo "[0/3] Skipping DB step (--skip-db)"
fi

# ── Steps 01–05: parallel staging ──────────────────────────────────────────
echo "[1/3] Starting parallel staging (steps 01–05)..."
echo ""

bash "$SCRIPT_DIR/01_get_hic_from_config.sh"    "$CONFIG" \
  2>&1 | tee "$LOG_DIR/step01_hic_${STAMP}.log" &
PID_HIC=$!

bash "$SCRIPT_DIR/02_get_hifi_from_config.sh"   "$CONFIG" \
  2>&1 | tee "$LOG_DIR/step02_hifi_${STAMP}.log" &
PID_HIFI=$!

bash "$SCRIPT_DIR/03_get_assembly_from_config.sh" "$CONFIG" \
  2>&1 | tee "$LOG_DIR/step03_assembly_${STAMP}.log" &
PID_ASM=$!

bash "$SCRIPT_DIR/05_get_draft_from_config.sh"  "$CONFIG" \
  2>&1 | tee "$LOG_DIR/step05_draft_${STAMP}.log" &
PID_DRAFT=$!

if [[ "$SKIP_MITO" == false ]]; then
  bash "$SCRIPT_DIR/04_get_mito_from_config.sh" "$CONFIG" \
    2>&1 | tee "$LOG_DIR/step04_mito_${STAMP}.log" &
  PID_MITO=$!
  echo "  HiC       PID $PID_HIC    → $LOG_DIR/step01_hic_${STAMP}.log"
  echo "  HiFi      PID $PID_HIFI   → $LOG_DIR/step02_hifi_${STAMP}.log"
  echo "  Assembly  PID $PID_ASM    → $LOG_DIR/step03_assembly_${STAMP}.log"
  echo "  Mito      PID $PID_MITO   → $LOG_DIR/step04_mito_${STAMP}.log"
  echo "  Draft     PID $PID_DRAFT  → $LOG_DIR/step05_draft_${STAMP}.log"
else
  echo "  HiC       PID $PID_HIC    → $LOG_DIR/step01_hic_${STAMP}.log"
  echo "  HiFi      PID $PID_HIFI   → $LOG_DIR/step02_hifi_${STAMP}.log"
  echo "  Assembly  PID $PID_ASM    → $LOG_DIR/step03_assembly_${STAMP}.log"
  echo "  Draft     PID $PID_DRAFT  → $LOG_DIR/step05_draft_${STAMP}.log"
  echo "  Mito      skipped (--skip-mito)"
fi
echo ""
echo "  Monitor: tail -f $LOG_DIR/*_${STAMP}.log"
echo ""

EXIT=0
wait $PID_HIC   && echo "[OK] HiC"      || { echo "[FAIL] HiC      — $LOG_DIR/step01_hic_${STAMP}.log";      EXIT=1; }
wait $PID_HIFI  && echo "[OK] HiFi"     || { echo "[FAIL] HiFi     — $LOG_DIR/step02_hifi_${STAMP}.log";     EXIT=1; }
wait $PID_ASM   && echo "[OK] Assembly" || { echo "[FAIL] Assembly — $LOG_DIR/step03_assembly_${STAMP}.log"; EXIT=1; }
wait $PID_DRAFT && echo "[OK] Draft"    || { echo "[FAIL] Draft    — $LOG_DIR/step05_draft_${STAMP}.log";    EXIT=1; }
if [[ "$SKIP_MITO" == false ]]; then
  wait $PID_MITO && echo "[OK] Mito"    || { echo "[FAIL] Mito     — $LOG_DIR/step04_mito_${STAMP}.log";    EXIT=1; }
fi

if [[ $EXIT -ne 0 ]]; then
  echo ""
  echo "Staging failed — fix errors above before continuing."
  exit 1
fi

echo ""

# ── Step 06: compile ────────────────────────────────────────────────────────
echo "[2/3] Compiling final package (step 06)..."
bash "$SCRIPT_DIR/06_compile_package.sh" "$CONFIG" \
  2>&1 | tee "$LOG_DIR/step06_compile_${STAMP}.log"
echo ""

# ── Audit ───────────────────────────────────────────────────────────────────
echo "Auditing compiled package..."
bash "$SCRIPT_DIR/audit_data_package.sh" "$CONFIG" \
  2>&1 | tee "$LOG_DIR/audit_${STAMP}.log"

if grep -q "FAIL" "$LOG_DIR/audit_${STAMP}.log"; then
  echo ""
  echo "Audit found failures — check $LOG_DIR/audit_${STAMP}.log before backing up."
  exit 1
fi
echo ""

# ── Step 07: package and backup ─────────────────────────────────────────────
echo "[3/3] Packaging and backing up (step 07)..."
bash "$SCRIPT_DIR/07_package_and_backup.sh" "$CONFIG" \
  2>&1 | tee "$LOG_DIR/step07_backup_${STAMP}.log"

echo ""
echo "=== Pipeline complete. All logs in $LOG_DIR ==="

#!/usr/bin/env bash
set -euo pipefail

# 07_package_and_backup.sh
#
# 1. Copies the compiled package to DATAPACKS_BUCKET/{DATA_ID}/
# 2. Lists DATAPACKS_BUCKET/{DATA_ID}/ and saves as {DATA_ID}_returned_{YYMMDD}.txt
# 3. Zips the local staging directory
# 4. Uploads the zip to DATAPACKS_ZIPPED_BUCKET/
#
# Usage:
#   bash 07_package_and_backup.sh refgenomes_data_package.conf

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

STAGING_BASE_DIR="$(expand_user "${STAGING_BASE_DIR:?Missing STAGING_BASE_DIR}")"
DATAPACKS_BUCKET="${DATAPACKS_BUCKET:-pawsey0964:oceanomics-datapacks}"
DATAPACKS_ZIPPED_BUCKET="${DATAPACKS_ZIPPED_BUCKET:-pawsey0964:oceanomics-datapacks-zipped}"
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

[[ -d "$STAGING_BASE_DIR" ]] || { echo "STAGING_BASE_DIR not found: $STAGING_BASE_DIR" >&2; exit 1; }

DATE="$(date +%y%m%d)"
LABEL="${DATA_ID}_returned_${DATE}"
LISTING="${STAGING_BASE_DIR}/${LABEL}.txt"
ZIPFILE="$(dirname "$STAGING_BASE_DIR")/${LABEL}.zip"

# ---- copy compiled package to datapacks bucket --------------------------
echo "Copying compiled package to ${DATAPACKS_BUCKET}/${DATA_ID}/"
rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} \
  "$STAGING_BASE_DIR" \
  "${DATAPACKS_BUCKET}/${DATA_ID}/" \
  --exclude "*.zip"
echo ""

# ---- generate file listing from remote ----------------------------------
echo "Generating file listing: $LISTING"
rclone lsf "${DATAPACKS_BUCKET}/${DATA_ID}/" \
  --recursive \
  ${RCLONE_FLAGS:+$RCLONE_FLAGS} \
  > "$LISTING"
echo "  $(wc -l < "$LISTING") files listed"
echo ""

# ---- zip local staging dir ----------------------------------------------
echo "Compressing: $ZIPFILE"
(
  cd "$(dirname "$STAGING_BASE_DIR")"
  zip -r "$ZIPFILE" "$(basename "$STAGING_BASE_DIR")" \
    --exclude "*.zip"
)
echo "  size: $(du -sh "$ZIPFILE" | cut -f1)"
echo ""

# ---- upload zip to datapacks-zipped -------------------------------------
echo "Uploading zip to ${DATAPACKS_ZIPPED_BUCKET}/"
rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} \
  "$ZIPFILE" \
  "${DATAPACKS_ZIPPED_BUCKET}/"
echo ""
echo "Done:"
echo "  remote  : ${DATAPACKS_BUCKET}/${DATA_ID}/"
echo "  listing : $LISTING"
echo "  zip     : ${DATAPACKS_ZIPPED_BUCKET}/$(basename "$ZIPFILE")"

#!/usr/bin/env bash
set -Eeuo pipefail
: "${IDEMPIERE_HOME:?IDEMPIERE_HOME no está definido}"
DATA_DIR="${IDEMPIERE_HOME}/data"
SOURCE="$DATA_DIR/ExpDat.tar.7z"
DATE="$(date +%Y%m%d_%H%M%S)"
DEST="$DATA_DIR/ExpDat${DATE}.tar.7z"
if [[ ! -f "$SOURCE" ]]; then
    echo "No existe el archivo $SOURCE" >&2
    exit 1
fi
mv -- "$SOURCE" "$DEST"
echo "Archivo preparado: $DEST"

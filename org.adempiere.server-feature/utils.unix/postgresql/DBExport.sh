#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
if (( $# < 2 )); then
    echo "Uso: $0 <usuario_db> <password_db>" >&2
    exit 1
fi
: "${IDEMPIERE_HOME:?IDEMPIERE_HOME no está definido}"
: "${ADEMPIERE_DB_NAME:?}"
: "${ADEMPIERE_DB_SERVER:?}"
: "${ADEMPIERE_DB_PORT:?}"
COMPRESSOR="$(command -v 7za || command -v 7z)" || { echo "Se requiere 7za o 7z" >&2; exit 1; }
DB_USER="$1"
DB_PASSWORD="$2"
DATA_DIR="${IDEMPIERE_HOME}/data"
FINAL_ARCHIVE="$DATA_DIR/ExpDat.tar.7z"
TMP_DIR="$(mktemp -d "$DATA_DIR/.dbexport.XXXXXX")"
DUMP_FILE="$TMP_DIR/ExpDat.dmp"
ARCHIVE_FILE="$TMP_DIR/ExpDat.tar.7z"
cleanup() {
    local rc=$?
    rm -rf -- "$TMP_DIR"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
if [[ -e "$FINAL_ARCHIVE" ]]; then
    echo "Ya existe un archivo pendiente: $FINAL_ARCHIVE" >&2
    exit 1
fi
echo "Exportando $ADEMPIERE_DB_NAME desde $ADEMPIERE_DB_SERVER"
PGPASSWORD="$DB_PASSWORD" pg_dump -w -h "$ADEMPIERE_DB_SERVER" \
    -p "$ADEMPIERE_DB_PORT" --no-owner -U "$DB_USER" "$ADEMPIERE_DB_NAME" > "$DUMP_FILE"
echo "Comprimiendo ExpDat.dmp en tar.7z"
tar -cf - -C "$TMP_DIR" ExpDat.dmp |
    "$COMPRESSOR" a -si -mx=4 -mmt=2 "$ARCHIVE_FILE"
mv -- "$ARCHIVE_FILE" "$FINAL_ARCHIVE"
chmod 0640 "$FINAL_ARCHIVE"
echo "Archivo generado: $FINAL_ARCHIVE"

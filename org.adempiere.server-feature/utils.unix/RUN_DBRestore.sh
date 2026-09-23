#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
: "${IDEMPIERE_HOME:?IDEMPIERE_HOME no está definido}"
cd "${IDEMPIERE_HOME}/utils"
set +u
export ID_ENV=Server
. ./myEnvironment.sh
set -u
DATA_DIR="${IDEMPIERE_HOME}/data"
DUMP="$DATA_DIR/ExpDat.dmp"
ARCHIVE=""
# PostgreSQL: newest modification time, descending name on ties.
if [[ "${ADEMPIERE_DB_PATH##*/}" == postgresql ]]; then
    shopt -s nullglob
    for candidate in "$DATA_DIR"/ExpDat*.tar.7z; do
        [[ -f "$candidate" && ! -L "$candidate" ]] || continue
        if [[ -z "$ARCHIVE" || "$candidate" -nt "$ARCHIVE" ]] ||
           { [[ ! "$ARCHIVE" -nt "$candidate" ]] && [[ "$candidate" > "$ARCHIVE" ]]; }; then
            ARCHIVE="$candidate"
        fi
    done
fi
if [[ -z "$ARCHIVE" && ! -s "$DUMP" ]]; then
    echo "No existe un backup disponible en $DATA_DIR" >&2
    exit 1
fi
echo "Restaurar $ADEMPIERE_DB_NAME desde ${ARCHIVE:-$DUMP}"
echo "Se recreará la base de datos. Presione Enter para continuar."
read -r _
if [[ -n "$ARCHIVE" ]]; then
    COMPRESSOR="$(command -v 7za || command -v 7z)" || { echo "Se requiere 7za o 7z" >&2; exit 1; }
    TMP_DIR="$(mktemp -d "$DATA_DIR/.dbrestore.XXXXXX")"
    cleanup() {
        local rc=$?
        rm -rf -- "$TMP_DIR"
        exit "$rc"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM
    # Extract only the dump, without accepting paths from the archive.
    "$COMPRESSOR" x -so "$ARCHIVE" |
        tar -xOf - -- ExpDat.dmp > "$TMP_DIR/ExpDat.dmp"
    [[ -s "$TMP_DIR/ExpDat.dmp" ]] || { echo "Dump vacío" >&2; exit 1; }
    chmod 0640 "$TMP_DIR/ExpDat.dmp"
    mv -- "$TMP_DIR/ExpDat.dmp" "$DUMP"
fi
if [[ -z "${ADEMPIERE_DB_SYSTEM_USER:-}" ]]; then
    if [[ "${ADEMPIERE_DB_PATH##*/}" == postgresql ]]; then
        ADEMPIERE_DB_SYSTEM_USER=postgres
    else
        ADEMPIERE_DB_SYSTEM_USER=SYSTEM
    fi
fi
bash "$ADEMPIERE_DB_PATH/DBRestore.sh" "$ADEMPIERE_DB_USER" \
    "$ADEMPIERE_DB_PASSWORD" "$ADEMPIERE_DB_SYSTEM_USER" "$ADEMPIERE_DB_SYSTEM"

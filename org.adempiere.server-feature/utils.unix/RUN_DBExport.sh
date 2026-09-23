#!/usr/bin/env bash
set -Eeuo pipefail
: "${IDEMPIERE_HOME:?IDEMPIERE_HOME no está definido}"
cd "${IDEMPIERE_HOME}/utils"
set +u
export ID_ENV=Server
. ./myEnvironment.sh
set -u
echo "Export de iDempiere - ${IDEMPIERE_HOME} ($ADEMPIERE_DB_NAME)"
bash "$ADEMPIERE_DB_PATH/DBExport.sh" "$ADEMPIERE_DB_USER" "$ADEMPIERE_DB_PASSWORD"
bash "${IDEMPIERE_HOME}/utils/myDBcopy.sh"

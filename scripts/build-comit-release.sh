#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

VERSION="${IDEMPIERE_RELEASE_VERSION:-13}"
DATE="${IDEMPIERE_RELEASE_DATE:-$(date +%Y%m%d)}"
SHORT_COMMIT="$(git rev-parse --short=10 HEAD)"
FULL_COMMIT="$(git rev-parse HEAD)"
PRODUCT_DIR="org.idempiere.p2/target/products/org.adempiere.server.product/linux/gtk/x86_64"
OUTPUT_DIR="${IDEMPIERE_RELEASE_OUTPUT_DIR:-$REPO_ROOT/release-artifacts}"
ARCHIVE="$OUTPUT_DIR/idempiere-server-v${VERSION}-${SHORT_COMMIT}-${DATE}.tar.gz"
CHECKSUM="$ARCHIVE.sha256"
MANIFEST="$ARCHIVE.manifest"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

command -v mvn >/dev/null 2>&1 || die 'mvn no está disponible.'
command -v tar >/dev/null 2>&1 || die 'tar no está disponible.'

printf '[INFO] Compilando con mvn -q verify\n'
mvn -q verify

[[ -d "$PRODUCT_DIR" ]] || die "No existe el producto: $PRODUCT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -f "$ARCHIVE" "$CHECKSUM" "$MANIFEST"

printf '[INFO] Empaquetando %s como idempiere-server\n' "$PRODUCT_DIR"
tar -C "$(dirname "$PRODUCT_DIR")" \
  --transform='s,^x86_64,idempiere-server,' \
  -czf "$ARCHIVE" \
  x86_64

(cd "$OUTPUT_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")")
cat > "$MANIFEST" <<EOF
artifact=$(basename "$ARCHIVE")
commit=$FULL_COMMIT
branch=$(git branch --show-current)
version=$VERSION
date=$DATE
sha256=$(cut -d' ' -f1 "$CHECKSUM")
source_product=$PRODUCT_DIR
EOF

printf '[INFO] Artefacto: %s\n' "$ARCHIVE"
printf '[INFO] Checksum:  %s\n' "$CHECKSUM"
printf '[INFO] Manifiesto: %s\n' "$MANIFEST"

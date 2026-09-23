#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

REPOSITORY="${GITHUB_REPOSITORY:-comitsrl/idempiere}"
VERSION="13"
ARTIFACT=""
RELEASE_TAG=""
PUBLISH=0
CHECK_ONLY=0

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

usage() {
  cat <<'EOF'
Uso:
  scripts/publish-comit-release.sh --artifact release-artifacts/<archivo>.tar.gz
  scripts/publish-comit-release.sh --artifact <archivo> --publish

Por defecto crea o actualiza el GitHub Release como borrador.
--publish lo hace público después de validar y cargar los assets.
--check-only valida el artefacto sin hacer push ni modificar GitHub.
EOF
}

manifest_value() {
  local key="$1"
  awk -F= -v wanted="$key" '$1 == wanted {print substr($0, index($0, "=") + 1); exit}' "$MANIFEST"
}

while (( $# > 0 )); do
  case "$1" in
    --artifact)
      (( $# >= 2 )) || die '--artifact requiere una ruta.'
      ARTIFACT="$2"
      shift 2
      ;;
    --version)
      (( $# >= 2 )) || die '--version requiere un valor.'
      VERSION="$2"
      shift 2
      ;;
    --tag)
      (( $# >= 2 )) || die '--tag requiere un nombre.'
      RELEASE_TAG="$2"
      shift 2
      ;;
    --publish)
      PUBLISH=1
      shift
      ;;
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Opción desconocida: $1"
      ;;
  esac
done

[[ -n "$ARTIFACT" ]] || { usage; die 'Debe indicarse --artifact.'; }
[[ -f "$ARTIFACT" ]] || die "No existe el artefacto: $ARTIFACT"

MANIFEST="$ARTIFACT.manifest"
CHECKSUM="$ARTIFACT.sha256"
[[ -f "$MANIFEST" ]] || die "No existe el manifiesto: $MANIFEST"
[[ -f "$CHECKSUM" ]] || die "No existe el checksum: $CHECKSUM"

command -v gh >/dev/null 2>&1 || die 'gh no está disponible.'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum no está disponible.'
command -v tar >/dev/null 2>&1 || die 'tar no está disponible.'

gh auth status >/dev/null 2>&1 || die 'gh no está autenticado.'
[[ -z "$(git status --porcelain=v1 --untracked-files=no)" ]] || \
  die 'Hay cambios tracked sin commit.'

MANIFEST_COMMIT="$(manifest_value commit)"
MANIFEST_BRANCH="$(manifest_value branch)"
MANIFEST_VERSION="$(manifest_value version)"
MANIFEST_DATE="$(manifest_value date)"
ARTIFACT_NAME="$(manifest_value artifact)"

[[ -n "$MANIFEST_COMMIT" && -n "$MANIFEST_BRANCH" ]] || die 'Manifiesto incompleto.'
[[ "$(basename "$ARTIFACT")" == "$ARTIFACT_NAME" ]] || die 'El manifiesto no corresponde al artefacto.'
[[ "$(git rev-parse HEAD)" == "$MANIFEST_COMMIT" ]] || \
  die "El HEAD actual no coincide con el commit del artefacto: $MANIFEST_COMMIT"
[[ "$MANIFEST_VERSION" == "$VERSION" ]] || \
  die "La versión solicitada ($VERSION) no coincide con el manifiesto ($MANIFEST_VERSION)."

(cd "$(dirname "$CHECKSUM")" && sha256sum -c "$(basename "$CHECKSUM")" >/dev/null) || \
  die 'El checksum del artefacto no coincide.'

ROOTS="$(tar -tzf "$ARTIFACT" | awk -F/ 'NF > 0 {print $1; next}' | sort -u)"
[[ "$ROOTS" == 'idempiere-server' ]] || \
  die "La raíz del artefacto no es idempiere-server: $ROOTS"

SHORT_COMMIT="$(git rev-parse --short=10 HEAD)"
RELEASE_TAG="${RELEASE_TAG:-comit-v${VERSION}-${SHORT_COMMIT}-${MANIFEST_DATE}}"

info "Publicando $ARTIFACT_NAME desde $MANIFEST_COMMIT"
info "Rama: $MANIFEST_BRANCH"
info "Tag: $RELEASE_TAG"

if (( CHECK_ONLY == 1 )); then
  info 'Validación local completada; no se ejecutará ninguna operación remota.'
  exit 0
fi

git push origin "$MANIFEST_BRANCH"

while IFS='|' read -r name ref branches; do
  [[ -n "${name//[[:space:]]/}" ]] || continue
  [[ "$name" == \#* ]] && continue
  git rev-parse "${ref}^{commit}" >/dev/null 2>&1 || \
    die "No existe la personalización $name: $ref"
  info "Publicando referencia de personalización: $ref"
  git push origin "$ref"
done < COMIT_CUSTOMIZATIONS.conf

if git rev-parse "${RELEASE_TAG}^{commit}" >/dev/null 2>&1; then
  [[ "$(git rev-parse "${RELEASE_TAG}^{commit}")" == "$MANIFEST_COMMIT" ]] || \
    die "El tag existente $RELEASE_TAG no apunta al commit del artefacto."
else
  git tag -a "$RELEASE_TAG" -m "iDempiere v${VERSION} ${MANIFEST_DATE}" "$MANIFEST_COMMIT"
fi

git push origin "$RELEASE_TAG"

TITLE="iDempiere v${VERSION} - ${MANIFEST_DATE}"
NOTES="Build generado desde el commit ${MANIFEST_COMMIT}. Incluye compresión de backups PostgreSQL como tar.7z y empaquetado instalable con raíz idempiere-server."

if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  info "Actualizando GitHub Release existente"
  gh release upload "$RELEASE_TAG" \
    "$ARTIFACT" "$CHECKSUM" "$MANIFEST" \
    --repo "$REPOSITORY" --clobber
  gh release edit "$RELEASE_TAG" \
    --repo "$REPOSITORY" \
    --title "$TITLE" \
    --notes "$NOTES"
else
  info "Creando GitHub Release como borrador"
  gh release create "$RELEASE_TAG" \
    "$ARTIFACT" "$CHECKSUM" "$MANIFEST" \
    --repo "$REPOSITORY" \
    --title "$TITLE" \
    --notes "$NOTES" \
    --draft
fi

if (( PUBLISH == 1 )); then
  info "Publicando GitHub Release"
  gh release edit "$RELEASE_TAG" --repo "$REPOSITORY" --draft=false
else
  info "Release dejado como borrador. Usar --publish después de revisarlo."
fi

gh release view "$RELEASE_TAG" --repo "$REPOSITORY" \
  --json tagName,isDraft,url

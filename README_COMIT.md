# Procedimiento de releases de iDempiere de Comit SRL

Este documento describe las personalizaciones mantenidas por Comit SRL sobre el fork de iDempiere y el procedimiento para actualizar, compilar, empaquetar y publicar releases.

## Estructura

- `update-repo.sh`: sincroniza el fork con `upstream` y puede reaplicar las personalizaciones.
- `COMIT_CUSTOMIZATIONS.conf`: inventario ordenado de personalizaciones y sus referencias Git.
- `scripts/build-comit-release.sh`: ejecuta el build y genera el artefacto instalable.
- `scripts/publish-comit-release.sh`: valida y publica el artefacto como GitHub Release.
- `org.adempiere.server-feature/utils.unix/`: fuente de los scripts que terminan dentro del producto compilado.

No se editan archivos bajo `target/`: son resultados generados por Maven/Tycho.

## Personalización de backups

El export PostgreSQL genera temporalmente `ExpDat.dmp`, lo comprime y luego elimina el archivo sin comprimir. `RUN_DBRestore.sh` selecciona y descomprime el `ExpDat*.tar.7z` más reciente antes de invocar `DBRestore.sh`.

Además genera el backup comprimido con este flujo:

```text
ExpDat.dmp -> tar -> 7z -> ExpDat.tar.7z
```

Después `myDBcopy.sh` mueve el archivo a:

```text
ExpDatYYYYMMDD_HHMMSS.tar.7z
```

El servidor debe tener instalados `tar` y `7z`. El archivo `.dmp` no se elimina durante el export.

## Build y empaquetado

Desde la raíz del repositorio:

```bash
./scripts/build-comit-release.sh
```

El script ejecuta `mvn -q verify`, toma el producto Linux desde:

```text
org.idempiere.p2/target/products/org.adempiere.server.product/linux/gtk/x86_64
```

y lo empaqueta con esta raíz:

```text
idempiere-server/
```

Los archivos generados quedan en `release-artifacts/`:

- `idempiere-server-v<version>-<commit>-<fecha>.tar.gz`
- checksum `.sha256`
- manifiesto `.manifest`

El artefacto no se agrega al repositorio Git; se publica como asset del GitHub Release.

## Publicación automatizada

Después de compilar y validar el artefacto, crear el GitHub Release como borrador:

```bash
./scripts/publish-comit-release.sh \
  --artifact release-artifacts/idempiere-server-v13-<commit>-<fecha>.tar.gz
```

Para probar todas las validaciones sin hacer `push` ni modificar GitHub:

```bash
./scripts/publish-comit-release.sh \
  --artifact release-artifacts/idempiere-server-v13-<commit>-<fecha>.tar.gz \
  --check-only
```

El script valida el manifiesto, commit, checksum y raíz `idempiere-server`; publica la rama y los tags de personalizaciones; crea el tag de release; y carga el artefacto, checksum y manifiesto en GitHub.

Revisar el borrador en GitHub y publicarlo explícitamente:

```bash
./scripts/publish-comit-release.sh \
  --artifact release-artifacts/idempiere-server-v13-<commit>-<fecha>.tar.gz \
  --publish
```

El script es idempotente para el mismo tag: si el release ya existe, actualiza sus assets con `--clobber` después de validar el checksum.

## Publicación manual

Validar primero el contenido y checksum. Luego crear un tag sobre el commit compilado y publicar el artefacto:

```bash
git tag -a comit-v13-<commit>-<fecha> -m "iDempiere v13 <fecha>"
git push origin comit-v13-<commit>-<fecha>
gh release create comit-v13-<commit>-<fecha> \
  release-artifacts/idempiere-server-v13-<commit>-<fecha>.tar.gz \
  release-artifacts/idempiere-server-v13-<commit>-<fecha>.tar.gz.sha256 \
  --title "iDempiere v13 - <fecha>"
```

No se utilizan workflows de GitHub para esta publicación.

## Actualizar desde upstream

Para una nueva rama, por ejemplo `release-14`, ejecutar:

```bash
./update-repo.sh --target release-14 --apply-comit --no-push
```

El script:

1. obtiene las ramas de `upstream` y `origin`;
2. prepara la rama destino desde `upstream`;
3. lee `COMIT_CUSTOMIZATIONS.conf`;
4. aplica los tags de personalizaciones en el orden declarado;
5. omite personalizaciones ya aplicadas;
6. se detiene si aparece un conflicto;
7. no modifica el remoto porque se utilizó `--no-push`.

Si la rama local ya contiene personalizaciones y upstream avanzó, `update-repo.sh` integra upstream mediante merge, conservando los commits publicados. Captura el inventario antes de cambiar de rama y omite tanto commits presentes como parches equivalentes ya aplicados por cherry-pick o rebase. Después publica la rama integrada.

Si hay conflicto:

```bash
git status
# resolver los archivos afectados
git add <archivos-resueltos>
git cherry-pick --continue
```

Si el conflicto ocurrió durante el merge de upstream, completar con
`git merge --continue` y volver a ejecutar el script.

Después deben ejecutarse las pruebas de backup y el build completo.

Cuando la rama local ya fue revisada y validada, publicar la rama integrada:

```bash
./update-repo.sh --target release-14 --apply-comit
```

Sin `--no-push`, el script actualiza `origin` y publica la rama integrada.

## Referencias de personalizaciones

Cada entrada de `COMIT_CUSTOMIZATIONS.conf` apunta a un tag Git inmutable, por ejemplo:

```text
backup-restore|comit/custom/backup-restore|release-13,release-14
```

Los tags se crean en el fork cuando los cambios quedan aprobados. Así no es necesario recordar hashes para actualizar una versión futura.

Las personalizaciones deben conservarse en commits separados:

1. backup y restore, incluyendo compresión, limpieza del `.dmp` y extracción;
2. build y empaquetado;
3. documentación y actualización automática;
4. publicación del release.

## Validaciones mínimas

Antes de publicar:

- comprobar la raíz `idempiere-server/` del tarball;
- verificar permisos ejecutables;
- comprobar el checksum;
- ejecutar el setup y arranque del servidor;
- probar exportación PostgreSQL;
- verificar el backup comprimido y la ausencia de temporales al finalizar el export;
- verificar restauración con el procedimiento existente;
- registrar commit, versión y checksum en el release.

## Operación de backups PostgreSQL

Los scripts del core incorporan el procedimiento de producción: Bash con
`set -Eeuo pipefail`, `pg_dump -w`, `umask 027`, compresión
`-mx=4 -mmt=2` y archivo final con permisos `0640`. Se prefiere `7za`;
si no está disponible se utiliza `7z`. Las llamadas se realizan con Bash.
Un fallo del export detiene la secuencia antes de renombrar el backup.

El dump se genera dentro de `data/.dbexport.XXXXXX`. El trap elimina ese
directorio y el dump al terminar, también ante errores y señales INT/HUP/TERM.
No puede hacerlo ante SIGKILL o un apagado abrupto: esos restos requieren
revisión manual. No se borran dumps anteriores ajenos a la ejecución.
Si existe `data/ExpDat.tar.7z`, el export aborta para conservar el pendiente.
Ejecutar una sola exportación por instalación a la vez, como en el procedimiento
de producción. La rotación produce `ExpDatYYYYMMDD_HHMMSS.tar.7z` sin esperas.

El restore PostgreSQL elige el archivo regular `ExpDat*.tar.7z` más reciente
por fecha de modificación; ante empate, el nombre mayor en orden descendente.
Muestra el archivo elegido y solicita confirmación. Extrae solo `ExpDat.dmp`
en un temporal; si falla o el dump está vacío, no invoca PostgreSQL.
El dump validado se instala con permisos `0640`. Se conservan el comprimido
y el dump restaurado. Si no hay comprimidos, se admite un `ExpDat.dmp` existente.
La restauración recrea la base de datos: probarla primero en un entorno aislado.

En instalaciones existentes, actualizar también `utils/myDBcopy.sh` desde
`utils/myDBcopyTemplate.sh`, revisando antes cualquier adaptación local.
La plantilla actualizada por sí sola no reemplaza necesariamente el script instalado.

El checksum del instalable contiene solo el nombre del archivo. Para verificarlo
después de descargarlo, situarse en el directorio que contiene el TAR.GZ y ejecutar
`sha256sum -c <archivo>.tar.gz.sha256`.

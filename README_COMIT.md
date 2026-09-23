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

El servidor debe tener instalados `tar` y `7za` o `7z`.

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
- verificar el backup comprimido y la eliminación de `ExpDat.dmp` al finalizar el export;
- verificar restauración con el procedimiento existente;
- registrar commit, versión y checksum en el release.

## Operación de backups PostgreSQL

Los cambios sobre los scripts del core son mínimos: el arranque, la carga de
`myEnvironment.sh` y el resto del flujo se mantienen como en iDempiere.
`RUN_DBExport.sh` no se modifica.

En `postgresql/DBExport.sh` se aplica `umask 027` antes de `pg_dump`, de modo
que el dump y el comprimido se crean sin acceso para otros usuarios (`0640`).
En lugar de `jar`, el dump se comprime con `tar` y `7za` (o `7z` si `7za` no
está disponible) usando `-mx=4 -mmt=2`. Se reemplaza cualquier
`ExpDat.tar.7z` previo y `ExpDat.dmp` se elimina solo si la compresión termina
correctamente.

`RUN_DBRestore.sh` elige el `ExpDat*.tar.7z` más reciente por fecha de
modificación y extrae solo `ExpDat.dmp` en `data/`, con `umask 027`. Si la
extracción falla, no invoca PostgreSQL. Si no hay comprimidos, se usa el
`ExpDat.dmp` existente, como en iDempiere. El comprimido se conserva.
La restauración recrea la base de datos: probarla primero en un entorno aislado.

En instalaciones existentes, actualizar también `utils/myDBcopy.sh` desde
`utils/myDBcopyTemplate.sh`, revisando antes cualquier adaptación local.
La plantilla actualizada por sí sola no reemplaza necesariamente el script instalado.

El checksum del instalable contiene solo el nombre del archivo. Para verificarlo
después de descargarlo, situarse en el directorio que contiene el TAR.GZ y ejecutar
`sha256sum -c <archivo>.tar.gz.sha256`.

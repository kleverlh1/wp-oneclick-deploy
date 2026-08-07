#!/usr/bin/env bash
#
# publish.sh — publica wordpress-stack.yaml y bootstrap.sh en S3 y genera la
#              URL del boton "Launch Stack".
#
# Por que existe: hoy el template apunta a raw.githubusercontent.com/.../main/.
# Esa rama es MUTABLE. Si renombras el repo, lo pasas a privado, o comiteas a
# medias, se rompe el despliegue de un cliente que este lanzando en ese momento
# y no te enteras. S3 versionado congela cada release.
#
# Uso (desde la raiz del repo):
#   ./scripts/publish.sh --dry-run
#   ./scripts/publish.sh
#   ./scripts/publish.sh --version v1.0.0 --region us-east-1

set -euo pipefail

REGION="${REGION:-us-east-1}"
BUCKET="${BUCKET:-}"
VERSION="${VERSION:-}"
DRY_RUN="false"

TEMPLATE_SRC="cloudformation/wordpress-stack.yaml"
BOOTSTRAP_SRC="scripts/bootstrap.sh"
BUILD_DIR=".build"

c_ok()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[0;33m%s\033[0m\n' "$*"; }
log()    { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
die()    { printf '\033[0;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '\033[0;90m[dry-run] %s\033[0m\n' "$*"
  else
    "$@"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bucket)  BUCKET="$2";  shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "argumento desconocido: $1" ;;
  esac
done

[ -f "$TEMPLATE_SRC" ]  || die "no encuentro $TEMPLATE_SRC — corre esto desde la raiz del repo"
[ -f "$BOOTSTRAP_SRC" ] || die "no encuentro $BOOTSTRAP_SRC — corre esto desde la raiz del repo"

if [ "$DRY_RUN" = "true" ]; then
  ACCOUNT_ID="${ACCOUNT_ID:-000000000000}"
else
  command -v aws >/dev/null 2>&1 || die "falta el AWS CLI"
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
    || die "no pude autenticar contra AWS — revisa 'aws configure'"
fi

BUCKET="${BUCKET:-wp-oneclick-deploy-${ACCOUNT_ID}}"

if [ -z "$VERSION" ]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    VERSION="$(git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD)"
  else
    VERSION="$(date -u +%Y%m%d-%H%M%S)"
  fi
fi
case "$VERSION" in *dirty*) c_warn "OJO: hay cambios sin commitear — publicando como '$VERSION'";; esac

log "Cuenta $ACCOUNT_ID | bucket $BUCKET ($REGION) | version $VERSION"

# ------------------------------------------------------- 1. validacion local
log "Validando bootstrap.sh..."
bash -n "$BOOTSTRAP_SRC" || die "bootstrap.sh tiene un error de sintaxis"
command -v shellcheck >/dev/null 2>&1 \
  && { shellcheck -S error "$BOOTSTRAP_SRC" || c_warn "shellcheck reporto avisos"; } \
  || c_warn "shellcheck no instalado — se omite analisis estatico"

# ------------------------------------------------------- 2. bucket
if [ "$DRY_RUN" = "false" ] && aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  log "El bucket ya existe."
else
  log "Creando bucket $BUCKET..."
  if [ "$REGION" = "us-east-1" ]; then
    run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
  run aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
  # La consola de CloudFormation del CLIENTE (otra cuenta AWS) tiene que poder
  # leer la plantilla sin credenciales.
  run aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false"
  POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"PublicReadArtifacts\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":[\"arn:aws:s3:::${BUCKET}/latest/*\",\"arn:aws:s3:::${BUCKET}/releases/*\"]}]}"
  run aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY"
  c_ok "Bucket listo (versionado, lectura publica solo en latest/ y releases/)."
fi

# ------------------------------------------------------- 3. build
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cp "$BOOTSTRAP_SRC" "$BUILD_DIR/bootstrap.sh"

BOOTSTRAP_SHA="$(sha256_of "$BUILD_DIR/bootstrap.sh")"
BOOTSTRAP_URL="https://${BUCKET}.s3.${REGION}.amazonaws.com/releases/${VERSION}/bootstrap.sh"
log "SHA256 bootstrap.sh: $BOOTSTRAP_SHA"

# Reescribe SOLO el Default: que esta dentro de cada bloque de parametro.
# (Un sed global sobre 'Default: ""' pisaria tambien HostedZoneId.)
awk -v url="$BOOTSTRAP_URL" -v sha="$BOOTSTRAP_SHA" '
  /^  BootstrapScriptUrl:/ { inurl=1; insha=0 }
  /^  BootstrapSha256:/    { insha=1; inurl=0 }
  /^  [A-Za-z][A-Za-z0-9]*:/ && !/^  BootstrapScriptUrl:/ && !/^  BootstrapSha256:/ { inurl=0; insha=0 }
  inurl && /^    Default:/ { print "    Default: \"" url "\""; inurl=0; next }
  insha && /^    Default:/ { print "    Default: \"" sha "\""; insha=0; next }
  { print }
' "$TEMPLATE_SRC" > "$BUILD_DIR/wordpress-stack.yaml"

grep -q "$BOOTSTRAP_URL"  "$BUILD_DIR/wordpress-stack.yaml" || die "no se inyecto la URL de S3 — ¿aplicaste el patch al template?"
grep -q "$BOOTSTRAP_SHA"  "$BUILD_DIR/wordpress-stack.yaml" || die "no se inyecto el SHA256 — falta el parametro BootstrapSha256"
grep -q "raw.githubusercontent" "$BUILD_DIR/wordpress-stack.yaml" && die "la plantilla publicada todavia apunta a GitHub raw"
c_ok "Plantilla fijada a $VERSION."

if [ "$DRY_RUN" = "false" ]; then
  log "Validando contra CloudFormation..."
  aws cloudformation validate-template \
    --template-body "file://$BUILD_DIR/wordpress-stack.yaml" --region "$REGION" >/dev/null \
    || die "CloudFormation rechazo la plantilla"
  c_ok "Plantilla valida."
fi

# ------------------------------------------------------- 4. subir
upload() {  # upload <local> <key> <content-type> <cache-control>
  run aws s3 cp "$1" "s3://${BUCKET}/$2" --region "$REGION" \
    --content-type "$3" --cache-control "$4" --only-show-errors
}

log "Subiendo release $VERSION..."
upload "$BUILD_DIR/wordpress-stack.yaml" "releases/${VERSION}/wordpress-stack.yaml" "text/yaml"          "max-age=31536000"
upload "$BUILD_DIR/bootstrap.sh"         "releases/${VERSION}/bootstrap.sh"         "text/x-shellscript" "max-age=31536000"

log "Actualizando latest/..."
# no-cache en latest: si no, depuras un bug que ya arreglaste.
upload "$BUILD_DIR/wordpress-stack.yaml" "latest/wordpress-stack.yaml" "text/yaml"          "no-cache"
upload "$BUILD_DIR/bootstrap.sh"         "latest/bootstrap.sh"         "text/x-shellscript" "no-cache"

# ------------------------------------------------------- 5. salida
TPL_LATEST="https://${BUCKET}.s3.${REGION}.amazonaws.com/latest/wordpress-stack.yaml"
TPL_PINNED="https://${BUCKET}.s3.${REGION}.amazonaws.com/releases/${VERSION}/wordpress-stack.yaml"
LAUNCH_URL="https://console.aws.amazon.com/cloudformation/home?region=${REGION}#/stacks/quickcreate?templateURL=${TPL_LATEST}&stackName=wp-oneclick"

echo
c_ok "================= PUBLICADO ================="
echo "Plantilla (latest) : $TPL_LATEST"
echo "Plantilla (fijada) : $TPL_PINNED"
echo "bootstrap.sh       : $BOOTSTRAP_URL"
echo "SHA256             : $BOOTSTRAP_SHA"
echo
echo "--- Boton para el README.md ---"
echo "[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](${LAUNCH_URL})"
echo
echo "--- URL directa para mandarle al cliente ---"
echo "$LAUNCH_URL"
echo

if [ "$DRY_RUN" = "true" ]; then
  c_warn "Dry-run: no se subio nada."
else
  log "Comprobando lectura publica sin credenciales..."
  curl -fsS -o /dev/null "$TPL_LATEST" \
    && c_ok "OK — la consola del cliente va a poder leerla." \
    || die "la URL publica no responde: revisa bucket policy y Block Public Access"
fi

#!/bin/bash
# ============================================================================
# bootstrap.sh — Instala WordPress + OpenLiteSpeed + MariaDB + PHP 8.4 + SSL
# de forma no interactiva. Pensado para correr como UserData de EC2, pero
# también puedes probarlo a mano por SSH exportando las variables primero.
#
# Uso manual (para probar antes de confiar en el flujo de un clic):
#   export DOMAIN_NAME="tiendasplanet.com"
#   export ADMIN_EMAIL="tucorreo@tiendasplanet.com"
#   export WP_ADMIN_USER="admin"          # opcional, default "admin"
#   export HOSTED_ZONE_ID=""              # opcional, ID de zona en Route 53
#   export AWS_REGION="us-east-1"         # opcional
#   export BACKUP_BUCKET=""               # opcional, bucket S3 de respaldos
#   sudo -E bash bootstrap.sh
# ============================================================================

set -euo pipefail
exec > /var/log/wp-bootstrap.log 2>&1
echo "=== Bootstrap iniciado: $(date) ==="

: "${DOMAIN_NAME:?Debes exportar DOMAIN_NAME (ej. tiendasplanet.com)}"
: "${ADMIN_EMAIL:?Debes exportar ADMIN_EMAIL}"
WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
BACKUP_BUCKET="${BACKUP_BUCKET:-}"   # bucket S3 para respaldos; vacio = solo copia local

# --- IP pública de la instancia vía metadata (IMDSv2) ---
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
echo "IP pública detectada: $PUBLIC_IP"

DB_NAME=$(echo "$DOMAIN_NAME" | tr '.' '_')
DB_USER="wp_$(echo "$DOMAIN_NAME" | cut -d. -f1)"
VH_NAME=$(echo "$DOMAIN_NAME" | tr '.' '-')
OLS_USER="admin"

# Credenciales persistentes: si ya corrimos el script antes en esta misma
# instancia (por un reintento tras un error), reutilizamos las mismas
# contraseñas en vez de generar unas nuevas que ya no coincidirían con lo
# que MariaDB/OLS quedaron esperando.
STATE_FILE="/root/.wp-bootstrap-secrets"
if [ -f "$STATE_FILE" ]; then
  echo "Se encontraron credenciales de un intento anterior, reutilizándolas."
  source "$STATE_FILE"
else
  OLS_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c22)
  DB_ROOT_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c22)
  DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c22)
  WP_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c22)
  cat > "$STATE_FILE" <<EOF
OLS_PASS='$OLS_PASS'
DB_ROOT_PASS='$DB_ROOT_PASS'
DB_PASS='$DB_PASS'
WP_PASS='$WP_PASS'
EOF
  chmod 600 "$STATE_FILE"
fi

echo "== Paso 1/13: sistema =="
apt update && apt upgrade -y
apt install -y wget curl gnupg2 software-properties-common ufw unzip jq expect dnsutils php-cli php8.3-mysql

echo "== Instalando AWS CLI v2 (instalador oficial, no depende de apt) =="
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
aws --version

echo "== Paso 2/13: OpenLiteSpeed =="
wget -O - https://repo.litespeed.sh | bash
apt update
apt install -y openlitespeed
systemctl enable lsws 2>/dev/null || systemctl enable lshttpd 2>/dev/null || echo "AVISO: no se pudo 'enable' OpenLiteSpeed para autoarranque (no crítico, se sigue iniciando/reiniciando bien con systemctl start|restart lsws). Revísalo luego con: systemctl status lsws"

echo "== Paso 3/13: MariaDB 11.4 LTS =="
curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-11.4"
apt update
apt install -y mariadb-server mariadb-client
systemctl enable mariadb
systemctl start mariadb

# Detecta si root ya tiene contraseña puesta (de un intento anterior) o no.
if mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
  MYSQL_ROOT=(mysql -u root)
elif mysql -u root -p"$DB_ROOT_PASS" -e "SELECT 1" >/dev/null 2>&1; then
  echo "root de MariaDB ya tenía la contraseña guardada puesta, continuando."
  MYSQL_ROOT=(mysql -u root -p"$DB_ROOT_PASS")
else
  echo "ERROR: no se pudo conectar a MariaDB como root ni sin contraseña ni con la guardada en $STATE_FILE"
  exit 1
fi

"${MYSQL_ROOT[@]}" <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "== Paso 4/13: PHP 8.4 (LSPHP) =="
apt install -y lsphp84 lsphp84-common lsphp84-mysql

for ext in curl json zip gd mbstring xml intl imagick opcache; do
  apt install -y lsphp84-$ext || echo "AVISO: el paquete lsphp84-$ext no existe en el repo, se omite (posiblemente ya viene incluido en el paquete base)"
done

echo "== Activando extensiones PHP que no vengan ya habilitadas =="
# OJO: el paquete base lsphp84 YA trae varias extensiones habilitadas via
# mods-available/ (mysqli, pdo_mysql, curl, intl, imagick, opcache). Si ademas
# las declaramos en php.ini, PHP arranca quejandose en cada peticion:
#   PHP Warning: Module "curl" is already loaded in Unknown on line 0
#   Cannot load Zend OPcache - it was already loaded
# Funciona igual, pero ensucia el log de errores y confunde al diagnosticar.
# Por eso aqui solo se agrega lo que NO este ya habilitado.
PHP_INI="/usr/local/lsws/lsphp84/etc/php/8.4/litespeed/php.ini"
PHP_ETC=$(dirname "$PHP_INI")/..
MODS_DIR="$PHP_ETC/mods-available"
EXT_DIR=$(find /usr/local/lsws/lsphp84/lib/php -maxdepth 1 -type d -name "2*" | head -1)

ya_habilitada() {
  # true si el paquete base ya la activa (archivo .ini en mods-available)
  local mod="$1"
  ls "$MODS_DIR"/*"${mod}".ini >/dev/null 2>&1
}

if [ -n "$EXT_DIR" ]; then
  for mod in mysqli pdo_mysql curl gd mbstring xml zip intl imagick; do
    if ya_habilitada "$mod"; then
      echo "  $mod: ya viene habilitada por el paquete base, no se toca."
    elif [ -f "$EXT_DIR/${mod}.so" ] && ! grep -q "^extension=${mod}\.so" "$PHP_INI"; then
      echo "  $mod: se activa en php.ini."
      echo "extension=${mod}.so" >> "$PHP_INI"
    fi
  done
  if ya_habilitada opcache; then
    echo "  opcache: ya viene habilitado por el paquete base, no se toca."
  elif [ -f "$EXT_DIR/opcache.so" ] && ! grep -qi "opcache.so" "$PHP_INI"; then
    echo "zend_extension=opcache.so" >> "$PHP_INI"
  fi
fi
echo "Verificando modulos PHP realmente cargados:"
# Nota: lsphp NO acepta -m; hay que preguntarle a PHP desde un script.
PHP_MODS=$(/usr/local/lsws/lsphp84/bin/lsphp -r 'echo implode(" ", get_loaded_extensions());' 2>/dev/null)
echo "  $PHP_MODS"
for req in mysqli curl gd mbstring xml zip intl imagick; do
  case " $PHP_MODS " in
    *" $req "*) : ;;
    *) echo "  AVISO: la extension '$req' NO esta cargada — algunos plugins de WordPress la necesitan." ;;
  esac
done

echo "== Ajustando límites de PHP (memoria, subida de archivos, tiempos) =="
set_php_ini() {
  local key="$1" val="$2" ini="$3"
  if grep -qE "^${key}[[:space:]]*=" "$ini"; then
    sed -i -E "s/^${key}[[:space:]]*=.*/${key} = ${val}/" "$ini"
  elif grep -qE "^;${key}[[:space:]]*=" "$ini"; then
    sed -i -E "s/^;${key}[[:space:]]*=.*/${key} = ${val}/" "$ini"
  else
    echo "${key} = ${val}" >> "$ini"
  fi
}
set_php_ini memory_limit 256M "$PHP_INI"
set_php_ini upload_max_filesize 64M "$PHP_INI"
set_php_ini post_max_size 64M "$PHP_INI"
set_php_ini max_execution_time 300 "$PHP_INI"
set_php_ini max_input_vars 3000 "$PHP_INI"
set_php_ini max_input_time 300 "$PHP_INI"

echo "== Paso 5/13: panel de administración OLS =="
# NOTA: admpass.sh es interactivo por diseño. Lo automatizamos con `expect`.
# Si LiteSpeed cambia el texto de sus prompts esto puede fallar — si pasa,
# entra por SSH y corre admpass.sh a mano una vez.
expect <<EOF || echo "AVISO: revisa /usr/local/lsws/admin/misc/admpass.sh manualmente"
spawn /usr/local/lsws/admin/misc/admpass.sh
expect "User Name*"
send "$OLS_USER\r"
expect "Password*"
send "$OLS_PASS\r"
expect "Retype Password*"
send "$OLS_PASS\r"
expect eof
EOF

echo "== Paso 6/13: Virtual Host para $DOMAIN_NAME =="
mkdir -p /usr/local/lsws/$VH_NAME/public_html
mkdir -p /usr/local/lsws/conf/vhosts/$VH_NAME

cat > /usr/local/lsws/conf/vhosts/$VH_NAME/vhconf.conf <<VHCONF
docRoot                   \$VH_ROOT/public_html
vhDomain                  $DOMAIN_NAME
vhAliases                 www.$DOMAIN_NAME
adminEmails               $ADMIN_EMAIL
enableGzip                1

index  {
  useServer               0
  indexFiles              index.php, index.html
}

scripthandler  {
  add                     lsapi:lsphp84 php
}

extprocessor lsphp84 {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp84.sock
  maxConns                10
  env                     PHP_LSAPI_CHILDREN=10
  initTimeout             60
  retryTimeout            0
  persistConn             1
  respBuffer              0
  autoStart               1
  path                    /usr/local/lsws/lsphp84/bin/lsphp
  backlog                 100
  instances               1
  priority                0
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           400
  procHardLimit           500
}

rewrite  {
  enable                  1
  autoLoadHtaccess        1
}
VHCONF

if ! grep -q "^virtualhost $VH_NAME {" /usr/local/lsws/conf/httpd_config.conf; then
cat >> /usr/local/lsws/conf/httpd_config.conf <<MAINCONF

virtualhost $VH_NAME {
  vhRoot                  /usr/local/lsws/$VH_NAME/
  configFile              \$SERVER_ROOT/conf/vhosts/$VH_NAME/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              0
}
MAINCONF
else
  echo "El virtualhost $VH_NAME ya estaba registrado, no se duplica."
fi

# Mapea el vhost al listener HTTP "Default" que trae OLS de fábrica (solo si
# no estaba mapeado ya, para poder reintentar el script sin duplicarlo).
# NOTA: esta es la parte más frágil del script — asume que existe un bloque
# `listener Default { ... }`. Si tu versión de OLS lo nombra distinto,
# ajusta este sed o hazlo una vez a mano desde el panel :7080.
if ! grep -q "map .*$VH_NAME $DOMAIN_NAME" /usr/local/lsws/conf/httpd_config.conf; then
  sed -i "/^listener Default/,/^}/ s/^}/  map                     $VH_NAME $DOMAIN_NAME, www.$DOMAIN_NAME\n}/" /usr/local/lsws/conf/httpd_config.conf
else
  echo "El mapeo del dominio ya existía, no se duplica."
fi

chown -R nobody:nogroup /usr/local/lsws/$VH_NAME/public_html
systemctl restart lsws

echo "== Paso 7/13: WP-CLI + WordPress =="
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp-cli.phar
# WP-CLI exige SAPI 'cli' — lsphp84 se identifica como SAPI 'litespeed' y WP-CLI
# lo rechaza, así que para WP-CLI usamos el php-cli del sistema (con php-mysql
# instalado arriba). El sitio en sí sigue sirviéndose con lsphp84, sin cambios.

cd /usr/local/lsws/$VH_NAME/public_html
if [ ! -f wp-load.php ]; then
  sudo -u nobody /usr/bin/php /usr/local/bin/wp-cli.phar core download
else
  echo "WordPress ya estaba descargado, se omite."
fi

if [ ! -f wp-config.php ]; then
  sudo -u nobody /usr/bin/php /usr/local/bin/wp-cli.phar config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost=localhost
else
  echo "wp-config.php ya existía, se omite."
fi

if sudo -u nobody /usr/bin/php /usr/local/bin/wp-cli.phar core is-installed 2>/dev/null; then
  echo "WordPress ya estaba instalado, se omite core install."
else
  sudo -u nobody /usr/bin/php /usr/local/bin/wp-cli.phar core install --url="https://$DOMAIN_NAME" --title="$DOMAIN_NAME" \
    --admin_user="$WP_ADMIN_USER" --admin_password="$WP_PASS" --admin_email="$ADMIN_EMAIL" --skip-email
fi
sudo -u nobody /usr/bin/php /usr/local/bin/wp-cli.phar plugin install litespeed-cache --activate

echo "== Paso 8/13: firewall (ufw) =="
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 7080/tcp
ufw --force enable

echo "== Paso 9/13: DNS automático en Route 53 (si se dio Hosted Zone) =="
if [ -n "$HOSTED_ZONE_ID" ]; then
  cat > /tmp/dns-change.json <<JSON
{
  "Changes": [
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "$DOMAIN_NAME", "Type": "A", "TTL": 300, "ResourceRecords": [{"Value": "$PUBLIC_IP"}]}},
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "www.$DOMAIN_NAME", "Type": "A", "TTL": 300, "ResourceRecords": [{"Value": "$PUBLIC_IP"}]}}
  ]
}
JSON
  aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch file:///tmp/dns-change.json --region "$AWS_REGION" \
    || echo "AVISO: falló el cambio de DNS automático — revisa los permisos IAM del rol de la instancia"
fi

echo "== Paso 10/13: SSL (Let's Encrypt, con reintento acotado hasta que el DNS resuelva) =="
apt install -y snapd
snap install core; snap refresh core
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

# --- Hooks de renovacion ---------------------------------------------------
# certbot emite y renueva en modo --standalone, que necesita el puerto 80 LIBRE.
# OpenLiteSpeed lo ocupa. La emision inicial funciona porque get-ssl.sh para OLS
# a mano, pero la RENOVACION automatica (timer de snap, a los ~60 dias) corre
# sin ese contexto: encuentra el puerto ocupado, falla, y el sitio se queda sin
# SSL sin que nadie se entere. Estos hooks viven en renewal-hooks/ y aplican a
# toda renovacion futura, sin depender de flags que haya que recordar.
mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post

cat > /etc/letsencrypt/renewal-hooks/pre/10-stop-lsws.sh <<'PREHOOK'
#!/bin/bash
# Libera el puerto 80 para que certbot --standalone pueda validar.
systemctl stop lsws || true
PREHOOK

cat > /etc/letsencrypt/renewal-hooks/post/10-start-lsws.sh <<'POSTHOOK'
#!/bin/bash
# Corre SIEMPRE, haya renovado bien o mal, para no dejar el sitio caido.
systemctl start lsws || systemctl restart lsws || true
POSTHOOK

chmod +x /etc/letsencrypt/renewal-hooks/pre/10-stop-lsws.sh \
         /etc/letsencrypt/renewal-hooks/post/10-start-lsws.sh
echo "Hooks de renovacion instalados en /etc/letsencrypt/renewal-hooks/"

cat > /usr/local/bin/get-ssl.sh <<SSLSCRIPT
#!/bin/bash
# Emite el certificado en cuanto el DNS del cliente apunte a esta IP.
# Se rinde tras MAX_TRIES intentos para no dejar un cron golpeando a
# Let's Encrypt para siempre si el dominio nunca se apunta.
DOMAIN="$DOMAIN_NAME"
IP="$PUBLIC_IP"
EMAIL="$ADMIN_EMAIL"
VH="$VH_NAME"
COUNTER=/var/lib/wp-ssl-attempts
GIVEUP=/var/lib/wp-ssl-giveup
MAX_TRIES=192   # 192 x 15 min = 48 horas

if [ -d "/etc/letsencrypt/live/\$DOMAIN" ]; then exit 0; fi
if [ -f "\$GIVEUP" ]; then exit 0; fi

N=\$(cat "\$COUNTER" 2>/dev/null || echo 0)
N=\$((N + 1))
echo "\$N" > "\$COUNTER"

if [ "\$N" -gt "\$MAX_TRIES" ]; then
  echo "\$(date): 48h de intentos y \$DOMAIN nunca apunto a \$IP. Me detengo."
  echo "  -> Corrige el registro A del dominio y luego ejecuta en el servidor:"
  echo "     rm -f \$GIVEUP \$COUNTER && /usr/local/bin/get-ssl.sh"
  touch "\$GIVEUP"
  exit 0
fi

RESOLVED=\$(dig +short A "\$DOMAIN" @8.8.8.8 | tail -1)
if [ "\$RESOLVED" != "\$IP" ]; then
  echo "\$(date): intento \$N/\$MAX_TRIES — \$DOMAIN resuelve a '\$RESOLVED', no a \$IP. Espero."
  exit 0
fi

# ¿El cliente creo tambien el registro de www? Si no existe, pedir el
# certificado con -d www.\$DOMAIN hace fallar la emision COMPLETA y deja al
# dominio raiz sin SSL tambien. Por eso www es opcional aqui.
WWW_RESOLVED=\$(dig +short A "www.\$DOMAIN" @8.8.8.8 | tail -1)
if [ "\$WWW_RESOLVED" = "\$IP" ]; then
  DOMAIN_ARGS="-d \$DOMAIN -d www.\$DOMAIN"
else
  echo "\$(date): www.\$DOMAIN no apunta aqui (resuelve a '\$WWW_RESOLVED'); emito solo para \$DOMAIN."
  DOMAIN_ARGS="-d \$DOMAIN"
fi

systemctl stop lsws
certbot certonly --standalone \$DOMAIN_ARGS --non-interactive --agree-tos \\
  -m "\$EMAIL" --keep-until-expiring
CERT_OK=\$?
systemctl start lsws

if [ "\$CERT_OK" -ne 0 ] || [ ! -d "/etc/letsencrypt/live/\$DOMAIN" ]; then
  echo "\$(date): certbot fallo (codigo \$CERT_OK). El cron reintenta en 15 min."
  exit 0
fi

if ! grep -q "listener SSL" /usr/local/lsws/conf/httpd_config.conf; then
cat >> /usr/local/lsws/conf/httpd_config.conf <<SSLCONF

listener SSL {
  address                 *:443
  secure                  1
  keyFile                 /etc/letsencrypt/live/\$DOMAIN/privkey.pem
  certFile                /etc/letsencrypt/live/\$DOMAIN/fullchain.pem
  map                     \$VH \$DOMAIN, www.\$DOMAIN
}
SSLCONF
systemctl restart lsws
fi
echo "\$(date): SSL activo para \$DOMAIN."
SSLSCRIPT
chmod +x /usr/local/bin/get-ssl.sh
# grep -v evita duplicar la linea si el script se re-ejecuta en la misma maquina
(crontab -l 2>/dev/null | grep -v get-ssl.sh; echo "*/15 * * * * /usr/local/bin/get-ssl.sh >> /var/log/get-ssl.log 2>&1") | crontab -
/usr/local/bin/get-ssl.sh || echo "Primer intento de SSL no completado, el cron reintentara solo."

echo "== Paso 11/13: respaldos automaticos (base de datos + archivos) =="
mkdir -p /var/backups/wordpress
chown nobody:nogroup /var/backups/wordpress
chmod 750 /var/backups/wordpress

cat > /usr/local/bin/wp-backup.sh <<BACKUPSCRIPT
#!/bin/bash
# Respaldo: volcado de la base de datos + wp-content + wp-config.php.
# Queda en /var/backups/wordpress (ultimas 3 copias) y, si hay bucket
# configurado, sube a S3 (alli la retencion la maneja la regla de ciclo de
# vida del bucket: 30 dias).
set -uo pipefail
DOMAIN="$DOMAIN_NAME"
DOCROOT="/usr/local/lsws/$VH_NAME/public_html"
BUCKET="$BACKUP_BUCKET"
REGION="$AWS_REGION"
DEST=/var/backups/wordpress
STAMP=\$(date +%Y%m%d-%H%M%S)

echo "=== Respaldo \$STAMP de \$DOMAIN ==="
cd "\$DOCROOT" || { echo "ERROR: no existe \$DOCROOT"; exit 1; }

sudo -u nobody /usr/bin/php /usr/local/bin/wp-cli.phar db export "\$DEST/db-\$STAMP.sql" --add-drop-table \\
  || { echo "ERROR: fallo el volcado de la base de datos"; exit 1; }
gzip -f "\$DEST/db-\$STAMP.sql"

tar -czf "\$DEST/files-\$STAMP.tar.gz" -C "\$DOCROOT" wp-content wp-config.php \\
  || { echo "ERROR: fallo el empaquetado de archivos"; exit 1; }

if [ -n "\$BUCKET" ]; then
  aws s3 cp "\$DEST/db-\$STAMP.sql.gz"    "s3://\$BUCKET/\$DOMAIN/\$STAMP/" --region "\$REGION" \\
    || echo "AVISO: no se pudo subir la base de datos a S3"
  aws s3 cp "\$DEST/files-\$STAMP.tar.gz" "s3://\$BUCKET/\$DOMAIN/\$STAMP/" --region "\$REGION" \\
    || echo "AVISO: no se pudieron subir los archivos a S3"
else
  echo "AVISO: sin bucket S3 configurado — la copia queda SOLO en este disco."
fi

# Conserva las 3 copias locales mas recientes de cada tipo
ls -1t "\$DEST"/db-*.sql.gz    2>/dev/null | tail -n +4 | xargs -r rm -f
ls -1t "\$DEST"/files-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f

echo "=== Respaldo \$STAMP terminado ==="
BACKUPSCRIPT
chmod +x /usr/local/bin/wp-backup.sh

# 07:15 UTC = 02:15 en Peru (UTC-5), fuera de hora pico
(crontab -l 2>/dev/null | grep -v wp-backup.sh; echo "15 7 * * * /usr/local/bin/wp-backup.sh >> /var/log/wp-backup.log 2>&1") | crontab -

# Un respaldo de prueba ahora mismo: si algo esta mal (permisos, IAM del
# bucket), es mejor enterarse aqui que dentro de 3 semanas cuando haga falta.
/usr/local/bin/wp-backup.sh >> /var/log/wp-backup.log 2>&1 \
  && echo "Respaldo de prueba OK (ver /var/log/wp-backup.log)" \
  || echo "AVISO: el respaldo de prueba fallo — revisa /var/log/wp-backup.log"

echo "== Paso 12/13: verificacion final (health check) =="
HEALTH_URL="https://$DOMAIN_NAME"
HEALTH_OK="no"
for i in 1 2 3; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time 20 "$HEALTH_URL" || echo "000")
  if [ "$CODE" = "200" ]; then HEALTH_OK="si"; break; fi
  echo "Health check intento $i/3: HTTP $CODE"
  sleep 10
done
if [ "$HEALTH_OK" = "si" ]; then
  echo "HEALTH CHECK OK — $HEALTH_URL responde 200."
else
  # Aun sin SSL el sitio puede estar bien: si el DNS no ha propagado todavia,
  # el cron de SSL lo resolvera solo en cuanto apunte.
  CODE_IP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "http://$PUBLIC_IP" || echo "000")
  echo "HEALTH CHECK PENDIENTE — $HEALTH_URL no respondio 200 todavia (HTTP $CODE)."
  echo "  Servidor por IP directa: HTTP $CODE_IP (200 = el servidor esta bien, falta el DNS/SSL)"
  echo "  Revisa: dig +short A $DOMAIN_NAME  ->  debe dar $PUBLIC_IP"
  echo "  Progreso del SSL: tail -f /var/log/get-ssl.log"
fi

echo "== Paso 13/13: credenciales en AWS Secrets Manager =="
SECRET_JSON=$(jq -n \
  --arg olsu "$OLS_USER" --arg olsp "$OLS_PASS" \
  --arg dbrp "$DB_ROOT_PASS" --arg dbu "$DB_USER" --arg dbp "$DB_PASS" \
  --arg wpu "$WP_ADMIN_USER" --arg wpp "$WP_PASS" \
  '{ols_admin_user:$olsu, ols_admin_pass:$olsp, db_root_pass:$dbrp, db_user:$dbu, db_pass:$dbp, wp_admin_user:$wpu, wp_admin_pass:$wpp}')

SECRET_NAME="wp-oneclick-deploy/$DOMAIN_NAME"
aws secretsmanager create-secret --name "$SECRET_NAME" --secret-string "$SECRET_JSON" --region "$AWS_REGION" \
  || aws secretsmanager put-secret-value --secret-id "$SECRET_NAME" --secret-string "$SECRET_JSON" --region "$AWS_REGION" \
  || echo "AVISO: no se pudieron guardar las credenciales en Secrets Manager — revisa el rol IAM. Quedan en este log."

echo "=== Bootstrap terminado: $(date) ==="
echo "Sitio:        https://$DOMAIN_NAME"
echo "Panel OLS:    https://$PUBLIC_IP:7080  (usuario: $OLS_USER)"
echo "Credenciales: Secrets Manager -> $SECRET_NAME (region $AWS_REGION)"
echo "Respaldos:    diarios 07:15 UTC -> /var/backups/wordpress + s3://${BACKUP_BUCKET:-(sin bucket)}"
echo "Health check: $HEALTH_OK  (si=el sitio ya responde 200 por HTTPS)"

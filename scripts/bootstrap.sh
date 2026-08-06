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

# --- IP pública de la instancia vía metadata (IMDSv2) ---
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
echo "IP pública detectada: $PUBLIC_IP"

DB_NAME=$(echo "$DOMAIN_NAME" | tr '.' '_')
DB_USER="wp_$(echo "$DOMAIN_NAME" | cut -d. -f1)"
VH_NAME=$(echo "$DOMAIN_NAME" | tr '.' '-')
OLS_USER="admin"
OLS_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c22)
DB_ROOT_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c22)
DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c22)
WP_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c22)

echo "== Paso 1/11: sistema =="
apt update && apt upgrade -y
apt install -y wget curl gnupg2 software-properties-common ufw unzip jq expect dnsutils php-cli

echo "== Instalando AWS CLI v2 (instalador oficial, no depende de apt) =="
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
aws --version

echo "== Paso 2/11: OpenLiteSpeed =="
wget -O - https://repo.litespeed.sh | bash
apt update
apt install -y openlitespeed
systemctl enable lsws

echo "== Paso 3/11: MariaDB 11.4 LTS =="
curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-11.4"
apt update
apt install -y mariadb-server mariadb-client
systemctl enable mariadb
systemctl start mariadb

mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "== Paso 4/11: PHP 8.4 (LSPHP) =="
apt install -y lsphp84 lsphp84-common lsphp84-mysql lsphp84-curl lsphp84-json \
  lsphp84-zip lsphp84-gd lsphp84-mbstring lsphp84-xml lsphp84-intl \
  lsphp84-imagick lsphp84-opcache

echo "== Paso 5/11: panel de administración OLS =="
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

echo "== Paso 6/11: Virtual Host para $DOMAIN_NAME =="
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

cat >> /usr/local/lsws/conf/httpd_config.conf <<MAINCONF

virtualhost $VH_NAME {
  vhRoot                  /usr/local/lsws/$VH_NAME/
  configFile              \$SERVER_ROOT/conf/vhosts/$VH_NAME/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              0
}
MAINCONF

# Mapea el vhost al listener HTTP "Default" que trae OLS de fábrica.
# NOTA: esta es la parte más frágil del script — asume que existe un bloque
# `listener Default { ... }`. Si tu versión de OLS lo nombra distinto,
# ajusta este sed o hazlo una vez a mano desde el panel :7080.
sed -i "/^listener Default/,/^}/ s/^}/  map                     $VH_NAME $DOMAIN_NAME, www.$DOMAIN_NAME\n}/" /usr/local/lsws/conf/httpd_config.conf

chown -R nobody:nogroup /usr/local/lsws/$VH_NAME/public_html
systemctl restart lsws

echo "== Paso 7/11: WP-CLI + WordPress =="
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp
export WP_CLI_PHP=/usr/local/lsws/lsphp84/bin/lsphp

cd /usr/local/lsws/$VH_NAME/public_html
sudo -u nobody -E env WP_CLI_PHP=$WP_CLI_PHP wp core download
sudo -u nobody -E env WP_CLI_PHP=$WP_CLI_PHP wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost=localhost
sudo -u nobody -E env WP_CLI_PHP=$WP_CLI_PHP wp core install --url="https://$DOMAIN_NAME" --title="$DOMAIN_NAME" \
  --admin_user="$WP_ADMIN_USER" --admin_password="$WP_PASS" --admin_email="$ADMIN_EMAIL" --skip-email
sudo -u nobody -E env WP_CLI_PHP=$WP_CLI_PHP wp plugin install litespeed-cache --activate

echo "== Paso 8/11: firewall (ufw) =="
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 7080/tcp
ufw --force enable

echo "== Paso 9/11: DNS automático en Route 53 (si se dio Hosted Zone) =="
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

echo "== Paso 10/11: SSL (Let's Encrypt, con reintento hasta que el DNS resuelva) =="
apt install -y snapd
snap install core; snap refresh core
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

cat > /usr/local/bin/get-ssl.sh <<SSLSCRIPT
#!/bin/bash
if [ -d "/etc/letsencrypt/live/$DOMAIN_NAME" ]; then exit 0; fi
RESOLVED=\$(dig +short $DOMAIN_NAME @8.8.8.8 | tail -1)
if [ "\$RESOLVED" != "$PUBLIC_IP" ]; then
  echo "\$(date): DNS aún no resuelve a $PUBLIC_IP (resuelve a '\$RESOLVED'). Reintentando en 15 min."
  exit 0
fi
systemctl stop lsws
certbot certonly --standalone -d $DOMAIN_NAME -d www.$DOMAIN_NAME --non-interactive --agree-tos -m $ADMIN_EMAIL
systemctl start lsws
if ! grep -q "listener SSL" /usr/local/lsws/conf/httpd_config.conf; then
cat >> /usr/local/lsws/conf/httpd_config.conf <<SSLCONF

listener SSL {
  address                 *:443
  secure                  1
  keyFile                 /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem
  certFile                /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem
  map                     $VH_NAME $DOMAIN_NAME, www.$DOMAIN_NAME
}
SSLCONF
systemctl restart lsws
fi
SSLSCRIPT
chmod +x /usr/local/bin/get-ssl.sh
(crontab -l 2>/dev/null; echo "*/15 * * * * /usr/local/bin/get-ssl.sh >> /var/log/get-ssl.log 2>&1") | crontab -
/usr/local/bin/get-ssl.sh || echo "Primer intento de SSL no completado, el cron reintentará solo."

echo "== Paso 11/11: credenciales en AWS Secrets Manager =="
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

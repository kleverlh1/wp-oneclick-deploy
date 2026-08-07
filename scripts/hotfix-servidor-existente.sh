#!/bin/bash
# ============================================================================
# hotfix-servidor-existente.sh
#
# Aplica el Bloque 0 (renovacion de SSL + respaldos) a un servidor que YA fue
# desplegado con una version anterior de bootstrap.sh — como tiendasplanet.com.
# No toca WordPress, ni la base de datos, ni la configuracion de OLS: solo
# agrega los hooks de renovacion y el respaldo diario.
#
# Uso, por SSH en el servidor:
#   sudo DOMAIN_NAME="tiendasplanet.com" BACKUP_BUCKET="" bash hotfix-servidor-existente.sh
#
# BACKUP_BUCKET es opcional: si lo dejas vacio, los respaldos quedan solo en el
# disco de la instancia (mejor que nada, pero no te salva si se pierde el
# volumen). Para tenerlos en S3, primero actualiza el stack de CloudFormation
# con el template nuevo (eso crea el bucket y le da permiso al rol de la
# instancia) y luego corre esto pasando el nombre del bucket.
# ============================================================================
set -euo pipefail

: "${DOMAIN_NAME:?Debes indicar DOMAIN_NAME (ej. tiendasplanet.com)}"
BACKUP_BUCKET="${BACKUP_BUCKET:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
VH_NAME=$(echo "$DOMAIN_NAME" | tr '.' '-')
DOCROOT="/usr/local/lsws/$VH_NAME/public_html"

if [ ! -d "$DOCROOT" ]; then
  echo "ERROR: no encuentro $DOCROOT — revisa que DOMAIN_NAME sea el correcto."
  exit 1
fi

echo "=== 1/3: hooks de renovacion de certificado ==="
# Sin esto, la renovacion automatica de certbot (a los ~60 dias) encuentra el
# puerto 80 ocupado por OpenLiteSpeed, falla, y el sitio se queda sin SSL.
mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post

cat > /etc/letsencrypt/renewal-hooks/pre/10-stop-lsws.sh <<'PREHOOK'
#!/bin/bash
systemctl stop lsws || true
PREHOOK

cat > /etc/letsencrypt/renewal-hooks/post/10-start-lsws.sh <<'POSTHOOK'
#!/bin/bash
systemctl start lsws || systemctl restart lsws || true
POSTHOOK

chmod +x /etc/letsencrypt/renewal-hooks/pre/10-stop-lsws.sh \
         /etc/letsencrypt/renewal-hooks/post/10-start-lsws.sh
echo "Hooks instalados."

echo "=== 2/3: respaldo diario ==="
mkdir -p /var/backups/wordpress
chown nobody:nogroup /var/backups/wordpress
chmod 750 /var/backups/wordpress

cat > /usr/local/bin/wp-backup.sh <<BACKUPSCRIPT
#!/bin/bash
set -uo pipefail
DOMAIN="$DOMAIN_NAME"
DOCROOT="$DOCROOT"
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
  echo "AVISO: sin bucket S3 — la copia queda SOLO en este disco."
fi

ls -1t "\$DEST"/db-*.sql.gz    2>/dev/null | tail -n +4 | xargs -r rm -f
ls -1t "\$DEST"/files-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
echo "=== Respaldo \$STAMP terminado ==="
BACKUPSCRIPT
chmod +x /usr/local/bin/wp-backup.sh
(crontab -l 2>/dev/null | grep -v wp-backup.sh; echo "15 7 * * * /usr/local/bin/wp-backup.sh >> /var/log/wp-backup.log 2>&1") | crontab -

echo "Ejecutando un respaldo de prueba ahora..."
/usr/local/bin/wp-backup.sh

echo "=== 3/3: prueba en seco de la renovacion ==="
echo "(esto detiene OLS unos segundos y lo vuelve a levantar — es la prueba real)"
certbot renew --dry-run || echo "AVISO: la prueba en seco fallo, revisa el mensaje de arriba."

echo
echo "=== Hotfix terminado ==="
echo "Certificado actual:"
certbot certificates 2>/dev/null | grep -E "Certificate Name|Expiry Date" || true
echo "Respaldos en: /var/backups/wordpress  (log: /var/log/wp-backup.log)"
[ -n "$BACKUP_BUCKET" ] && echo "Copia en S3:  s3://$BACKUP_BUCKET/$DOMAIN_NAME/" || true

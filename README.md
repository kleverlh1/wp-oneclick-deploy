# Despliegue de 1 clic — WordPress sobre OpenLiteSpeed en AWS

Lanza un sitio WordPress completo (OpenLiteSpeed + MariaDB + PHP 8.4 + SSL) en una
instancia EC2 nueva, sin tocar la terminal. Lo único que pone el cliente: su cuenta
de AWS, su dominio, y (si quiere DNS automático) su Hosted Zone de Route 53.

## Desplegar

[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https://wp-oneclick-deploy-968638548210.s3.us-east-1.amazonaws.com/latest/wordpress-stack.yaml&stackName=wp-oneclick)

El botón abre la consola de CloudFormation **en la cuenta de AWS de quien hace
clic**, con la plantilla ya cargada.

## Cómo funciona

```
Cliente hace clic en "Launch Stack"
        │
        ▼
Se abre la consola de CloudFormation con la plantilla ya cargada
        │
        ▼
Cliente llena: dominio, correo, tamaño de instancia, su IP, llave SSH
        │
        ▼
CloudFormation crea: Security Group + IAM Role + Instancia EC2 + Elastic IP
        │
        ▼
La instancia arranca y su UserData descarga scripts/bootstrap.sh desde S3
(verificando su checksum SHA256) y lo ejecuta automáticamente
        │
        ▼
bootstrap.sh instala todo: OLS, MariaDB, PHP, WordPress (vía WP-CLI),
firewall, DNS en Route 53 (si aplica), SSL con reintento automático,
respaldos diarios, y guarda las contraseñas generadas en AWS Secrets Manager
        │
        ▼
Sitio en https://tudominio.com (5–15 min, según DNS)
```

## Lo que el cliente necesita antes de hacer clic

- Cuenta de AWS con permisos para crear EC2 / IAM / CloudFormation
- Un **Key Pair** de EC2 ya creado en la región que va a usar (para SSH de emergencia)
- Su dominio — si lo tiene en Route 53, puede pasar el `HostedZoneId` y el DNS
  se configura solo; si no, deberá apuntar manualmente el registro A a la
  Elastic IP que el stack le entrega en los "Outputs"

Al terminar, las credenciales de WordPress quedan en AWS Secrets Manager, en
`wp-oneclick-deploy/<su-dominio>`.

---

# Para el mantenedor

Todo lo de abajo es para quien desarrolla esta plantilla, no para el cliente.

## Publicar cambios (obligatorio después de cada edición)

La plantilla y el `bootstrap.sh` que el botón sirve **no salen de GitHub**: salen
de un bucket S3. GitHub es donde se edita; S3 es lo que el cliente descarga.

Eso significa que **un commit a GitHub no cambia nada para el cliente** hasta que
se publique. Después de tocar `cloudformation/wordpress-stack.yaml` o
`scripts/bootstrap.sh`:

```bash
./scripts/publish.sh --version v1.0.1
```

El script:

1. Valida la sintaxis de `bootstrap.sh` y la plantilla contra CloudFormation
2. Calcula el SHA256 del `bootstrap.sh` y lo inyecta en la plantilla publicada,
   junto con la URL de S3 (por eso `BootstrapScriptUrl` y `BootstrapSha256`
   nunca se editan a mano)
3. Sube ambos a `releases/<version>/` (inmutable) y a `latest/` (lo que sirve el botón)
4. Comprueba con un `curl` sin credenciales que la plantilla se puede leer

Cada release queda congelado: un cliente que lanzó con `v1.0.0` recibe
exactamente ese `bootstrap.sh` para siempre, aunque después cambies el repo.

**Por qué S3 y no `raw.githubusercontent.com`:** la consola nueva de AWS rechaza
URLs de GitHub en el campo `templateURL`, y una rama como `main` es mutable — un
cliente lanzando mientras tú comiteas a medias desplegaría una versión rota.

Bucket: `wp-oneclick-deploy-<tu-account-id>`, región `us-east-1`, versionado,
con lectura pública solo en `latest/` y `releases/`.

## Probar sin gastar certificados de Let's Encrypt

Let's Encrypt permite **5 certificados por semana para el mismo dominio**. Si
pruebas la plantilla varias veces con el mismo dominio, el sexto intento falla
con un error que no parece un bug tuyo.

Para probar, lanza el stack con el parámetro **`CertbotStaging = true`**. Usa el
servidor de pruebas: no consume cupo. El navegador mostrará advertencia de
certificado — eso es exactamente lo que debe pasar, y confirma que todo el
camino (S3 → checksum → UserData → DNS → certbot → OpenLiteSpeed) funcionó.

Para el cliente real, déjalo en `false` (es el valor por defecto).

## Qué NO está 100% garantizado en el primer intento

Este es un v1 funcional, no un producto probado en decenas de despliegues. Las
dos partes con más riesgo de necesitar un ajuste menor:

- **`admpass.sh` automatizado con `expect`** (Paso 5 del script): si LiteSpeed
  cambia el texto exacto de sus prompts, el auto-responder puede fallar. El
  script no se detiene por esto, pero entrarías con un panel sin contraseña
  seteada — se corrige a mano en 30 segundos por SSH.
- **La edición directa del `httpd_config.conf`** para mapear el dominio al
  listener (Paso 6): asume que existe un bloque `listener Default { ... }`
  tal como lo trae OpenLiteSpeed de fábrica. Si algo no cuadra, se ve enseguida
  en `/var/log/wp-bootstrap.log` y se corrige a mano una vez desde el panel
  `:7080`.

## Respaldos y restauración

El stack crea un bucket S3 propio (aparece en los Outputs como `BackupBucket`)
y el servidor corre `/usr/local/bin/wp-backup.sh` todos los días a las **07:15
UTC** (02:15 en Perú). Cada corrida guarda dos archivos:

- `db-FECHA.sql.gz` — volcado completo de la base de datos
- `files-FECHA.tar.gz` — `wp-content` + `wp-config.php`

Quedan en `/var/backups/wordpress` (las 3 copias más recientes) y en
`s3://BUCKET/DOMINIO/FECHA/`. En S3 se borran solos a los 30 días
(`BackupRetentionDays` en el template). El bucket tiene `DeletionPolicy:
Retain`: si borras el stack, los respaldos siguen ahí.

Log: `/var/log/wp-backup.log`. Para forzar un respaldo ahora:
`sudo /usr/local/bin/wp-backup.sh`

### Cómo restaurar (pruébalo una vez ANTES de necesitarlo)

Un respaldo que nunca restauraste no es un respaldo. Por SSH en el servidor:

```bash
DOM=tiendasplanet.com
BUCKET=<el que sale en el Output BackupBucket>
FECHA=20260806-071500          # aws s3 ls s3://$BUCKET/$DOM/ para ver cuáles hay

cd /tmp
aws s3 cp s3://$BUCKET/$DOM/$FECHA/db-$FECHA.sql.gz .
aws s3 cp s3://$BUCKET/$DOM/$FECHA/files-$FECHA.tar.gz .
gunzip -f db-$FECHA.sql.gz

DOCROOT=/usr/local/lsws/$(echo $DOM | tr '.' '-')/public_html
cd $DOCROOT
sudo -u nobody /usr/bin/php /usr/local/bin/wp-cli.phar db import /tmp/db-$FECHA.sql
sudo tar -xzf /tmp/files-$FECHA.tar.gz -C $DOCROOT
sudo chown -R nobody:nogroup $DOCROOT
sudo systemctl restart lsws
```

## Renovación del certificado SSL

`certbot` emite y renueva en modo `--standalone`, que necesita el **puerto 80
libre** — y OpenLiteSpeed lo ocupa. Por eso el script instala dos hooks:

```
/etc/letsencrypt/renewal-hooks/pre/10-stop-lsws.sh    → detiene OLS
/etc/letsencrypt/renewal-hooks/post/10-start-lsws.sh  → lo vuelve a levantar
```

El `post` corre siempre, haya renovado o no, para no dejar el sitio caído.
Sin estos hooks la renovación falla en silencio a los ~60 días y el sitio se
queda sin SSL. Para comprobarlo en cualquier momento:

```bash
sudo certbot renew --dry-run     # la prueba real: detiene OLS unos segundos
sudo certbot certificates        # fecha de vencimiento actual
```

El certificado se emite con `--cert-name "$DOMAIN"`, así la ruta es siempre
`/etc/letsencrypt/live/$DOMAIN/` y nunca aparece un sufijo `-0001` que dejaría
al vhost apuntando a un certificado viejo.

**Servidores ya desplegados con una versión anterior del script** no tienen los
hooks. Se les aplica con:

```bash
sudo DOMAIN_NAME="tudominio.com" BACKUP_BUCKET="" \
  bash scripts/hotfix-servidor-existente.sh
```

## Ideas para una v2

- **Publicación automática con GitHub Actions**: que cada `push` a `main`
  corra `publish.sh` solo, para no depender de acordarse.
- **AMI pre-construida con Packer**: instalar OLS/MariaDB/PHP una sola vez en
  una imagen dorada, para que el arranque de cada cliente tome ~1 minuto en
  vez de 5–10.
- **Notificación al terminar**: correo o Slack cuando el bootstrap acaba (o
  falla), en vez de revisar el log por SSH.
- **Panel propio de auto-servicio**: un formulario web que llame a la API de
  CloudFormation en vez de mandar al cliente a la consola de AWS.
- **Multi-tenant en una sola instancia**: para vender barato a muchos clientes
  chicos, un solo servidor grande con varios Virtual Hosts.

## Archivos

```
wp-oneclick-deploy/
├── README.md
├── cloudformation/
│   └── wordpress-stack.yaml          ← lo que lanza el botón "Launch Stack"
└── scripts/
    ├── bootstrap.sh                  ← toda la lógica de instalación (fuente única)
    ├── publish.sh                    ← sube plantilla y bootstrap a S3 (correr tras cada cambio)
    └── hotfix-servidor-existente.sh  ← aplica SSL+respaldos a servidores ya desplegados
```

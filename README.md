# Despliegue de 1 clic — WordPress sobre OpenLiteSpeed en AWS

Lanza un sitio WordPress completo (OpenLiteSpeed + MariaDB + PHP 8.4 + SSL) en una
instancia EC2 nueva, sin tocar la terminal. Lo único que pone el cliente: su cuenta
de AWS, su dominio, y (si quiere DNS automático) su Hosted Zone de Route 53.

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
La instancia arranca y su UserData descarga scripts/bootstrap.sh desde este
repo y lo ejecuta automáticamente
        │
        ▼
bootstrap.sh instala todo: OLS, MariaDB, PHP, WordPress (vía WP-CLI),
firewall, DNS en Route 53 (si aplica), SSL con reintento automático,
y guarda las contraseñas generadas en AWS Secrets Manager
        │
        ▼
Sitio en https://tudominio.com (5–15 min, según DNS)
```

## 1. Publica este repo en GitHub

Sube esta carpeta tal cual a un repo (puede ser privado si vas a usarlo solo tú,
pero el archivo `scripts/bootstrap.sh` debe poder leerse en crudo — si el repo
es privado necesitas usar un token en la URL o copiar el script a un bucket S3
público en su lugar).

Ya está apuntado a tu repo real:
```
https://raw.githubusercontent.com/kleverlh1/wp-oneclick-deploy/main/scripts/bootstrap.sh
```
(si algún día cambias el nombre del repo o de usuario, este es el valor que hay que actualizar en `cloudformation/wordpress-stack.yaml`)

## 2. Agrega el botón "Launch Stack" a este README

```markdown
[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=wp-oneclick-deploy&templateURL=https://raw.githubusercontent.com/kleverlh1/wp-oneclick-deploy/main/cloudformation/wordpress-stack.yaml)
```

Cambia `region=us-east-1` si tú o tus clientes usan otra región por defecto.
Esto es literalmente el "un clic": el cliente hace clic, AWS le abre el
formulario con los parámetros (dominio, correo, llave SSH, etc.), y al confirmar
se crea todo solo.

## 3. Lo que el cliente necesita tener antes de hacer clic

- Cuenta de AWS con permisos para crear EC2 / IAM / CloudFormation
- Un **Key Pair** de EC2 ya creado en la región que va a usar (para SSH de emergencia)
- Su dominio — si lo tiene en Route 53, puede pasar el `HostedZoneId` y el DNS
  se configura solo; si no, deberá apuntar manualmente el registro A a la
  Elastic IP que el stack le entrega en los "Outputs"

## 4. Qué NO está 100% garantizado en el primer intento (pruébalo antes de dárselo a un cliente real)

Este es un v1 funcional, no un producto probado en decenas de despliegues. Las
dos partes más nuevas y con más riesgo de necesitar un ajuste menor son:

- **`admpass.sh` automatizado con `expect`** (Paso 5 del script): si LiteSpeed
  cambia el texto exacto de sus prompts, el auto-responder puede fallar. El
  script no se detiene por esto, pero entrarías con un panel sin contraseña
  seteada — se corrige a mano en 30 segundos por SSH.
- **La edición directa del `httpd_config.conf`** para mapear el dominio al
  listener (Paso 6): asume que existe un bloque `listener Default { ... }`
  tal como lo trae OpenLiteSpeed de fábrica. Si algo no cuadra, se ve enseguida
  en `/var/log/wp-bootstrap.log` y se corrige a mano una vez desde el panel
  `:7080` (igual que en la guía manual original).

Recomendación: lanza el stack una vez tú mismo con un dominio de prueba,
revisa `/var/log/wp-bootstrap.log` de principio a fin, y ajusta lo que haga
falta en `bootstrap.sh` antes de ofrecérselo a un cliente.

## 5. Ideas para una v2 (cuando esto ya esté probado y quieras escalarlo)

- **AMI pre-construida con Packer**: instalar OLS/MariaDB/PHP una sola vez en
  una imagen dorada, para que el arranque de cada cliente tome ~1 minuto en
  vez de 5–10 (solo quedaría por hacer la parte específica del dominio).
  Te lo puedo armar cuando quieras.
- **Panel propio de auto-servicio**: un formulario web simple (podría ser una
  app tuya) que llame a la API de CloudFormation en vez de mandar al cliente a
  la consola de AWS — así tu marca queda al frente y no la de AWS.
- **Multi-tenant en una sola instancia**: si vas a vender esto barato a muchos
  clientes chicos, podría convenir un solo servidor grande con varios Virtual
  Hosts en vez de una instancia EC2 por cliente.

## Archivos

```
tiendasplanet-deploy/
├── README.md
├── cloudformation/
│   └── wordpress-stack.yaml   ← lo que lanza el botón "Launch Stack"
└── scripts/
    └── bootstrap.sh           ← toda la lógica de instalación (fuente única)
```

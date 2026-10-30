# Motum Digital Repository — integración con Supabase

Este paquete adapta el HTML actual para usar Supabase Auth, Database y Storage, conservando la interfaz visual existente.

## Qué contiene

- `index.html`: la interfaz actual con el acceso de Google conectado a la capa Supabase.
- `supabase-integration.js`: conexión del navegador con Supabase y operaciones de usuarios, roles, departamentos, plantillas, contenidos, notificaciones e historial.
- `supabase/migrations/20261030_motum_platform_integration.sql`: columnas y catálogo de categorías que necesita la aplicación.
- `supabase/migrations/20261031_motum_permissions_avatars.sql`: permisos por rol, políticas RLS y buckets privados `plantillas` y `avatars`.
- `supabase/functions/admin-invite-user/index.ts`: función de servidor para crear o reutilizar una cuenta Auth y asignarle rol/departamento sin exponer la clave privada en el navegador.

> Este paquete está preparado, pero todavía no está conectado a tu proyecto real: debes colocar tu Project URL y Publishable Key, ejecutar las migraciones y desplegar la función. No se ha accedido directamente a tu cuenta de Supabase ni a tu repositorio remoto.

---

## Paso 1. Haz una copia del repositorio

Antes de reemplazar archivos, crea una rama de prueba en GitHub, por ejemplo `integracion-supabase`, o descarga una copia de seguridad del repositorio actual.

Copia estos elementos del paquete a la raíz publicada de GitHub Pages:

```text
index.html
supabase-integration.js
supabase/
  migrations/
  functions/
```

`index.html` y `supabase-integration.js` deben quedar en la misma carpeta. Si GitHub Pages publica desde `/docs`, coloca ambos ahí y conserva la carpeta `supabase` en el repositorio.

## Paso 2. Ejecuta las dos migraciones SQL

En Supabase abre **SQL Editor → New Query**.

Ejecuta los archivos en este orden:

1. `supabase/migrations/20261030_motum_platform_integration.sql`
2. `supabase/migrations/20261031_motum_permissions_avatars.sql`

Estos dos archivos son complementarios a las 13 tablas base que ya creaste. No vuelvas a ejecutar el script original de creación de tablas si ya existen.

Las migraciones agregan campos que utiliza la aplicación, crean la tabla `categorias`, afinan permisos y crean los buckets privados `plantillas` y `avatars` con sus políticas.

## Paso 3. Configura las dos claves públicas del navegador

El archivo `supabase-integration.js` ya viene configurado con el Project URL y la Publishable Key que proporcionaste. Se normalizó el URL quitando `/rest/v1/`, porque el cliente de Supabase recibe la URL base del proyecto.

No pegues en este archivo una Secret Key ni una clave `service_role`. El HTML y el JavaScript son públicos al estar en GitHub Pages. La Publishable Key está diseñada para uso en frontend; la protección de los datos depende de las políticas RLS y de las funciones seguras del servidor.

## Paso 4. Habilita Google en Supabase Auth

1. En Supabase abre **Authentication → Sign In / Providers → Google**.
2. Activa Google y registra el Client ID y Client Secret que obtienes de Google Cloud Console.
3. En la configuración de Google OAuth agrega como URI de redirección autorizada el callback que muestra Supabase. El formato habitual es:

```text
https://TU_PROJECT_REF.supabase.co/auth/v1/callback
```

4. En **Authentication → URL Configuration**, registra como Site URL la dirección de tu GitHub Pages.
5. Agrega también la URL exacta de tu página a las Redirect URLs permitidas, por ejemplo:

```text
https://TU_USUARIO.github.io/TU_REPOSITORIO/
```

Usa la dirección real de tu repositorio, incluido el nombre del repositorio cuando GitHub Pages lo requiera.

La restricción `@tecnomotum.com` también se valida en el código después del inicio de sesión. El parámetro `hd` enviado a Google es solo una sugerencia de dominio; la validación efectiva la realiza la aplicación.

## Paso 5. Publica la función segura para altas de usuarios

El panel no crea usuarios nuevos directamente desde el navegador. Invoca la Edge Function `admin-invite-user`, que verifica que quien solicita el alta tenga rol Administrador y utiliza una clave privada únicamente en el servidor.

Puedes desplegarla con Supabase CLI o directamente desde el Dashboard. **Opción más sencilla, desde el Dashboard:** abre Edge Functions → Deploy a new function → Via Editor; nombra la función `admin-invite-user`, reemplaza el código de ejemplo por el contenido completo de `supabase/functions/admin-invite-user/index.ts` y pulsa Deploy function. Después entra a Edge Function Secrets y agrega `MOTUM_SUPABASE_SECRET_KEY` con el valor de tu Secret Key del proyecto.

**Opción con Supabase CLI:** necesitas Supabase CLI en tu computadora. Ejecuta desde la carpeta raíz del proyecto:

```bash
supabase login
supabase link --project-ref TU_PROJECT_REF
supabase secrets set MOTUM_SUPABASE_SECRET_KEY=TU_SECRET_KEY --project-ref TU_PROJECT_REF
supabase functions deploy admin-invite-user --project-ref TU_PROJECT_REF
```

Obtén `TU_SECRET_KEY` en **Project Settings → API Keys**. Es la clave privada del proyecto (`sb_secret_...`, o la clave `service_role` heredada si tu proyecto todavía muestra esa opción). Guárdala como secreto de Edge Functions; nunca la pongas en `index.html`, `supabase-integration.js`, ni en otro archivo público.

Supabase proporciona `SUPABASE_URL` y `SUPABASE_ANON_KEY` al entorno de Edge Functions. Si el proyecto no las muestra como variables disponibles, agrégalas también como secretos desde el Dashboard.

Importante: no uses el nombre `SUPABASE_SECRET_KEY` para tu secreto personalizado: Supabase reserva el prefijo `SUPABASE_` para variables administradas por la plataforma. El nombre correcto para esta función es `MOTUM_SUPABASE_SECRET_KEY`.

La función crea cuentas sin contraseña para mantener Google como único método de acceso, o reutiliza la cuenta Auth si ya existe. Supabase puede vincular una identidad OAuth verificada cuando coincide con el correo de la cuenta existente. La función no envía una invitación de contraseña.

## Paso 6. Asigna tu primera cuenta como Administrador

Si tu perfil ya existe en `perfiles`, no dupliques el registro.

1. Abre la plataforma ya configurada e inicia sesión con tu Google corporativo.
2. Si todavía no tienes un rol, la aplicación cerrará la sesión y mostrará el aviso correspondiente. Esto es esperado en el primer acceso.
3. En Supabase abre **Table Editor → perfiles** y copia el `id` de tu correo.
4. Abre **Table Editor → roles** y copia el `id` del rol `Administrador`.
5. Abre **Table Editor → usuario_roles → Insert row** y registra:
   - `usuario_id`: el UUID de tu fila en `perfiles`.
   - `rol_id`: el UUID del rol `Administrador`.
   - `asignado_por`: tu propio UUID.
6. Guarda y vuelve a iniciar sesión con Google.

El administrador no necesita pertenecer a un departamento. Después podrá crear los departamentos desde el panel y administrar usuarios.

## Paso 7. Crea departamentos y usuarios desde la herramienta

1. Entra al panel de Administración.
2. Crea primero los departamentos que utilizarás.
3. En el módulo Usuarios, crea cada usuario con nombre, correo corporativo, teléfono, rol y departamento.
4. La función `admin-invite-user` crea o reutiliza su cuenta Auth y registra su perfil, rol y departamento.
5. Cada persona ingresa desde **Continuar con Google** utilizando exactamente el correo corporativo autorizado.

Los roles `Usuario` y `Monitorista` tienen permisos de consulta; `Editor` puede crear y editar contenidos, pero no publicarlos. El rol `Administrador` conserva la administración completa.

## Paso 8. Comprueba el funcionamiento antes de publicar en la rama principal

Prueba con una cuenta Administrador y otra cuenta de usuario:

- Inicio y cierre de sesión con Google.
- Consulta de departamentos y plantillas publicadas.
- Creación y edición de plantillas.
- Carga y descarga de archivos en Storage privado.
- Creación de contenido digital.
- Registro de notificaciones y persistencia de su resultado de envío.
- Registro de actividades en `historial_actividades`.
- Restricción de contenido por departamento y permisos RLS.

El envío de correos conserva el proxy HTTP que ya tenía tu HTML. Debe seguir configurado y operativo para que se envíen correos; Supabase almacena el historial de la notificación, pero no sustituye por sí solo ese servicio de correo.

## Notas importantes

- Los arreglos de ejemplo del HTML se limpian al iniciar y se reemplazan por los registros de Supabase después de autenticar al usuario. Los registros de ejemplo no se importan automáticamente a la base de datos.
- Las plantillas y contenidos se guardan en `public.plantillas`; los archivos se guardan en el bucket privado `plantillas`.
- Las fotografías de perfil se guardan en el bucket privado `avatars`.
- `perfiles.activo = false` bloquea el acceso, aunque el usuario conserve su cuenta en Supabase Auth.
- La aplicación solo permite correos `@tecnomotum.com`. Si tu dominio corporativo autorizado es diferente, debe cambiarse `CORPORATE_DOMAIN` en `supabase-integration.js` y la validación equivalente en la Edge Function.
- Los usuarios que existían solamente en la lista fija antigua o en Firebase no se migran automáticamente. Deben crearse/asignarse a Supabase Auth y a las tablas de perfil, rol y departamento.

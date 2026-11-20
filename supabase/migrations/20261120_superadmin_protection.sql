
-- =========================================================
-- MOTUM: SUPERADMINISTRADORA Y PROTECCION DEL ULTIMO ADMIN
-- Cuenta protegida: karlaramirez@tecnomotum.com
-- =========================================================

DO $$
DECLARE
  v_email CONSTANT text := 'karlaramirez@tecnomotum.com';
  v_user_id uuid;
  v_role_id uuid;
  v_role_count integer;
BEGIN
  SELECT u.id INTO v_user_id
  FROM auth.users AS u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No existe la cuenta de Karla en Supabase Auth.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.perfiles WHERE id = v_user_id
  ) THEN
    RAISE EXCEPTION 'Karla no tiene un perfil registrado.';
  END IF;

  SELECT count(*)::integer INTO v_role_count
  FROM public.roles
  WHERE lower(nombre) = 'administrador';

  IF v_role_count <> 1 THEN
    RAISE EXCEPTION 'Debe existir exactamente un rol Administrador.';
  END IF;

  SELECT id INTO v_role_id
  FROM public.roles
  WHERE lower(nombre) = 'administrador'
  LIMIT 1;

  UPDATE public.perfiles
  SET correo = v_email,
      activo = TRUE,
      updated_at = now()
  WHERE id = v_user_id;

  IF NOT EXISTS (
    SELECT 1
    FROM public.usuario_roles
    WHERE usuario_id = v_user_id
      AND rol_id = v_role_id
  ) THEN
    INSERT INTO public.usuario_roles
      (usuario_id, rol_id, asignado_por)
    VALUES
      (v_user_id, v_role_id, v_user_id);
  END IF;
END;
$$;

-- Superadministradora reconocida como administradora.
CREATE OR REPLACE FUNCTION public.es_administrador()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    EXISTS (
      SELECT 1
      FROM public.perfiles p
      WHERE p.id = (SELECT auth.uid())
        AND p.activo = TRUE
        AND lower(p.correo) = 'karlaramirez@tecnomotum.com'
    )
    OR
    EXISTS (
      SELECT 1
      FROM public.usuario_roles ur
      JOIN public.roles r ON r.id = ur.rol_id
      JOIN public.perfiles p ON p.id = ur.usuario_id
      WHERE ur.usuario_id = (SELECT auth.uid())
        AND lower(r.nombre) = 'administrador'
        AND p.activo = TRUE
    );
$$;

REVOKE ALL ON FUNCTION public.es_administrador() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.es_administrador() TO authenticated;

-- Proteccion de la cuenta y del ultimo administrador activo.
CREATE OR REPLACE FUNCTION public.proteger_perfil_superadministrador()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email CONSTANT text := 'karlaramirez@tecnomotum.com';
  v_role_id uuid;
  v_remaining bigint;
BEGIN
  IF TG_OP = 'UPDATE' THEN

    IF lower(coalesce(OLD.correo, '')) = v_email THEN
      IF NEW.id IS DISTINCT FROM OLD.id
         OR lower(coalesce(NEW.correo, '')) <> v_email
         OR NEW.activo IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'La cuenta Superadministradora esta protegida.';
      END IF;
    END IF;

    IF lower(coalesce(NEW.correo, '')) = v_email
       AND lower(coalesce(OLD.correo, '')) <> v_email THEN
      RAISE EXCEPTION 'El correo de Superadministradora esta reservado.';
    END IF;

    IF OLD.activo IS TRUE AND NEW.activo IS FALSE THEN
      PERFORM pg_advisory_xact_lock(59475211);

      SELECT id INTO v_role_id
      FROM public.roles
      WHERE lower(nombre) = 'administrador'
      LIMIT 1;

      IF v_role_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.usuario_roles
        WHERE usuario_id = OLD.id AND rol_id = v_role_id
      ) THEN
        SELECT count(DISTINCT p.id) INTO v_remaining
        FROM public.perfiles p
        JOIN public.usuario_roles ur ON ur.usuario_id = p.id
        WHERE ur.rol_id = v_role_id
          AND p.activo = TRUE
          AND p.id <> OLD.id;

        IF v_remaining = 0 THEN
          RAISE EXCEPTION 'No puedes desactivar al ultimo Administrador activo.';
        END IF;
      END IF;
    END IF;

    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN

    IF lower(coalesce(OLD.correo, '')) = v_email THEN
      RAISE EXCEPTION 'La cuenta Superadministradora no puede eliminarse.';
    END IF;

    IF OLD.activo IS TRUE THEN
      PERFORM pg_advisory_xact_lock(59475211);

      SELECT id INTO v_role_id
      FROM public.roles
      WHERE lower(nombre) = 'administrador'
      LIMIT 1;

      IF v_role_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.usuario_roles
        WHERE usuario_id = OLD.id AND rol_id = v_role_id
      ) THEN
        SELECT count(DISTINCT p.id) INTO v_remaining
        FROM public.perfiles p
        JOIN public.usuario_roles ur ON ur.usuario_id = p.id
        WHERE ur.rol_id = v_role_id
          AND p.activo = TRUE
          AND p.id <> OLD.id;

        IF v_remaining = 0 THEN
          RAISE EXCEPTION 'No puedes eliminar al ultimo Administrador activo.';
        END IF;
      END IF;
    END IF;

    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS proteger_perfil_superadmin_ultimo_admin
ON public.perfiles;

CREATE TRIGGER proteger_perfil_superadmin_ultimo_admin
BEFORE UPDATE OF activo, correo, id OR DELETE
ON public.perfiles
FOR EACH ROW
EXECUTE FUNCTION public.proteger_perfil_superadministrador();

-- Impedir retirar los roles de Karla y el ultimo rol Administrador.
CREATE OR REPLACE FUNCTION public.proteger_rol_superadministrador()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email text;
  v_active boolean;
  v_role_id uuid;
  v_remaining bigint;
BEGIN
  SELECT lower(p.correo), p.activo
  INTO v_email, v_active
  FROM public.perfiles p
  WHERE p.id = OLD.usuario_id;

  -- Durante una eliminacion CASCADE, el perfil ya no existe.
  -- La validacion principal se hizo en el trigger del perfil.
  IF NOT FOUND THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;

  IF v_email = 'karlaramirez@tecnomotum.com' THEN
    RAISE EXCEPTION 'No se pueden retirar los roles de la Superadministradora.';
  END IF;

  SELECT id INTO v_role_id
  FROM public.roles
  WHERE lower(nombre) = 'administrador'
  LIMIT 1;

  IF v_role_id IS NOT NULL
     AND OLD.rol_id = v_role_id
     AND v_active IS TRUE THEN

    PERFORM pg_advisory_xact_lock(59475211);

    SELECT count(DISTINCT p.id) INTO v_remaining
    FROM public.perfiles p
    JOIN public.usuario_roles ur ON ur.usuario_id = p.id
    WHERE ur.rol_id = v_role_id
      AND p.activo = TRUE
      AND p.id <> OLD.usuario_id;

    IF v_remaining = 0 THEN
      RAISE EXCEPTION 'No puedes retirar el rol del ultimo Administrador activo.';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS proteger_rol_superadmin_ultimo_admin
ON public.usuario_roles;

CREATE TRIGGER proteger_rol_superadmin_ultimo_admin
BEFORE UPDATE OF usuario_id, rol_id OR DELETE
ON public.usuario_roles
FOR EACH ROW
EXECUTE FUNCTION public.proteger_rol_superadministrador();


-- =========================================================
-- PROTECCION INTEGRAL DE LA CUENTA SUPERADMINISTRADORA
-- =========================================================

-- Impedir cambios en cualquier dato del perfil protegido.
CREATE OR REPLACE FUNCTION public.proteger_cambios_perfil_superadmin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email CONSTANT text := 'karlaramirez@tecnomotum.com';
BEGIN
  IF TG_OP = 'UPDATE' THEN

    IF LOWER(COALESCE(OLD.correo, '')) = v_email THEN
      IF NEW.id IS DISTINCT FROM OLD.id
         OR NEW.nombre_completo IS DISTINCT FROM OLD.nombre_completo
         OR NEW.correo IS DISTINCT FROM OLD.correo
         OR NEW.telefono IS DISTINCT FROM OLD.telefono
         OR NEW.activo IS DISTINCT FROM OLD.activo
         OR NEW.created_at IS DISTINCT FROM OLD.created_at
         OR NEW.updated_at IS DISTINCT FROM OLD.updated_at
         OR NEW.avatar_url IS DISTINCT FROM OLD.avatar_url THEN

        RAISE EXCEPTION
          'La cuenta Superadministradora no puede modificarse.';
      END IF;
    END IF;

    IF LOWER(COALESCE(NEW.correo, '')) = v_email
       AND LOWER(COALESCE(OLD.correo, '')) <> v_email THEN

      RAISE EXCEPTION
        'El correo de Superadministradora está reservado.';
    END IF;

    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN

    IF LOWER(COALESCE(OLD.correo, '')) = v_email THEN
      RAISE EXCEPTION
        'La cuenta Superadministradora no puede eliminarse.';
    END IF;

    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS proteger_cambios_perfil_superadmin
ON public.perfiles;

CREATE TRIGGER proteger_cambios_perfil_superadmin
BEFORE UPDATE OR DELETE
ON public.perfiles
FOR EACH ROW
EXECUTE FUNCTION public.proteger_cambios_perfil_superadmin();


-- Impedir eliminar o renombrar el rol Administrador.
CREATE OR REPLACE FUNCTION public.proteger_catalogo_rol_administrador()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN

  IF TG_OP = 'INSERT' THEN
    IF LOWER(COALESCE(NEW.nombre, '')) = 'administrador' THEN
      RAISE EXCEPTION
        'El nombre Administrador está reservado.';
    END IF;

    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN

    IF LOWER(COALESCE(OLD.nombre, '')) = 'administrador'
       AND LOWER(COALESCE(NEW.nombre, '')) <> 'administrador' THEN

      RAISE EXCEPTION
        'El rol Administrador no puede renombrarse.';
    END IF;

    IF LOWER(COALESCE(OLD.nombre, '')) <> 'administrador'
       AND LOWER(COALESCE(NEW.nombre, '')) = 'administrador' THEN

      RAISE EXCEPTION
        'El nombre Administrador está reservado.';
    END IF;

    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN

    IF LOWER(COALESCE(OLD.nombre, '')) = 'administrador' THEN
      RAISE EXCEPTION
        'El rol Administrador no puede eliminarse.';
    END IF;

    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS proteger_catalogo_rol_administrador
ON public.roles;

CREATE TRIGGER proteger_catalogo_rol_administrador
BEFORE INSERT OR UPDATE OR DELETE
ON public.roles
FOR EACH ROW
EXECUTE FUNCTION public.proteger_catalogo_rol_administrador();


-- Ajuste: proteger identidad y acceso, permitiendo actualizar
-- nombre, telefono y fotografia de la Superadministradora.
CREATE OR REPLACE FUNCTION public.proteger_cambios_perfil_superadmin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email CONSTANT text := 'karlaramirez@tecnomotum.com';
BEGIN
  IF TG_OP = 'UPDATE' THEN

    IF LOWER(COALESCE(OLD.correo, '')) = v_email THEN
      IF NEW.id IS DISTINCT FROM OLD.id
         OR LOWER(COALESCE(NEW.correo, '')) <> v_email
         OR NEW.activo IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION
          'La identidad y el acceso de la Superadministradora están protegidos.';
      END IF;
    END IF;

    IF LOWER(COALESCE(NEW.correo, '')) = v_email
       AND LOWER(COALESCE(OLD.correo, '')) <> v_email THEN
      RAISE EXCEPTION
        'El correo de Superadministradora está reservado.';
    END IF;

    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN

    IF LOWER(COALESCE(OLD.correo, '')) = v_email THEN
      RAISE EXCEPTION
        'La cuenta Superadministradora no puede eliminarse.';
    END IF;

    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;



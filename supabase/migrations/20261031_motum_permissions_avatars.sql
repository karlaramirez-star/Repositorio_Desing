-- Motum: permisos por rol, perfil y Storage privado.
-- Ejecutar DESPUÉS de 20261030_motum_platform_integration.sql.
-- Es idempotente: puede volver a ejecutarse sin duplicar políticas ni permisos.

ALTER TABLE public.perfiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- Crea los buckets privados si aún no existen.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('plantillas', 'plantillas', FALSE, 52428800, ARRAY['application/pdf','image/jpeg','image/png','image/webp','image/gif','video/mp4','application/zip','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.openxmlformats-officedocument.presentationml.presentation']),
  ('avatars', 'avatars', FALSE, 10485760, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = FALSE;

-- Función segura para consultar permisos del usuario autenticado.
CREATE OR REPLACE FUNCTION public.tiene_permiso(p_codigo TEXT)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuario_roles ur
    JOIN public.rol_permisos rp ON rp.rol_id = ur.rol_id
    JOIN public.permisos pe ON pe.id = rp.permiso_id
    JOIN public.perfiles pf ON pf.id = ur.usuario_id
    WHERE ur.usuario_id = (SELECT auth.uid())
      AND pf.activo = TRUE
      AND pe.codigo = p_codigo
  );
$$;
REVOKE ALL ON FUNCTION public.tiene_permiso(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tiene_permiso(TEXT) TO authenticated;

-- Catálogo de permisos utilizado por la aplicación.
INSERT INTO public.permisos (codigo, nombre, modulo) VALUES
  ('plantillas.publicar', 'Publicar plantillas', 'Plantillas'),
  ('contenido.ver', 'Consultar contenido digital', 'Contenido'),
  ('contenido.crear', 'Crear contenido digital', 'Contenido'),
  ('contenido.editar', 'Editar contenido digital', 'Contenido'),
  ('contenido.eliminar', 'Eliminar contenido digital', 'Contenido'),
  ('contenido.publicar', 'Publicar contenido digital', 'Contenido'),
  ('categorias.administrar', 'Administrar categorías', 'Categorías'),
  ('departamentos.administrar', 'Administrar departamentos', 'Departamentos'),
  ('adopcion.ver', 'Consultar métricas de adopción', 'Adopción')
ON CONFLICT (codigo) DO NOTHING;

-- Permisos iniciales de Editor, Usuario y Monitorista.
-- El Administrador recibe todos los permisos, incluidos los agregados arriba.
INSERT INTO public.rol_permisos (rol_id, permiso_id)
SELECT r.id, p.id
FROM public.roles r
JOIN public.permisos p ON p.codigo IN (
  'plantillas.ver','plantillas.crear','plantillas.editar',
  'contenido.ver','contenido.crear','contenido.editar'
)
WHERE LOWER(r.nombre) = 'editor'
ON CONFLICT DO NOTHING;

INSERT INTO public.rol_permisos (rol_id, permiso_id)
SELECT r.id, p.id
FROM public.roles r
JOIN public.permisos p ON p.codigo IN ('plantillas.ver','contenido.ver')
WHERE LOWER(r.nombre) IN ('usuario','monitorista')
ON CONFLICT DO NOTHING;

DELETE FROM public.rol_permisos rp
USING public.roles r, public.permisos p
WHERE rp.rol_id = r.id AND rp.permiso_id = p.id
  AND LOWER(r.nombre) IN ('usuario','monitorista')
  AND p.codigo = 'notificaciones.ver';

INSERT INTO public.rol_permisos (rol_id, permiso_id)
SELECT r.id, p.id
FROM public.roles r CROSS JOIN public.permisos p
WHERE LOWER(r.nombre) = 'administrador'
ON CONFLICT DO NOTHING;

-- Protege columnas sensibles del propio perfil: el usuario puede editar nombre,
-- teléfono y foto, pero no correo, UUID ni estado de habilitación.
CREATE OR REPLACE FUNCTION public.proteger_perfil_usuario()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.es_administrador() THEN
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.correo IS DISTINCT FROM OLD.correo
       OR NEW.activo IS DISTINCT FROM OLD.activo THEN
      RAISE EXCEPTION 'No tienes permiso para modificar el identificador, correo o estado de la cuenta.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS proteger_perfil_usuario_trigger ON public.perfiles;
CREATE TRIGGER proteger_perfil_usuario_trigger
BEFORE UPDATE ON public.perfiles
FOR EACH ROW EXECUTE FUNCTION public.proteger_perfil_usuario();

DROP POLICY IF EXISTS perfiles_actualizar_propio ON public.perfiles;
CREATE POLICY perfiles_actualizar_propio ON public.perfiles
FOR UPDATE TO authenticated
USING ((SELECT public.usuario_activo()) AND id = (SELECT auth.uid()))
WITH CHECK ((SELECT public.usuario_activo()) AND id = (SELECT auth.uid()));

-- Plantillas y contenido: lectura por departamento y permisos; los borradores
-- de un Editor solo son visibles para quien los creó.
DROP POLICY IF EXISTS plantillas_consulta ON public.plantillas;
DROP POLICY IF EXISTS plantillas_admin ON public.plantillas;
DROP POLICY IF EXISTS plantillas_insertar_con_permiso ON public.plantillas;
DROP POLICY IF EXISTS plantillas_actualizar_con_permiso ON public.plantillas;
DROP POLICY IF EXISTS plantillas_eliminar_con_permiso ON public.plantillas;

CREATE POLICY plantillas_consulta ON public.plantillas
FOR SELECT TO authenticated
USING (
  (SELECT public.usuario_activo())
  AND (
    (SELECT public.es_administrador())
    OR (
      (activo = TRUE AND estado = 'publicada')
      AND EXISTS (
        SELECT 1 FROM public.plantilla_departamentos pd
        JOIN public.usuario_departamentos ud ON ud.departamento_id = pd.departamento_id
        WHERE pd.plantilla_id = plantillas.id AND ud.usuario_id = (SELECT auth.uid())
      )
    )
    OR (
      creado_por = (SELECT auth.uid())
      AND (
        (tipo_registro = 'plantilla' AND (SELECT public.tiene_permiso('plantillas.ver')))
        OR (tipo_registro = 'contenido_digital' AND (SELECT public.tiene_permiso('contenido.ver')))
      )
    )
  )
);
CREATE POLICY plantillas_admin ON public.plantillas
FOR ALL TO authenticated
USING ((SELECT public.es_administrador()))
WITH CHECK ((SELECT public.es_administrador()));

CREATE POLICY plantillas_insertar_con_permiso ON public.plantillas
FOR INSERT TO authenticated
WITH CHECK (
  (SELECT public.usuario_activo())
  AND creado_por = (SELECT auth.uid())
  AND (
    (tipo_registro = 'plantilla' AND (SELECT public.tiene_permiso('plantillas.crear'))
      AND (estado <> 'publicada' OR (SELECT public.tiene_permiso('plantillas.publicar'))))
    OR
    (tipo_registro = 'contenido_digital' AND (SELECT public.tiene_permiso('contenido.crear'))
      AND (estado <> 'publicada' OR (SELECT public.tiene_permiso('contenido.publicar'))))
  )
);

CREATE POLICY plantillas_actualizar_con_permiso ON public.plantillas
FOR UPDATE TO authenticated
USING (
  (SELECT public.usuario_activo())
  AND creado_por = (SELECT auth.uid())
  AND (
    (tipo_registro = 'plantilla' AND (SELECT public.tiene_permiso('plantillas.editar')))
    OR (tipo_registro = 'contenido_digital' AND (SELECT public.tiene_permiso('contenido.editar')))
  )
)
WITH CHECK (
  (SELECT public.usuario_activo())
  AND creado_por = (SELECT auth.uid())
  AND (
    (tipo_registro = 'plantilla' AND (SELECT public.tiene_permiso('plantillas.editar'))
      AND (estado <> 'publicada' OR (SELECT public.tiene_permiso('plantillas.publicar'))))
    OR
    (tipo_registro = 'contenido_digital' AND (SELECT public.tiene_permiso('contenido.editar'))
      AND (estado <> 'publicada' OR (SELECT public.tiene_permiso('contenido.publicar'))))
  )
);

CREATE POLICY plantillas_eliminar_con_permiso ON public.plantillas
FOR DELETE TO authenticated
USING (
  (SELECT public.usuario_activo())
  AND creado_por = (SELECT auth.uid())
  AND (
    (tipo_registro = 'plantilla' AND (SELECT public.tiene_permiso('plantillas.eliminar')))
    OR (tipo_registro = 'contenido_digital' AND (SELECT public.tiene_permiso('contenido.eliminar')))
  )
);

-- Solo se pueden vincular plantillas a departamentos del propio usuario (salvo Admin).
DROP POLICY IF EXISTS plantilla_departamentos_admin ON public.plantilla_departamentos;
DROP POLICY IF EXISTS plantilla_departamentos_consulta ON public.plantilla_departamentos;
DROP POLICY IF EXISTS plantilla_departamentos_insertar_con_permiso ON public.plantilla_departamentos;
DROP POLICY IF EXISTS plantilla_departamentos_eliminar_con_permiso ON public.plantilla_departamentos;
CREATE POLICY plantilla_departamentos_consulta ON public.plantilla_departamentos
FOR SELECT TO authenticated
USING (
  (SELECT public.es_administrador())
  OR EXISTS (SELECT 1 FROM public.usuario_departamentos ud WHERE ud.usuario_id = (SELECT auth.uid()) AND ud.departamento_id = plantilla_departamentos.departamento_id)
  OR EXISTS (SELECT 1 FROM public.plantillas p WHERE p.id = plantilla_departamentos.plantilla_id AND p.creado_por = (SELECT auth.uid()))
);
CREATE POLICY plantilla_departamentos_admin ON public.plantilla_departamentos
FOR ALL TO authenticated
USING ((SELECT public.es_administrador()))
WITH CHECK ((SELECT public.es_administrador()));
CREATE POLICY plantilla_departamentos_insertar_con_permiso ON public.plantilla_departamentos
FOR INSERT TO authenticated
WITH CHECK (
  (SELECT public.usuario_activo())
  AND EXISTS (
    SELECT 1 FROM public.usuario_departamentos ud
    WHERE ud.usuario_id = (SELECT auth.uid()) AND ud.departamento_id = plantilla_departamentos.departamento_id
  )
  AND EXISTS (
    SELECT 1 FROM public.plantillas p
    WHERE p.id = plantilla_departamentos.plantilla_id
      AND p.creado_por = (SELECT auth.uid())
      AND ((p.tipo_registro = 'plantilla' AND (SELECT public.tiene_permiso('plantillas.crear')))
        OR (p.tipo_registro = 'contenido_digital' AND (SELECT public.tiene_permiso('contenido.crear'))))
  )
);
CREATE POLICY plantilla_departamentos_eliminar_con_permiso ON public.plantilla_departamentos
FOR DELETE TO authenticated
USING (
  (SELECT public.usuario_activo())
  AND EXISTS (
    SELECT 1 FROM public.usuario_departamentos ud
    WHERE ud.usuario_id = (SELECT auth.uid()) AND ud.departamento_id = plantilla_departamentos.departamento_id
  )
  AND EXISTS (
    SELECT 1 FROM public.plantillas p
    WHERE p.id = plantilla_departamentos.plantilla_id
      AND p.creado_por = (SELECT auth.uid())
      AND ((p.tipo_registro = 'plantilla' AND (SELECT public.tiene_permiso('plantillas.editar')))
        OR (p.tipo_registro = 'contenido_digital' AND (SELECT public.tiene_permiso('contenido.editar'))))
  )
);

-- Notification-to-department associations are visible only to the assigned departments or Admin.
DROP POLICY IF EXISTS notificacion_departamentos_consulta ON public.notificacion_departamentos;
CREATE POLICY notificacion_departamentos_consulta ON public.notificacion_departamentos
FOR SELECT TO authenticated
USING (
  (SELECT public.es_administrador())
  OR EXISTS (
    SELECT 1 FROM public.usuario_departamentos ud
    WHERE ud.usuario_id = (SELECT auth.uid())
      AND ud.departamento_id = notificacion_departamentos.departamento_id
  )
);

-- Bucket plantillas: private read, editor uploads only to records they own.
DROP POLICY IF EXISTS motum_plantillas_storage_read ON storage.objects;
DROP POLICY IF EXISTS motum_plantillas_storage_insert ON storage.objects;
DROP POLICY IF EXISTS motum_plantillas_storage_update ON storage.objects;
DROP POLICY IF EXISTS motum_plantillas_storage_delete ON storage.objects;
CREATE POLICY motum_plantillas_storage_read ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'plantillas'
  AND (SELECT public.usuario_activo())
  AND (
    (SELECT public.es_administrador())
    OR EXISTS (
      SELECT 1 FROM public.plantillas p
      WHERE p.id::TEXT = (storage.foldername(name))[1]
        AND p.creado_por = (SELECT auth.uid())
    )
    OR EXISTS (
      SELECT 1 FROM public.plantillas p
      JOIN public.plantilla_departamentos pd ON pd.plantilla_id = p.id
      JOIN public.usuario_departamentos ud ON ud.departamento_id = pd.departamento_id
      WHERE p.id::TEXT = (storage.foldername(name))[1]
        AND p.activo = TRUE AND p.estado = 'publicada'
        AND ud.usuario_id = (SELECT auth.uid())
    )
  )
);
CREATE POLICY motum_plantillas_storage_insert ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'plantillas' AND (SELECT public.usuario_activo())
  AND (
    (SELECT public.es_administrador())
    OR EXISTS (
      SELECT 1 FROM public.plantillas p
      WHERE p.id::TEXT = (storage.foldername(name))[1]
        AND p.creado_por = (SELECT auth.uid())
        AND ((p.tipo_registro = 'plantilla' AND (SELECT public.tiene_permiso('plantillas.crear')))
          OR (p.tipo_registro = 'contenido_digital' AND (SELECT public.tiene_permiso('contenido.crear'))))
    )
  )
);
CREATE POLICY motum_plantillas_storage_update ON storage.objects
FOR UPDATE TO authenticated
USING (
  bucket_id = 'plantillas' AND (SELECT public.usuario_activo())
  AND ((SELECT public.es_administrador()) OR EXISTS (
    SELECT 1 FROM public.plantillas p
    WHERE p.id::TEXT = (storage.foldername(name))[1]
      AND p.creado_por = (SELECT auth.uid())
      AND ((p.tipo_registro = 'plantilla' AND (SELECT public.tiene_permiso('plantillas.editar')))
        OR (p.tipo_registro = 'contenido_digital' AND (SELECT public.tiene_permiso('contenido.editar'))))
  ))
)
WITH CHECK (
  bucket_id = 'plantillas' AND (SELECT public.usuario_activo())
  AND ((SELECT public.es_administrador()) OR EXISTS (
    SELECT 1 FROM public.plantillas p
    WHERE p.id::TEXT = (storage.foldername(name))[1]
      AND p.creado_por = (SELECT auth.uid())
  ))
);
CREATE POLICY motum_plantillas_storage_delete ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'plantillas' AND (SELECT public.usuario_activo())
  AND ((SELECT public.es_administrador()) OR EXISTS (
    SELECT 1 FROM public.plantillas p
    WHERE p.id::TEXT = (storage.foldername(name))[1]
      AND p.creado_por = (SELECT auth.uid())
      AND ((p.tipo_registro = 'plantilla' AND (SELECT public.tiene_permiso('plantillas.eliminar')))
        OR (p.tipo_registro = 'contenido_digital' AND (SELECT public.tiene_permiso('contenido.eliminar'))))
  ))
);

-- Bucket avatars: each user can manage only their own folder; Admin can read all.
DROP POLICY IF EXISTS motum_avatars_read ON storage.objects;
DROP POLICY IF EXISTS motum_avatars_insert ON storage.objects;
DROP POLICY IF EXISTS motum_avatars_update ON storage.objects;
DROP POLICY IF EXISTS motum_avatars_delete ON storage.objects;
CREATE POLICY motum_avatars_read ON storage.objects
FOR SELECT TO authenticated
USING (bucket_id = 'avatars' AND (storage.foldername(name))[1] = (SELECT auth.uid())::TEXT);
CREATE POLICY motum_avatars_insert ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'avatars' AND (storage.foldername(name))[1] = (SELECT auth.uid())::TEXT);
CREATE POLICY motum_avatars_update ON storage.objects
FOR UPDATE TO authenticated
USING (bucket_id = 'avatars' AND (storage.foldername(name))[1] = (SELECT auth.uid())::TEXT)
WITH CHECK (bucket_id = 'avatars' AND (storage.foldername(name))[1] = (SELECT auth.uid())::TEXT);
CREATE POLICY motum_avatars_delete ON storage.objects
FOR DELETE TO authenticated
USING (bucket_id = 'avatars' AND (storage.foldername(name))[1] = (SELECT auth.uid())::TEXT);

GRANT EXECUTE ON FUNCTION public.tiene_permiso(TEXT) TO authenticated;

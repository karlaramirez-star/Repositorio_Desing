-- Motum platform integration migration
-- Run in Supabase SQL Editor AFTER the original 13 tables have been created.
-- Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE and drops named policies first.

-- 1) Extend the existing templates table so it can also store digital content metadata.
ALTER TABLE public.plantillas
  ADD COLUMN IF NOT EXISTS tipo_registro TEXT NOT NULL DEFAULT 'plantilla',
  ADD COLUMN IF NOT EXISTS categoria TEXT,
  ADD COLUMN IF NOT EXISTS url_canva TEXT,
  ADD COLUMN IF NOT EXISTS url_drive TEXT,
  ADD COLUMN IF NOT EXISTS preview_url TEXT,
  ADD COLUMN IF NOT EXISTS tamano TEXT,
  ADD COLUMN IF NOT EXISTS activo BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE public.plantillas
  DROP CONSTRAINT IF EXISTS plantillas_tipo_registro_check;
ALTER TABLE public.plantillas
  ADD CONSTRAINT plantillas_tipo_registro_check
  CHECK (tipo_registro IN ('plantilla', 'contenido_digital'));

-- 2) Persist notification delivery details (the original table stores the message basics).
ALTER TABLE public.notificaciones
  ADD COLUMN IF NOT EXISTS destinatarios JSONB NOT NULL DEFAULT '[]'::JSONB,
  ADD COLUMN IF NOT EXISTS html_body TEXT,
  ADD COLUMN IF NOT EXISTS http_code INTEGER,
  ADD COLUMN IF NOT EXISTS api_mensaje TEXT,
  ADD COLUMN IF NOT EXISTS api_data JSONB;

-- 3) Persistent category catalogue for both modules.
CREATE TABLE IF NOT EXISTS public.categorias (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre TEXT NOT NULL,
  slug TEXT NOT NULL,
  modulo TEXT NOT NULL CHECK (modulo IN ('plantillas', 'digital', 'ambos')),
  departamento_id UUID REFERENCES public.departamentos(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (slug, modulo, departamento_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS categorias_slug_modulo_departamento_uniq
ON public.categorias (slug, modulo, COALESCE(departamento_id, '00000000-0000-0000-0000-000000000000'::UUID));

ALTER TABLE public.categorias ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.categorias TO authenticated;

INSERT INTO public.categorias (nombre, slug, modulo)
VALUES
  ('Reportes', 'reportes', 'plantillas'),
  ('Presentaciones', 'presentaciones', 'plantillas'),
  ('Formularios', 'formularios', 'plantillas'),
  ('Comunicados', 'comunicados', 'plantillas'),
  ('Dashboards', 'dashboards', 'plantillas'),
  ('Propuestas', 'propuestas', 'plantillas'),
  ('Contratos', 'contratos', 'plantillas'),
  ('Programas', 'programas', 'plantillas'),
  ('Seguridad Patrimonial', 'seguridad', 'digital'),
  ('Academy', 'academy', 'digital'),
  ('Actualizaciones', 'actualizaciones', 'digital'),
  ('Optimizaciones', 'optimizaciones', 'digital')
ON CONFLICT DO NOTHING;

-- 4) Helper functions. Both run with owner privileges only to inspect access-control tables.
CREATE OR REPLACE FUNCTION public.usuario_activo()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.perfiles p
    WHERE p.id = (SELECT auth.uid())
      AND p.activo = TRUE
  );
$$;

CREATE OR REPLACE FUNCTION public.es_administrador()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuario_roles ur
    JOIN public.roles r ON r.id = ur.rol_id
    JOIN public.perfiles p ON p.id = ur.usuario_id
    WHERE ur.usuario_id = (SELECT auth.uid())
      AND LOWER(r.nombre) = 'administrador'
      AND p.activo = TRUE
  );
$$;

REVOKE ALL ON FUNCTION public.usuario_activo() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.es_administrador() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.usuario_activo() TO authenticated;
GRANT EXECUTE ON FUNCTION public.es_administrador() TO authenticated;

-- 5) Replace initial policies with active-user-aware policies.
-- Profiles
DROP POLICY IF EXISTS perfiles_consulta ON public.perfiles;
DROP POLICY IF EXISTS perfiles_admin ON public.perfiles;
CREATE POLICY perfiles_consulta ON public.perfiles
  FOR SELECT TO authenticated
  USING ((SELECT public.usuario_activo()) AND (id = (SELECT auth.uid()) OR (SELECT public.es_administrador())));
CREATE POLICY perfiles_admin ON public.perfiles
  FOR ALL TO authenticated
  USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

-- Roles and departments
DROP POLICY IF EXISTS roles_consulta ON public.roles;
DROP POLICY IF EXISTS roles_admin ON public.roles;
CREATE POLICY roles_consulta ON public.roles
  FOR SELECT TO authenticated USING ((SELECT public.usuario_activo()));
CREATE POLICY roles_admin ON public.roles
  FOR ALL TO authenticated USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

DROP POLICY IF EXISTS departamentos_consulta ON public.departamentos;
DROP POLICY IF EXISTS departamentos_admin ON public.departamentos;
CREATE POLICY departamentos_consulta ON public.departamentos
  FOR SELECT TO authenticated USING ((SELECT public.usuario_activo()));
CREATE POLICY departamentos_admin ON public.departamentos
  FOR ALL TO authenticated USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

-- User-role and user-department joins
DROP POLICY IF EXISTS usuario_roles_consulta ON public.usuario_roles;
DROP POLICY IF EXISTS usuario_roles_admin ON public.usuario_roles;
CREATE POLICY usuario_roles_consulta ON public.usuario_roles
  FOR SELECT TO authenticated
  USING ((SELECT public.usuario_activo()) AND (usuario_id = (SELECT auth.uid()) OR (SELECT public.es_administrador())));
CREATE POLICY usuario_roles_admin ON public.usuario_roles
  FOR ALL TO authenticated USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

DROP POLICY IF EXISTS usuario_departamentos_consulta ON public.usuario_departamentos;
DROP POLICY IF EXISTS usuario_departamentos_admin ON public.usuario_departamentos;
CREATE POLICY usuario_departamentos_consulta ON public.usuario_departamentos
  FOR SELECT TO authenticated
  USING ((SELECT public.usuario_activo()) AND (usuario_id = (SELECT auth.uid()) OR (SELECT public.es_administrador())));
CREATE POLICY usuario_departamentos_admin ON public.usuario_departamentos
  FOR ALL TO authenticated USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

-- Permission catalog and role-permission joins
DROP POLICY IF EXISTS permisos_consulta ON public.permisos;
DROP POLICY IF EXISTS permisos_admin ON public.permisos;
CREATE POLICY permisos_consulta ON public.permisos
  FOR SELECT TO authenticated USING ((SELECT public.usuario_activo()));
CREATE POLICY permisos_admin ON public.permisos
  FOR ALL TO authenticated USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

DROP POLICY IF EXISTS rol_permisos_consulta ON public.rol_permisos;
DROP POLICY IF EXISTS rol_permisos_admin ON public.rol_permisos;
CREATE POLICY rol_permisos_consulta ON public.rol_permisos
  FOR SELECT TO authenticated USING ((SELECT public.usuario_activo()));
CREATE POLICY rol_permisos_admin ON public.rol_permisos
  FOR ALL TO authenticated USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

-- Templates: ordinary users only see active, published rows linked to their department.
DROP POLICY IF EXISTS plantillas_consulta ON public.plantillas;
DROP POLICY IF EXISTS plantillas_admin ON public.plantillas;
CREATE POLICY plantillas_consulta ON public.plantillas
  FOR SELECT TO authenticated
  USING (
    (SELECT public.usuario_activo())
    AND (
      (SELECT public.es_administrador())
      OR (
        activo = TRUE
        AND estado = 'publicada'
        AND EXISTS (
          SELECT 1
          FROM public.plantilla_departamentos pd
          JOIN public.usuario_departamentos ud
            ON ud.departamento_id = pd.departamento_id
          WHERE pd.plantilla_id = plantillas.id
            AND ud.usuario_id = (SELECT auth.uid())
        )
      )
    )
  );
CREATE POLICY plantillas_admin ON public.plantillas
  FOR ALL TO authenticated
  USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

DROP POLICY IF EXISTS plantilla_departamentos_consulta ON public.plantilla_departamentos;
DROP POLICY IF EXISTS plantilla_departamentos_admin ON public.plantilla_departamentos;
CREATE POLICY plantilla_departamentos_consulta ON public.plantilla_departamentos
  FOR SELECT TO authenticated USING ((SELECT public.usuario_activo()));
CREATE POLICY plantilla_departamentos_admin ON public.plantilla_departamentos
  FOR ALL TO authenticated USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

-- Notifications
DROP POLICY IF EXISTS notificaciones_consulta ON public.notificaciones;
DROP POLICY IF EXISTS notificaciones_admin ON public.notificaciones;
CREATE POLICY notificaciones_consulta ON public.notificaciones
  FOR SELECT TO authenticated
  USING (
    (SELECT public.usuario_activo())
    AND (
      (SELECT public.es_administrador())
      OR creado_por = (SELECT auth.uid())
      OR EXISTS (
        SELECT 1
        FROM public.notificacion_departamentos nd
        JOIN public.usuario_departamentos ud
          ON ud.departamento_id = nd.departamento_id
        WHERE nd.notificacion_id = notificaciones.id
          AND ud.usuario_id = (SELECT auth.uid())
      )
    )
  );
CREATE POLICY notificaciones_admin ON public.notificaciones
  FOR ALL TO authenticated
  USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

DROP POLICY IF EXISTS notificacion_departamentos_consulta ON public.notificacion_departamentos;
DROP POLICY IF EXISTS notificacion_departamentos_admin ON public.notificacion_departamentos;
CREATE POLICY notificacion_departamentos_consulta ON public.notificacion_departamentos
  FOR SELECT TO authenticated USING ((SELECT public.usuario_activo()));
CREATE POLICY notificacion_departamentos_admin ON public.notificacion_departamentos
  FOR ALL TO authenticated USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

DROP POLICY IF EXISTS notificacion_lecturas_consulta ON public.notificacion_lecturas;
DROP POLICY IF EXISTS notificacion_lecturas_insertar ON public.notificacion_lecturas;
DROP POLICY IF EXISTS notificacion_lecturas_actualizar ON public.notificacion_lecturas;
DROP POLICY IF EXISTS notificacion_lecturas_admin ON public.notificacion_lecturas;
CREATE POLICY notificacion_lecturas_consulta ON public.notificacion_lecturas
  FOR SELECT TO authenticated
  USING ((SELECT public.usuario_activo()) AND (usuario_id = (SELECT auth.uid()) OR (SELECT public.es_administrador())));
CREATE POLICY notificacion_lecturas_insertar ON public.notificacion_lecturas
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.usuario_activo()) AND usuario_id = (SELECT auth.uid()));
CREATE POLICY notificacion_lecturas_actualizar ON public.notificacion_lecturas
  FOR UPDATE TO authenticated
  USING ((SELECT public.usuario_activo()) AND usuario_id = (SELECT auth.uid()))
  WITH CHECK ((SELECT public.usuario_activo()) AND usuario_id = (SELECT auth.uid()));
CREATE POLICY notificacion_lecturas_admin ON public.notificacion_lecturas
  FOR ALL TO authenticated
  USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

-- Activity log
DROP POLICY IF EXISTS historial_consulta ON public.historial_actividades;
DROP POLICY IF EXISTS historial_insertar ON public.historial_actividades;
CREATE POLICY historial_consulta ON public.historial_actividades
  FOR SELECT TO authenticated
  USING ((SELECT public.usuario_activo()) AND (usuario_id = (SELECT auth.uid()) OR (SELECT public.es_administrador())));
CREATE POLICY historial_insertar ON public.historial_actividades
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.usuario_activo()) AND (usuario_id = (SELECT auth.uid()) OR (SELECT public.es_administrador())));

-- Category catalogue
DROP POLICY IF EXISTS categorias_consulta ON public.categorias;
DROP POLICY IF EXISTS categorias_admin ON public.categorias;
CREATE POLICY categorias_consulta ON public.categorias
  FOR SELECT TO authenticated USING ((SELECT public.usuario_activo()));
CREATE POLICY categorias_admin ON public.categorias
  FOR ALL TO authenticated USING ((SELECT public.es_administrador()))
  WITH CHECK ((SELECT public.es_administrador()));

-- 6) Keep the table grants aligned with the browser application's CRUD operations.
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.perfiles,
  public.roles,
  public.departamentos,
  public.usuario_roles,
  public.usuario_departamentos,
  public.permisos,
  public.rol_permisos,
  public.plantillas,
  public.plantilla_departamentos,
  public.notificaciones,
  public.notificacion_departamentos,
  public.notificacion_lecturas,
  public.categorias
TO authenticated;
GRANT SELECT, INSERT ON public.historial_actividades TO authenticated;

-- Note: this migration intentionally does not expose the Supabase service-role key
-- to the browser. New Auth users are invited through the Edge Function in this package.

-- 7) Ensure global (NULL-department) categories are idempotent on re-run.
CREATE UNIQUE INDEX IF NOT EXISTS categorias_slug_modulo_departamento_uniq
ON public.categorias (slug, modulo, COALESCE(departamento_id, '00000000-0000-0000-0000-000000000000'::UUID));

-- 8) Private Storage policies. Create the private bucket named 'plantillas' in Storage first.
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
      SELECT 1
      FROM public.plantillas p
      JOIN public.plantilla_departamentos pd ON pd.plantilla_id = p.id
      JOIN public.usuario_departamentos ud ON ud.departamento_id = pd.departamento_id
      WHERE p.id::TEXT = (storage.foldername(name))[1]
        AND p.tipo_registro IN ('plantilla','contenido_digital')
        AND p.activo = TRUE
        AND p.estado = 'publicada'
        AND ud.usuario_id = (SELECT auth.uid())
    )
  )
);

CREATE POLICY motum_plantillas_storage_insert ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'plantillas' AND (SELECT public.es_administrador()));

CREATE POLICY motum_plantillas_storage_update ON storage.objects
FOR UPDATE TO authenticated
USING (bucket_id = 'plantillas' AND (SELECT public.es_administrador()))
WITH CHECK (bucket_id = 'plantillas' AND (SELECT public.es_administrador()));

CREATE POLICY motum_plantillas_storage_delete ON storage.objects
FOR DELETE TO authenticated
USING (bucket_id = 'plantillas' AND (SELECT public.es_administrador()));

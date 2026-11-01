-- Motum Digital Repository
-- Medicion de duracion real de sesiones de usuario
-- Migracion no destructiva: crea una tabla y funciones nuevas.
-- No modifica usuarios, roles, departamentos ni el historial existente.

BEGIN;

CREATE TABLE IF NOT EXISTS public.sesiones_usuario (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES public.perfiles(id) ON DELETE CASCADE,
  clave_sesion UUID NOT NULL,
  iniciada_en TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ultimo_latido TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  cerrada_en TIMESTAMPTZ,
  duracion_segundos INTEGER NOT NULL DEFAULT 0 CHECK (duracion_segundos >= 0),
  estado TEXT NOT NULL DEFAULT 'activa'
    CHECK (estado IN ('activa', 'cerrada')),
  motivo_cierre TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS sesiones_usuario_usuario_inicio_idx
  ON public.sesiones_usuario (usuario_id, iniciada_en DESC);

CREATE INDEX IF NOT EXISTS sesiones_usuario_estado_latido_idx
  ON public.sesiones_usuario (estado, ultimo_latido);

ALTER TABLE public.sesiones_usuario ENABLE ROW LEVEL SECURITY;

-- Cada usuario puede consultar sus propias sesiones; Administrador puede consultar todas.
DROP POLICY IF EXISTS sesiones_usuario_consulta ON public.sesiones_usuario;
CREATE POLICY sesiones_usuario_consulta
  ON public.sesiones_usuario
  FOR SELECT TO authenticated
  USING (
    (SELECT public.usuario_activo())
    AND (
      usuario_id = (SELECT auth.uid())
      OR (SELECT public.es_administrador())
    )
  );

-- El navegador no recibe permisos directos de escritura; toda escritura se hace
-- mediante las funciones RPC SECURITY DEFINER que validan auth.uid().
REVOKE ALL ON TABLE public.sesiones_usuario FROM anon, authenticated;
GRANT SELECT ON TABLE public.sesiones_usuario TO authenticated;

CREATE OR REPLACE FUNCTION public.iniciar_sesion_usuario(p_clave_sesion UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_usuario UUID := auth.uid();
  v_sesion UUID;
BEGIN
  IF v_usuario IS NULL OR NOT public.usuario_activo() THEN
    RAISE EXCEPTION 'Usuario no autenticado o inactivo.';
  END IF;
  IF p_clave_sesion IS NULL THEN
    RAISE EXCEPTION 'La clave de sesion es obligatoria.';
  END IF;

  -- Si se recarga la pagina en la misma pestaña, reutiliza la sesion reciente.
  SELECT s.id INTO v_sesion
  FROM public.sesiones_usuario s
  WHERE s.usuario_id = v_usuario
    AND s.clave_sesion = p_clave_sesion
    AND s.estado = 'activa'
    AND s.ultimo_latido >= NOW() - INTERVAL '2 minutes'
  ORDER BY s.iniciada_en DESC
  LIMIT 1;

  IF v_sesion IS NOT NULL THEN
    UPDATE public.sesiones_usuario
      SET ultimo_latido = NOW()
      WHERE id = v_sesion;
    RETURN v_sesion;
  END IF;

  -- Cierra sesiones abandonadas (sin latidos recientes) sin atribuirles tiempo adicional.
  UPDATE public.sesiones_usuario
  SET estado = 'cerrada',
      cerrada_en = COALESCE(cerrada_en, ultimo_latido),
      motivo_cierre = COALESCE(motivo_cierre, 'sesion_abandonada')
  WHERE usuario_id = v_usuario
    AND estado = 'activa'
    AND ultimo_latido < NOW() - INTERVAL '2 minutes';

  INSERT INTO public.sesiones_usuario (usuario_id, clave_sesion)
  VALUES (v_usuario, p_clave_sesion)
  RETURNING id INTO v_sesion;

  RETURN v_sesion;
END;
$$;

CREATE OR REPLACE FUNCTION public.registrar_latido_sesion(
  p_sesion_id UUID,
  p_segundos INTEGER DEFAULT 60
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_total INTEGER;
  v_segundos INTEGER := GREATEST(0, LEAST(COALESCE(p_segundos, 0), 75));
BEGIN
  IF auth.uid() IS NULL OR NOT public.usuario_activo() THEN
    RAISE EXCEPTION 'Usuario no autenticado o inactivo.';
  END IF;

  UPDATE public.sesiones_usuario
  SET duracion_segundos = duracion_segundos + v_segundos,
      ultimo_latido = NOW()
  WHERE id = p_sesion_id
    AND usuario_id = auth.uid()
    AND estado = 'activa'
  RETURNING duracion_segundos INTO v_total;

  -- -1 indica que la sesion ya no esta activa o no pertenece al usuario.
  RETURN COALESCE(v_total, -1);
END;
$$;

CREATE OR REPLACE FUNCTION public.cerrar_sesion_usuario(
  p_sesion_id UUID,
  p_segundos_finales INTEGER DEFAULT 0,
  p_motivo TEXT DEFAULT 'cierre_sesion'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_total INTEGER;
  v_segundos INTEGER := GREATEST(0, LEAST(COALESCE(p_segundos_finales, 0), 75));
BEGIN
  IF auth.uid() IS NULL OR NOT public.usuario_activo() THEN
    RAISE EXCEPTION 'Usuario no autenticado o inactivo.';
  END IF;

  UPDATE public.sesiones_usuario
  SET duracion_segundos = duracion_segundos + v_segundos,
      ultimo_latido = NOW(),
      cerrada_en = NOW(),
      estado = 'cerrada',
      motivo_cierre = LEFT(COALESCE(NULLIF(p_motivo, ''), 'cierre_sesion'), 80)
  WHERE id = p_sesion_id
    AND usuario_id = auth.uid()
    AND estado = 'activa'
  RETURNING duracion_segundos INTO v_total;

  RETURN COALESCE(v_total, -1);
END;
$$;

REVOKE ALL ON FUNCTION public.iniciar_sesion_usuario(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.registrar_latido_sesion(UUID, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cerrar_sesion_usuario(UUID, INTEGER, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.iniciar_sesion_usuario(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_latido_sesion(UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cerrar_sesion_usuario(UUID, INTEGER, TEXT) TO authenticated;

COMMIT;

-- Validacion de estructura (ejecutar por separado si se desea):
-- SELECT column_name, data_type
-- FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'sesiones_usuario'
-- ORDER BY ordinal_position;

-- MiEje Market Independiente
-- Persistencia de configuración de asistentes IA por negocio y plataforma.
-- IMPORTANTE: almacena instrucciones/configuración; no conecta por sí sola un proveedor IA.
-- BORRADOR: aplicar solo en un entorno de ensayo autorizado.

CREATE TABLE IF NOT EXISTS public.business_ai_settings (
  business_id uuid PRIMARY KEY REFERENCES public.businesses(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT false,
  assistant_name text NOT NULL DEFAULT 'Asistente del negocio'
    CHECK (char_length(btrim(assistant_name)) BETWEEN 2 AND 120),
  instructions text NOT NULL DEFAULT ''
    CHECK (char_length(instructions) <= 5000),
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.business_ai_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.business_ai_settings FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT (business_id, enabled, assistant_name, instructions, updated_at)
  ON TABLE public.business_ai_settings TO authenticated;
GRANT INSERT (business_id, enabled, assistant_name, instructions, updated_by, updated_at)
  ON TABLE public.business_ai_settings TO authenticated;
GRANT UPDATE (enabled, assistant_name, instructions, updated_by, updated_at)
  ON TABLE public.business_ai_settings TO authenticated;

DROP POLICY IF EXISTS business_ai_settings_admin_select ON public.business_ai_settings;
CREATE POLICY business_ai_settings_admin_select
ON public.business_ai_settings
FOR SELECT TO authenticated
USING (
  private.business_is_active(business_id)
  AND private.has_business_role(business_id, ARRAY['business_admin']::text[])
);

DROP POLICY IF EXISTS business_ai_settings_admin_insert ON public.business_ai_settings;
CREATE POLICY business_ai_settings_admin_insert
ON public.business_ai_settings
FOR INSERT TO authenticated
WITH CHECK (
  updated_by = (SELECT auth.uid())
  AND private.business_is_active(business_id)
  AND private.has_business_role(business_id, ARRAY['business_admin']::text[])
);

DROP POLICY IF EXISTS business_ai_settings_admin_update ON public.business_ai_settings;
CREATE POLICY business_ai_settings_admin_update
ON public.business_ai_settings
FOR UPDATE TO authenticated
USING (
  private.business_is_active(business_id)
  AND private.has_business_role(business_id, ARRAY['business_admin']::text[])
)
WITH CHECK (
  updated_by = (SELECT auth.uid())
  AND private.business_is_active(business_id)
  AND private.has_business_role(business_id, ARRAY['business_admin']::text[])
);

CREATE OR REPLACE FUNCTION private.audit_business_ai_settings_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    NEW.business_id,
    auth.uid(),
    CASE WHEN TG_OP = 'INSERT'
      THEN 'business.ai_settings_created'
      ELSE 'business.ai_settings_updated'
    END,
    'business_ai_settings',
    NEW.business_id::text,
    pg_catalog.jsonb_build_object(
      'enabled', NEW.enabled,
      'assistant_name', NEW.assistant_name,
      'instructions_changed', CASE WHEN TG_OP = 'INSERT' THEN true ELSE OLD.instructions IS DISTINCT FROM NEW.instructions END
    )
  );
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.audit_business_ai_settings_change() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS business_ai_settings_audit ON public.business_ai_settings;
CREATE TRIGGER business_ai_settings_audit
AFTER INSERT OR UPDATE ON public.business_ai_settings
FOR EACH ROW EXECUTE FUNCTION private.audit_business_ai_settings_change();

CREATE TABLE IF NOT EXISTS public.platform_ai_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id = true),
  enabled boolean NOT NULL DEFAULT false,
  assistant_name text NOT NULL DEFAULT 'Asistente general de MiEje Market'
    CHECK (char_length(btrim(assistant_name)) BETWEEN 2 AND 120),
  system_instructions text NOT NULL DEFAULT ''
    CHECK (char_length(system_instructions) <= 8000),
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.platform_ai_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.platform_ai_settings FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.platform_ai_settings TO service_role;

-- La configuración global no se consulta ni modifica desde Data API.
-- La Edge Function técnica exige propietario verificado y MFA AAL2.

-- PRUEBAS OBLIGATORIAS EN ENSAYO:
-- 1) Administrador A puede consultar/guardar la IA de A; no puede leer ni modificar B.
-- 2) Empleados, clientes y anon no pueden leer ni modificar business_ai_settings.
-- 3) El propietario técnico AAL2 puede consultar/guardar platform_ai_settings vía Edge.
-- 4) AAL1 y usuarios no propietarios no pueden consultar ni modificar la IA global.
-- 5) Las instrucciones y nombres respetan los límites de longitud.
-- 6) Guardar configuración no invoca ni habilita por sí solo un proveedor IA.


-- Actualizar la configuración global del asistente y su auditoría atómicamente.
-- Esta función solo guarda instrucciones/configuración; no llama a un proveedor IA.
CREATE OR REPLACE FUNCTION public.update_platform_ai_settings_transactional(
  p_enabled boolean,
  p_assistant_name text,
  p_system_instructions text,
  p_actor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_actor_role text;
  v_actor_blocked boolean;
  v_settings public.platform_ai_settings%ROWTYPE;
  v_assistant_name text := NULLIF(pg_catalog.btrim(p_assistant_name), '');
  v_instructions text := COALESCE(p_system_instructions, '');
BEGIN
  IF p_actor_id IS NULL
     OR p_enabled IS NULL
     OR v_assistant_name IS NULL
     OR pg_catalog.char_length(v_assistant_name) NOT BETWEEN 2 AND 120
     OR pg_catalog.char_length(v_instructions) > 8000 THEN
    RAISE EXCEPTION 'Datos de configuración de IA no válidos.'
      USING ERRCODE = '22023';
  END IF;

  SELECT p.platform_role, p.is_blocked
    INTO v_actor_role, v_actor_blocked
  FROM public.profiles AS p
  WHERE p.id = p_actor_id
  FOR SHARE;

  IF NOT FOUND OR v_actor_role IS DISTINCT FROM 'platform_owner'
     OR v_actor_blocked IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Actor técnico no autorizado.' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.platform_ai_settings (
    id, enabled, assistant_name, system_instructions, updated_by, updated_at
  ) VALUES (
    true, p_enabled, v_assistant_name, v_instructions,
    p_actor_id, pg_catalog.clock_timestamp()
  )
  ON CONFLICT (id) DO UPDATE SET
    enabled = EXCLUDED.enabled,
    assistant_name = EXCLUDED.assistant_name,
    system_instructions = EXCLUDED.system_instructions,
    updated_by = EXCLUDED.updated_by,
    updated_at = EXCLUDED.updated_at
  RETURNING * INTO v_settings;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    NULL, p_actor_id, 'platform.ai_settings_updated',
    'platform_ai_settings', NULL,
    pg_catalog.jsonb_build_object(
      'enabled', v_settings.enabled,
      'assistant_name', v_settings.assistant_name,
      'instructions_changed', true
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'settings', pg_catalog.jsonb_build_object(
      'enabled', v_settings.enabled,
      'assistant_name', v_settings.assistant_name,
      'system_instructions', v_settings.system_instructions,
      'updated_at', v_settings.updated_at
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.update_platform_ai_settings_transactional(boolean,text,text,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_platform_ai_settings_transactional(boolean,text,text,uuid)
  TO service_role;

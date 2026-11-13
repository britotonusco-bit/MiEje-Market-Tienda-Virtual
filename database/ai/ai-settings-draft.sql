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
      'instructions_changed', TG_OP = 'INSERT' OR OLD.instructions IS DISTINCT FROM NEW.instructions
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

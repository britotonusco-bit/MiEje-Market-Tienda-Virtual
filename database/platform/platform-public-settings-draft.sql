-- MiEje Market Independiente
-- BORRADOR: no ejecutar hasta revisar y aprobar la migración completa.
-- Configuración pública global de la plataforma; no representa datos de ningún negocio.
CREATE TABLE IF NOT EXISTS public.platform_public_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id = true),
  site_name text NOT NULL DEFAULT 'MiEje Market',
  site_description text NOT NULL DEFAULT '',
  logo_url text,
  hero_image_url text,
  support_whatsapp text,
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT platform_public_settings_site_name_length
    CHECK (char_length(btrim(site_name)) BETWEEN 2 AND 120),
  CONSTRAINT platform_public_settings_description_length
    CHECK (char_length(site_description) <= 2000),
  CONSTRAINT platform_public_settings_support_phone_format
    CHECK (support_whatsapp IS NULL OR support_whatsapp ~ '^[0-9]{10,18}$')
);

ALTER TABLE public.platform_public_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.platform_public_settings FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.platform_public_settings TO service_role;

COMMENT ON TABLE public.platform_public_settings IS
  'Configuración pública global de MiEje Market; se administra exclusivamente mediante Edge Functions autorizadas.';



-- Actualizar la configuración pública global y auditarla atómicamente.
CREATE OR REPLACE FUNCTION public.update_platform_public_settings_transactional(
  p_site_name text,
  p_site_description text,
  p_logo_url text,
  p_hero_image_url text,
  p_support_whatsapp text,
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
  v_settings public.platform_public_settings%ROWTYPE;
  v_site_name text := NULLIF(pg_catalog.btrim(p_site_name), '');
  v_site_description text := COALESCE(p_site_description, '');
  v_logo_url text := NULLIF(pg_catalog.btrim(p_logo_url), '');
  v_hero_image_url text := NULLIF(pg_catalog.btrim(p_hero_image_url), '');
  v_support_whatsapp text := NULLIF(pg_catalog.btrim(p_support_whatsapp), '');
BEGIN
  IF p_actor_id IS NULL
     OR v_site_name IS NULL OR pg_catalog.char_length(v_site_name) NOT BETWEEN 2 AND 120
     OR pg_catalog.char_length(v_site_description) > 2000
     OR pg_catalog.char_length(COALESCE(v_logo_url, '')) > 2048
     OR pg_catalog.char_length(COALESCE(v_hero_image_url, '')) > 2048
     OR (v_logo_url IS NOT NULL AND v_logo_url !~ '^https://')
     OR (v_hero_image_url IS NOT NULL AND v_hero_image_url !~ '^https://')
     OR (v_support_whatsapp IS NOT NULL AND v_support_whatsapp !~ '^[0-9]{10,18}$') THEN
    RAISE EXCEPTION 'Datos de configuración pública no válidos.'
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

  INSERT INTO public.platform_public_settings (
    id, site_name, site_description, logo_url, hero_image_url,
    support_whatsapp, updated_by, updated_at
  ) VALUES (
    true, v_site_name, v_site_description, v_logo_url, v_hero_image_url,
    v_support_whatsapp, p_actor_id, pg_catalog.clock_timestamp()
  )
  ON CONFLICT (id) DO UPDATE SET
    site_name = EXCLUDED.site_name,
    site_description = EXCLUDED.site_description,
    logo_url = EXCLUDED.logo_url,
    hero_image_url = EXCLUDED.hero_image_url,
    support_whatsapp = EXCLUDED.support_whatsapp,
    updated_by = EXCLUDED.updated_by,
    updated_at = EXCLUDED.updated_at
  RETURNING * INTO v_settings;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    NULL, p_actor_id, 'platform.public_settings_updated',
    'platform_settings', NULL,
    pg_catalog.jsonb_build_object(
      'site_name', v_settings.site_name,
      'logo_changed', v_settings.logo_url IS NOT NULL,
      'hero_image_changed', v_settings.hero_image_url IS NOT NULL,
      'support_updated', v_settings.support_whatsapp IS NOT NULL
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'settings', pg_catalog.jsonb_build_object(
      'site_name', v_settings.site_name,
      'site_description', v_settings.site_description,
      'logo_url', v_settings.logo_url,
      'hero_image_url', v_settings.hero_image_url,
      'support_whatsapp', v_settings.support_whatsapp,
      'updated_at', v_settings.updated_at
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.update_platform_public_settings_transactional(text,text,text,text,text,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_platform_public_settings_transactional(text,text,text,text,text,uuid)
  TO service_role;

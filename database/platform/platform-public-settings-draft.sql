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


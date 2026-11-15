-- MiEje Market Independiente
-- Guardado atómico de métodos de pago de un negocio.
-- BORRADOR: instalar después de business-admin-boundaries.sql y probar en staging.

CREATE OR REPLACE FUNCTION public.save_business_payment_methods(
  p_business_id uuid,
  p_methods jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_item jsonb;
  v_code text;
  v_name text;
  v_instructions text;
  v_old_id uuid;
  v_retained_ids uuid[] := ARRAY[]::uuid[];
  v_index integer := 0;
BEGIN
  IF auth.uid() IS NULL
     OR NOT private.business_is_active(p_business_id)
     OR NOT private.has_business_role(p_business_id, ARRAY['business_admin']::text[]) THEN
    RAISE EXCEPTION 'No tienes permiso para modificar los métodos de pago de este negocio.'
      USING ERRCODE = '42501';
  END IF;

  IF p_methods IS NULL
     OR pg_catalog.jsonb_typeof(p_methods) <> 'array'
     OR pg_catalog.jsonb_array_length(p_methods) < 1
     OR pg_catalog.jsonb_array_length(p_methods) > 20 THEN
    RAISE EXCEPTION 'Debes configurar entre 1 y 20 métodos de pago.';
  END IF;

  -- Serializa cambios simultáneos de configuración para el mismo negocio.
  PERFORM b.id
  FROM public.businesses AS b
  WHERE b.id = p_business_id
  FOR UPDATE;

  -- Validación completa antes de modificar filas.
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_methods) AS entry(value)
    WHERE pg_catalog.jsonb_typeof(value) <> 'object'
       OR pg_catalog.jsonb_typeof(value->'method_code') <> 'string'
       OR pg_catalog.jsonb_typeof(value->'display_name') <> 'string'
       OR COALESCE(pg_catalog.char_length(pg_catalog.btrim(value->>'display_name')), 0) < 2
       OR COALESCE(pg_catalog.char_length(pg_catalog.btrim(value->>'display_name')), 0) > 100
       OR COALESCE(value->>'method_code', '') NOT IN ('cash','transfer','card','other')
       OR (
         value ? 'public_instructions'
         AND value->'public_instructions' <> 'null'::jsonb
         AND (
           pg_catalog.jsonb_typeof(value->'public_instructions') <> 'string'
           OR pg_catalog.char_length(value->>'public_instructions') > 500
         )
       )
  ) THEN
    RAISE EXCEPTION 'Uno de los métodos de pago tiene datos inválidos.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_methods) AS entry(value)
    GROUP BY pg_catalog.lower(pg_catalog.btrim(value->>'display_name'))
    HAVING pg_catalog.count(*) > 1
  ) THEN
    RAISE EXCEPTION 'No repitas el nombre de un método de pago.';
  END IF;

  -- Bloquear las filas existentes en orden estable.
  PERFORM m.id
  FROM public.business_payment_methods AS m
  WHERE m.business_id = p_business_id
  ORDER BY m.id
  FOR UPDATE;

  FOR v_item IN
    SELECT entry.value
    FROM pg_catalog.jsonb_array_elements(p_methods) WITH ORDINALITY AS entry(value, ord)
    ORDER BY entry.ord
  LOOP
    v_code := pg_catalog.btrim(v_item->>'method_code');
    v_name := pg_catalog.btrim(v_item->>'display_name');
    v_instructions := NULLIF(pg_catalog.btrim(v_item->>'public_instructions'), '');

    -- Primero conservar el ID de la misma forma de pago; si fue renombrada,
    -- reutilizar otra fila del mismo código que aún no haya sido asignada.
    SELECT m.id
    INTO v_old_id
    FROM public.business_payment_methods AS m
    WHERE m.business_id = p_business_id
      AND m.method_code = v_code
      AND pg_catalog.lower(pg_catalog.btrim(m.display_name)) = pg_catalog.lower(v_name)
      AND NOT (m.id = ANY(v_retained_ids))
    ORDER BY m.is_enabled DESC, m.sort_order, m.id
    LIMIT 1
    FOR UPDATE;

    IF v_old_id IS NULL THEN
      SELECT m.id
      INTO v_old_id
      FROM public.business_payment_methods AS m
      WHERE m.business_id = p_business_id
        AND m.method_code = v_code
        AND NOT (m.id = ANY(v_retained_ids))
      ORDER BY m.is_enabled DESC, m.sort_order, m.id
      LIMIT 1
      FOR UPDATE;
    END IF;

    v_index := v_index + 1;

    IF v_old_id IS NULL THEN
      INSERT INTO public.business_payment_methods (
        business_id, method_code, display_name, public_instructions,
        is_enabled, sort_order
      )
      VALUES (
        p_business_id, v_code, v_name, v_instructions,
        true, v_index - 1
      )
      RETURNING id INTO v_old_id;
    ELSE
      UPDATE public.business_payment_methods
      SET method_code = v_code,
          display_name = v_name,
          public_instructions = v_instructions,
          is_enabled = true,
          sort_order = v_index - 1,
          updated_at = pg_catalog.now()
      WHERE id = v_old_id
        AND business_id = p_business_id;
    END IF;

    v_retained_ids := pg_catalog.array_append(v_retained_ids, v_old_id);
    v_old_id := NULL;
  END LOOP;

  -- Retirar métodos ausentes sin borrar sus IDs ni romper snapshots de pedidos.
  UPDATE public.business_payment_methods
  SET is_enabled = false,
      updated_at = pg_catalog.now()
  WHERE business_id = p_business_id
    AND is_enabled = true
    AND NOT (id = ANY(v_retained_ids));

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'saved_count', v_index
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.save_business_payment_methods(uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_business_payment_methods(uuid, jsonb)
  TO authenticated;

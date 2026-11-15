-- MiEje Market Independiente
-- Registro auditable de movimientos y ajustes seguros de inventario.
-- ESTADO: BORRADOR. No ejecutar en producción sin revisión y autorización.
--
-- Los movimientos se registran automáticamente cuando se crea un producto
-- o cambia su inventario. Los clientes autenticados no pueden insertar,
-- modificar ni borrar el historial directamente.

CREATE TABLE IF NOT EXISTS public.inventory_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL,
  product_id uuid NOT NULL,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  movement_type text NOT NULL CHECK (
    movement_type IN ('initial', 'adjustment', 'sale', 'cancellation_return')
  ),
  quantity_before integer NOT NULL CHECK (quantity_before >= 0),
  quantity_after integer NOT NULL CHECK (quantity_after >= 0),
  quantity_delta integer NOT NULL CHECK (quantity_delta <> 0),
  reason text NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 3 AND 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_movements_product_business_fk
    FOREIGN KEY (business_id, product_id)
    REFERENCES public.products (business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT inventory_movements_delta_check
    CHECK (quantity_delta = quantity_after - quantity_before)
);

-- Conservar la relación histórica entre una línea de pedido y su producto.
-- Los productos vendidos deben desactivarse, no borrarse: una cancelación posterior
-- necesita la referencia para restituir existencias y el historial debe seguir íntegro.
ALTER TABLE public.order_items
  DROP CONSTRAINT IF EXISTS order_items_product_id_fkey;
ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_product_id_fkey
  FOREIGN KEY (product_id)
  REFERENCES public.products(id)
  ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS inventory_movements_business_created_idx
  ON public.inventory_movements (business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS inventory_movements_product_created_idx
  ON public.inventory_movements (business_id, product_id, created_at DESC);

ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.inventory_movements FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.inventory_movements TO authenticated;

DROP POLICY IF EXISTS inventory_movements_admin_read
  ON public.inventory_movements;
CREATE POLICY inventory_movements_admin_read
ON public.inventory_movements
FOR SELECT
TO authenticated
USING (
  private.business_is_active(business_id)
  AND private.has_business_role(business_id, ARRAY['business_admin']::text[])
);

CREATE OR REPLACE FUNCTION private.log_product_inventory_movement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_before integer;
  v_after integer;
  v_reason text;
  v_type text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- No registrar un movimiento de cero unidades: la tabla exige delta distinto de cero.
    IF NEW.inventory = 0 THEN
      RETURN NEW;
    END IF;
    v_before := 0;
    v_after := NEW.inventory;
    v_reason := 'Inventario inicial';
  ELSE
    v_before := OLD.inventory;
    v_after := NEW.inventory;

    IF v_before IS NOT DISTINCT FROM v_after THEN
      RETURN NEW;
    END IF;

    v_reason := NULLIF(
      pg_catalog.btrim(
        pg_catalog.current_setting('app.inventory_movement_reason', true)
      ),
      ''
    );
    v_type := NULLIF(
      pg_catalog.current_setting('app.inventory_movement_type', true),
      ''
    );

    IF v_reason IS NULL THEN
      v_reason := 'Cambio de existencias (origen no especificado)';
    END IF;

    IF v_type IS NULL OR v_type NOT IN ('adjustment', 'sale', 'cancellation_return') THEN
      v_type := 'adjustment';
    END IF;
  END IF;

  INSERT INTO public.inventory_movements (
    business_id, product_id, actor_id, movement_type,
    quantity_before, quantity_after, quantity_delta, reason
  ) VALUES (
    NEW.business_id, NEW.id, auth.uid(),
    CASE WHEN TG_OP = 'INSERT' THEN 'initial' ELSE v_type END,
    v_before, v_after, v_after - v_before, v_reason
  );

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.log_product_inventory_movement()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS products_inventory_movement_insert
  ON public.products;
CREATE TRIGGER products_inventory_movement_insert
AFTER INSERT ON public.products
FOR EACH ROW
EXECUTE FUNCTION private.log_product_inventory_movement();

DROP TRIGGER IF EXISTS products_inventory_movement_update
  ON public.products;
CREATE TRIGGER products_inventory_movement_update
AFTER UPDATE OF inventory ON public.products
FOR EACH ROW
WHEN (OLD.inventory IS DISTINCT FROM NEW.inventory)
EXECUTE FUNCTION private.log_product_inventory_movement();

CREATE OR REPLACE FUNCTION public.adjust_business_inventory(
  p_business_id uuid,
  p_product_id uuid,
  p_expected_inventory integer,
  p_new_inventory integer,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_product public.products%ROWTYPE;
  v_reason text := pg_catalog.btrim(p_reason);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión.'
      USING ERRCODE = '42501';
  END IF;

  IF p_expected_inventory IS NULL OR p_expected_inventory < 0
     OR p_new_inventory IS NULL OR p_new_inventory < 0 THEN
    RAISE EXCEPTION 'Las existencias deben ser un número entero igual o mayor que cero.'
      USING ERRCODE = '22023';
  END IF;

  IF p_reason IS NULL
     OR pg_catalog.char_length(v_reason) < 3
     OR pg_catalog.char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'Indica un motivo de entre 3 y 500 caracteres.'
      USING ERRCODE = '22023';
  END IF;

  IF NOT private.business_is_active(p_business_id)
     OR NOT private.has_business_role(
       p_business_id, ARRAY['business_admin']::text[]
     ) THEN
    RAISE EXCEPTION 'Solo el administrador activo del negocio puede ajustar existencias.'
      USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id
    AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el producto dentro de este negocio.'
      USING ERRCODE = 'P0002';
  END IF;

  -- Rechazar formularios desactualizados en vez de sobrescribir ventas
  -- ocurridas mientras el administrador tenía abierto el producto.
  IF v_product.inventory <> p_expected_inventory THEN
    RAISE EXCEPTION 'Las existencias cambiaron desde que abriste el producto. Recarga la lista y vuelve a realizar el ajuste.'
      USING ERRCODE = '40001';
  END IF;

  IF v_product.inventory = p_new_inventory THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'inventory', v_product.inventory
    );
  END IF;

  PERFORM pg_catalog.set_config(
    'app.inventory_movement_reason', v_reason, true
  );
  PERFORM pg_catalog.set_config(
    'app.inventory_movement_type', 'adjustment', true
  );

  UPDATE public.products
  SET inventory = p_new_inventory,
      updated_at = pg_catalog.now()
  WHERE id = p_product_id
    AND business_id = p_business_id;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'previous_inventory', v_product.inventory,
    'inventory', p_new_inventory,
    'delta', p_new_inventory - v_product.inventory
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.adjust_business_inventory(uuid, uuid, integer, integer, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.adjust_business_inventory(uuid, uuid, integer, integer, text)
  TO authenticated;

-- Antes de desplegar, comprobar:
-- 1. Admin del negocio A puede ajustar solo productos de A.
-- 2. Empleado, cliente y admin de B no pueden ajustar productos de A.
-- 3. Dos ajustes simultáneos no pierden actualizaciones: la fila se bloquea.
-- 4. Cada INSERT/UPDATE de inventory genera exactamente un movimiento.
-- 5. Checkout y cancelaciones generan movimientos con un motivo entendible.
-- 6. Un ajuste fallido no modifica inventario ni crea movimiento.

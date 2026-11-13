-- MiEje Market Independiente
-- Vinculación segura de pedidos con clientes y favoritos.
-- ESTADO: BORRADOR. Esta migración debe aplicarse ANTES de
-- checkout-idempotency-draft.sql y order-financial-access-draft.sql, porque
-- ambos dependen de orders.customer_user_id. Probar el conjunto en staging;
-- no aplicar directamente en producción.

-- Los pedidos de invitados conservan customer_user_id NULL. Los pedidos de
-- clientes autenticados quedan vinculados al usuario; al eliminar una cuenta,
-- la relación se limpia sin borrar pedidos ni su historial comercial.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS customer_user_id uuid
  REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS orders_customer_user_created_idx
  ON public.orders (customer_user_id, created_at DESC)
  WHERE customer_user_id IS NOT NULL;

COMMENT ON COLUMN public.orders.customer_user_id IS
  'Usuario autenticado que realizó el pedido. NULL para compras como invitado.';

-- Favoritos personales. El borrado de una cuenta elimina sus favoritos; el
-- borrado físico de un producto elimina solo su relación de favorito.
CREATE TABLE IF NOT EXISTS public.customer_favorites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_favorites_user_product_unique UNIQUE (user_id, product_id)
);

CREATE INDEX IF NOT EXISTS customer_favorites_user_created_idx
  ON public.customer_favorites (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS customer_favorites_product_idx
  ON public.customer_favorites (product_id);

ALTER TABLE public.customer_favorites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_favorites_select_own ON public.customer_favorites;
CREATE POLICY customer_favorites_select_own
ON public.customer_favorites
FOR SELECT
TO authenticated
USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS customer_favorites_insert_own_active_product ON public.customer_favorites;
CREATE POLICY customer_favorites_insert_own_active_product
ON public.customer_favorites
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = (SELECT auth.uid())
  AND EXISTS (
    SELECT 1
    FROM public.products p
    JOIN public.businesses b ON b.id = p.business_id
    WHERE p.id = customer_favorites.product_id
      AND p.is_active = true
      AND b.status = 'active'
  )
);

DROP POLICY IF EXISTS customer_favorites_delete_own ON public.customer_favorites;
CREATE POLICY customer_favorites_delete_own
ON public.customer_favorites
FOR DELETE
TO authenticated
USING (user_id = (SELECT auth.uid()));

-- Retirar cualquier concesión heredada y permitir solo las operaciones
-- necesarias. No se concede UPDATE: el usuario no puede reasignar el favorito.
REVOKE ALL ON TABLE public.customer_favorites FROM PUBLIC, anon, authenticated;
GRANT SELECT, DELETE ON TABLE public.customer_favorites TO authenticated;
GRANT INSERT (user_id, product_id) ON TABLE public.customer_favorites TO authenticated;

-- El historial con importes se entrega mediante get_customer_order_history()
-- del borrador order-financial-access-draft.sql, que filtra por auth.uid().
-- No se concede lectura directa de customer_user_id ni de importes de pedidos.

-- PRUEBAS OBLIGATORIAS EN STAGING:
-- 1) Cliente A crea y consulta favoritos; Cliente B no puede leerlos ni borrarlos.
-- 2) Cliente no puede insertar favoritos de otro usuario ni de producto inactivo.
-- 3) Cliente puede borrar su favorito aunque el producto ya no sea visible.
-- 4) Pedido autenticado se guarda con customer_user_id correcto; invitado queda NULL.
-- 5) get_customer_order_history() devuelve solo pedidos propios.
-- 6) Borrar cuenta no elimina pedidos: customer_user_id queda NULL.
-- 7) Repetir el mismo favorito no duplica filas.

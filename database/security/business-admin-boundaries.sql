-- MiEje Market Independiente
-- Limitar configuración comercial al administrador de cada negocio.
-- BORRADOR: revisar grants/columnas y probar en entorno controlado antes de ejecutar.
--
-- El técnico superior conserva su gestión mediante Edge Function con service_role.
-- Estas políticas evitan que platform_owner use acceso directo a RLS para cambiar
-- la ficha comercial o los métodos de pago de las tiendas.

DROP POLICY IF EXISTS businesses_admin_update ON public.businesses;
CREATE POLICY businesses_admin_update
ON public.businesses
FOR UPDATE
TO authenticated
USING (
  private.business_is_active(id)
  AND private.has_business_role(id, ARRAY['business_admin']::text[])
)
WITH CHECK (
  private.business_is_active(id)
  AND private.has_business_role(id, ARRAY['business_admin']::text[])
);

DROP POLICY IF EXISTS payment_methods_admin_insert ON public.business_payment_methods;
CREATE POLICY payment_methods_admin_insert
ON public.business_payment_methods
FOR INSERT
TO authenticated
WITH CHECK (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS payment_methods_admin_select ON public.business_payment_methods;
CREATE POLICY payment_methods_admin_select
ON public.business_payment_methods
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS payment_methods_admin_update ON public.business_payment_methods;
CREATE POLICY payment_methods_admin_update
ON public.business_payment_methods
FOR UPDATE
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
)
WITH CHECK (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

-- No se crea una política DELETE nueva: se conserva el comportamiento actual.
-- No se modifican las políticas de lectura pública del directorio en este cambio.


-- Los datos financieros y detalles de reembolso pertenecen al negocio.
-- Se elimina el acceso directo global del propietario técnico a estas tablas.
-- La gestión técnica continúa por funciones autorizadas, sin exponer datos
-- bancarios o referencias de clientes desde consultas generales del panel.

DROP POLICY IF EXISTS financial_admin_select ON public.financial_transactions;
CREATE POLICY financial_admin_select
ON public.financial_transactions
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS refund_admin_select ON public.refund_details;
CREATE POLICY refund_admin_select
ON public.refund_details
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);


-- El técnico superior administra negocios y accesos desde la Edge Function.
-- No consulta pedidos, productos, clientes ni datos financieros mediante el Data API.
-- Los administradores y empleados solo ven datos operativos de su negocio activo.

DROP POLICY IF EXISTS businesses_public_directory_authenticated ON public.businesses;
CREATE POLICY businesses_public_directory_authenticated
ON public.businesses
FOR SELECT
TO authenticated
USING (
  status = ANY (ARRAY['active','suspended']::text[])
  OR private.has_business_role(id, ARRAY['business_admin','employee']::text[])
);

DROP POLICY IF EXISTS memberships_select_self_admin_owner ON public.business_memberships;
CREATE POLICY memberships_select_self_admin_owner
ON public.business_memberships
FOR SELECT
TO authenticated
USING (
  user_id = (SELECT auth.uid())
  OR (
    private.business_is_active(business_id)
    AND private.has_business_role(business_id, ARRAY['business_admin']::text[])
  )
);

DROP POLICY IF EXISTS products_authenticated_select ON public.products;
CREATE POLICY products_authenticated_select
ON public.products
FOR SELECT
TO authenticated
USING (
  (is_active = true AND private.business_is_active(business_id))
  OR (
    private.has_business_role(business_id, ARRAY['business_admin','employee']::text[])
    AND private.business_is_active(business_id)
  )
);

DROP POLICY IF EXISTS orders_members_select ON public.orders;
CREATE POLICY orders_members_select
ON public.orders
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin','employee']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS orders_members_update_status ON public.orders;
CREATE POLICY orders_members_update_status
ON public.orders
FOR UPDATE
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin','employee']::text[])
  AND private.business_is_active(business_id)
)
WITH CHECK (
  private.has_business_role(business_id, ARRAY['business_admin','employee']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS order_items_members_select ON public.order_items;
CREATE POLICY order_items_members_select
ON public.order_items
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_items.order_id
      AND private.has_business_role(o.business_id, ARRAY['business_admin','employee']::text[])
      AND private.business_is_active(o.business_id)
  )
);

-- El trigger también bloquea cambios de estado cuando el negocio está suspendido
-- y elimina el bypass del propietario técnico.
CREATE OR REPLACE FUNCTION private.enforce_order_status_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
DECLARE
  v_actor_id uuid := auth.uid();
  v_has_approved_cancellation boolean;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Se requiere un usuario autenticado para cambiar el estado.'
      USING ERRCODE = '42501';
  END IF;

  IF NOT private.business_is_active(OLD.business_id)
     OR NOT private.has_business_role(
       OLD.business_id,
       ARRAY['business_admin','employee']::text[]
     ) THEN
    RAISE EXCEPTION 'No tienes permisos para modificar pedidos de este negocio.'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.status = 'cancelled' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.order_cancellation_requests r
      WHERE r.business_id = OLD.business_id
        AND r.order_id = OLD.id
        AND r.status = 'approved'
        AND r.decided_by = v_actor_id
    ) INTO v_has_approved_cancellation;

    IF NOT v_has_approved_cancellation THEN
      RAISE EXCEPTION 'No se puede cancelar el pedido sin una solicitud aprobada por este usuario.'
        USING ERRCODE = '23514';
    END IF;

    IF OLD.status IN ('delivered','cancelled') THEN
      RAISE EXCEPTION 'No se puede cancelar un pedido que ya terminó.'
        USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
  END IF;

  IF NOT (
    (OLD.status = 'pending' AND NEW.status = 'confirmed') OR
    (OLD.status = 'confirmed' AND NEW.status = 'preparing') OR
    (OLD.status = 'preparing' AND NEW.status = 'ready') OR
    (OLD.status = 'ready' AND NEW.status = 'out_for_delivery') OR
    (OLD.status = 'out_for_delivery' AND NEW.status = 'delivered')
  ) THEN
    RAISE EXCEPTION 'Cambio de estado no permitido: % -> %.', OLD.status, NEW.status
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;


-- Garantía transaccional: nunca dejar un negocio sin administrador activo
-- por dos suspensiones/cambios concurrentes. El bloqueo de la fila del negocio
-- serializa estas operaciones antes de contar administradores restantes.
CREATE OR REPLACE FUNCTION private.guard_last_active_business_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_business_id uuid;
  v_remaining_admins integer;
  v_removing_active_admin boolean := false;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_business_id := OLD.business_id;
    v_removing_active_admin := OLD.role = 'business_admin' AND OLD.status = 'active';
  ELSE
    v_business_id := OLD.business_id;
    v_removing_active_admin :=
      OLD.role = 'business_admin'
      AND OLD.status = 'active'
      AND NOT (
        NEW.business_id = OLD.business_id
        AND NEW.role = 'business_admin'
        AND NEW.status = 'active'
      );
  END IF;

  IF NOT v_removing_active_admin THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  PERFORM 1
  FROM public.businesses
  WHERE id = v_business_id
  FOR UPDATE;

  SELECT count(*)::integer
  INTO v_remaining_admins
  FROM public.business_memberships
  WHERE business_id = v_business_id
    AND role = 'business_admin'
    AND status = 'active'
    AND id <> OLD.id;

  IF v_remaining_admins = 0 THEN
    RAISE EXCEPTION 'No se puede retirar el último administrador activo del negocio.'
      USING ERRCODE = '23514';
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$function$;

DROP TRIGGER IF EXISTS guard_last_active_business_admin
ON public.business_memberships;

CREATE TRIGGER guard_last_active_business_admin
BEFORE UPDATE OF role, status OR DELETE
ON public.business_memberships
FOR EACH ROW
EXECUTE FUNCTION private.guard_last_active_business_admin();

REVOKE ALL ON FUNCTION private.guard_last_active_business_admin() FROM PUBLIC, anon, authenticated;


-- Separar también el contenido comercial, costos internos y solicitudes
-- de personal/pedidos del acceso global del propietario técnico.
-- El técnico conserva la auditoría global y la gestión de cuentas,
-- pero no consulta operaciones privadas de cada tienda desde el Data API.

DROP POLICY IF EXISTS business_content_pages_admin_read ON public.business_content_pages;
CREATE POLICY business_content_pages_admin_read
ON public.business_content_pages
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS business_expenses_select ON public.business_expenses;
CREATE POLICY business_expenses_select
ON public.business_expenses
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS product_costs_admin_select ON public.product_costs;
CREATE POLICY product_costs_admin_select
ON public.product_costs
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS product_costs_admin_insert ON public.product_costs;
CREATE POLICY product_costs_admin_insert
ON public.product_costs
FOR INSERT
TO authenticated
WITH CHECK (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS product_costs_admin_update ON public.product_costs;
CREATE POLICY product_costs_admin_update
ON public.product_costs
FOR UPDATE
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
)
WITH CHECK (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS order_item_costs_admin_select ON public.order_item_costs;
CREATE POLICY order_item_costs_admin_select
ON public.order_item_costs
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS cancellation_members_select ON public.order_cancellation_requests;
CREATE POLICY cancellation_members_select
ON public.order_cancellation_requests
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin','employee']::text[])
  AND private.business_is_active(business_id)
);

DROP POLICY IF EXISTS job_applications_business_admin_read ON public.job_applications;
CREATE POLICY job_applications_business_admin_read
ON public.job_applications
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);

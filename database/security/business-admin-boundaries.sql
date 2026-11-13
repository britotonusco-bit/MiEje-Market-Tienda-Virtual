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


-- Las solicitudes de cancelación solo son visibles para el administrador del
-- negocio. Los empleados pueden crear solicitudes mediante la RPC controlada,
-- pero no consultar la bandeja ni decidir solicitudes.
DROP POLICY IF EXISTS cancellation_members_select ON public.order_cancellation_requests;
DROP POLICY IF EXISTS cancellation_admin_select ON public.order_cancellation_requests;
CREATE POLICY cancellation_admin_select
ON public.order_cancellation_requests
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
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
    IF NEW.business_id IS DISTINCT FROM OLD.business_id THEN
      RAISE EXCEPTION 'No se puede trasladar una membresía a otro negocio.'
        USING ERRCODE = '42501';
    END IF;

    v_business_id := OLD.business_id;
    v_removing_active_admin :=
      OLD.role = 'business_admin'
      AND OLD.status = 'active'
      AND NOT (
        NEW.role = 'business_admin'
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
BEFORE UPDATE OF business_id, role, status OR DELETE
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
DROP POLICY IF EXISTS cancellation_admin_select ON public.order_cancellation_requests;
CREATE POLICY cancellation_admin_select
ON public.order_cancellation_requests
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
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


-- Impedir trasladar registros entre tiendas cuando una misma cuenta
-- administra más de un negocio. La política RLS valida el destino, pero
-- esta protección conserva inmutable la pertenencia original del registro.
CREATE OR REPLACE FUNCTION private.prevent_business_scope_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_product_business_id uuid;
BEGIN
  IF NEW.business_id IS DISTINCT FROM OLD.business_id THEN
    RAISE EXCEPTION 'No se puede trasladar un registro de un negocio a otro.'
      USING ERRCODE = '42501';
  END IF;

  IF TG_TABLE_NAME = 'product_costs' THEN
    SELECT p.business_id
    INTO v_product_business_id
    FROM public.products p
    WHERE p.id = NEW.product_id;

    IF v_product_business_id IS NULL
       OR v_product_business_id <> NEW.business_id THEN
      RAISE EXCEPTION 'El costo debe corresponder a un producto del mismo negocio.'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS prevent_product_business_scope_change ON public.products;
CREATE TRIGGER prevent_product_business_scope_change
BEFORE UPDATE OF business_id ON public.products
FOR EACH ROW EXECUTE FUNCTION private.prevent_business_scope_change();

DROP TRIGGER IF EXISTS prevent_expense_business_scope_change ON public.business_expenses;
CREATE TRIGGER prevent_expense_business_scope_change
BEFORE UPDATE OF business_id ON public.business_expenses
FOR EACH ROW EXECUTE FUNCTION private.prevent_business_scope_change();

DROP TRIGGER IF EXISTS prevent_payment_method_business_scope_change ON public.business_payment_methods;
CREATE TRIGGER prevent_payment_method_business_scope_change
BEFORE UPDATE OF business_id ON public.business_payment_methods
FOR EACH ROW EXECUTE FUNCTION private.prevent_business_scope_change();

DROP TRIGGER IF EXISTS prevent_product_cost_business_scope_change ON public.product_costs;
CREATE TRIGGER prevent_product_cost_business_scope_change
BEFORE UPDATE OF business_id, product_id ON public.product_costs
FOR EACH ROW EXECUTE FUNCTION private.prevent_business_scope_change();

REVOKE ALL ON FUNCTION private.prevent_business_scope_change() FROM PUBLIC, anon, authenticated;


-- Eliminar bypass técnico y limitar los campos que el administrador puede
-- modificar directamente en productos, métodos de pago y costos.
DROP POLICY IF EXISTS product_costs_admin_insert ON public.product_costs;
CREATE POLICY product_costs_admin_insert
ON public.product_costs
FOR INSERT
TO authenticated
WITH CHECK (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
  AND EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.id = product_id
      AND p.business_id = product_costs.business_id
  )
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
  AND EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.id = product_id
      AND p.business_id = product_costs.business_id
  )
);

-- Evitar que un UPDATE genérico cambie identificadores o la tienda propietaria.
-- La interfaz actual solo necesita modificar estos campos del producto.
REVOKE UPDATE ON TABLE public.products FROM PUBLIC, anon, authenticated;
REVOKE UPDATE (id, business_id, name, category, description, sku, price, inventory,
  image_url, is_active, created_at, updated_at)
ON TABLE public.products FROM PUBLIC, anon, authenticated;
GRANT UPDATE (name, category, description, price, inventory, image_url, is_active, sku, updated_at)
ON TABLE public.products TO authenticated;

-- Los métodos de pago tampoco deben poder trasladarse ni alterar su identidad.
REVOKE UPDATE ON TABLE public.business_payment_methods FROM PUBLIC, anon, authenticated;
REVOKE UPDATE (id, business_id, method_code, display_name, provider, account_holder,
  account_type, account_reference, public_instructions, is_enabled, sort_order,
  created_at, updated_at)
ON TABLE public.business_payment_methods FROM PUBLIC, anon, authenticated;
GRANT UPDATE (method_code, display_name, provider, account_holder, account_type,
  account_reference, public_instructions, is_enabled, sort_order, updated_at)
ON TABLE public.business_payment_methods TO authenticated;

-- Los costos conservan su producto y negocio de origen después de crearse.
REVOKE UPDATE ON TABLE public.product_costs FROM PUBLIC, anon, authenticated;
REVOKE UPDATE (product_id, business_id, cost_price, created_at, updated_at)
ON TABLE public.product_costs FROM PUBLIC, anon, authenticated;
GRANT UPDATE (cost_price, updated_at)
ON TABLE public.product_costs TO authenticated;

-- La lectura de postulaciones requiere que el negocio siga activo.
DROP POLICY IF EXISTS job_applications_business_admin_read ON public.job_applications;
CREATE POLICY job_applications_business_admin_read
ON public.job_applications
FOR SELECT
TO authenticated
USING (
  private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND private.business_is_active(business_id)
);


-- El administrador configura la ficha comercial, pero no puede cambiar
-- estado de plataforma, slug, propietario técnico ni otros campos internos.
REVOKE UPDATE ON TABLE public.businesses FROM PUBLIC, anon, authenticated;
REVOKE UPDATE (id, name, slug, category, description, tagline, city, contact_phone,
  whatsapp_support, opening_hours, business_type, logo_url, status,
  suspension_reason, public_suspension_message, created_by, created_at,
  updated_at, delivery_fee, minimum_order_amount)
ON TABLE public.businesses FROM PUBLIC, anon, authenticated;
GRANT UPDATE (name, category, tagline, description, city, contact_phone,
  whatsapp_support, logo_url, opening_hours, delivery_fee, minimum_order_amount)
ON TABLE public.businesses TO authenticated;



-- Segunda pasada de aislamiento: estas políticas conservaban un bypass
-- del propietario técnico que no había sido sustituido en la primera versión.
-- La gestión de cuentas y negocios se realiza por la Edge Function técnica;
-- el Data API no debe dar acceso global a datos personales u operativos.

DROP POLICY IF EXISTS business_expenses_select ON public.business_expenses;
CREATE POLICY business_expenses_select
ON public.business_expenses
FOR SELECT
TO authenticated
USING (
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

-- El técnico consulta perfiles puntuales mediante la Edge Function con
-- service_role; por Data API cada usuario solo puede leer su propio perfil.
DROP POLICY IF EXISTS profiles_select_self_or_owner ON public.profiles;
CREATE POLICY profiles_select_self_or_owner
ON public.profiles
FOR SELECT
TO authenticated
USING (id = (SELECT auth.uid()));


-- Reglas de cuentas y membresías: solo el servicio técnico puede crear o modificar asignaciones.
-- El Data API de authenticated queda limitado a consultar sus membresías propias.
ALTER TABLE public.business_memberships
  ADD COLUMN IF NOT EXISTS job_title text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.business_memberships'::regclass
      AND conname = 'business_memberships_job_title_length'
  ) THEN
    ALTER TABLE public.business_memberships
      ADD CONSTRAINT business_memberships_job_title_length
      CHECK (job_title IS NULL OR char_length(btrim(job_title)) BETWEEN 2 AND 100);
  END IF;
END $$;

REVOKE INSERT, UPDATE, DELETE ON TABLE public.business_memberships FROM PUBLIC, anon, authenticated;

-- El Data API solo expone los campos de perfil necesarios para la interfaz.
-- Los campos internos de rol y bloqueo quedan disponibles únicamente a las
-- funciones de confianza (service_role), no a las consultas directas del cliente.
REVOKE SELECT ON TABLE public.profiles FROM PUBLIC, anon, authenticated;
REVOKE SELECT (id, display_name, phone, avatar_url, platform_role, is_blocked,
  blocked_reason, created_at, updated_at)
ON TABLE public.profiles FROM PUBLIC, anon, authenticated;
GRANT SELECT (id, display_name, avatar_url, phone)
ON TABLE public.profiles TO authenticated;

-- El usuario puede cambiar únicamente los datos de presentación de su perfil.
-- Nunca puede modificar platform_role, is_blocked ni blocked_reason.
REVOKE UPDATE ON TABLE public.profiles FROM PUBLIC, anon, authenticated;
REVOKE UPDATE (id, display_name, phone, avatar_url, platform_role, is_blocked,
  blocked_reason, created_at, updated_at)
ON TABLE public.profiles FROM PUBLIC, anon, authenticated;
GRANT UPDATE (display_name, avatar_url, phone) ON TABLE public.profiles TO authenticated;

DROP POLICY IF EXISTS profiles_select_self_or_owner ON public.profiles;
DROP POLICY IF EXISTS profiles_select_self ON public.profiles;
DROP POLICY IF EXISTS profiles_select_self_or_same_business_admin ON public.profiles;
CREATE POLICY profiles_select_self_or_same_business_admin
ON public.profiles
FOR SELECT
TO authenticated
USING (
  id = (SELECT auth.uid())
  OR EXISTS (
    SELECT 1
    FROM public.business_memberships AS target_membership
    WHERE target_membership.user_id = profiles.id
      AND private.business_is_active(target_membership.business_id)
      AND private.has_business_role(
        target_membership.business_id,
        ARRAY['business_admin']::text[]
      )
  )
);

DROP POLICY IF EXISTS profiles_update_self ON public.profiles;
CREATE POLICY profiles_update_self
ON public.profiles
FOR UPDATE
TO authenticated
USING (id = (SELECT auth.uid()))
WITH CHECK (id = (SELECT auth.uid()));

-- El cargo se almacena en la membresía porque puede variar si una persona
-- trabaja en más de un negocio. El panel y el rol se derivan del campo role.

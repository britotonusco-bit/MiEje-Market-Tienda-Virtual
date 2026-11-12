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
  status <> 'closed'
  AND private.has_business_role(id, ARRAY['business_admin']::text[])
)
WITH CHECK (
  private.has_business_role(id, ARRAY['business_admin']::text[])
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

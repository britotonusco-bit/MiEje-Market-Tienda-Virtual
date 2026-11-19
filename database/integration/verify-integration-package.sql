-- MiEje Market — verificación posterior del paquete de integración
-- SOLO LECTURA. Ejecutar en staging después de aplicar todas las migraciones.
-- Si un requisito falla, el bloque aborta con un mensaje claro.

DO $verify$
DECLARE
  missing text;
  v_mark_payment text;
  v_complete_refund text;
  v_decide_cancellation text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='orders'
      AND column_name='customer_user_id'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta orders.customer_user_id.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='orders'
      AND column_name='privacy_consent'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='orders'
      AND column_name='privacy_consent_version'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='orders'
      AND column_name='privacy_consent_at'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.orders'::regclass
      AND conname='orders_privacy_consent_evidence_check'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta la evidencia versionada y fechada del consentimiento de privacidad en pedidos.';
  END IF;

  IF has_column_privilege('authenticated','public.orders','privacy_consent','SELECT')
     OR has_column_privilege('authenticated','public.orders','privacy_consent_version','SELECT')
     OR has_column_privilege('authenticated','public.orders','privacy_consent_at','SELECT')
     OR has_column_privilege('authenticated','public.orders','privacy_consent','UPDATE')
     OR has_column_privilege('authenticated','public.orders','privacy_consent_version','UPDATE')
     OR has_column_privilege('authenticated','public.orders','privacy_consent_at','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los usuarios autenticados no deben leer ni modificar directamente la evidencia del consentimiento.';
  END IF;

  IF to_regprocedure('public.create_public_order_for_customer_with_payment_method(uuid,uuid,uuid,text,text,text,text,text,text,boolean,text,jsonb)') IS NULL
     OR NOT has_function_privilege('service_role',
       'public.create_public_order_for_customer_with_payment_method(uuid,uuid,uuid,text,text,text,text,text,text,boolean,text,jsonb)','EXECUTE')
     OR has_function_privilege('anon',
       'public.create_public_order_for_customer_with_payment_method(uuid,uuid,uuid,text,text,text,text,text,text,boolean,text,jsonb)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.create_public_order_for_customer_with_payment_method(uuid,uuid,uuid,text,text,text,text,text,text,boolean,text,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: la RPC que persiste el consentimiento no tiene la firma o los permisos exclusivos de servidor.';
  END IF;

  IF position('privacy_consent_at' IN lower(pg_get_functiondef(
       'public.create_public_order_for_customer_with_payment_method(uuid,uuid,uuid,text,text,text,text,text,text,boolean,text,jsonb)'::regprocedure
     ))) = 0
     OR position('transaction_timestamp' IN lower(pg_get_functiondef(
       'public.create_public_order_for_customer_with_payment_method(uuid,uuid,uuid,text,text,text,text,text,text,boolean,text,jsonb)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: la RPC no registra la fecha de consentimiento desde PostgreSQL.';
  END IF;

  IF position('privacy-2026-11-19-v1' IN pg_get_functiondef(
       'public.create_public_order_for_customer_with_payment_method(uuid,uuid,uuid,text,text,text,text,text,text,boolean,text,jsonb)'::regprocedure
     )) = 0 THEN
    RAISE EXCEPTION 'FALLO: la RPC no exige la versión de aviso de privacidad configurada para el checkout.';
  END IF;

  -- El código público de seguimiento es una credencial aleatoria:
  -- debe generarse en PostgreSQL, ser obligatorio y tener unicidad global.
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='public'
      AND table_name='orders'
      AND column_name='public_tracking_token'
      AND is_nullable='NO'
      AND column_default ILIKE '%gen_random_uuid%'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_index i
    JOIN pg_class t ON t.oid=i.indrelid
    JOIN pg_namespace n ON n.oid=t.relnamespace
    JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=ANY(i.indkey)
    WHERE n.nspname='public'
      AND t.relname='orders'
      AND i.indisunique
      AND i.indisvalid
      AND a.attname='public_tracking_token'
      AND i.indnkeyatts=1
  ) THEN
    RAISE EXCEPTION 'FALLO: el código privado de seguimiento debe ser obligatorio, generado por gen_random_uuid() y único.';
  END IF;

  IF to_regclass('public.customer_favorites') IS NULL
     OR to_regclass('private.checkout_idempotency') IS NULL
     OR to_regclass('private.checkout_rate_limit_reservations') IS NULL
     OR to_regclass('public.platform_public_settings') IS NULL THEN
    RAISE EXCEPTION 'FALLO: falta una tabla de clientes, checkout o configuración global.';
  END IF;

  IF to_regclass('public.access_block_requests') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='access_block_requests'
         AND c.relrowsecurity
     ) THEN
    RAISE EXCEPTION 'FALLO: falta access_block_requests o RLS no está habilitado.';
  END IF;

  IF has_table_privilege('anon','public.access_block_requests','SELECT')
     OR has_table_privilege('anon','public.access_block_requests','INSERT')
     OR has_table_privilege('authenticated','public.access_block_requests','SELECT')
     OR has_table_privilege('authenticated','public.access_block_requests','UPDATE')
     OR has_table_privilege('authenticated','public.access_block_requests','DELETE')
     OR NOT has_any_column_privilege('authenticated','public.access_block_requests','INSERT') THEN
    RAISE EXCEPTION 'FALLO: los permisos directos de access_block_requests no respetan el modelo esperado.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='access_block_requests'
      AND policyname='access_block_requests_admin_submit'
      AND cmd='INSERT'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta la política de solicitud exclusiva del administrador del negocio.';
  END IF;

  IF to_regprocedure('public.resolve_access_block_request(uuid,text,text,uuid)') IS NULL
     OR NOT has_function_privilege('service_role','public.resolve_access_block_request(uuid,text,text,uuid)','EXECUTE')
     OR has_function_privilege('anon','public.resolve_access_block_request(uuid,text,text,uuid)','EXECUTE')
     OR has_function_privilege('authenticated','public.resolve_access_block_request(uuid,text,text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: la RPC de resolución de bloqueos no tiene permisos exclusivos de servidor.';
  END IF;

  IF to_regclass('public.platform_financial_records') IS NULL
     OR to_regclass('public.payroll_records') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='platform_financial_records'
         AND c.relrowsecurity
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='payroll_records'
         AND c.relrowsecurity
     ) THEN
    RAISE EXCEPTION 'FALLO: faltan tablas financieras de plataforma o RLS no está habilitado.';
  END IF;

  IF has_table_privilege('anon','public.platform_financial_records','SELECT')
     OR has_table_privilege('anon','public.platform_financial_records','INSERT')
     OR has_table_privilege('authenticated','public.platform_financial_records','SELECT')
     OR has_table_privilege('authenticated','public.platform_financial_records','INSERT')
     OR has_table_privilege('authenticated','public.platform_financial_records','UPDATE')
     OR has_table_privilege('authenticated','public.platform_financial_records','DELETE')
     OR has_table_privilege('anon','public.payroll_records','SELECT')
     OR has_table_privilege('authenticated','public.payroll_records','SELECT')
     OR has_table_privilege('authenticated','public.payroll_records','INSERT')
     OR has_table_privilege('authenticated','public.payroll_records','UPDATE')
     OR has_table_privilege('authenticated','public.payroll_records','DELETE')
     OR NOT has_table_privilege('service_role','public.platform_financial_records','SELECT')
     OR NOT has_table_privilege('service_role','public.platform_financial_records','INSERT')
     OR NOT has_table_privilege('service_role','public.payroll_records','SELECT')
     OR NOT has_table_privilege('service_role','public.payroll_records','INSERT')
     OR NOT has_table_privilege('service_role','public.payroll_records','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los grants financieros no son exclusivos del servidor.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.check_constraints
    WHERE constraint_schema='public'
      AND constraint_name='payroll_paid_fields_consistent'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta la validación de coherencia del estado de nómina.';
  END IF;

  IF to_regclass('public.business_ai_settings') IS NULL
     OR to_regclass('public.platform_ai_settings') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='business_ai_settings'
         AND c.relrowsecurity
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='platform_ai_settings'
         AND c.relrowsecurity
     ) THEN
    RAISE EXCEPTION 'FALLO: faltan tablas de configuración IA o RLS no está habilitado.';
  END IF;

  IF has_table_privilege('anon','public.business_ai_settings','SELECT')
     OR has_table_privilege('anon','public.business_ai_settings','INSERT')
     OR has_table_privilege('anon','public.platform_ai_settings','SELECT')
     OR has_table_privilege('anon','public.platform_ai_settings','INSERT')
     OR has_table_privilege('authenticated','public.platform_ai_settings','SELECT')
     OR has_table_privilege('authenticated','public.platform_ai_settings','INSERT')
     OR has_table_privilege('authenticated','public.platform_ai_settings','UPDATE')
     OR NOT has_table_privilege('service_role','public.platform_ai_settings','SELECT')
     OR NOT has_table_privilege('service_role','public.platform_ai_settings','INSERT')
     OR NOT has_table_privilege('service_role','public.platform_ai_settings','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los permisos de configuración IA no respetan el acceso por rol.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_ai_settings'
      AND policyname='business_ai_settings_admin_select' AND cmd='SELECT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_ai_settings'
      AND policyname='business_ai_settings_admin_insert' AND cmd='INSERT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_ai_settings'
      AND policyname='business_ai_settings_admin_update' AND cmd='UPDATE'
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan políticas de IA exclusivas del administrador del negocio.';
  END IF;

  IF to_regprocedure('public.resolve_platform_payroll_record(uuid,text,text,uuid)') IS NULL
     OR NOT has_function_privilege('service_role','public.resolve_platform_payroll_record(uuid,text,text,uuid)','EXECUTE')
     OR has_function_privilege('anon','public.resolve_platform_payroll_record(uuid,text,text,uuid)','EXECUTE')
     OR has_function_privilege('authenticated','public.resolve_platform_payroll_record(uuid,text,text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: la RPC de resolución de nómina no es exclusiva del servidor.';
  END IF;

  IF to_regprocedure('private.audit_business_ai_settings_change()') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_trigger t
       JOIN pg_class c ON c.oid=t.tgrelid
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='business_ai_settings'
         AND t.tgname='business_ai_settings_audit'
         AND NOT t.tgisinternal
     ) THEN
    RAISE EXCEPTION 'FALLO: falta el registro de auditoría de cambios de IA por negocio.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname='customer_favorites'
      AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'FALLO: RLS no está habilitado en customer_favorites.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname='platform_public_settings'
      AND c.relrowsecurity
  ) OR has_table_privilege('anon','public.platform_public_settings','SELECT')
    OR has_table_privilege('authenticated','public.platform_public_settings','SELECT')
    OR has_table_privilege('anon','public.platform_public_settings','UPDATE')
    OR has_table_privilege('authenticated','public.platform_public_settings','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: configuración global sin RLS o expuesta directamente al cliente.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='business_memberships'
      AND column_name='job_title'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta business_memberships.job_title.';
  END IF;

  IF to_regprocedure('public.get_public_order_idempotent(uuid,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)') IS NULL
     OR to_regprocedure('public.reserve_checkout_rate_limit(uuid,text,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)') IS NULL
     OR to_regprocedure('public.create_public_order_idempotent(uuid,text,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan RPCs de idempotencia del checkout.';
  END IF;
  IF position('privacy_consent' IN lower(pg_get_functiondef(
       'public.get_public_order_idempotent(uuid,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)'::regprocedure
     ))) = 0
     OR position('privacy_consent' IN lower(pg_get_functiondef(
       'public.reserve_checkout_rate_limit(uuid,text,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)'::regprocedure
     ))) = 0
     OR position('privacy_consent' IN lower(pg_get_functiondef(
       'public.create_public_order_idempotent(uuid,text,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: la aceptación/version del aviso no forma parte de las tres huellas de idempotencia.';
  END IF;


  IF to_regprocedure('public.get_business_admin_order_financials(uuid,boolean,integer)') IS NULL
     OR to_regprocedure('public.mark_order_payment_received(uuid,text,text,text)') IS NULL
     OR to_regprocedure('public.get_customer_order_history()') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan RPCs de finanzas o historial de clientes.';
  END IF;

  IF position('cr.status = ''approved''' IN lower(pg_get_functiondef(
       'public.get_business_admin_order_financials(uuid,boolean,integer)'::regprocedure
     ))) = 0
     OR position('o.status = ''cancelled''' IN lower(pg_get_functiondef(
       'public.get_business_admin_order_financials(uuid,boolean,integer)'::regprocedure
     ))) = 0
     OR position('o.payment_status = ''paid''' IN lower(pg_get_functiondef(
       'public.get_business_admin_order_financials(uuid,boolean,integer)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: la lista de devoluciones debe limitarse a pedidos cancelados y pagados con una solicitud aprobada.';
  END IF;

  IF NOT EXISTS (
       SELECT 1 FROM pg_indexes
       WHERE schemaname='public'
         AND indexname='financial_one_completed_payment_per_order'
         AND indexdef ILIKE '%UNIQUE INDEX%'
         AND indexdef ILIKE '%(business_id, order_id)%'
         AND indexdef ILIKE '%WHERE ((transaction_type = ''payment_received''::text) AND (status = ''completed''::text))%'
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_indexes
       WHERE schemaname='public'
         AND indexname='financial_one_completed_refund_per_order'
         AND indexdef ILIKE '%UNIQUE INDEX%'
         AND indexdef ILIKE '%(business_id, order_id)%'
         AND indexdef ILIKE '%WHERE ((transaction_type = ''refund''::text) AND (status = ''completed''::text))%'
     ) THEN
    RAISE EXCEPTION 'FALLO: los índices únicos de pagos y reembolsos no protegen exactamente una operación completada por pedido.';
  END IF;

  IF position('v_order.total' IN lower(pg_get_functiondef(
       'public.mark_order_payment_received(uuid,text,text,text)'::regprocedure
     ))) = 0
     OR position('''cop''' IN lower(pg_get_functiondef(
       'public.mark_order_payment_received(uuid,text,text,text)'::regprocedure
     ))) = 0
     OR position('completed_at' IN lower(pg_get_functiondef(
       'public.mark_order_payment_received(uuid,text,text,text)'::regprocedure
     ))) = 0
     OR position('payment_status = ''paid''' IN lower(pg_get_functiondef(
       'public.mark_order_payment_received(uuid,text,text,text)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: la confirmación de pago no registra total, moneda, fecha efectiva y estado del pedido de forma coherente.';
  END IF;

  IF position('cancellation_request_id' IN lower(pg_get_functiondef(
       'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
     ))) = 0
     OR position('completed_at' IN lower(pg_get_functiondef(
       'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
     ))) = 0
     OR position('payment_status = ''refunded''' IN lower(pg_get_functiondef(
       'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: el reembolso no vincula la cancelación, su fecha efectiva y el estado reembolsado del pedido.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename IN (
      'financial_transactions','business_expenses','refund_details',
      'product_costs','order_item_costs'
    )
      AND policyname IN (
        'financial_admin_select','business_expenses_select','refund_admin_select',
        'product_costs_admin_select','product_costs_admin_insert',
        'product_costs_admin_update','order_item_costs_admin_select'
      )
      AND (
        coalesce(qual,'') ILIKE '%is_platform_owner%'
        OR coalesce(with_check,'') ILIKE '%is_platform_owner%'
      )
  ) THEN
    RAISE EXCEPTION 'FALLO: el propietario técnico conserva lectura directa global de finanzas o costos de negocios.';
  END IF;

  IF position('has_business_role' IN lower(pg_get_functiondef(
       'public.get_business_admin_order_financials(uuid,boolean,integer)'::regprocedure
     ))) = 0
     OR position('business_is_active' IN lower(pg_get_functiondef(
       'public.get_business_admin_order_financials(uuid,boolean,integer)'::regprocedure
     ))) = 0
     OR position('has_business_role' IN lower(pg_get_functiondef(
       'public.mark_order_payment_received(uuid,text,text,text)'::regprocedure
     ))) = 0
     OR position('business_is_active' IN lower(pg_get_functiondef(
       'public.mark_order_payment_received(uuid,text,text,text)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: un RPC financiero no valida membresía administrativa y negocio activo.';
  END IF;

  IF to_regclass('public.refund_details') IS NULL
     OR to_regclass('public.financial_transactions') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan tablas necesarias para conciliar reembolsos.';
  END IF;

  IF position('for update' IN lower(pg_get_functiondef(
       'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
     ))) = 0
     OR position('payment_status <> ''paid''' IN lower(pg_get_functiondef(
       'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
     ))) = 0
     OR position('status <> ''cancelled''' IN lower(pg_get_functiondef(
       'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
     ))) = 0
     OR position('v_payment_count <> 1' IN lower(pg_get_functiondef(
       'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
     ))) = 0
     OR position('v_paid_amount <> v_order.total' IN lower(pg_get_functiondef(
       'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
     ))) = 0
     OR position('ft.currency = ''cop''' IN lower(pg_get_functiondef(
       'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
     ))) = 0
     OR position('r.status = ''approved''' IN lower(pg_get_functiondef(
       'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: el reembolso no valida bloqueo, cancelación aprobada, pago único y conciliación exacta en COP.';
  END IF;

  IF position('ft.currency=''cop''' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: el reporte de ganancias debe separar explícitamente los movimientos en COP.';
  END IF;

  -- Conciliar cada clase de movimiento por su fecha efectiva local:
  -- cobros/reembolsos por completed_at, cancelación por decided_at y gastos por paid_at.
  IF position('ft.completed_at >=' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('ft.completed_at <' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('be.paid_at >=' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('be.paid_at <' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('cr.decided_at >=' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('cr.decided_at <' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('paid.currency=''cop''' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('america/bogota' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: cobros, reembolsos, cancelaciones o gastos no se filtran por su fecha efectiva en hora Bogotá.';
  END IF;

  -- Identidades aritméticas: los acumulados por subperiodos deben ser aditivos
  -- porque todas las clases usan rangos semiabiertos por su fecha efectiva.
  -- Domicilios son informativos: ya están incluidos en sales y no se suman otra vez.
  IF position('sum(unit_cost*quantity*direction)' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('''net_sales'',sales-refunds' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('''gross_profit_estimate'',case when missing_cost_lines=0' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('then sales-refunds-cost_of_sales' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('then sales-refunds-cost_of_sales-paid_expenses' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('''delivery_fees_collected'',delivery_fees' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('''sales'',sales' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: las identidades de cobros netos, costos, ganancias o domicilios pueden duplicar importes o romper la aditividad de los periodos.';
  END IF;

  -- El periodo anual completo debe caber en el límite declarado por el RPC.
  IF position('p_end_date - p_start_date > 366' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: el reporte no admite un año calendario completo de 366 días.';
  END IF;

  -- Las cancelaciones aprobadas no pueden duplicar la reversión de costo.
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public'
      AND indexname='order_cancellation_one_approved_per_order'
      AND indexdef ILIKE '%UNIQUE INDEX%'
      AND indexdef ILIKE '%(business_id, order_id)%'
      AND indexdef ILIKE '%WHERE (status = ''approved''::text)%'
  ) THEN
    RAISE EXCEPTION 'FALLO: no está garantizada una sola cancelación aprobada por pedido.';
  END IF;
  IF to_regprocedure('public.complete_order_refund(uuid,text,text,text,text)') IS NULL
     OR NOT has_function_privilege('authenticated',
       'public.complete_order_refund(uuid,text,text,text,text)','EXECUTE')
     OR has_function_privilege('anon',
       'public.complete_order_refund(uuid,text,text,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: RPC de reembolso ausente o con permisos incorrectos.';
  END IF;

  IF to_regclass('public.order_cancellation_one_approved_per_order') IS NULL THEN
    RAISE EXCEPTION 'FALLO: falta el índice que impide aprobar dos cancelaciones para el mismo pedido.';
  END IF;
  IF to_regprocedure('public.request_order_cancellation(uuid,uuid,text)') IS NULL
     OR to_regprocedure('public.decide_order_cancellation(uuid,text,text)') IS NULL
     OR to_regprocedure('public.complete_order_refund(uuid,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan RPCs de cancelación o reembolso.';
  END IF;

  IF to_regprocedure('private.guard_last_active_business_admin()') IS NULL
     OR to_regprocedure('private.prevent_business_scope_change()') IS NULL
     OR to_regprocedure('private.enforce_order_status_transition()') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan funciones de protección de membresías/negocios/pedidos.';
  END IF;

  -- El técnico no debe conservar un bypass global sobre pedidos ni partidas.
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='orders'
      AND policyname IN ('orders_members_select','orders_members_update_status')
      AND (
        coalesce(qual,'') ILIKE '%is_platform_owner%'
        OR coalesce(with_check,'') ILIKE '%is_platform_owner%'
      )
  ) OR EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='order_items'
      AND policyname='order_items_members_select'
      AND coalesce(qual,'') ILIKE '%is_platform_owner%'
  ) OR position(
    'is_platform_owner' IN lower(pg_get_functiondef(
      'private.enforce_order_status_transition()'::regprocedure
    ))
  ) > 0 THEN
    RAISE EXCEPTION 'FALLO: el propietario técnico conserva un bypass directo en el flujo de pedidos.';
  END IF;

  IF NOT has_column_privilege('authenticated','public.orders','status','UPDATE')
     OR NOT has_column_privilege('authenticated','public.orders','delivery_tracking','UPDATE')
     OR has_column_privilege('authenticated','public.orders','payment_status','UPDATE')
     OR has_column_privilege('authenticated','public.orders','total','UPDATE')
     OR has_table_privilege('anon','public.orders','SELECT')
     OR has_table_privilege('anon','public.order_items','SELECT') THEN
    RAISE EXCEPTION 'FALLO: los permisos de actualización/lectura de pedidos no coinciden con el modelo.';
  END IF;

  -- Un cambio operativo de estado/seguimiento nunca debe poder alterar
  -- importes, identidad del cliente, método de pago ni snapshots del pedido.
  IF NOT has_column_privilege('authenticated','public.orders','status','UPDATE')
     OR NOT has_column_privilege('authenticated','public.orders','delivery_tracking','UPDATE')
     OR has_column_privilege('authenticated','public.orders','subtotal','UPDATE')
     OR has_column_privilege('authenticated','public.orders','delivery_fee','UPDATE')
     OR has_column_privilege('authenticated','public.orders','total','UPDATE')
     OR has_column_privilege('authenticated','public.orders','payment_method','UPDATE')
     OR has_column_privilege('authenticated','public.orders','payment_method_name','UPDATE')
     OR has_column_privilege('authenticated','public.orders','payment_status','UPDATE')
     OR has_column_privilege('authenticated','public.orders','customer_name','UPDATE')
     OR has_column_privilege('authenticated','public.orders','customer_phone','UPDATE')
     OR has_column_privilege('authenticated','public.orders','customer_email','UPDATE')
     OR has_column_privilege('authenticated','public.orders','delivery_address','UPDATE')
     OR has_column_privilege('authenticated','public.orders','customer_user_id','UPDATE')
     OR has_column_privilege('authenticated','public.orders','public_tracking_token','UPDATE')
     OR has_column_privilege('authenticated','public.order_items','unit_price','UPDATE')
     OR has_column_privilege('authenticated','public.order_items','quantity','UPDATE')
     OR has_column_privilege('authenticated','public.order_items','product_name','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los paneles pueden alterar importes, datos originales o líneas históricas del pedido.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.orders'::regclass
      AND conname='orders_status_check'
      AND contype='c'
      AND pg_get_constraintdef(oid) ILIKE '%received%'
      AND pg_get_constraintdef(oid) ILIKE '%on_the_way%'
      AND pg_get_constraintdef(oid) ILIKE '%cancelled%'
  ) THEN
    RAISE EXCEPTION 'FALLO: los estados almacenados no coinciden con el flujo operativo vigente.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_proc p ON p.oid=t.tgfoid
    WHERE n.nspname='public' AND c.relname='orders'
      AND NOT t.tgisinternal
      AND (t.tgtype & 1) = 1
      AND (t.tgtype & 2) = 2
      AND (t.tgtype & 16) = 16
      AND p.proname='enforce_order_status_transition'
      AND position('old.status' IN lower(pg_get_functiondef(p.oid))) > 0
      AND position('new.status' IN lower(pg_get_functiondef(p.oid))) > 0
      AND position('subtotal' IN lower(pg_get_functiondef(p.oid))) = 0
      AND position('delivery_fee' IN lower(pg_get_functiondef(p.oid))) = 0
      AND position('new.total' IN lower(pg_get_functiondef(p.oid))) = 0
  ) THEN
    RAISE EXCEPTION 'FALLO: falta el trigger de transición de estado o inspecciona campos financieros.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='customer_favorites'
      AND policyname='customer_favorites_select_own' AND cmd='SELECT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='customer_favorites'
      AND policyname='customer_favorites_insert_own_active_product' AND cmd='INSERT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='customer_favorites'
      AND policyname='customer_favorites_delete_own' AND cmd='DELETE'
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan políticas RLS de favoritos.';
  END IF;

  IF has_table_privilege('anon','public.customer_favorites','SELECT')
     OR has_table_privilege('anon','public.customer_favorites','INSERT')
     OR has_table_privilege('anon','public.customer_favorites','DELETE')
     OR NOT has_table_privilege('authenticated','public.customer_favorites','SELECT')
     OR NOT has_table_privilege('authenticated','public.customer_favorites','INSERT')
     OR NOT has_table_privilege('authenticated','public.customer_favorites','DELETE')
     OR has_table_privilege('authenticated','public.customer_favorites','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los permisos de favoritos no son exclusivos del cliente autenticado.';
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.get_customer_order_history()','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_customer_order_history()','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: el historial no está limitado a sesiones autenticadas.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname='get_customer_order_history'
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']::text[]
      AND position('auth.uid()' IN lower(pg_get_functiondef(p.oid))) > 0
      AND position('customer_user_id = v_actor' IN lower(pg_get_functiondef(p.oid))) > 0
      AND position('is_blocked = false' IN lower(pg_get_functiondef(p.oid))) > 0
  ) THEN
    RAISE EXCEPTION 'FALLO: la RPC de historial no valida sesión, perfil activo, propiedad y search_path seguro.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='private'
      AND p.proname='customer_owns_order'
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']::text[]
      AND position('auth.uid()' IN lower(pg_get_functiondef(p.oid))) > 0
      AND position('customer_user_id = auth.uid()' IN lower(pg_get_functiondef(p.oid))) > 0
  ) OR NOT has_function_privilege('authenticated',
       'private.customer_owns_order(uuid)','EXECUTE')
     OR has_function_privilege('anon',
       'private.customer_owns_order(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: la función interna de propiedad del pedido no está limitada por auth.uid() o tiene permisos incorrectos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='order_items'
      AND policyname='order_items_customer_select_own'
      AND cmd='SELECT'
      AND coalesce(qual,'') ILIKE '%customer_owns_order%'
  ) THEN
    RAISE EXCEPTION 'FALLO: las líneas de pedido no tienen política de lectura propia para el cliente.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='customer_favorites'
      AND policyname='customer_favorites_select_own'
      AND cmd='SELECT'
      AND coalesce(qual,'') ILIKE '%auth.uid%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='customer_favorites'
      AND policyname='customer_favorites_insert_own_active_product'
      AND cmd='INSERT'
      AND coalesce(with_check,'') ILIKE '%auth.uid%'
      AND coalesce(with_check,'') ILIKE '%is_active%'
      AND coalesce(with_check,'') ILIKE '%status%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='customer_favorites'
      AND policyname='customer_favorites_delete_own'
      AND cmd='DELETE'
      AND coalesce(qual,'') ILIKE '%auth.uid%'
  ) THEN
    RAISE EXCEPTION 'FALLO: las políticas de favoritos no restringen lectura/escritura a su propietario y productos activos.';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=ANY(c.conkey)
    WHERE c.conrelid='public.orders'::regclass
      AND c.contype='f'
      AND a.attname='customer_user_id'
      AND c.confdeltype='n'
  ) THEN
    RAISE EXCEPTION 'FALLO: borrar una cuenta podría no conservar los pedidos con customer_user_id en NULL.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_content_pages'
      AND policyname='business_content_pages_public_read'
      AND cmd='SELECT' AND roles @> ARRAY['anon']::name[]
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_content_pages'
      AND policyname='business_content_pages_public_or_admin_read'
      AND cmd='SELECT' AND roles @> ARRAY['authenticated']::name[]
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan políticas separadas para contenido público anon y authenticated.';
  END IF;

  IF NOT has_function_privilege('service_role',
       'public.get_public_order_idempotent(uuid,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR NOT has_function_privilege('service_role',
       'public.reserve_checkout_rate_limit(uuid,text,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR NOT has_function_privilege('service_role',
       'public.create_public_order_idempotent(uuid,text,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_public_order_idempotent(uuid,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.get_public_order_idempotent(uuid,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('anon',
       'public.reserve_checkout_rate_limit(uuid,text,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.reserve_checkout_rate_limit(uuid,text,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('anon',
       'public.create_public_order_idempotent(uuid,text,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.create_public_order_idempotent(uuid,text,uuid,uuid,uuid,boolean,text,text,text,text,text,text,text,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: permisos incorrectos en RPCs de idempotencia del checkout.';
  END IF;

  IF has_table_privilege('anon','private.checkout_idempotency','SELECT')
     OR has_table_privilege('authenticated','private.checkout_idempotency','SELECT')
     OR has_table_privilege('service_role','private.checkout_idempotency','SELECT')
     OR has_table_privilege('anon','private.checkout_rate_limit_reservations','SELECT')
     OR has_table_privilege('authenticated','private.checkout_rate_limit_reservations','SELECT')
     OR has_table_privilege('service_role','private.checkout_rate_limit_reservations','SELECT') THEN
    RAISE EXCEPTION 'FALLO: tablas internas de idempotencia no deben tener lectura directa.';
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.get_business_admin_order_financials(uuid,boolean,integer)','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_business_admin_order_financials(uuid,boolean,integer)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: permisos incorrectos en RPC financiero.';
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.get_customer_order_history()','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_customer_order_history()','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: permisos incorrectos en RPC de historial.';
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.mark_order_payment_received(uuid,text,text,text)','EXECUTE')
     OR has_function_privilege('anon',
       'public.mark_order_payment_received(uuid,text,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: permisos incorrectos en RPC de confirmación de pagos.';
  END IF;

  IF has_column_privilege('authenticated','public.orders','total','SELECT')
     OR has_column_privilege('authenticated','public.orders','subtotal','SELECT')
     OR has_column_privilege('authenticated','public.orders','delivery_fee','SELECT')
     OR has_column_privilege('authenticated','public.orders','payment_method','SELECT')
     OR has_column_privilege('authenticated','public.orders','payment_status','SELECT')
     OR has_column_privilege('authenticated','public.orders','customer_email','SELECT')
     OR has_column_privilege('authenticated','public.orders','customer_user_id','SELECT')
     OR has_column_privilege('authenticated','public.order_items','product_id','SELECT')
     OR has_column_privilege('authenticated','public.order_items','unit_price','SELECT')
     OR has_column_privilege('authenticated','public.order_items','line_total','SELECT')
     OR has_table_privilege('authenticated','public.orders','SELECT')
     OR has_table_privilege('authenticated','public.order_items','SELECT')
     OR NOT has_column_privilege('authenticated','public.orders','status','SELECT')
     OR NOT has_column_privilege('authenticated','public.orders','business_id','SELECT')
     OR NOT has_column_privilege('authenticated','public.order_items','product_name','SELECT')
     OR NOT has_column_privilege('authenticated','public.order_items','quantity','SELECT') THEN
    RAISE EXCEPTION 'FALLO: columnas de pedidos visibles/no visibles no coinciden con el mínimo operativo.';
  END IF;

  IF has_table_privilege('authenticated','public.orders','UPDATE')
     OR has_table_privilege('authenticated','public.order_items','INSERT')
     OR has_table_privilege('authenticated','public.order_items','UPDATE')
     OR has_table_privilege('authenticated','public.order_items','DELETE')
     OR NOT has_column_privilege('authenticated','public.orders','status','UPDATE')
     OR NOT has_column_privilege('authenticated','public.orders','delivery_tracking','UPDATE')
     OR has_column_privilege('authenticated','public.orders','payment_status','UPDATE')
     OR has_column_privilege('authenticated','public.orders','total','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los paneles conservan escritura directa de columnas financieras o líneas de pedido.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id='business-assets' AND public=true AND file_size_limit=5242880
  ) OR NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id='job-applications-private' AND public=false AND file_size_limit=5242880
  ) THEN
    RAISE EXCEPTION 'FALLO: buckets ausentes o su visibilidad/límite de 5 MB no coincide con lo esperado.';
  END IF;

  -- Storage: las imágenes comerciales son públicas por diseño, pero su
  -- escritura/gestión queda limitada al administrador del negocio propietario.
  -- Hojas de vida y comprobantes financieros deben permanecer privados.
  IF NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id='business-expense-receipts' AND public=false
      AND file_size_limit=5242880
  ) THEN
    RAISE EXCEPTION 'FALLO: el bucket de comprobantes financieros no es privado o no limita archivos a 5 MB.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname IN (
        'business_assets_admin_upload','business_assets_admin_read',
        'business_assets_admin_update','business_assets_admin_delete'
      )
      AND (
        coalesce(qual,'') ILIKE '%storage.foldername(b.name)%'
        OR coalesce(with_check,'') ILIKE '%storage.foldername(b.name)%'
      )
  ) THEN
    RAISE EXCEPTION 'FALLO: una política de business-assets obtiene la ruta desde businesses.name en lugar del objeto Storage.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='job_application_documents_business_admin_read'
      AND cmd='SELECT'
      AND roles @> ARRAY['authenticated']::name[]
      AND qual ILIKE '%job-applications-private%'
      AND qual ILIKE '%has_business_role%'
      AND qual ILIKE '%business_admin%'
      AND qual ILIKE '%array_length%'
      AND qual ILIKE '%storage.filename%'
      AND qual ILIKE '%job_applications%'
      AND qual ILIKE '%resume_path%'
  ) OR EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='job_application_documents_business_admin_read'
      AND (coalesce(qual,'') ILIKE '%platform_owner%' OR roles @> ARRAY['anon']::name[])
  ) THEN
    RAISE EXCEPTION 'FALLO: la lectura de hojas de vida no está restringida al administrador autenticado del negocio.';
  END IF;

  -- Las cuatro operaciones administrativas de imágenes deben derivar el
  -- negocio desde la ruta real del objeto y exigir exactamente dos carpetas.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_assets_admin_upload' AND cmd='INSERT'
      AND roles @> ARRAY['authenticated']::name[]
      AND with_check ILIKE '%business-assets%'
      AND with_check ILIKE '%storage.foldername(objects.name)%'
      AND with_check ILIKE '%array_length%'
      AND with_check ILIKE '%has_business_role%'
      AND with_check ILIKE '%business_admin%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_assets_admin_read' AND cmd='SELECT'
      AND roles @> ARRAY['authenticated']::name[]
      AND qual ILIKE '%business-assets%'
      AND qual ILIKE '%storage.foldername(objects.name)%'
      AND qual ILIKE '%array_length%'
      AND qual ILIKE '%has_business_role%'
      AND qual ILIKE '%business_admin%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_assets_admin_update' AND cmd='UPDATE'
      AND roles @> ARRAY['authenticated']::name[]
      AND qual ILIKE '%storage.foldername(objects.name)%'
      AND qual ILIKE '%has_business_role%'
      AND with_check ILIKE '%storage.foldername(objects.name)%'
      AND with_check ILIKE '%has_business_role%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_assets_admin_delete' AND cmd='DELETE'
      AND roles @> ARRAY['authenticated']::name[]
      AND qual ILIKE '%storage.foldername(objects.name)%'
      AND qual ILIKE '%has_business_role%'
  ) THEN
    RAISE EXCEPTION 'FALLO: las políticas de business-assets no aíslan las operaciones por ruta y administrador del negocio.';
  END IF;

  -- La política privada debe vincular UUID de negocio, UUID de postulación
  -- y ruta exacta guardada en la fila; conocer una ruta no basta.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='job_application_documents_business_admin_read'
      AND cmd='SELECT'
      AND qual ILIKE '%ja.id%'
      AND qual ILIKE '%ja.business_id%'
      AND qual ILIKE '%ja.resume_path%'
      AND qual ILIKE '%objects.name%'
      AND qual ILIKE '%storage.foldername(objects.name)%'
      AND qual ILIKE '%storage.filename(objects.name)%'
  ) THEN
    RAISE EXCEPTION 'FALLO: la política privada no vincula el archivo con su postulación y ruta exactas.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_expense_receipts_admin_read'
      AND cmd='SELECT'
      AND roles @> ARRAY['authenticated']::name[]
      AND qual ILIKE '%business-expense-receipts%'
      AND qual ILIKE '%has_business_role%'
      AND qual ILIKE '%business_admin%'
      AND qual ILIKE '%business_expenses%'
      AND qual ILIKE '%array_length%'
      AND qual ILIKE '%storage.filename%'
      AND qual ILIKE '%voided%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_expense_receipts_admin_upload'
      AND cmd='INSERT'
      AND roles @> ARRAY['authenticated']::name[]
      AND with_check ILIKE '%business-expense-receipts%'
      AND with_check ILIKE '%has_business_role%'
      AND with_check ILIKE '%business_admin%'
      AND with_check ILIKE '%status%'
      AND with_check ILIKE '%active%'
      AND with_check NOT ILIKE '%voided%'
      AND with_check ILIKE '%array_length%'
      AND with_check ILIKE '%storage.filename%'
  ) THEN
    RAISE EXCEPTION 'FALLO: comprobantes de gastos sin políticas privadas de lectura/carga para el administrador activo.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND roles @> ARRAY['anon']::name[]
      AND (
        coalesce(qual,'') ILIKE '%job-applications-private%'
        OR coalesce(qual,'') ILIKE '%business-expense-receipts%'
        OR coalesce(with_check,'') ILIKE '%job-applications-private%'
        OR coalesce(with_check,'') ILIKE '%business-expense-receipts%'
      )
  ) THEN
    RAISE EXCEPTION 'FALLO: anon tiene una política directa sobre hojas de vida o comprobantes financieros.';
  END IF;


  IF to_regclass('public.job_applications') IS NULL
     OR to_regclass('public.job_application_upload_sessions') IS NULL
     OR to_regclass('public.job_application_rate_limits') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan tablas base de postulaciones, sesiones de carga o límite de solicitudes.';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.job_applications'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.job_application_upload_sessions'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.job_application_rate_limits'::regclass) THEN
    RAISE EXCEPTION 'FALLO: las tablas de postulaciones/sesiones/límites deben tener RLS habilitado.';
  END IF;

  IF has_table_privilege('anon','public.job_applications','SELECT')
     OR has_table_privilege('anon','public.job_applications','INSERT')
     OR has_table_privilege('anon','public.job_applications','UPDATE')
     OR has_table_privilege('anon','public.job_applications','DELETE')
     OR has_table_privilege('authenticated','public.job_application_upload_sessions','SELECT')
     OR has_table_privilege('authenticated','public.job_application_upload_sessions','INSERT')
     OR has_table_privilege('authenticated','public.job_application_upload_sessions','UPDATE')
     OR has_table_privilege('authenticated','public.job_application_upload_sessions','DELETE')
     OR has_table_privilege('anon','public.job_application_upload_sessions','SELECT')
     OR has_table_privilege('anon','public.job_application_upload_sessions','INSERT')
     OR has_table_privilege('anon','public.job_application_upload_sessions','UPDATE')
     OR has_table_privilege('anon','public.job_application_upload_sessions','DELETE')
     OR has_table_privilege('anon','public.job_application_rate_limits','SELECT')
     OR has_table_privilege('anon','public.job_application_rate_limits','INSERT')
     OR has_table_privilege('anon','public.job_application_rate_limits','UPDATE')
     OR has_table_privilege('anon','public.job_application_rate_limits','DELETE')
     OR has_table_privilege('authenticated','public.job_application_rate_limits','SELECT')
     OR has_table_privilege('authenticated','public.job_application_rate_limits','INSERT')
     OR has_table_privilege('authenticated','public.job_application_rate_limits','UPDATE')
     OR has_table_privilege('authenticated','public.job_application_rate_limits','DELETE')
     OR has_table_privilege('authenticated','public.job_applications','INSERT')
     OR has_table_privilege('authenticated','public.job_applications','DELETE') THEN
    RAISE EXCEPTION 'FALLO: anon o authenticated conservan acceso directo indebido a postulaciones, sesiones o contadores privados.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='job_applications'
      AND policyname='job_applications_business_admin_read'
      AND cmd='SELECT'
      AND roles @> ARRAY['authenticated']::name[]
      AND qual ILIKE '%has_business_role%'
      AND qual ILIKE '%business_admin%'
      AND qual ILIKE '%business_is_active%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='job_applications'
      AND policyname='job_applications_business_admin_update'
      AND cmd='UPDATE'
      AND roles @> ARRAY['authenticated']::name[]
      AND qual ILIKE '%has_business_role%'
      AND qual ILIKE '%business_admin%'
      AND with_check ILIKE '%business_is_active%'
  ) THEN
    RAISE EXCEPTION 'FALLO: las postulaciones no están limitadas por RLS al administrador del negocio activo.';
  END IF;

  IF has_table_privilege('authenticated','public.job_applications','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: authenticated conserva UPDATE a nivel de tabla en postulaciones; deben existir solo permisos por columna.';
  END IF;

  IF NOT has_column_privilege('authenticated','public.job_applications','status','UPDATE')
     OR NOT has_column_privilege('authenticated','public.job_applications','admin_notes','UPDATE')
     OR has_column_privilege('authenticated','public.job_applications','business_id','UPDATE')
     OR has_column_privilege('authenticated','public.job_applications','applicant_name','UPDATE')
     OR has_column_privilege('authenticated','public.job_applications','resume_path','UPDATE')
     OR has_column_privilege('authenticated','public.job_applications','reviewed_by','UPDATE')
     OR has_column_privilege('authenticated','public.job_applications','reviewed_at','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los permisos de revisión permiten campos incorrectos o no habilitan los campos operativos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.job_applications'::regclass
      AND conname='job_applications_status_allowed_check'
      AND contype='c'
      AND pg_get_constraintdef(oid) ILIKE '%pending%'
      AND pg_get_constraintdef(oid) ILIKE '%reviewing%'
      AND pg_get_constraintdef(oid) ILIKE '%contacted%'
      AND pg_get_constraintdef(oid) ILIKE '%accepted%'
      AND pg_get_constraintdef(oid) ILIKE '%rejected%'
  ) THEN
    RAISE EXCEPTION 'FALLO: el estado de las postulaciones no tiene la restricción de valores permitidos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_proc p ON p.oid=t.tgfoid
    WHERE n.nspname='public'
      AND c.relname='job_applications'
      AND t.tgname='trg_job_application_review_audit'
      AND NOT t.tgisinternal
      AND p.proname='set_job_application_review_audit'
      AND NOT p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']::text[]
      AND position('auth.uid()' IN pg_get_functiondef(p.oid)) > 0
      AND position('transaction_timestamp()' IN pg_get_functiondef(p.oid)) > 0
  ) THEN
    RAISE EXCEPTION 'FALLO: falta el trigger que genera reviewed_by y reviewed_at desde PostgreSQL.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND coalesce(qual,'') ILIKE '%job-applications-private%'
      AND cmd <> 'SELECT'
  ) OR EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND coalesce(with_check,'') ILIKE '%job-applications-private%'
      AND cmd <> 'SELECT'
  ) THEN
    RAISE EXCEPTION 'FALLO: hay políticas de escritura directa sobre el bucket privado de hojas de vida; la carga debe usar URL firmada.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname='submit_public_job_application'
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']::text[]
      AND has_function_privilege('service_role',p.oid,'EXECUTE')
      AND NOT has_function_privilege('anon',p.oid,'EXECUTE')
      AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'FALLO: la RPC de postulación debe ser SECURITY DEFINER, usar search_path vacío y ejecutarse solo desde service_role.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname='consume_job_application_rate_limit'
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']::text[]
      AND has_function_privilege('service_role',p.oid,'EXECUTE')
      AND NOT has_function_privilege('anon',p.oid,'EXECUTE')
      AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'FALLO: el limitador de postulaciones no está restringido a service_role.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname='list_expired_job_application_upload_sessions'
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']::text[]
      AND has_function_privilege('service_role',p.oid,'EXECUTE')
      AND NOT has_function_privilege('anon',p.oid,'EXECUTE')
      AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'FALLO: la RPC de limpieza de sesiones debe estar restringida a service_role.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='job_applications'
      AND column_name='privacy_consent_version' AND data_type='text'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='job_applications'
      AND column_name='privacy_consent_at' AND data_type='timestamp with time zone'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.job_applications'::regclass
      AND conname='job_applications_privacy_consent_evidence_check'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta la evidencia versionada y fechada del consentimiento de postulaciones.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname='submit_public_job_application'
      AND pg_get_function_arguments(p.oid) =
        'p_application_id uuid, p_business_id uuid, p_content_page_id uuid, p_applicant_name text, p_applicant_contact text, p_applicant_message text, p_form_responses jsonb, p_privacy_consent boolean, p_privacy_consent_version text, p_resume_path text'
      AND position('job-application-2026-11-19-v1' IN pg_get_functiondef(p.oid)) > 0
      AND position('transaction_timestamp()' IN pg_get_functiondef(p.oid)) > 0
  ) THEN
    RAISE EXCEPTION 'FALLO: la RPC de postulaciones no valida la versión actual o no genera la fecha en PostgreSQL.';
  END IF;

  IF NOT has_column_privilege('anon','public.businesses','id','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','status','SELECT') THEN
    RAISE EXCEPTION 'FALLO: anon no tiene las columnas públicas mínimas para resolver contenido publicado.';
  END IF;

  IF NOT has_column_privilege('anon','public.businesses','name','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','slug','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','business_type','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','category','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','description','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','tagline','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','city','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','contact_phone','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','whatsapp_support','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','opening_hours','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','logo_url','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','public_suspension_message','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','delivery_fee','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','minimum_order_amount','SELECT') THEN
    RAISE EXCEPTION 'FALLO: anon no puede leer todas las columnas públicas necesarias del directorio.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_content_pages'
      AND policyname='business_content_pages_public_read'
      AND cmd='SELECT' AND roles @> ARRAY['anon']::name[]
      AND qual ILIKE '%EXISTS%'
      AND qual NOT ILIKE '%private.business_is_active%'
      AND qual NOT ILIKE '%private.has_business_role%'
  ) THEN
    RAISE EXCEPTION 'FALLO: el contenido público anon todavía depende de helpers privados.';
  END IF;

  IF NOT has_table_privilege('anon','public.products','SELECT')
     OR NOT EXISTS (
       SELECT 1 FROM pg_policies
       WHERE schemaname='public' AND tablename='businesses'
         AND policyname='businesses_public_directory_anon'
         AND cmd='SELECT' AND roles @> ARRAY['anon']::name[]
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_policies
       WHERE schemaname='public' AND tablename='products'
         AND policyname='products_public_active_anon'
         AND cmd='SELECT' AND roles @> ARRAY['anon']::name[]
         AND qual ILIKE '%EXISTS%'
         AND qual NOT ILIKE '%private.business_is_active%'
     ) THEN
    RAISE EXCEPTION 'FALLO: el catálogo público anon no tiene grants/políticas independientes de helpers privados.';
  END IF;

  IF has_function_privilege('anon','private.business_is_active(uuid)','EXECUTE')
     OR has_function_privilege('anon','private.has_business_role(uuid,text[])','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: no se debe conceder a anon ejecución de helpers privados.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_assets_admin_upload' AND cmd='INSERT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_assets_admin_read' AND cmd='SELECT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='job_application_documents_business_admin_read' AND cmd='SELECT'
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan políticas de Storage para activos o documentos privados.';
  END IF;


  IF to_regclass('public.product_costs') IS NULL
     OR to_regclass('public.order_item_costs') IS NULL
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.product_costs'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.order_item_costs'::regclass) THEN
    RAISE EXCEPTION 'FALLO: faltan tablas de costos o RLS no está habilitado.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='product_costs'
      AND policyname='product_costs_admin_select'
      AND cmd='SELECT' AND qual NOT ILIKE '%is_platform_owner%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='product_costs'
      AND policyname='product_costs_admin_insert'
      AND cmd='INSERT' AND with_check NOT ILIKE '%is_platform_owner%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='product_costs'
      AND policyname='product_costs_admin_update'
      AND cmd='UPDATE' AND qual NOT ILIKE '%is_platform_owner%'
      AND with_check NOT ILIKE '%is_platform_owner%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='order_item_costs'
      AND policyname='order_item_costs_admin_select'
      AND cmd='SELECT' AND qual NOT ILIKE '%is_platform_owner%'
  ) THEN
    RAISE EXCEPTION 'FALLO: las políticas de costos permiten acceso técnico global o faltan.';
  END IF;

  IF NOT has_table_privilege('authenticated','public.product_costs','SELECT')
     OR NOT has_table_privilege('authenticated','public.product_costs','INSERT')
     OR NOT has_table_privilege('authenticated','public.product_costs','UPDATE')
     OR has_table_privilege('anon','public.product_costs','SELECT')
     OR has_table_privilege('anon','public.order_item_costs','SELECT')
     OR has_table_privilege('authenticated','public.order_item_costs','INSERT')
     OR has_table_privilege('authenticated','public.order_item_costs','UPDATE')
     OR has_table_privilege('authenticated','public.order_item_costs','DELETE') THEN
    RAISE EXCEPTION 'FALLO: privilegios incorrectos en tablas de costos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='order_item_costs'
      AND column_name='unit_cost'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='product_costs'
      AND column_name='cost_price'
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan columnas para costo unitario e histórico.';
  END IF;
  IF NOT EXISTS (
       SELECT 1 FROM pg_trigger t
       WHERE t.tgrelid='public.order_item_costs'::regclass
         AND t.tgname='order_item_costs_immutable'
         AND NOT t.tgisinternal
         AND (t.tgtype & 16) = 16
         AND (t.tgtype & 8) = 8
     )
     OR has_table_privilege('service_role','public.order_item_costs','UPDATE')
     OR has_table_privilege('service_role','public.order_item_costs','DELETE')
     OR has_table_privilege('service_role','public.order_item_costs','TRUNCATE') THEN
    RAISE EXCEPTION 'FALLO: el costo histórico de las líneas puede modificarse o eliminarse.';
  END IF;


  IF to_regclass('public.idx_financial_completed_business_type_date') IS NULL
     OR to_regclass('public.idx_business_expenses_paid_at') IS NULL
     OR to_regclass('public.idx_cancellation_approved_business_decided') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan índices para consultar pagos, cancelaciones y gastos por fecha de movimiento.';
  END IF;
  IF to_regprocedure('public.get_business_admin_profit_report(uuid,date,date)') IS NULL THEN
    RAISE EXCEPTION 'FALLO: falta el RPC de reporte financiero por periodo.';
  END IF;
  IF pg_get_functiondef('public.get_business_admin_profit_report(uuid,date,date)'::regprocedure)
     NOT LIKE '%inventory_cost_reversals%'
     OR pg_get_functiondef('public.get_business_admin_profit_report(uuid,date,date)'::regprocedure)
     NOT LIKE '%decided_at%'
     OR pg_get_functiondef('public.get_business_admin_profit_report(uuid,date,date)'::regprocedure)
     LIKE '%AT TIME ZONE ''America/Bogota'')::date%' THEN
    RAISE EXCEPTION 'FALLO: el reporte no revierte el costo de inventario en la fecha de aprobación de cancelación.';
  END IF;
  IF position('CASE WHEN missing_cost_lines=0' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('THEN NULL END' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: el reporte presenta ganancias numéricas aunque falten costos históricos.';
  END IF;
  IF NOT has_function_privilege('authenticated','public.get_business_admin_profit_report(uuid,date,date)','EXECUTE')
     OR has_function_privilege('anon','public.get_business_admin_profit_report(uuid,date,date)','EXECUTE')
     OR NOT (
       SELECT p.prosecdef
       FROM pg_proc p
       WHERE p.oid='public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     )
     OR position('has_business_role' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('business_is_active' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: el reporte financiero no está limitado al administrador activo del negocio.';
  END IF;


  IF to_regprocedure('public.attach_business_expense_receipt(uuid,text)') IS NULL
     OR to_regprocedure('public.pay_business_expense(uuid,text,text)') IS NULL
     OR to_regprocedure('public.register_business_expense(uuid,text,text,numeric,date,text,text,text,text,text,text)') IS NULL
     OR to_regprocedure('public.void_business_expense(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan RPCs de confirmación de gasto o asociación de comprobantes.';
  END IF;

  IF position('v_expense.payment_status <> ''pending''' IN lower(pg_get_functiondef(
       'public.void_business_expense(uuid,text)'::regprocedure
     ))) = 0
     OR position('payment_status=''pending''' IN lower(pg_get_functiondef(
       'public.void_business_expense(uuid,text)'::regprocedure
     ))) = 0
     OR position('old.payment_status = ''pending''' IN lower(pg_get_functiondef(
       'private.guard_business_expense_update()'::regprocedure
     ))) = 0
     OR position('new.payment_status = ''pending''' IN lower(pg_get_functiondef(
       'private.guard_business_expense_update()'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: se permite anular un gasto pagado y retirarlo del histórico financiero.';
  END IF;
  IF has_function_privilege('anon','public.attach_business_expense_receipt(uuid,text)','EXECUTE')
     OR has_function_privilege('anon','public.pay_business_expense(uuid,text,text)','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.attach_business_expense_receipt(uuid,text)','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.pay_business_expense(uuid,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: privilegios incorrectos en RPCs de gastos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id='business-expense-receipts' AND public=false
      AND file_size_limit=5242880
  ) THEN
    RAISE EXCEPTION 'FALLO: el bucket privado de comprobantes de gastos no está configurado.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_expense_receipts_admin_read' AND cmd='SELECT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_expense_receipts_admin_upload' AND cmd='INSERT'
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan políticas privadas para comprobantes de gastos.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_expense_receipts_public_read'
  ) THEN
    RAISE EXCEPTION 'FALLO: no debe existir lectura pública de comprobantes de gastos.';
  END IF;

  -- Cuentas internas: los clientes autenticados no pueden crear ni cambiar membresías.
  IF has_table_privilege('authenticated','public.business_memberships','INSERT')
     OR has_table_privilege('authenticated','public.business_memberships','UPDATE')
     OR has_table_privilege('authenticated','public.business_memberships','DELETE')
     OR has_table_privilege('anon','public.business_memberships','SELECT') THEN
    RAISE EXCEPTION 'FALLO: authenticated/anon tienen privilegios indebidos sobre membresías.';
  END IF;

  -- El usuario solo puede modificar datos de presentación; nunca su rol o bloqueo.
  IF has_column_privilege('authenticated','public.profiles','platform_role','UPDATE')
     OR has_column_privilege('authenticated','public.profiles','is_blocked','UPDATE')
     OR has_column_privilege('authenticated','public.profiles','blocked_reason','UPDATE')
     OR has_column_privilege('authenticated','public.profiles','id','UPDATE')
     OR NOT has_column_privilege('authenticated','public.profiles','display_name','UPDATE')
     OR NOT has_column_privilege('authenticated','public.profiles','avatar_url','UPDATE')
     OR NOT has_column_privilege('authenticated','public.profiles','phone','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los privilegios de profiles permiten alterar roles/bloqueos o impiden editar datos propios.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='profiles'
      AND policyname='profiles_select_self_or_same_business_admin'
      AND cmd='SELECT' AND qual NOT ILIKE '%is_platform_owner%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_memberships'
      AND policyname='memberships_select_self_admin_owner'
      AND cmd='SELECT' AND qual NOT ILIKE '%is_platform_owner%'
  ) THEN
    RAISE EXCEPTION 'FALLO: profiles/memberships conservan lectura global del propietario o faltan políticas limitadas.';
  END IF;

  -- Solicitudes de bloqueo: solo admin del negocio crea; solo servicio resuelve.
  IF to_regclass('public.access_block_requests') IS NULL
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.access_block_requests'::regclass)
     OR to_regprocedure('public.resolve_access_block_request(uuid,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan la tabla protegida o la RPC de resolución de bloqueos.';
  END IF;
  IF has_table_privilege('anon','public.access_block_requests','SELECT')
     OR has_table_privilege('authenticated','public.access_block_requests','SELECT')
     OR has_table_privilege('authenticated','public.access_block_requests','UPDATE')
     OR has_table_privilege('authenticated','public.access_block_requests','DELETE')
     OR has_function_privilege('anon','public.resolve_access_block_request(uuid,text,text,uuid)','EXECUTE')
     OR has_function_privilege('authenticated','public.resolve_access_block_request(uuid,text,text,uuid)','EXECUTE')
     OR NOT has_function_privilege('service_role','public.resolve_access_block_request(uuid,text,text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: las solicitudes de bloqueo o su RPC tienen privilegios excesivos.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='access_block_requests'
      AND policyname='access_block_requests_admin_submit'
      AND cmd='INSERT' AND with_check ILIKE '%business_admin%'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta la política de solicitud de bloqueo limitada al administrador del negocio.';
  END IF;

  -- Inventario: tabla, RLS, trigger de altas/cambios y RPC de ajuste.
  IF to_regclass('public.inventory_movements') IS NULL
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.inventory_movements'::regclass)
     OR to_regprocedure('public.adjust_business_inventory(uuid,uuid,integer,integer,text)') IS NULL THEN
    RAISE EXCEPTION 'FALLO: falta el registro de movimientos de inventario, RLS o RPC de ajuste.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.products'::regclass
      AND tgname='products_inventory_movement_insert' AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.products'::regclass
      AND tgname='products_inventory_movement_update' AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan los triggers que registran movimientos de inventario.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.order_items'::regclass
      AND tgname='order_items_history_guard'
      AND NOT tgisinternal
      AND (tgtype & 4) = 4
      AND (tgtype & 8) = 8
      AND (tgtype & 16) = 16
  ) OR to_regprocedure('private.guard_order_item_history()') IS NULL THEN
    RAISE EXCEPTION 'FALLO: las líneas de pedido no tienen protección de snapshot histórico.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.order_items'::regclass
      AND conname='order_items_product_id_fkey'
      AND contype='f'
      AND confdeltype='r'
      AND convalidated
      AND pg_get_constraintdef(oid) ILIKE '%product_id%'
      AND pg_get_constraintdef(oid) ILIKE '%products(id)%'
  ) THEN
    RAISE EXCEPTION 'FALLO: eliminar un producto todavía puede romper la referencia de las líneas de pedido.';
  END IF;

  IF position(
    'new.product_id is null' IN lower(pg_get_functiondef(
      'private.guard_order_item_history()'::regprocedure
    ))
  ) = 0 OR position(
    'v_order_business_id <> v_product_business_id' IN lower(pg_get_functiondef(
      'private.guard_order_item_history()'::regprocedure
    ))
  ) = 0 THEN
    RAISE EXCEPTION 'FALLO: el trigger de líneas de pedido no valida referencia y pertenencia al mismo negocio.';
  END IF;

  IF position(
    'oi.product_id is null' IN lower(pg_get_functiondef(
      'public.decide_order_cancellation(uuid,text,text)'::regprocedure
    ))
  ) = 0 THEN
    RAISE EXCEPTION 'FALLO: la cancelación no bloquea pedidos históricos con productos sin referencia para restituir.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.inventory_movements'::regclass
      AND tgname='inventory_movements_immutable'
      AND NOT tgisinternal
      AND (tgtype & 16) = 16
      AND (tgtype & 8) = 8
  ) OR to_regprocedure('private.prevent_inventory_movement_mutation()') IS NULL THEN
    RAISE EXCEPTION 'FALLO: el historial de inventario no tiene protección contra UPDATE/DELETE.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_movements'::regclass
      AND conname='inventory_movements_direction_check'
      AND contype='c'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta la restricción que valida el sentido de cada movimiento de inventario.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_movements'::regclass
      AND conname='inventory_movements_product_business_fk'
      AND contype='f'
      AND confdeltype='r'
      AND convalidated
      AND pg_get_constraintdef(oid) ILIKE '%(business_id, product_id)%'
      AND pg_get_constraintdef(oid) ILIKE '%products(business_id, id)%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_movements'::regclass
      AND conname='inventory_movements_delta_check'
      AND contype='c' AND convalidated
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_movements'::regclass
      AND conname='inventory_movements_direction_check'
      AND contype='c' AND convalidated
      AND pg_get_constraintdef(oid) ILIKE '%sale%'
      AND pg_get_constraintdef(oid) ILIKE '%cancellation_return%'
  ) THEN
    RAISE EXCEPTION 'FALLO: las restricciones de relación, delta y dirección del libro de inventario no están validadas.';
  END IF;

  IF has_table_privilege('service_role','public.inventory_movements','INSERT')
     OR has_table_privilege('service_role','public.inventory_movements','UPDATE')
     OR has_table_privilege('service_role','public.inventory_movements','DELETE')
     OR has_table_privilege('service_role','public.inventory_movements','TRUNCATE') THEN
    RAISE EXCEPTION 'FALLO: service_role conserva escritura directa sobre el historial inmutable de inventario.';
  END IF;

  IF NOT has_function_privilege('authenticated','public.adjust_business_inventory(uuid,uuid,integer,integer,text)','EXECUTE')
     OR has_function_privilege('anon','public.adjust_business_inventory(uuid,uuid,integer,integer,text)','EXECUTE')
     OR NOT has_table_privilege('authenticated','public.inventory_movements','SELECT')
     OR has_table_privilege('authenticated','public.inventory_movements','INSERT')
     OR has_table_privilege('authenticated','public.inventory_movements','UPDATE')
     OR has_table_privilege('authenticated','public.inventory_movements','DELETE')
     OR has_table_privilege('anon','public.inventory_movements','SELECT')
     OR has_table_privilege('anon','public.inventory_movements','INSERT')
     OR has_table_privilege('anon','public.inventory_movements','UPDATE')
     OR has_table_privilege('anon','public.inventory_movements','DELETE')
     OR has_column_privilege('authenticated','public.products','inventory','UPDATE')
     OR has_column_privilege('anon','public.products','inventory','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los permisos directos de inventario permiten alterar existencias o el historial.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.oid='public.adjust_business_inventory(uuid,uuid,integer,integer,text)'::regprocedure
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']::text[]
  ) THEN
    RAISE EXCEPTION 'FALLO: la RPC de ajuste de inventario debe ser SECURITY DEFINER con search_path vacío.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='inventory_movements'
      AND policyname='inventory_movements_admin_read'
      AND cmd='SELECT'
      AND qual ILIKE '%business_admin%'
      AND qual ILIKE '%business_is_active%'
  ) THEN
    RAISE EXCEPTION 'FALLO: el historial de inventario no está limitado a administradores de negocios activos.';
  END IF;

  IF position(
    'product_name' IN lower(pg_get_functiondef(
      'public.create_public_order(uuid,text,text,text,text,text,text,jsonb)'::regprocedure
    ))
  ) = 0 OR position(
    'unit_price' IN lower(pg_get_functiondef(
      'public.create_public_order(uuid,text,text,text,text,text,text,jsonb)'::regprocedure
    ))
  ) = 0 THEN
    RAISE EXCEPTION 'FALLO: el checkout no conserva nombre y precio como snapshot de la línea de pedido.';
  END IF;


  -- Checkout y cancelación: bloqueo determinista y restitución atómica.
  IF to_regprocedure('public.create_public_order(uuid,text,text,text,text,text,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'FALLO: falta la RPC base de checkout con control de inventario.';
  END IF;
  IF position('order by (value->>''product_id'')::uuid' IN lower(pg_get_functiondef(
       'public.create_public_order(uuid,text,text,text,text,text,text,jsonb)'::regprocedure
     ))) = 0
     OR position('for update' IN lower(pg_get_functiondef(
       'public.create_public_order(uuid,text,text,text,text,text,text,jsonb)'::regprocedure
     ))) = 0
     OR position('inventory = inventory -' IN lower(pg_get_functiondef(
       'public.create_public_order(uuid,text,text,text,text,text,text,jsonb)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: el checkout no bloquea productos en orden determinista o no descuenta inventario.';
  END IF;

  -- La aprobación de cancelación solo modifica el pedido y el inventario.
  -- Nunca debe simular un reembolso ni cambiar el estado financiero a refunded.
  IF position('payment_status = ''refunded''' IN lower(pg_get_functiondef(
       'public.decide_order_cancellation(uuid,text,text)'::regprocedure
     ))) > 0
     OR position('insert into public.financial_transactions' IN lower(pg_get_functiondef(
       'public.decide_order_cancellation(uuid,text,text)'::regprocedure
     ))) > 0 THEN
    RAISE EXCEPTION 'FALLO: la cancelación está registrando un reembolso o marcando dinero devuelto sin la operación financiera separada.';
  END IF;

  IF position('v_request.request_status <> ''pending''' IN lower(pg_get_functiondef(
       'public.decide_order_cancellation(uuid,text,text)'::regprocedure
     ))) = 0
     OR position('v_request.order_status in (''delivered'',''cancelled'')' IN lower(pg_get_functiondef(
       'public.decide_order_cancellation(uuid,text,text)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: la decisión no bloquea solicitudes ya atendidas o pedidos terminados.';
  END IF;

  -- La reversión de costo solo corresponde a pedidos con ingreso real completado.
  IF position('paid.transaction_type=''payment_received''' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('paid.status=''completed''' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0
     OR position('paid.currency=''cop''' IN lower(pg_get_functiondef(
       'public.get_business_admin_profit_report(uuid,date,date)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: el reporte puede revertir costos de pedidos cancelados sin un pago real completado en COP.';
  END IF;

  IF position('for update of p' IN lower(pg_get_functiondef(
       'public.decide_order_cancellation(uuid,text,text)'::regprocedure
     ))) = 0
     OR position('order by p.id' IN lower(pg_get_functiondef(
       'public.decide_order_cancellation(uuid,text,text)'::regprocedure
     ))) = 0
     OR position('inventory = p.inventory + quantities.quantity' IN lower(pg_get_functiondef(
       'public.decide_order_cancellation(uuid,text,text)'::regprocedure
     ))) = 0
     OR position('v_restored_products <> v_expected_products' IN lower(pg_get_functiondef(
       'public.decide_order_cancellation(uuid,text,text)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: la cancelación no bloquea/restaura todos los productos de forma controlada.';
  END IF;

  -- Métodos de pago: la escritura directa queda cerrada y se usa la RPC atómica.
  IF to_regprocedure('public.save_business_payment_methods(uuid,jsonb)') IS NULL
     OR has_table_privilege('authenticated','public.business_payment_methods','INSERT')
     OR has_table_privilege('authenticated','public.business_payment_methods','UPDATE')
     OR has_column_privilege('authenticated','public.business_payment_methods','business_id','INSERT')
     OR has_column_privilege('authenticated','public.business_payment_methods','method_code','INSERT')
     OR has_column_privilege('authenticated','public.business_payment_methods','display_name','UPDATE')
     OR NOT has_function_privilege('authenticated','public.save_business_payment_methods(uuid,jsonb)','EXECUTE')
     OR has_function_privilege('anon','public.save_business_payment_methods(uuid,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: los métodos de pago permiten escritura directa o falta la RPC atómica.';
  END IF;

  -- Membresías técnicas: todas las RPC se ejecutan únicamente desde la Edge Function.
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='business_memberships'
      AND column_name='job_title'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta business_memberships.job_title.';
  END IF;
  IF to_regprocedure('public.create_business_membership_assignment(uuid,uuid,text,text,text,uuid,boolean)') IS NULL
     OR to_regprocedure('public.update_business_membership_assignment(uuid,text,text,uuid)') IS NULL
     OR to_regprocedure('public.suspend_business_membership(uuid,text,uuid)') IS NULL
     OR to_regprocedure('public.reactivate_business_membership(uuid,text,uuid)') IS NULL
     OR to_regprocedure('public.set_technical_business_status(uuid,text,text,text,uuid)') IS NULL
     OR to_regprocedure('public.moderate_business_content_transactionally(uuid,text,text,uuid)') IS NULL
     OR to_regprocedure('public.create_technical_business_transactional(text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan RPC transaccionales de membresías o administración técnica.';
  END IF;
  IF NOT has_function_privilege('service_role','public.create_business_membership_assignment(uuid,uuid,text,text,text,uuid,boolean)','EXECUTE')
     OR NOT has_function_privilege('service_role','public.update_business_membership_assignment(uuid,text,text,uuid)','EXECUTE')
     OR NOT has_function_privilege('service_role','public.suspend_business_membership(uuid,text,uuid)','EXECUTE')
     OR NOT has_function_privilege('service_role','public.reactivate_business_membership(uuid,text,uuid)','EXECUTE')
     OR NOT has_function_privilege('service_role','public.set_technical_business_status(uuid,text,text,text,uuid)','EXECUTE')
     OR NOT has_function_privilege('service_role','public.moderate_business_content_transactionally(uuid,text,text,uuid)','EXECUTE')
     OR NOT has_function_privilege('service_role','public.create_technical_business_transactional(text,text,text,uuid)','EXECUTE')
     OR has_function_privilege('anon','public.create_business_membership_assignment(uuid,uuid,text,text,text,uuid,boolean)','EXECUTE')
     OR has_function_privilege('authenticated','public.create_business_membership_assignment(uuid,uuid,text,text,text,uuid,boolean)','EXECUTE')
     OR has_function_privilege('anon','public.set_technical_business_status(uuid,text,text,text,uuid)','EXECUTE')
     OR has_function_privilege('authenticated','public.set_technical_business_status(uuid,text,text,text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: las RPC técnicas no están restringidas a service_role.';
  END IF;

  -- Los perfiles son privados: cada usuario autenticado solo lee su fila.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='profiles'
      AND policyname='profiles_select_self'
      AND cmd='SELECT'
      AND qual ILIKE '%auth.uid%'
      AND qual ILIKE '%id%'
      AND qual NOT ILIKE '%is_platform_owner%'
  ) OR EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='profiles'
      AND cmd='SELECT'
      AND (coalesce(qual,'') ILIKE '%is_platform_owner%'
        OR coalesce(with_check,'') ILIKE '%is_platform_owner%')
  ) THEN
    RAISE EXCEPTION 'FALLO: perfiles debe permitir lectura propia y no acceso global del propietario técnico.';
  END IF;

  IF has_column_privilege('authenticated','public.profiles','platform_role','UPDATE')
     OR has_column_privilege('authenticated','public.profiles','is_blocked','UPDATE')
     OR has_column_privilege('authenticated','public.profiles','blocked_reason','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: authenticated no puede modificar rol, bloqueo ni motivo de bloqueo del perfil.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_memberships'
      AND policyname='memberships_select_self_or_admin'
      AND cmd='SELECT'
      AND qual ILIKE '%auth.uid%'
      AND qual ILIKE '%business_admin%'
  ) OR EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_memberships'
      AND cmd='SELECT'
      AND (coalesce(qual,'') ILIKE '%is_platform_owner%'
        OR coalesce(with_check,'') ILIKE '%is_platform_owner%')
  ) THEN
    RAISE EXCEPTION 'FALLO: membresías debe limitar lectura a la cuenta propia o al administrador del negocio.';
  END IF;

  -- Ninguna política de pedidos, partidas, cancelaciones o finanzas puede
  -- conservar un bypass del propietario técnico, aunque tenga otro nombre.
  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN (
        'orders', 'order_items', 'order_cancellation_requests',
        'financial_transactions', 'refund_details'
      )
      AND (
        coalesce(qual, '') ILIKE '%is_platform_owner%'
        OR coalesce(with_check, '') ILIKE '%is_platform_owner%'
      )
  ) THEN
    RAISE EXCEPTION 'FALLO: existe un bypass del propietario técnico en políticas de pedidos, cancelaciones o finanzas.';
  END IF;

  -- Las RPC que reciben IDs de pedidos/solicitudes deben autorizar el negocio
  -- antes del primer FOR UPDATE y volver a validar después de adquirir el lock.
  v_mark_payment := pg_get_functiondef(
    'public.mark_order_payment_received(uuid,text,text,text)'::regprocedure
  );
  v_complete_refund := pg_get_functiondef(
    'public.complete_order_refund(uuid,text,text,text,text)'::regprocedure
  );
  v_decide_cancellation := pg_get_functiondef(
    'public.decide_order_cancellation(uuid,text,text)'::regprocedure
  );

  IF strpos(v_mark_payment, 'private.has_business_role')
       = 0
     OR strpos(v_mark_payment, 'private.has_business_role')
       > strpos(v_mark_payment, 'FOR UPDATE')
     OR (length(v_mark_payment) - length(replace(v_mark_payment, 'private.has_business_role', '')))
       < 2 THEN
    RAISE EXCEPTION 'FALLO: mark_order_payment_received debe autorizar antes del bloqueo y revalidar después.';
  END IF;

  IF strpos(v_complete_refund, 'private.has_business_role')
       = 0
     OR strpos(v_complete_refund, 'private.has_business_role')
       > strpos(v_complete_refund, 'FOR UPDATE')
     OR (length(v_complete_refund) - length(replace(v_complete_refund, 'private.has_business_role', '')))
       < 2 THEN
    RAISE EXCEPTION 'FALLO: complete_order_refund debe autorizar antes del bloqueo y revalidar después.';
  END IF;

  IF strpos(v_decide_cancellation, 'private.has_business_role')
       = 0
     OR strpos(v_decide_cancellation, 'private.has_business_role')
       > strpos(v_decide_cancellation, 'FOR UPDATE')
     OR (length(v_decide_cancellation) - length(replace(v_decide_cancellation, 'private.has_business_role', '')))
       < 2 THEN
    RAISE EXCEPTION 'FALLO: decide_order_cancellation debe autorizar antes del bloqueo y revalidar después.';
  END IF;

  RAISE NOTICE 'OK: estructura, RPCs, RLS, privilegios y buckets del paquete están presentes.';
END
$verify$;

-- Comprobación adicional, también de solo lectura:
-- ejecutar después de este bloque:
-- database/orders/verify-order-financial-access.sql

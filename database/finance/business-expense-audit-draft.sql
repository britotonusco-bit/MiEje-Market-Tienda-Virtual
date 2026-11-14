-- MiEje Market Independiente
-- Transiciones protegidas y auditoría de gastos.
-- BORRADOR: depende de las tablas y helpers existentes y del bucket
-- business-expense-receipts-draft.sql. Revisar en staging antes de ejecutar.

-- Mantener la función de trigger compatible con tres cambios permitidos:
-- (1) pendiente -> pagado, (2) activo -> anulado, (3) adjuntar comprobante una vez.
CREATE OR REPLACE FUNCTION private.guard_business_expense_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  IF OLD.status = 'voided' THEN
    RAISE EXCEPTION 'Un gasto anulado no puede modificarse.';
  END IF;

  IF OLD.status = 'active'
     AND NEW.status = 'active'
     AND OLD.payment_status = 'pending'
     AND NEW.payment_status = 'paid'
     AND (to_jsonb(NEW) - ARRAY['payment_status','payment_method','transaction_reference','paid_at','updated_at'])
         = (to_jsonb(OLD) - ARRAY['payment_status','payment_method','paid_at','updated_at'])
  THEN
    IF NEW.payment_method IS NULL OR NEW.paid_at IS NULL THEN
      RAISE EXCEPTION 'Para marcar el gasto como pagado debes indicar método y fecha.';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF OLD.status = 'active'
     AND NEW.status = 'active'
     AND OLD.receipt_path IS NULL
     AND NEW.receipt_path IS NOT NULL
     AND (to_jsonb(NEW) - ARRAY['receipt_path','updated_at'])
         = (to_jsonb(OLD) - ARRAY['receipt_path','updated_at'])
  THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF OLD.status = 'active'
     AND NEW.status = 'voided'
     AND NEW.voided_by = (SELECT auth.uid())
     AND (to_jsonb(NEW) - ARRAY['status','void_reason','voided_by','voided_at','updated_at'])
         = (to_jsonb(OLD) - ARRAY['status','void_reason','voided_by','voided_at','updated_at'])
  THEN
    IF NEW.void_reason IS NULL OR length(btrim(NEW.void_reason)) = 0 OR NEW.voided_at IS NULL THEN
      RAISE EXCEPTION 'Debes indicar el motivo y la fecha de anulación.';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Los gastos no pueden editarse libremente. Anula el registro y crea uno nuevo si necesitas corregirlo.';
END;
$function$;


-- Siempre se crea un gasto pendiente. El estado pagado solo se alcanza por RPC.
CREATE OR REPLACE FUNCTION public.register_business_expense(
  p_business_id uuid,
  p_category text,
  p_description text,
  p_amount numeric,
  p_expense_date date DEFAULT ((now() AT TIME ZONE 'America/Bogota'))::date,
  p_payment_status text DEFAULT 'pending',
  p_payment_method text DEFAULT NULL,
  p_supplier text DEFAULT NULL,
  p_transaction_reference text DEFAULT NULL,
  p_receipt_path text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_expense_id uuid;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE='42501';
  END IF;
  IF private.is_platform_owner()
     OR NOT private.business_is_active(p_business_id)
     OR NOT private.has_business_role(p_business_id, ARRAY['business_admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el administrador del negocio activo puede registrar gastos.' USING ERRCODE='42501';
  END IF;
  IF p_payment_status IS DISTINCT FROM 'pending' OR p_payment_method IS NOT NULL THEN
    RAISE EXCEPTION 'El gasto se crea pendiente. Registra el pago mediante la opción de confirmar pago.' USING ERRCODE='22023';
  END IF;
  IF p_category IS NULL OR char_length(btrim(p_category)) NOT BETWEEN 1 AND 80
     OR p_description IS NULL OR char_length(btrim(p_description)) NOT BETWEEN 1 AND 200
     OR p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Revisa categoría, descripción e importe del gasto.' USING ERRCODE='22023';
  END IF;
  IF p_supplier IS NOT NULL AND char_length(btrim(p_supplier)) > 160
     OR p_transaction_reference IS NOT NULL AND char_length(btrim(p_transaction_reference)) > 160
     OR p_notes IS NOT NULL AND char_length(p_notes) > 2000 THEN
    RAISE EXCEPTION 'Uno de los campos supera la longitud permitida.' USING ERRCODE='22023';
  END IF;
  IF p_receipt_path IS NOT NULL THEN
    RAISE EXCEPTION 'Crea primero el gasto y adjunta el comprobante después.' USING ERRCODE='22023';
  END IF;

  INSERT INTO public.business_expenses (
    business_id, expense_date, category, description, amount,
    payment_status, payment_method, supplier, transaction_reference,
    receipt_path, notes, status, created_by
  ) VALUES (
    p_business_id,
    coalesce(p_expense_date, (now() AT TIME ZONE 'America/Bogota')::date),
    btrim(p_category), btrim(p_description), p_amount,
    'pending', NULL, nullif(btrim(p_supplier), ''),
    nullif(btrim(p_transaction_reference), ''), NULL,
    nullif(btrim(p_notes), ''), 'active', v_actor
  ) RETURNING id INTO v_expense_id;

  INSERT INTO public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
  VALUES (
    p_business_id,v_actor,'business_expense.created','business_expense',v_expense_id::text,
    jsonb_build_object('amount',p_amount,'category',btrim(p_category),'expense_date',coalesce(p_expense_date,(now() AT TIME ZONE 'America/Bogota')::date),'payment_status','pending')
  );
  RETURN v_expense_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.register_business_expense(uuid,text,text,numeric,date,text,text,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_business_expense(uuid,text,text,numeric,date,text,text,text,text,text,text) TO authenticated;


-- Confirmación manual de un pago ya realizado. No procesa dinero ni contacta bancos.
DROP FUNCTION IF EXISTS public.pay_business_expense(uuid,text);
CREATE OR REPLACE FUNCTION public.pay_business_expense(
  p_expense_id uuid,
  p_payment_method text,
  p_transaction_reference text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_expense public.business_expenses%ROWTYPE;
  v_actor uuid := auth.uid();
  v_method text := lower(btrim(p_payment_method));
  v_reference text := nullif(btrim(p_transaction_reference),'');
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE='42501'; END IF;
  IF v_method IS NULL OR v_method NOT IN ('cash','transfer','card','other') THEN
    RAISE EXCEPTION 'Método de pago no válido.' USING ERRCODE='22023';
  END IF;
  IF v_method IN ('transfer','card') AND v_reference IS NULL THEN
    RAISE EXCEPTION 'Para transferencia o tarjeta debes registrar la referencia del pago.' USING ERRCODE='22023';
  END IF;
  IF v_reference IS NOT NULL AND char_length(v_reference) > 160 THEN
    RAISE EXCEPTION 'La referencia no puede superar 160 caracteres.' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_expense
  FROM public.business_expenses WHERE id=p_expense_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Gasto no encontrado.' USING ERRCODE='P0002'; END IF;
  IF private.is_platform_owner()
     OR NOT private.business_is_active(v_expense.business_id)
     OR NOT private.has_business_role(v_expense.business_id,ARRAY['business_admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el administrador del negocio activo puede confirmar el pago.' USING ERRCODE='42501';
  END IF;
  IF v_expense.status <> 'active' OR v_expense.payment_status <> 'pending' THEN
    RAISE EXCEPTION 'El gasto ya no está pendiente o fue anulado.' USING ERRCODE='23514';
  END IF;

  UPDATE public.business_expenses
  SET payment_status='paid', payment_method=v_method,
      transaction_reference=coalesce(v_reference,transaction_reference),
      paid_at=now(), updated_at=now()
  WHERE id=p_expense_id AND business_id=v_expense.business_id
    AND status='active' AND payment_status='pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo confirmar el pago; actualiza el listado.' USING ERRCODE='40001'; END IF;

  INSERT INTO public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
  VALUES (
    v_expense.business_id,v_actor,'business_expense.payment_received',
    'business_expense',p_expense_id::text,
    jsonb_build_object('amount',v_expense.amount,'payment_method',v_method,'reference',v_reference)
  );
  RETURN p_expense_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.pay_business_expense(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pay_business_expense(uuid,text,text) TO authenticated;


CREATE OR REPLACE FUNCTION public.void_business_expense(p_expense_id uuid,p_void_reason text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_expense public.business_expenses%ROWTYPE;
  v_actor uuid := auth.uid();
  v_reason text := btrim(p_void_reason);
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE='42501'; END IF;
  IF v_reason IS NULL OR char_length(v_reason) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'El motivo debe tener entre 3 y 500 caracteres.' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_expense FROM public.business_expenses WHERE id=p_expense_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Gasto no encontrado.' USING ERRCODE='P0002'; END IF;
  IF private.is_platform_owner()
     OR NOT private.business_is_active(v_expense.business_id)
     OR NOT private.has_business_role(v_expense.business_id,ARRAY['business_admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el administrador del negocio activo puede anular gastos.' USING ERRCODE='42501';
  END IF;
  IF v_expense.status <> 'active' THEN RAISE EXCEPTION 'El gasto ya fue anulado.' USING ERRCODE='23514'; END IF;

  UPDATE public.business_expenses
  SET status='voided',void_reason=v_reason,voided_by=v_actor,voided_at=now(),updated_at=now()
  WHERE id=p_expense_id AND business_id=v_expense.business_id AND status='active';
  IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo anular el gasto.' USING ERRCODE='40001'; END IF;

  INSERT INTO public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
  VALUES (
    v_expense.business_id,v_actor,'business_expense.voided','business_expense',p_expense_id::text,
    jsonb_build_object('amount',v_expense.amount,'reason',v_reason,'previous_payment_status',v_expense.payment_status)
  );
  RETURN p_expense_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.void_business_expense(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_business_expense(uuid,text) TO authenticated;


-- El comprobante solo se puede adjuntar a un gasto propio, una vez y desde
-- el bucket privado. El objeto debe existir antes de asociar la ruta.
CREATE OR REPLACE FUNCTION public.attach_business_expense_receipt(
  p_expense_id uuid,
  p_receipt_path text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_expense public.business_expenses%ROWTYPE;
  v_actor uuid := auth.uid();
  v_expected_prefix text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE='42501'; END IF;
  SELECT * INTO v_expense FROM public.business_expenses WHERE id=p_expense_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Gasto no encontrado.' USING ERRCODE='P0002'; END IF;
  IF private.is_platform_owner()
     OR NOT private.business_is_active(v_expense.business_id)
     OR NOT private.has_business_role(v_expense.business_id,ARRAY['business_admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el administrador del negocio activo puede adjuntar comprobantes.' USING ERRCODE='42501';
  END IF;
  IF v_expense.status <> 'active' OR v_expense.receipt_path IS NOT NULL THEN
    RAISE EXCEPTION 'El gasto está anulado o ya tiene un comprobante asociado.' USING ERRCODE='23514';
  END IF;
  v_expected_prefix := v_expense.business_id::text || '/' || v_expense.id::text || '/';
  IF p_receipt_path IS NULL OR left(p_receipt_path,char_length(v_expected_prefix)) <> v_expected_prefix
     OR char_length(p_receipt_path) > 500 THEN
    RAISE EXCEPTION 'La ruta del comprobante no corresponde al gasto.' USING ERRCODE='22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM storage.objects o
    WHERE o.bucket_id='business-expense-receipts'
      AND o.name=p_receipt_path
  ) THEN
    RAISE EXCEPTION 'El archivo no existe en el almacenamiento privado.' USING ERRCODE='P0002';
  END IF;

  UPDATE public.business_expenses SET receipt_path=p_receipt_path,updated_at=now()
  WHERE id=p_expense_id AND business_id=v_expense.business_id AND receipt_path IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo asociar el comprobante.' USING ERRCODE='40001'; END IF;

  INSERT INTO public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
  VALUES (
    v_expense.business_id,v_actor,'business_expense.receipt_attached',
    'business_expense',p_expense_id::text,
    jsonb_build_object('bucket','business-expense-receipts','receipt_attached',true)
  );
  RETURN p_expense_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.attach_business_expense_receipt(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.attach_business_expense_receipt(uuid,text) TO authenticated;

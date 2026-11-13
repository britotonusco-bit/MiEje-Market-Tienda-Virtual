-- MiEje Market Independiente
-- Finanzas de plataforma y nómina para el panel técnico.
-- Solo la Edge Function técnica (propietario con MFA AAL2) accede a estas tablas.
-- No registra pagos bancarios ni ejecuta transferencias: es un libro de control interno.

CREATE TABLE IF NOT EXISTS public.platform_financial_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid REFERENCES public.businesses(id) ON DELETE SET NULL,
  record_type text NOT NULL
    CHECK (record_type IN ('income','expense','refund','adjustment')),
  description text NOT NULL
    CHECK (char_length(btrim(description)) BETWEEN 3 AND 500),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'COP'
    CHECK (currency ~ '^[A-Z]{3}$'),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  reference text CHECK (reference IS NULL OR char_length(reference) <= 160),
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS platform_financial_records_occurred_idx
  ON public.platform_financial_records (occurred_at DESC);
CREATE INDEX IF NOT EXISTS platform_financial_records_business_idx
  ON public.platform_financial_records (business_id, occurred_at DESC);

ALTER TABLE public.platform_financial_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.platform_financial_records FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON TABLE public.platform_financial_records TO service_role;

CREATE TABLE IF NOT EXISTS public.payroll_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid REFERENCES public.businesses(id) ON DELETE SET NULL,
  payee_name text NOT NULL
    CHECK (char_length(btrim(payee_name)) BETWEEN 2 AND 160),
  description text NOT NULL
    CHECK (char_length(btrim(description)) BETWEEN 3 AND 500),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'COP'
    CHECK (currency ~ '^[A-Z]{3}$'),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','paid','cancelled')),
  due_date date,
  paid_at timestamptz,
  payment_reference text CHECK (payment_reference IS NULL OR char_length(payment_reference) <= 160),
  created_by uuid NOT NULL,
  updated_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payroll_paid_fields_consistent CHECK (
    (status = 'paid' AND paid_at IS NOT NULL)
    OR (status <> 'paid' AND paid_at IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS payroll_records_created_idx
  ON public.payroll_records (created_at DESC);
CREATE INDEX IF NOT EXISTS payroll_records_status_due_idx
  ON public.payroll_records (status, due_date);

ALTER TABLE public.payroll_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.payroll_records FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.payroll_records TO service_role;

CREATE OR REPLACE FUNCTION public.resolve_platform_payroll_record(
  p_record_id uuid,
  p_decision text,
  p_payment_reference text,
  p_actor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_payroll public.payroll_records%ROWTYPE;
  v_updated public.payroll_records%ROWTYPE;
  v_financial_id uuid := NULL;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'Actor requerido.';
  END IF;
  IF p_decision NOT IN ('paid','cancelled') THEN
    RAISE EXCEPTION 'Decisión de nómina no válida.';
  END IF;
  IF p_payment_reference IS NOT NULL AND pg_catalog.char_length(p_payment_reference) > 160 THEN
    RAISE EXCEPTION 'La referencia supera el máximo permitido.';
  END IF;

  SELECT * INTO v_payroll
  FROM public.payroll_records
  WHERE id = p_record_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El registro de nómina no existe.';
  END IF;
  IF v_payroll.status <> 'pending' THEN
    RAISE EXCEPTION 'El registro de nómina ya fue resuelto.';
  END IF;

  UPDATE public.payroll_records
  SET status = p_decision,
      paid_at = CASE WHEN p_decision = 'paid' THEN v_now ELSE NULL END,
      payment_reference = CASE WHEN p_decision = 'paid' THEN NULLIF(pg_catalog.btrim(p_payment_reference), '') ELSE NULL END,
      updated_by = p_actor_id,
      updated_at = v_now
  WHERE id = p_record_id
  RETURNING * INTO v_updated;

  IF p_decision = 'paid' THEN
    INSERT INTO public.platform_financial_records (
      business_id, record_type, description, amount, currency,
      occurred_at, reference, created_by
    ) VALUES (
      v_updated.business_id,
      'expense',
      pg_catalog.left('Nómina: ' || v_updated.payee_name || ' — ' || v_updated.description, 500),
      v_updated.amount,
      v_updated.currency,
      v_now,
      NULLIF(pg_catalog.btrim(p_payment_reference), ''),
      p_actor_id
    )
    RETURNING id INTO v_financial_id;
  END IF;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_updated.business_id,
    p_actor_id,
    CASE WHEN p_decision = 'paid' THEN 'platform.payroll_marked_paid' ELSE 'platform.payroll_cancelled' END,
    'payroll_record',
    v_updated.id::text,
    pg_catalog.jsonb_build_object(
      'amount', v_updated.amount,
      'currency', v_updated.currency,
      'payment_reference', v_updated.payment_reference,
      'financial_record_id', v_financial_id
    )
  );

  IF v_financial_id IS NOT NULL THEN
    INSERT INTO public.audit_logs (
      business_id, actor_id, action, entity_type, entity_id, details
    ) VALUES (
      v_updated.business_id,
      p_actor_id,
      'platform.finance_record_created',
      'platform_financial_record',
      v_financial_id::text,
      pg_catalog.jsonb_build_object(
        'record_type', 'expense',
        'amount', v_updated.amount,
        'currency', v_updated.currency,
        'source_payroll_id', v_updated.id
      )
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'payroll', pg_catalog.to_jsonb(v_updated),
    'financial_record_id', v_financial_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_platform_payroll_record(uuid,text,text,uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.resolve_platform_payroll_record(uuid,text,text,uuid)
  TO service_role;

-- No se permiten modificaciones ni eliminaciones directas desde el navegador.
-- La Edge Function valida el propietario/MFA, aplica transiciones y registra auditoría.

-- PRUEBAS OBLIGATORIAS EN ENSAYO:
-- 1) anon/authenticated no pueden leer, insertar, actualizar ni eliminar ninguna tabla.
-- 2) solo el propietario técnico AAL2 puede consultar o crear movimientos.
-- 3) movimientos financieros son inmutables desde la API; no existe acción de edición/borrado.
-- 4) nómina permite pending -> paid o pending -> cancelled una sola vez.
-- 5) marcar pagado requiere referencia opcional y fija paid_at; no se registran datos bancarios.
-- 6) todos los cambios generan audit_logs; un fallo de auditoría se informa sin ocultar el resultado guardado.
-- 7) importes deben ser positivos y moneda ISO de tres letras.

-- Comprobantes privados de gastos del negocio.
-- No ejecutar en producción sin revisar primero el paquete completo de integración.
-- Ruta prevista: <business_uuid>/<expense_uuid>/<random_uuid>.<extension>
-- Lectura de gastos anulados se conserva para auditoría; no se admiten cargas nuevas.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'business-expense-receipts',
  'business-expense-receipts',
  false,
  5242880,
  ARRAY['application/pdf','image/jpeg','image/png','image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = 5242880,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS business_expense_receipts_admin_read ON storage.objects;
CREATE POLICY business_expense_receipts_admin_read
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'business-expense-receipts'
  AND array_length(storage.foldername(name), 1) = 2
  AND (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND storage.filename(name) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](pdf|jpg|jpeg|png|webp)$'
  AND EXISTS (
    SELECT 1
    FROM public.business_expenses e
    WHERE e.id = ((storage.foldername(name))[2])::uuid
      AND e.business_id = ((storage.foldername(name))[1])::uuid
      AND e.status IN ('active','voided')
      AND e.receipt_path = name
      AND private.business_is_active(e.business_id)
      AND private.has_business_role(e.business_id, ARRAY['business_admin']::text[])
  )
);

DROP POLICY IF EXISTS business_expense_receipts_admin_upload ON storage.objects;
CREATE POLICY business_expense_receipts_admin_upload
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'business-expense-receipts'
  AND array_length(storage.foldername(name), 1) = 2
  AND (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND storage.filename(name) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](pdf|jpg|jpeg|png|webp)$'
  AND EXISTS (
    SELECT 1
    FROM public.business_expenses e
    WHERE e.id = ((storage.foldername(name))[2])::uuid
      AND e.business_id = ((storage.foldername(name))[1])::uuid
      AND e.status = 'active'
      AND private.business_is_active(e.business_id)
      AND private.has_business_role(e.business_id, ARRAY['business_admin']::text[])
  )
);

-- No se crean políticas UPDATE/DELETE: los comprobantes se conservan como evidencia.
-- Los enlaces de descarga deben generarse como signed URLs de corta duración.

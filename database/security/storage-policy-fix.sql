-- MiEje Market Independiente
-- Corrección propuesta para las políticas de Storage del bucket business-assets.
-- REVISAR ANTES DE EJECUTAR. No ejecutar desde este archivo sin probar primero.
--
-- El error actual usa storage.foldername(b.name), pero b es businesses y no
-- contiene la ruta del objeto. La ruta debe obtenerse de storage.objects.name.
-- Convención esperada: <business_uuid>/logo/<archivo> o
-- <business_uuid>/products/<archivo>.

DROP POLICY IF EXISTS business_assets_admin_upload ON storage.objects;
CREATE POLICY business_assets_admin_upload
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'business-assets'
  AND (storage.foldername(objects.name))[1] ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND (storage.foldername(objects.name))[2] IN ('logo', 'products')
  AND EXISTS (
    SELECT 1
    FROM public.businesses AS b
    WHERE b.id = ((storage.foldername(objects.name))[1])::uuid
      AND b.status = 'active'
      AND private.has_business_role(b.id, ARRAY['business_admin']::text[])
  )
);

DROP POLICY IF EXISTS business_assets_admin_read ON storage.objects;
CREATE POLICY business_assets_admin_read
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'business-assets'
  AND (storage.foldername(objects.name))[1] ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND (storage.foldername(objects.name))[2] IN ('logo', 'products')
  AND EXISTS (
    SELECT 1
    FROM public.businesses AS b
    WHERE b.id = ((storage.foldername(objects.name))[1])::uuid
      AND b.status = 'active'
      AND private.has_business_role(b.id, ARRAY['business_admin']::text[])
  )
);

DROP POLICY IF EXISTS business_assets_admin_update ON storage.objects;
CREATE POLICY business_assets_admin_update
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'business-assets'
  AND (storage.foldername(objects.name))[1] ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND (storage.foldername(objects.name))[2] IN ('logo', 'products')
  AND EXISTS (
    SELECT 1
    FROM public.businesses AS b
    WHERE b.id = ((storage.foldername(objects.name))[1])::uuid
      AND b.status = 'active'
      AND private.has_business_role(b.id, ARRAY['business_admin']::text[])
  )
)
WITH CHECK (
  bucket_id = 'business-assets'
  AND (storage.foldername(objects.name))[1] ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND (storage.foldername(objects.name))[2] IN ('logo', 'products')
  AND EXISTS (
    SELECT 1
    FROM public.businesses AS b
    WHERE b.id = ((storage.foldername(objects.name))[1])::uuid
      AND b.status = 'active'
      AND private.has_business_role(b.id, ARRAY['business_admin']::text[])
  )
);

DROP POLICY IF EXISTS business_assets_admin_delete ON storage.objects;
CREATE POLICY business_assets_admin_delete
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'business-assets'
  AND (storage.foldername(objects.name))[1] ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND (storage.foldername(objects.name))[2] IN ('logo', 'products')
  AND EXISTS (
    SELECT 1
    FROM public.businesses AS b
    WHERE b.id = ((storage.foldername(objects.name))[1])::uuid
      AND b.status = 'active'
      AND private.has_business_role(b.id, ARRAY['business_admin']::text[])
  )
);

-- Nota: business-assets es un bucket público. Esta política limita la gestión
-- autenticada de objetos; la lectura pública se controla por la configuración
-- public del bucket. job-applications-private no se modifica aquí.

-- Lectura estricta de hojas de vida privadas.
-- Convención generada por create-job-application:
-- <business_uuid>/<application_uuid>/<random_uuid>.(pdf|doc|docx)
-- El bucket sigue siendo privado; el administrador obtiene enlaces firmados
-- de corta duración únicamente después de leer la postulación de su negocio.
DROP POLICY IF EXISTS job_application_documents_business_admin_read ON storage.objects;
CREATE POLICY job_application_documents_business_admin_read
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'job-applications-private'
  AND array_length(storage.foldername(objects.name), 1) = 2
  AND (storage.foldername(objects.name))[1] ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND (storage.foldername(objects.name))[2] ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND storage.filename(objects.name) ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(pdf|doc|docx)$'
  AND EXISTS (
    SELECT 1
    FROM public.businesses AS b
    WHERE b.id = ((storage.foldername(objects.name))[1])::uuid
      AND b.status = 'active'
      AND private.has_business_role(b.id, ARRAY['business_admin']::text[])
  )
);

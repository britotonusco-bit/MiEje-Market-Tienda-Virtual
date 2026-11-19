-- MiEje Market: índices de cobertura para claves foráneas.
-- BORRADOR: aplicar primero en un proyecto de staging y medir antes/después.
-- No ejecutar en el proyecto activo durante la auditoría.
-- Los índices compuestos también cubren las claves foráneas cuyos campos
-- constituyen un prefijo izquierdo del índice.

CREATE INDEX IF NOT EXISTS business_content_pages_created_by_idx
  ON public.business_content_pages (created_by);

CREATE INDEX IF NOT EXISTS business_content_pages_moderated_by_idx
  ON public.business_content_pages (moderated_by);

CREATE INDEX IF NOT EXISTS business_content_pages_updated_by_idx
  ON public.business_content_pages (updated_by);

CREATE INDEX IF NOT EXISTS business_expenses_created_by_idx
  ON public.business_expenses (created_by);

CREATE INDEX IF NOT EXISTS business_expenses_voided_by_idx
  ON public.business_expenses (voided_by);

CREATE INDEX IF NOT EXISTS financial_transactions_business_order_cancellation_idx
  ON public.financial_transactions (business_id, order_id, cancellation_request_id);

CREATE INDEX IF NOT EXISTS financial_transactions_cancellation_request_idx
  ON public.financial_transactions (cancellation_request_id);

-- El primer campo cubre también la FK simple business_id.
CREATE INDEX IF NOT EXISTS job_application_upload_sessions_business_content_idx
  ON public.job_application_upload_sessions (business_id, content_page_id);

CREATE INDEX IF NOT EXISTS job_applications_business_content_page_idx
  ON public.job_applications (business_id, content_page_id);

CREATE INDEX IF NOT EXISTS job_applications_reviewed_by_idx
  ON public.job_applications (reviewed_by);

CREATE INDEX IF NOT EXISTS order_item_costs_business_order_idx
  ON public.order_item_costs (business_id, order_id);

CREATE INDEX IF NOT EXISTS order_item_costs_order_item_idx
  ON public.order_item_costs (order_id, order_item_id);

CREATE INDEX IF NOT EXISTS product_costs_business_product_idx
  ON public.product_costs (business_id, product_id);

-- El prefijo (business_id, order_id) cubre también la FK compuesta
-- refund_business_order_fk.
CREATE INDEX IF NOT EXISTS refund_details_business_order_financial_idx
  ON public.refund_details (business_id, order_id, financial_transaction_id);

-- Verificación de solo lectura posterior a la aplicación:
-- SELECT schemaname, tablename, indexname, indexdef
-- FROM pg_indexes
-- WHERE schemaname = 'public'
--   AND indexname IN (
--     'business_content_pages_created_by_idx',
--     'business_content_pages_moderated_by_idx',
--     'business_content_pages_updated_by_idx',
--     'business_expenses_created_by_idx',
--     'business_expenses_voided_by_idx',
--     'financial_transactions_business_order_cancellation_idx',
--     'financial_transactions_cancellation_request_idx',
--     'job_application_upload_sessions_business_content_idx',
--     'job_applications_business_content_page_idx',
--     'job_applications_reviewed_by_idx',
--     'order_item_costs_business_order_idx',
--     'order_item_costs_order_item_idx',
--     'product_costs_business_product_idx',
--     'refund_details_business_order_financial_idx'
--   )
-- ORDER BY tablename, indexname;

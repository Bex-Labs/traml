-- Phase 2: Alert Lineage, Deduplication, and Evidence JSON
-- Safely altering the table established in the Phase 1 baseline

ALTER TABLE public.alerts
  ADD COLUMN IF NOT EXISTS tenant_id text,
  ADD COLUMN IF NOT EXISTS rule_version integer DEFAULT 1,
  ADD COLUMN IF NOT EXISTS evidence jsonb DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS idempotency_key text;

-- Add a unique constraint to prevent duplicate alerts for the exact same event.
-- PostgreSQL treats multiple NULLs in a UNIQUE column as distinct, so this 
-- will not crash on your existing historical alerts.
ALTER TABLE public.alerts
  ADD CONSTRAINT alerts_idempotency_key_key UNIQUE (idempotency_key);
-- Phase 0: Secure External Function Callers (Webhooks & Cron)
-- Dynamic resolution of Project URL, Anon Key, and Secrets from Supabase Vault

-- 1. Create the Webhook trigger function for match-entity
CREATE OR REPLACE FUNCTION public.enqueue_match_entity_webhook()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_base_url text;
  v_anon_key text;
  v_secret text;
BEGIN
  -- Read environment configuration dynamically from Vault
  SELECT decrypted_secret INTO v_base_url FROM vault.decrypted_secrets WHERE name = 'project_url';
  SELECT decrypted_secret INTO v_anon_key FROM vault.decrypted_secrets WHERE name = 'anon_key';
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'match_entity_webhook_secret';

  PERFORM net.http_post(
    -- Fallback to local Docker network if Vault project_url is missing
    url := coalesce(v_base_url, 'http://host.docker.internal:54321') || '/functions/v1/match-entity',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || coalesce(v_anon_key, ''),
      'x-webhook-secret', coalesce(v_secret, '')
    ),
    body := jsonb_build_object(
      'type', TG_OP,
      'table', TG_TABLE_NAME,
      'schema', TG_TABLE_SCHEMA,
      'record', NEW,
      'old_record', OLD
    )
  );

  RETURN NEW;
END;
$$;

-- Bind the trigger to the customers table
DROP TRIGGER IF EXISTS match_entity_webhook ON public.customers;

CREATE TRIGGER match_entity_webhook
AFTER INSERT OR UPDATE OF entity_name, industry, geography ON public.customers
FOR EACH ROW
EXECUTE FUNCTION public.enqueue_match_entity_webhook();

-- 2. Secure the dispatch-reports cron job
-- Schedule the job using a DO block to evaluate Vault secrets at runtime
SELECT cron.schedule(
  'dispatch_reports_job', 
  '0 23 * * *', 
  $$
  DO $job$
  DECLARE
    v_base_url text;
    v_anon_key text;
    v_secret text;
  BEGIN
    SELECT decrypted_secret INTO v_base_url FROM vault.decrypted_secrets WHERE name = 'project_url';
    SELECT decrypted_secret INTO v_anon_key FROM vault.decrypted_secrets WHERE name = 'anon_key';
    SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'report_dispatch_cron_secret';

    PERFORM net.http_post(
      url := coalesce(v_base_url, 'http://host.docker.internal:54321') || '/functions/v1/dispatch-reports',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || coalesce(v_anon_key, ''),
        'x-cron-secret', coalesce(v_secret, '')
      )
    );
  END;
  $job$;
  $$
);



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "public";






CREATE TYPE "public"."account_status" AS ENUM (
    'ACTIVE',
    'DORMANT',
    'FROZEN',
    'CLOSED'
);


ALTER TYPE "public"."account_status" OWNER TO "postgres";


CREATE TYPE "public"."account_type" AS ENUM (
    'SAVINGS',
    'CURRENT',
    'DOMICILIARY'
);


ALTER TYPE "public"."account_type" OWNER TO "postgres";


CREATE TYPE "public"."customer_type" AS ENUM (
    'INDIVIDUAL',
    'CORPORATE'
);


ALTER TYPE "public"."customer_type" OWNER TO "postgres";


CREATE TYPE "public"."risk_tier" AS ENUM (
    'LOW',
    'MEDIUM',
    'HIGH',
    'VERY_HIGH'
);


ALTER TYPE "public"."risk_tier" OWNER TO "postgres";


CREATE TYPE "public"."transaction_channel" AS ENUM (
    'WEB',
    'MOBILE',
    'ATM',
    'POS',
    'BRANCH',
    'USSD',
    'SYSTEM',
    'BRANCH_CASH',
    'BRANCH_TRANSFER'
);


ALTER TYPE "public"."transaction_channel" OWNER TO "postgres";


CREATE TYPE "public"."transaction_type" AS ENUM (
    'DEBIT',
    'CREDIT'
);


ALTER TYPE "public"."transaction_type" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_safe_login_func"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    -- We only want to log when the user ACTUALLY logs in (when the timestamp changes)
    IF OLD.last_sign_in_at IS DISTINCT FROM NEW.last_sign_in_at THEN
        INSERT INTO public.audit_logs (
            event_type,
            actor_id,
            target_id,
            details,
            tenant_id
        ) VALUES (
            'auth_login',
            NEW.id,
            NEW.id,
            jsonb_build_object('email', NEW.email, 'action', 'session_started'),
            CAST(NULLIF(NEW.raw_app_meta_data->>'tenant_id', '') AS UUID)
        );
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."audit_safe_login_func"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_alert_severity"("p_rule_severity" "text", "p_customer_risk" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE

    v_rank INTEGER;
    v_offset INTEGER;

BEGIN

    v_rank := public.severity_rank(p_rule_severity);

    IF v_rank IS NULL THEN
        RAISE EXCEPTION
            'Invalid alert severity: %',
            p_rule_severity;
    END IF;

    v_offset :=
        public.risk_escalation_offset(
            p_customer_risk
        );

    RETURN public.severity_from_rank(
        LEAST(v_rank + v_offset,4)
    );

END;
$$;


ALTER FUNCTION "public"."calculate_alert_severity"("p_rule_severity" "text", "p_customer_risk" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_dynamic_baselines"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Upsert the newly calculated 30-day baselines
    INSERT INTO public.customer_baselines (customer_id, avg_tx_amount, stddev_tx_amount, daily_velocity_avg, last_calculated_at)
    SELECT 
        a.customer_id,
        COALESCE(AVG(t.amount), 0) as avg_tx_amount,
        COALESCE(STDDEV_POP(t.amount), 0) as stddev_tx_amount,
        COALESCE(COUNT(t.id) / 30.0, 0) as daily_velocity_avg,
        NOW()
    FROM public.accounts a
    LEFT JOIN public.transactions t 
        ON t.account_id = a.id 
        AND t.transaction_timestamp >= NOW() - INTERVAL '30 days'
    GROUP BY a.customer_id
    ON CONFLICT (customer_id) 
    DO UPDATE SET 
        avg_tx_amount = EXCLUDED.avg_tx_amount,
        stddev_tx_amount = EXCLUDED.stddev_tx_amount,
        daily_velocity_avg = EXCLUDED.daily_velocity_avg,
        last_calculated_at = EXCLUDED.last_calculated_at;
END;
$$;


ALTER FUNCTION "public"."calculate_dynamic_baselines"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_massive_outflow"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_customer_id UUID;
BEGIN
    IF NEW.transaction_type = 'DEBIT' AND NEW.amount > 10000000 THEN
        SELECT customer_id INTO v_customer_id FROM public.accounts WHERE id = NEW.account_id;
        
        INSERT INTO public.alerts (
            alert_ref, 
            customer_id, 
            transaction_id,  -- 1. Explicitly mapped column
            rule_triggered, 
            severity, 
            status, 
            details
        )
        VALUES (
            'ALT-' || upper(substring(md5(random()::text) from 1 for 6)),
            v_customer_id, 
            NEW.id,          -- 2. Securely passes the new transaction's UUID
            'Massive Outflow Protocol', 
            'CRITICAL', 
            'UNASSIGNED', 
            'Engine flagged transaction of ₦' || NEW.amount || ' exceeding the strict threshold of ₦10000000 set by rule: Massive Outflow Protocol'
        );
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_massive_outflow"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_alert"("p_customer_id" "uuid", "p_rule_name" "text", "p_severity" "text", "p_details" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$

DECLARE

    v_rule_id UUID;
    v_customer_risk TEXT := 'LOW';
    v_final_severity TEXT;

BEGIN

    -----------------------------------------------------
    -- Resolve Rule
    -----------------------------------------------------

    SELECT id

    INTO v_rule_id

    FROM public.aml_rules

    WHERE rule_name = p_rule_name;

    IF NOT FOUND THEN

        RAISE EXCEPTION
            'AML rule "%" not found.',
            p_rule_name;

    END IF;

    -----------------------------------------------------
    -- Existing Customer Risk
    -----------------------------------------------------

    SELECT risk_level

    INTO v_customer_risk

    FROM public.customer_risk_profiles

    WHERE customer_id = p_customer_id;

    -----------------------------------------------------
    -- Escalate Severity
    -----------------------------------------------------

    v_final_severity :=
        public.calculate_alert_severity(
            p_severity,
            COALESCE(v_customer_risk,'LOW')
        );

    -----------------------------------------------------
    -- Persist Alert
    -----------------------------------------------------

    INSERT INTO public.alerts (

        alert_ref,
        customer_id,
        rule_triggered,
        severity,
        status,
        details

    )

    VALUES (

        'ALT-' || UPPER(SUBSTRING(gen_random_uuid()::TEXT,1,6)),
        p_customer_id,
        p_rule_name,
        v_final_severity,
        'UNASSIGNED',
        p_details

    );

    -----------------------------------------------------
    -- Update Customer Risk
    -----------------------------------------------------

    PERFORM public.update_customer_risk(

        p_customer_id,
        v_rule_id,
        'AML_ALERT: ' || p_rule_name

    );

END;
$$;


ALTER FUNCTION "public"."create_alert"("p_customer_id" "uuid", "p_rule_name" "text", "p_severity" "text", "p_details" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."custom_access_token_hook"("event" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
  DECLARE
    claims jsonb;
    user_role text;
    user_tenant uuid;
  BEGIN
    -- Try to find your profile
    SELECT role, tenant_id INTO user_role, user_tenant
    FROM public.user_profiles
    WHERE id = (event->'claims'->>'sub')::uuid;

    claims := event->'claims';

    IF user_role IS NOT NULL THEN
      -- Success! Inject real data
      claims := jsonb_set(claims, '{app_metadata, role}', to_jsonb(user_role));
      claims := jsonb_set(claims, '{app_metadata, tenant_id}', to_jsonb(user_tenant));
    ELSE
      -- DIAGNOSTIC FAILURE FLAG
      claims := jsonb_set(claims, '{app_metadata, role}', '"DEBUG_PROFILE_NOT_FOUND"');
    END IF;

    event := jsonb_set(event, '{claims}', claims);
    RETURN event;
  END;
$$;


ALTER FUNCTION "public"."custom_access_token_hook"("event" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."detect_circular_layering"("start_account_id" "uuid", "max_hops" integer DEFAULT 4) RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    cycle_detected BOOLEAN;
BEGIN
    WITH RECURSIVE 
    linked_transfers AS (
        SELECT 
            t.account_id AS sender_id,
            a.id AS receiver_id,
            t.transaction_timestamp
        FROM public.transactions t
        INNER JOIN public.accounts a 
          ON t.counterparty_account = a.account_number
        WHERE t.transaction_type = 'DEBIT' 
          AND t.transaction_timestamp > NOW() - INTERVAL '14 days'
    ),
    transfer_graph AS (
        SELECT 
            sender_id, 
            receiver_id, 
            1 AS depth,
            ARRAY[sender_id, receiver_id] AS path
        FROM linked_transfers
        WHERE sender_id = start_account_id

        UNION ALL

        SELECT 
            lt.sender_id, 
            lt.receiver_id, 
            tg.depth + 1,
            tg.path || lt.receiver_id
        FROM linked_transfers lt
        INNER JOIN transfer_graph tg ON tg.receiver_id = lt.sender_id
        WHERE tg.depth < max_hops
          -- FIX: Allow the money to hit the start_account to complete the ring, 
          -- but block loops on intermediate nodes to prevent infinite recursion.
          AND lt.receiver_id <> ALL(tg.path[2:array_length(tg.path, 1)])
    )
    SELECT EXISTS (
        SELECT 1 
        FROM transfer_graph 
        WHERE receiver_id = start_account_id AND depth > 1
    ) INTO cycle_detected;

    RETURN cycle_detected;
END;
$$;


ALTER FUNCTION "public"."detect_circular_layering"("start_account_id" "uuid", "max_hops" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_match_entity_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
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


ALTER FUNCTION "public"."enqueue_match_entity_webhook"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."evaluate_amount_above"("p_amount" numeric, "p_threshold" numeric, "p_rule_name" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
BEGIN

    IF p_amount > p_threshold THEN
        RETURN
            'Engine flagged transaction of ₦'
            || p_amount
            || ' exceeding the strict threshold of ₦'
            || p_threshold
            || ' set by rule: '
            || p_rule_name;
    END IF;

    RETURN NULL;

END;
$$;


ALTER FUNCTION "public"."evaluate_amount_above"("p_amount" numeric, "p_threshold" numeric, "p_rule_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."evaluate_behavioral_anomaly"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    target_customer_id UUID;
    baseline RECORD;
    anomaly_threshold DECIMAL;
BEGIN
    -- Get the customer_id associated with the account
    SELECT customer_id INTO target_customer_id
    FROM public.accounts
    WHERE id = NEW.account_id;

    IF target_customer_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Fetch the customer's cached baseline
    SELECT * INTO baseline
    FROM public.customer_baselines
    WHERE customer_id = target_customer_id;

    -- If we have a baseline, evaluate the transaction
    IF FOUND AND baseline.stddev_tx_amount > 0 THEN
        -- Anomaly Definition: Amount is > (Average + 3 * Standard Deviations)
        anomaly_threshold := baseline.avg_tx_amount + (3 * baseline.stddev_tx_amount);

        IF NEW.amount > anomaly_threshold THEN
            -- Generate a human-readable Explainable AI (XAI) rationale
            INSERT INTO public.alerts (
                alert_ref, 
                transaction_id, 
                customer_id, 
                rule_triggered, 
                severity, 
                status, 
                details
            ) VALUES (
                'ALT-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6)),
                NEW.id,
                target_customer_id,
                'Behavioural Velocity Spike (3-Sigma)',
                'CRITICAL',
                'UNASSIGNED',
                FORMAT('Statistical Anomaly: Transaction amount (₦%s) exceeds the customer''s 30-day historical average (₦%s) by more than 3 standard deviations. This indicates a highly abnormal wealth injection.', NEW.amount, ROUND(baseline.avg_tx_amount, 2))
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."evaluate_behavioral_anomaly"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."evaluate_dormant_account_activity"("p_account_id" "uuid", "p_current_transaction_timestamp" timestamp with time zone, "p_threshold_days" integer, "p_rule_name" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$

DECLARE

    v_last_activity TIMESTAMPTZ;

    v_inactive_days INTEGER;

BEGIN

    -- Retrieve the previous account activity

    v_last_activity := get_last_account_activity(

        p_account_id,
        p_current_transaction_timestamp

    );

    -- No previous activity means this is the first transaction

    IF v_last_activity IS NULL THEN
        RETURN NULL;
    END IF;

    -- Calculate inactive days

    v_inactive_days := FLOOR(

        EXTRACT(
            EPOCH FROM (
                p_current_transaction_timestamp - v_last_activity
            )
        ) / 86400

    );

    -- Evaluate dormancy

    IF v_inactive_days >= p_threshold_days THEN

        RETURN format(

            'Dormant Account Activity detected. Rule "%s" triggered. Account was inactive for %s day(s).',

            p_rule_name,
            v_inactive_days

        );

    END IF;

    RETURN NULL;

END;

$$;


ALTER FUNCTION "public"."evaluate_dormant_account_activity"("p_account_id" "uuid", "p_current_transaction_timestamp" timestamp with time zone, "p_threshold_days" integer, "p_rule_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."evaluate_mule_ring"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    is_layering BOOLEAN;
    target_customer_id UUID;
BEGIN
    -- We only need to check the graph when money leaves an account
    IF NEW.transaction_type = 'DEBIT' THEN
        
        -- Run the graph algorithm (Check up to 4 hops)
        is_layering := public.detect_circular_layering(NEW.account_id, 4);
        
        IF is_layering THEN
            -- Find the customer attached to this account
            SELECT customer_id INTO target_customer_id
            FROM public.accounts WHERE id = NEW.account_id;

            -- Generate the Alert
            INSERT INTO public.alerts (
                alert_ref, transaction_id, customer_id, rule_triggered, severity, status, details
            ) VALUES (
                'ALT-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6)),
                NEW.id,
                target_customer_id,
                'Circular Layering (Mule Ring Detected)',
                'CRITICAL',
                'UNASSIGNED',
                'Graph Analytics Engine: A closed-loop transfer network (circular layering) was detected across 4 or fewer degrees of separation. Funds originating from this account have looped back to it, indicating severe money laundering typologies.'
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."evaluate_mule_ring"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."evaluate_rule_metadata"("p_rule_metadata" "jsonb", "p_transaction_type" "text", "p_channel" "text", "p_currency" "text") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$

DECLARE

    v_transaction_type TEXT;
    v_channel TEXT;
    v_currency TEXT;

BEGIN

    -- No metadata means no filtering

    IF p_rule_metadata IS NULL
       OR p_rule_metadata = '{}'::JSONB THEN
        RETURN TRUE;
    END IF;

    -----------------------------------------------------------------
    -- Transaction Type
    -----------------------------------------------------------------

    v_transaction_type := UPPER(
        COALESCE(
            p_rule_metadata ->> 'transaction_type',
            'BOTH'
        )
    );

    v_channel := UPPER(COALESCE(p_channel,''));

    v_currency := UPPER(COALESCE(p_currency,''));

    IF v_transaction_type <> 'BOTH'
       AND UPPER(p_transaction_type) <> v_transaction_type THEN
        RETURN FALSE;
    END IF;

    -----------------------------------------------------------------
    -- Channels (optional)
    -----------------------------------------------------------------

    IF p_rule_metadata ? 'channels'
        AND jsonb_array_length(p_rule_metadata -> 'channels') > 0 THEN

        IF NOT EXISTS (

            SELECT 1
            FROM jsonb_array_elements_text(
                p_rule_metadata -> 'channels'
            ) AS c(channel)

            WHERE UPPER(channel) = v_channel

        ) THEN

            RETURN FALSE;

        END IF;

    END IF;

    -----------------------------------------------------------------
    -- Currencies (optional)
    -----------------------------------------------------------------

    IF p_rule_metadata ? 'currencies'
        AND jsonb_array_length(p_rule_metadata -> 'currencies') > 0 THEN

        IF NOT EXISTS (

            SELECT 1
            FROM jsonb_array_elements_text(
                p_rule_metadata -> 'currencies'
            ) AS c(currency)

            WHERE UPPER(currency) = v_currency

        ) THEN

            RETURN FALSE;

        END IF;

    END IF;

    RETURN TRUE;

END;

$$;


ALTER FUNCTION "public"."evaluate_rule_metadata"("p_rule_metadata" "jsonb", "p_transaction_type" "text", "p_channel" "text", "p_currency" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."evaluate_structuring"("p_account_id" "uuid", "p_amount" numeric, "p_threshold" numeric, "p_window_hours" integer, "p_rule_name" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_stats JSON;
    v_total_volume NUMERIC;
    v_tx_count INTEGER;
BEGIN

    -- Get rolling statistics
    v_stats := get_rolling_tx_stats(
        p_account_id,
        p_window_hours,
        'CREDIT'
    );

    -- Extract values
    v_total_volume := COALESCE((v_stats ->> 'total_volume')::NUMERIC, 0);
    v_tx_count := COALESCE((v_stats ->> 'tx_count')::INTEGER, 0);

    -- Detect structuring
    IF p_amount < p_threshold
       AND v_total_volume >= p_threshold
       AND v_tx_count >= 2 THEN

        RETURN format(
            '%s: Structuring detected. %s transactions totaling %s within %s hours.',
            p_rule_name,
            v_tx_count,
            v_total_volume,
            p_window_hours
        );

    END IF;

    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."evaluate_structuring"("p_account_id" "uuid", "p_amount" numeric, "p_threshold" numeric, "p_window_hours" integer, "p_rule_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."evaluate_velocity_count"("p_account_id" "uuid", "p_threshold" numeric, "p_time_window_hours" integer, "p_rule_name" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$

DECLARE

    rolling_stats JSONB;

    rolling_volume NUMERIC;
    rolling_count INTEGER;

BEGIN

    -- Retrieve rolling transaction statistics

    rolling_stats := get_rolling_tx_stats(

        p_account_id,
        p_time_window_hours,
        'CREDIT'

    );

    -- Extract returned values

    rolling_volume := COALESCE(
        (rolling_stats->>'total_volume')::NUMERIC,
        0
    );

    rolling_count := COALESCE(
        (rolling_stats->>'tx_count')::INTEGER,
        0
    );

    -- Evaluate transaction count

    IF rolling_count >= p_threshold THEN

        RETURN format(

            'Velocity Rule Triggered: "%s". %s credit transactions detected within the last %s hour(s).',

            p_rule_name,
            rolling_count,
            p_time_window_hours

        );

    END IF;

    RETURN NULL;

END;

$$;


ALTER FUNCTION "public"."evaluate_velocity_count"("p_account_id" "uuid", "p_threshold" numeric, "p_time_window_hours" integer, "p_rule_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_last_account_activity"("p_account_id" "uuid", "p_current_transaction_timestamp" timestamp with time zone) RETURNS timestamp with time zone
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$

DECLARE

    v_last_activity TIMESTAMPTZ;

BEGIN

    SELECT
        MAX(transaction_timestamp)
    INTO
        v_last_activity
    FROM
        public.transactions
    WHERE
        account_id = p_account_id
        AND transaction_timestamp < p_current_transaction_timestamp;

    RETURN v_last_activity;

END;

$$;


ALTER FUNCTION "public"."get_last_account_activity"("p_account_id" "uuid", "p_current_transaction_timestamp" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_rolling_tx_stats"("p_account_id" "uuid", "p_hours" integer, "p_tx_type" "text" DEFAULT 'CREDIT'::"text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    result json;
BEGIN
    SELECT json_build_object(
        'total_volume', COALESCE(SUM(amount), 0),
        'tx_count', COUNT(id)
    ) INTO result
    FROM public.transactions
    WHERE account_id = p_account_id
      AND transaction_type::text = p_tx_type  -- 🚨 CRITICAL FIX: The explicit text cast
      AND transaction_timestamp >= NOW() - (p_hours || ' hours')::interval;
      
    RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_rolling_tx_stats"("p_account_id" "uuid", "p_hours" integer, "p_tx_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_rolling_tx_volume"("p_account_id" "uuid", "p_hours" integer, "p_tx_type" "text") RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sum NUMERIC;
BEGIN
  -- We sum the amounts for this account, filtered by type and the lookback window
  SELECT COALESCE(SUM(amount), 0)
  INTO v_sum
  FROM transactions
  WHERE account_id = p_account_id
    AND transaction_type = p_tx_type
    AND transaction_timestamp > NOW() - (p_hours || ' hours')::INTERVAL;
    
  RETURN v_sum;
END;
$$;


ALTER FUNCTION "public"."get_rolling_tx_volume"("p_account_id" "uuid", "p_hours" integer, "p_tx_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.profiles (id, email, role, tenant_id, full_name)
  VALUES (
    new.id,
    new.email,
    -- Safely extract the role and tenant from the token metadata injected by your invite function
    COALESCE(new.raw_app_meta_data->>'role', new.raw_user_meta_data->>'role', 'compliance_officer'),
    COALESCE(new.raw_app_meta_data->>'tenant_id', new.raw_user_meta_data->>'tenant_id', 'default'),
    COALESCE(new.raw_user_meta_data->>'full_name', 'System User')
  )
  -- If the profile already exists somehow, update it to ensure it matches Auth
  ON CONFLICT (id) DO UPDATE
  SET 
    role = EXCLUDED.role,
    tenant_id = EXCLUDED.tenant_id;
  RETURN new;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_user_login"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Only track if it's an actual login update
  IF OLD.last_sign_in_at IS DISTINCT FROM NEW.last_sign_in_at THEN
      
      -- FIREWALL: Wrap the insert in a TRY/CATCH block
      BEGIN
          INSERT INTO public.audit_logs (user_id, event_type, description, tenant_id)
          VALUES (
            NEW.id, 
            'USER_LOGIN', 
            'Secure system authentication successful.',
            CAST(NULLIF(NEW.raw_app_meta_data ->> 'tenant_id', '') AS uuid)
          );
      EXCEPTION WHEN OTHERS THEN
          -- If the insert fails (due to invalid UUID text, missing columns, etc.)
          -- Do absolutely nothing. Just swallow the error so the login succeeds.
      END;

  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."log_user_login"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_user_logout"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    -- Ensure we actually have an active user before logging
    IF auth.uid() IS NOT NULL THEN
        INSERT INTO public.audit_logs (
            event_type, 
            actor_id, 
            target_id, 
            details, 
            tenant_id
        ) VALUES (
            'auth_logout',
            auth.uid(),
            auth.uid(),
            jsonb_build_object('action', 'global_disconnect'),
            CAST(NULLIF(current_setting('request.jwt.claims', true)::jsonb->'app_metadata'->>'tenant_id', '') AS UUID)
        );
    END IF;
END;
$$;


ALTER FUNCTION "public"."log_user_logout"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_sanctions"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) RETURNS TABLE("sanction_id" "uuid", "sanction_entity_name" "text", "similarity" double precision)
    LANGUAGE "sql" STABLE
    AS $$
    SELECT
        sw.id AS sanction_id,
        sw.entity_name AS sanction_entity_name,
        -- Calculate the cosine similarity (1 - cosine distance)
        1 - (sw.entity_embedding <=> query_embedding) AS similarity
    FROM public.sanctions_watchlist sw
    -- Only return matches above the confidence threshold (e.g., 0.88 for 88%)
    WHERE 1 - (sw.entity_embedding <=> query_embedding) > match_threshold
    -- Sort natively by the HNSW index operator (<=>) for extreme speed
    ORDER BY sw.entity_embedding <=> query_embedding ASC
    LIMIT match_count;
$$;


ALTER FUNCTION "public"."match_sanctions"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_aml_rules"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$

DECLARE

    account_record RECORD;
    customer_record RECORD;
    active_rule RECORD;

    alert_text TEXT;
    alert_severity TEXT;

BEGIN

    -- Identify the account and customer associated with the transaction

    SELECT *
    INTO account_record
    FROM public.accounts
    WHERE id = NEW.account_id;

    SELECT *
    INTO customer_record
    FROM public.customers
    WHERE id = account_record.customer_id;


    -- Evaluate all active transaction rules for the customer's tenant

    FOR active_rule IN

        SELECT *
        FROM public.aml_rules
        WHERE tenant_id = customer_record.tenant_id
          AND status = 'ACTIVE'
          AND target_entity = 'TRANSACTION'

    LOOP

        -- Reset evaluator output before processing each rule

        alert_text := NULL;
        alert_severity := 'HIGH';

        -- Skip rules whose metadata does not match this transaction

            IF NOT evaluate_rule_metadata(

            active_rule.rule_metadata,
            NEW.transaction_type::TEXT,
            NEW.channel::TEXT,
            NEW.currency::TEXT

        ) THEN

            CONTINUE;

        END IF;

        -- Dispatch to the appropriate evaluator

        CASE active_rule.condition_type

            WHEN 'AMOUNT_ABOVE' THEN

                alert_text := evaluate_amount_above(

                    NEW.amount,
                    active_rule.threshold_value,
                    active_rule.rule_name

                );

                alert_severity := 'CRITICAL';


            WHEN 'STRUCTURING_PATTERN' THEN

                alert_text := evaluate_structuring(

                    NEW.account_id,
                    NEW.amount,
                    active_rule.threshold_value,
                    active_rule.time_window_hours,
                    active_rule.rule_name

                );

                alert_severity := 'HIGH';


            WHEN 'VELOCITY_COUNT' THEN

                alert_text := evaluate_velocity_count(

                    NEW.account_id,
                    active_rule.threshold_value,
                    active_rule.time_window_hours,
                    active_rule.rule_name

                );

                alert_severity := 'MEDIUM';

            WHEN 'DORMANT_ACCOUNT_ACTIVITY' THEN

                alert_text := evaluate_dormant_account_activity(

                    NEW.account_id,
                    NEW.transaction_timestamp,
                    active_rule.threshold_value::INTEGER,
                    active_rule.rule_name

                );

                alert_severity := 'HIGH';
            
            -- Future evaluators

            WHEN 'STATIC_THRESHOLD' THEN
                NULL;

            WHEN 'BEHAVIORAL_VELOCITY' THEN
                NULL;

            ELSE
                NULL;

        END CASE;


        IF alert_text IS NOT NULL THEN

            PERFORM create_alert(

                customer_record.id,
                active_rule.rule_name,
                alert_severity,
                alert_text

            );

        END IF;

    END LOOP;


    RETURN NEW;

END;

$$;


ALTER FUNCTION "public"."process_aml_rules"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_vault_transfer"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    -- Only act when a manager changes the status from PENDING to APPROVED
    IF NEW.status = 'APPROVED' AND OLD.status = 'PENDING' THEN
        IF NEW.transfer_type = 'VAULT_IN' THEN
            -- Float Request: Add cash to the teller's till
            UPDATE public.tills 
            SET current_balance = current_balance + NEW.amount, 
                updated_at = NOW() 
            WHERE id = NEW.till_id;
        ELSIF NEW.transfer_type = 'VAULT_OUT' THEN
            -- Remittance: Deduct excess cash from the teller's till
            UPDATE public.tills 
            SET current_balance = current_balance - NEW.amount, 
                updated_at = NOW() 
            WHERE id = NEW.till_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."process_vault_transfer"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."propagate_network_contagion"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    target_cust_id UUID;
    counterparty RECORD;
BEGIN
    -- Only execute when a SAR moves to APPROVED or is submitted
    IF NEW.status IN ('PENDING_APPROVAL', 'APPROVED') THEN
        
        -- Identify the primary customer linked to this SAR
        SELECT customer_id INTO target_cust_id 
        FROM public.alerts 
        WHERE id = NEW.alert_id;

        IF target_cust_id IS NOT NULL THEN
            -- Find all distinct accounts that transacted with the target in the last 30 days
            FOR counterparty IN 
                SELECT DISTINCT c.id, c.risk_score, c.risk_tier, c.entity_name
                FROM public.transactions t
                JOIN public.accounts a ON (t.account_id = a.id)
                JOIN public.customers c ON (a.customer_id = c.id)
                WHERE c.id != target_cust_id
                  AND t.transaction_timestamp >= NOW() - INTERVAL '30 days'
                  -- Add logic here to match counterparty account references if stored in tx metadata
            LOOP
                -- Apply a +25 point Contagion Penalty (capped at 99)
                UPDATE public.customers
                SET risk_score = LEAST(99, COALESCE(risk_score, 10) + 25),
                    risk_tier = CASE 
                        WHEN LEAST(99, COALESCE(risk_score, 10) + 25) >= 75 THEN 'HIGH'
                        WHEN LEAST(99, COALESCE(risk_score, 10) + 25) >= 40 THEN 'MEDIUM'
                        ELSE 'LOW'
                    END
                WHERE id = counterparty.id;

                -- Record the automated contagion shift in the immutable risk ledger
                INSERT INTO public.risk_score_history (
                    customer_id, previous_score, new_score, previous_tier, new_tier, change_reason
                ) VALUES (
                    counterparty.id,
                    COALESCE(counterparty.risk_score, 10),
                    LEAST(99, COALESCE(counterparty.risk_score, 10) + 25),
                    COALESCE(counterparty.risk_tier, 'LOW'),
                    CASE 
                        WHEN LEAST(99, COALESCE(counterparty.risk_score, 10) + 25) >= 75 THEN 'HIGH'
                        WHEN LEAST(99, COALESCE(counterparty.risk_score, 10) + 25) >= 40 THEN 'MEDIUM'
                        ELSE 'LOW'
                    END,
                    'AUTOMATED NETWORK CONTAGION: Direct counterparty exposure to finalized SAR.'
                );
            END LOOP;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."propagate_network_contagion"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."provision_new_customer"("p_tenant_id" "text", "p_customer_type" "text", "p_first_name" "text", "p_last_name" "text", "p_company_name" "text", "p_bvn" "text", "p_phone" "text", "p_email" "text", "p_industry" "text", "p_address" "text") RETURNS json
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_new_customer_id UUID := gen_random_uuid();
    v_new_account_id UUID := gen_random_uuid();
    v_new_account_number TEXT;
    v_entity_name TEXT;
    v_initial_risk_score NUMERIC := 10; -- Base Low Risk
    v_initial_risk_tier TEXT := 'LOW';
BEGIN
    -- 1. Format the Entity Name and Day-0 Risk based on Customer Type
    IF p_customer_type = 'Corporate' THEN
        v_entity_name := p_company_name;
        v_initial_risk_score := 30; -- Corporate entities carry slightly higher base risk
    ELSE
        v_entity_name := p_first_name || ' ' || p_last_name;
    END IF;

    -- 2. Insert the Customer Profile
    INSERT INTO public.customers (
        id, tenant_id, customer_type, first_name, last_name, company_name, 
        entity_name, bvn, phone_number, email, industry, address_line, 
        kyc_status, risk_score, risk_tier, created_at, updated_at
    ) VALUES (
        v_new_customer_id, p_tenant_id, p_customer_type, p_first_name, p_last_name, p_company_name, 
        v_entity_name, p_bvn, p_phone, p_email, p_industry, p_address, 
        'PENDING', v_initial_risk_score, v_initial_risk_tier, NOW(), NOW()
    );

    -- 3. Generate a deterministic 10-digit account number (Prefix '10' + 8 random digits)
    v_new_account_number := '10' || lpad(floor(random() * 100000000)::text, 8, '0');

    -- 4. Insert the Linked Bank Account
    INSERT INTO public.accounts (
        id, customer_id, account_number, account_type, currency, 
        status, branch_code, opened_at, created_at, updated_at, balance
    ) VALUES (
        v_new_account_id, v_new_customer_id, v_new_account_number, 'STANDARD', 'NGN', 
        'ACTIVE', '001', CURRENT_DATE, NOW(), NOW(), 0.00
    );

    -- 5. Return success payload to the Teller UI
    RETURN json_build_object(
        'status', 'success',
        'customer_id', v_new_customer_id,
        'account_number', v_new_account_number,
        'entity_name', v_entity_name
    );
EXCEPTION
    WHEN OTHERS THEN
        -- If anything fails (e.g., duplicate BVN), rollback and throw error to the UI
        RAISE EXCEPTION 'Provisioning failed: %', SQLERRM;
END;
$$;


ALTER FUNCTION "public"."provision_new_customer"("p_tenant_id" "text", "p_customer_type" "text", "p_first_name" "text", "p_last_name" "text", "p_company_name" "text", "p_bvn" "text", "p_phone" "text", "p_email" "text", "p_industry" "text", "p_address" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalculate_customer_risk"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
    base_score INTEGER := 10;
    critical_count INTEGER;
    high_count INTEGER;
    calculated_score INTEGER;
    calculated_tier TEXT;
    old_score INTEGER;
    old_tier TEXT;
BEGIN
    -- Get the customer's current score before we change it (Explicitly cast to TEXT)
    SELECT risk_score, risk_tier::TEXT INTO old_score, old_tier 
    FROM public.customers 
    WHERE id = NEW.customer_id;
    
    -- Count how many bad things they've done
    SELECT count(*) INTO critical_count FROM public.alerts WHERE customer_id = NEW.customer_id AND severity = 'CRITICAL';
    SELECT count(*) INTO high_count FROM public.alerts WHERE customer_id = NEW.customer_id AND severity = 'HIGH';

    -- The Penalty Math: 40 points for Critical, 20 points for High
    calculated_score := base_score + (critical_count * 40) + (high_count * 20);
    IF calculated_score > 100 THEN calculated_score := 100; END IF;

    -- Map Score to Tier
    IF calculated_score >= 75 THEN calculated_tier := 'HIGH';
    ELSIF calculated_score >= 40 THEN calculated_tier := 'MEDIUM';
    ELSE calculated_tier := 'LOW';
    END IF;

    -- If the score actually changed, update the customer and log it
    IF old_score IS DISTINCT FROM calculated_score THEN
        -- Update the profile (Explicitly cast back to the custom ENUM type)
        UPDATE public.customers 
        SET risk_score = calculated_score, risk_tier = calculated_tier::public.risk_tier
        WHERE id = NEW.customer_id;

        -- Write the receipt to the ledger
        INSERT INTO public.risk_score_history (
            customer_id, previous_score, new_score, previous_tier, new_tier, change_reason
        ) VALUES (
            NEW.customer_id, old_score, calculated_score, old_tier, calculated_tier, 
            'System auto-recalculation triggered by new ' || NEW.severity || ' alert: ' || NEW.rule_triggered
        );
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."recalculate_customer_risk"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."risk_escalation_offset"("p_risk_level" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $_$
SELECT
CASE UPPER(TRIM(COALESCE($1,'LOW')))
    WHEN 'HIGH' THEN 1
    WHEN 'CRITICAL' THEN 2
    ELSE 0
END;
$_$;


ALTER FUNCTION "public"."risk_escalation_offset"("p_risk_level" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."screen_transactions_for_sanctions"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
    target_customer_id UUID;
    sanction_match TEXT;
BEGIN
    -- Find the customer associated with this account
    SELECT customer_id INTO target_customer_id FROM public.accounts WHERE id = NEW.account_id;

    -- Check if the counterparty or the narration contains any name from our watchlist
    SELECT entity_name INTO sanction_match 
    FROM public.sanctions_watchlist 
    WHERE NEW.counterparty_name ILIKE '%' || entity_name || '%' 
       OR NEW.narration ILIKE '%' || entity_name || '%'
    LIMIT 1;

    -- If a match is found, spawn a Sanctions Alert
    IF sanction_match IS NOT NULL THEN
        INSERT INTO public.alerts (alert_ref, customer_id, rule_triggered, severity, status, details)
        VALUES (
            'SNC-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6)), 
            target_customer_id,
            'Sanctions / Watchlist Match', 
            'CRITICAL', 
            'UNASSIGNED',
            'Direct match found for restricted entity: ' || sanction_match
        );
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."screen_transactions_for_sanctions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."severity_from_rank"("p_rank" integer) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
SELECT
CASE
    WHEN $1 <= 1 THEN 'LOW'
    WHEN $1 = 2 THEN 'MEDIUM'
    WHEN $1 = 3 THEN 'HIGH'
    ELSE 'CRITICAL'
END;
$_$;


ALTER FUNCTION "public"."severity_from_rank"("p_rank" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."severity_rank"("p_severity" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $_$
SELECT
CASE UPPER(TRIM($1))
    WHEN 'LOW' THEN 1
    WHEN 'MEDIUM' THEN 2
    WHEN 'HIGH' THEN 3
    WHEN 'CRITICAL' THEN 4
    ELSE NULL
END;
$_$;


ALTER FUNCTION "public"."severity_rank"("p_severity" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_customer_risk"("p_customer_id" "uuid", "p_rule_id" "uuid", "p_change_reason" "text", "p_changed_by" "uuid" DEFAULT NULL::"uuid") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$

DECLARE

    v_previous_score INTEGER := 0;
    v_new_score INTEGER;

    v_previous_tier TEXT := 'LOW';
    v_new_tier TEXT;

    v_rule_weight INTEGER;
    v_rule_name TEXT;

BEGIN

    -----------------------------------------------------
    -- Load Rule
    -----------------------------------------------------

    SELECT
        risk_weight,
        rule_name
    INTO
        v_rule_weight,
        v_rule_name
    FROM public.aml_rules
    WHERE id = p_rule_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'AML rule % not found',
            p_rule_id;
    END IF;

    -----------------------------------------------------
    -- Existing Profile
    -----------------------------------------------------

    SELECT
        total_score,
        risk_level
    INTO
        v_previous_score,
        v_previous_tier
    FROM public.customer_risk_profiles
    WHERE customer_id = p_customer_id;

    IF NOT FOUND THEN

        v_previous_score := 0;
        v_previous_tier := 'LOW';

    END IF;

    -----------------------------------------------------
    -- Calculate Score
    -----------------------------------------------------

    v_new_score := v_previous_score + v_rule_weight;

    -----------------------------------------------------
    -- Calculate Tier
    -----------------------------------------------------

    v_new_tier := CASE

        WHEN v_new_score >= 150 THEN 'CRITICAL'

        WHEN v_new_score >= 100 THEN 'HIGH'

        WHEN v_new_score >= 50 THEN 'MEDIUM'

        ELSE 'LOW'

    END;

    -----------------------------------------------------
    -- Upsert Risk Profile
    -----------------------------------------------------

    INSERT INTO public.customer_risk_profiles (

        customer_id,
        total_score,
        risk_level

    )

    VALUES (

        p_customer_id,
        v_new_score,
        v_new_tier

    )

    ON CONFLICT (customer_id)

    DO UPDATE

    SET

        total_score = EXCLUDED.total_score,
        risk_level = EXCLUDED.risk_level,
        updated_at = now();

    -----------------------------------------------------
    -- Audit History
    -----------------------------------------------------

    INSERT INTO public.risk_score_history (

        customer_id,
        previous_score,
        new_score,
        previous_tier,
        new_tier,
        change_reason,
        changed_by

    )

    VALUES (

        p_customer_id,
        v_previous_score,
        v_new_score,
        v_previous_tier,
        v_new_tier,
        p_change_reason,
        p_changed_by

    );

    RETURN v_new_score;

END;

$$;


ALTER FUNCTION "public"."update_customer_risk"("p_customer_id" "uuid", "p_rule_id" "uuid", "p_change_reason" "text", "p_changed_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_customer_risk_score"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
    total_alerts INT;
    calculated_score INT;
    calculated_tier TEXT;
BEGIN
    -- Count open/historical alerts for this specific customer
    SELECT COUNT(*) INTO total_alerts FROM public.alerts WHERE customer_id = NEW.customer_id;
    
    -- Formula: Base score 15 + (25 penalty points per alert). Capped at 99.
    calculated_score := LEAST(15 + (total_alerts * 25), 99);
    
    -- Matrix Mapping
    IF calculated_score >= 75 THEN
        calculated_tier := 'HIGH';
    ELSIF calculated_score >= 40 THEN
        calculated_tier := 'MEDIUM';
    ELSE
        calculated_tier := 'LOW';
    END IF;

    -- Instantly update the Customer 360 profile (Notice the ::risk_tier cast!)
    UPDATE public.customers 
    SET risk_score = calculated_score, risk_tier = calculated_tier::public.risk_tier
    WHERE id = NEW.customer_id;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_customer_risk_score"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_risk_tier"("p_id" "uuid", "p_score" integer, "p_tier" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    UPDATE public.customers
    SET risk_score = p_score, 
        risk_tier = p_tier::risk_tier -- This converts the text to your Enum type safely
    WHERE id = p_id;
END;
$$;


ALTER FUNCTION "public"."update_risk_tier"("p_id" "uuid", "p_score" integer, "p_tier" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_str_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_str_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_till_balance"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Only process if the transaction is linked to a physical till (Branch Cash)
    IF NEW.till_id IS NOT NULL THEN
        IF NEW.transaction_type = 'CREDIT' THEN
            -- Cash Deposit: Increases physical cash in the till
            UPDATE public.tills 
            SET current_balance = current_balance + NEW.amount,
                updated_at = NOW()
            WHERE id = NEW.till_id;
        ELSIF NEW.transaction_type = 'DEBIT' THEN
            -- Cash Withdrawal: Decreases physical cash in the till
            UPDATE public.tills 
            SET current_balance = current_balance - NEW.amount,
                updated_at = NOW()
            WHERE id = NEW.till_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_till_balance"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "customer_id" "uuid" NOT NULL,
    "account_number" character varying(10) NOT NULL,
    "account_type" "text" NOT NULL,
    "currency" character varying(3) DEFAULT 'NGN'::character varying,
    "status" "public"."account_status" DEFAULT 'ACTIVE'::"public"."account_status",
    "branch_code" "text",
    "opened_at" "date" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "balance" numeric DEFAULT 500000.00
);


ALTER TABLE "public"."accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."alerts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "alert_ref" "text" NOT NULL,
    "customer_id" "uuid",
    "transaction_id" "uuid",
    "rule_triggered" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "status" "text" DEFAULT 'UNASSIGNED'::"text",
    "details" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "assigned_user_id" "uuid",
    "qa_reviewed_by" "uuid",
    "qa_review_notes" "text",
    "qa_reviewed_at" timestamp with time zone
);


ALTER TABLE "public"."alerts" OWNER TO "postgres";


COMMENT ON COLUMN "public"."alerts"."qa_reviewed_by" IS 'Stores the UUID of the Head of Compliance or QA Lead who verified a false-positive dismissal.';



CREATE TABLE IF NOT EXISTS "public"."aml_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "text" NOT NULL,
    "created_by" "uuid",
    "rule_name" "text" NOT NULL,
    "description" "text",
    "target_entity" "text" NOT NULL,
    "condition_type" "text" NOT NULL,
    "threshold_value" numeric,
    "time_window_hours" integer DEFAULT 24,
    "action_to_take" "text" DEFAULT 'GENERATE_ALERT'::"text",
    "status" "text" DEFAULT 'ACTIVE'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "rule_metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "mode" "text" DEFAULT 'ACTIVE'::"text",
    "risk_weight" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "aml_rules_action_to_take_check" CHECK (("action_to_take" = ANY (ARRAY['GENERATE_ALERT'::"text", 'AUTO_FREEZE'::"text", 'SILENT_MONITOR'::"text"]))),
    CONSTRAINT "aml_rules_condition_type_check" CHECK (("condition_type" = ANY (ARRAY['AMOUNT_ABOVE'::"text", 'STRUCTURING_PATTERN'::"text", 'VELOCITY_COUNT'::"text", 'BEHAVIORAL_VELOCITY'::"text", 'STATIC_THRESHOLD'::"text", 'DORMANT_ACCOUNT_ACTIVITY'::"text"]))),
    CONSTRAINT "aml_rules_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'PENDING_APPROVAL'::"text", 'ACTIVE'::"text", 'INACTIVE'::"text"])))
);


ALTER TABLE "public"."aml_rules" OWNER TO "postgres";


COMMENT ON COLUMN "public"."aml_rules"."rule_metadata" IS 'Stores dynamic algorithmic parameters for the smart AML engine.';



CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "event_type" "text" NOT NULL,
    "actor_id" "uuid",
    "target_id" "uuid",
    "details" "jsonb",
    "tenant_id" "uuid"
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."banks" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "logo_url" "text",
    "primary_color" "text",
    "secondary_color" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."banks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."custom_roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "role_name" "text" NOT NULL,
    "description" "text",
    "permissions" "jsonb" NOT NULL,
    "tenant_id" "uuid",
    "created_by" "uuid"
);


ALTER TABLE "public"."custom_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_baselines" (
    "customer_id" "uuid" NOT NULL,
    "avg_tx_amount" numeric(15,2) DEFAULT 0.00,
    "stddev_tx_amount" numeric(15,2) DEFAULT 0.00,
    "daily_velocity_avg" numeric(10,2) DEFAULT 0.00,
    "last_calculated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."customer_baselines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_risk_profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "customer_id" "uuid" NOT NULL,
    "total_score" integer DEFAULT 0 NOT NULL,
    "risk_level" "text" DEFAULT 'LOW'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "customer_risk_profiles_risk_level_check" CHECK (("risk_level" = ANY (ARRAY['LOW'::"text", 'MEDIUM'::"text", 'HIGH'::"text", 'CRITICAL'::"text"])))
);


ALTER TABLE "public"."customer_risk_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "customer_type" "text" NOT NULL,
    "first_name" "text",
    "last_name" "text",
    "middle_name" "text",
    "date_of_birth" "date",
    "company_name" "text",
    "registration_number" "text",
    "incorporation_date" "date",
    "bvn" character varying(11),
    "nin" character varying(11),
    "email" "text",
    "phone_number" "text",
    "address_line" "text",
    "city" "text",
    "lga" "text",
    "state" "text",
    "country" "text" DEFAULT 'NG'::"text",
    "industry_code" "text",
    "is_pep" boolean DEFAULT false,
    "risk_score" numeric(5,2) DEFAULT 0.00,
    "risk_tier" "text" DEFAULT 'LOW'::"public"."risk_tier",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "entity_name" "text",
    "industry" "text",
    "geography" "text",
    "ubo_name" "text",
    "iei_exposure" boolean DEFAULT false,
    "kyc_status" "text" DEFAULT 'PENDING'::"text" NOT NULL,
    "tenant_id" "text",
    "identity_embedding" "public"."vector"(384),
    "id_url" "text",
    "utility_bill_url" "text"
);


ALTER TABLE "public"."customers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."loans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "text" NOT NULL,
    "account_id" "uuid" NOT NULL,
    "loan_reference" "text" NOT NULL,
    "principal" numeric NOT NULL,
    "interest_rate" numeric NOT NULL,
    "term_months" integer NOT NULL,
    "monthly_pmt" numeric NOT NULL,
    "remaining_balance" numeric NOT NULL,
    "status" "text" DEFAULT 'ACTIVE'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "next_payment_date" "date",
    "last_payment_date" "date"
);


ALTER TABLE "public"."loans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "full_name" "text",
    "email" "text",
    "role" "text",
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "tenant_id" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."report_archives" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "text" NOT NULL,
    "generated_by" "uuid",
    "report_type" "text" NOT NULL,
    "file_name" "text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "retention_expires_at" timestamp with time zone DEFAULT ("now"() + '7 years'::interval) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."report_archives" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."report_schedules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "text" NOT NULL,
    "configured_by" "uuid",
    "report_type" "text" DEFAULT 'COMPLIANCE_SUMMARY'::"text" NOT NULL,
    "frequency" "text" NOT NULL,
    "recipient_emails" "text"[] NOT NULL,
    "is_active" boolean DEFAULT true,
    "last_run_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "report_schedules_frequency_check" CHECK (("frequency" = ANY (ARRAY['DAILY'::"text", 'WEEKLY'::"text", 'MONTHLY'::"text"])))
);


ALTER TABLE "public"."report_schedules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."risk_score_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "customer_id" "uuid",
    "previous_score" integer,
    "new_score" integer,
    "previous_tier" "text",
    "new_tier" "text",
    "change_reason" "text" NOT NULL,
    "changed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."risk_score_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sanctions_watchlist" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "entity_name" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "list_source" "text" NOT NULL,
    "risk_level" "text" DEFAULT 'CRITICAL'::"text",
    "added_on" timestamp with time zone DEFAULT "now"(),
    "entity_embedding" "public"."vector"(384)
);


ALTER TABLE "public"."sanctions_watchlist" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shadow_evaluations" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "transaction_id" "uuid",
    "rule_name" "text",
    "evaluation_result" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "tenant_id" "text"
);


ALTER TABLE "public"."shadow_evaluations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."suspicious_transaction_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "alert_id" "uuid",
    "tenant_id" "text" NOT NULL,
    "generated_by" "uuid",
    "reviewed_by" "uuid",
    "report_data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "investigator_notes" "text",
    "executive_justification" "text",
    "status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "pdf_archive_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "locked_at" timestamp with time zone,
    "created_by" "uuid",
    CONSTRAINT "suspicious_transaction_reports_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'PENDING_APPROVAL'::"text", 'APPROVED'::"text", 'REJECTED'::"text", 'SUBMITTED_TO_NFIU'::"text"])))
);


ALTER TABLE "public"."suspicious_transaction_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."system_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_type" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "message" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "tenant_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "user_id" "uuid" DEFAULT "auth"."uid"()
);


ALTER TABLE "public"."system_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "institution_name" "text" NOT NULL,
    "cbn_license_number" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tenants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tills" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "text" NOT NULL,
    "teller_id" "uuid" NOT NULL,
    "status" "text" NOT NULL,
    "opening_balance" numeric DEFAULT 0.00,
    "current_balance" numeric DEFAULT 0.00,
    "closing_balance" numeric,
    "vault_limit" numeric DEFAULT 5000000.00,
    "opened_at" timestamp with time zone DEFAULT "now"(),
    "closed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "declared_balance" numeric,
    "variance" numeric,
    "manager_override_id" "uuid",
    CONSTRAINT "tills_status_check" CHECK (("status" = ANY (ARRAY['OPEN'::"text", 'CLOSED'::"text", 'BALANCING'::"text", 'DISCREPANCY'::"text"])))
);


ALTER TABLE "public"."tills" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "transaction_reference" "text" NOT NULL,
    "account_id" "uuid" NOT NULL,
    "amount" numeric(15,2) NOT NULL,
    "currency" character varying(3) DEFAULT 'NGN'::character varying,
    "transaction_type" "public"."transaction_type" NOT NULL,
    "channel" "public"."transaction_channel" NOT NULL,
    "narration" "text",
    "counterparty_name" "text",
    "counterparty_account" character varying(20),
    "counterparty_bank" "text",
    "transaction_timestamp" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "tx_type" "text",
    "timestamp" timestamp with time zone,
    "till_id" "uuid"
);


ALTER TABLE "public"."transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_profiles" (
    "id" "uuid" NOT NULL,
    "tenant_id" "text",
    "role" "text" NOT NULL,
    "full_name" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "user_profiles_role_check" CHECK (("role" = ANY (ARRAY['compliance_officer'::"text", 'bank_manager'::"text", 'head_of_compliance'::"text", 'it_admin'::"text"])))
);


ALTER TABLE "public"."user_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vault_transfers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "text" NOT NULL,
    "till_id" "uuid" NOT NULL,
    "teller_id" "uuid" NOT NULL,
    "manager_id" "uuid",
    "transfer_type" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "status" "text" NOT NULL,
    "reference" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "vault_transfers_status_check" CHECK (("status" = ANY (ARRAY['PENDING'::"text", 'APPROVED'::"text", 'REJECTED'::"text"]))),
    CONSTRAINT "vault_transfers_transfer_type_check" CHECK (("transfer_type" = ANY (ARRAY['VAULT_IN'::"text", 'VAULT_OUT'::"text"])))
);


ALTER TABLE "public"."vault_transfers" OWNER TO "postgres";


ALTER TABLE ONLY "public"."accounts"
    ADD CONSTRAINT "accounts_account_number_key" UNIQUE ("account_number");



ALTER TABLE ONLY "public"."accounts"
    ADD CONSTRAINT "accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."alerts"
    ADD CONSTRAINT "alerts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."aml_rules"
    ADD CONSTRAINT "aml_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."aml_rules"
    ADD CONSTRAINT "aml_rules_rule_name_key" UNIQUE ("rule_name");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."banks"
    ADD CONSTRAINT "banks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."custom_roles"
    ADD CONSTRAINT "custom_roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer_baselines"
    ADD CONSTRAINT "customer_baselines_pkey" PRIMARY KEY ("customer_id");



ALTER TABLE ONLY "public"."customer_risk_profiles"
    ADD CONSTRAINT "customer_risk_profiles_customer_id_key" UNIQUE ("customer_id");



ALTER TABLE ONLY "public"."customer_risk_profiles"
    ADD CONSTRAINT "customer_risk_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_bvn_key" UNIQUE ("bvn");



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_nin_key" UNIQUE ("nin");



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."loans"
    ADD CONSTRAINT "loans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."report_archives"
    ADD CONSTRAINT "report_archives_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."report_schedules"
    ADD CONSTRAINT "report_schedules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."risk_score_history"
    ADD CONSTRAINT "risk_score_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sanctions_watchlist"
    ADD CONSTRAINT "sanctions_watchlist_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shadow_evaluations"
    ADD CONSTRAINT "shadow_evaluations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."suspicious_transaction_reports"
    ADD CONSTRAINT "suspicious_transaction_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."system_events"
    ADD CONSTRAINT "system_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tills"
    ADD CONSTRAINT "tills_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_transaction_reference_key" UNIQUE ("transaction_reference");



ALTER TABLE ONLY "public"."custom_roles"
    ADD CONSTRAINT "unique_role_per_tenant" UNIQUE ("role_name", "tenant_id");



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vault_transfers"
    ADD CONSTRAINT "vault_transfers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vault_transfers"
    ADD CONSTRAINT "vault_transfers_reference_key" UNIQUE ("reference");



CREATE INDEX "customers_identity_embedding_idx" ON "public"."customers" USING "hnsw" ("identity_embedding" "public"."vector_cosine_ops");



CREATE INDEX "idx_accounts_customer_id" ON "public"."accounts" USING "btree" ("customer_id");



CREATE INDEX "idx_accounts_number" ON "public"."accounts" USING "btree" ("account_number");



CREATE INDEX "idx_customers_bvn" ON "public"."customers" USING "btree" ("bvn");



CREATE INDEX "idx_customers_risk_tier" ON "public"."customers" USING "btree" ("risk_tier");



CREATE INDEX "idx_str_status_tenant" ON "public"."suspicious_transaction_reports" USING "btree" ("tenant_id", "status");



CREATE INDEX "idx_transactions_account_id" ON "public"."transactions" USING "btree" ("account_id");



CREATE INDEX "idx_transactions_amount" ON "public"."transactions" USING "btree" ("amount");



CREATE INDEX "idx_transactions_timestamp" ON "public"."transactions" USING "btree" ("transaction_timestamp");



CREATE INDEX "idx_transactions_type_channel" ON "public"."transactions" USING "btree" ("transaction_type", "channel");



CREATE INDEX "sanctions_entity_embedding_idx" ON "public"."sanctions_watchlist" USING "hnsw" ("entity_embedding" "public"."vector_cosine_ops");



CREATE OR REPLACE TRIGGER "match_entity_webhook" AFTER INSERT OR UPDATE OF "entity_name", "industry", "geography" ON "public"."customers" FOR EACH ROW EXECUTE FUNCTION "public"."enqueue_match_entity_webhook"();



CREATE OR REPLACE TRIGGER "str_update_timestamp" BEFORE UPDATE ON "public"."suspicious_transaction_reports" FOR EACH ROW EXECUTE FUNCTION "public"."update_str_timestamp"();



CREATE OR REPLACE TRIGGER "trg_network_contagion" AFTER INSERT OR UPDATE ON "public"."suspicious_transaction_reports" FOR EACH ROW EXECUTE FUNCTION "public"."propagate_network_contagion"();



CREATE OR REPLACE TRIGGER "trigger_aml_engine" AFTER INSERT ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."process_aml_rules"();



CREATE OR REPLACE TRIGGER "trigger_behavioral_anomaly" AFTER INSERT ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."evaluate_behavioral_anomaly"();



CREATE OR REPLACE TRIGGER "trigger_mule_ring_eval" AFTER INSERT ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."evaluate_mule_ring"();



CREATE OR REPLACE TRIGGER "trigger_recalculate_risk" AFTER INSERT ON "public"."alerts" FOR EACH ROW EXECUTE FUNCTION "public"."recalculate_customer_risk"();



CREATE OR REPLACE TRIGGER "trigger_risk_scoring" AFTER INSERT OR UPDATE ON "public"."alerts" FOR EACH ROW EXECUTE FUNCTION "public"."update_customer_risk_score"();



CREATE OR REPLACE TRIGGER "trigger_sanctions_screening" AFTER INSERT ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."screen_transactions_for_sanctions"();



CREATE OR REPLACE TRIGGER "trigger_update_till" AFTER INSERT ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."update_till_balance"();



CREATE OR REPLACE TRIGGER "trigger_vault_transfer_approval" AFTER UPDATE ON "public"."vault_transfers" FOR EACH ROW EXECUTE FUNCTION "public"."process_vault_transfer"();



ALTER TABLE ONLY "public"."accounts"
    ADD CONSTRAINT "accounts_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alerts"
    ADD CONSTRAINT "alerts_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id");



ALTER TABLE ONLY "public"."alerts"
    ADD CONSTRAINT "alerts_qa_reviewed_by_fkey" FOREIGN KEY ("qa_reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."alerts"
    ADD CONSTRAINT "alerts_transaction_id_fkey" FOREIGN KEY ("transaction_id") REFERENCES "public"."transactions"("id");



ALTER TABLE ONLY "public"."aml_rules"
    ADD CONSTRAINT "aml_rules_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."custom_roles"
    ADD CONSTRAINT "custom_roles_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."customer_baselines"
    ADD CONSTRAINT "customer_baselines_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."customer_risk_profiles"
    ADD CONSTRAINT "customer_risk_profiles_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loans"
    ADD CONSTRAINT "loans_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."report_archives"
    ADD CONSTRAINT "report_archives_generated_by_fkey" FOREIGN KEY ("generated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."report_schedules"
    ADD CONSTRAINT "report_schedules_configured_by_fkey" FOREIGN KEY ("configured_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."risk_score_history"
    ADD CONSTRAINT "risk_score_history_changed_by_fkey" FOREIGN KEY ("changed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."risk_score_history"
    ADD CONSTRAINT "risk_score_history_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shadow_evaluations"
    ADD CONSTRAINT "shadow_evaluations_transaction_id_fkey" FOREIGN KEY ("transaction_id") REFERENCES "public"."transactions"("id");



ALTER TABLE ONLY "public"."suspicious_transaction_reports"
    ADD CONSTRAINT "suspicious_transaction_reports_alert_id_fkey" FOREIGN KEY ("alert_id") REFERENCES "public"."alerts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."suspicious_transaction_reports"
    ADD CONSTRAINT "suspicious_transaction_reports_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."suspicious_transaction_reports"
    ADD CONSTRAINT "suspicious_transaction_reports_generated_by_fkey" FOREIGN KEY ("generated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."suspicious_transaction_reports"
    ADD CONSTRAINT "suspicious_transaction_reports_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."tills"
    ADD CONSTRAINT "tills_manager_override_id_fkey" FOREIGN KEY ("manager_override_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."tills"
    ADD CONSTRAINT "tills_teller_id_fkey" FOREIGN KEY ("teller_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_till_id_fkey" FOREIGN KEY ("till_id") REFERENCES "public"."tills"("id");



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."banks"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."vault_transfers"
    ADD CONSTRAINT "vault_transfers_manager_id_fkey" FOREIGN KEY ("manager_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."vault_transfers"
    ADD CONSTRAINT "vault_transfers_teller_id_fkey" FOREIGN KEY ("teller_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."vault_transfers"
    ADD CONSTRAINT "vault_transfers_till_id_fkey" FOREIGN KEY ("till_id") REFERENCES "public"."tills"("id");



CREATE POLICY "Allow authenticated read on system_events" ON "public"."system_events" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated users to view branch roles" ON "public"."custom_roles" FOR SELECT USING ((("tenant_id" = (NULLIF((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'tenant_id'::"text"), ''::"text"))::"uuid") OR ("tenant_id" IS NULL)));



CREATE POLICY "Allow dashboard read access" ON "public"."system_events" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow officers to read risk history" ON "public"."risk_score_history" FOR SELECT USING (true);



CREATE POLICY "Allow officers to view transactions" ON "public"."transactions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow read on report_archives" ON "public"."report_archives" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow team to view profiles" ON "public"."profiles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Audit logs can be read by authorized roles" ON "public"."system_events" FOR SELECT USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = ANY (ARRAY['system_admin'::"text", 'head_of_compliance'::"text", 'auditor'::"text"])));



CREATE POLICY "Bank Manager Select Alerts" ON "public"."alerts" FOR SELECT USING ((("auth"."jwt"() ->> 'role'::"text") = 'bank_manager'::"text"));



CREATE POLICY "Bank Manager Select Customers" ON "public"."customers" FOR SELECT USING ((("auth"."jwt"() ->> 'role'::"text") = 'bank_manager'::"text"));



CREATE POLICY "Bank Manager Select Transactions" ON "public"."transactions" FOR SELECT USING ((("auth"."jwt"() ->> 'role'::"text") = 'bank_manager'::"text"));



CREATE POLICY "Deny deletions on report_archives" ON "public"."report_archives" FOR DELETE TO "authenticated" USING (false);



CREATE POLICY "Deny deletions on system_events" ON "public"."system_events" FOR DELETE TO "authenticated" USING (false);



CREATE POLICY "Deny updates on report_archives" ON "public"."report_archives" FOR UPDATE TO "authenticated" USING (false);



CREATE POLICY "Deny updates on system_events" ON "public"."system_events" FOR UPDATE TO "authenticated" USING (false);



CREATE POLICY "Enable insert for IT Admins" ON "public"."banks" FOR INSERT TO "authenticated" WITH CHECK (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'it_admin'::"text"));



CREATE POLICY "Enable read access for all authenticated users" ON "public"."banks" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable read access for all authenticated users" ON "public"."user_profiles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Executives can update STRs" ON "public"."suspicious_transaction_reports" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Head of Compliance views own tenant logs" ON "public"."audit_logs" FOR SELECT USING ((((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'head_of_compliance'::"text") AND ("tenant_id" = (NULLIF((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'tenant_id'::"text"), ''::"text"))::"uuid")));



CREATE POLICY "Heads of Compliance can view branch custom roles" ON "public"."custom_roles" FOR SELECT USING (("tenant_id" = (NULLIF((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'tenant_id'::"text"), ''::"text"))::"uuid"));



CREATE POLICY "IT Admins can manage all custom roles" ON "public"."custom_roles" USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'it_admin'::"text"));



CREATE POLICY "IT Admins can view all audit logs" ON "public"."audit_logs" FOR SELECT USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'it_admin'::"text"));



CREATE POLICY "IT Admins can view system telemetry" ON "public"."system_events" FOR SELECT USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'it_admin'::"text"));



CREATE POLICY "IT Admins manage all profiles" ON "public"."user_profiles" USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'it_admin'::"text"));



CREATE POLICY "Managers can override tills" ON "public"."tills" FOR UPDATE TO "authenticated" USING (true);



CREATE POLICY "Officers can insert STRs" ON "public"."suspicious_transaction_reports" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure AML Rules" ON "public"."aml_rules" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure Alerts" ON "public"."alerts" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure Customers" ON "public"."customers" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure Report Archives" ON "public"."report_archives" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure Report Schedules" ON "public"."report_schedules" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure Risk History" ON "public"."risk_score_history" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure STRs" ON "public"."suspicious_transaction_reports" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure Sanctions" ON "public"."sanctions_watchlist" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure Shadow Evals" ON "public"."shadow_evaluations" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure System Events" ON "public"."system_events" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure Tenants" ON "public"."tenants" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Secure Transactions" ON "public"."transactions" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Simulator can read accounts" ON "public"."accounts" FOR SELECT USING (true);



CREATE POLICY "Staff can manage vault transfers" ON "public"."vault_transfers" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Staff can view accounts" ON "public"."accounts" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Staff can view all tills" ON "public"."tills" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Staff can view customers" ON "public"."customers" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Strict Tenant Audit Visibility" ON "public"."audit_logs" FOR SELECT USING ((((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'it_admin'::"text") OR ("tenant_id" = (NULLIF((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'tenant_id'::"text"), ''::"text"))::"uuid")));



CREATE POLICY "Tellers can open tills" ON "public"."tills" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "teller_id"));



CREATE POLICY "Tellers can update their own tills" ON "public"."tills" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "teller_id"));



CREATE POLICY "Tellers can view their own tills" ON "public"."tills" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "teller_id"));



CREATE POLICY "Users can always read their own profile during JWT lag" ON "public"."profiles" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can read own profile" ON "public"."user_profiles" FOR SELECT USING (("auth"."uid"() = "id"));



ALTER TABLE "public"."accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."alerts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."aml_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."banks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."custom_roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."customer_baselines" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."customers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."report_archives" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."report_schedules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."risk_score_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sanctions_watchlist" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shadow_evaluations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."suspicious_transaction_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."system_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tenants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tills" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vault_transfers" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."system_events";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."transactions";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "supabase_auth_admin";






GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "service_role";











































































































































































REVOKE ALL ON FUNCTION "public"."audit_safe_login_func"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."audit_safe_login_func"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_safe_login_func"() TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_alert_severity"("p_rule_severity" "text", "p_customer_risk" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_alert_severity"("p_rule_severity" "text", "p_customer_risk" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_alert_severity"("p_rule_severity" "text", "p_customer_risk" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_dynamic_baselines"() TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_dynamic_baselines"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_dynamic_baselines"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_massive_outflow"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_massive_outflow"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_massive_outflow"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_alert"("p_customer_id" "uuid", "p_rule_name" "text", "p_severity" "text", "p_details" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_alert"("p_customer_id" "uuid", "p_rule_name" "text", "p_severity" "text", "p_details" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_alert"("p_customer_id" "uuid", "p_rule_name" "text", "p_severity" "text", "p_details" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "supabase_auth_admin";



GRANT ALL ON FUNCTION "public"."detect_circular_layering"("start_account_id" "uuid", "max_hops" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."detect_circular_layering"("start_account_id" "uuid", "max_hops" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."detect_circular_layering"("start_account_id" "uuid", "max_hops" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_match_entity_webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_match_entity_webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_match_entity_webhook"() TO "service_role";



GRANT ALL ON FUNCTION "public"."evaluate_amount_above"("p_amount" numeric, "p_threshold" numeric, "p_rule_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."evaluate_amount_above"("p_amount" numeric, "p_threshold" numeric, "p_rule_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."evaluate_amount_above"("p_amount" numeric, "p_threshold" numeric, "p_rule_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."evaluate_behavioral_anomaly"() TO "anon";
GRANT ALL ON FUNCTION "public"."evaluate_behavioral_anomaly"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."evaluate_behavioral_anomaly"() TO "service_role";



GRANT ALL ON FUNCTION "public"."evaluate_dormant_account_activity"("p_account_id" "uuid", "p_current_transaction_timestamp" timestamp with time zone, "p_threshold_days" integer, "p_rule_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."evaluate_dormant_account_activity"("p_account_id" "uuid", "p_current_transaction_timestamp" timestamp with time zone, "p_threshold_days" integer, "p_rule_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."evaluate_dormant_account_activity"("p_account_id" "uuid", "p_current_transaction_timestamp" timestamp with time zone, "p_threshold_days" integer, "p_rule_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."evaluate_mule_ring"() TO "anon";
GRANT ALL ON FUNCTION "public"."evaluate_mule_ring"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."evaluate_mule_ring"() TO "service_role";



GRANT ALL ON FUNCTION "public"."evaluate_rule_metadata"("p_rule_metadata" "jsonb", "p_transaction_type" "text", "p_channel" "text", "p_currency" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."evaluate_rule_metadata"("p_rule_metadata" "jsonb", "p_transaction_type" "text", "p_channel" "text", "p_currency" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."evaluate_rule_metadata"("p_rule_metadata" "jsonb", "p_transaction_type" "text", "p_channel" "text", "p_currency" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."evaluate_structuring"("p_account_id" "uuid", "p_amount" numeric, "p_threshold" numeric, "p_window_hours" integer, "p_rule_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."evaluate_structuring"("p_account_id" "uuid", "p_amount" numeric, "p_threshold" numeric, "p_window_hours" integer, "p_rule_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."evaluate_structuring"("p_account_id" "uuid", "p_amount" numeric, "p_threshold" numeric, "p_window_hours" integer, "p_rule_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."evaluate_velocity_count"("p_account_id" "uuid", "p_threshold" numeric, "p_time_window_hours" integer, "p_rule_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."evaluate_velocity_count"("p_account_id" "uuid", "p_threshold" numeric, "p_time_window_hours" integer, "p_rule_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."evaluate_velocity_count"("p_account_id" "uuid", "p_threshold" numeric, "p_time_window_hours" integer, "p_rule_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_last_account_activity"("p_account_id" "uuid", "p_current_transaction_timestamp" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."get_last_account_activity"("p_account_id" "uuid", "p_current_transaction_timestamp" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_last_account_activity"("p_account_id" "uuid", "p_current_transaction_timestamp" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_rolling_tx_stats"("p_account_id" "uuid", "p_hours" integer, "p_tx_type" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_rolling_tx_stats"("p_account_id" "uuid", "p_hours" integer, "p_tx_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_rolling_tx_stats"("p_account_id" "uuid", "p_hours" integer, "p_tx_type" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_rolling_tx_volume"("p_account_id" "uuid", "p_hours" integer, "p_tx_type" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_rolling_tx_volume"("p_account_id" "uuid", "p_hours" integer, "p_tx_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_rolling_tx_volume"("p_account_id" "uuid", "p_hours" integer, "p_tx_type" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "service_role";



REVOKE ALL ON FUNCTION "public"."log_user_login"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."log_user_login"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_user_login"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."log_user_logout"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."log_user_logout"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_user_logout"() TO "service_role";



GRANT ALL ON FUNCTION "public"."match_sanctions"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."match_sanctions"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_sanctions"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."process_aml_rules"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."process_aml_rules"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_aml_rules"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_vault_transfer"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_vault_transfer"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_vault_transfer"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."propagate_network_contagion"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."propagate_network_contagion"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."propagate_network_contagion"() TO "service_role";



GRANT ALL ON FUNCTION "public"."provision_new_customer"("p_tenant_id" "text", "p_customer_type" "text", "p_first_name" "text", "p_last_name" "text", "p_company_name" "text", "p_bvn" "text", "p_phone" "text", "p_email" "text", "p_industry" "text", "p_address" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."provision_new_customer"("p_tenant_id" "text", "p_customer_type" "text", "p_first_name" "text", "p_last_name" "text", "p_company_name" "text", "p_bvn" "text", "p_phone" "text", "p_email" "text", "p_industry" "text", "p_address" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."provision_new_customer"("p_tenant_id" "text", "p_customer_type" "text", "p_first_name" "text", "p_last_name" "text", "p_company_name" "text", "p_bvn" "text", "p_phone" "text", "p_email" "text", "p_industry" "text", "p_address" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."recalculate_customer_risk"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recalculate_customer_risk"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_customer_risk"() TO "service_role";



GRANT ALL ON FUNCTION "public"."risk_escalation_offset"("p_risk_level" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."risk_escalation_offset"("p_risk_level" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."risk_escalation_offset"("p_risk_level" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."screen_transactions_for_sanctions"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."screen_transactions_for_sanctions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."screen_transactions_for_sanctions"() TO "service_role";



GRANT ALL ON FUNCTION "public"."severity_from_rank"("p_rank" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."severity_from_rank"("p_rank" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."severity_from_rank"("p_rank" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."severity_rank"("p_severity" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."severity_rank"("p_severity" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."severity_rank"("p_severity" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_customer_risk"("p_customer_id" "uuid", "p_rule_id" "uuid", "p_change_reason" "text", "p_changed_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."update_customer_risk"("p_customer_id" "uuid", "p_rule_id" "uuid", "p_change_reason" "text", "p_changed_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_customer_risk"("p_customer_id" "uuid", "p_rule_id" "uuid", "p_change_reason" "text", "p_changed_by" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_customer_risk_score"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_customer_risk_score"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_customer_risk_score"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_risk_tier"("p_id" "uuid", "p_score" integer, "p_tier" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_risk_tier"("p_id" "uuid", "p_score" integer, "p_tier" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_risk_tier"("p_id" "uuid", "p_score" integer, "p_tier" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_str_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_str_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_str_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_till_balance"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_till_balance"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_till_balance"() TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "service_role";












GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "service_role";















GRANT ALL ON TABLE "public"."accounts" TO "anon";
GRANT ALL ON TABLE "public"."accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."accounts" TO "service_role";



GRANT ALL ON TABLE "public"."alerts" TO "anon";
GRANT ALL ON TABLE "public"."alerts" TO "authenticated";
GRANT ALL ON TABLE "public"."alerts" TO "service_role";



GRANT ALL ON TABLE "public"."aml_rules" TO "anon";
GRANT ALL ON TABLE "public"."aml_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."aml_rules" TO "service_role";



GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."banks" TO "anon";
GRANT ALL ON TABLE "public"."banks" TO "authenticated";
GRANT ALL ON TABLE "public"."banks" TO "service_role";



GRANT ALL ON TABLE "public"."custom_roles" TO "anon";
GRANT ALL ON TABLE "public"."custom_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."custom_roles" TO "service_role";



GRANT ALL ON TABLE "public"."customer_baselines" TO "anon";
GRANT ALL ON TABLE "public"."customer_baselines" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_baselines" TO "service_role";



GRANT ALL ON TABLE "public"."customer_risk_profiles" TO "anon";
GRANT ALL ON TABLE "public"."customer_risk_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_risk_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."customers" TO "anon";
GRANT ALL ON TABLE "public"."customers" TO "authenticated";
GRANT ALL ON TABLE "public"."customers" TO "service_role";



GRANT ALL ON TABLE "public"."loans" TO "anon";
GRANT ALL ON TABLE "public"."loans" TO "authenticated";
GRANT ALL ON TABLE "public"."loans" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."report_archives" TO "anon";
GRANT ALL ON TABLE "public"."report_archives" TO "authenticated";
GRANT ALL ON TABLE "public"."report_archives" TO "service_role";



GRANT ALL ON TABLE "public"."report_schedules" TO "anon";
GRANT ALL ON TABLE "public"."report_schedules" TO "authenticated";
GRANT ALL ON TABLE "public"."report_schedules" TO "service_role";



GRANT ALL ON TABLE "public"."risk_score_history" TO "anon";
GRANT ALL ON TABLE "public"."risk_score_history" TO "authenticated";
GRANT ALL ON TABLE "public"."risk_score_history" TO "service_role";



GRANT ALL ON TABLE "public"."sanctions_watchlist" TO "anon";
GRANT ALL ON TABLE "public"."sanctions_watchlist" TO "authenticated";
GRANT ALL ON TABLE "public"."sanctions_watchlist" TO "service_role";



GRANT ALL ON TABLE "public"."shadow_evaluations" TO "anon";
GRANT ALL ON TABLE "public"."shadow_evaluations" TO "authenticated";
GRANT ALL ON TABLE "public"."shadow_evaluations" TO "service_role";



GRANT ALL ON TABLE "public"."suspicious_transaction_reports" TO "anon";
GRANT ALL ON TABLE "public"."suspicious_transaction_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."suspicious_transaction_reports" TO "service_role";



GRANT ALL ON TABLE "public"."system_events" TO "anon";
GRANT ALL ON TABLE "public"."system_events" TO "authenticated";
GRANT ALL ON TABLE "public"."system_events" TO "service_role";



GRANT ALL ON TABLE "public"."tenants" TO "anon";
GRANT ALL ON TABLE "public"."tenants" TO "authenticated";
GRANT ALL ON TABLE "public"."tenants" TO "service_role";



GRANT ALL ON TABLE "public"."tills" TO "anon";
GRANT ALL ON TABLE "public"."tills" TO "authenticated";
GRANT ALL ON TABLE "public"."tills" TO "service_role";



GRANT ALL ON TABLE "public"."transactions" TO "anon";
GRANT ALL ON TABLE "public"."transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."transactions" TO "service_role";



GRANT ALL ON TABLE "public"."user_profiles" TO "anon";
GRANT ALL ON TABLE "public"."user_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."vault_transfers" TO "anon";
GRANT ALL ON TABLE "public"."vault_transfers" TO "authenticated";
GRANT ALL ON TABLE "public"."vault_transfers" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
































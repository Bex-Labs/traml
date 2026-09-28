-- Phase 2: Alert Factory & Dispatcher Update

-- 1. Create the upgraded create_alert function signature
CREATE OR REPLACE FUNCTION public.create_alert(
    p_customer_id uuid,
    p_transaction_id uuid,
    p_tenant_id text,
    p_rule_name text,
    p_severity text,
    p_details text,
    p_evidence jsonb
) RETURNS void
LANGUAGE plpgsql
SET search_path TO public
AS $$
DECLARE
    v_rule_id UUID;
    v_customer_risk TEXT := 'LOW';
    v_final_severity TEXT;
    v_idempotency_key TEXT;
    v_inserted_id UUID;
BEGIN
    SELECT id INTO v_rule_id FROM public.aml_rules WHERE rule_name = p_rule_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'AML rule "%" not found.', p_rule_name;
    END IF;

    SELECT risk_level INTO v_customer_risk FROM public.customer_risk_profiles WHERE customer_id = p_customer_id;

    v_final_severity := public.calculate_alert_severity(p_severity, COALESCE(v_customer_risk,'LOW'));
    
    -- Cryptographic hash of Transaction + Rule creates a unique fingerprint
    v_idempotency_key := md5(p_transaction_id::text || '_' || p_rule_name);

    INSERT INTO public.alerts (
        alert_ref, customer_id, transaction_id, tenant_id, rule_triggered, severity, status, details, evidence, idempotency_key
    )
    VALUES (
        'ALT-' || UPPER(SUBSTRING(gen_random_uuid()::TEXT,1,6)),
        p_customer_id, p_transaction_id, p_tenant_id, p_rule_name, v_final_severity, 'UNASSIGNED', p_details, p_evidence, v_idempotency_key
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id INTO v_inserted_id;

    -- Only escalate customer risk if this was a new, unique alert (not a duplicate)
    IF v_inserted_id IS NOT NULL THEN
        PERFORM public.update_customer_risk(p_customer_id, v_rule_id, 'AML_ALERT: ' || p_rule_name);
    END IF;
END;
$$;

-- 2. Update the main AML dispatcher to pass the new parameters
CREATE OR REPLACE FUNCTION public.process_aml_rules() RETURNS trigger
LANGUAGE plpgsql
SET search_path TO public
AS $$
DECLARE
    account_record RECORD;
    customer_record RECORD;
    active_rule RECORD;
    alert_text TEXT;
    alert_severity TEXT;
BEGIN
    SELECT * INTO account_record FROM public.accounts WHERE id = NEW.account_id;
    SELECT * INTO customer_record FROM public.customers WHERE id = account_record.customer_id;

    FOR active_rule IN
        SELECT * FROM public.aml_rules
        WHERE tenant_id = customer_record.tenant_id AND status = 'ACTIVE' AND target_entity = 'TRANSACTION'
    LOOP
        alert_text := NULL;
        alert_severity := 'HIGH';

        IF NOT evaluate_rule_metadata(active_rule.rule_metadata, NEW.transaction_type::TEXT, NEW.channel::TEXT, NEW.currency::TEXT) THEN
            CONTINUE;
        END IF;

        CASE active_rule.condition_type
            WHEN 'AMOUNT_ABOVE' THEN
                alert_text := evaluate_amount_above(NEW.amount, active_rule.threshold_value, active_rule.rule_name);
                alert_severity := 'CRITICAL';
            WHEN 'STRUCTURING_PATTERN' THEN
                alert_text := evaluate_structuring(NEW.account_id, NEW.amount, active_rule.threshold_value, active_rule.time_window_hours, active_rule.rule_name);
                alert_severity := 'HIGH';
            WHEN 'VELOCITY_COUNT' THEN
                alert_text := evaluate_velocity_count(NEW.account_id, active_rule.threshold_value, active_rule.time_window_hours, active_rule.rule_name);
                alert_severity := 'MEDIUM';
            WHEN 'DORMANT_ACCOUNT_ACTIVITY' THEN
                alert_text := evaluate_dormant_account_activity(NEW.account_id, NEW.transaction_timestamp, active_rule.threshold_value::INTEGER, active_rule.rule_name);
                alert_severity := 'HIGH';
            ELSE
                NULL;
        END CASE;

        IF alert_text IS NOT NULL THEN
            -- Injecting strict lineage into the alert factory
            PERFORM create_alert(
                customer_record.id,
                NEW.id,
                customer_record.tenant_id,
                active_rule.rule_name,
                alert_severity,
                alert_text,
                jsonb_build_object(
                    'transaction_amount', NEW.amount, 
                    'transaction_type', NEW.transaction_type, 
                    'channel', NEW.channel,
                    'rule_threshold', active_rule.threshold_value
                )
            );
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;

-- 3. Update Massive Outflow trigger
CREATE OR REPLACE FUNCTION public.check_massive_outflow() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer_id UUID;
    v_tenant_id TEXT;
    v_idempotency_key TEXT;
BEGIN
    IF NEW.transaction_type = 'DEBIT' AND NEW.amount > 10000000 THEN
        SELECT customer_id INTO v_customer_id FROM public.accounts WHERE id = NEW.account_id;
        SELECT tenant_id INTO v_tenant_id FROM public.customers WHERE id = v_customer_id;
        
        v_idempotency_key := md5(NEW.id::text || '_Massive Outflow Protocol');
        
        INSERT INTO public.alerts (
            alert_ref, customer_id, transaction_id, tenant_id, rule_triggered, severity, status, details, evidence, idempotency_key
        )
        VALUES (
            'ALT-' || upper(substring(md5(random()::text) from 1 for 6)),
            v_customer_id, NEW.id, v_tenant_id, 'Massive Outflow Protocol', 'CRITICAL', 'UNASSIGNED', 
            'Engine flagged transaction of ₦' || NEW.amount || ' exceeding the strict threshold of ₦10000000 set by rule: Massive Outflow Protocol',
            jsonb_build_object('amount', NEW.amount, 'threshold', 10000000),
            v_idempotency_key
        ) ON CONFLICT (idempotency_key) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

-- 4. Update Behavioral Anomaly trigger
CREATE OR REPLACE FUNCTION public.evaluate_behavioral_anomaly() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    target_customer_id UUID;
    v_tenant_id TEXT;
    baseline RECORD;
    anomaly_threshold DECIMAL;
    v_idempotency_key TEXT;
BEGIN
    SELECT customer_id INTO target_customer_id FROM public.accounts WHERE id = NEW.account_id;
    IF target_customer_id IS NULL THEN RETURN NEW; END IF;
    
    SELECT tenant_id INTO v_tenant_id FROM public.customers WHERE id = target_customer_id;
    SELECT * INTO baseline FROM public.customer_baselines WHERE customer_id = target_customer_id;

    IF FOUND AND baseline.stddev_tx_amount > 0 THEN
        anomaly_threshold := baseline.avg_tx_amount + (3 * baseline.stddev_tx_amount);

        IF NEW.amount > anomaly_threshold THEN
            v_idempotency_key := md5(NEW.id::text || '_Behavioural Velocity Spike (3-Sigma)');
            
            INSERT INTO public.alerts (
                alert_ref, transaction_id, customer_id, tenant_id, rule_triggered, severity, status, details, evidence, idempotency_key
            ) VALUES (
                'ALT-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6)),
                NEW.id, target_customer_id, v_tenant_id, 'Behavioural Velocity Spike (3-Sigma)', 'CRITICAL', 'UNASSIGNED',
                FORMAT('Statistical Anomaly: Transaction amount (₦%s) exceeds the customer''s 30-day historical average (₦%s) by more than 3 standard deviations. This indicates a highly abnormal wealth injection.', NEW.amount, ROUND(baseline.avg_tx_amount, 2)),
                jsonb_build_object('amount', NEW.amount, 'avg_tx_amount', baseline.avg_tx_amount, 'stddev_tx_amount', baseline.stddev_tx_amount),
                v_idempotency_key
            ) ON CONFLICT (idempotency_key) DO NOTHING;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- 5. Update Mule Ring trigger
CREATE OR REPLACE FUNCTION public.evaluate_mule_ring() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    is_layering BOOLEAN;
    target_customer_id UUID;
    v_tenant_id TEXT;
    v_idempotency_key TEXT;
BEGIN
    IF NEW.transaction_type = 'DEBIT' THEN
        is_layering := public.detect_circular_layering(NEW.account_id, 4);
        IF is_layering THEN
            SELECT customer_id INTO target_customer_id FROM public.accounts WHERE id = NEW.account_id;
            SELECT tenant_id INTO v_tenant_id FROM public.customers WHERE id = target_customer_id;
            
            v_idempotency_key := md5(NEW.id::text || '_Circular Layering (Mule Ring Detected)');

            INSERT INTO public.alerts (
                alert_ref, transaction_id, customer_id, tenant_id, rule_triggered, severity, status, details, evidence, idempotency_key
            ) VALUES (
                'ALT-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6)),
                NEW.id, target_customer_id, v_tenant_id, 'Circular Layering (Mule Ring Detected)', 'CRITICAL', 'UNASSIGNED',
                'Graph Analytics Engine: A closed-loop transfer network (circular layering) was detected across 4 or fewer degrees of separation. Funds originating from this account have looped back to it, indicating severe money laundering typologies.',
                jsonb_build_object('max_hops', 4),
                v_idempotency_key
            ) ON CONFLICT (idempotency_key) DO NOTHING;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- 6. Update Sanctions trigger
CREATE OR REPLACE FUNCTION public.screen_transactions_for_sanctions() RETURNS trigger
LANGUAGE plpgsql SET search_path TO public
AS $$
DECLARE
    target_customer_id UUID;
    v_tenant_id TEXT;
    sanction_match TEXT;
    v_idempotency_key TEXT;
BEGIN
    SELECT customer_id INTO target_customer_id FROM public.accounts WHERE id = NEW.account_id;
    SELECT tenant_id INTO v_tenant_id FROM public.customers WHERE id = target_customer_id;

    SELECT entity_name INTO sanction_match 
    FROM public.sanctions_watchlist 
    WHERE NEW.counterparty_name ILIKE '%' || entity_name || '%' 
       OR NEW.narration ILIKE '%' || entity_name || '%'
    LIMIT 1;

    IF sanction_match IS NOT NULL THEN
        v_idempotency_key := md5(NEW.id::text || '_Sanctions / Watchlist Match');
        
        INSERT INTO public.alerts (
            alert_ref, transaction_id, customer_id, tenant_id, rule_triggered, severity, status, details, evidence, idempotency_key
        ) VALUES (
            'SNC-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6)), 
            NEW.id, target_customer_id, v_tenant_id, 'Sanctions / Watchlist Match', 'CRITICAL', 'UNASSIGNED',
            'Direct match found for restricted entity: ' || sanction_match,
            jsonb_build_object('matched_entity', sanction_match, 'counterparty_name', NEW.counterparty_name, 'narration', NEW.narration),
            v_idempotency_key
        ) ON CONFLICT (idempotency_key) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

-- 7. Clean up the obsolete 4-parameter signature
DROP FUNCTION IF EXISTS public.create_alert(uuid, text, text, text);
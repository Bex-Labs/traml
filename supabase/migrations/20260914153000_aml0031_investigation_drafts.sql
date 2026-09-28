-- Phase 4: Durable Investigations & AI Integration

-- 1. Create the secure drafts table
CREATE TABLE IF NOT EXISTS public.investigation_drafts (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id text NOT NULL,
    alert_id uuid NOT NULL REFERENCES public.alerts(id) ON DELETE CASCADE,
    investigator_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    draft_narrative text,
    ai_explanation jsonb DEFAULT '{}'::jsonb,
    evidence_snapshot jsonb DEFAULT '{}'::jsonb,
    status text DEFAULT 'IN_PROGRESS' CHECK (status IN ('IN_PROGRESS', 'SUBMITTED', 'DISCARDED')),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT unique_active_investigation UNIQUE (alert_id, investigator_id)
);

-- 2. Enforce Row Level Security (RLS)
ALTER TABLE public.investigation_drafts ENABLE ROW LEVEL SECURITY;

-- Investigators can only read and update their own assigned drafts
CREATE POLICY "Investigators manage their own drafts" 
    ON public.investigation_drafts 
    FOR ALL TO authenticated 
    USING (auth.uid() = investigator_id)
    WITH CHECK (auth.uid() = investigator_id);

-- Head of Compliance gets read-only oversight for their specific tenant
CREATE POLICY "Compliance Head tenant visibility" 
    ON public.investigation_drafts 
    FOR SELECT TO authenticated 
    USING (
        (auth.jwt() -> 'app_metadata' ->> 'role') = 'head_of_compliance' 
        AND 
        tenant_id = auth.jwt() -> 'app_metadata' ->> 'tenant_id'
    );

-- The backend AI Python worker (service_role) needs full access to inject SHAP explanations
CREATE POLICY "Service Role AI access" 
    ON public.investigation_drafts 
    FOR ALL TO service_role 
    USING (true) 
    WITH CHECK (true);

-- 3. Attach the auto-updating timestamp trigger we established in Phase 1
CREATE TRIGGER trigger_update_investigation_drafts_timestamp
    BEFORE UPDATE ON public.investigation_drafts
    FOR EACH ROW
    EXECUTE FUNCTION public.update_str_timestamp();
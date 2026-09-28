-- Phase 5: Compliance Reporting Storage & Dispatch Logic

-- 1. Create the secure storage bucket for generated PDF reports
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'compliance_reports', 
    'compliance_reports', 
    false, 
    10485760, -- 10MB limit
    ARRAY['application/pdf']::text[]
)
ON CONFLICT (id) DO UPDATE SET 
    public = false,
    allowed_mime_types = ARRAY['application/pdf']::text[];

-- 2. Secure the Storage Bucket with RLS
-- Allow the service_role (Edge Function) to seamlessly upload reports
CREATE POLICY "Service Role manages compliance reports"
    ON storage.objects
    FOR ALL TO service_role
    USING (bucket_id = 'compliance_reports')
    WITH CHECK (bucket_id = 'compliance_reports');

-- Allow Head of Compliance to read only their specific tenant's reports
CREATE POLICY "Compliance Head reads tenant reports"
    ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'compliance_reports' 
        AND (auth.jwt() -> 'app_metadata' ->> 'role') = 'head_of_compliance'
        -- Enforce isolation: storage paths must be formatted as tenant_id/YYYY-MM/report.pdf
        AND (string_to_array(name, '/'))[1] = (auth.jwt() -> 'app_metadata' ->> 'tenant_id')
    );

-- 3. Create an optimized evaluation function for the dispatch-reports Edge Function
CREATE OR REPLACE FUNCTION public.get_due_report_schedules()
RETURNS SETOF public.report_schedules
LANGUAGE sql
SECURITY DEFINER
SET search_path TO public
AS $$
    SELECT * 
    FROM public.report_schedules
    WHERE is_active = true
      AND (
          last_run_at IS NULL 
          OR (frequency = 'DAILY' AND last_run_at <= NOW() - INTERVAL '1 day')
          OR (frequency = 'WEEKLY' AND last_run_at <= NOW() - INTERVAL '1 week')
          OR (frequency = 'MONTHLY' AND last_run_at <= NOW() - INTERVAL '1 month')
      );
$$;
-- Run as the project database administrator after installing the PEP migrations.
-- The hosted project uses GMT for pg_cron, so 05:30 UTC is 06:30 WAT.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM coreaml_private.pep_senate_refresh_runs
        WHERE status='SUCCEEDED' AND finished_at > clock_timestamp()-interval '1 day'
    ) THEN
        RAISE EXCEPTION 'Verify a successful Senate refresh before enabling the schedule';
    END IF;
    PERFORM cron.schedule('coreaml-pep-senate-refresh','30 5 * * *',
        'SELECT coreaml_private.refresh_pep_senate_roster()');
END
$$;

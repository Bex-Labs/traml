DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM coreaml_private.pep_state_house_refresh_runs
        WHERE status='SUCCEEDED' AND finished_at > clock_timestamp()-interval '1 day'
    ) THEN
        RAISE EXCEPTION 'Verify a successful State House refresh before enabling the schedule';
    END IF;
    PERFORM cron.schedule('coreaml-pep-state-house-refresh','45 5 * * *',
        'SELECT coreaml_private.refresh_pep_state_house_roster()');
END
$$;

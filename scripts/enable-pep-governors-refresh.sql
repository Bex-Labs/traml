-- 06:00 UTC is 07:00 WAT.
SELECT cron.schedule('coreaml-pep-governors-refresh','0 6 * * *','SELECT coreaml_private.refresh_pep_governors_roster()');

-- Optional: after enabling pg_cron from Supabase Dashboard > Database > Extensions,
-- execute in SQL Editor. Runs daily at 01:13 UTC.
-- Open deliveries (not yet returned) are retained until the rack returns.
-- Closed deliveries are retained for 30 days AFTER physical return.
select cron.schedule('icph-rack-retention','13 1 * * *', $$
  delete from public.rack_events where occurred_at < now() - interval '30 days';
  delete from public.deliveries where returned_at is not null and returned_at < now() - interval '30 days';
$$);
-- event_corrections are linked to rack_events using ON DELETE CASCADE.
-- Photo storage files are deliberately not automatically deleted by this job.

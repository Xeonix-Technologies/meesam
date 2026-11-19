-- 0043 — A second source to test the fetcher with small files (Founder, 19 Nov 2026), and the console action that
-- switches a fetcher on: "confirm re-use" (MSM-PRD-02 Section 4 re-use gate; Section 9A, Registries page).
--
-- The UK IPO Trade Marks Journal as observed on 19 Nov 2026: a "previous publications" page lists every weekly
-- journal, newest first, one table row each: number (2026-046), date (13 November 2026), then a PDF of about
-- 15 MB and a ZIP of about 20 MB. Published on Fridays. The location is recorded here; the fetcher stays OFF
-- (the re-use gate is ruled) until the watch operations lead confirms re-use in the console.
-- The UK opposition period is unverified, so no window is computed and no deadline is shown: the catalogue
-- says to hold the newest issue only ("take_latest": 1). The registry is not opened to accounts by any of this.
BEGIN;

UPDATE watch.publication_source ps
   SET format = 'pdf',
       fetch_spec = ps.fetch_spec || jsonb_build_object(
         'url', 'https://www.ipo.gov.uk/t-tmj/t-tmj-previous.htm',
         'fetcher', 'page_crawler',
         'link_href', '\.pdf($|\?)',
         'issue_no', '(\d{4}-\d{3})',
         'date', '(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})',
         'context', 'before',
         'container', 'pdf',
         'take_latest', 1,
         'max_per_run', 1,
         'poll_minutes', 180,
         'max_bytes', 209715200,
         'reuse', 'To confirm. The journal is listed on data.gov.uk under the Open Government Licence (record seen 19 Nov 2026, last updated 2014).',
         'observed', '19 Nov 2026: weekly journal, PDF about 15 MB per issue, listed newest first on the previous publications page')
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'GB' AND ps.stream = 'national_bulletin';

INSERT INTO watch.publication_schedule (source_id, frequency, weekday, timezone)
SELECT ps.id, 'weekly', 5, 'Europe/London'
  FROM watch.publication_source ps JOIN registry.registry g ON g.id = ps.registry_id
 WHERE g.code = 'GB' AND ps.stream = 'national_bulletin'
ON CONFLICT (source_id) DO NOTHING;

-- Confirms that storing and re-using a source's publications is permitted, with the basis in words, and switches
-- its fetcher on. Watch operations lead only; audited (trigger on the table); a poll starts at once (0042).
-- A source with no location in its catalogue row cannot be switched on.
CREATE FUNCTION watch.fn_source_confirm_reuse(p_source_id uuid, p_basis text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_basis text := NULLIF(btrim(left(p_basis, 300)), '');
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF v_basis IS NULL THEN RAISE EXCEPTION 'the basis of the confirmation is required' USING ERRCODE = '22023'; END IF;
  UPDATE watch.publication_source
     SET active = true, paused = false, failures = 0, next_poll_at = now(), updated_at = now(),
         fetch_spec = fetch_spec || jsonb_build_object('reuse', v_basis, 'reuse_confirmed_on', current_date,
                        'reuse_confirmed_by', (SELECT u.name FROM core.app_user u WHERE u.id = platform.current_user_id()))
   WHERE id = p_source_id AND NOT active AND fetch_spec ? 'url';
  IF NOT FOUND THEN RAISE EXCEPTION 'no such source that is off and has a location' USING ERRCODE = 'P0002'; END IF;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_source_confirm_reuse(uuid, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_source_confirm_reuse(uuid, text) TO meesam_staff, meesam_admin;

COMMIT;

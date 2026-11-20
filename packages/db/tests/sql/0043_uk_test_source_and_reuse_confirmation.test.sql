-- Tests for migration 0043: the UK source has a location but stays off until the lead confirms re-use.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t43.lead', platform.fn_staff_invite('lead@x43.test', 'Lead Person', 'watch_lead')::text, false);
SELECT set_config('t43.rev', platform.fn_staff_invite('rev@x43.test', 'Rev', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x43.test', 'rev@x43.test');
CREATE TEMP TABLE _s AS SELECT s.id, g.code FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code IN ('GB', 'SA') AND s.stream = 'national_bulletin';
GRANT SELECT ON _s TO PUBLIC;
DELETE FROM platform.job WHERE kind = 'watch.fetch';
DO $$ BEGIN
  ASSERT (SELECT NOT active AND fetch_spec ->> 'fetcher' = 'pattern' AND fetch_spec ->> 'start_issue' = '2026-046' FROM watch.publication_source WHERE id = (SELECT id FROM _s WHERE code = 'GB')), 'the UK row has its location and is still off';
  ASSERT NOT (SELECT supported FROM registry.registry WHERE code = 'GB'), 'the UK registry is not open to accounts';
  ASSERT (SELECT NOT active AND fetch_spec ? 'url' AND (fetch_spec ->> 'take_latest')::int = 1 FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'BH'), 'Bahrain (0044) has a location and is off';
  ASSERT (SELECT active AND fetch_spec ->> 'link_href' LIKE '%_OG%' AND (fetch_spec ->> 'take_latest')::int = 1 FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'US'), 'the US gazette (0051) has its location; the newest issue only';
END $$;
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_fetch_due() WHERE registry_code = 'GB'), 'off means not polled'; END $$;
RESET ROLE;

SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t43.rev'), true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM watch.fn_source_confirm_reuse((SELECT id FROM _s WHERE code = 'GB'), 'OGL'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a reviewer cannot confirm re-use';
END $$;
SELECT set_config('meesam.user_id', current_setting('t43.lead'), true);
DO $$ DECLARE refused integer := 0; BEGIN
  BEGIN PERFORM watch.fn_source_confirm_reuse((SELECT id FROM _s WHERE code = 'GB'), '  '); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_source_confirm_reuse((SELECT id FROM _s WHERE code = 'SA'), 'ok'); EXCEPTION WHEN no_data_found THEN refused := refused + 1; END;
  ASSERT refused = 2, 'a basis is required, and a source with no location cannot be switched on';
  PERFORM watch.fn_source_confirm_reuse((SELECT id FROM _s WHERE code = 'GB'), 'Open Government Licence v3.0, IPO terms read 19 Nov 2026');
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT active AND fetch_spec ->> 'reuse' LIKE 'Open Government%' AND fetch_spec ->> 'reuse_confirmed_by' = 'Lead Person' FROM watch.publication_source WHERE id = (SELECT id FROM _s WHERE code = 'GB')), 'on, with the basis and who confirmed it';
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.fetch' AND status = 'queued') = 1, 'a poll starts at once';
  ASSERT (SELECT count(*) FROM platform.audit_event WHERE schema_name = 'watch' AND table_name = 'publication_source' AND user_id = current_setting('t43.lead')::uuid) = 1, 'audited to the person';
  ASSERT NOT (SELECT supported FROM registry.registry WHERE code = 'GB'), 'still not open to accounts';
END $$;
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN
  ASSERT (SELECT fetch_spec ->> 'pattern' FROM watch.fn_fetch_due() WHERE registry_code = 'GB') LIKE '%{issue}/jnl.pdf', 'now polled, by its numbered address';
  ASSERT (SELECT days FROM watch.fn_source_window(source_id)) IS NULL FROM watch.fn_fetch_due() WHERE registry_code = 'GB';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0043 TESTS PASSED

-- Tests for migration 0099: Egypt's gazette carries its reading settings; nothing is accepted without a person.
BEGIN;
SET client_min_messages = warning;
DO $$ DECLARE r jsonb := (SELECT s.fetch_spec -> 'read' FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'EG' AND s.stream = 'national_bulletin'); BEGIN
  ASSERT r ->> 'method' = 'labels' AND r ->> 'prepare' = 'arabic_order', 'read by its labels, after the letters are put in order';
  ASSERT r #>> '{forms,0,layout}' = 'centred' AND r #>> '{forms,0,kind}' = 'marks', 'one form of marks, its labels beside the middle of their values';
  ASSERT NOT (r ? 'accept'), 'every Egyptian mark waits for a person';
  ASSERT r #> '{picture,not}' = '[[1600, 1383]]'::jsonb, 'the watermark is not a mark''s picture';
  ASSERT (SELECT bool_or(l ->> 'field' = 'conditions' AND (l ->> 'top')::boolean) FROM jsonb_array_elements(r #> '{forms,0,labels}') l), 'the conditions label stands on the first line of its value';
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r #> '{forms,0,labels}') l WHERE l ->> 'field' = 'mark'), 'no wording is printed, so none is expected';
END $$;
ROLLBACK;
\echo ALL 0099 TESTS PASSED

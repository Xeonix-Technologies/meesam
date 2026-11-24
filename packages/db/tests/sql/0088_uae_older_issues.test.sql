-- Tests for migration 0088: the UAE settings also know the older Madrid title and the cancellations part.
BEGIN;
SET client_min_messages = warning;
DO $$ DECLARE r jsonb; m jsonb; c jsonb; BEGIN
  SELECT s.fetch_spec -> 'read' INTO r FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin';
  ASSERT jsonb_array_length(r -> 'forms') = 11, 'eleven forms now: ' || jsonb_array_length(r -> 'forms');
  SELECT f INTO m FROM jsonb_array_elements(r -> 'forms') f WHERE f ->> 'key' = 'madrid';
  ASSERT 'TheTrademarksDepartment' ~ (m ->> 'title') AND 'TheTrademarksandIntellectualWorksDepartment' ~ (m ->> 'title'), 'both openings of the Madrid form are told';
  ASSERT m ->> 'start' = 'The Trademarks' AND m ->> 'number_prefix' = 'IR ' AND m ->> 'kind' = 'marks', 'the rest of the Madrid form is as it was';
  SELECT f INTO c FROM jsonb_array_elements(r -> 'forms') f WHERE f ->> 'key' = 'cancellation';
  ASSERT c ->> 'like' = 'change_of_mark' AND c ->> 'kind' = 'notices', 'cancellations are notices on the form of the changes';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(r -> 'forms') f, jsonb_array_elements(f -> 'labels') l WHERE f ->> 'key' = 'change_of_mark' AND l ->> 'label' LIKE '%شطب%') = 3, 'the three labels of a cancellation';
  ASSERT (SELECT f ->> 'key' FROM jsonb_array_elements(r -> 'forms') WITH ORDINALITY AS x(f, o) ORDER BY o LIMIT 1) = 'accepted', 'the order of the forms is kept';
  ASSERT NOT (r ? 'accept') AND r ->> 'method' = 'labels', 'nothing else changed';
END $$;
ROLLBACK;
\echo ALL 0088 TESTS PASSED

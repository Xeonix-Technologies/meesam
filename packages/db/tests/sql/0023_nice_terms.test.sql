-- Tests for migration 0023: the Nice list is loaded with its two versions and changes over on 1 January 2027.
BEGIN;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM registry.nice_term WHERE in_force_from <= DATE '2026-12-31' AND (in_force_until IS NULL OR DATE '2026-12-31' < in_force_until)) = 10123, 'NCL(13-2026): 10,123 terms';
  ASSERT (SELECT count(*) FROM registry.nice_term WHERE in_force_from <= DATE '2027-01-01' AND (in_force_until IS NULL OR DATE '2027-01-01' < in_force_until)) = 10227, 'NCL(13-2027): 10,227 terms';
  ASSERT (SELECT count(DISTINCT c.number) FROM registry.nice_term t JOIN registry.nice_class c ON c.id = t.class_id) = 45, 'all 45 classes have terms';
  ASSERT (SELECT term ->> 'en' FROM registry.fn_nice_terms(1::smallint, DATE '2026-12-01') WHERE basic_number = '010002') = 'adhesives for industrial purposes', 'a term by basic number';
  ASSERT (SELECT count(*) FROM registry.fn_nice_terms(1::smallint, DATE '2026-12-01') WHERE basic_number = '010269') = 1, 'a term deleted in 2027 is in force in 2026';
  ASSERT (SELECT count(*) FROM registry.fn_nice_terms(1::smallint, DATE '2027-01-01') WHERE basic_number = '010269') = 0, 'and gone from 1 January 2027';
  ASSERT (SELECT count(*) FROM registry.fn_nice_terms(1::smallint, DATE '2026-12-01') WHERE basic_number = '010751') = 0, 'a term added in 2027 is not offered in 2026';
  ASSERT (SELECT count(*) FROM registry.fn_nice_terms(1::smallint, DATE '2027-01-01') WHERE basic_number = '010751') = 1, 'and is from 1 January 2027';
  ASSERT (SELECT count(*) FROM (SELECT basic_number FROM registry.nice_term WHERE in_force_from <= current_date AND (in_force_until IS NULL OR current_date < in_force_until) GROUP BY 1 HAVING count(*) > 1) x) = 0, 'one wording per basic number at a time';
END $$;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN ASSERT (SELECT count(*) FROM registry.fn_nice_terms(35::smallint)) > 100, 'the app role reads the list'; END $$;
RESET ROLE;
SELECT 'ALL 0023 TESTS PASSED' AS result;
ROLLBACK;

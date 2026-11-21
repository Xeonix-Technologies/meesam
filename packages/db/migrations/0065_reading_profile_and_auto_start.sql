-- 0065 — Reading tests start at the first page of entries, and the reader is told how a registry lays out its
-- bulletin (staging, 21 Nov 2026: the first Qatar test read two index pages, so it showed no owners or agents).
-- How a registry lays out its bulletin is data, like its fetch location: fetch_spec.read carries a pattern that
-- recognises a page of entries and a few sentences of layout notes for the reader. Qatar is entered from its
-- issue No. 351 (A) of 17 Sep 2026, supplied by the Founder: cover, a ten-page index (number, class, page,
-- picture), then one entry per mark, each page headed by the class, the application number in brackets and the
-- issue; long lists of goods run over following pages under the same heading.
BEGIN;

ALTER TABLE watch.read_test ADD COLUMN auto_start boolean NOT NULL DEFAULT false;   -- first page left for Meesam to find

CREATE OR REPLACE FUNCTION watch.fn_read_test_request(p_issue_id uuid, p_first_page integer, p_pages integer, p_model text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_id uuid; v_model text := NULLIF(btrim(left(p_model, 80)), '');
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF v_model IS NULL OR v_model !~ '^[a-z0-9.-]+$' THEN RAISE EXCEPTION 'a model is required' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM watch.publication_issue i WHERE i.id = p_issue_id AND i.object_key IS NOT NULL) THEN
    RAISE EXCEPTION 'no such stored issue' USING ERRCODE = 'P0002';
  END IF;
  IF EXISTS (SELECT 1 FROM watch.publication_issue i JOIN watch.publication_source s ON s.id = i.source_id
              JOIN watch.reuse_register r ON r.registry_id = s.registry_id WHERE i.id = p_issue_id AND r.may_store IS FALSE) THEN
    RAISE EXCEPTION 'the re-use register does not allow processing this registry''s publications' USING ERRCODE = '42501';
  END IF;
  IF (SELECT count(*) FROM watch.read_test WHERE created_at > now() - interval '1 hour') >= 30 THEN
    RAISE EXCEPTION 'too many reading tests in the last hour' USING ERRCODE = '54000';
  END IF;
  -- no first page given (or zero): Meesam finds the first page of entries itself
  INSERT INTO watch.read_test (issue_id, first_page, pages, model, requested_by, auto_start)
  VALUES (p_issue_id, greatest(1, COALESCE(p_first_page, 1)), least(5, greatest(1, p_pages)), v_model, platform.current_user_id(),
          COALESCE(p_first_page, 0) < 1)
  RETURNING id INTO v_id;
  PERFORM platform.enqueue_job('watch.read_test', jsonb_build_object('id', v_id), now(), 'watch.read_test:' || v_id);
  RETURN v_id;
END $$;

UPDATE watch.publication_source s
   SET fetch_spec = s.fetch_spec || jsonb_build_object('read', jsonb_build_object(
         'entry_marker', 'طالب التسجيل|قدم عنها الطلب رقم',
         'observed', 'Issue No. 351 (A), 17 Sep 2026',
         'notes', 'Layout of this gazette (Qatar, Industrial Property Gazette, First Section: Trademarks). After the cover come index pages headed "الفهرس": rows of mark number, class and page only; they are not entries. Then one entry per mark. Every entry page carries a heading with the Nice class inside a gear ("فئة المنتجات"), the application number in square brackets, and the issue number and date. An entry begins with the picture of the mark, then "قدم عنها الطلب رقم <number> بتاريخ <dd/mm/yyyy>" (application number and filing date), then "الفئة <n>:" followed by the goods or services, then "طالب التسجيل:" (the applicant), "مركزها العام:" (the applicant''s address, whose last part is the country), and under "عنوان المراسلة" the name of the agent. A long list of goods runs over the following pages, which repeat the same heading and number: these pages belong to the same single entry. The page number is printed at the foot of the page.'))
  FROM registry.registry g
 WHERE g.id = s.registry_id AND g.code = 'QA' AND s.stream = 'national_bulletin';

COMMIT;

-- 0077 — Feedback from signed-in users (Founder ruling R11, 21 Nov 2026: "Feedback to a form for signed-in users").
-- The table exists since 0001. Added here: a closed way to write it (length checked, the account and user taken
-- from the session, never from the form) and staff reading in Meesam System Admin. Feedback is read by staff only.
BEGIN;

CREATE FUNCTION platform.fn_feedback_add(p_body text, p_page text, p_locale text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
DECLARE v uuid; b text := btrim(COALESCE(p_body, ''));
BEGIN
  IF platform.current_account_id() IS NULL OR platform.current_user_id() IS NULL THEN RAISE EXCEPTION 'not signed in' USING ERRCODE = '42501'; END IF;
  IF char_length(b) < 5 OR char_length(b) > 4000 THEN RAISE EXCEPTION 'feedback is between 5 and 4000 characters' USING ERRCODE = '22023'; END IF;
  INSERT INTO platform.feedback (account_id, user_id, page, body, locale)
  VALUES (platform.current_account_id(), platform.current_user_id(), NULLIF(left(btrim(COALESCE(p_page, '')), 200), ''), b, NULLIF(left(COALESCE(p_locale, ''), 5), ''))
  RETURNING id INTO v;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION platform.fn_feedback_add(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.fn_feedback_add(text, text, text) TO meesam_app;

CREATE POLICY feedback_staff_read ON platform.feedback FOR SELECT TO meesam_staff, meesam_admin USING (true);
GRANT SELECT ON platform.feedback TO meesam_staff, meesam_admin;

COMMIT;

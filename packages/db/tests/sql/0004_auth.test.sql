-- Tests for migration 0004: sign-up → e-mail verification → review → session.
BEGIN;
SET client_min_messages = warning;

SET LOCAL ROLE meesam_app;   -- the web app has no account context at sign-up
DO $$ DECLARE r record; v_user uuid; tok bytea := digest('t1', 'sha256'); s record; BEGIN
  SELECT * INTO r FROM core.sp_register_account('{
    "kind": "agency_office", "name": {"en": "Alpha IP", "ar": "ألفا"}, "country": "AE", "city": "Dubai",
    "contact": {"mobile": "+9715"}, "languages_served": ["ar", "en"],
    "user": {"email": "Admin@Alpha.test", "name": "A. Admin", "locale": "ar", "password_hash": "scrypt$x"},
    "licences": [{"registry_code": "AE", "licence_ref": "TM-AG-1"}]}'::jsonb);
  ASSERT r.account_id IS NOT NULL AND r.user_id IS NOT NULL, 'registered';
  -- duplicate e-mail refused, case-insensitively
  BEGIN
    PERFORM core.sp_register_account('{"kind": "owner_individual", "name": {"en": "X"}, "country": "AE", "user": {"email": "admin@alpha.test", "name": "x", "password_hash": "h"}}'::jsonb);
    RAISE EXCEPTION 'duplicate e-mail must be refused';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  -- cannot log in before e-mail verification
  SELECT * INTO s FROM core.fn_user_for_login('admin@alpha.test');
  ASSERT s.user_status = 'invited' AND s.verification_status = 'pending_email', 'pending e-mail';
  PERFORM core.sp_issue_token(r.user_id, 'email_verify', tok);
  v_user := core.sp_consume_token(tok, 'email_verify');
  ASSERT v_user = r.user_id, 'token consumed';
  ASSERT core.sp_consume_token(tok, 'email_verify') IS NULL, 'token is single use';
  SELECT * INTO s FROM core.fn_user_for_login('admin@alpha.test');
  ASSERT s.user_status = 'active' AND s.verification_status = 'pending_review', 'now under Meesam review';
  -- a session can exist while under review (the user sees only the verification status page)
  PERFORM core.sp_session_create(r.user_id, digest('s1', 'sha256'), interval '30 days', '10.0.0.1'::inet, 'test');
  SELECT * INTO s FROM core.fn_session(digest('s1', 'sha256'));
  ASSERT s.user_id = r.user_id AND s.verification_status = 'pending_review' AND s.locale = 'ar', 'session resolves';
  PERFORM core.sp_login_attempt('admin@alpha.test', false, NULL, NULL);
  PERFORM core.sp_login_attempt('admin@alpha.test', false, NULL, NULL);
  ASSERT core.fn_recent_failures('admin@alpha.test') = 2, 'failures counted';
  -- the app role cannot read sessions or tokens directly
  BEGIN
    PERFORM count(*) FROM core.session;
    RAISE EXCEPTION 'app must not read sessions';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  -- directory listing stays off until verified (0001 check constraint), even for the account itself
  PERFORM set_config('meesam.account_id', r.account_id::text, true);
  BEGIN
    UPDATE core.account SET directory_listed = true WHERE id = r.account_id;
    RAISE EXCEPTION 'listing before verification must fail';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
RESET ROLE;

-- staff review approves; users notified in-app and by e-mail; licence verified; listing now possible
DO $$ DECLARE a core.account; BEGIN
  SELECT * INTO a FROM core.account WHERE name ->> 'en' = 'Alpha IP';
  CALL core.sp_review_account(a.id, true, 'staff', NULL, 'licence checked');
  SELECT * INTO a FROM core.account WHERE id = a.id;
  ASSERT a.verification_status = 'verified' AND a.verified_at IS NOT NULL AND a.verification_method = 'staff', 'verified';
  ASSERT (SELECT count(*) FROM platform.notification WHERE account_id = a.id AND kind = 'account_verified') = 2, 'in-app + e-mail notification';
  ASSERT (SELECT verified_at FROM core.agency_licence WHERE account_id = a.id) IS NOT NULL, 'licence verified';
  UPDATE core.account SET directory_listed = true WHERE id = a.id;
  -- revoking the session ends it
  PERFORM core.sp_session_revoke(digest('s1', 'sha256'));
  ASSERT NOT EXISTS (SELECT 1 FROM core.fn_session(digest('s1', 'sha256'))), 'revoked session gone';
END $$;

SELECT 'ALL 0004 TESTS PASSED' AS result;
ROLLBACK;

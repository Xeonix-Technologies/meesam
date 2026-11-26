-- 0096 — Publications received by e-mail (Founder, 26 Nov 2026: a trial on staging before he rules).
--
-- Some registries' sites are closed to requests from outside their country. The Founder will have those
-- publications sent to a Meesam mailbox. A file that arrives there is NOT a publication yet: it waits here, and
-- the watch operations lead adds it to a source that is switched to "collected by hand" (0047), where it passes
-- the same checks as any file added by hand, or discards it. Nothing is read, matched or alerted from a waiting
-- file. The web service receives the mail only where its key is set (INBOUND_MAIL_KEY), and only from the senders
-- named in its configuration.
BEGIN;

CREATE TABLE watch.mail_intake (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  received_at timestamptz NOT NULL DEFAULT now(),
  sender      text NOT NULL,
  subject     text NULL,
  file_name   text NOT NULL,
  bytes       bigint NOT NULL CHECK (bytes > 0),
  sha256      bytea NOT NULL,
  object_key  text NOT NULL UNIQUE,
  state       text NOT NULL DEFAULT 'waiting' CHECK (state IN ('waiting', 'added', 'discarded')),
  decided_by  uuid NULL REFERENCES core.app_user(id),
  decided_at  timestamptz NULL,
  added_as    text NULL
);
CREATE UNIQUE INDEX mail_intake_one_waiting ON watch.mail_intake (sha256) WHERE state = 'waiting';
CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON watch.mail_intake
  FOR EACH ROW WHEN (platform.current_user_id() IS NOT NULL) EXECUTE FUNCTION platform.trg_audit_row();
REVOKE ALL ON watch.mail_intake FROM PUBLIC, meesam_app;
GRANT SELECT ON watch.mail_intake TO meesam_staff, meesam_admin;

-- A file has arrived by e-mail. Called by the web service, which has checked its key and the sender. The same
-- file still waiting is not entered twice; the answer says whether a row was made.
CREATE FUNCTION watch.fn_mail_intake_receive(p_sender text, p_subject text, p_file_name text, p_bytes bigint, p_sha256 bytea, p_object_key text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
BEGIN
  IF NULLIF(btrim(p_sender), '') IS NULL OR NULLIF(btrim(p_file_name), '') IS NULL OR p_object_key !~ '^_mail/' THEN
    RAISE EXCEPTION 'sender, file name and a key under _mail/ are required' USING ERRCODE = '22023';
  END IF;
  INSERT INTO watch.mail_intake (sender, subject, file_name, bytes, sha256, object_key)
  VALUES (left(btrim(p_sender), 200), NULLIF(left(btrim(p_subject), 300), ''), left(btrim(p_file_name), 200), p_bytes, p_sha256, p_object_key)
  ON CONFLICT DO NOTHING;
  RETURN FOUND;
END $$;

-- The lead's decision on a waiting file: added (to which source and issue, as text) or discarded.
CREATE FUNCTION watch.fn_mail_intake_decide(p_id uuid, p_state text, p_added_as text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF p_state NOT IN ('added', 'discarded') THEN RAISE EXCEPTION 'added or discarded' USING ERRCODE = '22023'; END IF;
  UPDATE watch.mail_intake SET state = p_state, decided_by = platform.current_user_id(), decided_at = now(),
         added_as = CASE WHEN p_state = 'added' THEN left(p_added_as, 200) END
   WHERE id = p_id AND state = 'waiting';
  IF NOT FOUND THEN RAISE EXCEPTION 'no such waiting file' USING ERRCODE = 'P0002'; END IF;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_mail_intake_receive(text, text, text, bigint, bytea, text) FROM PUBLIC, meesam_app, meesam_staff;
REVOKE EXECUTE ON FUNCTION watch.fn_mail_intake_decide(uuid, text, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_mail_intake_receive(text, text, text, bigint, bytea, text) TO meesam_admin;
GRANT EXECUTE ON FUNCTION watch.fn_mail_intake_decide(uuid, text, text) TO meesam_staff;

COMMIT;

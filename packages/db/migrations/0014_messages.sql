-- 0014 — Per-record message thread between the owner and the holding agency (item 39 (vi): text only,
-- each message a timeline entry; one thread per record per owner–agency pair).
--
-- Closes the write path: 0001 let either party insert, edit and delete messages and threads directly.
-- From here the app role only reads; posting goes through fn_message_post, which works out the pair from
-- the record's owner and its holding agency. An agency reads a thread only while it still has access to
-- the record (item 38: nothing after the appointment ends); the owner keeps the whole history.
BEGIN;

ALTER TABLE core.message_thread ADD COLUMN IF NOT EXISTS owner_read_at timestamptz NULL;
ALTER TABLE core.message_thread ADD COLUMN IF NOT EXISTS agency_read_at timestamptz NULL;
-- the author's name as it was when the message was written: the other side cannot read this account's users
ALTER TABLE core.message ADD COLUMN IF NOT EXISTS author_name text NULL;

DROP POLICY IF EXISTS thread_all ON core.message_thread;
DROP POLICY IF EXISTS message_all ON core.message;
CREATE POLICY thread_select ON core.message_thread FOR SELECT TO meesam_app USING (
  owner_account_id = platform.current_account_id()
  OR (agency_account_id = platform.current_account_id() AND core.fn_can_access(record_id, platform.current_account_id())));
CREATE POLICY message_select ON core.message FOR SELECT TO meesam_app
  USING (EXISTS (SELECT 1 FROM core.message_thread t WHERE t.id = thread_id));
REVOKE INSERT, UPDATE, DELETE ON core.message_thread, core.message FROM meesam_app;

-- The agencies holding a record now (accepted appointment, record in scope).
CREATE FUNCTION core.fn_holding_agencies(p_record_id uuid) RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT DISTINCT a.agency_account_id FROM core.appointment a JOIN core.appointment_record ar ON ar.appointment_id = a.id
   WHERE ar.record_id = p_record_id AND ar.removed_at IS NULL AND a.status = 'accepted' AND a.ended_at IS NULL
$$;
REVOKE EXECUTE ON FUNCTION core.fn_holding_agencies(uuid) FROM PUBLIC, meesam_app;

-- Posts a message on a record's thread. The caller is the owner of the mark or an agency holding the record;
-- an owner with more than one holding agency names the agency. A Viewer does not post.
CREATE FUNCTION core.fn_message_post(p_record_id uuid, p_body text, p_agency uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); u core.app_user; v_owner uuid; v_agency uuid; v_thread uuid; v_id uuid; v_body text := btrim(COALESCE(p_body, ''));
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = me;
  IF u.id IS NULL OR u.status <> 'active' OR u.role = 'viewer' THEN RAISE EXCEPTION 'this user does not post messages' USING ERRCODE = '42501'; END IF;
  IF v_body = '' THEN RAISE EXCEPTION 'empty message' USING ERRCODE = '22023'; END IF;
  SELECT f.owner_account_id INTO v_owner FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id WHERE r.id = p_record_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'no such record' USING ERRCODE = '22023'; END IF;
  IF me = v_owner THEN
    IF p_agency IS NOT NULL THEN
      SELECT x INTO v_agency FROM core.fn_holding_agencies(p_record_id) x WHERE x = p_agency;
    ELSIF (SELECT count(*) FROM core.fn_holding_agencies(p_record_id)) = 1 THEN
      SELECT x INTO v_agency FROM core.fn_holding_agencies(p_record_id) x;
    END IF;
  ELSE
    SELECT x INTO v_agency FROM core.fn_holding_agencies(p_record_id) x WHERE x = me;
    IF v_agency IS NULL THEN RAISE EXCEPTION 'not a party to this record' USING ERRCODE = '42501'; END IF;
  END IF;
  IF v_agency IS NULL THEN RAISE EXCEPTION 'no holding agency to write to' USING ERRCODE = '22023'; END IF;

  INSERT INTO core.message_thread (record_id, owner_account_id, agency_account_id) VALUES (p_record_id, v_owner, v_agency)
  ON CONFLICT (record_id, owner_account_id, agency_account_id) DO UPDATE SET updated_at = now() RETURNING id INTO v_thread;
  INSERT INTO core.message (thread_id, author_user_id, author_account_id, author_name, body) VALUES (v_thread, u.id, me, u.name, left(v_body, 4000)) RETURNING id INTO v_id;
  UPDATE core.message_thread SET owner_read_at = CASE WHEN me = v_owner THEN now() ELSE owner_read_at END,
                                 agency_read_at = CASE WHEN me = v_agency THEN now() ELSE agency_read_at END WHERE id = v_thread;
  INSERT INTO platform.notification (account_id, channel, kind, record_id, payload)
  VALUES (CASE WHEN me = v_owner THEN v_agency ELSE v_owner END, 'in_app', 'message_new', p_record_id, jsonb_build_object('message_id', v_id, 'from', u.name));
  RETURN v_id;
END $$;

-- The caller has read the record's thread(s) up to now.
CREATE FUNCTION core.fn_thread_mark_read(p_record_id uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  UPDATE core.message_thread SET owner_read_at = now() WHERE record_id = p_record_id AND owner_account_id = platform.current_account_id();
  UPDATE core.message_thread SET agency_read_at = now() WHERE record_id = p_record_id AND agency_account_id = platform.current_account_id()
     AND core.fn_can_access(record_id, platform.current_account_id());
$$;

-- Who is told by e-mail about a message: the other side's active users, not Viewers. Only the author's account may ask.
CREATE FUNCTION core.fn_message_recipients(p_message_id uuid)
RETURNS TABLE (email citext, name text, locale text, account_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); m core.message; t core.message_thread; v_other uuid;
BEGIN
  SELECT * INTO m FROM core.message WHERE id = p_message_id;
  IF m.id IS NULL OR me IS NULL OR m.author_account_id <> me THEN RAISE EXCEPTION 'not the author of this message' USING ERRCODE = '42501'; END IF;
  SELECT * INTO t FROM core.message_thread WHERE id = m.thread_id;
  v_other := CASE WHEN me = t.owner_account_id THEN t.agency_account_id ELSE t.owner_account_id END;
  RETURN QUERY SELECT u.email, u.name, u.locale, u.account_id FROM core.app_user u
                WHERE u.account_id = v_other AND u.status = 'active' AND u.role <> 'viewer';
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_message_post(uuid, text, uuid), core.fn_thread_mark_read(uuid), core.fn_message_recipients(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_message_post(uuid, text, uuid), core.fn_thread_mark_read(uuid), core.fn_message_recipients(uuid) TO meesam_app;

COMMIT;

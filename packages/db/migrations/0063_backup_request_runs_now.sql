-- 0063 — "Copy now" really runs now (staging, 21 Nov 2026).
-- A copy that failed was kept in the queue for a later retry (1, 2, 4, 8… minutes), and a new request was then
-- silently merged into that waiting retry, so pressing "Copy now" after a failure did nothing for minutes.
-- A request now takes over a waiting copy job and runs it at once; the worker no longer leaves a failed copy in
-- the queue for retry (the failure is on record in platform.backup_run and the nightly check tries again).
BEGIN;

CREATE OR REPLACE FUNCTION platform.fn_backup_request(p_restore_test boolean DEFAULT false) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, public, pg_temp AS $$
DECLARE v_id uuid;
        v_payload jsonb := jsonb_build_object('requested', true, 'restore_test', p_restore_test, 'by', platform.current_user_id());
BEGIN
  IF NOT EXISTS (SELECT 1 FROM platform.staff_role r WHERE r.user_id = platform.current_user_id() AND r.role = 'system_admin') THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM platform.backup_run b WHERE b.ok IS NULL AND b.started_at > now() - interval '2 hours')
     OR EXISTS (SELECT 1 FROM platform.job j WHERE j.kind = 'platform.backup' AND j.status = 'running') THEN
    RAISE EXCEPTION 'a copy is already being made' USING ERRCODE = '55006';
  END IF;
  -- a copy job already waiting (a retry, or the half-hourly check) is taken over and run now
  UPDATE platform.job SET payload = v_payload, run_at = now(), attempts = 0, last_error = NULL, updated_at = now()
   WHERE kind = 'platform.backup' AND status = 'queued'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    v_id := platform.enqueue_job('platform.backup', v_payload, now(), 'platform.backup');
  END IF;
  RETURN v_id;
END $$;

COMMIT;

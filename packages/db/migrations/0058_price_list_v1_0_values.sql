-- 0058 — Price List v1.0 (Founder, 21 Nov 2026), part 1: the two new values the list needs.
-- A new mark now pays a filing fee (case 4 of the list), so payments get the case 'filing' and a record gets
-- the state 'filing_paid' (filing fee paid; reminders run, no watch yet). New enum values cannot be used in the
-- transaction that adds them, so they stand alone here and 0059 carries the rest.
BEGIN;
ALTER TYPE core.payment_case ADD VALUE IF NOT EXISTS 'filing';
ALTER TYPE core.paid_state ADD VALUE IF NOT EXISTS 'filing_paid' AFTER 'free_new_pending';
COMMIT;

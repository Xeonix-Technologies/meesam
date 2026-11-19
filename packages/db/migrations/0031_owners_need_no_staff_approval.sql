-- 0031 — Owners need no staff approval (Founder ruling 19 Nov 2026).
-- An owner account (individual or company) is verified when its e-mail address is confirmed. Staff approval
-- remains for agency offices only. An owner invited by an agency is still recorded as verified by that
-- invitation (0028: method 'agency_invite', with the notice to the staff); every other owner gets method 'email'.
-- An owner account that staff rejected earlier is left as it is: only the step from "e-mail not yet confirmed"
-- verifies, so correcting details after a rejection still goes to staff.
BEGIN;

CREATE FUNCTION core.trg_owner_self_verifies() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN
  UPDATE core.account SET verification_status = 'verified', verified_at = now(), verification_method = 'email',
         review_note = 'Owner account: verified on confirming the e-mail address'
   WHERE id = NEW.id AND verified_at IS NULL AND verification_status = 'pending_review'
     AND kind <> 'agency_office' AND NOT is_staff;
  RETURN NULL;
END $$;
-- named to run after account_invite_verifies (0028) on the same event, so an invited owner keeps that record
CREATE TRIGGER account_owner_self_verifies AFTER UPDATE OF verification_status ON core.account
  FOR EACH ROW WHEN (NEW.verification_status = 'pending_review' AND OLD.verification_status = 'pending_email')
  EXECUTE FUNCTION core.trg_owner_self_verifies();

-- owners already waiting for a first review (never reviewed by staff) are verified now
UPDATE core.account SET verification_status = 'verified', verified_at = now(), verification_method = 'email',
       review_note = 'Owner account: verified under the ruling of 19 Nov 2026 (no staff approval for owners)'
 WHERE verified_at IS NULL AND verification_status = 'pending_review' AND kind <> 'agency_office' AND NOT is_staff
   AND reviewed_by_user_id IS NULL;

COMMIT;

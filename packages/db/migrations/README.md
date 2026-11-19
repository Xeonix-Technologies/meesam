# Migrations

Plain SQL, written and reviewed by hand (CLAUDE.md: never regenerated destructively). Applied in
file-name order by `packages/db/src/migrate.ts`, which records each file's SHA-256 in
`platform.schema_migration`; an applied file must never change — add a new one.

| File | Content |
|---|---|
| `0001_core.sql` | Schemas, roles, every table of Data Architecture v0.2 Sections 5–10, access view and RLS, lifecycle/timer functions, pricing, procedures, normaliser, job queue, registry seed |
| `0002_pgvector.sql` | Image embedding columns (DINOv3 768-d, SigLIP 2 768-d), HNSW indexes, `core.record_image` — needs pgvector |
| `0005_records.sql` | Intake drafts, vault key function (item 43), historical-clock closing, next-dates view, draft sweep |
| `0006_record_select_owner.sql` | Record SELECT policy recognises the family owner directly, so `INSERT … RETURNING` on `core.record` works under RLS (intake commit). |
| `0007_account_logo.sql` | `core.account.logo_key` (vault key of the account logo) and `fn_session` returning it. |
| `0008_certificate_reflow.sql` | `fn_correct_certificate` (certificate corrections move the filed/registered event dates and re-flow the clocks) and `fn_timers_for_event` honouring the certificate's own expiry. |
| `0009_filing_request.sql` | `core.record.filing_request` — the Section 6 request as accepted, kept on the pre-filing record. |
| `0009_staff_roles.sql` | `platform.staff_role` (system_admin, watch_lead, publication_reviewer), grant/revoke procedures, `v_admin_account` for the verification review. |
| `0010_appointments.sql` | Appointments: closed write path. The app role can only read `core.appointment` / `appointment_record`; request, answer, end and record scope go through `fn_appointment_*` (SECURITY DEFINER, caller checked). Unchecked procedures (`sp_end_appointment`, `sp_pay`, `sp_certificate_received`, `sp_redeem_pass`, `sp_select_quote`) revoked from the app role. |
| `0011_account_users.sql` | Users and roles inside an account: `core.app_user` becomes read-only for the app role (no password hashes; own name and language only); invite, role, suspend/reactivate/remove and invitation acceptance go through `fn_user_*` / `sp_accept_invite` (administrator checked; one active administrator always kept). |
| `0012_removed_user_frees_email.sql` | E-mail unique among users that are not removed (Founder ruling 18 Nov 2026); sign-in, look-up, sign-up and invitation see the live user only. |
| `0013_appointment_mail_recipients.sql` | `fn_appointment_recipients`: the other side's active, non-Viewer users for appointment e-mails, for parties to the appointment only. |
| `0014_messages.sql` | Per-record message thread (item 39 (vi)): threads and messages read-only for the app role; `fn_message_post` works out the owner–agency pair; read markers; `fn_message_recipients`; an agency reads nothing after its appointment ends. |
| `0015_owner_pass.sql` | Owner pass (4.4 link 2): `fn_pass_issue` (agency holding the record; code returned once, hash stored), `fn_pass_preview`, `fn_pass_redeem` (owner account; record attached; issuing agency keeps managing under an appointment in force). No direct writes by the app role. |
| `0016_registration_closes_prior_timers.sql` | Once a mark is registered its filing-stage deadlines (priority document, opposition, counter-statement, registration fee, appeal) are closed — met if past, otherwise no longer applying — so the renewal clocks are the next dates. Trigger on `record_event`; existing records back-filled. |
| `0017_pass_verifies_named_owner.sql` | An owner account waiting for review is verified by redeeming a pass the agency had e-mailed to that owner's own address (`verification_method = owner_pass`); `fn_pass_addressee` tells whether a pass is named, open or sent elsewhere. |
| `0018_pass_bound_to_addressee.sql` | A pass the agency sent to an address is redeemed only by a user signed in with that address; a pass without an address stays a bare code for a verified owner. |
| `0019_pass_take_back.sql` | The agency that issued a redeemed pass takes the record back into its own account while it still manages it (`fn_pass_take_back`); the record leaves the appointment, which ends if it covers nothing else. |
| `0020_rulings_18_nov.sql` | Founder rulings 18 Nov: take-back within 30 days; `record.priority_claimed` and profile timers with `requires` (`fn_set_priority_claimed`); document type IMG for the mark image; enum value `historical` added to `timer_state`. |
| `0021_historical_timer_state.sql` | Clocks closed by loading history are `historical`, not `met`; earlier ones converted. |
| `0022_registry_check.sql` | "Verified with registry" as a self-declared statement: who and when on the record (`fn_record_registry_check`), withdrawn by trigger when certificate numbers or dates change. |
| `0023_nice_terms.sql` | Nice list of goods and services from WIPO's revision file (EN, FR, ES): NCL(13-2026) and NCL(13-2027), each term with the dates it is in force (`registry.nice_edition`, `fn_nice_terms`). Generated data, 10,760 rows. |
| `0024_two_factor.sql` | Two-factor sign-in: authenticator secret and sign-in challenge kept out of the app role's reach; `fn_2fa_state` (required for account administrators and staff, optional otherwise), e-mail code and authenticator checks, set-up functions. |
| `0025_staff_login.sql` | Separate staff login: one internal staff account (`account.is_staff`), staff roles only for its users, `fn_staff_invite` / `fn_staff_remove`, `v_staff`; staff roles on customer logins end when a System Administrator activates a staff login; `fn_session` returns `is_staff`. |
| `0026_agency_invites_owner.sql` | An agency invites an owner by e-mail (Founder ruling 18 Nov, point 10): `fn_owner_invite` sends an appointment request to an existing verified owner, or records a waiting invitation (`core.owner_invite`) that becomes the request when an owner account with that address is verified; `fn_owner_invite_withdraw`. |
| `0027_cross_border_instruction.sql` | Cross-border instruction between agency offices (4.4 link 3): read-only for the app role; `fn_instruction_request` / `_respond` / `_end` / `_list` / `_recipients`; the instructed office reads and edits the record while the instruction is active and the instructing office still holds the record (Founder ruling 18 Nov, point 17); the owner is not shown the instructed office (`fn_record_actor`: "handled through"); `v_record_access` withdrawn from the app role. |
| `0028_invitation_verifies_owner.sql` | An agency's invitation verifies the invited owner (Founder ruling 19 Nov): verification method `agency_invite`; `fn_invite_verifies` runs when the owner confirms the invited e-mail address (and when an owner already waiting for review is invited); the staff are told by e-mail (`platform.fn_staff_notices_take`). |
| `0029_owner_instructs_and_invite_mail.sql` | Founder rulings 19 Nov: an owner sends an instruction on its own trademark and messages the office it instructed (`fn_instruction_actor`, `fn_holding_agencies`, `fn_message_parties`); an Agent answers an instruction; the owner is e-mailed when an invitation becomes a request unless the office switched it off (`owner_invite.notify_owner`, `platform.fn_invite_request_mails_take`); `fn_owner_invite` takes the choice. |
| `0030_verification_method_email.sql` | Adds verification method `email` (alone: a new enum value cannot be used in the transaction that adds it). |
| `0031_owners_need_no_staff_approval.sql` | Founder ruling 19 Nov: an owner account is verified on confirming its e-mail address (method `email`); staff approval remains for agency offices; owners waiting for a first review are verified by the migration. |
| `0032_instruction_documents_and_naming.sql` | Instruction carries the owner's legal request and the power of attorney (two documents of the record; `fn_instruction_doc` opens them for the instructed office before it answers); "name the correspondent to the owner" switch (`named_to_owner`, `fn_instruction_name_to_owner`, `fn_record_named_offices`; `fn_record_actor` honours it). |
| `0033_document_removal.sql` | An administrator removes a document from a record (`fn_document_remove`): the row and the vault file are kept (`removed_at`, by whom), the change is audited, the document is no longer listed, and a removed power of attorney no longer counts; `fn_record_object_keys` keeps vault names unique. |
| `0034_instruction_invites_office.sql` | Instructing an agency office not on Meesam yet: `fn_instruction_by_email` sends the instruction at once to an office on Meesam, or records a waiting invitation (`core.instruction_invite`) that becomes the instruction when an agency office with that address is verified; `fn_instruction_invite_withdraw`; `platform.fn_instruction_invite_mails_take`. |
| `0035_deadline_reminders.sql` | Deadline reminders (4.11): `platform.reminder_cadence` (cadences as data), `core.fn_reminders_materialise` (reminder points by the registry's calendar day → in-app notification per account, e-mail per user; idempotent), `platform.fn_reminder_mails_take` / `fn_notification_failed` for the worker; `notification.severity`, `timer_id`, `point`. |
| `0036_calendar_feed.sql` | Calendar feed per user: `core.calendar_feed` (hash of the secret link only), `fn_calendar_feed_set` / `_off` / `_status`, `fn_calendar_events` (open statutory dates of the trademarks the user's account reaches). |
| `0037_notification_preferences_digest.sql` | Per-user notification preferences (`core.user_notify_pref`, `fn_notify_pref`, `fn_notify_pref_set`): Important reminders at once or in the daily summary; daily summary of the other side's changes on or off. `platform.fn_digest_take` hands the worker each user's daily summary once a day; `fn_reminder_mails_take` now holds Important reminders for users who chose the summary. |
| `0038_two_factor_switch.sql` | Two-step sign-in on/off per user (Founder ruling 19 Nov): `app_user.two_factor_choice`; `fn_2fa_state` uses the user's choice, else the earlier default (on for company and agency administrators); staff logins always on. |
| `0039_acknowledge_assign_escalate.sql` | Acknowledge and assign a deadline per account (`core.timer_ack`, audited and shown on the record; `fn_timer_acknowledge`, `fn_timer_assign`); escalation of unacknowledged hard deadlines at 7 days (Administrator) and 3 days (every user) (`fn_reminders_escalate`); `fn_reminder_mails_take` returns `unack`. |
| `0040_legal_acceptance.sql` | Record of the legal texts each user accepted at sign-up or invitation (document, version, time) |
| `0041_watch_fetch.sql` | Watch stage 1, Fetch: poll state on `watch.publication_source`, file facts on `watch.publication_issue`, `watch.fetch_incident`; worker functions `fn_fetch_due/known/wanted/polled/stored/failed` (retry with backoff, incident after three failures); staff actions `fn_source_pause`, `fn_source_poll_now`, `fn_incident_close` (watch lead, audited); UAE catalogue row with the observed MoET location; `platform.fn_staff_role_set` (several roles per staff member). |
| `0042_poll_now_runs_at_once.sql` | A staff "Poll now", "Resume" or incident close queues the `watch.fetch` job at once (trigger `source_due_now`). |
| `0043_uk_test_source_and_reuse_confirmation.sql` | UK IPO Trade Marks Journal location in the catalogue (kept off), weekly Friday schedule row; `watch.fn_source_confirm_reuse` (watch lead states the basis and switches a fetcher on, audited). |
| `0044_bahrain_test_source.sql` | Bahrain "Bulletin on Trademarks" location in the catalogue (kept off; newest listed issue only); notes on the US weekly gazette. |
| `0045_uk_current_journal_page.sql` | The UK source reads the "current journal" page; the file name identifies the issue. |
| `0046_uk_pattern_fetcher.sql` | The UK source becomes a pattern source (numbered file addresses, no page read). |
| `0047_manual_intake_temporary.sql` | Temporary collection by hand (ruling 19 Nov 2026): `manual_intake` per source (`fn_source_manual`, lead, reason required, pauses the fetcher), `fn_manual_add` (lead adds a downloaded file; same checks; recorded and audited), `fn_manual_due_on`, `fn_manual_reminders_take` (worker e-mails the lead when an issue is due). |
| `0048_one_issue_however_typed.sql` | An issue number is matched by its letters and digits (`watch.fn_issue_key`); a number typed by hand takes the form on record; rows split by a different separator are joined. |
| `0004_auth.sql` | Verification status on accounts, agency licences, sessions, verification tokens, login attempts; sign-up / token / session / review procedures (SECURITY DEFINER) |
| `0003_registry_profiles.sql` | Registry profiles v1 for the 14 registries from the Registry Profiles annex (each clock verified/unverified as the annex states; UAE opens), publication sources per stream, English Nice class headings, timer-engine refinements (reminders relative to due date; profile fallback for historical events) |

Where they run:
- Railway: the `worker` service's pre-deploy command `node dist/migrate.js` (direct `DATABASE_URL`), so a
  deploy that cannot migrate never starts serving.
- Locally / CI: `psql -v ON_ERROR_STOP=1 -f migrations/0001_core.sql` and so on, then `pnpm --filter @meesam/db test:sql`
  (behavioural tests in `tests/sql`, rolled back at the end).

Database roles (`SET LOCAL ROLE` per transaction; see `withAccount` / `withRole` in `src/index.ts`):
`meesam_app` (RLS-bound, needs `meesam.account_id` / `meesam.user_id`), `meesam_worker`, `meesam_staff`,
`meesam_admin`, `meesam_readonly`. Sign-up and account verification run as `meesam_admin`, since no account
context exists yet.

Open rulings carried as `-- RULING NEEDED` in the SQL: initial risk-band thresholds (0.85 / 0.70 / floor 0.55 as an engineering start).

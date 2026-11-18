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

Open rulings carried as `-- RULING NEEDED` in the SQL: cross-border instruction edit rights (read-only
taken), initial risk-band thresholds (0.85 / 0.70 / floor 0.55 as an engineering start).

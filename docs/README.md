# Specification documents of record

PDF exports of the Meesam documents as they stood on the date in each file name. The editable
masters are the Claude docs; after every lock or version bump the PDF here is replaced and the
change noted in the commit message. `CLAUDE.md` at the repository root says which document
governs which area of the code.

| Folder | Contents |
|---|---|
| `01-product/` | System Description v0.4; MSM-PRD-02 Watch System (v1.1 locked + v1.2 suggestions) and its Registry Profiles annex; Business Model; End-to-End Workflow; UAE Trademark Workflow (nine stages); Agency and Owner Services and Pages; Data Architecture v0.2; Marketing Strategy and Plan; Home Page Content; Migration and Deployment Plan v0.3 |
| `02-brand/` | Brand Concept v0.2; Brief for brand designers |
| `03-legal/` | Pilot legal pack v0.1 (eight drafts, pending lawyer review) |

Amendment recorded 14 Nov 2026: Data Architecture item 14.1 — PostgreSQL **18** (Railway's pgvector
template), superseding 16.

Implementation notes recorded 15 Nov 2026 (Step 3.1, migration `0001_core.sql`) — points where the
code takes the narrowest reading and awaits a ruling, or where the Data Architecture is to be amended
at its next version:
- Cross-border instruction: the instructed office reads and edits the record it was instructed on (Founder ruling
  18 Nov 2026, point 17; migration 0027). Earlier reading: read only.
- Quote requests gained a `quote_request_recipient` table (Inferred): the document records only
- Mark image: item 43 lists 14 document type codes and none for the mark representation; the image is filed as `OTH` and pointed at by `record.mark_image_doc_id` until ruled (a 15th code such as `IMG` would make vault listings clearer).
  `sent_to_count`, but routing a request to agencies and its row-level security need the recipients.
- `core.record_state` is a regular view with `security_invoker` (not a materialised view), so RLS applies to
  it; refresh semantics are live. To be reflected in Section 7 at the next version.
- Partitioned tables (`published_mark`, `candidate`, `audit_event`, `telemetry_event`) are referenced by id
  without a database foreign key, because PostgreSQL requires the partition key inside any referenced key.
- Unverified clocks create a timer row with `awaiting_user_entry = true` and no date (item 44: no default).
- Initial risk-band thresholds 0.85 / 0.70 / floor 0.55 are an engineering start, tuned from alert feedback.
- Nice class headings and terms are loaded from the official data files in Step 3.3; the migration seeds
  the 45 class numbers only.

Step 3.2 (sign-up, verification, login — 15 Nov 2026):
- `RULING NEEDED`: no document names the login mechanism. Implemented the narrowest standard: e-mail +
  password (scrypt), e-mail confirmation link (24 h), server-side sessions (30 days, httpOnly cookie),
  password reset link (1 h). Passwordless links, UAE Pass or a second factor would be additions.
- Verification states: `pending_email` → `pending_review` (after the link) → `verified` / `rejected`
  (staff or AI decision through `core.sp_review_account`). Until the System Admin screen exists (3.10),
  staff review is a procedure call. Directory listing stays impossible until verified (0001 check).
- Licence and registration documents are captured as references now; the upload lands with the vault (3.4).
- Country list on the forms is the registries' countries plus frequent applicant countries; the full
  ISO 3166 list in Arabic and English is a data file to load (`RULING NEEDED`: source of Arabic names).
- Login, register and reset handlers live under `/api/auth/*` so the Cloudflare rate-limit rule covers them;
  a database-side throttle (8 failures / 15 min per e-mail) is the second line.

Step 3.4 (existing-mark intake, record page, vault — 16 Nov 2026):
- Intake follows System Description 4.7 as six screens (who manages → registry and stage → mark and classes →
  numbers and dates → documents → review and accept); the seventh step, "record created", is the record page.
  Answers live in `core.intake_draft` until acceptance; documents uploaded during intake are stored at once.
- Advisory checks (`apps/web/lib/checks.ts`) warn and never block; a confirmed warning keeps the user's note
  and timestamp in `record.warnings`, unconfirmed ones show as a flag on the portfolio and the record.
- Vault keys follow item 43 (`regno_serial_DDMMYY_TYPE.ext`) inside a per-registry folder; a second document of
  the same type on the same day gets `_2` before the extension. Access to a document is checked by RLS, then a
  10-minute presigned link. `RULING NEEDED`: AI pre-fill from documents is Step 3.5 (document reader).
- Clocks already over when a mark is loaded with its history are closed as `met` (`RULING NEEDED`: a distinct
  historical state instead?). Only registries with `supported = true` (UAE) can be chosen.
- An agency adding a client's mark without an appointment owns the family until an owner pass is redeemed
  (`RULING NEEDED`: confirm against Section 4.4).

Founder feedback 16 Nov 2026 (recorded for Step 3.5, document reader):
- When certificate reading is active, the intake asks for the certificate **first** and the form is then filled
  with what the reader could not find — reverse of today's order (numbers before documents).
- The publication date is not asked for on a mark that is already registered; the check now applies only to
  marks at the published / fee-paid stages.

## Design transfer (16 Nov 2026)

The visual design comes from the Claude Design artifact "Meesam Pilot Prototype" (13 Nov 2026). Its
`ds/tokens.css` and `ds/bundle.css` are copied verbatim into `apps/web/app/ds/` (edit the prototype,
then copy — never hand-edit the copies). `apps/web/app/globals.css` maps the application's class names
onto those tokens; screens move to the `ms-*` components one by one (Pass 2), dashboard and record page first.
Light and dark follow the device (`prefers-color-scheme`), as in the prototype.

## Step 3.5 — document reader (17 Nov 2026)

Intake order is now: who manages it → **certificate and documents** → registry and stage → mark and classes →
numbers and dates → review (Founder ruling 16 Nov 2026; System Description 4.7 step 5). Each upload is read by
the configured AI provider (`apps/web/lib/extract.ts`: Anthropic Messages API, key `AI_PROVIDER_KEY`, model
`AI_MODEL`, default `claude-sonnet-4-5`). Read values fill only empty fields, carry the file and the passage
they came from, are tagged "Read by AI · review" on every step and listed with their source on the review step
(4.7 step 7). A value the user types replaces the read one and drops the source. On commit the uploads are
copied to their final vault names (item 43) and the extraction is kept on `core.document.extracted` with
status `accepted` (the account holder accepted it on review). Without `AI_PROVIDER_KEY` the flow is manual.

## Step 3 item 4 — filing request (17 Nov 2026)

"Request a new filing" (System Description Section 6): seven steps following the MoET form — applicant
(pre-filled from the account), registry and who files (the registry's own who-may-file rules shown from the
profile, never enforced), mark, classes and goods (class heading or goods per class), priority, declarations
and attachments, review with advisory checks. Accepting creates a record at stage 1 (pre-filing,
`entry_mode = new_filing`, free until certificate) with the request kept in `record.filing_request`; the record
page gets a printable "Filing request" tab. Recording the application number and filing date (stage change
"Filed") moves it to stage 2. Meesam does not file, sign, pay, advise or search (Section 6, Ruled).
Not yet built, by dependency on item 5 (Links): sending the request to an agency inside Meesam and the
cross-border variant; until then the request is printed and handed over.
The selectable list of goods per class (Section 6 group 4) is loaded (migration 0023, 18 Nov 2026).

## Step 5 — Links: appointments

Owners appoint a verified agency from the directory and choose the trademarks in scope; the agency
administrator accepts or declines; either side ends the appointment and access stops at once (System
Description 4.4 link 1, item 38). Every change goes through the checked functions of migration 0010.

- Ruled (Founder, 17 Nov 2026): before it accepts, an agency sees only how many trademarks are offered,
  not their names or numbers.
- The other side's active users (not Viewers) are told by e-mail when an appointment is requested, accepted,
  declined, ended or its trademarks change (migration 0013); a waiting request also shows on the dashboard
  and as a count on the Clients / Agencies menu item.
- Ruled (Founder, 18 Nov 2026): on an agency's dashboard and portfolio the column shows the client (the
  owner of the mark), not "Self"; an owner sees Self or the agency.
- Open: an agency inviting an owner needs an invite-by-e-mail flow (with Step 6 notifications); the power of
  attorney is not yet part of the appointment flow.

## Users and roles inside an account

The administrator of a company or agency account invites users by e-mail (link valid 7 days), sets roles,
suspends, reactivates and removes them (System Description Section 3; "Company accounts: invite users,
assign roles", Ruled). Owner-company roles: Company administrator, Trademark manager. Agency roles: Agency
administrator, Agent, Viewer (items 38 and 39). Migration 0011 closes the write path on `core.app_user`.

- A Viewer's writes are refused in the route guard (`requireVerified`); buttons are not yet hidden per role.
- Ruled (Founder, 18 Nov 2026): removing a user frees the e-mail address; the person can then be invited into
  another account or register one. The removed row is kept for history (migration 0012).
- Ruled (Founder, 18 Nov 2026): an Agent answers appointment requests, as the Agency administrator does.
  Ending an appointment stays with the administrator.
- Ruled (Founder, 18 Nov 2026): the Viewer role is removed for now (not offered on the Users screen); it may be
  added back later. This departs from item 38 of the System Description v0.4, which keeps a Viewer for
  agencies: the document needs the amendment. The database still carries the role.
- Two-factor sign-in is not built yet.

## Messages on a record

One thread per record between the owner and the holding agency, text only; each message also shows on the
record's timeline (item 39 (vi)). Posting goes through `fn_message_post` (migration 0014); messages cannot be
edited or deleted. The other side's active users (not Viewers) are told by e-mail; unread messages show on
the dashboard, the side navigation and the record's Messages tab. After an appointment ends the agency no
longer sees the thread (item 38); the owner keeps it.

- Ruled (Founder, 18 Nov 2026): where more than one agency manages a trademark, the owner ticks which of them
  receive a message (one or more); each agency keeps its own thread with the owner and never sees another's.
- Ruled (Founder, 18 Nov 2026): message times are shown in each reader's own time zone, with the zone named.

## Owner pass

An agency that entered a record for a client issues a pass on the record's Agencies tab: a 12-character code,
shown once and optionally e-mailed to the owner; single use, 30 days; a new pass stops the earlier one
(4.4 link 2, item 38). The owner opens `/pass`, logs in (or creates an owner account) and confirms; the
record is attached to the owner's account (migration 0015).

- Ruled (Founder, 18 Nov 2026: keep): on redemption the issuing agency goes on managing the record under an appointment in force
  (created by the redemption), which the owner can end. The other reading — the agency loses the record until
  the owner appoints it — would cut the agency off from a record it entered. Confirm.
- Ruled (Founder, 18 Nov 2026: keep): a pass is bound to one record; if the agency kept it in a family with other records, the
  record moves to a family of its own on redemption and the others stay with the agency.
- Ruled (Founder, 18 Nov 2026): an owner the agency named on the pass (the pass was e-mailed to that address) needs
  no staff review: the owner account, once its e-mail is confirmed, is verified by redeeming the pass
  (migration 0017). This amends the 7 Nov ruling that every owner registration is verified before the account
  is active. Ruled (Founder, 18 Nov 2026: keep): a pass handed over as a bare code (no address) still needs a verified account.
- Ruled (Founder, 18 Nov 2026): a pass the agency sent to an address is attached only by a user signed in with
  that address (migration 0018); another account sees why and can switch account. A pass issued without an
  address is a bare code any verified owner account holding it can use.
- Ruled (Founder, 18 Nov 2026): the side that issued the pass can take the record back, without the other side
  confirming, and the appointment ends automatically (migration 0019; Take back on the record's "Owner pass and
  agency" tab). Bounds taken as the narrowest reading: only while the agency still manages the record (after
  the owner ends the appointment the agency has no access, item 38); the record leaves the appointment, which
  ends when it covers nothing else. Ruled (Founder, 18 Nov 2026): taking back is possible for 30 days from the day the pass was used (migration 0020). Accepted: what happens to
  documents and data the owner added meanwhile (they stay on the record and go with it).
- After login the browser returns to a waiting pass only for the address it was sent to (or a bare code);
  another account logging in from the same browser is not taken to it.
- Sign-up: an individual owner gives the name once; it is also the user's name.
- Redemption during registration (item 39 (vii)): the pass page keeps the code in the browser while the person
  logs in, creates an owner account or switches from another account; the next login returns to the pass, and
  the owner's dashboard shows it waiting.

## Deadlines on a registered mark

- Founder report 18 Nov 2026: a mark added as registered showed "Priority document due". Migration 0016 closes
  the filing-stage deadlines once the mark is registered.
- Ruled (Founder, 18 Nov 2026): the priority-document clock opens only when the record says priority is claimed (profile `requires`, migration 0020). Before: the UAE profile opened it on every filing (6 months from filing, verified).
  It only matters where priority is claimed. Should the clock open only when the record says priority is claimed?

## Founder rulings of 18 Nov 2026 on the ruling list (22 points)

Built: 1 take-back within 30 days; 7 priority clock only where priority is claimed (Certificate information tab,
filing request); 8 message times in the reader's zone; 18 mark image is document type IMG (15th code;
CLAUDE.md rule 8 amended; files stored earlier keep `_OTH` in their vault name); 19 clocks closed by loading
history are `historical`, not `met` (migration 0021).

Kept as built: 2 the owner's additions go back with a record taken back; 3 no take-back once the owner ended
the appointment; 4 the agency goes on managing after a pass is used; 5 one pass, one trademark; 6 a bare-code
pass does not verify a new owner; 9 only the Agency administrator ends an appointment; 11 a missing power of
attorney is flagged, it does not block an appointment; 15 what the document reader read is stored on the
draft before acceptance.

Ruled, to build:
- 10: an agency invites an owner by e-mail: an existing owner account receives an appointment request, a new
  one a sign-up link.
- 12: two-factor sign-in with both methods (authenticator app and e-mail code), for staff and administrators.
- 13: staff use a separate staff login, not the login of an owner or agency account.
- 17: the instructed office in a cross-border instruction may edit the record, for updates in its own country
  (amends the read-only reading in 0001; applies when cross-border is built).

Ruled and built: 16 "Verified with registry" is self-declared by the owner or the managing agency (who and when
kept; withdrawn when certificate numbers or dates change; migration 0022).

Ruled and built: 21 the Nice list is loaded from WIPO's revision file ncl-20270101 (10,123 terms in force in
2026, 10,227 from 1 Jan 2027; English, French, Spanish; migration 0023) and offered as a search-and-add picker
on the filing request. No Arabic list is in the file: Arabic screens show the English terms.
Ruled: 20 country names: the English list is used; there is no Arabic version (Founder, 18 Nov 2026).
Ruled: 13 the first staff login is mohamed.buhannad@meesam.ae (to build with two-factor sign-in).

Open: 14 AI provider key (parked);
22 watch risk-band cut-offs (before the watch goes live).

System Description v0.4 now needs amending for: Viewer removed; owner named on a pass verified without review;
a removed user's e-mail freed; the pass rules (address-bound, take-back 30 days); IMG document type;
historical clock state; priority claim; cross-border edit right.

## Two-factor sign-in (ruling 12, 18 Nov 2026)

Both methods: a code from an authenticator app (TOTP, RFC 6238) and a code sent by e-mail (6 digits, 15 minutes,
one use, six wrong tries end the attempt). Required for account administrators (company and agency) and for
anyone holding a staff role; optional for other users, who switch it on under Account. Without an
authenticator app the code is e-mailed, so nobody is locked out on the first day. Migration 0024.

- The authenticator is set up by typing a key (or opening a link on the phone); a QR code to scan is not
  offered yet, because it needs a library that cannot be added from the build environment at present.
- The authenticator secret is stored in the database unreadable by the app role, but not encrypted with a
  separate key. `RULING NEEDED`: add a configuration key (`TWO_FACTOR_KEY`) to encrypt it before production?
- An invitation accepted from its e-mail link signs the new user in without a second step (the link is the proof).
- Not built: "remember this device", recovery codes.

## Separate staff login (ruling 13, 18 Nov 2026)

Staff are users of one internal staff account and never of an owner or agency account (migration 0025). A System
Administrator invites staff under System Admin → Staff; the person chooses a password from the e-mailed link and
must pass two-step sign-in at every login. The first staff login ruled: mohamed.buhannad@meesam.ae.

- Cut-over: the staff role granted earlier on a customer login keeps working until a System Administrator has
  activated a separate staff login; at that moment every staff role on a customer login is removed.
- A new environment (production): name the first administrator's address in `SYSTEM_ADMIN_EMAILS`, then ask for
  a password reset for that address on the login page; the invitation goes to that mailbox. The variable no
  longer gives a staff role to a customer login.
- A staff login has no customer dashboard: it lands in the System Admin and reaches only its own Account page.

## Agency invites an owner by e-mail (ruling 10, 18 Nov 2026)

- Migration 0026. On Clients the administrator or an agent enters the owner's e-mail address and an optional message.
  An address that belongs to an active user of a verified owner account produces an appointment request at once
  (from the agency; the owner chooses the trademarks when accepting). Any other address gets a waiting invitation and an
  e-mail with a link to create an owner account; the invitation becomes the same request when an owner account with that
  address is verified. One waiting invitation per office and address; the office can withdraw it.
- The office learns from the outcome whether the address already has an owner account (a request shows the account's
  name). This follows from the ruling as worded.
- Founder ruling 19 Nov 2026 (migration 0028): an owner who signs up from an agency's invitation needs no staff review.
  The account is verified when the owner confirms the invited e-mail address (method `agency_invite`); the System
  Administrators receive an e-mail saying the account was created from the invitation. An owner account already waiting
  for review is verified the same way when an agency invites its address.
- Founder ruling 19 Nov 2026: an owner with no trademarks yet accepts an agency's request with none and chooses the
  trademarks later on Agencies, after adding them. An owner who has trademarks still chooses at least one.
- Founder ruling 19 Nov 2026: 50 invitations per office in 24 hours is confirmed; may be reviewed later.
- Founder ruling 19 Nov 2026 (0029): when an invitation becomes a request the owner is e-mailed as well; the inviting
  office can switch that off on the invitation form ("Also e-mail the owner…", on by default). The invitation e-mail is
  written in the language the inviting user is working in, since the owner's language is not known yet.

## Cross-border instruction (ruling 17, 18 Nov 2026)

- Migration 0027, following the Data Architecture: an instruction is agency office → agency office on one record.
  An office that holds a record (its own, or under an accepted appointment) instructs another verified office, chosen
  from the directory or named by the e-mail of one of its users (a sister office that is not listed). The instructed
  office's Administrator accepts or declines; either Administrator ends it; the sender withdraws one still waiting.
- While the instruction is active the instructed office reads and edits that record (stages, certificate details,
  documents). The right lasts only while the instructing office itself still holds the record: when its appointment
  ends, the instructed office's access ends with it.
- Disclosure (item 26): the owner cannot read the instructed office or the instruction; a change made by the instructed
  office shows to the owner as "Handled through [instructing agency]". The two offices see each other; the instructed
  office sees the owner. The instructed office is not part of the owner's message thread and cannot issue a pass.
- Built 19 Nov (0032): the sender attaches the owner's legal request and the power of attorney from the record's
  documents; the instructed office opens those two before answering. "Name the correspondent to the owner" is a switch
  per instruction, off by default, set by the instructing agency (Administrator or Agent).
- Built 19 Nov (0034): instructing an office that is not on Meesam. The sender gives the office's e-mail; the address
  receives a link to create an agency account, and the instruction (with its message and documents) reaches the
  office once staff have verified the account. The invitation lapses if the sender no longer holds the trademark.
- Not built yet: the multi-country request (Owner 3.12, Agency 3.11 "Create": one request, several countries, one
  record per country; recommended after the pilot launch).
- Founder ruling 19 Nov 2026 (0029): an Agent, as well as the Administrator, accepts or declines an instruction.
  Ending or withdrawing stays with the Administrator.
- Founder ruling 19 Nov 2026 (0029): the owner of a trademark can send an instruction to an agency office too. The
  office the owner instructed is known to the owner and the two write to each other on the record's message thread.
  An office instructed by an agency stays hidden from the owner (item 26). This departs from the Data Architecture
  (instruction = office to office) and from the v0.4 System Description; both need the revision.
- Security correction in the same migration: the app role could write instruction rows directly (0001 policy) and
  could read `core.v_record_access` across tenants (identifiers only). Both closed.

## Owners need no staff approval (ruling 19 Nov 2026)

- Migrations 0030 and 0031. An owner account, individual or company, is verified when its e-mail address is confirmed.
  Staff approval remains for agency offices. This replaces System Description 4.2 "verification before activation"
  for owners; the document needs the revision.
- An owner that staff rejected earlier stays rejected; correcting details still goes to staff.
- `RULING NEEDED`: the Founder's wording is that staff approval is "only for agencies wanted to be listed in Meesam
  agencies list where official documents required and later verified by the AI system". Narrowest reading taken: every
  agency office still waits for staff approval before it can work. Should an agency that does not want to be listed
  work without approval, with approval gating only the directory listing? Founder, 19 Nov: keep as it is for the time
  being (every agency approved by staff); to be reviewed later.

## Removing a document (staging test, 19 Nov 2026)

- Migration 0033. An administrator of an account that may edit the record removes a document uploaded by mistake.
  Nothing is deleted: the row and the vault file stay, the removal is audited and shown on the timeline, and the
  document is no longer listed or downloadable. The mark's own image is replaced on the Mark tab, not removed.
- Founder ruling 19 Nov 2026: a document is removed by the Administrator in an agency or a company, and by the
  owner himself in an individual owner account. This is what 0033 does (an individual owner's login is the
  account's administrator).
- The Documents upload form now starts on "POA" when the record's power of attorney is missing or expired, and the
  notice says how to add it.

## Notifications and timers, first part (plan Step 3 item 6; System Description 4.11) — 19 Nov 2026

- Built (0035, worker): deadline reminders. The worker runs every hour: it works out the reminder points that fell due
  by each registry's own calendar day and writes one in-app notification per account and one e-mail per user, then sends
  the e-mails. Cadences are rows in `platform.reminder_cadence`: 30-day clocks at start, 10 days, 3 days and the due day;
  renewal at window open, 6/3/1 months (the registry profile's reminder clocks) and the expiry day; grace period 3 months,
  1 month and the day. Severity: Critical when the hard deadline is within 30 days (a calendar month counts as within),
  otherwise Important. Recipients: every active user of each account that reaches the record.
- No reminder is sent for a point that had already passed when the clock was created (loading an existing mark does
  not produce a burst of old reminders).
- Built (0036): calendar feed per user (Settings), by secret link shown once; "Add to calendar" on each open date.
- Worker variables needed for reminder e-mails: `EMAIL_PROVIDER_KEY`, `EMAIL_FROM`, `APP_URL` (and `EMAIL_STREAM` if
  set on web). Without the key the reminders stay queued and are sent once it is set.
- Fixed: the nightly housekeeping job re-queued itself while running, which its own dedupe key refused, so it ran only
  once per start. Recurring jobs are now queued by the worker's own schedule.
- Built 19 Nov (0037): per-user preferences on the Account page (Important reminders at once or in the daily summary;
  daily summary of the other side's changes on or off; Critical always at once) and the daily summary e-mail, sent
  once a day after `DIGEST_HOUR_UTC` (worker variable, default 4 = 08:00 Gulf time) and only when it has content.
- Not built yet from 4.11: acknowledge / assign / escalate; in-app
  notification centre (the dashboard's next dates are the in-app view for now); assignment of records to users;
  the monthly fee reminder while a penalty accrues; soft, milestone and vulnerability clocks; bounce flag;
  the import review summary (bulk import is not built).
- `RULING NEEDED`: cadence for hard deadlines the document does not list (priority document, and other registries'
  clocks): 1 month (3 and 1 for others), 10 days, 3 days and the due day are taken.

## To test with real agencies in the pilot (Founder, 19 Nov 2026)

Functions built and covered by automated tests, but not exercised on staging because the staging data does not
produce the situation. They are to be confirmed with real accounts and real dates during the pilot:

- Deadline reminder e-mails (0035): the hourly worker run, the reminder points (30-day clocks at start / 10 / 3 / due
  day; renewal at window open, 6 / 3 / 1 months and expiry day; grace period), the wording in both languages, and
  delivery to every active user of each account that reaches the trademark.
- The daily summary e-mail and the notification preferences (0037), once built.

## Two-step sign-in can be switched off (ruling 19 Nov 2026)

- Migration 0038. Every customer user has an on/off switch on the Account page. Default where no choice was made:
  on for the administrators of company and agency accounts, off for other users. This relaxes ruling 12 of 18 Nov
  (two-step sign-in required for administrators): it is now their choice.
- Staff logins have no switch and stay on, because a staff role reaches every account. `RULING NEEDED` if the Founder
  wants the switch for staff as well.
- Before production: consider requiring the password again to switch it off, and telling the account by e-mail.

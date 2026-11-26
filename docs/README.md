# Specification documents of record

PDF exports of the Meesam documents as they stood on the date in each file name. The editable
masters are the Claude docs; after every lock or version bump the PDF here is replaced and the
change noted in the commit message. `CLAUDE.md` at the repository root says which document
governs which area of the code.

| Folder | Contents |
|---|---|
| `01-product/` | System Description v0.4; MSM-PRD-02 Watch System (v1.1 locked + v1.2 suggestions) and its Registry Profiles annex; Price List v1.0 (ruled 21 Nov 2026, the price list in force); Business Model; End-to-End Workflow; UAE Trademark Workflow (nine stages); Agency and Owner Services and Pages; Data Architecture v0.2; Marketing Strategy and Plan; Home Page Content; Migration and Deployment Plan v0.3 |
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
- Built 19 Nov (0039): acknowledge and assign on every open hard deadline (per account, any user except a Viewer,
  audited and on the timeline; the assignee is e-mailed), and escalation: a hard deadline an account has not
  acknowledged is re-sent marked "unacknowledged" to its Administrator at 7 days and to every user at 3 days.
- Not built yet from 4.11: in-app
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
- The daily summary e-mail and the notification preferences (0037).
- Escalation of unacknowledged deadlines at 7 and 3 days (0039).

## Two-step sign-in can be switched off (ruling 19 Nov 2026)

- Migration 0038. Every customer user has an on/off switch on the Account page. Default where no choice was made:
  on for the administrators of company and agency accounts, off for other users. This relaxes ruling 12 of 18 Nov
  (two-step sign-in required for administrators): it is now their choice.
- Staff logins have no switch and stay on, because a staff role reaches every account. `RULING NEEDED` if the Founder
  wants the switch for staff as well.
- Before production: consider requiring the password again to switch it off, and telling the account by e-mail.

## Bulk import (plan Step 3 item 4; System Description 4.7 "Portfolio import") — 19 Nov 2026

- Built: Portfolio → Bulk import. A spreadsheet saved as CSV is staged (`platform.import_batch` / `import_row`), its
  columns are matched to Meesam's fields (suggested from the header names, English or Arabic), each row is checked,
  and the readable rows are loaded by the same code as "Add existing trademark" (`insertLoadedRecord`), with
  `entry_mode = bulk_import`. Up to 500 rows and 2 MB per file. A template is offered.
- Advisory checks do not block a row (Ruled 10 Nov): it is loaded and keeps its warnings. Left out: rows that cannot
  be read (no known registry; nothing to identify the mark) and duplicates (same registry and application or
  registration number already in the portfolio or earlier in the file).
- The import ends with the summary of item 44: trademarks loaded, checks to review, open dates computed, dates overdue,
  dates due within 90 days. No reminders are sent about dates already past (0035).
- Loaded marks are `free_loaded`, following item 45 (existing marks are loaded free; the fee is due when the watch is
  switched on). The Data Architecture text (Section 9 item 2) still says `read_only_unpaid`; item 45 is later and wins.
  To correct in the Data Architecture revision.
- An agency's imported marks are held by the agency's own account, as with a single added mark; the owner pass moves
  each one to its owner.
- Not built: reading .xlsx directly (no spreadsheet library in the build; the page tells the user to save as CSV);
  documents per row; choosing the client per row; the free retrospective conflict report on import (needs the watch).

## Legal pages and sign-up consent (built 19 Nov 2026)

- The five public legal texts (Terms of Use, Privacy Policy, Cookie Notice, Acceptable Use Policy, AI and Watch Notice) are shown at `/{locale}/legal/{slug}` word for word from `03-legal/*.pdf` (converted by `infra/tools/legal2md.py`; "Notes for review" left out). They are v0.1 drafts: the page carries a "Draft, not yet in force" banner, the square-bracket blanks are shown as written, and the Arabic site shows the English text until the Arabic legal text exists.
- Sign-up and invitation acceptance require a tick box; what was accepted, which version and when is kept in `core.legal_acceptance` (migration 0040). Users who signed up before this have no row.
- Discrepancy for the Founder: Terms of Use 4.4 ("An owner account becomes active only after we verify the registration") no longer matches the ruling of 19 Nov 2026 (owners need no staff approval). The text is shown as written; the document needs a revision.
- Cookie Notice blanks: the build sets only strictly necessary cookies (`msm_session`, `ms_2fa`, `ms_pass_<id>`, `ms_pass_hold`, `ms_cal`, `ms_cookie_ok`); the page lists them under the draft text. No consent tool is needed until a non-essential cookie is added.
- RULING NEEDED: when the final legal versions are published, should existing users be asked to accept again at next login? (The consent note tells them they will be.)

## Public home page (built 19 Nov 2026)

- `/{locale}` now carries the nine blocks of Home Page Content v0.1 with the Section 3 copy as written (Arabic retyped from the PDF pages, since text extraction corrupts it). Block 7 shows the principle only, no figures (ruling of 10 Nov 2026).
- Held back, RULING NEEDED: the "See pricing" link (no public Pricing page yet; pricing is under review); the footer links Help, Feedback and suggestions, Contact (no public destination yet).
- Discrepancies for the Founder: (1) three Arabic stage names differ between the Home Page Content document (الطعون / القيود اللاحقة للتسجيل / الطعن في التسجيل) and the product screens (التظلّمات / التأشيرات بعد التسجيل / الطعون في التسجيل); the home page follows the document, the product is unchanged. (2) The document spells the company زيونكس, the product footer زيونيكس. (3) The document still says "ten-stage bar" in two places; nine are shown.
- Not in the document, written for the page: the Arabic section headings, the labels on the record-card illustration ("Watch active", "Stage 3 of 9"), and the sample mark name (Meesam's own).
- The site still opens in English by default on every domain (`DEFAULT_LOCALE`); the document asks for Arabic by default on the .ae and Arabic domains.

## Watch, stage 1: Fetch, and the Watch Operations Console (plan Step 3 item 8; MSM-PRD-02 Sections 3, 4, 9A) — 19 Nov 2026

- The worker job `watch.fetch` polls every source that is active, not paused and has a location in its catalogue row. It reads the page, lists the issues, downloads those whose opposition window is still open (period from the registry profile, last day to 23:59 registry time), checks the file (kind, size, date not in the future), stores it once in the publications bucket (`REG/stream/issue_checksum.ext`) and records the run. Nothing is uploaded by a person anywhere.
- Failure: retry after 5, 15 and 30 minutes; after three failures in a row the source shows "Failing" and a "source broken" incident opens with the earliest window at risk. The lead closes the incident once the source works.
- Observed 19 Nov 2026 (differs from the Watch document and the annex, which say "PDF, links on the page"): MoET publishes each issue as ONE `.rar` archive on its publications page, newest first, with number and date in the link text; issue 354 is dated 17 Nov 2026 and 353 is dated 3 Nov 2026. The archive holds the issue's PDFs, so the Madrid stream is read from the same file. The catalogue row carries this as data.
- Console (`/{locale}/ops`, staff roles watch_lead and publication_reviewer; a separate area from System Admin): Registries, Release calendar, Publications inbox, Fetcher incidents. Lead actions: pause, resume, poll now, close incident; all audited. System Admin → Staff can now give a staff member a second role.
- Not built yet: unpacking the archive and Extract (needs the AI provider key), Verify, Normalise, Compare, Alert, Learn; recovery steps 2 to 4 (other fetcher types, AI re-discovery, secondary sources); e-mail to the lead on an incident; editing the catalogue, the profile values and the release calendar from the console; Issue detail, Reviewer queue, Watch health, Retrospective, Learning releases, Audit pages; fetcher types other than the page crawler (USPTO pattern fetcher next).
- RULING NEEDED: the location stored for MoET is the page address that was reachable on 19 Nov 2026; confirm with MoET that this is the stable publications page.
- RULING NEEDED: the fetcher identifies itself to registries as "MeesamWatch/1.0 (+https://meesam.ae; publication fetcher)".
- USPTO (Founder, 19 Nov 2026): the Founder pointed to https://www.uspto.gov/learning-and-resources/xml-resources. It lists the "Trademark Daily XML Files (TDXF)" documentation (applications v2.3 of 13 Aug 2025, status codes, assignments, TTAB) hosted on data.uspto.gov; the page itself gives no download address, cadence, terms or key requirement. A structured daily XML stream would skip AI extraction and human verification (Watch document Section 4). To profile before the USPTO fetcher is built: the download location on data.uspto.gov, whether a key is needed, and the terms of use.
- First run on staging, 19 Nov 2026: reading the MoET page from the worker (Railway, Singapore) failed twice with a connection timeout at 10 seconds. The reader now uses IPv4, allows 45 seconds to connect and reports the real network error. If the timeout persists, MoET's network is not answering Railway's addresses. RULING NEEDED in that case: ask MoET to allow Meesam's fetcher from a fixed address, or run the fetcher from a UAE network.
- Second test source (Founder, 19 Nov 2026: MoET's site is sometimes unreachable and USPTO files are large): the UK IPO Trade Marks Journal. Observed: weekly on Fridays, a PDF of about 15 MB per issue (journal 2026-046 dated 13 Nov 2026), listed newest first at `https://www.ipo.gov.uk/t-tmj/t-tmj-previous.htm`. The fetcher stays off until the watch operations lead confirms re-use in the console (Registries → "Confirm re-use and switch on", basis recorded and audited). Evidence found for re-use: the data.gov.uk record lists the journal under the Open Government Licence (record last updated 2014); the IPO's current terms were not read. The UK opposition period is unverified: only the newest issue is held and no deadline is shown. The catalogue said XML for the UK; the test takes the PDF (the 230 MB XML on the page is a different data file). RULING NEEDED: which UK file the watch will finally read (PDF, or the ZIP "Compressed Journal").

### Publication sources researched 19 Nov 2026 (Founder: "do the same with the rest of the countries")

| Code | What was found | State |
|---|---|---|
| GB | Weekly journal (Fridays), PDF about 15 MB, listed newest first; Crown copyright, Open Government Licence by default (National Archives) and on data.gov.uk | Location in the catalogue; off until re-use confirmed |
| BH | Ministry of Industry and Commerce "Bulletin on Trademarks" page, PDFs of 1 to 2 MB per issue; page states objections within sixty days; no re-use terms found; the page read showed 2025 issues 10 to 20 only | Location in the catalogue; off until re-use confirmed |
| US | Weekly gazette (Tuesdays), one PDF of 228 to 597 MB at a dated address; daily XML files documented on data.uspto.gov; US government works | Notes only; waits for the daily data to be profiled |
| SA | A 2012 agency note says publication is on the Ministry of Commerce e-services site; SAIP's current publication page was not found | Not located |
| EM | EUIPO's bulletin location, bulk access and terms were not found by search | Not located |
| OM, KW, QA | No official publication page found | Not located |
| TR, IN, CN, EG, JO | IN: the journal site is search.ipindia.gov.in/IPOJournal; JO: gazette PDFs appear on mit.gov.jo; nothing confirmed | Second wave; not located |
| WO | Off until an agreement with WIPO (ruled 12 Nov 2026) | Not researched |

Nothing above is switched on. Each fetcher starts only when the watch operations lead confirms re-use in the console.
- Staging, 19 Nov 2026: (1) MoET's page was read from Railway at 14:52 and issue 353 was listed with its date, so the page reader works on the real page and the site is reachable; the file download then failed to connect, so the connection to MoET is intermittent rather than blocked. (2) After a redeploy killed a running fetch, the job stayed "running" and no source was polled again (the UK and Bahrain sources showed no poll for an hour). Fixed in the worker: a heartbeat on the job in hand, release of any job silent for two minutes, hand-back on shutdown, and a time limit on a site that connects but sends nothing.

## Founder ruling 19 Nov 2026: temporary collection of publications by hand

- Reverses, for named sources only, the ruling of 7–8 Nov 2026 ("no manual upload step") in MSM-PRD-02 Section 4 and System Description; both documents and CLAUDE.md rule 7 need the exception written in (CLAUDE.md is updated).
- Why: the UK IPO and Bahrain ministry sites answer 403 to Meesam's fetcher for the listing pages and for the file itself; the fetcher is not disguised as a browser.
- How: the watch operations lead switches a source to "Collected by hand (temporary)" on Registries, stating the reason (the fetcher is paused). When an issue is due (expected release, else a week after the last one, else at once) the lead gets an e-mail and the console shows it; the lead downloads the issue from the registry and adds it under Publications inbox with its number and date. The file gets the same shape check, is stored once by checksum in the publications bucket and is marked "added by hand" with the person's name; every step is audited. Limit 120 MB per file.
- Narrowest reading taken, RULING NEEDED: (1) "a temporary staff rule" was built as a rule for the existing watch operations lead, not as a new staff role; (2) only the lead adds files, not the publication reviewer; (3) the source must have re-use confirmed first; (4) reminders repeat every three days while an issue stays due.
- Railway: the web service needs the four `PUBLICATIONS_*` variables (it had only the vault ones) to store a file added by hand.

## Qatar publications linked (Founder, 20 Nov 2026)

- Source: Ministry of Commerce and Industry, `https://www.moci.gov.qa/en/reports-statistics`. Observed 20 Nov 2026: Industrial Property Gazette in two parts per issue (No. 352 (A) and (B), 15 Oct 2026; No. 351, 17 Sep 2026) and the Madrid Trademark Gazette (MD13 posted 11 Nov 2026, MD12 posted 8 Oct 2026), all PDF.
- Both are in the catalogue as page-crawler sources and are off until the watch operations lead confirms re-use in the console; no re-use terms were found on the site. If the site refuses the fetcher, the source can be collected by hand under the ruling of 19 Nov 2026.
- Qatar's opposition period (60 days) is verified in its profile, so issues are taken while their window is open (today: No. 352 and the Madrid numbers posted in the last 60 days).
- RULING NEEDED: (1) what parts (A) and (B) each contain (trademarks, designs, patents) and whether both are needed; (2) whether the Madrid gazette's posting date is the publication date its opposition period runs from; (3) the ministry's terms for re-use.
- Staging, 20 Nov 2026: the Qatar Madrid gazettes MD12 and MD13 were fetched automatically (the ministry's site accepts the fetcher). The national gazette failed with "no issue links were found": the page carries more markup between an entry's heading and its link than the reader's look-back reached. The look-back is widened, and the error now says whether no link matched or links matched but named no issue.
- Staging, 20 Nov 2026: Qatar's national gazette No. 352 (A) 4.6 MB and (B) 5.0 MB were fetched after the reader fix. Since then an incident closes by itself when its source works again (migration 0050), and the console tables keep dates and numbers on one line.

### Registries checked on 20 Nov 2026 (Founder: "activate all registries to test if they work")

| Code | What the office offers | Result |
|---|---|---|
| AE | One archive per issue on the MoET page | Automatic, working |
| QA | PDFs on the ministry's Reports & Statistics page (national parts A and B; Madrid) | Automatic, working |
| US | Weekly gazette PDF of about 500 MB at a dated address on the TMOG page | Location set (0051); starts by itself; result to be seen on staging |
| GB | Weekly journal PDF at a numbered address | Site answers 403 to the fetcher; collected by hand |
| BH | PDFs on the ministry's Bulletin on Trademarks page | Site answers 403 to the fetcher (19 and 20 Nov); paused |
| SA | No issue files: publication is a searchable portal (ipn.saip.gov.sa, ipgazette.saip.gov.sa) | Needs a portal adapter or a data feed from SAIP; not activated |
| TR | The office's own page turkpatent.gov.tr/bultenler (supplied by the Founder) lists the trademark bulletins (No. 504 of 12 Nov 2026) with download links; the separate site bulten.turkpatent.gov.tr disallows robots and is not used | Location set (0052); off until re-use is confirmed in the console |
| IN | Journal page lists weekly journals in class parts (No. 2287 of 16 Nov 2026) | Downloads appear to be buttons, not links, and files are large; needs its own fetcher; not activated |
| EM | Bulletin sits inside EUIPO's search application; its information page disallows robots | Needs EUIPO's data access (registration); not activated |
| KW | Only an applicants' service page found; no public gazette page | Not located |
| EG | Trademark gazette by year on the Egyptian Patent Office's site, egypo.gov.eg (index page id=99; 2026 = id=100), supplied by the Founder; the site did not answer from outside Egypt, so the layout is not yet seen | First-test location set (0053); off until re-use is confirmed; to be finished from a screenshot |
| OM, CN, JO | No official publication page found | Not located |
| WO | Off until an agreement with WIPO (ruled 12 Nov 2026) | Not activated |

RULING NEEDED: whether Meesam's fetcher obeys a site's robots rules (built as: a site that disallows robots is not activated, as for Türkiye).
- Staging, 20 Nov 2026: the USPTO gazette of 17 Nov 2026 (514.6 MB) and Türkiye's bulletin No. 504 (367.5 MB) were fetched automatically; both sites accept the fetcher. Egypt's page is reachable from the worker, but the first test picked a non-gazette PDF from the page's furniture. New catalogue mode "list_only": the worker reads a page and shows the staff its file links (Fetcher incidents, "Page read, nothing taken"), downloading nothing; Egypt's row is to be finished from that list.
- Egypt, 20 Nov 2026 (Founder's screenshot): the 2026 page is one table, a row per monthly issue (1025 of 2026-1-6 to 1035 of 2026-11-19), oldest first, the issue number being the link. The reader now supports links told by their text, values read from the link's own table row, and oldest-first pages (migration 0056). What the links return is still to be seen on staging.

## Price List v1.0 reflected in the product (Founder rulings 21 Nov 2026)

The Founder's pricing review produced "Meesam (ميسم) — Price List v1.0" (PDF in `01-product/`). It supersedes the
price points of the Business Model v0.1 and item 45's free states. Built from it (migrations 0058–0059):

- Price list version 2 in `core.price_list`: list AED 480 (10 years), introductory AED 370 while the offer is open,
  10% of the full price less per year, floor AED 195 (the introductory 5-year step stays 195), filing fee AED 100
  for a new mark (credited toward the full price, not refunded), AED 150 per additional or watch-only registry,
  AED 100 per added class, VAT-inclusive total shown to UAE buyers.
- No free states. The stored state names are kept; their meaning and wording changed: `free_new_pending` = new
  mark, filing fee due; new `filing_paid` = filing fee paid (reminders, no watch); `free_loaded` = existing mark,
  record fee due; `read_only_unpaid` and `paid` as before.
- The record's Fee tab shows list price, introductory price, the filing fee already paid, what is due, VAT and the
  total. The home page pricing lines no longer say a new mark enters free.
- `INVOICE_ISSUER` is now Xeonix Technologies (the Railway variable is changed by the Founder).

Nothing is charged yet: there is no payment gateway, and the pilot stays free.

RULING NEEDED (open in the Price List itself):
- Effective date of v1.0 (entered as 2 Dec 2026, the date of the list it replaces).
- Pilot terms and the 30-day conversion period (the pilot stays "everything free" as last ruled; the dashboard
  notice still says so).
- End date of the introductory offer (entered as open, no end date).
- Renewal price (Q4 Year 1 review); the 12-month renewal credit is carried as configuration only.
- Credit wallet; large single-registry portfolios.
- What an unpaid record may do (the list says what is paid and when, not what is withheld until then). Nothing was
  changed: only a new mark past its certificate is read-only until paid, as ruled 30 Oct and 7 Nov 2026.
- "When a new registry becomes available, every account holder is told by e-mail": not built; the moment a
  registry counts as available (switched on in the Operations Console, or announced by staff) needs a ruling.
- The legal name to print on invoices for Xeonix Technologies (legal form and licence details).

Documents that now disagree with the Price List and need the Founder's revision (not changed in code, because
legal and specification texts are documents of record):
- `03-legal` Pricing and Refund Terms v0.1, and Terms of Use 8.2 and 9.4 ("free until its registration
  certificate"); the legal texts shown in the product are still these drafts.
- Business Model v0.1 Section 7 and System Description item 45 (free load, free until certificate).
- Home Page Content v0.1 (pricing lines).
- "Data Management and Use v0.1" (draft of 21 Nov 2026) is proposals awaiting ruling (its items 10.1–10.13);
  nothing in it was built. Its Section 7.3 still names Wahaat Investment as the invoicing entity, and its Section 4
  registry table predates the sources linked on 19–20 Nov (UK, Qatar, USA, Türkiye, Egypt, India).

## Founder rulings of 21 Nov 2026 on the before-launch list (R1–R19)

- R2 AI reading model: Sonnet 5.5 by batch; one issue also read with Haiku 5.5 to compare.
- R3 Qatar: part (B) of an issue is the continuation of part (A) (split to keep the files small). Both parts are read
  as one issue. (Founder's reading; to confirm from the contents when read.)
- R4 Verification of AI-read marks in the pilot: the Founder, under the watch operations lead role, until a reviewer
  is appointed.
- R5 Data Management and Use 10.1 and 10.2 adopted: four data classes, six zones; a record is matched to its
  published mark, never merged; differences are shown as an advisory "Registry shows…" note.
- R6 Risk bands: the related-class weight is raised from 0.6 to 0.75, so identical marks in related classes alert as
  Medium (bands stay High 0.85, Medium 0.70, floor 0.55). To be reviewed against what users say. It is entered as
  configuration when the comparison stage is built; this closes the "initial risk-band cut-offs" RULING NEEDED.
- R7 All registries' dates and deadlines are verified and confirmed before they are relied on; no Qatar deadline is
  shown until its Madrid publication date is confirmed.
- R8 Data Management and Use 10.4 and 10.5 adopted: re-use register per registry, read by the fetcher's gate;
  data-quality page in the Watch Operations Console.
- R9 The fetcher obeys a site's robots rules: a site that disallows robots is not activated.
- R10 The public Pricing page shows the list price and the introductory price, with the VAT-inclusive figure for the UAE.
- R11 Footer: Help leads to a short page of questions, Feedback to a form for signed-in users, Contact to info@meesam.ae.
- R13 A separate configuration key protects two-step sign-in secrets before production.
- R14 Publication files are all kept during the pilot; retention is decided at the Year 1 review or earlier.
- R16 Production values go into Railway two days before launch, or earlier if the build is ready.
- R17 Default language on meesam.ae is English, with Arabic one click away.
- R19 Data Management and Use 10.9, 10.11 and 10.12 adopted: the "what Meesam will not do with data" list (no public
  trademark search or public mark pages; no sale of raw corpus extracts or contact lists; no use of one account's
  records to benefit another account; no first contact that cites the publication issue); the Founder holds all four
  data-owner roles until staff are hired; paid data services are studied only after Year 1.

- R15 Backup copy: Cloudflare R2, EU jurisdiction (see `infra/README.md`).

Still open from the list: R1 (AI provider key in Railway), R12 (pilot terms; a proposal was given, P1–P8), R18 (revised legal texts), and Data Management and Use 10.10.

## Re-use register and data-quality page (plan item A5; rulings R8 and R9, 21 Nov 2026)

- Operations Console → "Re-use and data quality" (`/ops/quality`). The register holds one row per registry: terms as
  read, link, date read, and yes / no / not yet read for store, show, derive, train and contact. The watch operations
  lead edits it; every change is audited. Rows were started from the bases already stated when sources were switched on.
- The gate reads the register (migration 0060): with storing set to "no", the registry's sources are paused at once,
  cannot be resumed or switched on, and no file of that registry can be recorded as stored, fetched or added by hand.
- Data quality, per source that is on: last issue, lateness, issues stored, issues waiting to be read, failed attempts
  in 30 days, open incident, marks read, marks waiting for verification.
- Not built yet (they need the reading stage): reading accuracy per registry and field, and records without a match.
- RULING NEEDED: only "store" is enforced by the gate today. "Show", "derive", "train" and "contact" are recorded
  and will be enforced where each use is built (alerts, market intelligence, model training, outreach).

## Records matched to published marks, never merged (plan item A3; ruling R5, 21 Nov 2026)

- What a registry publishes stays in `watch.published_mark`; what an account enters stays in `core.record`. Migration
  0061 adds only the link (`watch.record_match`), by registry and application number, however the number was typed.
- Only verified marks are matched. A record entered later is matched to what was already published; a corrected
  number drops the old match. Nothing in the record is ever changed by a match.
- The record's Overview shows an advisory "Registry shows…" note with the differences (mark wording, classes), the
  publication and page, and the applicant and agent as published. It appears only where the re-use register says the
  registry's data may be shown ("Show" = Yes).
- Not built: a match without a number (a scored match the user confirms) comes with the comparison stage; owner names
  are shown but not compared (spelling varies too much to compare safely).
- RULING NEEDED: capital and small accented letters (É, é) may count as a difference on a database set to plain
  sorting; to be checked on staging when the first marks are read.

## Nightly second copy of the database (plan item A7; ruling R15, 21 Nov 2026)

- The worker copies the whole database each night (after 22:00 UTC) with PostgreSQL's own tool, checks that the copy
  lists its contents, and stores it in Cloudflare R2 (EU jurisdiction), a different company and region from Railway.
- A restore test runs about weekly and on request: the copy is restored into a scratch database, compared with the
  live counts and removed. The live database is only read.
- Kept: every copy for 35 days, then the first of each month for a year.
- Meesam System Admin → Backups lists every run and lets a system administrator ask for a copy now.
- Covers the database only. RULING NEEDED: whether the documents vault and the publication files also get a second
  copy; and who is told by e-mail when a nightly copy fails (today it shows on the Backups page and in the logs).
- Not yet done from plan item A7: sign-in limits review, error monitoring, the separate key for two-step sign-in
  secrets (ruling R13).

## Reading tests (plan item A1, first step; ruling R2, 21 Nov 2026)

- Operations Console → Reading tests: the watch operations lead picks a stored issue, a first page, one to five pages
  and a model (Sonnet 5.5 or Haiku 5.5). The worker brings the file from the bucket, opens it if it is an archive,
  cuts out the pages and sends only those to the AI reader. What it read (marks, numbers, classes, applicants, agents,
  dates, its own confidence and notes) is shown beside the test, with the size of the request and reply.
- A test loads nothing among the published marks and reaches no account. It exists to judge the reader on real pages
  and to compare the two models before the reading stage is built in full.
- The re-use gate applies: no test on a registry whose register says storing is not allowed. At most 30 tests an hour.
- The certificate reader in "Add existing trademark" now defaults to Sonnet 5.5.
- RULING NEEDED after the first tests: which model reads the pilot registries; whether the mark's picture is cut out
  of the page by the reader's description or by a separate step; how many pages go in one request.

## First reading test and what it changed (staging, 21 Nov 2026)

- The first test (Qatar 352 (A), PDF pages 5–6, Sonnet 5.5) read two index pages: 44 rows of number, class and
  picture, so no owner, agent or date, and the "page" shown was the page inside the excerpt. The Founder found the
  result inaccurate on page number, classes, mark name, owner and agency, and supplied issue 351 (A).
- Qatar's layout, read from issue 351 (A): PDF pages 1–4 cover, 5–14 index, entries from PDF page 16 (printed page
  1). One entry per mark; each entry page is headed by the class, the application number in brackets and the issue;
  the entry gives the picture, "قدم عنها الطلب رقم … بتاريخ …", the goods, "طالب التسجيل", the address and, under
  "عنوان المراسلة", the agent. Long goods lists run over several pages under the same heading. The file has a good
  text layer.
- Changes (migration 0065): the layout is data on the source (`fetch_spec.read`); a test with no first page starts
  at the first page of entries; the reader is told the layout, lists one entry per mark across pages, returns no
  marks for index pages, and gives the printed page number; the console shows the PDF page and the printed page.
- For the full reading stage this means: entries are grouped by application number across pages, not read page by
  page; the index gives the complete list of numbers, classes and pages to check the reading against.

## First true reading of entries, and translation by selection (staging, 21 Nov 2026)

- Qatar 352 (A), PDF pages 17–21, Sonnet 5.5: five entries read. Checked against the file's own text: all five
  numbers, filing dates, classes, applicants and agents agree, except one letter in one applicant name (the file
  prints "ئي.إل.إف", the reader gave "ثي.إل.إف") and the agent's city being joined to the agent's name. The reader
  now returns the city separately.
- Issue 352 stores its Arabic in presentation forms, issue 351 in plain letters; the start-finding compares both.
- Founder's question: can the Arabic information be shown in other languages, by selection? A reading test can now
  name one language: the reader adds the applicant and agent names in that script, the goods translated and the
  meaning of the mark's wording, beside what is printed and never in place of it; shown marked "≈".
- RULING NEEDED for the product: which fields are translated (proposed: goods, and names written in the viewer's
  script; never the mark itself), into which languages, whether at reading time or on request, and the wording of
  the notice that the registry's own text is the official one.

## Founder ruling 21 Nov 2026: published information is shown in the user's language

"An agency or owner in Türkiye receives Meesam in Turkish with all information in the same language unless he
requested otherwise."

- Which fields: all the published information (goods and services, owner, agent, addresses, notes).
- Which languages: the user's own language selection (the language Meesam is shown in for that user), unless the
  user asks for another.
- When: by the user's selection, so a translation is made when a user in that language needs it (an alert sent to
  him, a mark he opens) and kept, so it is made once per mark and language.
- The registry's own wording is always kept and shown with the translation; a translation never replaces it in the
  data, in matching or in deadlines.
- Notice shown with a translation (ruled 21 Nov 2026): "Translated by Meesam for your convenience. The registry's own
  text is the official one." Arabic: "ترجمة من ميسم لتيسير القراءة. النص الرسمي هو نص مكتب التسجيل."
- Turkish as a Meesam language: left until the Founder evaluates how soon it is needed (21 Nov 2026).
- The mark's own wording is never translated (ruled 21 Nov 2026: "No need to translate the trademarks, they stay as
  they are").
- RULING NEEDED (asked 21 Nov 2026, not yet answered): whether a user may switch translations off.
- Depends on: the user's language being available in Meesam (English and Arabic today; Turkish and others are added
  as data, plan item after launch), and on the re-use register allowing "show" for the registry.
- Not in scope of this ruling: what an account enters itself stays as entered.

## 21 Nov 2026 — Reading a whole issue (plan item A1; migration 0067)

- Founder ruling: while testing, a whole issue is sent to the AI reader "at once" (results in minutes, full price);
  batch sending (half price, slower) is for later, when the reading runs nightly.
- The watch operations lead asks for a stored issue to be read in full (Operations Console, Reading). The worker
  finds the pages where entries begin from the file's own text (the registry's pattern, `fetch_spec.read.entry_start`),
  cuts the issue at those pages into parts of a few pages, sends each part to the reader, and stores every mark as
  `ai_extracted`: waiting for verification. A mark in that state reaches no account, no match and no alert.
- Where the registry prints an index before its entries (`fetch_spec.read.index = before_entries`; Qatar), the index
  is read too and compared: numbers in the index that were not read, numbers read that the index does not list,
  classes that differ, pages that could not be read.
- Spending: a run stops itself at a size ceiling (3,000,000 tokens by default), when the provider refuses the key or
  the account has no credit; the lead can stop it; at most six whole issues a day. A mark read again is brought up to
  date, never stored twice; a mark a person has verified is never changed by a reading.
- Checked against the two Qatar issues supplied by the Founder, with a stand-in reader: issue 351 (A) has 215 entries
  and 215 index rows; issue 352 (A) has 255 and 255. The real reader has not yet read a whole issue.
- Not yet built: the reviewer's queue (plan item A2), the picture of each mark cut out of the page (needed for the
  image comparison in A4), the opposition deadline on each published mark, layouts of registries other than Qatar.
- RULING NEEDED: when a whole issue is read again after some of its marks were verified, verified marks are kept as
  they are (the narrowest reading); whether a later reading may ever reopen a verified mark is not ruled.

## 21 Nov 2026 — First whole issue read on staging; the reviewer's queue (plan item A2; migration 0068)

- Staging, 21 Nov 2026: Qatar issue 352 (A) read in full with Sonnet 5.5 in 613 seconds: 59 parts, 255 marks stored,
  779,903 tokens sent and 173,481 received; the reading agreed with the registry's index (all 255 numbers, each in
  the class the index gives). The index comparison covers numbers and classes only; names and wording are checked by
  the reviewer.
- Reviewer's queue (Operations Console, Verify marks): a publication reviewer or the watch operations lead sees one
  mark at a time, what was read beside the gazette page, corrects what differs and confirms, or removes something
  that is not a mark (reason required). Only a confirmed mark is matched to trademarks. What the reader gave is kept
  beside each correction, so the reader's accuracy can be measured per registry; both actions are audited.
- The gazette page(s) of each mark are cut out of the issue by the worker and kept beside the issue in the
  publications bucket (`<issue key>.pages/p<from>-<to>.pdf`); a long entry is shown as its first two and last two pages.
- RULING NEEDED: (1) marks are verified one by one (the narrowest reading of "human verification stays on"); whether
  a reviewer may confirm several marks at once, for example all marks the reader was very sure of, is not ruled;
  (2) whether a verified mark may be reopened and corrected later, and by whom.

## 21 Nov 2026 — Compare and alert, first engine (plan item A4; migration 0069)

- Engine "text-1" compares wording only: spelling per script (words that only state the legal form stripped), sound
  (consonant skeleton per script) and Arabic against Latin by sound. The strongest counts in full; sound weighs 0.9,
  cross-script sound 0.85, "one wording contained in the other" 0.85. The class is a gate and a weight: same class 1,
  related class 0.75 (ruling R6), none = outside the classes (kept only at High, no alert). Bands: High 0.85, Medium
  0.70, floor 0.55. All of these are configuration (`watch.engine_config`, `watch.threshold`), not code.
- When: a mark is compared when a person verifies it; a trademark is compared with what is already published when it
  is added or its wording, classes, registries or payment state change (backfill); a registry is compared again when
  its re-use entry starts to allow showing.
- Alerts: one per account that holds the trademark and per registry, never merged or shared. The deadline is computed
  only from a verified opposition period in the registry profile; otherwise the account enters it before marking the
  alert reviewed. The account's own publication (same application number, or its own name as applicant) is not an
  alert. Account actions: reviewed, opposition recorded, dismissed with a reason, back to new; all audited.
- Re-use register: nothing is compared where "derive" is refused; an alert is raised only where "show" is allowed
  (the narrowest reading of the open point on enforcing the register's uses; consistent with the "Registry shows" note).
- E-mail: new alerts once per user of the account; reminders while an alert is still new, on the days given by the
  registry profile (`watch_alert_reminders_days`) or, where absent, the engine settings (10 and 3).
- Pages: Watch alerts (owner and agency), with the trademark beside the published mark, the reasons in plain
  descriptive words in both languages, and the measured likeness.
- Not in this engine: meaning and image comparison (they need the embeddings service and the picture of each mark cut
  out of the page), goods wording, the "other matches" and "outside your classes" lists on the trademark page, the
  Watch tab (scope per registry; today a trademark is watched in its own registry), the pending-issue banner, the
  retrospective report, translation of published information into the user's language, forwarding to the agency.
- RULING NEEDED: (1) the weights above are an engineering starting point; (2) no registry has a related-classes table
  yet, so today only the same class counts until a table is entered per registry; (3) how far back to compare where a
  registry's opposition period is unverified or unknown (90 days is configured); (4) the PRD says one alert with one
  shared status for a trademark under several accounts, while the rules say alerts are never shared between accounts:
  built per account, each with its own status; (5) whether an instructing office may act on an alert or only read it.

## 21 Nov 2026 — Watch tab and comparison summary (migration 0070)

- Trademark page, Watch tab: the registries the trademark is watched in (its own, plus any "watch-only" registry the
  holding account adds from those Meesam reads), with the alerts of that trademark. Adding a registry compares the
  trademark with what that registry has already published. The price of a watch-only registry is shown from the
  price list; nothing is charged in the pilot.
- "Watched" now means in the watch (paid, or free while the pilot is free), on the Watch tab and in the portfolio list.
- Operations Console, Verify marks: per issue, how many verified marks were compared, how many matches were kept, how
  many alerts were raised, and how many are held back by the re-use register. Counts only; no account is named.
- Deadlines: Qatar's own gazette uses its verified 60-day period. Qatar's Madrid gazette is marked "date basis
  unconfirmed", so its alerts carry no computed deadline (ruling R7 read as applying to the Madrid gazette, the open
  question of migration 0049). RULING NEEDED: confirm this reading, or hold every Qatar deadline.

## 21 Nov 2026 — Two-step sign-in secrets sealed under their own key (ruling R13; migration 0071)

- The web service encrypts each authenticator secret before storing it (AES-256-GCM) under `TWO_FACTOR_KEY`, a
  configuration value of the web service only, at least 32 characters, apart from the database and from `AUTH_SECRET`.
  A copy of the database alone no longer gives the means to produce sign-in codes.
- Secrets stored before the key existed stay usable and are sealed the next time their owner signs in with a code.
- While `TWO_FACTOR_KEY` is not set, secrets are stored unsealed as before (staging keeps working). It must be set on
  production before launch. The key is set once and never changed: changing or losing it locks every authenticator
  out until each user sets one up again (e-mail codes still work for accounts that use them).

## 21 Nov 2026 — Sign-in limits review (plan item A7; migration 0072)

- Already in place: 8 failed sign-ins per e-mail address in 15 minutes; 6 tries per two-step challenge; password
  rules; the same answer whether or not an address has an account.
- Found and closed: no limit per network address (now 40 failed sign-ins in 15 minutes from one address, across all
  e-mail addresses); no limit on "forgot password" and "send the link again" (now 3 e-mails an hour to one address
  and 10 an hour from one network address; the page answers in the same words either way); no limit on "create
  account" (now 6 an hour from one network address).
- Still open: a rate-limit rule at Cloudflare in front of the site (a second line, set in Cloudflare, not in code),
  and error monitoring (RULING NEEDED: an outside service such as Sentry, which receives error details, or a page
  inside Meesam System Admin).

## 21 Nov 2026 — Publications under review shown on the Watch alerts page (PRD Section 8.5; migration 0073)

- An account sees, for the registries it watches, each publication that is received but not yet read, or read but
  not fully verified: registry, issue, date and counts only. No mark is shown before a person has verified it.

## 22 Nov 2026 — Founder's first pass through the reviewer's queue; cost of one Qatar issue (migration 0074)

- Cost measured in the Claude Console: USD 3.72 in all for 844,377 tokens sent and 203,171 received, of which the
  whole reading of Qatar 352 (A) was 779,903 and 173,481: about USD 3.50 for one issue of 255 marks with the goods
  shortened to 200 characters.
- Founder: "Goods or services can not be corrected and the list shortened"; "Arrange the above spaces to manage the
  whole list". Done: the reader now gives the goods in full (up to 3,000 characters per mark; a longer list ends
  with " …"); the reviewer corrects the goods and the applicant's address; the short fields share rows so the list
  has room. Issues read before this keep their shortened lists until read again.
- Founder: a Latin code inside an Arabic address was read reversed (page shows "JP12AL", read as "AL12JP"). The
  reader is now told to copy such codes as printed on the page and not from the file's hidden text layer. To be
  watched on the next reading; the address is correctable in the queue either way.
- A reply cut at the length limit no longer passes as read: the part is asked again with the goods shortened.
- Expected effect on cost: full goods lists mean more text received, so one Qatar issue is expected to cost about
  USD 6 to 8 instead of 3.50 (an estimate until the next reading shows the figure).

## 22 Nov 2026 — Reading some pages of an issue (migration 0075)

- Founder: issue 352 (A) keeps its 255 marks as read (shortened goods); the changes to the reviewer's queue are
  verified and working; the watch is to be tested with real cases of the brand "oro selekt" (one publication in the
  UAE, two in Türkiye).
- For that, the lead can read only a range of PDF pages of a stored issue. The marks on those pages are stored
  waiting for verification like any others. Where a registry's layout is not entered (UAE, Türkiye today), up to 12
  pages can be read at a time. A reading of some pages is not compared with the registry's index.

## 22 Nov 2026 — Fault found and fixed before the watch test (migration 0076)

- Price List v1.0 takes effect on 2 Dec 2026. Until then no list is "in effect" by date, and the function that
  decides whether a trademark is watched (migration 0069) did not fall back to the newest list as the pricing engine
  does. Effect: before 2 Dec an unpaid trademark was not watched, so no alert would have been raised for it, although
  the pilot is free. Fixed: one function gives the list in force to both; trademarks skipped for this reason are
  queued for comparing.

## 22 Nov 2026 — Pricing, Help and Feedback pages (plan item A6; rulings R10 and R11; migration 0077)

- Public Pricing page (`/pricing`): list price and introductory price by years left, with the UAE VAT-inclusive
  figure, the filing fee for a new mark, the flat price per additional or watch-only registry, the price per class
  added. Every figure is read from the price list in force; none is written in the page. Stated as open, in plain
  words: the renewal price and the end of the introductory offer. While the pilot is free the page says so.
- Help page (`/help`): eleven short questions and answers in both languages, written from the rules in force
  (what Meesam is and is not, what one fee covers, how deadlines are computed, how the watch works and what it can
  miss, data, languages, support for technical and payment matters only). The wording is the builder's and awaits
  the Founder's reading; it is not in the Home Page Content document.
- Feedback (`/feedback`, signed-in users): a form stored with the account and user of the session, at most ten an
  hour per account; read in Meesam System Admin, Feedback. It is not a support channel.
- Footer on every page: Help, Feedback, Contact (info@meesam.ae). Home page Block 7 now links to the prices.
- Still open for these pages: pilot terms (P1–P8), the list's effective date, the introductory offer's end date.

## 22 Nov 2026 — Collection by hand takes the bulletin's PDF from inside the registry's archive

- Found in the Founder's UAE watch test: the UAE bulletin is published as a .rar holding several PDFs ("Publication
  of accepted marks", renewals, transfers and others). The Founder had the unpacked PDFs, not the archive, and the
  inbox refused the PDF as "not what this registry publishes".
- Now, for a source switched to "collected by hand" whose registry publishes an archive, the watch operations lead
  may add the bulletin's PDF taken out of that archive. It is checked as a PDF, stored once and recorded as a PDF.
  Same source, same role, same audience as the ruling of 19 Nov 2026; only the form of the file differs.
- RULING NEEDED: confirm this reading of the temporary exception (rule 7), or require the registry's archive itself.

## 22 Nov 2026 — The watch after the first real case (Founder rulings; migrations 0078 and 0079)

- Real case: "ORO LABS", class 32, UAE bulletin 350 of 15 Sept 2026, against the Founder's "oro selekt", class 35.
  Under the first engine it scored 51% and was not kept, and class 32 was outside class 35.
- Founder rulings (they replace the class gate and the three bands of MSM-PRD-02 Sections 6 and 7, and ruling R6;
  the PRD document is to be updated to match):
  1. A shared whole word counts: 80% when it is the first word of both marks, 70% otherwise.
  2. Small words are skipped when words are compared ("the", "a", "an", "and", "of", "la", "le", "les", "el", "los",
     "las", "il", "lo", "de", "du", "di", "der", "die", "das"; Arabic "و" and the attached "ال").
  3. "Let's keep the classes out of the watch, the watch mentions the classes and the agency or the owner decide":
     the class is information on the alert (same class or different classes), never a gate or a weight. Same-class
     alerts are listed first and can be filtered. Related-class tables are no longer needed.
  4. Four bands with names and colours: Very high 90–100, High 80–89, Medium 60–79, Low 40–59; under 40 is not kept.
     Very high, High and Medium raise an alert and an e-mail; Low is listed on the trademark's Watch tab only, the
     closest 20 per issue, same class first.
  5. "The watch system will be modified based on the agencies' feedback later": every figure is a setting.
- With these rules: "ORO LABS" 80% (High), the Turkish "oro" 85% (High), both against "oro selekt".
- Known effect, told to the Founder: Medium (60–79) includes names two letters apart from a six-letter name
  (for example "SEESAW" against "MEESAM", 67%), and each one sends an e-mail. To be watched in the pilot.
- Collection by hand: the Turkish bulletin 495 is 576 MB (3,758 pages), above the 120 MB limit of the inbox form.
  For the staging test an extract of six pages was cut on the Founder's computer. Large issues need the downloader
  or a larger upload path; not built.

## 22 Nov 2026 — Translation, large files, self-refreshing pages (migration 0080)

- Founder, testing the Turkish bulletin: "No translation done, at least to English". Built: a translation of the
  applicant, address, agent, goods and picture description is made by the AI reader (Haiku 5.5 by default,
  `AI_TRANSLATE_MODEL`) and kept beside the published mark per language. In the reviewer's queue a button asks for
  it in the page's language; when an alert is raised it is made automatically in the languages of the account's
  users and shown under the registry's text with the ruled notice. The mark's wording is never sent or translated.
- "Why every time I have to refresh the page?": the Reading pages refresh themselves while a reading runs, and the
  reviewer's page while a translation is being made.
- "It's taking longer than supposed": the six Turkish pages held 20 marks with very long goods lists; the first
  reply was cut at the length limit and the part was asked again with the goods shortened (two requests, 164 s).
  The length limit of a reading part is raised from 16,000 to 28,000 tokens.
- Large files: the 576 MB Turkish bulletin stopped the web service (error 502). The inbox now refuses a file above
  120 MB before reading it, with a plain message. RULING NEEDED / planned work for large registries: (1) such files
  must come by the automatic downloader, straight into storage; (2) a Turkish bulletin has about 3,750 pages and
  roughly 11,000 marks: reading it with AI would cost in the order of hundreds of US dollars per issue, so
  registries that print coded, regular entries (Türkiye uses the INID codes (210), (511), (540), (731)) should be
  read by rules from the file's own text, with AI only for the mark's picture and unclear entries.

## 22 Nov 2026 — Reading by printed codes (Türkiye), why no alert showed, translation under the fields (migration 0081)

- Founder ruling: "For the reading of the Turkish bulletin, I agree" (read large registries by rules, not by AI).
  Built: `apps/worker/src/watch/codes.ts` reads a bulletin from the file's own text, word by word with each word's
  place on the page (`pdftotext -bbox`): an entry runs from its (210) line to the next; (220) date, (731) applicant
  (customer number, name, country, address; several applicants), "Vekil:" agent, (540) wording, (531) figure
  classes, (511) classes, (510) goods, "Çıkarılan Mal/Hizmetler:" (goods taken out, kept under that label). The
  contents page gives the sections; those titled "… İlan Edildiği Bölüm" are read. All of this is data on the source.
- Checked on the Founder's computer against bulletin 495 (576 MB, 3,756 pages): 8,405 entries in about 33 seconds;
  national 8,052, Madrid 294, re-examination board 46 and 13; in each section the numbers read are exactly the
  numbers in the office's own list; every entry has its number, applicant, classes and goods; 203 have more than
  one applicant; 135 are figure only ("şekil"), plus sound, motion and three-dimensional marks. No AI, no cost.
- The marks still wait for a person (rule 7). RULING NEEDED: whether a mark read by rules, complete and present in
  the office's own list, needs a person at all (8,405 marks per issue cannot be confirmed one by one).
- A mark's gazette page is cut out when a reviewer opens it (and for the next 25 marks), not for all 8,405 at once.
- Not built: the picture of the mark is not cut out yet; getting a file above 120 MB into storage needs the
  downloader (Türkiye's is configured, off until re-use is confirmed; its size limit is 1.5 GB) or a larger upload path.
- "I'm waiting for the alerts": no alert was raised because (UAE) "Show" is not Yes in the re-use register, so the
  match was held back, and (Türkiye) no trademark watches Türkiye. The console did not say so: the count of held
  matches missed a match whose "own publication" test was left unknown (an account name in one script only). Fixed;
  the Verify marks page now shows watched trademarks per registry, held and low matches, and "Compare again" (lead),
  which compares an issue whatever its date (a trademark added to a registry later is otherwise compared only with
  publications inside the opposition period).
- Translation (Founder: why separate and by request; Arabic not accurate): it is now asked for when a mark is opened
  (and for the next two), and shown in its own box under each field; it arrives without reloading the page. Rules,
  second version: goods are translated; a name or address is left as printed (given in Latin letters only where it
  is printed in another script and the reader's language uses Latin letters). RULING NEEDED: whether names should
  also be given in Arabic letters for Arabic readers.
- Language switch: it went to the area's first page; it now stays on the same page and item (all three areas).

## 22 Nov 2026 — First full run on staging; rulings after the watch test (migration 0082)

- Watch test passed on staging: "ORO LABS" (UAE 350) 80% High and the Turkish "oro" (495) 85% High against "oro selekt",
  in the app and by e-mail, one alert per account that holds the trademark. Türkiye had to be added on the trademark's
  Watch tab and the issues compared again.
- Türkiye's bulletin 504 read by rules on staging: 2,966 pages, 6,691 marks, 131 seconds, no AI, equal to the office's list.
- Founder rulings: (1) marks read by rules need no person ("preferably NO"): complete and listed marks are accepted,
  incomplete ones wait; a setting per source. (2) Names are not given in Arabic letters for Arabic readers. (3) Alerts are
  raised also when the opposition period has ended; the owner decides. A trademark added to a registry later is compared
  with the last 365 days of that registry's publications (setting `backfill_days`).
- Fixed from his test: the alert e-mail said "(-38 days left)" (now "the period has ended"); the alert showed the
  trademark's UAE number under "TR" (now its own registry, with "watched in TR"); pages that refresh themselves pulled the
  reader back after he left them (now only the page's data is read again, and only while he is on it); the issues table
  scrolled sideways.
- Reported by him, not reproduced: a wrong password led to the six-digit step. The sign-in route refuses a wrong password
  before the second step; a second step left open by an earlier correct attempt is now dropped on a failed attempt.

## 22 Nov 2026 — Alerts of bulletin 504 analysed; the e-mail names the marks; weak matches are Low (migration 0083)

- Bulletin 504 (6,691 marks) raised three alerts for "oro selekt": "oro vicenza jewellery" and "oro isso" (80%, High, same
  class 35) and "er pelet" (60%, Medium, no shared word, shown without a reason).
- Founder rulings: (1) the alert e-mail lists each mark: wording, registry, likeness, band, same or different class;
  (2) "a sound-only match below 80% becomes Low".
- Correction to what the Founder was told: "er pelet" scored 60% on spelling (four letters apart in ten), not on sound.
  The ruled rule is applied to both: sound alone alerts from 80%, spelling alone from 70%; under that the match is capped
  at 59% (Low: listed, no alert, no e-mail). Ruled 22 Nov 2026 ("Agree on the 70%"): 70% for spelling alone. The Founder also allowed the build to be moved to production once his Railway steps are done.
- A match always carries its reason. An alert nobody acted on whose match is now Low is withdrawn.
- Founder ruling 22 Nov 2026: "d'oro" is read as "oro". Checked: Meesam already did this (an apostrophe separates words
  when a name is normalised), so "argos d'oro olive" scores 70% (Medium) against "oro selekt"; the Founder had been told
  it was not matched, which was wrong. Nothing to build; a test now holds the behaviour.

## 23 Nov 2026 — Sign-up closed in production until launch; the build moves to `main`

- Founder ruling 23 Nov 2026 ("Keep sign-up closed until we get ready"): production does not take new accounts before
  launch. A configuration value on the web service, `SIGNUP`: `open` lets anyone register; unset or anything else shows
  "Meesam opens soon" in place of the sign-up pages and the register route stores nothing. Closed is the default, so a
  new environment never opens by oversight. Signing in, password reset, staff logins and invitations into an existing
  account are not affected. Staging needs `SIGNUP=open`; production gets it on the day the Founder opens.
- The production Railway services (web-prod, worker-prod: branch `main`, Wait for CI, pre-deploy migrations) were set
  up by the Founder and their variable names checked; `develop` is moved to `main` with this change.

## 23 Nov 2026 — Production is up (meesam.ae), sign-up closed

- `main` carries the build; web-prod and worker-prod deployed, migrations applied on the production database, the
  first System Administrator signed in, e-mail delivered, and the first second copy made and restored
  (183 tables) in the production backup bucket.
- Lessons from the set-up, kept so they are not met twice:
  - Several production variables had been filled with a description of the value instead of the value. Every
    link-type or key-type variable is now checked by `/api/health/ready` (database and link settings; names and an
    error code only, never a value), and Forgot password and the first-administrator step write what they did to
    the log (never the address).
  - A reference to another service's variable (`${{Postgres.DATABASE_URL}}`, `${{<bucket>.ENDPOINT}}`) resolves
    only when set on the service itself; inside a shared variable it comes out empty. The database links and the
    eight `VAULT_…` / `PUBLICATIONS_…` values are therefore set on web-prod and worker-prod directly, as on staging.
  - The e-mail provider's free plan (100 a month) was used up by staging; the account is now on a paid plan.
  - A first administrator whose invitation e-mail failed gets it again from Forgot password.
- Open: web-prod still connects to Postgres directly; it moves to PgBouncer (`${{PgBouncer.DATABASE_POOL_URL}}`,
  on the service) before launch. `AUTH_SECRET` is not read by the code today.

## 23 Nov 2026 — Two-step sign-in: a code to scan, sign-in after an invitation, and the question put once

Founder rulings 23 Nov 2026:
- **A QR code** on the authenticator set-up (Account → Two-step sign-in). Meesam draws it itself (`apps/web/lib/qr.ts`,
  no outside service or library: the set-up key leaves Meesam for no one). The key to type stays beneath it, and a
  small link for a person setting up on the same phone.
- **After an invitation, everyone signs in.** Setting a password from an invitation no longer opens a session; the
  person goes to the log-in page, so a second step that applies to them is asked from the first entry.
- **Asked after signing in, with "Don't ask me again"** (migrations 0084, 0085; second ruling of the day): every
  login, existing or new, without an authenticator app is asked at each sign-in whether to use two-step sign-in and
  how — a code by e-mail, an authenticator app, or (customers only) not now. Ticking "Don't ask me again" ends the
  question for that login; the choice stays changeable under Account. Staff are asked only which way, since their
  second step is always on. "Not now" changes nothing for the login.
- **App or e-mail, never both** (Founder, 23 Nov 2026): a login with an authenticator app is asked for the app's
  code and no e-mail is sent; the e-mail code goes only to a login without the app. The on-request button
  "Send me a code by e-mail instead" (lost or flat phone) is kept, to be reviewed during the first period of the pilot.
- **The name of the authenticator entry is a setting** (`TWO_FACTOR_ISSUER` on the web service; Founder ruling
  24 Nov 2026): production keeps "Meesam" (unset), staging sets "Meesam Staging", so the two entries for one
  address are told apart in the app.

## 24 Nov 2026 — System check for the System Administrator

- `/api/admin/check` (System Administrators only; others get "not found"): one line each for the database, the
  documents and publications buckets (a small file written, read back and removed), the e-mail and AI providers
  (is the key accepted; nothing sent, nothing paid), and whether the sender address, the two-step key and the
  first-administrator list are set. "ok" or a short reason; never a value. Built after the production set-up of
  23 Nov, where several settings held a description instead of a value.
- web-prod now connects through PgBouncer (`${{PgBouncer.DATABASE_POOL_URL}}`, set on the service), confirmed by
  `/api/health/ready`.

## 24 Nov 2026 — An owner invites an agency; the certificate reader made robust

- **An owner invites an agency by e-mail** (Founder ruling 24 Nov 2026; migration 0086, the mirror of the agency's
  invitation of an owner, 0026). Owner → Agencies → "Invite your agency": an agency office already on Meesam receives
  the appointment request; an unknown address receives a link to open an agency account, and the request reaches the
  office when it is verified. The owner then names the trademarks on the appointment.
  `RULING NEEDED: may an invited address open an account while sign-up is closed (SIGNUP)? Built: no — the invited agent sees "Meesam opens soon" until sign-up opens. The Founder will not send invitations before then.`
- **Certificate reader:** on production the reader's answer for a certificate could not be parsed ("Expected ',' or
  '}' … in JSON"): the answer was JSON written as text, and a quoted passage broke it. The answer is now asked for as
  the input of a tool, which the provider returns as a ready object; the text form stays as a fallback, and the
  failure message says why the reader stopped.
- Reading page: "Marks stored, waiting for verification" now reads "Marks stored" (marks read by rules do not wait).

## 24 Nov 2026 — The UAE bulletin is read by rules (plan item D2)

- **Examined:** bulletin 353 of 3 Nov 2026, an archive of eleven files, all made with a word processor with the
  text inside. Accepted marks (1,428 pages) and six kinds of change are printed on one two-column Arabic form with
  fixed labels; Madrid designations on an English form; registrations and renewals as tables. No list of the
  accepted numbers is printed, so there is nothing to check a reading against as there is for Türkiye.
- **Built (migration 0087, worker `labels.ts`, `read-labels.ts`, `arabic-order.ts`):** a second way of reading by
  rules, "labels", beside Türkiye's "codes". Every title, label, column place and table column is data on the
  source (`fetch_spec.read.forms`). Each file of the archive is told by the title on its first page.
- **Arabic letter order:** the file's text gives the joined letters "لا" the wrong way round after a word is
  turned to reading order. The worker reads a prepared copy in which this is put right (qpdf, already in the
  service); pages shown to a reviewer are still cut from the office's own file. Checked letter by letter against
  an independent reading on 123 pages: all identical.
- **Result on issue 353, read in under a minute:** 1,204 accepted marks, all complete, all numbers different;
  265 Madrid designations; 526 changes, licences and transfers; 978 registrations; 2,186 renewals.
- **Founder rulings 24 Nov 2026:** (C) a person verifies every UAE mark to begin with; the share found wrong is
  reported, and the Founder then decides whether complete marks skip the person (the setting `accept: complete`
  is ready, not switched on). (Scope 2) all parts are read now; the parts that publish no application are stored
  with their source in `watch.published_notice` and shown nowhere until their use is ruled.
- **Found:** a Madrid notice prints no wording, only the picture, so Madrid marks are stored but the word
  comparison has nothing to compare for them.
- `RULING NEEDED:` what Meesam does with the stored notices (who is told, how; whether a change of the mark or of
  the goods raises a watch alert).
- **Founder ruling 24 Nov 2026:** a Madrid mark keeps the prefix as part of its number ("IR <number>"), so it is
  never taken for a national application of the same number.
- `RULING NEEDED:` where the wording of a Madrid mark comes from (reading the picture, or another source by its
  international registration number).
- **An older issue checked the same day (bulletin 335, migration 0088):** accepted marks 2,104 pages, 1,747 marks,
  one incomplete; registrations read as they are. Two differences found and entered as settings: the Madrid form
  opened with another department name, and the issue carries a cancellations part. Issues 328 to 334 and 336 to
  352 are not checked; a part whose title no form knows is left unread and named in the worker's log.

## 24 Nov 2026 — Comparing marks as pictures: first step (the pictures are cut out)

- **Founder, 24 Nov 2026:** picture comparison is built now, the launch of 2 December is moved if it has to be;
  the monthly cost of the picture service must be known before the prices are made final. Order: (1) cut the
  picture of each mark out of the bulletin, (2) switch on the picture service, then compare and show.
- **Built (migration 0089, worker job `watch.mark_pictures`):** after a reading by labels the picture of each mark
  is taken out of the file as the office put it there and kept in the publications bucket beside the issue
  (`<issue>.marks/<part>-p<page>.png`); its key is noted on the mark. Which image is the mark comes from the
  source's settings (`fetch_spec.read.picture`). Bulletin 353: all 1,469 marks have a picture; 335: 1,743 of 1,747.
- The reviewer's queue now goes through the parts of an archive one after another (accepted marks, then Madrid),
  and names the file under the page shown.
- **Open before step 2:** the licence review of the picture models (Data Architecture 14.20) is not closed;
  `RULING NEEDED:` which models may be used commercially (DINOv3 is under its maker's own licence and its files
  are released only to an account that accepted it; SigLIP 2 is under Apache 2.0).
- Not yet: pictures for bulletins read by codes (Türkiye) and for the customers' own marks' images.

## 25 Nov 2026 — Comparing marks as pictures: second step (the picture service, SigLIP 2 alone)

- **Founder ruling 25 Nov 2026 ("A"):** the picture service starts with SigLIP 2 alone (Apache 2.0). DINOv3 is
  added when its licence is reviewed and accepted; until then the service refuses a request for it.
- **Built:** `apps/embeddings` loads `google/siglip2-base-patch16-224` (its files are put into the image at build;
  the running service fetches nothing), prepares every picture the same way (on white, padded to a square) and
  returns a vector of 768 numbers with the engine's full name and a 64-bit hash for exact copies. The worker job
  `watch.mark_embed` (after `watch.mark_pictures`) sends each mark's picture and keeps the vector (migration 0090).
  Without `EMBEDDINGS_URL` on the worker nothing is made and nothing fails.
- CI now runs the service with its real model (a word, the same word in another colour, a device, a text).
- **Railway:** a new service `embeddings` per environment, private network only (no public address).
  Memory and cost are to be measured on staging before the prices are made final.
- **DINOv3 licence, as read on 25 Nov 2026:** Meta's own "DINOv3 License": royalty-free use including commercial;
  conditions include showing "Built with DINOv3" where the materials are distributed, trade-control and
  prohibited-use clauses, an indemnity, California law, and Meta may change the terms. The files are released
  on Hugging Face to an account that filled in a form (name, date of birth, country, affiliation) and accepted.
  `RULING NEEDED:` accept the licence (after legal review) and which entity's account asks for the files.
- `RULING NEEDED:` how a picture score becomes a band and how it stands beside the word score (third step).
- The "Find a number" box on Verify marks now tells "already verified" from "not in this issue".

## 25 Nov 2026 — DINOv3 accepted and added to the picture service

- **Founder, 25 Nov 2026:** Meta's DINOv3 License is accepted. Access was asked from the company's Hugging Face
  account and granted the same day; one approval covers the 13 models of the DINOv3 group, the ViT-B/16 of our
  plan among them (`facebook/dinov3-vitb16-pretrain-lvd1689m`, 86 million parameters).
- **Built:** the picture service loads DINOv3 beside SigLIP 2 where its files are in the image. The files are
  fetched at build only where the service's `HF_TOKEN` variable is set (Railway, sealed; never in the repository);
  without it the service runs with SigLIP 2 alone and refuses a request for DINOv3. The worker keeps both vectors
  (migration 0091). CI tests DINOv3 where the repository holds the secret `HF_TOKEN`.
- **Licence condition noted:** "Built with DINOv3" is to be shown where the model is distributed.
  `RULING NEEDED:` where Meesam shows this line (the legal texts in the product are still to come).
- **Lesson, 25 Nov 2026:** the first build wrote the access key into a command, and Railway printed the command,
  key included, in the build log. The key was replaced the same day. The build now reads the key from the
  environment inside a script, in a stage of its own that is not part of the final image. A secret is never
  written in a Dockerfile command.

## 25 Nov 2026 — Picture fingerprints proven on staging; the look-alikes page

- **Proven on staging (bulletin 354):** read by rules in 30 seconds (1,247 marks, 1,483 notices); 1,231 pictures cut
  out, none missing; 1,247 marks fingerprinted by both models in about 13 minutes, none unopened.
- **Measured cost of the picture service:** 1.5 GB of memory with both models loaded (about USD 15 a month for
  each environment at Railway's rate), and about 2 processors for 13 minutes for a bulletin (one to two US cents).
  A fixed cost, not one that grows with marks or customers. To be looked at again after a week.
- **Built (migration 0092, Operations Console → Pictures):** for any mark of an issue, the ten marks of the same
  issue that each model finds nearest, with both models' figures. For judging the fingerprints on real marks
  before the Founder rules how a picture score becomes a band. Nothing there raises an alert.
- Still to come before pictures reach an alert: fingerprints of the customers' own mark pictures; the rulings on
  bands and on how the picture score stands beside the word score; showing it on the alert and the Watch tab.
- **Compare two pictures (25 Nov 2026):** on the same page staff can give two pictures and see each model's figure,
  for trying real cases (first one: a Saudi device mark and a later mark using a like frame). The pictures are not
  kept. The web service needs `EMBEDDINGS_URL` for this.

## 25 Nov 2026 — First real case tried on the picture models

- **The case (from an agent):** Saudi registration 1437014340 (a device: a cloud-edged frame with rays on maroon, no
  words, class 30) and the later Saudi mark SA 1443021824 (a like frame in gold with a factory name).
- **Figures (SigLIP 2 / DINOv3), the earlier mark against:** the later mark 69.0 / 49.0; a stock picture of the same
  idea (cloud frame, rays, pink) 77.3 / 47.7; two plain cloud logos 57.9 / 26.7 and 58.2 / 14.2; unrelated
  pictures 47.7 / -0.5 and 37.9 / 6.5.
- **Read:** both models put the real case above everything unrelated; DINOv3 separates more widely; neither tells a
  copied drawing from another drawing of the same idea, which for a watch is acceptable: a person decides.
- **Founder, 25 Nov 2026:** an alert is wanted at about that closeness (the stock picture too); the lines are to
  be improved over time. `RULING NEEDED:` the lines themselves, per model, and how the picture figure becomes one of
  the four bands. Built for that (migration 0093): on Pictures, the spread of nearest-picture figures in an issue.

## 25 Nov 2026 — A line cannot be read from pairs inside one bulletin

- **Measured on UAE bulletin 354 (staging, the spread table):** almost every mark has a very near neighbour in the
  same bulletin. By SigLIP 2, 99% of marks have another picture at 60 or nearer, 86% at 70, 32% at 80, 11% at 90.
  By DINOv3, 94% at 50 or nearer, 86% at 60, 67% at 70, 47% at 80, 23% at 90. Likely reasons (not yet checked mark
  by mark): most pictures are plain words on white, which the models see as alike, and one applicant often files
  several forms of one mark in the same bulletin.
- **What it means:** the figures of the first real case (69.0 / 49.0) cannot be used as a line between the marks of
  a bulletin; the table answers "does a bulletin contain near pairs", not "how many pictures of a bulletin come
  near one customer's mark", which is what the watch asks.
- **Built (migration 0094, Pictures page of an issue, "One picture against this issue"):** staff give one picture;
  the page shows the ten nearest pictures of the issue by each model and how many pictures stand at each step of
  ten. The picture and its fingerprints are not kept. The same picture printed for several classes counts once.
- `RULING NEEDED:` the picture lines per model, after this tool has been run with the real case and with ten to
  twenty known pairs; and whether word-only pictures are compared as pictures at all or left to the word score.

## 26 Nov 2026 — Lettered marks, and the Founder's direction on kinds of mark

- **Two more tries on bulletin 354:** a word-only mark and a lettered logo come near hundreds of pictures by DINOv3
  (308 and 259 pictures at 40 or nearer; 8 and 30 at 60 or nearer); the picture-only mark of the real case came
  near none above 30. One fixed line cannot serve every kind of mark. Measured against each mark's own usual
  level, the real case stands out by about 6 to 7 spreads, the nearest pictures of the two lettered marks by
  under 3 (estimates from the ten-point bands).
- **Founder's direction (26 Nov 2026, to be confirmed as a ruling):** Meesam compares by kind of mark: word mark;
  picture mark or device; word mark with a device; picture with wording inside or linked to it.
- **Founder, 26 Nov 2026:** a note states that the trademarks belong to their registered owners. Added on the
  Operations Console Pictures pages (`ops.pictures.ownership`). `RULING NEEDED:` the wording, and where else it is
  shown (alerts, the Watch tab, the public site, the legal texts).
- Older publications are brought by the fetchers (rule 7), source by source and within each registry's re-use
  terms; no upload by a person.

## 26 Nov 2026 — Founder directions on pictures, kinds of mark and the ownership note

- **Ruling (Founder, 26 Nov 2026):** the note "Trademarks shown in Meesam belong to their registered owners" is on
  every page of Meesam that can show a trademark. Built as one line in every page footer (`footer.trademarks`):
  the public home page, the sign-in pages, the account area, the Operations Console and System Admin. It replaces
  the Pictures-only note of the same day. **Discrepancy to settle:** "Home Page Content" Block 9 does not carry
  this line yet; the document should be amended. `RULING NEEDED:` whether the alert e-mails and the legal texts
  carry it too.
- **Direction:** Meesam keeps learning further methods of comparison; the goal is a model trained on Meesam's own
  data, its cost to be estimated and managed. Not a change to the ruled architecture until a costed plan is ruled.
- **Kinds of mark:** the Founder's four kinds are his own wording; the standard list is the kind of mark of WIPO
  ST.96 (word, figurative, combined, and the non-traditional kinds). `RULING NEEDED:` adopt the standard names,
  with the Founder's "word with device" and "picture with wording" kept as two forms of "combined".
- **Publications from sites closed to the fetcher:** received by e-mail outside Meesam and added by the watch
  operations lead in the console for a source switched to "collected by hand": this is the exception of rule 7
  as ruled 19 Nov 2026, not a widening. An intake that reads the mailbox by itself would be new and needs a ruling.
- **Built:** the exact "stands out" figures on "One picture against this issue" (migration 0095).

## 26 Nov 2026 — Ownership note in e-mails; kinds of mark; publications by e-mail (trial); stand-out on lettered marks

- **Ruling (Founder, 26 Nov 2026):** the ownership note is also in the alert e-mails (built) and in the legal
  texts. The legal texts are generated from the documents of record (`docs/03-legal`), so the sentence is added
  by amending the document and regenerating, not in code. Proposed for the Terms of Use, Section 11.2: "Trademarks
  shown in Meesam, including those in registry publications and in alerts, belong to their registered owners."
  `RULING NEEDED:` the wording, and the new version of the Terms of Use.
- **Ruling (Founder, 26 Nov 2026):** the Founder's four kinds of mark are kept (word mark; picture mark or device;
  word mark with a device; picture with wording inside or linked to it) and linked to the standard kind of mark
  (WIPO ST.96) when a user enters the certificate details or when Meesam reads the mark; Vienna Classification
  codes are kept where a publication or certificate prints them. Not built yet.
- **Trial on staging (Founder, 26 Nov 2026; he rules after trying it):** publications received by e-mail
  (migration 0096; `/api/inbound/publications`; Publications inbox, "Received by e-mail"). A file waits until the
  watch operations lead adds it to a source collected by hand, through the same checks as a file added by hand,
  or discards it. Off wherever `INBOUND_MAIL_KEY` is unset; must stay unset on production until ruled. The
  provider's inbound limit is 35 MB for all attachments of a message, so the UAE archive (45 MB) cannot arrive
  this way and is added in the console as now.
- **Measured (exact, bulletin 354):** OnePlus logo by DINOv3: usual level 30.6, spread 16.1; Soup & Salad: 34.0
  and 11.6. For OnePlus even an identical picture (100) stands out by only 4.3 spreads, so the "4 to 5 spreads"
  line suggested on 26 Nov does not work for lettered marks. To try next: the usual level measured against
  pictures of the same kind only, and a rank measure (among the nearest few and clear of the rest).
- **Direction:** a cost report is given whenever real cost data exists (training a model included).

## 26 Nov 2026 — Terms of Use v0.2 (draft) published to the legal pages

- **Founder, 26 Nov 2026 ("legal wording agreed", "publish v0.2"):** Terms of Use, Section 11.2 gains "Trademarks
  shown in Meesam, including those in registry publications and in alerts, belong to their registered owners."
  The document of record is `docs/03-legal/MSM — Terms of Use v0.2 (draft, 2026-11-26).pdf`; v0.1 is kept beside
  it as history. The legal pages were regenerated; `infra/tools/legal2md.py` now reads the newest version of each
  document, and the version recorded with an acceptance is that of the newest document (`v0.2-draft-2026-11-26`).
  Still a draft awaiting the lawyer's review. `RULING NEEDED:` whether people who accepted v0.1 are asked to
  accept again when a new version is released on production.
- Publications by e-mail proven on staging the same day: a bulletin sent to the publications address was held,
  and added by the lead to Egypt (switched to collected by hand). The mail provider's inbound feature needed its
  Pro plan (the Founder upgraded; the monthly price is to be added to the cost picture).

## 26 Nov 2026 — Kinds of mark, first piece (published UAE marks, by rules)

- **Built (migrations 0097, 0098):** the Founder's four kinds as data (`core.mark_kind`), each linked to the
  standard kind; the kind of a published mark worked out by rules from the registry's own wording and description
  (the UAE form's "وصف العلامة"), with the word lists as data on the source (`fetch_spec.read.kind`); shown on the
  Pictures page with counts per kind and a way to open marks of one kind; "One picture against this issue" can
  measure a picture against marks of its own kind only.
- **On bulletin 353 (1,204 accepted marks, local run):** word 613, word with device 383, picture with wording 178,
  device 11, no kind 19 (no description printed). From reading samples of the descriptions, roughly one in four
  looks wrong (a drawing described in words the lists do not hold; "inside" taken too broadly). The pictures
  themselves were not looked at. The rules are a first attempt for the Founder to judge.
- `RULING NEEDED:` what separates "word mark with a device" from "picture with wording inside or linked to it"
  (the rule used: the description says the lettering is inside or within the drawing).
- **Not built yet:** the kind on customers' own marks at entry (they hold the standard three today,
  `core.mark_type`); Vienna codes; a check of the kind against the picture itself.

## 26 Nov 2026 — Egypt: the gazette examined (issue 1035, the part "publication of accepted marks")

- **The file** (received by e-mail, 434 pages, 11.8 MB): made with a word processor, the text inside; one mark to
  a page (426 marks; 8 pages continue a long list of goods), each page with one picture of the mark over the
  office's watermark. Printed per mark: application number (seven digits), filing date, applicant, address,
  class numbers, goods by class, and conditions on about a third. **No wording of the mark is printed, no agent
  and no description**: the mark is the picture only.
- **Readable by rules:** yes. The preparation and the line reading built for the UAE give clean lines on this file
  without change (tried on the whole file). Still to build: the form's settings for Egypt, a rule for the class
  line and the goods that stand around the "فئات العلامة" label, the watermark left out of the pictures, and the
  issue number taken from the foot of the page.
- **Consequences:** with no wording printed, the word comparison has nothing to compare for Egypt; a watch there
  rests on the picture, or on wording read off the picture by another means (not built).
- **Re-use:** every page carries the notice "لا يجوز التعامل مع هذا الملف أو أي جزء منه بالنقل أو النسخ أو التعديل أو
  النشر أو إعادة الطبع" (no dealing with this file or any part of it by transfer, copying, alteration, publication
  or reprinting). The re-use register for Egypt says "pilot test only; terms to be confirmed with the ministry".
  `RULING NEEDED:` what Meesam may store and show from this gazette, before anything of it leaves testing; a
  question for the lawyer.

## 26 Nov 2026 — Egypt read by rules (test data; not live until the Founder confirms)

- **Founder, 26 Nov 2026:** Egypt continues in the test and learning phase and is not live until he confirms.
- **Built (migration 0099; labels reader):** a "centred" layout for forms laid out as a table whose labels stand
  beside the middle of their values; lines told by their shape (the class numbers); a label that stands on the
  first line of its value (`top`). On gazette 1035, outside the worker: 426 marks of 434 pages, all complete,
  numbers all different, 8 entries running over two pages, 145 with conditions; the UAE bulletin 353 reads exactly
  as before (1,204 accepted, 265 Madrid, and the rest). The watermark is left out of the pictures.
- No wording is printed by Egypt, so the word comparison finds nothing there; the kind of mark is not worked out
  (no description). Every Egyptian mark read waits for a person (no `accept`).
- Not proven on staging yet: the reading there, and the pictures and fingerprints for Egypt.

## 26 Nov 2026 — Publications page for signed-in accounts; the ministry's reply

- **Ruling (Founder, 26 Nov 2026):** the bulletins Meesam holds are seen and downloaded inside Meesam by signed-in
  owners and agencies, the UAE first, to show the ministry an easier way to reach its bulletin. Built (migration
  0100; `/publications`; download by a ten-minute link to the file as published; the registry named as source).
  Off everywhere until the watch operations lead switches a registry on with a stated basis (Registries page).
  **Discrepancy to settle:** "Owner Services and Pages" and "Agency Services and Pages" do not have this page yet.
  `RULING NEEDED:` the basis recorded for the UAE before production (the ministry's agreement to Meesam handing
  its files to customers).
- **Ministry of Economy and Tourism, e-mail of 26 Nov 2026:** from the launch of its new trademark services system
  in December 2026 the UAE bulletin is issued daily, not twice a month; the ministry invites a proposal for
  another channel to obtain the bulletin; it sent a list of 308 registered agents' offices with e-mail addresses.
  Consequences noted: collection by hand each day is not practical, so the UAE downloader matters; the layout may
  change with the new system; the release calendar for AE changes in December. The agents' list is not loaded
  anywhere. `RULING NEEDED:` what that list may be used for (rule 13: no contact lists sold, no first contact
  that cites the publication).

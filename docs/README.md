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


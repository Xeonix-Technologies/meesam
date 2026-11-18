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
- Cross-border instruction: the instructed office gets **read** access only (Section 6 lists it as a grant
  but does not say whether it may edit). `RULING NEEDED`.
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
`RULING NEEDED`: the selectable list of goods per class (Section 6 group 4) needs the Nice 13-2026 term list
loaded into `registry.nice_term`; until that data file is supplied the applicant claims the heading or types the goods.

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
- `RULING NEEDED`: message times are shown in Gulf Standard Time; should they follow each registry or user?

## Owner pass

An agency that entered a record for a client issues a pass on the record's Agencies tab: a 12-character code,
shown once and optionally e-mailed to the owner; single use, 30 days; a new pass stops the earlier one
(4.4 link 2, item 38). The owner opens `/pass`, logs in (or creates an owner account) and confirms; the
record is attached to the owner's account (migration 0015).

- `RULING NEEDED`: on redemption the issuing agency goes on managing the record under an appointment in force
  (created by the redemption), which the owner can end. The other reading — the agency loses the record until
  the owner appoints it — would cut the agency off from a record it entered. Confirm.
- `RULING NEEDED`: a pass is bound to one record; if the agency kept it in a family with other records, the
  record moves to a family of its own on redemption and the others stay with the agency.
- Ruled (Founder, 18 Nov 2026): an owner the agency named on the pass (the pass was e-mailed to that address) needs
  no staff review: the owner account, once its e-mail is confirmed, is verified by redeeming the pass
  (migration 0017). This amends the 7 Nov ruling that every owner registration is verified before the account
  is active. `RULING NEEDED`: a pass handed over as a bare code (no address) still needs a verified account.
- Ruled (Founder, 18 Nov 2026): a pass the agency sent to an address is attached only by a user signed in with
  that address (migration 0018); another account sees why and can switch account. A pass issued without an
  address is a bare code any verified owner account holding it can use.
- Open (Founder, 18 Nov 2026: "we have to think of adding a hand-back function"): there is no way yet to return a
  record attached to the wrong owner account. To be designed: who may start it (owner, agency, staff), whether
  the other side confirms, and what happens to the appointment.
- After login the browser returns to a waiting pass only for the address it was sent to (or a bare code);
  another account logging in from the same browser is not taken to it.
- Sign-up: an individual owner gives the name once; it is also the user's name.
- Redemption during registration (item 39 (vii)): the pass page keeps the code in the browser while the person
  logs in, creates an owner account or switches from another account; the next login returns to the pass, and
  the owner's dashboard shows it waiting.

## Deadlines on a registered mark

- Founder report 18 Nov 2026: a mark added as registered showed "Priority document due". Migration 0016 closes
  the filing-stage deadlines once the mark is registered.
- `RULING NEEDED`: the UAE profile opens "priority document" on every filing (6 months from filing, verified).
  It only matters where priority is claimed. Should the clock open only when the record says priority is claimed?

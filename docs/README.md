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

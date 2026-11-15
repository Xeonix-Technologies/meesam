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

# Meesam (ميسم) — engineering rules

Meesam is Xeonix Technologies' trademark-management platform (owners, agencies, staff).
This file is the standing instruction set for every Claude Code session in this repository.
The specification documents in `docs/` are the authority; when code and a document disagree,
the document wins and the discrepancy is reported to the Founder, never silently "fixed" in code.

## Documents of record (read before touching the area)

| Area | Document (docs/) |
|---|---|
| System scope, accounts, records, links, lifecycle, notifications | `01-product/MSM — System Description v0.4*.pdf` (items 1–45) |
| AI publication watch, fetchers, alerts, operations console | `01-product/MSM-PRD-02 — Watch System*.pdf` (locked v1.1 + v1.2 suggestions) + Registry Profiles annex |
| Pricing (price list in force) | `01-product/MSM — Price List v1.0*.pdf` (supersedes the price points of the Business Model) |
| Business model, pilot offer | `01-product/MSM — Business Model v0.1*.pdf` |
| Data model, RLS, queue, retention, vault naming | `01-product/MSM — Data Architecture v0.2*.pdf` |
| Screens and states per audience | `01-product/MSM — Agency Services and Pages*.pdf`, `… Owner Services and Pages*.pdf` |
| Stages and timers | `01-product/MSM — UAE Trademark Workflow*.pdf`, `… End-to-End Workflow*.pdf` |
| Public site copy | `01-product/MSM — Home Page Content*.pdf` |
| Legal texts shown in-product | `03-legal/*.pdf` |
| Build and deployment plan | `01-product/MSM — Migration and Deployment Plan v0.3*.pdf` |

## Ruled architecture (do not re-decide)

- TypeScript end to end: `apps/web` (Next.js App Router), `apps/worker` (Node), shared `packages/*`.
- `apps/embeddings` is the only Python service (FastAPI; DINOv3 + SigLIP 2 + perceptual hash). Nothing else in Python.
- PostgreSQL 18 with pgvector on Railway. Drizzle ORM; migrations are plain SQL files in `packages/db/migrations`, reviewed, never regenerated destructively.
- Queue = PostgreSQL job table (`SELECT … FOR UPDATE SKIP LOCKED`). No Redis, no external queue.
- Documents (POA, certificates, publications) live in S3-compatible buckets; never on a volume, never in the database.
- One Dockerfile per service; configuration only through environment variables; nothing Railway-specific in code.
- Web uses the pooled connection string (`DATABASE_POOL_URL`); worker and migrations use the direct one (`DATABASE_URL`).

## Non-negotiable product rules

1. **Multilingual by construction.** Every user-facing string goes through `packages/i18n` (English and Arabic now; languages are data, more later). RTL is a first-class layout, not a patch. No hard-coded UI text, dates or number formats.
2. **Row-level security on every tenant table.** Access is enforced in PostgreSQL policies, with the application setting the session context; the app layer is a second line, never the only one.
3. **Every change to a record is audited** (who, when, what, from which account) and the other side (owner ↔ agency) is notified.
4. **All deadlines are computed from the registry profile.** Never hard-code a period, a stage name or a status wording; each registry carries its own calendar block, timers and wording. Day ends 23:59 registry-local time; no rollover of the last day. Where a period is unverified the user must enter the deadline; the system supplies no default.
5. **Nine-stage lifecycle** (item 42): pre-filing; filing and examination; acceptance, publication and opposition; appeals; registration; post-registration recordals; renewal, grace and expiry; challenges to a registration; enforcement. Terminal statuses sit inside the stage where the mark ended; there is no separate "closed" stage.
6. **Advisory checks only** on data entry: warn, never block saving.
7. **Watch:** no manual upload of publications — fetchers download them, and the fallback on a failed download is automated too. One temporary exception (Founder ruling 19 Nov 2026): a source the watch operations lead has switched to "collected by hand", because its site refuses the fetcher, takes a file added by the lead in the Operations Console, checked and stored like a fetched one. Do not widen it: no upload for any other source, role or audience, and it ends per source when the site accepts the fetcher. Human verification of AI-extracted marks stays on per registry until retired by ruling. Alerts are per registry and per account; never merged across a mark family or shared between accounts.
8. **Vault file naming:** `regno_serial_DDMMYY_TYPE.ext` with the 14 three-letter type codes (APP, OAC, RSP, PUB, OPP, ORC, REN, DOU, ASG, LIC, CNA, POA, LGR, OTH), plus IMG for the mark's own image (Founder ruling 18 Nov 2026; a 15th code, set by the image upload, not offered in the document list). Registry and country codes are WIPO ST.3.
9. **Pricing engine** implements the price list in force exactly: **Price List v1.0** (Founder ruling 21 Nov 2026; it replaces the Business Model v0.1 list). One fee buys docketing and the watch for one mark at one registry. List price AED 480 at 10 years remaining; introductory price AED 370 only for records paid while the offer is open; 10% of the full price less per year; floor AED 195 at 4 years or less (the introductory 5-year step also stays AED 195). No free states: a new mark pays AED 100 at filing (reminders, no watch), credited toward the full price at the certificate or when the watch is switched on, not refunded; an existing registered mark pays by years remaining when added. AED 150 flat per additional or watch-only registry; AED 100 per class added. UAE buyers see the VAT-inclusive total. Renewal price, pilot terms, the offer's end date and the list's effective date are open: until ruled, the pilot stays "everything free". Prices are configuration (`core.price_list`), dated and versioned, never literals in code; a new list is a new version, never an edit of an old one.
10. **Invoicing entity** is a configuration value (`INVOICE_ISSUER`), currently Xeonix Technologies, the contracting party (Founder ruling 21 Nov 2026; before that Wahaat Investment L.L.C.).
11. **Staff surfaces:** Meesam System Admin and the Watch Operations Console are separate areas behind a staff role. Human support exists only for technical and payment issues; everything else is self-service and AI-assisted.
12. **Registries are never login users.** A registry is a data source and, later, a data partner.
13. **Data (Founder rulings 21 Nov 2026, from "Data Management and Use v0.1" items 10.1, 10.2, 10.4, 10.5, 10.9, 10.11, 10.12).** What registries publish and what accounts enter are kept in separate areas, matched but never merged: a customer's correction never changes the published data, and a difference is shown as an advisory note. Every published fact carries its source. Meesam does not offer a public trademark search or public mark pages, does not sell raw extracts or contact lists, does not use one account's records to benefit another account, and makes no first contact that cites the publication issue. The other items of that document (10.3, 10.6–10.8, 10.10, 10.13) are planned work or open, not rules.

## Working conventions

- Branches: `develop` → staging (Railway autodeploy), `main` → production. Feature branches from `develop`; pull requests get a Railway PR environment.
- Commits: conventional prefixes (`feat:`, `fix:`, `chore:`, `docs:`), present tense, one concern each.
- Never commit secrets. `.env*` files are ignored; Railway variables are the only source of configuration.
- Tests run in CI (`.github/workflows/ci.yml`) before Railway deploys (Wait for CI is enabled on the services).
- When a specification point is ambiguous, implement the narrowest reading, tag it `// RULING NEEDED: <question>` and list it in the PR description for the Founder.
- Write "Section", never the § sign, in any text shown to users or written to documents.

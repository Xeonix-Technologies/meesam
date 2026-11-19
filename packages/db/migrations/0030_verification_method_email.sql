-- 0030 — Verification method 'email' (Founder ruling 19 Nov 2026: owners need no staff approval).
-- Alone in its migration: a new enum value cannot be used in the transaction that adds it; 0031 uses it.
BEGIN;
ALTER TYPE core.verification_method ADD VALUE IF NOT EXISTS 'email';
COMMIT;

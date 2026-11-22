-- 0078 — A fourth risk band (Founder ruling 22 Nov 2026): Very high, High, Medium, Low. The value is added here,
-- on its own, because a new value of a type cannot be used in the migration that adds it; 0079 uses it.
BEGIN;
ALTER TYPE watch.risk_band ADD VALUE IF NOT EXISTS 'very_high' BEFORE 'high';
COMMIT;

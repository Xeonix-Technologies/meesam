-- 0009: the filing request (System Description Section 6). Before Filed, a record exists only as a
-- filing request: a record at stage pre_filing with entry_mode new_filing. The request's own content
-- (applicant, who files, mark description, priority claim, declarations) is kept on the record as
-- accepted by the account holder; the classes, goods and attachments use the ordinary tables.
BEGIN;
ALTER TABLE core.record ADD COLUMN IF NOT EXISTS filing_request jsonb NULL;
COMMENT ON COLUMN core.record.filing_request IS 'Section 6 request as accepted: {applicant, route, mark, priority, declarations, accepted_at}';
COMMIT;

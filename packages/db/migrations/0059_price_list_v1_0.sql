-- 0059 — Price List v1.0 (Founder, 21 Nov 2026), part 2: the list itself, as configuration (CLAUDE.md rule 9).
-- Document of record: "Meesam (ميسم) — Price List v1.0". It replaces price list version 1 (Business Model v0.1):
--   1  record with 10 years remaining, list price                    AED 480
--   2  introductory price while the offer is open                    AED 370
--   3  fewer years remaining: 10% of the full price less per year, floor AED 195 at 4 years or less;
--      at introductory prices the 5-year step also stays at the floor (370 − 5×37 = 185 → 195)
--   4  new mark at filing: AED 100, reminders from the entered information, no watch
--   5  new mark at the certificate, or watch switched on early: full price less the 100 already paid
--   6, 7  additional registry / watch-only registry                  AED 150 each, flat
--   8  class added to an existing mark                               AED 100
--   9  renewal: price open (Q4 Year 1 review); a fee paid in the last 12 months before expiry is credited
-- No free states: an existing registered mark pays by years remaining when it is added.
-- The states keep their stored names (free_new_pending = new mark, filing fee not yet paid; free_loaded =
-- existing mark, record fee not yet paid); only what they mean and how they are worded changed.
--
-- RULING NEEDED: the effective date of Price List v1.0 is open in the document. It is entered with the date of
--   the list it replaces (2 Dec 2026) so that no payment can ever be priced on the old list.
-- RULING NEEDED: pilot terms are open in the document ("to be ruled later"); the pilot stays "everything free"
--   (pilot_all_free) as last ruled, until the Founder rules otherwise.
-- RULING NEEDED: the introductory offer is entered as open with no end date ("to be set after launch").
-- Not built here, waiting for their rulings or their moment: the renewal price, the 12-month renewal credit
--   (carried as configuration only), the credit wallet, large single-registry portfolios, and the e-mail to
--   every account holder when a new registry becomes available.
BEGIN;

INSERT INTO core.price_list (version, effective_from, rules) VALUES (2, DATE '2026-12-02', '{
  "name": "Price List v1.0",
  "ruled_on": "2026-11-21",
  "currency": "AED",
  "vat_rate": 0.05,
  "vat_inclusive_display": ["AE"],
  "home_registry": {"base": 480, "base_years": 10, "step_per_year": 48, "floor": 195, "floor_at_years_or_less": 4},
  "introductory": {"open": true, "until": null, "base": 370, "base_years": 10, "step_per_year": 37, "floor": 195, "floor_at_years_or_less": 5},
  "filing_fee": 100,
  "filing_fee_credited": true,
  "filing_fee_refundable": false,
  "extra_registry": 150,
  "watch_only": 150,
  "class_add": 100,
  "renewal": {"price": null, "credit_if_paid_within_months": 12},
  "free_until_certificate": false,
  "existing_free_until_watch": false,
  "pilot_all_free": true,
  "annual_option": false
}'::jsonb);

-- One step of the years-remaining scale, from a block of the price list.
CREATE OR REPLACE FUNCTION core.fn_scale_price(p_block jsonb, p_years smallint) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_years <= (p_block ->> 'floor_at_years_or_less')::smallint THEN (p_block ->> 'floor')::numeric
    ELSE greatest((p_block ->> 'floor')::numeric,
                  (p_block ->> 'base')::numeric - (p_block ->> 'step_per_year')::numeric
                    * ((p_block ->> 'base_years')::smallint - least(p_years, (p_block ->> 'base_years')::smallint)))
  END
$$;

-- The price of one case on one day. amount = what applies (introductory while the offer is open, otherwise
-- list); list_amount = the list price for the same case; introductory says which of the two amount is.
DROP FUNCTION core.fn_price(core.payment_case, date, date, boolean);
CREATE FUNCTION core.fn_price(p_case core.payment_case, p_expiry date, p_as_of date DEFAULT current_date,
                              p_pilot boolean DEFAULT false,
                              OUT years_remaining smallint, OUT amount numeric, OUT vat numeric,
                              OUT list_amount numeric, OUT introductory boolean)
LANGUAGE plpgsql STABLE AS $$
DECLARE pl jsonb; h jsonb; i jsonb; yrs smallint; computed numeric;
BEGIN
  SELECT rules INTO pl FROM core.price_list WHERE effective_from <= p_as_of ORDER BY effective_from DESC, version DESC LIMIT 1;
  IF pl IS NULL THEN SELECT rules INTO pl FROM core.price_list ORDER BY version DESC LIMIT 1; END IF;
  h := pl -> 'home_registry';
  i := pl -> 'introductory';
  yrs := CASE WHEN p_expiry IS NULL THEN (h ->> 'base_years')::smallint ELSE core.fn_years_remaining(p_expiry, p_as_of) END;
  years_remaining := yrs;
  introductory := false;
  IF p_case IN ('registration', 'early_watch', 'existing_watch') THEN
    list_amount := core.fn_scale_price(h, yrs);
    computed := list_amount;
    IF i IS NOT NULL AND jsonb_typeof(i) = 'object' AND COALESCE((i ->> 'open')::boolean, false)
       AND ((i ->> 'until') IS NULL OR p_as_of <= (i ->> 'until')::date) THEN
      computed := core.fn_scale_price(i, yrs);
      introductory := true;
    END IF;
  ELSIF p_case = 'filing' THEN computed := (pl ->> 'filing_fee')::numeric;
  ELSIF p_case = 'extra_registry' THEN computed := (pl ->> 'extra_registry')::numeric;
  ELSIF p_case = 'watch_only' THEN computed := (pl ->> 'watch_only')::numeric;
  ELSIF p_case = 'class_add' THEN computed := (pl ->> 'class_add')::numeric;
  END IF;
  IF computed IS NULL THEN RAISE EXCEPTION 'the price list in force has no price for case %', p_case; END IF;
  list_amount := round(COALESCE(list_amount, computed), 2);
  IF p_pilot AND COALESCE((pl ->> 'pilot_all_free')::boolean, false) THEN
    amount := 0; vat := 0; RETURN;
  END IF;
  amount := round(computed, 2);
  vat := round(amount * COALESCE((pl ->> 'vat_rate')::numeric, 0), 2);
END $$;

-- What a record owes today: the case, the price, the filing fee already paid (credited), and what is left.
-- Runs as the caller, so row-level security on records and payments applies.
CREATE FUNCTION core.fn_record_due(p_record_id uuid, p_as_of date DEFAULT current_date, p_pilot boolean DEFAULT false,
                                   OUT "case" core.payment_case, OUT years_remaining smallint, OUT list_amount numeric,
                                   OUT amount numeric, OUT introductory boolean, OUT credit numeric,
                                   OUT due numeric, OUT vat numeric, OUT total numeric, OUT vat_inclusive boolean)
LANGUAGE plpgsql STABLE AS $$
DECLARE r core.record; p record; pl jsonb; v_country text; v_rate numeric;
BEGIN
  SELECT * INTO r FROM core.record WHERE id = p_record_id;
  IF r.id IS NULL OR r.paid_state = 'paid' THEN RETURN; END IF;
  SELECT rules INTO pl FROM core.price_list WHERE effective_from <= p_as_of ORDER BY effective_from DESC, version DESC LIMIT 1;
  IF pl IS NULL THEN SELECT rules INTO pl FROM core.price_list ORDER BY version DESC LIMIT 1; END IF;
  v_rate := COALESCE((pl ->> 'vat_rate')::numeric, 0);
  "case" := CASE
    WHEN r.paid_state = 'free_new_pending' THEN 'filing'
    WHEN r.entry_mode = 'new_filing' THEN 'registration'
    ELSE 'existing_watch' END::core.payment_case;
  SELECT * INTO p FROM core.fn_price("case", r.expiry_date, p_as_of, p_pilot);
  years_remaining := p.years_remaining; list_amount := p.list_amount; amount := p.amount; introductory := p.introductory;
  credit := 0;
  IF "case" <> 'filing' AND COALESCE((pl ->> 'filing_fee_credited')::boolean, false) THEN
    SELECT COALESCE(sum(pm.amount), 0) INTO credit FROM core.payment pm WHERE pm.record_id = r.id AND pm."case" = 'filing';
  END IF;
  credit := least(credit, amount);
  due := amount - credit;
  vat := round(due * v_rate, 2);
  total := due + vat;
  -- the buyer is the account looking at the price (an owner, or the agency that pays for it)
  SELECT a.country::text INTO v_country FROM core.account a WHERE a.id = platform.current_account_id();
  vat_inclusive := COALESCE(pl -> 'vat_inclusive_display' ? v_country, false);
END $$;
GRANT EXECUTE ON FUNCTION core.fn_scale_price(jsonb, smallint), core.fn_record_due(uuid, date, boolean) TO meesam_app, meesam_staff, meesam_admin;
GRANT EXECUTE ON FUNCTION core.fn_price(core.payment_case, date, date, boolean) TO meesam_app, meesam_staff, meesam_admin;

-- A record takes one filing fee.
CREATE UNIQUE INDEX payment_one_filing ON core.payment (record_id) WHERE "case" = 'filing';

-- sp_pay: the filing fee moves a new mark to 'filing_paid' (reminders, no watch); the full fee pays the record
-- and switches the watch on, as before.
CREATE OR REPLACE PROCEDURE core.sp_pay(p_record_id uuid, p_payer_account_id uuid, p_case core.payment_case,
                                        p_amount numeric, p_vat numeric, p_issuer text, p_provider_ref text,
                                        p_years_remaining smallint DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
DECLARE r core.record;
BEGIN
  SELECT * INTO r FROM core.record WHERE id = p_record_id FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'record % not found', p_record_id; END IF;
  IF p_case IN ('registration', 'early_watch', 'existing_watch') AND r.paid_state = 'paid' THEN
    RAISE EXCEPTION 'record % is already paid', p_record_id USING ERRCODE = 'unique_violation';
  END IF;
  IF p_case = 'filing' AND r.paid_state <> 'free_new_pending' THEN
    RAISE EXCEPTION 'record % takes no filing fee in state %', p_record_id, r.paid_state USING ERRCODE = 'unique_violation';
  END IF;
  INSERT INTO core.payment (record_id, payer_account_id, "case", years_remaining, amount, vat, issuer, provider_ref)
  VALUES (p_record_id, p_payer_account_id, p_case, p_years_remaining, p_amount, p_vat, p_issuer, p_provider_ref);
  IF p_case IN ('registration', 'early_watch', 'existing_watch') THEN
    UPDATE core.record SET paid_state = 'paid', watch_active_from = COALESCE(watch_active_from, now()) WHERE id = p_record_id;
  ELSIF p_case = 'filing' THEN
    UPDATE core.record SET paid_state = 'filing_paid' WHERE id = p_record_id;
  END IF;
END $$;

-- Certificate arrives: the balance of the full price falls due, whether or not the filing fee was paid.
CREATE OR REPLACE PROCEDURE core.sp_certificate_received(p_record_id uuid, p_doc_id uuid, p_registration_date date, p_registration_no text DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
DECLARE r core.record;
BEGIN
  SELECT * INTO r FROM core.record WHERE id = p_record_id FOR UPDATE;
  UPDATE core.record SET registration_no = COALESCE(p_registration_no, registration_no), registration_date = p_registration_date WHERE id = p_record_id;
  INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id)
  VALUES (p_record_id, 'registered', p_registration_date, 'manual', jsonb_build_object('document_id', p_doc_id), platform.current_account_id());
  IF r.paid_state IN ('free_new_pending', 'filing_paid') AND NOT EXISTS (SELECT 1 FROM core.payment p WHERE p.record_id = p_record_id AND p."case" IN ('registration', 'early_watch')) THEN
    UPDATE core.record SET paid_state = 'read_only_unpaid' WHERE id = p_record_id;
  END IF;
END $$;

COMMIT;

-- ============================================================
-- Migration 265: a cafe's checklist has no price list.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: the price list is for coworking spaces and
-- should not appear for cafes. A cafe keeps only its cappuccino price
-- (a feel for how pricey it is), edited in the Owner account. So
-- "Prices" leaves the Get more from your page checklist for a cafe,
-- and with it the monthly email's "Add your prices" tip.
-- ============================================================

do $$
declare d text;
begin
  select pg_get_functiondef('public.page_parts(uuid)'::regprocedure) into d;
  if position('v.type = ''cafe''' in d) = 0 then
    d := replace(d,
      '  select k into nxt',
      '  if v.type = ''cafe'' then
    parts := (select jsonb_agg(p) from jsonb_array_elements(parts) p
               where p ->> ''key'' <> ''prices'');
  end if;
  select k into nxt');
    if position('v.type = ''cafe''' in d) = 0 then
      raise exception 'page_parts did not change';
    end if;
    execute d;
  end if;
end $$;

-- A price the owner entered themselves stays as they entered it.
--
-- Jonathan, 22 Nov 2026: OUR HQ's owner entered £89 and £99 when they
-- logged in; their website showed £99 and £149 and has most likely not
-- been updated. A reading of a space's website must never change a
-- product the owner added or edited from their own account. It is
-- flagged instead ("DIFFERS FROM THEIR SITE" on the Prices page) so
-- the founder can ask them.
--
-- This adds one guard to import_price_check, just before it looks for
-- an open proposal. The rest of the function is left exactly as it is,
-- so the guard is spliced into the live definition. Safe to run twice.
do $mig$
declare
  d      text := pg_get_functiondef('public.import_price_check(jsonb,text)'::regprocedure);
  marker text := E'      select * into open_ from public.product_changes x\n       where x.product_id = pid\n';
  guard  text := $g$      -- The owner entered this themselves: a website reading never
      -- changes it. It is flagged, and the page is left as it is.
      if res in ('changed', 'gone') and (pr.source = 'owner' or exists (
           select 1 from public.product_changes x
            where x.product_id = pid and x.source = 'owner'
              and x.status = 'applied')) then
        delete from public.product_changes x
         where x.product_id = pid and x.source = 'check'
           and x.status in ('proposed', 'failed');
        update public.venue_products set
          checked_at = null, checked_url = null, check_result = 'differs',
          check_note = left('The owner entered this themselves, so it stays as it is.'
                            || coalesce(' ' || note_, ''), 2000),
          check_seen_at = now(), updated_at = now()
         where id = pid;
        skipped := skipped || jsonb_build_array(jsonb_build_object(
          'slug', v.webflow_slug, 'ref', it->>'ref',
          'why', 'the owner entered this themselves: flagged, not changed'));
        continue;
      end if;

$g$;
begin
  if position('The owner entered this themselves' in d) > 0 then
    return;  -- already in place
  end if;
  if (length(d) - length(replace(d, marker, ''))) / length(marker) <> 1 then
    raise exception 'import_price_check has changed shape: owner guard not added';
  end if;
  execute replace(d, marker, guard || marker);
end $mig$;

-- ============================================================
-- Migration 197: "straight to your email address".
--
-- Jonathan, 22 Oct 2026, on the customer email: "Their replies will
-- come straight to your email address." (was "this email address").
-- The same for one space: "their reply will come straight to your
-- email address". Everything else in enquiry_nomad_email (migration
-- 196) is unchanged.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.enquiry_nomad_email(p_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  em    text;
  nm    text;
  first text;
  n     integer;
  one   text;
  site  text;
  lines text;
  sites boolean;
begin
  select lower(min(e.email)), min(e.name), count(*), min(v.name), min(v.website),
         string_agg('- ' || v.name
                    || coalesce(' (' || nullif(btrim(coalesce(v.website, '')), '') || ')', ''),
                    E'\n' order by v.name),
         bool_or(coalesce(btrim(v.website), '') <> '')
    into em, nm, n, one, site, lines, sites
    from public.enquiries e
    join public.venues v on v.id = e.venue_id
   where e.id = any(p_ids);
  if coalesce(n, 0) = 0 then return null; end if;
  first := nullif(nullif(split_part(btrim(nm), ' ', 1), ''), 'Someone');

  if n = 1 then
    return jsonb_build_object(
      'to', em,
      'subject', 'Your enquiry has been sent to ' || one,
      'body',
        'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
        || 'Thank you for your enquiry on Nomadwise. We have sent it to ' || one
        || ', and their reply will come straight to your email address.' || E'\n\n'
        || case when coalesce(btrim(site), '') <> ''
                then 'If you would like to contact them yourself as well, their website is '
                     || btrim(site) || E'\n\n'
                else '' end
        || 'If you have any further questions, simply reply to this email.' || E'\n\n'
        || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
  end if;

  return jsonb_build_object(
    'to', em,
    'subject', 'Your enquiry has been sent to ' || n || ' spaces',
    'body',
      'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
      || 'Thank you for your enquiry on Nomadwise. We have sent it to these '
      || n || ' spaces:' || E'\n\n'
      || lines || E'\n\n'
      || 'Their replies will come straight to your email address.'
      || case when sites
              then ' If you would like to contact any of them yourself, their websites '
                   || 'are listed above.'
              else '' end || E'\n\n'
      || 'If you have any further questions, simply reply to this email.' || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;
revoke all on function public.enquiry_nomad_email(uuid[]) from public, anon, authenticated;

notify pgrst, 'reload schema';

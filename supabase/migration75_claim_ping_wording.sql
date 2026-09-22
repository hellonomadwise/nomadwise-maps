-- ============================================================
-- Migration 75: claim page ping reads naturally when no space is named.
-- (Applied automatically by the build; nothing to paste.)
-- ============================================================

create or replace function public.claim_opened(
  p_seed text, p_from text, p_referrer text, p_user_agent text)
returns void language plpgsql security definer set search_path = public as $$
declare
  seed   text := nullif(left(trim(coalesce(p_seed, '')), 200), '');
  frm    text := nullif(left(trim(coalesce(p_from, '')), 300), '');
  ref    text := nullif(left(trim(coalesce(p_referrer, '')), 300), '');
  ua     text := nullif(left(trim(coalesce(p_user_agent, '')), 300), '');
  v_name text;
  v_city text;
  what   text;
  whence text;
  recent int;
begin
  insert into public.claim_visits (seed, from_path, referrer, user_agent)
  values (seed, frm, ref, ua);

  select count(*) into recent from public.claim_visits
   where created_at > now() - interval '1 hour';
  if recent > 30 then
    return;
  end if;

  if seed is not null then
    select name, city into v_name, v_city from public.venues
     where webflow_slug = seed or name ilike seed
     limit 1;
  end if;
  what := case when v_name is not null
               then ' for ' || v_name || coalesce(' in ' || nullif(v_city, ''), '')
               when seed is not null then ' for "' || seed || '"'
               else '' end;
  whence := case when frm is not null then 'from nomadwise.io' || frm
                 when ref is not null then 'from ' ||
                      regexp_replace(ref, '^https?://(www\.)?', '')
                 else 'direct, no referrer' end;

  perform public.notify_phone(
    'Claim page opened',
    'Someone opened the claim page' || what || ', ' || whence || '.',
    'eyes');
end $$;
grant execute on function public.claim_opened(text, text, text, text) to anon, authenticated;

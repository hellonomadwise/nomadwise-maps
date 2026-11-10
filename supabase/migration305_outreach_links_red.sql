-- ============================================================
-- Migration 305: links in outreach emails in Nomadwise red
-- ============================================================
-- Jonathan, 10 Nov 2026: "Nomadwise is highlight blue it shouldn't be".
-- Links in the outreach email look (outreach_plain_html) were blue
-- (#1A56DB); they are now Nomadwise red and underlined, the same as the
-- owner emails in Postmark. Safe to run twice.
-- ============================================================
do $$
declare d text;
begin
  d := pg_get_functiondef('public.outreach_plain_html(text)'::regprocedure);
  if position('#1A56DB' in d) > 0 then
    d := replace(d, 'style="color:#1A56DB;"', 'style="color:#FF444F;text-decoration:underline;"');
    execute d;
  end if;
end $$;

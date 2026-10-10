-- 186: the designed email, for sending from our own inbox.
--
-- Jonathan, 10 Oct 2026, with the Level39 hello pasted into Spark on
-- Windows as bare text (long addresses, no button): "how can i go about
-- sending it with the styling that you showed me earlier, with the
-- button etc. if I tried to open it using spark desktop it looks bad".
-- A web page cannot hand a designed email to Spark; it can put one on
-- the clipboard. admin_outreach_email_html gives the app the same HTML
-- an email sent from here carries (migration 180 and after): the claim
-- button, short links, the signature, the small unsubscribe line. The
-- app copies it with the plain text, and pasting into a new email in
-- Spark keeps the design. Founders only. Nothing is sent or stored.
-- Pure ASCII. Safe to apply twice.

create or replace function public.admin_outreach_email_html(p_body text)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  return public.outreach_plain_html(p_body);
end $$;
revoke all on function public.admin_outreach_email_html(text) from public, anon;
grant execute on function public.admin_outreach_email_html(text) to authenticated;

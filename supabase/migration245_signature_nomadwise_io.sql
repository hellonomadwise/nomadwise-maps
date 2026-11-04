-- ============================================================
-- Migration 245: the email signature says nomadwise.io.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 4 Nov 2026: "the nomadwise in the signature should be
-- nomadwise.io (all nomadwise red)". Every designed email (email_html)
-- signs off "Co-founder, nomadwise.io", the whole address in Nomadwise
-- red and linked to the site. Only the signature changes.
-- ============================================================

do $$
declare
  d text;
begin
  select pg_get_functiondef('public.email_html(text, text, text, boolean)'::regprocedure) into d;
  if position('text-decoration:none;">nomadwise.io</a></p>' in d) > 0 then
    return;  -- already done
  end if;
  d := replace(d,
    'text-decoration:none;">Nomadwise</a></p>',
    'text-decoration:none;">nomadwise.io</a></p>');
  if position('text-decoration:none;">nomadwise.io</a></p>' in d) = 0 then
    raise exception 'Signature not found in email_html';
  end if;
  execute d;
end $$;

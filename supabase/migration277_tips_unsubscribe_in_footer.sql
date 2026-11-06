-- ============================================================
-- Migration 277: owner tips, "Unsubscribe" in the grey footer.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: the "Stop these tips" line under the signature
-- is too much; it should be "Unsubscribe" in the grey area below.
--  * The shared layout shows " · Unsubscribe" after "Owner account"
--    only for an email whose model says has_stop (the tips), so every
--    other email looks exactly as before.
--  * The tips lose their own line under the signature.
-- After this, the layout and the four tip templates are pushed to
-- Postmark by hand (pm_layout_push(true), pm_template_push(alias, true)).
-- ============================================================

select public.pm_patch_fn('public.pm_layout_html()',
  $a${{#for_spaces}} &middot; <a href="https://nomadmaps.io/owner" style="color:#96A0AC;">Owner account</a>{{/for_spaces}}$a$,
  $a${{#for_spaces}} &middot; <a href="https://nomadmaps.io/owner" style="color:#96A0AC;">Owner account</a>{{/for_spaces}}{{#has_stop}} &middot; <a href="{{../stop_url}}" style="color:#96A0AC;">Unsubscribe</a>{{/has_stop}}$a$,
  $m${{#has_stop}}$m$);

select public.pm_patch_fn('public.pm_layout_text()',
  $a$Reply to this email and a person answers. https://www.nomadwise.io'$a$,
  $a$Reply to this email and a person answers. https://www.nomadwise.io{{#has_stop}}\nUnsubscribe: {{../stop_url}}{{/has_stop}}'$a$,
  $m${{#has_stop}}$m$);

update public.email_templates
   set html_body = regexp_replace(html_body, E'\\n<p style="margin:24px 0 0;font-size:12.5px;[^\\n]*Stop these tips</a></p>\\n', E'\n'),
       text_body = regexp_replace(text_body, E'\\n\\nYou get a tip like this now and then[^\\n]*$', ''),
       updated_at = now()
 where alias like 'tip-%' and html_body like '%Stop these tips%';

select public.pm_patch_fn('public.owner_tip_model(uuid,text,text)',
  $a$    'stop_url', 'https://nomadmaps.io/stop/?k=tips&t=' || coalesce(tok, 'test'),$a$,
  $a$    'stop_url', 'https://nomadmaps.io/stop/?k=tips&t=' || coalesce(tok, 'test'), 'has_stop', true,$a$,
  $m$'has_stop', true$m$);

-- ============================================================
-- Migration 263: the website chat email signs off "nomadwise.io".
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026, test pair 20: "on the signature, the new one
-- says Nomadwise.io where it should be nomadwise.io". The template
-- (site-chat-reply) and today's code both now say nomadwise.io; in the
-- HTML it carries a hidden break so inboxes do not turn it into a link.
-- ============================================================

update public.email_templates
   set html_body = replace(html_body, '<br>{{from_name}}<br>Nomadwise.io</p>', '<br>{{from_name}}<br>nomadwise&#8203;.io</p>'),
       text_body = replace(text_body, E'{{from_name}}\nNomadwise.io', E'{{from_name}}\nnomadwise.io'),
       updated_at = now()
 where alias = 'site-chat-reply' and html_body like '%<br>{{from_name}}<br>Nomadwise.io</p>%';

select public.pm_patch_fn('public.site_chat_email_sync()',
  $a$|| 'Kind regards,' || E'\n' || coalesce(who, 'Jonathan') || E'\n' || 'Nomadwise.io',$a$,
  $a$|| 'Kind regards,' || E'\n' || coalesce(who, 'Jonathan') || E'\n' || 'nomadwise.io',$a$,
  $a$'nomadwise.io',$a$);

-- Jonathan approved test pairs 20-22 on 6 Nov 2026 ("20, 21, 22 ok"):
-- the three rarer emails go out through their templates too.
update public.email_templates set live = true, updated_at = now()
 where alias in ('site-chat-reply','enquiry-unreachable-nomad','enquiry-sent-nomad-many')
   and not live;

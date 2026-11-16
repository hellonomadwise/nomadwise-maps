-- Migration 330: "since you last looked" says its numbers in sentences.
--
-- Jonathan, 16 Nov 2026, on the email Lisbon-Cowork got ("Shown in
-- Google search 111 / Page views 15"): "Your listing was shown in
-- Google 111 times. 15 people viewed your listing page."
--
-- A label and a number in a table reads like a report. A sentence says
-- what happened. Each line is now a sentence with the number in bold:
--   Your listing was shown in Google 111 times
--   Your listing page was viewed 15 times
--   People asked for directions 3 times
--   You received 2 requests
--
-- The view line says "viewed 15 times", not "15 people viewed": a view
-- is counted once per visit (page_hit), so one person who comes back on
-- another day is counted again. "Times" is always true.
--
-- The model gains "pre" and "post" (the words either side of the
-- number); "label" and "value" stay for anything that still reads them.
-- Order matters: the model first (the old template ignores the new
-- words), then the template, then the push to Postmark.

select public.pm_patch_fn('public.owner_tip_model(uuid,text,text)',
  $a$jsonb_build_object('label', 'Shown in Google search', 'value', to_char(g, 'FM999,999'));$a$,
  $a$jsonb_build_object('label', 'Shown in Google search', 'value', to_char(g, 'FM999,999'), 'pre', 'Your listing was shown in Google', 'post', 'times');$a$,
  $a$'pre', 'Your listing was shown in Google'$a$);

select public.pm_patch_fn('public.owner_tip_model(uuid,text,text)',
  $a$jsonb_build_object('label', 'Page views', 'value', to_char(views, 'FM999,999'));$a$,
  $a$jsonb_build_object('label', 'Page views', 'value', to_char(views, 'FM999,999'), 'pre', 'Your listing page was viewed', 'post', case when views = 1 then 'time' else 'times' end);$a$,
  $a$'pre', 'Your listing page was viewed'$a$);

select public.pm_patch_fn('public.owner_tip_model(uuid,text,text)',
  $a$jsonb_build_object('label', 'Asked for directions', 'value', to_char(dirs, 'FM999,999'));$a$,
  $a$jsonb_build_object('label', 'Asked for directions', 'value', to_char(dirs, 'FM999,999'), 'pre', 'People asked for directions', 'post', case when dirs = 1 then 'time' else 'times' end);$a$,
  $a$'pre', 'People asked for directions'$a$);

select public.pm_patch_fn('public.owner_tip_model(uuid,text,text)',
  $a$jsonb_build_object('label', case when reqs = 1 then 'Request' else 'Requests' end, 'value', reqs::text);$a$,
  $a$jsonb_build_object('label', case when reqs = 1 then 'Request' else 'Requests' end, 'value', reqs::text, 'pre', 'You received', 'post', case when reqs = 1 then 'request' else 'requests' end);$a$,
  $a$'pre', 'You received'$a$);

-- The line under the subject in the inbox: the same sentences.
select public.pm_patch_fn('public.owner_tip_model(uuid,text,text)',
  $a$string_agg(r ->> 'label' || ' ' || (r ->> 'value'), ', ' order by o)$a$,
  $a$string_agg((r ->> 'pre') || ' ' || (r ->> 'value') || ' ' || (r ->> 'post'), '. ' order by o)$a$,
  $a$string_agg((r ->> 'pre') || ' ' || (r ->> 'value')$a$);

-- The template: one sentence a line, the number in bold.
update public.email_templates
   set html_body = replace(html_body,
         $a${{#each rows}}<tr><td style="padding:12px 16px;font-size:15px;color:#3D444D;{{border}}">{{label}}</td><td align="right" style="padding:12px 16px;font-size:17px;font-weight:700;color:#142032;{{border}}">{{value}}</td></tr>{{/each}}$a$,
         $a${{#each rows}}<tr><td style="padding:12px 16px;font-size:16px;line-height:1.5;color:#142032;{{border}}">{{pre}} <strong style="font-weight:700;">{{value}}</strong> {{post}}</td></tr>{{/each}}$a$),
       text_body = replace(text_body,
         $a${{#each rows}}{{label}}: {{value}}$a$,
         $a${{#each rows}}{{pre}} {{value}} {{post}}$a$)
 where alias = 'tip-quiet';

-- Then, by hand, in this order (DECISIONS: push first, back up after):
--   select public.pm_template_push('tip-quiet', true);
--   select public.pm_templates_backup();

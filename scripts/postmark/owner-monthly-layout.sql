-- Layout "nomadwise-layout-monthly" (Postmark id 48615926), used only by
-- the owner-monthly template (id 48615927). It is the shared
-- "nomadwise-layout" (owned by the owner email setup work) with the
-- monthly email's own lines added at the top of the grey footer:
-- why they get it, "Choose which emails you get" and "Stop monthly
-- updates" (Jonathan, 6 Nov 2026). Made this way so the shared layout
-- is not changed. If the shared layout changes, re-run this (delete
-- the old layout in Postmark first: pg_net has no PUT).
with l as (
  select replace(public.pm_layout_html(),
    'color:#96A0AC;">Nomadwise, work from anywhere.',
    'color:#96A0AC;"><div style="margin:0 0 12px;">You get this once a month because you manage {{space}} on Nomadwise. Numbers are for 1 to {{last_day}} {{month_name}}.<br><a href="{{settings_url}}" style="color:#6B7480;">Choose which emails you get</a> &middot; <a href="{{stop_url}}" style="color:#6B7480;">Stop monthly updates</a></div>Nomadwise, work from anywhere.') h,
  replace(public.pm_layout_text(), E'\n\n--\n',
    E'\n\n--\nYou get this once a month because you manage {{space}} on Nomadwise. Numbers are for 1 to {{last_day}} {{month_name}}.\nChoose which emails you get: {{settings_url}}\nStop monthly updates: {{stop_url}}\n\n') t)
select net.http_post(url := 'https://api.postmarkapp.com/templates',
  body := jsonb_build_object('Name','Nomadwise layout (monthly email)','Alias','nomadwise-layout-monthly','TemplateType','Layout','HtmlBody',h,'TextBody',t),
  headers := jsonb_build_object('Accept','application/json','Content-Type','application/json','X-Postmark-Server-Token',public.pm_token()))
from l;

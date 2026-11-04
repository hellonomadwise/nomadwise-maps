-- Migration 249: "enquiry" becomes "request" in the emails the visitor gets.
--
-- Many visitors are not native English speakers and "enquiry" is a formal
-- British word. The price list already says "Request" (prices.js). This
-- changes the wording in the three emails that go to the person who asked:
--   enquiry_nomad_email     (it has been sent to the space)
--   enquiry_received_email  (we have it and will pass it on)
--   admin_enquiry_close     (we could not reach the space)
-- Emails to spaces, admin text and all names in the database stay as they are.
-- Each phrase must be found exactly as expected, or the migration stops.

do $mig$
declare
  r   record;
  def text;
  n   int;
begin
  for r in
    select * from (values
      ('public.enquiry_nomad_email(uuid[])',   'Your enquiry has been sent to ',  'Your request has been sent to ',  2),
      ('public.enquiry_nomad_email(uuid[])',   'Thank you for your enquiry on Nomadwise.', 'Thank you for your request on Nomadwise.', 2),
      ('public.enquiry_received_email(uuid)',  '''We have your enquiry''',         '''We have your request''',          1),
      ('public.enquiry_received_email(uuid)',  'Thank you for your enquiry on Nomadwise.', 'Thank you for your request on Nomadwise.', 1),
      ('public.admin_enquiry_close(uuid,text,boolean)', '''Your enquiry for ''', '''Your request for ''',             1),
      ('public.admin_enquiry_close(uuid,text,boolean)', '''Thanks for your enquiry about ''', '''Thanks for your request about ''', 1)
    ) as t(fn, old, new, expected)
  loop
    def := pg_get_functiondef(r.fn::regprocedure);
    n := (length(def) - length(replace(def, r.old, ''))) / length(r.old);
    if n = 0 and position(r.new in def) > 0 then
      continue;  -- already changed
    end if;
    if n <> r.expected then
      raise exception 'migration 249: % has % of "%", expected %', r.fn, n, r.old, r.expected;
    end if;
    execute replace(def, r.old, r.new);
  end loop;
end
$mig$;

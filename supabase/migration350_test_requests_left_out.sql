-- Migration 350: test requests are marked and left out of the request
-- counts (Jonathan, 23 Nov 2026: "yes, leave test requests out of the
-- count"). A test Leonie sent from Fora - Warnford Court was counted
-- as a request in Prices overview, where a month holds about six.
--
-- A request is a test when: it came from an @nomadwise.io address (the
-- rule of migration 244, which already closed those), or one of us
-- closes it as "It was a test" in Enquiries.

alter table public.enquiries
  add column if not exists is_test boolean not null default false;

comment on column public.enquiries.is_test is
  'A test by the team, not a real request: left out of request counts.';

-- The tests so far: the two from a nomadwise.io address and Leonie's
-- of 23 Nov 2026 from her own address.
update public.enquiries
   set is_test = true
 where handled_note like 'Team test (nomadwise.io address)%'
    or id = '9928b919-cc54-455a-9660-6eb88744f06c';

-- From now on a request from a nomadwise.io address is marked as well
-- as closed.
select public.pm_patch_fn('public.enquiry_after_insert()',
  $a$           handled_note = 'Team test (nomadwise.io address), not sent to the space.'
     where id = new.id;$a$,
  $a$           handled_note = 'Team test (nomadwise.io address), not sent to the space.',
           is_test = true
     where id = new.id;$a$,
  'is_test = true');

-- Closing a waiting request as a test.
select public.pm_patch_fn('public.admin_enquiry_close(uuid,text,boolean)',
  $a$if p_reason not in ('handled', 'unreachable', 'spam') then$a$,
  $a$if p_reason not in ('handled', 'unreachable', 'spam', 'test') then$a$,
  $a$'spam', 'test')$a$);

select public.pm_patch_fn('public.admin_enquiry_close(uuid,text,boolean)',
  $a$                          else 'Spam.' end
   where id = p_id;$a$,
  $a$                          when 'test' then 'A test by us, not a real request.'
                          else 'Spam.' end,
         is_test = (p_reason = 'test')
   where id = p_id;$a$,
  'A test by us, not a real request.');

-- Prices overview: requests are counted without the tests.
select public.pm_patch_fn('public.admin_prices_dashboard()',
  $a$     where l.type = 'coworking'
       and e.created_at >= current_date - 89$a$,
  $a$     where l.type = 'coworking'
       and not e.is_test
       and e.created_at >= current_date - 89$a$,
  'and not e.is_test');

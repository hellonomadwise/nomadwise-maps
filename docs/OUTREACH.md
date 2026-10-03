# Outreach: the spaces we talk to

Control centre, Team tools menu, **Outreach** (or
`nomadmaps.io/?admin=outreach`). Migration 121.

## What it is

One list of every cafe, coworking and coliving space we are in
conversation with: the ones that emailed hello@nomadwise.io, the ones
that filled in a form on nomadwise.io, and (next) the ones we invite.
Each has a card with who they are, what they wrote, where they are in
the conversation, our notes, and the space on the map when we can
match it.

## Stages

| Stage | Meaning | Who moves it |
|---|---|---|
| New | They wrote, we have not answered | set on arrival |
| Contacted | We wrote to them | set when an email is sent |
| Replied | They answered us | a founder ("They replied", or "Log what they wrote") |
| Claimed | They claimed a page with the same email | by itself |
| Verified | They pay | by itself |
| Not now / Declined | Their answer | a founder |
| Unsubscribed | They used the link in an email | by itself |

## Replying

**Reply** on a card opens the email with a template already filled in
with their name, space, the claim link for their space (with their
email in it, so the form opens half done) and the Verified price for
their country when we know it, otherwise "around a day pass a month".
Read it, change anything, press Send. It goes from
hello@nomadwise.io through Postmark, replies land in the inbox as
usual, a copy is sent to hello@ so the inbox has it too, and the card
moves to Contacted.

Templates are edited from the page icon at the top. Rules for the
words: no em dashes, no promised times, prices with their symbol,
"Owner account" never "members area".

Guard rails, all enforced in the database:

- never to someone who unsubscribed;
- no second email within 30 days unless "send anyway" is ticked;
- at most 40 outreach emails a day;
- an email with a `{placeholder}` still in it is refused;
- an unsubscribe line is added to any email that lacks one.

## How contacts arrive

- **Website forms.** The ten-minute website sync reads every form on
  nomadwise.io except the enquiry pop-up (Add Coworking Space, Add
  Cafe, Recommendations from Users) and files each submission once.
- **The inbox backlog.** A file of contacts is imported with the
  upload icon at the top: open the file, select all, copy, press the
  icon. The file is not kept in the code repository, because the site
  is built from it and people's names and addresses do not belong
  there. Importing twice does no harm.
- **By hand.** The person icon at the top: a space that emailed, or
  one we came across and want to invite.

New emails to hello@ are not read automatically. When one comes in
from a space, add it by hand or use "Log what they wrote" on its card.

## Not built yet

- The campaign to spaces already listed ("your page is on
  nomadwise.io, claim it"), in small daily batches. Postmark does not
  allow email to people who never asked to hear from us on its normal
  stream, so this wants a decision on how it is sent before it is
  built.
- "Add to outreach" from a space in the control centre or on the map.
- Reading replies from the inbox by itself.

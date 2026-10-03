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

There are two ways to send from that box:

- **Send from here** goes out at once from hello@nomadwise.io through
  Postmark. For answering someone who wrote to us.
- **Open in mail app** opens the same email as a draft in the
  computer's mail app (Spark), to send by hand from whichever inbox
  you choose. For invitations to spaces that have not written to us:
  an ordinary email from our own mailbox, one at a time. The full text
  is also put on the clipboard in case the draft is cut short. After
  sending, press "I sent it" so the card moves on (migration 122).
  Spark must be the default email app on the computer for the draft
  to open there.

Templates are managed from the page icon at the top: tap one to
change its name, subject or words, or press New template (migration
123). Placeholder chips above the email put one in at the cursor, and
a placeholder we do not fill in is refused when saving, with its name. Rules for the
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
- **Rows from a spreadsheet.** The same upload icon also takes rows
  copied from a sheet (or typed lines such as "Cafe Central,
  hello@cafecentral.pt, Lisbon"). With a header row the columns are
  read by name; without one each cell is recognised by what it looks
  like. The box shows the first few as read, and asks which group they
  belong to, before anything is filed.
- **Listed spaces.** Pick the "Listed, unclaimed" group and press
  "Bring in listed spaces": every space on nomadwise.io that nobody
  has claimed gets a card (migration 124). Nothing is sent. Where we
  have no address, the ten-minute sync reads the space's own website
  for one, a few spaces each run, each space once, and the card picks
  it up.
- **By hand.** The person icon at the top: a space that emailed, or
  one we came across and want to invite.

The chips at the top narrow the list to one group: Wrote to us,
Listed and unclaimed, or Prospects. Cards with an address come first.

There is no reading of pictures in the app. A screenshot of a list of
spaces can be turned into an import file in a Claude session and then
imported with the upload icon.

New emails to hello@ are not read automatically. When one comes in
from a space, add it by hand or use "Log what they wrote" on its card.

## Not built yet

- Sending invitations to the listed spaces as a daily batch. They
  can be brought in and written to one at a time already; how and
  whether they are invited at all is Leonie's decision.
- "Add to outreach" from a space in the control centre or on the map.
- Reading replies from the inbox by itself.

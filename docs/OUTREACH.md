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

A stage set by mistake can be put back two ways: the message that
confirms a stage change carries **Undo** for a few seconds, and a
Replied card has **Did not reply**, which returns it to Contacted (or
to New if we never wrote to them). The three dots also hold every
stage.

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
- **From my own inbox** (it was called "Open in mail app") gets the
  same email ready to send by hand from whichever inbox you choose.
  For invitations to spaces that have not written to us: an ordinary
  email from our own mailbox, one at a time. After sending, press
  "I sent it" so the card moves on (migration 122).
  - On Windows, Spark cannot be handed an email from a web page
    (Readdle's own help page: Spark cannot be set as the default email
    app on Windows). So the box offers three buttons, Copy the
    address, Copy the subject, Copy the email, to paste into a new
    email in Spark. The text is also put on the clipboard.
  - On a Mac with Spark as the default email app (Spark, Settings,
    General, "Make default") the draft opens in Spark by itself.

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

## Who looked at claiming (7 Oct 2026, migration 153)

When someone opens the claim page for a space and leaves without
claiming, the space shows under "Looked at the claim page" on the path
(the last 60 days; our own devices are left out) and, for looks of the
last two weeks, as a job in "Next up". Its card says when, how often,
how far they got and from where. From the card: Reply (the follow-up
template is picked), WhatsApp (type the number or look it up on
Google; WhatsApp opens with the message written; "I sent it" records
it), or "Done for now". Writing to the space, or "Done for now", takes
it off the step until its claim page is opened again.

The visitor is not known to be the owner, so both templates say "if
that was you". Nothing is sent by itself.

## The whole picture (7 Oct 2026, migration 153)

The card above the path counts every place we know of once, top down:
found and not checked, candidates, on the map only, in the queue,
live; the live ones closed or open; the open ones claimed, set up by
us, tests, not claimed; the unclaimed by how far Outreach has got with
them. Three columns: all, coworking, cafes. Each indented group adds
up to the line above it. "The path" counts lines in Outreach instead
(a space can have two, and people with no page are in it), so the two
do not match one for one.

## Signs of interest (7 Oct 2026, migration 154)

The first of three cards at the top of Outreach (the others: The
path, The whole picture). Each way a space shows interest is a row
with how many spaces stand there now, what we know, and the one thing
to do: they wrote back, began the claim form and stopped, made an
account on the map without claiming, looked at the claim page, a
follow-up has come due; and after claiming: never been in, changed
nothing, looked at Verified, set up by us. Tap a row for its spaces.

An account on the map counts as a space's when its address is the one
on the space's website or at the website's own domain, or its name or
its address's domain is the space's name. A public mail domain alone
never counts. The template "Follow-up: they made an account on the
map" is picked when replying from such a card. The phone hears of a
new match within the half hour.

## Where a claim page visitor was (7 Oct 2026, migration 154)

The "Claim page opened" notice, and the look's card here, say roughly
where the visitor was against the space: its own area, its country,
or another country. Two things are read: where the internet connection
is, and which time zone the device's clock is set to. A VPN moves the
first and not the second, so "the connection shows Singapore, but the
device's clock is on Indonesia time" means: probably there, through a
VPN. Looks from nearer the space come first in the list.

It is a hint, never proof. Someone from the space can be travelling,
and a visitor in the same town can be a customer.

## A look that follows our own message (7 Oct 2026, migration 156)

When a space opens its claim page through the link in a WhatsApp or
email we sent, or straight after we wrote to it, the notice and the
look's card say so ("most likely the person we wrote to") and the look
comes first in the list. That counts for more than where the visitor
is: the first one was an owner with a French number and a space in
Lisbon.

The WhatsApp box fills in Google's number for the place by itself when
the line has none (asked once per space), and has links to the place
on Google Maps, a search, and the space's website and Instagram, for
finding another number by hand.


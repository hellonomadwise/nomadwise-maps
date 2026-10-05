-- ============================================================
-- Migration 134: page upgrades for two pages Jonathan requested on
-- 5 Oct 2026: Monday (Uluwatu) and FLOW Workspace (Sanur).
-- (Applied automatically by the build; nothing to paste.)
--
-- Nothing on a public page changes with this file. Each draft waits
-- on its page in Page upgrades for its own Go, and each price change
-- waits in Price check for its own Go.
--
-- 1. Drafts: a page title, a search description and a page
--    description for each page (docs/PAGE_UPGRADES.md). Written from
--    what people search (Ahrefs, 5 Oct 2026: both pages are found by
--    the space's own name) and from each space's own website. Every
--    price is written as that website shows it. The "Based on" line
--    of each draft names the pages it came from.
--    A page with an owner keeps its owner's description: if Monday
--    has one, the loader leaves its description draft out and loads
--    the title and the search description only.
--
-- 2. Price check (docs/PRICE_CHECK.md), done on the way because the
--    drafts quote prices:
--      Monday          all three prices on our page are lower than on
--                      their website (three changes).
--      FLOW Workspace  all five prices match (stamped as checked).
--    Products their sites sell that our pages do not show are named
--    in each summary and not proposed.
--
-- Built on main at b440baa. It adds this one file and touches no
-- other.
-- ============================================================

select public.import_page_upgrades($drafts$
[
 {
  "slug": "monday",
  "kind": "title",
  "text": "Monday Coworking and Coffee, Uluwatu: Prices, WiFi, Hours",
  "note": "Ahrefs, 5 Oct 2026: this page is at position 4 in Indonesia for \"monday coworking and\" (400 to 700 searches a month; it is the start of the space's full name, Monday Coworking and Coffee), behind their Instagram, their own website and Tripadvisor. The current title does not carry the full name. \"coworking uluwatu\" is 60 a month and is left to the location page."
 },
 {
  "slug": "monday",
  "kind": "search_description",
  "text": "Monday Coworking and Coffee in Ungasan, Uluwatu. Daily Pass Rp 225.000, WiFi at 202 Mbps, phone booths, meeting rooms and a cafe. Open Mon to Sat, 8am to 11pm.",
  "note": "Price as shown on https://mondaybali.com/coworking (\"Daily Pass\", \"Rp 225.000\"), checked 5 Oct 2026. WiFi speed, opening hours and area are the ones on our page. Phone booths, meeting rooms and cafe are on their website. Written for the name search (Ahrefs, 5 Oct 2026). The price cards on our page still say 200,000 IDR until the price check in this same upload gets its Go, so press that first."
 },
 {
  "slug": "monday",
  "kind": "description",
  "text": "Monday Coworking and Coffee is a coworking space with its own cafe in Ungasan, in the Uluwatu area of Bali. It was founded in October 2023. We measured the WiFi at 202 Mbps. It is open Monday to Saturday from 8am to 11pm and closed on Sundays.\n\n## Prices at Monday\n\nA Daily Pass is Rp 225.000 and includes two hours in a phone booth. A Weekly Pass is Rp 1.300.000 and is valid for seven days, Sunday not included. A Monthly Pass is Rp 2.500.000 and adds access to the private booths, a locker when one is free, one guest day pass and 50 pages of black and white printing.\n\nFor shorter stays there is a 4-Hours Pass at Rp 125.000 (sign up before 4pm) and an Owl Nighter Pass at Rp 175.000 for the evening (sign up after 4pm). A 3 Days Pass is Rp 500.000, to use within one week, and a 10 Days Pass is Rp 1.800.000, to use within one month.\n\nMeeting rooms are booked by the hour: Rp 150.000 for the 4 Seater and Rp 200.000 for the 6 Seater.\n\nThese are the prices on Monday's own website, checked on 5 October 2026. Their promo page and Instagram account carry the current offers.\n\n## Where Monday is\n\nMonday is in Ungasan, close to the local golf course, on a quieter side road away from the main bustle of Uluwatu. That makes it a calm place to work that is still easy to reach.\n\n## Working at Monday\n\nThere are large shared desks, small booths for two to four people, a small sofa area and seats along the big windows. Phone booths are there for private calls, which keeps the main room fairly quiet. The former photo studio is now a quiet work zone.\n\nAt the front is an open-air cafe area for breaks, and at the back there is more outdoor seating in the garden. The meeting rooms are at the back of the building.\n\nThe WiFi is one of the fastest in the Uluwatu area, and the main room has a cozy, high-end feel that makes it easy to settle into focused work.\n\n## Interior and atmosphere\n\nThe main workspace is best described as dark chic: walls in deep tones, a cozy but polished feel, and plants throughout. The meeting rooms are the opposite: lighter, with white walls, simple furniture and windows that open onto the back garden. The whole place looks fresh and well kept.\n\n## The cafe\n\nThe cafe serves coffee, matcha, tea and chocolate drinks, with croissants, pastries, sandwiches, pies and quiches.\n\n## Community and events\n\nMonday puts a lot into its community. There are many regular members, a large community board where you can share your business or see what is coming up, and regular events. In October 2026 their website listed a Breakfast Club on Wednesday mornings and the Monday Padel Club on Thursdays. The space can also be hired for events outside of work, such as art nights and workshops.",
  "note": "Prices as shown on https://mondaybali.com/coworking and https://mondaybali.com/meeting-room, checked 5 Oct 2026. Founding month from https://mondaybali.com/about-us, cafe menu from https://mondaybali.com/cafe, events from https://mondaybali.com/. Everything about the rooms, the location and the atmosphere is kept from the description already on the page, shortened; the photo studio is left out because our own Best Of text says it became a quiet work zone. WiFi speed and opening hours are the ones on our page."
 },
 {
  "slug": "indonesia-bali-flow-workspace",
  "kind": "title",
  "text": "FLOW Workspace Sanur, Bali: Coworking Prices, WiFi, Hours",
  "note": "Ahrefs, 5 Oct 2026: this page is at position 9 in Indonesia for \"flow workspace\" (1,000 to 1,100 searches a month), behind their Instagram, their own website, LinkedIn and two unrelated results (Google Workspace Flows, a Jakarta office called Flow). \"flow workspace sanur\" is 30 a month. Their own title reads \"coworking in Sanur\", so Sanur and Bali are in ours to mark it as this FLOW."
 },
 {
  "slug": "indonesia-bali-flow-workspace",
  "kind": "search_description",
  "text": "FLOW Workspace is a coworking space in Sanur, Bali. Day pass 300K IDR, WiFi at 150 Mbps, phone booths, meeting rooms and 24/7 access for registered members.",
  "note": "Price as shown on https://www.flowworkspacebali.com/ourworkspaces (\"FLOW Day Pass\", \"300K/day\"), checked 5 Oct 2026. WiFi (\"150mbps\") and \"Registered members have 24/7 access\" are from the same page; phone booths and meeting rooms from https://www.flowworkspacebali.com/. Replaces the generic line shared by most pages."
 },
 {
  "slug": "indonesia-bali-flow-workspace",
  "kind": "description",
  "text": "FLOW Workspace is a coworking space in Sanur, Bali, at Jl. Danau Poso No.66. Registered members have 24/7 access, the WiFi is 150 Mbps, and you can buy anything from a single day to a six-month membership.\n\n## Prices at FLOW Workspace\n\nThe FLOW Day Pass is 300K IDR a day. It covers the hot desks and standing desks, the private phone booths and printing on request, with access until midnight.\n\nThe FLOW Community membership is 1.05mil IDR a week, 3.8mil IDR a month, 10.9mil IDR for 3 months or 21.1mil IDR for 6 months. It comes with invitations to member-only workshops and community events and, depending on the plan, the member-only meeting room and a locker.\n\nFLOW 10 Days/month is 2.4mil IDR a month, for people who want a flexible ten days each month without a longer commitment.\n\nMeeting rooms are booked by the hour with a two-hour minimum: IDR 150,000 an hour for the Small Meeting Room (1 to 4 people) and IDR 300,000 an hour for the Large Meeting Room (5 to 15 people). Half-day and full-day rates are on their website, and booking is by WhatsApp or walk-in.\n\nThese are the prices on FLOW Workspace's own website, checked on 5 October 2026.\n\n## The space\n\nThere are two work zones. Free FLOW is the collaborative zone, with flexible desks and comfortable seating. Focus FLOW is the quiet zone for deep work, soundproofed and with natural light.\n\nAround them are privacy booths for calls, standing desks, a coffee station and lunch area, the FLOW Terrace (an open-air lounge) and Green FLOW. Private offices are also available.\n\n## Opening hours and your first visit\n\nRegistered members can come and go at any hour. New members register while the team is in: Monday to Friday 9am to 6pm and Saturday 9am to 5pm, closed on Sunday. Plan your first visit inside those hours.",
  "note": "The page had no description. Prices, zones, WiFi and hours as shown on https://www.flowworkspacebali.com/ourworkspaces, meeting rooms on https://www.flowworkspacebali.com/meeting-rooms, address on https://www.flowworkspacebali.com/, all checked 5 Oct 2026. Their footnote on the meeting room and locker (\"Exclusive for up to monthly membership\") can be read two ways, so the draft only says \"depending on the plan\"."
 }
]
$drafts$::jsonb, 'Monday and FLOW Workspace, 5 Oct 2026');

select public.import_price_check($check$
[
 {
  "slug": "monday",
  "url": "https://mondaybali.com/coworking",
  "checked_on": "2026-10-05",
  "summary": "All three prices on our page are lower than on their Coworking Membership page: Daily Pass Rp 225.000 (ours 200,000), Weekly Pass Rp 1.300.000 (ours 1,000,000), Monthly Pass Rp 2.500.000 (ours 2,400,000). Their site also sells a 4-Hours Pass, an Owl Nighter Pass, a 3 Days Pass, a 10 Days Pass and two meeting rooms by the hour, which our page does not show; none is proposed here.",
  "items": [
   {
    "ref": "Day Pass",
    "result": "changed",
    "amount": 225000,
    "note": "Seen on their Coworking Membership page: \"Daily Pass\", \"Rp 225.000\""
   },
   {
    "ref": "Week Pass",
    "result": "changed",
    "amount": 1300000,
    "note": "Seen on their Coworking Membership page: \"Weekly Pass\", \"Rp 1.300.000\", \"Valid for 7 days (Sunday not included)\""
   },
   {
    "ref": "Month Pass",
    "result": "changed",
    "amount": 2500000,
    "note": "Seen on their Coworking Membership page: \"Monthly Pass\", \"Rp 2.500.000\", \"Valid for 30 days\""
   }
  ]
 },
 {
  "slug": "indonesia-bali-flow-workspace",
  "url": "https://www.flowworkspacebali.com/ourworkspaces",
  "checked_on": "2026-10-05",
  "summary": "All five prices on our page match their Coworking page. Their site also lists a 6 month FLOW Community membership (21.1mil) and two meeting rooms by the hour, which our page does not show; none is proposed here.",
  "items": [
   {
    "ref": "Day Pass",
    "result": "same",
    "note": "Seen on their Coworking page: \"FLOW Day Pass\", \"300K/day\""
   },
   {
    "ref": "Week Pass",
    "result": "same",
    "note": "Seen on their Coworking page: \"FLOW Community\", \"1.05mil/week\""
   },
   {
    "ref": "Month Pass",
    "result": "same",
    "note": "Seen on their Coworking page: \"FLOW Community\", \"3.8 mil/month\""
   },
   {
    "ref": "3 Month Pass",
    "result": "same",
    "note": "Seen on their Coworking page: \"FLOW Community\", \"10.9mil/3 month\""
   },
   {
    "ref": "10 Day Month Pass",
    "result": "same",
    "note": "Seen on their Coworking page: \"FLOW 10 Days/month\", \"2.4mil/month\""
   }
  ]
 }
]
$check$::jsonb, 'Monday and FLOW Workspace, 5 Oct 2026');

-- Migration 133: the first price check (5 Oct 2026), four spaces
-- Jonathan requested: 4 WALLS Coworking (Hamburg), ACE Coworking Space
-- (Da Nang), Alt_ChiangMai, AT 06 (Canggu).
--
-- Each price on our page was compared with the space's own website,
-- and with nothing else. Result:
--   4 WALLS       10 of 10 the same; 2 products on their site that we
--                 do not show are proposed as new.
--   Alt_ChiangMai 16 of 18 the same; the meeting room for 4 and for 8
--                 hours is cheaper on their site (two changes); monitor
--                 and locker rental are proposed as new (six).
--   ACE, AT 06    no website of their own, only Instagram, which
--                 cannot be read: every price is marked as not
--                 confirmed and nothing is proposed.
--
-- Nothing on a public page changes with this file. The two changes
-- and eight new products wait in Price check for a Go each.
select public.import_price_check($check$[
 {
  "slug": "germany-hamburg-4-walls-coworking",
  "url": "https://www.4walls-hamburg.de/coworking-raeume-eventlocation/",
  "checked_on": "2026-10-05",
  "summary": "All ten prices on our page match their site. Their site also lists two things we do not show: a monthly subscription (285 € plus VAT, on their home page) and a Monday or Friday price for the large conference room (450 € plus VAT). Breakfast and lunch catering are priced 'from' per person and were left out.",
  "items": [
   {
    "ref": "de90b160",
    "result": "same",
    "note": "Seen on their Coworking page: \"1 Stunde = 7 € inkl. MwSt\""
   },
   {
    "ref": "1d04b2a2",
    "result": "same",
    "note": "Seen on their Coworking page: \"½ Tag (4 Stunden) = 15 € inkl. MwSt\""
   },
   {
    "ref": "eba86784",
    "result": "same",
    "note": "Seen on their Coworking page: \"1 Tag (9 Stunden) = 20 € inkl. MwSt\""
   },
   {
    "ref": "6889b5c8",
    "result": "same",
    "note": "Seen on their Coworking page: \"10er Karte + 1/2 Tag free = 150 € inkl. MwSt\""
   },
   {
    "ref": "9f43c2d1",
    "result": "same",
    "note": "Seen on their Coworking page: \"10er Karte + 1 Tag free = 200 € inkl. MwSt\""
   },
   {
    "ref": "82c95367",
    "result": "same",
    "note": "Seen on their Coworking page: Konferenzraum klein, \"1 Stunde = 35 € + MwST.\""
   },
   {
    "ref": "1e903366",
    "result": "same",
    "note": "Seen on their Coworking page: Konferenzraum groß, \"½ Tag = 400 € + MwST.\""
   },
   {
    "ref": "42e274e7",
    "result": "same",
    "note": "Seen on their Coworking page: Konferenzraum groß, \"1 Tag = 650 € + MwST.\""
   },
   {
    "ref": "619181ee",
    "result": "same",
    "note": "Seen on their Coworking page: 2. OG., \"1 Tag = 1000 € + MwST.\""
   },
   {
    "ref": "169ac71a",
    "result": "same",
    "note": "Seen on their Coworking page: Café Catering, \"Getränkeflat 1 Tag = 18 € p.P. + MwST.\""
   },
   {
    "result": "new",
    "name": "Monthly Subscription",
    "category": "coworking",
    "amount": 285,
    "label": "€ 285",
    "currency": "EUR",
    "vat_included": false,
    "details": [
     "Price per month, plus VAT",
     "Monday to Friday, 09:00 to 19:00",
     "Fast internet",
     "Water station included",
     "Use of the lockers, subject to availability",
     "15% off in the café"
    ],
    "note": "On their home page (https://www.4walls-hamburg.de/): \"NEU: Monatsabo\", \"Preis, Monatlich: 285€ zzgl. MwSt\". Not on our page."
   },
   {
    "result": "new",
    "name": "Large Conference Room (Full Day, Monday or Friday)",
    "category": "meeting_room",
    "amount": 450,
    "label": "€ 450",
    "currency": "EUR",
    "vat_included": false,
    "details": [
     "Price per day on a Monday or a Friday, plus VAT"
    ],
    "note": "Seen on their Coworking page under Konferenzraum groß: \"Special: Mo. & Fr. 1 Tag = 450€ + MwSt\". Not on our page."
   }
  ]
 },
 {
  "slug": "vietnam-da-nang-ace-coworking-space",
  "url": "https://www.instagram.com/ace_coworking/",
  "checked_on": "2026-10-05",
  "summary": "None of the eleven prices could be confirmed. ACE has no website of its own that could be found; the link on file is its Instagram, which cannot be read for prices, and other directories are not a source we use. Nothing is proposed.",
  "items": [
   {
    "ref": "5ca1eea7",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "4df42c35",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "0599c332",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "232bde6c",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "1495a20c",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "77120ff7",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "39818b05",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "1625ecab",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "5ef97e6f",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "696be3e1",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "2c8b9af1",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   }
  ]
 },
 {
  "slug": "thailand-chiang-mai-altchiangmai-coliving-coworking-space",
  "url": "https://www.altcoliving.com/alt-chiangmai/work/",
  "checked_on": "2026-10-05",
  "summary": "Sixteen of our eighteen prices match their site. The meeting room for 4 hours and for 8 hours is cheaper on their site than on our page (1,200 and 2,000 THB, ours say 1,500 and 2,500). Their site also lists monitor and locker rental, which we do not show.",
  "items": [
   {
    "ref": "103e334d",
    "result": "same",
    "note": "Seen on their Work page: For Casual Explorers, 4 Hour, 220 THB"
   },
   {
    "ref": "2c66a4a0",
    "result": "same",
    "note": "Seen on their Work page: For Casual Explorers, 1 Day, 320 THB"
   },
   {
    "ref": "51cee706",
    "result": "same",
    "note": "Seen on their Work page: For Casual Explorers, 1 Week, 1,600 THB"
   },
   {
    "ref": "63515703",
    "result": "same",
    "note": "Seen on their Work page: For Casual Explorers, 15 Days, 3,500 THB"
   },
   {
    "ref": "5c3db2eb",
    "result": "same",
    "note": "Seen on their Work page: Hot Desk, 1 Month, 4,000 THB"
   },
   {
    "ref": "b9c8e1fd",
    "result": "same",
    "note": "Seen on their Work page: Hot Desk, 2 Months, 8,000 THB"
   },
   {
    "ref": "6503d880",
    "result": "same",
    "note": "Seen on their Work page: Hot Desk, 3 Months, 10,000 THB"
   },
   {
    "ref": "d83cb64a",
    "result": "same",
    "note": "Seen on their Work page: Cold Desk (their name for a reserved desk), 1 Month, 5,500 THB"
   },
   {
    "ref": "820ca902",
    "result": "same",
    "note": "Seen on their Work page: Cold Desk, 2 Months, 11,000 THB"
   },
   {
    "ref": "ff3bc128",
    "result": "same",
    "note": "Seen on their Work page: Cold Desk, 3 Months, 15,000 THB"
   },
   {
    "ref": "e02ab78b",
    "result": "same",
    "note": "Seen on their Work page: Private Offices TYPE A, 1-5 Months, 17,000 THB/month"
   },
   {
    "ref": "a3099c5b",
    "result": "same",
    "note": "Seen on their Work page: Private Offices TYPE A, 6 Months +, 15,000 THB/month"
   },
   {
    "ref": "543763e4",
    "result": "same",
    "note": "Seen on their Work page: Private Offices TYPE B, 1-5 Months, 30,000 THB/month"
   },
   {
    "ref": "8d6d3b32",
    "result": "same",
    "note": "Seen on their Work page: Private Offices TYPE B, 6 Months +, 17,000 THB/month. That is a large drop from 30,000 and the same figure as Type A; it may be a slip on their side, but it is what their site says."
   },
   {
    "ref": "7ee17dd3",
    "result": "same",
    "note": "Seen on their Work page: War Room Rental, 1 Hour, 600 THB"
   },
   {
    "ref": "d30d41b9",
    "result": "changed",
    "amount": 1200,
    "note": "Their Work page, War Room Rental: 4 Hours, 1,200 THB. Our page says 1,500 THB."
   },
   {
    "ref": "132b328b",
    "result": "changed",
    "amount": 2000,
    "note": "Their Work page, War Room Rental: 8 Hours, 2,000 THB. Our page says 2,500 THB."
   },
   {
    "ref": "9e99bae9",
    "result": "same",
    "note": "Seen on their Work page: Virtual Office, 1 Year, 20,000 THB"
   },
   {
    "result": "new",
    "name": "Monitor Rental (1 Day)",
    "category": "other",
    "amount": 70,
    "currency": "THB",
    "note": "Their Work page, Monitor Rental: 1 Day, 70 THB. Not on our page."
   },
   {
    "result": "new",
    "name": "Monitor Rental (1 Week)",
    "category": "other",
    "amount": 330,
    "currency": "THB",
    "note": "Their Work page, Monitor Rental: 1 Week, 330 THB. Not on our page."
   },
   {
    "result": "new",
    "name": "Monitor Rental (1 Month)",
    "category": "other",
    "amount": 1200,
    "currency": "THB",
    "note": "Their Work page, Monitor Rental: 1 Month, 1,200 THB. Not on our page."
   },
   {
    "result": "new",
    "name": "Locker Rental (1 Day)",
    "category": "other",
    "amount": 50,
    "currency": "THB",
    "note": "Their Work page, Locker Rental: 1 Day, 50 THB. Not on our page."
   },
   {
    "result": "new",
    "name": "Locker Rental (1 Week)",
    "category": "other",
    "amount": 300,
    "currency": "THB",
    "note": "Their Work page, Locker Rental: 1 Week, 300 THB. Not on our page."
   },
   {
    "result": "new",
    "name": "Locker Rental (1 Month)",
    "category": "other",
    "amount": 1000,
    "currency": "THB",
    "note": "Their Work page, Locker Rental: 1 Month, 1,000 THB. Not on our page."
   }
  ]
 },
 {
  "slug": "bali-canggu-at-06",
  "url": "https://www.instagram.com/at06.bali",
  "checked_on": "2026-10-05",
  "summary": "None of the seven prices could be confirmed. AT 06 has no website of its own that could be found; the link on file is its Instagram, which cannot be read for prices, and other directories are not a source we use. Nothing is proposed.",
  "items": [
   {
    "ref": "da728fac",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "ac6b8430",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "8e166da6",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "0569a6ab",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "3ca2f86d",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "88da99fe",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   },
   {
    "ref": "5b00e54c",
    "result": "not_found",
    "note": "They have no website of their own that could be found: the only link on file is their Instagram, which cannot be read for a price list. This price could not be confirmed. It may well still be right."
   }
  ]
 }
]$check$::jsonb, 'price check 5 Oct 2026');

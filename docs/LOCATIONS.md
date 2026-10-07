# Country, Region, Location: how a space is filed

A page on nomadwise.io sits under a Country and a Region (always), and
a Location (sometimes). A Region can be wider than a city: Bali is a
Region and Uluwatu is a Location in it. Munich is a Region and
Maxvorstadt is a Location in it.

The Region is what a page needs. A Location is added only when it is
almost certain, because a wrong one puts the space on the wrong
neighbourhood page. No Location is always fine.

## How a Location is decided (7 Oct 2026, migration 155)

Two signs are read for a space in review:

- **Its area's name.** One of the names of where it is (its own
  neighbourhood, the names Google gives the area, its town) is a
  Location of the space's own Region.
- **The places nearby.** The nearest listed places of that Region
  agree on a Location: at least two of them, and at least two in
  three, among the six nearest within reach that have a Location. (A
  listed place with no Location says nothing either way.)

| What the signs say | What happens |
|---|---|
| Both, and the same Location | It is assigned. The card says why. |
| One of them, or two that disagree | A suggestion on the card: "Use it", or look at the map. |
| Neither | No Location. |

A Location you choose yourself always wins, and so does "No Location".

"Within reach" depends on the kind of Region:

| Kind | Reach |
|---|---|
| A city | 1.5 km |
| An island | 4 km |
| A rural or wide area | 8 km |

Every Region counts as a city until told otherwise. The islands and
wide areas were sorted by name on 7 Oct 2026; "Change" at the bottom
of the map sets it for a Region.

A Location of the same name in another Region no longer counts (Kuta
on Lombok is not filed under Kuta on Bali): a name only points to a
Region the space can be in, which means within 80 km of the Region's
centre, or a Region whose own name is among the space's area names.

## The map

On a space's card in the control centre, "Nearby spaces on a map" (or
the NEARBY cell) opens a map of the listed places around it, each a
dot in the colour of its Location, grey for none, and the space itself
as the dark dot. Above the map is the verdict in a sentence. Below it:
the Locations nearby with how many places each has (tap one, then "Use
..."), the Region's other Locations, "No Location", and the full list.

A previous space's Location makes the next one easier to decide, but
not always: a street can be the border.

## Where the facts come from

- Each listed place's Region and Location are kept on the venue
  (`webflow_region_id`, `webflow_location_id`) by the nightly website
  sync. Until its first run after migration 155 they are filled in
  from the Location's name and the nearest Region, which is close but
  not exact.
- Google's names for a space's area are asked once, when the space is
  first prepared for the site, and kept (`g_area`). Before, they were
  asked again every ten minutes while a space sat in the queue.
- The verdict is made in the database (`location_verdict`), so the
  sync and the map say the same thing.

## Not built yet

- Proposing a new Location when five places without one share an area
  name. The area names have to be collected first.
- Reading the area names of pages that are already live and have no
  Location (it would ask Google once per page).

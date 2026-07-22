#!/usr/bin/env python3
"""Phase 1 of the Webflow integration: match the nomadwise.io
coworking listings (scripts/webflow_listings.json, extracted from the
Webflow CMS) against the Nomadmaps database, and write a report.

Read-only everywhere. Output: ci-debug/webflow_match_report.json
"""
import json
import os
import urllib.request

SUPABASE_URL = os.environ['SUPABASE_URL'].rstrip('/')
SERVICE_KEY = os.environ['SUPABASE_SERVICE_ROLE_KEY']


def req(url):
    r = urllib.request.Request(url, headers={
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
    })
    with urllib.request.urlopen(r) as resp:
        return json.loads(resp.read().decode())


here = os.path.dirname(__file__)
listings = json.load(open(os.path.join(here, 'webflow_listings.json')))

venues = req(f'{SUPABASE_URL}/rest/v1/venues'
             '?select=id,name,google_place_id,wifi_speed_mbps')
venue_pids = {v['google_place_id']: v for v in venues
              if v.get('google_place_id')}

discovered = []
offset = 0
while True:
    page = req(f'{SUPABASE_URL}/rest/v1/discovered_places'
               '?select=google_place_id,name,signal_wifi,signal_laptop,'
               'signal_power,signal_negative'
               f'&limit=1000&offset={offset}')
    discovered.extend(page)
    if len(page) < 1000:
        break
    offset += 1000
disc_pids = {d['google_place_id']: d for d in discovered}

wf_pids = {l['place_id'] for l in listings if l['place_id']}

matched_venues = [l for l in listings
                  if l['place_id'] and l['place_id'] in venue_pids]
matched_discovered = [l for l in listings
                      if l['place_id'] and l['place_id'] in disc_pids
                      and l['place_id'] not in venue_pids]
webflow_only = [l for l in listings
                if l['place_id'] and l['place_id'] not in venue_pids
                and l['place_id'] not in disc_pids]
no_pid = [l for l in listings if not l['place_id']]
maps_only_venues = [v for p, v in venue_pids.items() if p not in wf_pids]

report = {
    'webflow_listings_total': len(listings),
    'webflow_with_place_id': len(wf_pids),
    'webflow_without_place_id': len(no_pid),
    'nomadmaps_venues_total': len(venues),
    'nomadmaps_discovered_total': len(discovered),
    'matched_to_nomadmaps_venues': len(matched_venues),
    'matched_to_nomadmaps_discovered': len(matched_discovered),
    'webflow_only_new_to_nomadmaps': len(webflow_only),
    'nomadmaps_venues_not_on_webflow': len(maps_only_venues),
    'samples': {
        'matched_venues': [l['name'] for l in matched_venues[:10]],
        'webflow_only': [l['name'] for l in webflow_only[:10]],
        'maps_only_venues': [v['name'] for v in maps_only_venues[:10]],
        'no_pid': [l['name'] for l in no_pid[:10]],
    },
}

os.makedirs('ci-debug', exist_ok=True)
with open('ci-debug/webflow_match_report.json', 'w') as fh:
    json.dump(report, fh, indent=2)
print(json.dumps(report, indent=2))

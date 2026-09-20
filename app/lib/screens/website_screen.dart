import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/venue.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'venue_detail.dart';

/// Admin-only: the nomadwise.io control centre.
///
/// Four tabs. The INBOX is the only one that asks for decisions: new
/// spaces that are not on the site yet, queued spaces that need a
/// Region, and prepared proposals waiting for Approve. Acting on a
/// card moves it out, the count on the tab goes down, and an empty
/// inbox shows an all-clear. DRAFTS, RELEASED and SITEMAP are for
/// looking things up.
///
/// The nightly sync (scripts/webflow_sync.py) does the heavy lifting
/// between visits: it prepares proposals for queued spaces, creates the
/// Webflow draft for approved ones, and marks pages released once they
/// are live. So most actions here take effect "tonight".
class WebsiteScreen extends StatefulWidget {
  const WebsiteScreen({super.key});
  @override
  State<WebsiteScreen> createState() => _WebsiteScreenState();
}

class _WebsiteScreenState extends State<WebsiteScreen> {
  final _supabase = SupabaseService();

  List<Map<String, dynamic>>? _inbox;
  List<Map<String, dynamic>> _drafts = [];
  List<Map<String, dynamic>> _released = [];
  List<Map<String, dynamic>> _sitemap = [];
  List<Map<String, dynamic>> _regions = [];
  List<Map<String, dynamic>> _hidden = [];
  List<Map<String, dynamic>> _closed = [];
  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _countries = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _supabase.websiteInbox(),
        _supabase.websiteDrafts(),
        _supabase.websiteReleased(),
        _supabase.sitemapPending(),
        _supabase.webflowRegions(),
        _supabase.websiteHidden(),
        _supabase.webflowLocations(),
        _supabase.webflowCountries(),
        _supabase.websiteClosed(),
      ]);
      if (!mounted) return;
      setState(() {
        _inbox = results[0];
        _drafts = results[1];
        _released = results[2];
        _sitemap = results[3];
        _regions = results[4];
        _hidden = results[5];
        _locations = results[6];
        _countries = results[7];
        _closed = results[8];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  // ------------------------------------------------------------ creators

  Future<void> _newRegion() async {
    final made = await Navigator.push<String>(
        context,
        MaterialPageRoute(
            builder: (_) => _NewRegionPage(
                supabase: _supabase, countries: _countries, regions: _regions)));
    if (made != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$made is being created on nomadwise.io; it appears '
              'in the pickers within a minute or two.')));
    }
  }

  Future<void> _newLocation() async {
    final made = await Navigator.push<String>(
        context,
        MaterialPageRoute(
            builder: (_) => _NewLocationPage(
                supabase: _supabase, regions: _regions, locations: _locations)));
    if (made != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$made is being created on nomadwise.io; it appears '
              'in the pickers within a minute or two.')));
    }
  }

  /// Regions or Locations made in Webflow by hand (or by anything other
  /// than the app) reach the pickers on the nightly copy. This asks the
  /// sync to copy them now instead, so they can be used within minutes.
  Future<void> _refreshFromWebflow() async {
    try {
      await _supabase.createTaxonomyRequest(
          {'kind': 'refresh', 'name': 'Refresh from Webflow'});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Copying the site\'s Regions and Locations into '
              'Nomad Maps. Reload in a minute or two.'),
          duration: Duration(seconds: 5)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That did not save: $e'), backgroundColor: Brand.red));
    }
  }

  // ------------------------------------------------------------ actions

  Future<void> _update(Map<String, dynamic> v, Map<String, dynamic> fields,
      String toast) async {
    try {
      await _supabase.updateVenueFields(v['id'], fields);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(toast), duration: const Duration(seconds: 2)));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That did not save: $e'),
          backgroundColor: Brand.red));
    }
  }

  /// New space -> queued. The sync prepares a proposal tonight.
  Future<void> _queue(Map<String, dynamic> v) => _update(
      v,
      {
        'website_status': 'queued',
        'website_prepared': null,
        'website_approved_at': null,
        'website_dismissed_at': null,
      },
      '${v['name']} queued. The full proposal is ready in a few minutes.');

  static const dismissReasons = [
    'Not really a place to work from',
    'Closed, closing or unreliable',
    'Too small or a locals-only gem',
    'Chain or not on brand',
    'Duplicate of a space already on the site',
    'City has no page on nomadwise.io yet',
    'Waiting for photos or more info',
    'Other',
  ];

  /// Not for the site: leaves the inbox (status unchanged), with the
  /// reason kept so the decision makes sense later.
  Future<void> _dismiss(Map<String, dynamic> v) async {
    String? reason = v['website_dismiss_reason'];
    final note = TextEditingController(text: v['website_dismiss_note'] ?? '');
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
              builder: (ctx, setLocal) => AlertDialog(
                title: Text('Why not ${v['name']}?'),
                content: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                            'Kept with the space, so it is clear later why '
                            'it is on Nomad Maps but not on nomadwise.io.',
                            style: TextStyle(fontSize: 12.5, height: 1.4)),
                        const SizedBox(height: 8),
                        ...dismissReasons.map((r) => RadioListTile<String>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(r,
                                  style: const TextStyle(fontSize: 13.5)),
                              value: r,
                              groupValue: reason,
                              onChanged: (x) => setLocal(() => reason = x),
                            )),
                        const SizedBox(height: 6),
                        TextField(
                            controller: note,
                            minLines: 1,
                            maxLines: 3,
                            decoration: const InputDecoration(
                                labelText: 'Note (optional)',
                                hintText: 'Anything worth remembering')),
                      ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  ElevatedButton(
                      onPressed:
                          reason == null ? null : () => Navigator.pop(ctx, true),
                      child: const Text('Not for the site')),
                ],
              ),
            ));
    if (ok != true) return;
    await _update(
        v,
        {
          'website_dismissed_at': DateTime.now().toUtc().toIso8601String(),
          'website_dismiss_reason': reason,
          'website_dismiss_note':
              note.text.trim().isEmpty ? null : note.text.trim(),
        },
        '${v['name']} marked as not for the site.');
  }

  /// One-tap "Not for the site" with a preset reason, for the cases
  /// that need no thought (nomads said laptops are not welcome).
  Future<void> _dismissAs(Map<String, dynamic> v, String reason) => _update(
      v,
      {
        'website_dismissed_at': DateTime.now().toUtc().toIso8601String(),
        'website_dismiss_reason': reason,
        'website_dismiss_note': null,
      },
      '${v['name']} marked as not for the site: ${reason.toLowerCase()}.');

  /// Queued -> back to "New spaces" in the inbox, so it can be
  /// edited and queued again.
  Future<void> _unqueue(Map<String, dynamic> v) => _update(
      v,
      {
        'website_status': 'not_on_site',
        'website_prepared': null,
        'website_approved_at': null,
        'website_region_override': null,
        'website_slug_override': null,
        'website_dismissed_at': null,
      },
      '${v['name']} is back under New spaces.');

  /// Undo "Not for the site".
  Future<void> _restore(Map<String, dynamic> v) => _update(
      v,
      {
        'website_dismissed_at': null,
        'website_dismiss_reason': null,
        'website_dismiss_note': null,
      },
      '${v['name']} is back in the inbox.');

  /// Approve the proposal: the draft is created in Webflow tonight,
  /// with exactly the slug shown on the card.
  Future<void> _approve(Map<String, dynamic> v) async {
    final p = _prepared(v);
    final region = _regionFor(v);
    final slug = p['slug'] ?? (region != null ? _slugPreview(v, region) : null);
    final regionName = p['region'] ?? region?['name'];
    if (slug == null || regionName == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Pick a Region first; the slug is built from it.')));
      return;
    }
    if (_photoCount(v) < minPhotos) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Add at least $minPhotos photos first.')));
      return;
    }
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Approve for nomadwise.io?'),
              content: Text(
                  'Within about ten minutes a draft page will be created '
                  'in Webflow at\n\n'
                  '/coworking/$slug\n\n'
                  'under $regionName. This exact slug is used; if it turns '
                  'out to be taken the space comes back to you instead of '
                  'being renamed. The slug cannot be changed afterwards '
                  'without a redirect. Your photos go in with it; you then '
                  'add the words in Webflow and publish.',
                  style: const TextStyle(height: 1.45)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Not yet')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Approve')),
              ],
            ));
    if (ok == true) {
      await _update(
          v,
          {
            'website_approved_at': DateTime.now().toUtc().toIso8601String(),
            // Lock the slug you approved so it is used exactly.
            'website_slug_override': slug,
            if (region != null) 'website_region_override': region['id'],
            // Approving the suggested photos makes them yours.
            'website_photos_auto': false,
          },
          '${v['name']} approved. The draft is created within minutes.');
      _recordPicks(v);
    }
  }

  Future<void> _editSlug(Map<String, dynamic> v) async {
    final p = _prepared(v);
    final region = _regionFor(v);
    final current = p['slug'] ??
        (region != null ? _slugPreview(v, region) : v['website_slug_override']);
    final ctl = TextEditingController(text: current ?? '');
    final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Change the slug'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text(
                    'This is the last chance to change it: after '
                    'approval the page address is fixed. Lowercase '
                    'letters, numbers and hyphens only.',
                    style: TextStyle(fontSize: 13, height: 1.4)),
                const SizedBox(height: 12),
                TextField(
                    controller: ctl,
                    autofocus: true,
                    decoration: const InputDecoration(
                        prefixText: '/coworking/', labelText: 'Slug')),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Save')),
              ],
            ));
    if (saved != true) return;
    final slug = _slugify(ctl.text);
    if (slug.isEmpty) return;
    // Shown immediately; the sync re-checks it is unique tonight and,
    // if approved, creates the page with it.
    final next = Map<String, dynamic>.from(p)
      ..['slug'] = slug
      ..['url'] = 'https://www.nomadwise.io/coworking/$slug';
    if (p['error'] == 'slug_taken') next.remove('error');
    await _update(
        v,
        {
          'website_slug_override': slug,
          'website_prepared': p['error'] == 'slug_taken' ? null : (p.isNotEmpty ? next : null),
        },
        'Slug saved: /coworking/$slug');
  }

  Future<void> _pickRegion(Map<String, dynamic> v) async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (_) => _RegionPicker(
            regions: _regions,
            forName: v['name'],
            onRefresh: _refreshFromWebflow));
    if (picked == null) return;
    await _update(
        v,
        {
          'website_region_override': picked['id'],
          // Cleared so the card moves back to Queued with the new Region.
          'website_prepared': null,
        },
        '${picked['name']} chosen. The proposal is prepared in a few minutes.');
  }

  /// The full space page (photos, WiFi tests, facts, hours, who
  /// added it), the same one nomads see, plus the admin rows.
  Future<void> _openVenue(Map<String, dynamic> v) async {
    final venue = await _supabase.venueById(v['id']);
    if (!mounted) return;
    if (venue == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load that space.')));
      return;
    }
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => VenueDetailScreen(
                venue: venue,
                onConfirm: () {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text(
                          'To review a space as a nomad, open it from the '
                          'map.')));
                })));
    await _load(); // it may have been queued or edited in there
  }

  /// Review and correct everything the app knows about a space before
  /// it goes to the site: names, place, links, facts and hours.
  Future<void> _editVenue(Map<String, dynamic> v) async {
    final venue = await _supabase.venueById(v['id']);
    if (!mounted) return;
    if (venue == null) return;
    final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => _EditVenuePage(
                venue: venue,
                supabase: _supabase,
                countryGuess: _countryOf(v),
                regions: _regions,
                locations: _locations,
                countries: _countries,
                regionGuess: _regionFor(v),
                locationGuess: _locationGuess(
                    v, (_prepared(v)['region_id'] ?? _regionFor(v)?['id'])),
                googleAreas: _googleAreas(v),
                row: v)));
    if (changed == true) {
      // A prepared proposal stays approvable: the page is built from
      // the latest details on the night it is created.
      final p = _prepared(v);
      if (p.isNotEmpty && p['error'] == null) {
        await _supabase.updateVenueFields(v['id'], {
          'website_prepared': (Map<String, dynamic>.from(p)
            ..['edited_at'] = DateTime.now().toUtc().toIso8601String())
        });
      }
      await _load();
    }
  }

  /// The Location (neighbourhood page) is optional and easy to guess
  /// wrong, so the founder confirms it: pick one in the Region, or
  /// none.
  Future<void> _pickLocation(Map<String, dynamic> v) async {
    final p = _prepared(v);
    final regionId = p['region_id'] ?? _regionFor(v)?['id'];
    final inRegion =
        _locations.where((l) => l['region_id'] == regionId).toList();
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (_) => _RegionPicker(
            regions: [
              {'id': 'none', 'name': 'No Location (Region page only)',
                'country': null},
              ...inRegion,
            ],
            forName: v['name'],
            onRefresh: _refreshFromWebflow,
            title: 'Which Location is ${v['name']} in?',
            subtitle: inRegion.isEmpty
                ? 'This Region has no Locations on the site yet, so the '
                    'page will sit under the Region only.'
                : 'Locations are the neighbourhood pages inside '
                    '${p['region'] ?? 'the Region'}. Only pick one you are '
                    'sure of; the Region alone is fine.'));
    if (picked == null) return;
    final none = picked['id'] == 'none';
    final next = Map<String, dynamic>.from(p)
      ..['location'] = none ? null : picked['name']
      ..['location_id'] = none ? null : picked['id']
      ..['location_chosen'] = true;
    await _update(
        v,
        {
          'website_location_override': picked['id'],
          if (p.isNotEmpty) 'website_prepared': next,
        },
        none ? 'No Location: Region page only.' : '${picked['name']} chosen.');
  }

  Future<void> _copy(String text, String toast) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(toast), duration: const Duration(seconds: 2)));
  }

  // ------------------------------------------------------------ helpers

  static Map<String, dynamic> _prepared(Map<String, dynamic> v) =>
      Map<String, dynamic>.from(v['website_prepared'] as Map? ?? {});

  static String _slugify(String s) {
    // Apostrophes vanish rather than become hyphens (d'Arno -> darno),
    // as everywhere on the site.
    var x = s.trim().toLowerCase().replaceAll(RegExp("['\u2019\u2018`]"), '');
    const folds = {
      'å': 'a', 'ä': 'a', 'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a',
      'ö': 'o', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ø': 'o',
      'ü': 'u', 'ú': 'u', 'ù': 'u', 'û': 'u', 'é': 'e', 'è': 'e',
      'ê': 'e', 'ë': 'e', 'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
      'ç': 'c', 'ñ': 'n', 'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
    };
    folds.forEach((k, val) => x = x.replaceAll(k, val));
    x = x.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    x = x.replaceAll(RegExp(r'-{2,}'), '-');
    return x.replaceAll(RegExp(r'^-+|-+$'), '');
  }

  /// Local spellings the app may hold for a city that has an English
  /// Region name on the site. Same list as the nightly sync.
  static const _cityAliases = {
    'kobenhavn': 'copenhagen', 'wien': 'vienna', 'munchen': 'munich',
    'lisboa': 'lisbon', 'firenze': 'florence', 'roma': 'rome',
    'milano': 'milan', 'napoli': 'naples', 'torino': 'turin',
    'venezia': 'venice', 'praha': 'prague', 'warszawa': 'warsaw',
    'athina': 'athens', 'sevilla': 'seville', 'koln': 'cologne',
    'bruxelles': 'brussels', 'brussel': 'brussels', 'antwerpen': 'antwerp',
    'den haag': 'the hague', 'geneve': 'geneva', 'goteborg': 'gothenburg',
    'bucuresti': 'bucharest', 'beograd': 'belgrade',
    'ho chi minh city': 'saigon',
  };

  static String _norm(String? x) {
    var n = _slugify(x ?? '').replaceAll('-', ' ');
    return _cityAliases[n] ?? n;
  }

  /// The Region the founder chose, else the sync's guess if there is
  /// one, else the app's own best match of city or neighbourhood
  /// against the site's Regions. Null when nothing matches: the space
  /// cannot go to the site until a Region is picked.
  Map<String, dynamic>? _regionFor(Map<String, dynamic> v) {
    final wantR = v['website_new_region'];
    if (wantR != null && '$wantR'.trim().isNotEmpty) return null;
    final chosen = v['website_region_override'];
    if (chosen != null) {
      for (final r in _regions) {
        if (r['id'] == chosen || _norm(r['name']) == _norm(chosen)) return r;
      }
    }
    final p = _prepared(v);
    if (p['region_id'] != null) {
      for (final r in _regions) {
        if (r['id'] == p['region_id']) return r;
      }
    }
    final names = [v['neighbourhood'], v['city']]
        .whereType<String>()
        .map(_norm)
        .where((n) => n.isNotEmpty)
        .toList();
    for (final n in names) {
      for (final r in _regions) {
        if (_norm(r['name']) == n) return r;
      }
    }
    for (final n in names) {
      if (n.length < 4) continue;
      for (final r in _regions) {
        final rn = _norm(r['name']);
        if (rn.contains(n) || n.contains(rn)) return r;
      }
    }
    return null;
  }

  /// "Region 'Mafra'" or "Location 'Saldanha'" while the founder waits
  /// for it to be created in Webflow; null otherwise.
  static String? _awaiting(Map<String, dynamic> v) {
    final r = v['website_new_region'];
    if (r != null && '$r'.trim().isNotEmpty) return "Region '$r'";
    final l = v['website_new_location'];
    if (l != null && '$l'.trim().isNotEmpty) return "Location '$l'";
    return null;
  }

  /// Google's own neighbourhood or district words for the place, most
  /// specific first, from the cached address parts.
  static List<String> _googleAreas(Map<String, dynamic> v) {
    final comps = v['address_components'];
    if (comps is! List) return const [];
    const wanted = [
      'neighborhood', 'sublocality_level_1', 'sublocality',
      'administrative_area_level_3', 'locality'
    ];
    final out = <String>[];
    for (final w in wanted) {
      for (final c in comps) {
        if (c is Map && (c['types'] as List?)?.contains(w) == true) {
          final n = c['longText'] ?? c['shortText'];
          if (n != null && !out.contains('$n')) out.add('$n');
        }
      }
    }
    return out;
  }

  /// Best Location guess inside a Region: exact name match against
  /// what Google or the nomad wrote, else a contains match, else null.
  Map<String, dynamic>? _locationGuess(
      Map<String, dynamic> v, String? regionId) {
    if (regionId == null) return null;
    final inRegion =
        _locations.where((l) => l['region_id'] == regionId).toList();
    final hints = [v['neighbourhood'], ..._googleAreas(v), v['city']]
        .whereType<String>()
        .map(_norm)
        .where((n) => n.isNotEmpty)
        .toList();
    for (final h in hints) {
      for (final l in inRegion) {
        if (_norm(l['name']) == h) return l;
      }
    }
    for (final h in hints) {
      if (h.length < 4) continue;
      for (final l in inRegion) {
        final n = _norm(l['name']);
        if (n.contains(h) || h.contains(n)) return l;
      }
    }
    return null;
  }

  /// What the slug will be, before the sync confirms it (the sync
  /// only adds -2, -3 if the exact slug is already taken).
  /// House rule: country-region-name, e.g. portugal-lisbon-lacs-anjos.
  String _slugPreview(Map<String, dynamic> v, Map<String, dynamic> region) {
    final typed = v['website_slug_override'];
    if (typed != null && '$typed'.isNotEmpty) return '$typed';
    final country = _countryOf(v) ?? region['country'] ?? '';
    return [
      _slugify('$country'),
      _slugify(region['name'] ?? ''),
      _slugify(v['name'] ?? ''),
    ].where((x) => x.isNotEmpty).join('-');
  }

  /// Inbox groups, in the order they are worth working through.
  ({
    List<Map<String, dynamic>> ready,
    List<Map<String, dynamic>> needsRegion,
    List<Map<String, dynamic>> preparing,
    List<Map<String, dynamic>> fresh,
  }) _groups() {
    final ready = <Map<String, dynamic>>[];
    final needsRegion = <Map<String, dynamic>>[];
    final preparing = <Map<String, dynamic>>[];
    final fresh = <Map<String, dynamic>>[];
    for (final v in _inbox ?? const <Map<String, dynamic>>[]) {
      if (v['website_status'] == 'queued') {
        if (v['website_approved_at'] != null) continue; // shown in Drafts
        final p = _prepared(v);
        if (p.isEmpty) {
          // Not prepared yet: still show straight away whether a
          // Region is known, since without one nothing can happen.
          if (_regionFor(v) == null || _awaiting(v) != null) {
            needsRegion.add(v);
          } else {
            preparing.add(v);
          }
        } else if (p['error'] != null) {
          needsRegion.add(v);
        } else {
          ready.add(v);
        }
      } else {
        fresh.add(v);
      }
    }
    return (
      ready: ready,
      needsRegion: needsRegion,
      preparing: preparing,
      fresh: fresh
    );
  }

  int get _inboxCount {
    final g = _groups();
    return g.ready.length + g.needsRegion.length + g.fresh.length;
  }

  List<Map<String, dynamic>> get _approvedTonight => (_inbox ?? const <Map<String, dynamic>>[])
      .where((v) =>
          v['website_status'] == 'queued' && v['website_approved_at'] != null)
      .toList();

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final inbox = _inbox;
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('nomadwise.io'),
          if (inbox != null && _inboxCount > 0) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: Brand.accent, borderRadius: BorderRadius.circular(10)),
              child: Text('$_inboxCount to do',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800)),
            ),
          ],
        ]),
        actions: [
          // The site's taxonomy, made from here: a Region (city page) or
          // a Location (neighbourhood page), built and published by the
          // sync within a minute or two, then in every picker.
          PopupMenuButton<String>(
            tooltip: 'Create on nomadwise.io',
            icon: const Icon(Icons.add_location_alt_outlined),
            onSelected: (k) => k == 'region'
                ? _newRegion()
                : k == 'location'
                    ? _newLocation()
                    : _refreshFromWebflow(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'region', child: Text('Create a Region (city page)')),
              PopupMenuItem(
                  value: 'location', child: Text('Create a Location (area page)')),
              PopupMenuDivider(),
              PopupMenuItem(
                  value: 'refresh',
                  child: Text('Refresh Regions and Locations from Webflow')),
            ],
          ),
        ],
      ),
      body: inbox == null && _error == null
          ? const Center(child: CircularProgressIndicator(color: Brand.red))
          : _error != null
              ? _errorView()
              : _wrap(_pipeline()),
    );
  }

  /// Phone: full width. Laptop: a comfortable reading column.
  Widget _wrap(Widget child) => RefreshIndicator(
        onRefresh: _load,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: child,
          ),
        ),
      );

  Widget _errorView() => ListView(padding: const EdgeInsets.all(24), children: [
        const SizedBox(height: 30),
        const Icon(Icons.cloud_off_outlined, size: 40, color: Brand.inkMuted),
        const SizedBox(height: 12),
        const Text('Could not load the control centre',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 6),
        Text(
            'If this is the first visit after an update, the database '
            'migration may still be applying. Pull to retry.\n\n$_error',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
        const SizedBox(height: 16),
        Center(
            child: OutlinedButton(
                onPressed: _load, child: const Text('Try again'))),
      ]);

  // --------------------------------------------------------------- inbox

  /// Which inbox group is showing. null = the first one with work in it.
  String? _groupKey;

  Widget _pipeline() {
    final g = _groups();
    final groups = <({String key, String label, int count, Color color,
        String hint, String empty})>[
      (
        key: 'fresh',
        label: 'New spaces',
        count: g.fresh.length,
        color: Brand.violet,
        hint: 'Verified in the app, not on the site. Queue the ones '
            'worth a page.',
        empty: 'No new spaces waiting. Anything nomads add and you '
            'verify lands here.'
      ),
      (
        key: 'preparing',
        label: 'Queued',
        count: g.preparing.length,
        color: Brand.inkSecondary,
        hint: 'Queued, with a Region known. Approve the slug here to create '
            'the draft within about ten minutes, or wait a few minutes for '
            'the full proposal under Ready to approve. Nothing reaches '
            'Webflow without your Approve.',
        empty: 'Nothing queued.'
      ),
      // Blocked sits right after Queued: a queued space that is missing
      // its Region is the next thing to fix, not something to find at
      // the far end of the row.
      (
        key: 'region',
        label: 'Blocked',
        count: g.needsRegion.length,
        color: Brand.goldTextDark,
        hint: 'Blocked: a page needs a Country and a Region, and a slug no '
            'other listing uses. Fix the item to unblock.',
        empty: 'Nothing is blocked.'
      ),
      (
        key: 'ready',
        label: 'Ready to approve',
        count: g.ready.length,
        color: Brand.accent,
        hint: 'Check the proposal, then Approve. Within about ten minutes '
            'it becomes a draft in Webflow.',
        empty: 'Nothing to approve. Queue a space and its full proposal '
            'appears here within a few minutes.'
      ),
      (
        key: 'drafts',
        label: 'In Webflow',
        count: _drafts.length + _approvedTonight.length,
        color: Brand.inkSecondary,
        hint: 'Approved. The draft and its Images entry are created within '
            'minutes, then it is yours to finish in Webflow: words, publish.',
        empty: 'No drafts waiting in Webflow.'
      ),
      (
        key: 'sitemap',
        label: 'Sitemap',
        count: _sitemap.length,
        color: Brand.goldTextDark,
        hint: 'Released pages that still need their sitemap entry.',
        empty: 'Sitemap is up to date.'
      ),
      (
        key: 'closed',
        label: 'Closed',
        count: _closed.length,
        color: Brand.red,
        hint: 'Google reports these places as no longer operating. Retire '
            'the page (it comes off the site, the address redirects to the '
            'city page) or say it is still open. Checked about monthly.',
        empty: 'No closures waiting. Every page is checked against Google '
            'about once a month; anything that closes lands here.'
      ),
      (
        key: 'hidden',
        label: 'Not for the site',
        count: _hidden.length,
        color: Brand.inkMuted,
        hint: 'On Nomad Maps but kept off nomadwise.io, each with its '
            'reason. Bring back any of them at any time.',
        empty: 'Nothing has been marked as not for the site.'
      ),
      // The archive: every live page, searchable. Last because it is
      // reference, not work.
      (
        key: 'released',
        label: 'Released',
        count: _released.length,
        color: Brand.success,
        hint: 'Every page live on nomadwise.io, for looking one up. '
            'Nothing here needs doing.',
        empty: 'Nothing released yet.'
      ),
    ];
    var key = _groupKey;
    if (key == null || groups.firstWhere((x) => x.key == key).count == 0) {
      const steps = ['fresh', 'preparing', 'region', 'ready'];
      key = groups
          .firstWhere((x) => steps.contains(x.key) && x.count > 0,
              orElse: () => groups[0])
          .key;
    }
    final current = groups.firstWhere((x) => x.key == key);

    final cards = switch (key) {
      'ready' => g.ready.map(_readyCard).toList(),
      'region' => g.needsRegion.map(_needsRegionCard).toList(),
      'fresh' => g.fresh.map(_freshCard).toList(),
      'preparing' => g.preparing.map(_preparingTile).toList(),
      'hidden' => _hidden.map(_hiddenTile).toList(),
      'closed' => _closed.map(_closedCard).toList(),
      _ => <Widget>[],
    };
    // The later stages have their own list screens.
    final Widget? whole = switch (key) {
      'drafts' => _draftsTab(),
      'released' => _releasedTab(),
      'sitemap' => _SitemapTab(
          pending: _sitemap,
          onMarked: (ids) async {
            await _supabase.markSitemapAdded(ids);
            await _load();
          },
          copy: _copy),
      _ => null,
    };

    return Column(children: [
      // The groups, side by side, scrollable on a phone. Tap to switch.
      SizedBox(
        height: 54,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          itemCount: groups.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final x = groups[i];
            final on = x.key == key;
            return ChoiceChip(
              selected: on,
              showCheckmark: false,
              onSelected: (_) => setState(() => _groupKey = x.key),
              selectedColor: x.color,
              backgroundColor: Brand.surface,
              side: BorderSide(color: on ? x.color : Brand.border),
              labelStyle: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: on ? Colors.white : Brand.inkSecondary),
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(x.label),
                if (x.count > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                        color: on
                            ? Colors.white.withValues(alpha: .25)
                            : Brand.field,
                        borderRadius: BorderRadius.circular(9)),
                    child: Text('${x.count}',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: on ? Colors.white : Brand.inkSecondary)),
                  ),
                ],
              ]),
            );
          },
        ),
      ),
      Expanded(
        child: whole ??
            ListView(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 30),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
                    child: Text(current.hint,
                        style: const TextStyle(
                            fontSize: 12, color: Brand.inkMuted, height: 1.4)),
                  ),
                  if (cards.isEmpty)
                    _inboxCount == 0
                        ? _inboxZero()
                        : _groupEmpty(current.empty)
                  else
                    ...cards,
                ]),
      ),
    ]);
  }

  Widget _inboxZero() => Column(children: [
        const SizedBox(height: 40),
        Container(
          width: 76,
          height: 76,
          decoration: const BoxDecoration(
              color: Brand.successTint, shape: BoxShape.circle),
          child: const Icon(Icons.check_circle_outline,
              size: 36, color: Brand.success),
        ),
        const SizedBox(height: 16),
        const Text('Inbox zero',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: Brand.ink)),
        const SizedBox(height: 6),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 40),
          child: Text(
              'Nothing needs a decision. New spaces, proposals to '
              'approve and anything missing a Region will land here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13.5, color: Brand.inkMuted, height: 1.5)),
        ),
      ]);

  Widget _groupEmpty(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(30, 40, 30, 0),
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 13.5, color: Brand.inkMuted, height: 1.5)),
      );

  Widget _preparingTile(Map<String, dynamic> v) {
    final region = _regionFor(v);
    final chosen = v['website_region_override'] != null;
    return _card(
      tint: Brand.field,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(v, badge: 'QUEUED', badgeColor: Brand.inkSecondary),
        const SizedBox(height: 8),
        _taxonomyRow(v),
        const SizedBox(height: 8),
        if (region != null) ...[
          if (!chosen)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('Region matched from the city; tap it if wrong.',
                  style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
            ),
          InkWell(
            onTap: () => _editSlug(v),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                  color: Brand.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Brand.border)),
              child: Row(children: [
                const Icon(Icons.link, size: 16, color: Brand.inkSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('/coworking/${_slugPreview(v, region)}',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                const Icon(Icons.edit_outlined,
                    size: 16, color: Brand.inkMuted),
              ]),
            ),
          ),
          const SizedBox(height: 4),
          Text(
              v['website_slug_override'] != null
                  ? 'Your slug. It is used exactly as written.'
                  : 'Expected slug (country-region-name). Tap it to change. '
                      'Approving locks it; if it is taken you are asked, '
                      'never renamed.',
              style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
          _photosRow(v),
        ],
        const SizedBox(height: 6),
        Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                  onPressed: () => _editVenue(v),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit')),
              TextButton.icon(
                  onPressed: () => _pickRegion(v),
                  icon: const Icon(Icons.place_outlined, size: 16),
                  label: const Text('Change region')),
              TextButton(
                  onPressed: () => _unqueue(v),
                  style:
                      TextButton.styleFrom(foregroundColor: Brand.inkSecondary),
                  child: const Text('Remove from queue')),
              if (region != null)
                ElevatedButton.icon(
                    onPressed:
                        _photoCount(v) >= minPhotos ? () => _approve(v) : null,
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(_photoCount(v) >= minPhotos
                        ? 'Approve slug and create'
                        : 'Add $minPhotos photos to approve')),
            ]),
      ]),
    );
  }

  /// A space marked "Not for the site": its reason, and a way back.
  // ------------------------------------------------------------ closed

  static String _statusWords(String? bs) => switch (bs) {
        'CLOSED_PERMANENTLY' => 'closed for good',
        'CLOSED_TEMPORARILY' => 'temporarily closed',
        _ => 'not operating',
      };

  Future<void> _retire(Map<String, dynamic> v) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: Text('Retire ${v['name']}?'),
              content: Text(
                  'The page comes off nomadwise.io within a minute or two: '
                  'the listing and its Images entry are unpublished and '
                  'archived, the slug /coworking/${v['webflow_slug'] ?? ''} '
                  'is released, and a redirect to the city page is added. '
                  'The redirect goes live when you next publish the site.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Not now')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Retire the page')),
              ],
            ));
    if (ok != true) return;
    await _update(
        v,
        {
          'website_retire_requested_at':
              DateTime.now().toUtc().toIso8601String()
        },
        'Retiring. The card updates once the page is off the site.');
  }

  Future<void> _stillOpen(Map<String, dynamic> v) => _update(
      v,
      {'closed_dismissed_at': DateTime.now().toUtc().toIso8601String()},
      'Kept. It stays on the map and the site; Google is checked again '
      'next month.');

  Future<void> _retireDone(Map<String, dynamic> v) => _update(
      v,
      {'website_retire_done_at': DateTime.now().toUtc().toIso8601String()},
      'Done. ${v['name']} is fully retired.');

  Widget _closedCard(Map<String, dynamic> v) {
    final note = (v['website_retire_note'] as Map?) ?? const {};
    final retired = v['website_retired_at'] != null;
    final asked = v['website_retire_requested_at'] != null && !retired;
    final err = note['error'];
    final url = v['webflow_slug'] == null
        ? null
        : 'https://www.nomadwise.io/coworking/${v['webflow_slug']}';
    final country = _countryOf(v);
    return _card(
      tint: retired ? Brand.field : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v['name'] ?? '',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                      [
                        if (_where(v).isNotEmpty) _where(v),
                        if (country != null) country,
                      ].join(', '),
                      style: const TextStyle(
                          fontSize: 12, color: Brand.inkSecondary)),
                ]),
          ),
          IconButton(
              tooltip: 'Open the space',
              onPressed: () => _openVenue(v),
              icon: const Icon(Icons.chevron_right)),
        ]),
        const SizedBox(height: 8),
        if (!retired) ...[
          Text(
              'Google says ${_statusWords(v['business_status'])}, first '
              'seen ${_ago(v['closed_seen_at'])}. The page is '
              '${v['website_status'] == 'released' ? 'live and in the sitemap' : 'a draft on the site'}.',
              style: const TextStyle(fontSize: 13, height: 1.4)),
          if (url != null)
            InkWell(
              onTap: () => launchUrl(Uri.parse(url),
                  mode: LaunchMode.externalApplication),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(url,
                    style: const TextStyle(
                        fontSize: 12,
                        color: Brand.accent,
                        decoration: TextDecoration.underline)),
              ),
            ),
          if (err != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  'Last attempt failed: $err. Tap Retire to try again.',
                  style: const TextStyle(fontSize: 12.5, color: Brand.red)),
            ),
          const SizedBox(height: 10),
          if (asked && err == null)
            const Text('Retiring: the sync is taking the page down now.',
                style: TextStyle(
                    fontSize: 12.5,
                    color: Brand.inkSecondary,
                    fontStyle: FontStyle.italic))
          else
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                  onPressed: () => _retire(v),
                  style: FilledButton.styleFrom(backgroundColor: Brand.red),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Retire the page')),
              OutlinedButton.icon(
                  onPressed: () => _stillOpen(v),
                  icon: const Icon(Icons.storefront_outlined, size: 18),
                  label: const Text('Still open')),
            ]),
        ] else ...[
          Text(
              'Retired ${_ago(v['website_retired_at'])}. Off the site and '
              'archived; the slug is released.',
              style: const TextStyle(fontSize: 13, height: 1.4)),
          const SizedBox(height: 6),
          Text('Redirect: ${note['from'] ?? '?'}  to  ${note['to'] ?? '?'}',
              style: const TextStyle(
                  fontSize: 12.5, fontFamily: 'monospace', height: 1.4)),
          Text('${note['redirect'] ?? ''}',
              style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
          const SizedBox(height: 8),
          const Text(
              'Two things left for you: remove this address from the '
              'custom sitemap, and publish the site in Webflow so the '
              'redirect goes live. Then tick it off.',
              style: TextStyle(fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
                onPressed: () => _copy(
                    'https://www.nomadwise.io${note['from'] ?? ''}',
                    'Old address copied'),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy old address')),
            FilledButton.icon(
                onPressed: () => _retireDone(v),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Sitemap and publish done')),
          ]),
        ],
      ]),
    );
  }

  Widget _hiddenTile(Map<String, dynamic> v) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        elevation: 0,
        color: Brand.field,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.visibility_off_outlined,
              color: Brand.inkMuted),
          title: Text(v['name'] ?? '',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
              [
                v['website_dismiss_reason'] ?? 'No reason recorded',
                if (v['website_dismiss_note'] != null)
                  v['website_dismiss_note'],
                if (_where(v).isNotEmpty) _where(v),
                'hidden ${_ago(v['website_dismissed_at'])}',
              ].join('  ·  '),
              style: const TextStyle(fontSize: 12, height: 1.4)),
          isThreeLine: true,
          trailing: TextButton(
              onPressed: () => _restore(v), child: const Text('Bring back')),
          onTap: () => _openVenue(v),
        ),
      );

  Widget _section(String title, int count, String hint) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 14, 2, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionLabel('$title  ·  $count'),
          const SizedBox(height: 4),
          Text(hint,
              style: const TextStyle(
                  fontSize: 12, color: Brand.inkMuted, height: 1.4)),
        ]),
      );

  static String _where(Map<String, dynamic> v) => [
        v['neighbourhood'],
        v['city']
      ].where((x) => x != null && '$x'.isNotEmpty).join(', ');

  /// The country, from Google's address parts (cached on the venue),
  /// else from the Region the space matched. Never left to guesswork
  /// on the card: a founder should not have to open a space to learn
  /// which country it is in.
  String? _countryOf(Map<String, dynamic> v) {
    final typed = v['country'];
    if (typed != null && '$typed'.trim().isNotEmpty) return '$typed'.trim();
    // The site's own Country for the matched Region comes before
    // Google's: Google says "United Kingdom", the site files London
    // under England (england-london-...).
    final region = _regionFor(v);
    final siteCountry = region?['country'] as String?;
    if (siteCountry != null && siteCountry.isNotEmpty) return siteCountry;
    final comps = v['address_components'];
    if (comps is List) {
      for (final c in comps) {
        if (c is Map && (c['types'] as List?)?.contains('country') == true) {
          final name = c['longText'] ?? c['shortText'];
          if (name != null) return '$name';
        }
      }
    }
    return null;
  }

  static const minPhotos = 3;

  /// Links the founder pasted for the page.
  static List<String> _pasted(Map<String, dynamic> v) =>
      ((v['website_photos'] as List?) ?? const [])
          .map((u) => '$u'.trim())
          .where((u) => u.startsWith('http'))
          .toList();

  /// Pictures the page would get: pasted links plus approved community
  /// photos the sync counted. At least [minPhotos] before Approve.
  int _photoCount(Map<String, dynamic> v) {
    final p = _prepared(v);
    final counted = (p['photos'] as num?)?.toInt() ?? 0;
    final pasted = _pasted(v).length;
    return pasted > counted ? pasted : counted;
  }

  /// The scored photos the sync found for this space (Google and
  /// community), best first. Empty until the sync has looked.
  List<Map<String, dynamic>> _candidates(Map<String, dynamic> v) =>
      ((v['website_photo_candidates'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

  /// At Approve: which candidates the founder kept (and in what
  /// order) and which were skipped. Best-effort; never blocks.
  Future<void> _recordPicks(Map<String, dynamic> v) async {
    final cands = _candidates(v);
    if (cands.isEmpty) return;
    final kept = _pasted(v);
    final rows = cands
        .map((c) => {
              'venue_id': v['id'],
              'uri': c['uri'],
              'source': c['source'],
              'picked': kept.contains(c['uri']),
              'position': kept.contains(c['uri']) ? kept.indexOf(c['uri']) : null,
              'score': c['score'],
            })
        .toList();
    try {
      await _supabase.recordPhotoPicks(rows);
    } catch (_) {}
  }

  /// Paste up to five image links; saved on the venue, used by the
  /// sync for the Images entry when the draft is created.
  Future<void> _editPhotos(Map<String, dynamic> v) async {
    final saved = await Navigator.push<List<String>>(
        context,
        MaterialPageRoute(
            builder: (_) => _PhotosPage(
                name: v['name'] ?? '',
                searchText: [v['name'], _where(v), _countryOf(v)]
                    .where((x) => x != null && '$x'.isNotEmpty)
                    .join(' '),
                placeId: v['google_place_id'],
                candidates: _candidates(v),
                initial: _pasted(v))));
    if (saved == null) return;
    final p = _prepared(v);
    final next = Map<String, dynamic>.from(p);
    if (p.isNotEmpty) {
      final counted = (p['photos'] as num?)?.toInt() ?? 0;
      next['photos'] = saved.length > counted ? saved.length : counted;
      if (p['error'] == 'needs_photos' && saved.length >= minPhotos) {
        next.remove('error');
        next.remove('why');
      }
    }
    await _update(
        v,
        {
          'website_photos': saved,
          'website_photos_auto': false,
          if (p.isNotEmpty) 'website_prepared': next,
        },
        '${saved.length} photo${saved.length == 1 ? '' : 's'} saved.');
  }

  /// The photos row on a card: thumbnails, the count, and the button.
  Widget _photosRow(Map<String, dynamic> v) {
    final urls = _pasted(v);
    final count = _photoCount(v);
    final enough = count >= minPhotos;
    final auto = v['website_photos_auto'] == true;
    // Suggested photos the brief was not sure about (filled in to reach
    // five when the place had too few clear shots).
    final weak = auto
        ? _candidates(v)
            .where((c) => c['suggested'] == true && c['weak'] == true)
            .length
        : 0;
    final text = Text(
        auto
            ? (weak > 0
                ? '$count suggested, $weak weak (few clear shots on '
                    'Google). Check them'
                : '$count photo${count == 1 ? '' : 's'} suggested. Check them, '
                    'or Approve to keep them')
            : enough
                ? '$count photo${count == 1 ? '' : 's'} ready for the page'
                : '$count of $minPhotos photos needed before Approve',
        style: TextStyle(
            fontSize: 12.5,
            color: auto
                ? Brand.goldTextDark
                : (enough ? Brand.success : Brand.goldTextDark),
            fontWeight: FontWeight.w600));
    final button = TextButton.icon(
        onPressed: () => _editPhotos(v),
        icon: Icon(
            auto
                ? Icons.auto_awesome_outlined
                : Icons.add_photo_alternate_outlined,
            size: 16),
        label: Text(auto
            ? 'Review'
            : urls.isEmpty
                ? (_candidates(v).isEmpty ? 'Add photos' : 'Pick photos')
                : 'Edit photos'));
    // Thumbnails on their own line (they scroll sideways on a phone),
    // then the words and the button; a Row with the strip inside left
    // the text one letter per line on mobile.
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (urls.isNotEmpty) ...[
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: urls.length,
              separatorBuilder: (_, __) => const SizedBox(width: 4),
              itemBuilder: (_, i) => ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(urls[i],
                    width: 58,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                        width: 58,
                        height: 44,
                        color: Brand.field,
                        child: const Icon(Icons.broken_image_outlined,
                            size: 18, color: Brand.inkMuted))),
              ),
            ),
          ),
          const SizedBox(height: 6),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (urls.isEmpty) ...[
            const Icon(Icons.photo_library_outlined,
                size: 18, color: Brand.inkMuted),
            const SizedBox(width: 8),
          ],
          Expanded(child: text),
          button,
        ]),
      ]),
    );
  }

  /// "Anjos, Lisbon, Portugal" for the card header. The city is
  /// spelled the site's way once a Region matches (Lisbon, not Lisboa).
  String _placeLine(Map<String, dynamic> v) {
    final region = _regionFor(v);
    final where = region != null
        ? [v['neighbourhood'], region['name']]
            .where((x) => x != null && '$x'.isNotEmpty)
            .join(', ')
        : _where(v);
    final country = _countryOf(v);
    if (country == null) return where;
    if (where.toLowerCase().contains(country.toLowerCase())) return where;
    return where.isEmpty ? country : '$where, $country';
  }

  Widget _card({required Widget child, Color? tint}) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 1.5,
        color: tint,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      );

  /// Card header. Tapping it opens the full space page.
  Widget _title(Map<String, dynamic> v, {String? badge, Color? badgeColor}) =>
      InkWell(
        onTap: () => _openVenue(v),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            if (badge != null) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                    color: badgeColor ?? Brand.accent,
                    borderRadius: BorderRadius.circular(10)),
                child: Text(badge,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900)),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(v['name'] ?? 'Unnamed',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    Text(
                        '${v['type'] == 'coworking' ? 'Coworking space' : 'Cafe'}'
                        '${_placeLine(v).isNotEmpty ? ' · ${_placeLine(v)}' : ''}'
                        '  ·  tap to open',
                        style: const TextStyle(
                            fontSize: 12, color: Brand.inkMuted)),
                  ]),
            ),
            const Icon(Icons.chevron_right, color: Brand.inkMuted),
          ]),
        ),
      );

  Widget _freshCard(Map<String, dynamic> v) {
    final hasPlace = v['google_place_id'] != null;
    final rating = v['google_rating_snapshot'];
    final reviews = v['google_reviews_snapshot'];
    final wifi = v['wifi_speed_mbps'];
    // Nomads answered "no" to laptops: almost always not for the site,
    // so the card says so and the one-tap route is the main button.
    final noLaptops = v['laptops_allowed'] == false;
    return _card(
      tint: noLaptops ? Brand.field : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(v, badge: 'NEW', badgeColor: Brand.violet),
        const SizedBox(height: 8),
        _taxonomyRow(v),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (noLaptops) const StatusChip('No laptops', dotColor: Brand.red),
          if (rating != null)
            StatusChip('★ $rating${reviews != null ? ' ($reviews)' : ''}',
                dotColor: Brand.gold),
          if (wifi != null)
            StatusChip('${(wifi as num).round()} Mbps', dotColor: Brand.success),
          StatusChip(hasPlace ? 'Google matched' : 'No Google match',
              dotColor: hasPlace ? Brand.success : Brand.red),
        ]),
        if (noLaptops) ...[
          const SizedBox(height: 8),
          const Text(
              'Nomads say laptops are not welcome here, so it is probably '
              'not a place to work from. Open it if you want to check.',
              style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary, height: 1.4)),
        ],
        const SizedBox(height: 10),
        Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.end,
            children: [
          TextButton.icon(
              onPressed: () => _editVenue(v),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Edit')),
          if (noLaptops) ...[
            TextButton(
                onPressed: hasPlace ? () => _queue(v) : null,
                style: TextButton.styleFrom(foregroundColor: Brand.inkSecondary),
                child: Text(hasPlace ? 'Queue anyway' : 'Needs a Google match')),
            // Navy, not the red used for "Queue for the site", so the
            // two opposite actions never look alike.
            ElevatedButton.icon(
                onPressed: () => _dismissAs(v, dismissReasons.first),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Brand.ink, foregroundColor: Colors.white),
                icon: const Icon(Icons.laptop_outlined, size: 18),
                label: const Text('Not a place to work')),
          ] else ...[
            TextButton(
                onPressed: () => _dismiss(v),
                style: TextButton.styleFrom(foregroundColor: Brand.inkSecondary),
                child: const Text('Not for the site')),
            ElevatedButton.icon(
                onPressed: hasPlace ? () => _queue(v) : null,
                icon: const Icon(Icons.add_to_queue_outlined, size: 18),
                label: Text(hasPlace
                    ? 'Queue for the site'
                    : 'Needs a Google match first')),
          ],
        ]),
      ]),
    );
  }

  Widget _needsRegionCard(Map<String, dynamic> v) {
    final p = _prepared(v);
    final names = (p['google_names'] as List?)?.cast<String>() ?? const [];
    final error = p['error'];
    final awaiting = _awaiting(v);
    final why = awaiting != null
        ? 'Waiting for $awaiting to be created in Webflow. Once it exists '
            'with that exact name, the space is linked to it automatically '
            'and moves on. Or pick an existing one instead.'
        : p['why'] ??
            'No Region on nomadwise.io matches "${v['city'] ?? v['neighbourhood'] ?? 'this city'}". '
                'A page needs a Country and a Region, and the slug is built '
                'from the Region, so nothing can be prepared or created until '
                'you pick one.';
    return _card(
      tint: Brand.goldTint,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(v, badge: 'REGION', badgeColor: Brand.goldTextDark),
        const SizedBox(height: 8),
        Text(why, style: const TextStyle(fontSize: 13, height: 1.4)),
        if (names.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Google calls the area: ${names.join(' · ')}',
              style: const TextStyle(fontSize: 12, color: Brand.inkSecondary)),
        ],
        const SizedBox(height: 10),
        Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.end,
            children: [
          TextButton.icon(
              onPressed: () => _editVenue(v),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Edit')),
          TextButton(
              onPressed: () => _unqueue(v),
              style: TextButton.styleFrom(foregroundColor: Brand.inkSecondary),
              child: const Text('Remove')),
          if (awaiting != null)
            ElevatedButton.icon(
                onPressed: () => _editVenue(v),
                icon: const Icon(Icons.place_outlined, size: 18),
                label: const Text('Change place'))
          else if (error == 'no_place_id')
            const Text('Add a Google match in the space first',
                style: TextStyle(fontSize: 12, color: Brand.inkMuted))
          else if (error == 'slug_taken')
            ElevatedButton.icon(
                onPressed: () => _editSlug(v),
                icon: const Icon(Icons.link, size: 18),
                label: const Text('Change the slug'))
          else if (error == 'needs_photos')
            ElevatedButton.icon(
                onPressed: () => _editPhotos(v),
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: const Text('Add photos'))
          else
            ElevatedButton.icon(
                onPressed: () => _pickRegion(v),
                icon: const Icon(Icons.place_outlined, size: 18),
                label: const Text('Pick a Region')),
        ]),
      ]),
    );
  }

  Widget _readyCard(Map<String, dynamic> v) {
    final p = _prepared(v);
    final hours = Map<String, dynamic>.from(p['hours'] as Map? ?? {});
    final facts = Map<String, dynamic>.from(p['facts'] as Map? ?? {});
    final place = [p['location'], p['region'], p['country']]
        .where((x) => x != null)
        .join(' · ');
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(v, badge: 'REVIEW'),
        const SizedBox(height: 10),

        // The address it will get. Editable until approval.
        InkWell(
          onTap: () => _editSlug(v),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
                color: Brand.field, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              const Icon(Icons.link, size: 16, color: Brand.inkSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('/coworking/${p['slug']}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              const Icon(Icons.edit_outlined, size: 16, color: Brand.inkMuted),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        _kv(Icons.place_outlined, place),
        InkWell(
          onTap: () => _pickLocation(v),
          borderRadius: BorderRadius.circular(8),
          child: _kv(
              Icons.pin_drop_outlined,
              p['location'] == null
                  ? 'No Location (neighbourhood page)'
                      '${p['location_chosen'] == true ? ', your choice' : ''}'
                      '  ·  tap to pick one'
                  : 'Location: ${p['location']}'
                      '${p['location_chosen'] == true ? ' (your choice)' : ' (guessed, check it)'}'
                      '  ·  tap to change',
              muted: p['location'] == null && p['location_chosen'] != true),
        ),
        _kv(Icons.title, p['h1'] ?? ''),
        if (hours.isNotEmpty)
          _kv(Icons.schedule_outlined, _hoursSummary(hours))
        else
          _kv(Icons.schedule_outlined, 'No opening hours known',
              muted: true),
        _photosRow(v),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: facts.entries
                .map((e) => StatusChip('${e.key}: ${e.value}',
                    dotColor: e.value == 'Yes' ? Brand.success : Brand.inkFaint))
                .toList(),
          ),
        ],
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (p['rating'] != null)
            StatusChip('★ ${p['rating']} (${p['reviews'] ?? 0})',
                dotColor: Brand.gold),
          if (p['wifi_mbps'] != null)
            StatusChip('${p['wifi_mbps']} Mbps', dotColor: Brand.success),
          StatusChip(p['kind'] ?? '', dotColor: Brand.inkMuted),
        ]),
        if (p['edited_at'] != null)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
                'Edited since this proposal was prepared. The page is built '
                'from the latest details, so approving is safe; the summary '
                'above refreshes in a few minutes.',
                style: TextStyle(
                    fontSize: 11.5, color: Brand.goldTextDark, height: 1.4)),
          ),
        const SizedBox(height: 10),
        Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.end,
            children: [
          TextButton.icon(
              onPressed: () => _editVenue(v),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Edit')),
          TextButton(
              onPressed: () => _unqueue(v),
              style: TextButton.styleFrom(foregroundColor: Brand.inkSecondary),
              child: const Text('Remove from queue')),
          ElevatedButton.icon(
              onPressed:
                  _photoCount(v) >= minPhotos ? () => _approve(v) : null,
              icon: const Icon(Icons.check, size: 18),
              label: Text(_photoCount(v) >= minPhotos
                  ? 'Approve'
                  : 'Add $minPhotos photos to approve')),
        ]),
      ]),
    );
  }

  static String _hoursSummary(Map<String, dynamic> hours) {
    // "Mon-Fri 8:00 AM - 6:00 PM · Sat 9:00 AM - 2:00 PM · Sun Closed"
    const order = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
      'Sunday'
    ];
    const short = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final parts = <String>[];
    var i = 0;
    while (i < order.length) {
      final val = hours[order[i]];
      if (val == null) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < order.length && hours[order[j + 1]] == val) {
        j++;
      }
      parts.add('${i == j ? short[i] : '${short[i]}-${short[j]}'} $val');
      i = j + 1;
    }
    return parts.join(' · ');
  }

  /// Country, Region and Location as the site will file the space,
  /// spelled out under the title so nothing has to be guessed from
  /// the address line. Region and Location are tappable pickers.
  Widget _taxonomyRow(Map<String, dynamic> v) {
    final region = _regionFor(v);
    final newRegion = v['website_new_region'] as String?;
    final newLocation = v['website_new_location'] as String?;
    final country = _countryOf(v);

    // Location: the founder's choice, else the proposal, else a guess.
    String locText;
    Color locColor = Brand.ink;
    final locOverride = v['website_location_override'] as String?;
    final p = _prepared(v);
    if (newLocation != null && newLocation.isNotEmpty) {
      locText = '$newLocation (new, requested)';
      locColor = Brand.goldTextDark;
    } else if (locOverride == 'none') {
      locText = 'None (your choice)';
      locColor = Brand.inkSecondary;
    } else if (locOverride != null) {
      final l = _locations.where((l) => l['id'] == locOverride).firstOrNull;
      locText = l != null ? '${l['name']}' : 'Chosen';
    } else if (p['location'] != null) {
      locText = '${p['location']}${p['location_chosen'] == true ? '' : ' (guess)'}';
      if (p['location_chosen'] != true) locColor = Brand.goldTextDark;
    } else {
      final g = region == null ? null : _locationGuess(v, region['id']);
      if (g != null) {
        locText = '${g['name']} (guess)';
        locColor = Brand.goldTextDark;
      } else {
        locText = region == null ? 'Pick a Region first' : 'None';
        locColor = Brand.inkMuted;
      }
    }

    Widget cell(String label, String value, Color color,
            {VoidCallback? onTap}) =>
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            constraints: const BoxConstraints(minWidth: 96),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: Brand.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Brand.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .6,
                      color: Brand.inkMuted)),
              const SizedBox(height: 1),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(value,
                    style: TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
                if (onTap != null) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more, size: 14, color: Brand.inkMuted),
                ],
              ]),
            ]),
          ),
        );

    return Wrap(spacing: 6, runSpacing: 6, children: [
      cell('COUNTRY', country ?? 'Unknown',
          country == null ? Brand.red : Brand.ink),
      cell(
          'REGION',
          newRegion != null && newRegion.isNotEmpty
              ? '$newRegion (new, requested)'
              : region?['name'] ?? 'Not matched',
          newRegion != null && newRegion.isNotEmpty
              ? Brand.goldTextDark
              : (region == null ? Brand.red : Brand.ink),
          onTap: () => _pickRegion(v)),
      cell('LOCATION', locText, locColor,
          onTap: region == null ? null : () => _pickLocation(v)),
    ]);
  }

  Widget _kv(IconData icon, String text, {bool muted = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 15, color: Brand.inkMuted),
          const SizedBox(width: 7),
          Expanded(
              child: Text(text,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: muted ? Brand.inkMuted : Brand.ink))),
        ]),
      );

  // -------------------------------------------------------------- drafts

  Widget _draftsTab() {
    final approved = _approvedTonight;
    if (_drafts.isEmpty && approved.isEmpty) {
      return _empty(Icons.edit_note_outlined, 'No drafts waiting',
          'Approved spaces appear here until you publish their page in '
              'Webflow.');
    }
    return ListView(padding: const EdgeInsets.all(14), children: [
      if (approved.isNotEmpty) ...[
        _section('APPROVED, BEING CREATED', approved.length,
            'The Webflow draft and its Images entry are built within '
            'about ten minutes. Pull down to refresh.'),
        ...approved.map((v) => _card(
              tint: Brand.successTint,
              child: Row(children: [
                const Icon(Icons.nightlight_outlined, color: Brand.success),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(v['name'] ?? '',
                          style:
                              const TextStyle(fontWeight: FontWeight.w700)),
                      Text('/coworking/${_prepared(v)['slug'] ?? ''}',
                          style: const TextStyle(
                              fontSize: 12, color: Brand.inkSecondary)),
                    ])),
                TextButton(
                    onPressed: () => _update(
                        v,
                        {'website_approved_at': null},
                        'Approval withdrawn; back in the inbox.'),
                    child: const Text('Undo')),
              ]),
            )),
      ],
      if (_drafts.isNotEmpty) ...[
        _section('IN WEBFLOW, NOT RELEASED', _drafts.length,
            'Each draft is checked against Webflow within a minute or '
            'two. When it passes, Publish puts both the listing and its '
            'Images entry live; it then moves to Released and its entry '
            'appears under Sitemap.'),
        ..._drafts.map((v) => _card(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(v['name'] ?? '',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text('/coworking/${v['webflow_slug'] ?? ''}',
                            style: const TextStyle(
                                fontSize: 12, color: Brand.inkSecondary)),
                        Text(
                            'Draft since ${_ago(v['website_synced_at'])}',
                            style: const TextStyle(
                                fontSize: 11.5, color: Brand.inkMuted)),
                      ])),
                  IconButton(
                      tooltip: 'Copy the name (to find it in Webflow)',
                      onPressed: () => _copy(v['name'] ?? '', 'Name copied'),
                      icon: const Icon(Icons.copy_outlined, size: 18)),
                ]),
                const SizedBox(height: 6),
                _draftCheck(v),
                const SizedBox(height: 6),
                Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Published by hand in Webflow: say so and carry on
                      // to the sitemap. The nightly read corrects a
                      // still-draft page.
                      TextButton(
                          onPressed: () => _publishedNow(v),
                          style: TextButton.styleFrom(
                              foregroundColor: Brand.inkSecondary),
                          child: const Text('I published it in Webflow')),
                      if (v['website_publish_requested_at'] != null)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('Publishing within a minute or two',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: Brand.goldTextDark)),
                        )
                      else
                        ElevatedButton.icon(
                            onPressed: _checkOf(v)['ok'] == true
                                ? () => _requestPublish(v)
                                : null,
                            icon: const Icon(Icons.publish_outlined, size: 18),
                            label: const Text('Publish on nomadwise.io')),
                    ]),
              ]),
            )),
      ],
      const SizedBox(height: 30),
    ]);
  }

  /// The sync's read-back of the draft: listing and Images entry
  /// linked, slug as approved, Region, Country, enough photos.
  Map<String, dynamic> _checkOf(Map<String, dynamic> v) {
    final c = _prepared(v)['webflow_check'];
    return c is Map ? Map<String, dynamic>.from(c) : const {};
  }

  Widget _draftCheck(Map<String, dynamic> v) {
    final c = _checkOf(v);
    if (c.isEmpty) {
      return const Text('Checking the draft against Webflow...',
          style: TextStyle(fontSize: 12.5, color: Brand.inkMuted));
    }
    final issues = (c['issues'] as List?)?.cast<String>() ?? const [];
    final err = c['publish_error'];
    if (c['ok'] == true && err == null) {
      return Row(children: [
        const Icon(Icons.verified_outlined, size: 16, color: Brand.success),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
              'Checked: listing and Images entry linked, '
              '${c['photos']} photo${c['photos'] == 1 ? '' : 's'}, slug as '
              'approved, Region and Country set.',
              style: const TextStyle(fontSize: 12.5, color: Brand.success)),
        ),
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.error_outline, size: 16, color: Brand.red),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
            err != null
                ? 'Publishing failed: $err. Fix it in Webflow, or publish '
                    'there by hand.'
                : 'Needs attention in Webflow: ${issues.join('; ')}.',
            style: const TextStyle(fontSize: 12.5, color: Brand.red)),
      ),
    ]);
  }

  /// Founder asks the sync to stage and publish both items via the
  /// API. The run re-checks first; a failure shows on the card.
  Future<void> _requestPublish(Map<String, dynamic> v) => _update(
      v,
      {
        'website_publish_requested_at':
            DateTime.now().toUtc().toIso8601String(),
      },
      '${v['name']} will be published within a minute or two.');

  /// Founder says the page is live: released now, so its sitemap
  /// entry is ready under Sitemap straight away.
  Future<void> _publishedNow(Map<String, dynamic> v) async {
    await _update(
        v,
        {
          'website_status': 'released',
          'website_synced_at': DateTime.now().toUtc().toIso8601String(),
        },
        '${v['name']} released. Its sitemap entry is under Sitemap.');
    if (mounted) setState(() => _groupKey = 'sitemap');
  }

  static String _ago(String? ts) {
    final t = ts != null ? DateTime.tryParse(ts) : null;
    if (t == null) return 'a while';
    final d = DateTime.now().difference(t.toLocal());
    if (d.inHours < 24) return 'today';
    if (d.inDays == 1) return 'yesterday';
    if (d.inDays < 30) return '${d.inDays} days ago';
    return DateFormat('d MMM').format(t.toLocal());
  }

  // ------------------------------------------------------------ released

  String _search = '';

  Widget _releasedTab() {
    final q = _search.trim().toLowerCase();
    final rows = q.isEmpty
        ? _released
        : _released
            .where((v) =>
                '${v['name']} ${v['city']} ${v['webflow_slug']}'
                    .toLowerCase()
                    .contains(q))
            .toList();
    return ListView(padding: const EdgeInsets.all(14), children: [
      TextField(
        decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search released pages',
            filled: true,
            fillColor: Brand.field,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none)),
        onChanged: (s) => setState(() => _search = s),
      ),
      const SizedBox(height: 6),
      Text(
          '${_released.length} released page${_released.length == 1 ? '' : 's'}'
          '${_released.length >= 300 ? ' (latest 300 shown)' : ''}',
          style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
      const SizedBox(height: 8),
      ...rows.map((v) => ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            dense: true,
            title: Text(v['name'] ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
                '/coworking/${v['webflow_slug']}'
                '${v['sitemap_added_at'] == null ? '  ·  not in sitemap yet' : ''}',
                style: TextStyle(
                    fontSize: 12,
                    color: v['sitemap_added_at'] == null
                        ? Brand.goldTextDark
                        : Brand.inkSecondary)),
            trailing: const Icon(Icons.open_in_new, size: 16),
            onTap: () => launchUrl(
                Uri.parse(
                    'https://www.nomadwise.io/coworking/${v['webflow_slug']}'),
                mode: LaunchMode.externalApplication),
          )),
      if (rows.isEmpty)
        const Padding(
          padding: EdgeInsets.all(30),
          child: Text('Nothing matches.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Brand.inkMuted)),
        ),
      const SizedBox(height: 30),
    ]);
  }

  Widget _empty(IconData icon, String title, String body) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 48),
          Icon(icon, size: 40, color: Brand.inkMuted),
          const SizedBox(height: 12),
          Text(title,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          Text(body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13.5, color: Brand.inkMuted, height: 1.5)),
        ],
      );
}

// --------------------------------------------------------------- edit page

/// Everything the app knows about a space, editable in one place.
/// Saves straight to the venue; the nightly sync carries changes to
/// nomadwise.io for queued spaces.
class _EditVenuePage extends StatefulWidget {
  final Venue venue;
  final SupabaseService supabase;
  final String? countryGuess;
  final List<Map<String, dynamic>> regions;
  final List<Map<String, dynamic>> locations;
  final List<Map<String, dynamic>> countries;
  final Map<String, dynamic>? regionGuess;
  final Map<String, dynamic>? locationGuess;
  final List<String> googleAreas;
  final Map<String, dynamic> row;
  const _EditVenuePage(
      {required this.venue,
      required this.supabase,
      required this.regions,
      required this.locations,
      this.countries = const [],
      required this.googleAreas,
      required this.row,
      this.countryGuess,
      this.regionGuess,
      this.locationGuess});
  @override
  State<_EditVenuePage> createState() => _EditVenuePageState();
}

class _EditVenuePageState extends State<_EditVenuePage> {
  late final _name = TextEditingController(text: widget.venue.name);
  late final _hood =
      TextEditingController(text: widget.venue.neighbourhood ?? '');
  late final _city = TextEditingController(text: widget.venue.city ?? '');
  late final _country = TextEditingController(
      text: (widget.venue.raw['country'] as String?) ??
          widget.countryGuess ??
          '');
  late final _website = TextEditingController(text: widget.venue.website ?? '');
  late final _instagram =
      TextEditingController(text: widget.venue.instagram ?? '');
  late final _wifi = TextEditingController(
      text: widget.venue.wifiSpeedMbps?.toString() ?? '');
  late String _type = widget.venue.type;

  // The site's taxonomy. Only existing Regions and Locations can be
  // chosen; "needs a new one" records a request, never creates.
  late String? _regionId = (widget.row['website_region_override'] as String?)
      ?? widget.regionGuess?['id'] as String?;
  late String? _locationId =
      widget.row['website_location_override'] as String? ??
          (widget.locationGuess?['id'] as String?);
  late String? _newRegion = widget.row['website_new_region'] as String?;
  late String? _newLocation = widget.row['website_new_location'] as String?;

  Map<String, dynamic>? get _region =>
      widget.regions.where((r) => r['id'] == _regionId).firstOrNull;
  Map<String, dynamic>? get _location => _locationId == null ||
          _locationId == 'none'
      ? null
      : widget.locations.where((l) => l['id'] == _locationId).firstOrNull;

  Future<void> _pickRegion() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (_) => _RegionPicker(
            regions: [
              {'id': 'new', 'name': 'Needs a new Region (not on the site yet)',
                'country': null},
              ...widget.regions,
            ],
            forName: widget.venue.name));
    if (picked == null) return;
    if (picked['id'] == 'new') {
      // The creator form: the sync builds and publishes the Region and
      // links this space to it by name within a minute or two.
      final name = await Navigator.push<String>(
          context,
          MaterialPageRoute(
              builder: (_) => _NewRegionPage(
                  supabase: widget.supabase,
                  countries: widget.countries,
                  regions: widget.regions,
                  initialName: _city.text.trim(),
                  initialCountry: _country.text.trim(),
                  state: _stateOf(widget.row),
                  lat: widget.venue.lat,
                  lng: widget.venue.lng,
                  venueId: widget.venue.id)));
      if (name == null) return;
      setState(() {
        _newRegion = name;
        _regionId = null;
        _locationId = null;
        _newLocation = null;
      });
      return;
    }
    setState(() {
      _regionId = picked['id'];
      _newRegion = null;
      if (_location != null && _location!['region_id'] != _regionId) {
        _locationId = null;
      }
      // The slug's country follows the Region's Country on the site.
      final c = picked['country'] as String?;
      if (c != null && c.isNotEmpty) _country.text = c;
    });
  }

  /// Google's state or province (administrative_area_level_1), for
  /// the country-state-city slugs the site uses in the US and India.
  static String? _stateOf(Map<String, dynamic> row) {
    final comps = row['address_components'];
    if (comps is! List) return null;
    for (final c in comps) {
      if (c is Map &&
          (c['types'] as List?)?.contains('administrative_area_level_1') == true) {
        final n = c['longText'] ?? c['shortText'];
        if (n != null) return '$n';
      }
    }
    return null;
  }

  /// The site's Country for the chosen Region when it differs from
  /// what is typed (United Kingdom typed, England on the site).
  String? get _countryMismatch {
    final c = _region?['country'] as String?;
    if (c == null || c.isEmpty) return null;
    return c.trim().toLowerCase() == _country.text.trim().toLowerCase()
        ? null
        : c;
  }

  Future<void> _pickLocation() async {
    final inRegion =
        widget.locations.where((l) => l['region_id'] == _regionId).toList();
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (_) => _RegionPicker(
            regions: [
              {'id': 'none', 'name': 'No Location (Region page only)',
                'country': null},
              {'id': 'new',
                'name': 'Needs a new Location (not on the site yet)',
                'country': null},
              ...inRegion,
            ],
            forName: widget.venue.name,
            title: 'Which Location is ${widget.venue.name} in?',
            subtitle: inRegion.isEmpty
                ? 'This Region has no Locations on the site yet.'
                : 'The neighbourhood pages inside ${_region?['name'] ?? 'the Region'}. '
                    'Only pick one you are sure of.'));
    if (picked == null) return;
    if (picked['id'] == 'new') {
      final name = await Navigator.push<String>(
          context,
          MaterialPageRoute(
              builder: (_) => _NewLocationPage(
                  supabase: widget.supabase,
                  regions: widget.regions,
                  locations: widget.locations,
                  initialRegionId: _regionId,
                  initialName: _hood.text.trim(),
                  venueId: widget.venue.id)));
      if (name == null) return;
      setState(() {
        _newLocation = name;
        _locationId = null;
      });
      return;
    }
    setState(() {
      _locationId = picked['id'];
      _newLocation = null;
    });
  }

  Widget _taxonomyRow(
      {required String label,
      required String value,
      required String hint,
      required bool warn,
      required VoidCallback onTap}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
                color: warn ? Brand.goldTint : Brand.field,
                borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(
                              fontSize: 11.5, color: Brand.inkSecondary)),
                      const SizedBox(height: 2),
                      Text(value,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      if (hint.isNotEmpty)
                        Text(hint,
                            style: const TextStyle(
                                fontSize: 11.5, color: Brand.inkMuted,
                                height: 1.35)),
                    ]),
              ),
              const Icon(Icons.expand_more, color: Brand.inkMuted),
            ]),
          ),
        ),
      );

  late final Map<String, bool?> _facts = {
    'laptops_allowed': widget.venue.laptopsAllowed,
    'power_outlets': widget.venue.powerOutlets,
    'aircon': widget.venue.aircon,
    'comfortable_seating': widget.venue.comfortableSeating,
    'cozy': widget.venue.cozy,
    'quiet_space': widget.venue.quietSpace,
    'good_for_calls': widget.venue.goodForCalls,
    'call_room': widget.venue.callRoom,
    'monitor': widget.venue.monitorAvailable,
    'office_chairs': widget.venue.officeChairs,
    'access_24h': widget.venue.access24h,
    'serves_food': widget.venue.servesFood,
  };
  static const _factLabels = {
    'laptops_allowed': 'Laptops welcome',
    'power_outlets': 'Plug sockets',
    'aircon': 'Aircon',
    'comfortable_seating': 'Comfortable seating',
    'cozy': 'Cozy',
    'quiet_space': 'Quiet space',
    'good_for_calls': 'Good for calls',
    'call_room': 'Call room',
    'monitor': 'Monitor available',
    'office_chairs': 'Office chairs',
    'access_24h': '24 hour access',
    'serves_food': 'Serves food',
  };
  static const _days = [
    ('mon', 'Monday'), ('tue', 'Tuesday'), ('wed', 'Wednesday'),
    ('thu', 'Thursday'), ('fri', 'Friday'), ('sat', 'Saturday'),
    ('sun', 'Sunday'),
  ];
  late final Map<String, TextEditingController> _hours = {
    for (final d in _days)
      d.$1: TextEditingController(
          text: (widget.venue.fallbackHours?[d.$1] ?? '').toString())
  };
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _hood, _city, _country, _website, _instagram, _wifi]) {
      c.dispose();
    }
    for (final c in _hours.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// House style for hours: "8:00 AM - 6:00 PM" with a plain hyphen.
  static String _plainHours(String t) {
    var x = t.replaceAll(
        RegExp('[\\u2010\\u2011\\u2012\\u2013\\u2014\\u2015\\u2212]'), '-');
    x = x.replaceAll(RegExp('[\\u00a0\\u2009\\u202f\\u2007]'), ' ');
    x = x.replaceAll(RegExp(r'\s*-\s*'), ' - ');
    return x.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  String? _nullIfEmpty(String s) => s.trim().isEmpty ? null : s.trim();

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final hours = <String, String>{};
      for (final d in _days) {
        final t = _plainHours(_hours[d.$1]!.text);
        if (t.isNotEmpty) hours[d.$1] = t;
      }
      // Google's live hours are the source when the app has none; an
      // empty form means "leave it to Google", not "closed all week".
      await widget.supabase.updateVenueFields(widget.venue.id, {
        'name': _name.text.trim(),
        'type': _type,
        'neighbourhood': _nullIfEmpty(_hood.text),
        'city': _nullIfEmpty(_city.text),
        'country': _nullIfEmpty(_country.text),
        'website_region_override': _regionId,
        'website_location_override': _locationId,
        'website_new_region': _newRegion,
        'website_new_location': _newLocation,
        // A different place means a different slug and page: the
        // proposal is rebuilt from scratch (within minutes).
        if (_regionId != widget.row['website_region_override'] ||
            _locationId != widget.row['website_location_override'] ||
            _newRegion != widget.row['website_new_region'] ||
            _newLocation != widget.row['website_new_location'])
          'website_prepared': null,
        'website': _nullIfEmpty(_website.text),
        'instagram': _nullIfEmpty(_instagram.text),
        'wifi_speed_mbps': num.tryParse(_wifi.text.trim()),
        'opening_hours': hours.isEmpty ? null : hours,
        ..._facts,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('That did not save: $e'),
            backgroundColor: Brand.red));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label,
          {String? hint,
          TextInputType? keyboard,
          ValueChanged<String>? onChanged}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
            controller: c,
            keyboardType: keyboard,
            onChanged: onChanged,
            decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                filled: true,
                fillColor: Brand.field,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none))),
      );

  Widget _heading(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 14, 2, 10),
        child: SectionLabel(t),
      );

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    return Scaffold(
      appBar: AppBar(
        title: Text(v.name, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save',
                  style: TextStyle(fontWeight: FontWeight.w700))),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(padding: const EdgeInsets.all(14), children: [
            // What Google says, for reference while editing.
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Brand.field, borderRadius: BorderRadius.circular(12)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('From Google',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .8,
                            color: Brand.inkSecondary)),
                    const SizedBox(height: 4),
                    Text(
                        v.googlePlaceId == null
                            ? 'No Google match yet.'
                            : [
                                if (v.live?.displayName != null)
                                  v.live!.displayName!,
                                if (v.live?.address != null) v.live!.address!,
                                if (v.live?.rating != null)
                                  '★ ${v.live!.rating} (${v.live!.userRatingCount ?? 0} reviews)',
                                if (v.live?.primaryType != null)
                                  v.live!.primaryType!,
                              ].join('  ·  '),
                        style: const TextStyle(fontSize: 12.5, height: 1.4)),
                    if ((v.live?.weekdayDescriptions ?? []).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(v.live!.weekdayDescriptions!.join('\n'),
                          style: const TextStyle(
                              fontSize: 11.5,
                              color: Brand.inkSecondary,
                              height: 1.4)),
                    ],
                  ]),
            ),
            _heading('THE SPACE'),
            _field(_name, 'Name'),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'cafe', label: Text('Cafe')),
                  ButtonSegment(
                      value: 'coworking', label: Text('Coworking space')),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
            ),
            _heading('ON NOMADWISE.IO'),
            _taxonomyRow(
              label: 'Region (city page)',
              value: _newRegion != null
                  ? 'Needs a new Region: $_newRegion'
                  : _region?['name'] ?? 'Not chosen',
              hint: [
                if (_region != null && widget.row['website_region_override'] == null)
                  'Matched from the city; change it if wrong.',
                if ((widget.venue.city ?? '').isNotEmpty)
                  'Nomad wrote: ${widget.venue.city}',
                if (widget.googleAreas.isNotEmpty)
                  'Google says: ${widget.googleAreas.join(', ')}',
              ].join('  ·  '),
              warn: _region == null,
              onTap: _pickRegion,
            ),
            _taxonomyRow(
              label: 'Location (neighbourhood page, optional)',
              value: _newLocation != null
                  ? 'Needs a new Location: $_newLocation'
                  : _location?['name'] ??
                      (_locationId == 'none' ? 'None (Region page only)'
                          : 'None yet'),
              hint: [
                if (_location != null &&
                    widget.row['website_location_override'] == null)
                  'A guess from the words below; confirm or change it.',
                if ((widget.venue.neighbourhood ?? '').isNotEmpty)
                  'Nomad wrote: ${widget.venue.neighbourhood}',
                if (widget.googleAreas.isNotEmpty)
                  'Google says: ${widget.googleAreas.take(2).join(', ')}',
              ].join('  ·  '),
              warn: false,
              onTap: _region == null && _newRegion == null
                  ? () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Pick the Region first.')))
                  : _pickLocation,
            ),
            _field(_country, 'Country',
                hint: 'First part of the slug: country-region-name',
                onChanged: (_) => setState(() {})),
            if (_countryMismatch != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(children: [
                  Expanded(
                    child: Text(
                        'nomadwise.io files ${_region?['name']} under '
                        '${_countryMismatch!}.',
                        style: const TextStyle(
                            fontSize: 12, color: Brand.inkMuted)),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _country.text = _countryMismatch!),
                    child: Text('Use ${_countryMismatch!}'),
                  ),
                ]),
              ),
            _heading('AS SHOWN IN THE APP'),
            _field(_hood, 'Neighbourhood',
                hint: 'Free text nomads see on the map'),
            _field(_city, 'City', hint: 'Free text nomads see on the map'),
            _heading('LINKS AND WIFI'),
            _field(_website, 'Website', keyboard: TextInputType.url),
            _field(_instagram, 'Instagram', hint: 'Full link or @handle'),
            _field(_wifi, 'WiFi speed (Mbps)',
                hint: 'Leave empty if untested',
                keyboard: TextInputType.number),
            _heading('FACTS'),
            const Text('Tap to cycle: unknown, yes, no.',
                style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _facts.keys.map((k) {
                final val = _facts[k];
                final (color, icon) = switch (val) {
                  true => (Brand.success, Icons.check),
                  false => (Brand.red, Icons.close),
                  null => (Brand.inkFaint, Icons.help_outline),
                };
                return ActionChip(
                  onPressed: () => setState(() => _facts[k] =
                      val == null ? true : (val == true ? false : null)),
                  avatar: Icon(icon, size: 15, color: color),
                  label: Text(_factLabels[k]!,
                      style: const TextStyle(fontSize: 12)),
                  side: BorderSide(color: color.withValues(alpha: .5)),
                  backgroundColor: color.withValues(alpha: .07),
                );
              }).toList(),
            ),
            _heading('OPENING HOURS'),
            const Text(
                'Optional. Leave empty and the site uses Google\'s hours. '
                'Write times like 8:00 AM - 6:00 PM, or Closed.',
                style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
            const SizedBox(height: 8),
            for (final d in _days) _field(_hours[d.$1]!, d.$2),
            const SizedBox(height: 8),
            ElevatedButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save changes')),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- photos page

/// Up to five image links for the page. The usual way: open the place
/// on Google, right-click a photo, copy the image address, paste.
class _PhotosPage extends StatefulWidget {
  final String name;
  final String searchText;
  final String? placeId;
  final List<String> initial;
  final List<Map<String, dynamic>> candidates;
  const _PhotosPage(
      {required this.name,
      required this.searchText,
      required this.initial,
      this.candidates = const [],
      this.placeId});
  @override
  State<_PhotosPage> createState() => _PhotosPageState();
}

class _PhotosPageState extends State<_PhotosPage> {
  late final List<TextEditingController> _ctl = List.generate(
      5,
      (i) => TextEditingController(
          text: i < widget.initial.length ? widget.initial[i] : ''));

  @override
  void dispose() {
    for (final c in _ctl) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _urls => _ctl
      .map((c) => c.text.trim())
      .where((u) => u.startsWith('http'))
      .toList();

  /// Tap a suggested photo: into the first free slot, or out again.
  void _toggle(String uri) {
    setState(() {
      for (final c in _ctl) {
        if (c.text.trim() == uri) {
          c.clear();
          return;
        }
      }
      for (final c in _ctl) {
        if (c.text.trim().isEmpty) {
          c.text = uri;
          return;
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Five already. Remove one first.')));
    });
  }

  int _slotOf(String uri) {
    for (var i = 0; i < _ctl.length; i++) {
      if (_ctl[i].text.trim() == uri) return i;
    }
    return -1;
  }

  /// Short, human label from the brief sentence the photo matched.
  static String _short(String? label) {
    if (label == null) return '';
    final l = label.toLowerCase();
    if (l.contains('food')) return 'Food close-up';
    if (l.contains('cup of coffee') || l.contains('drink')) return 'Drink close-up';
    if (l.contains('pastries')) return 'Pastry display';
    if (l.contains('menu')) return 'Menu';
    if (l.contains('selfie')) return 'Person';
    if (l.contains('logo')) return 'Logo or sign';
    if (l.contains('blurry')) return 'Dark or blurry';
    if (l.contains('coworking')) return 'Coworking interior';
    if (l.contains('laptops')) return 'People working';
    if (l.contains('front entrance')) return 'Front';
    if (l.contains('terrace')) return 'Terrace';
    if (l.contains('coffee on a table')) return 'Coffee and room';
    if (l.contains('coliving')) return 'Common area';
    if (l.contains('interior')) return 'Interior';
    return '';
  }

  Widget _grid() {
    final cands = widget.candidates;
    final width = MediaQuery.of(context).size.width;
    final cols = width > 600 ? 4 : 3;
    final tile = ((width > 760 ? 760 : width) - 28 - (cols - 1) * 6) / cols;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: cands.map((c) {
        final uri = '${c['uri']}';
        final slot = _slotOf(uri);
        final good = c['good'] != false;
        final label = _short(c['label'] as String?);
        return InkWell(
          onTap: () => _toggle(uri),
          borderRadius: BorderRadius.circular(10),
          child: Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Opacity(
                opacity: good ? 1 : .55,
                child: Image.network('${c['thumb'] ?? uri}',
                    width: tile,
                    height: tile * .75,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                        width: tile,
                        height: tile * .75,
                        color: Brand.field,
                        child: const Icon(Icons.broken_image_outlined,
                            color: Brand.inkMuted))),
              ),
            ),
            if (slot >= 0)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Brand.accent, width: 3)),
                ),
              ),
            if (slot >= 0)
              Positioned(
                top: 6,
                left: 6,
                child: CircleAvatar(
                    radius: 12,
                    backgroundColor: Brand.accent,
                    child: Text('${slot + 1}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w800))),
              ),
            if (label.isNotEmpty)
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(
                      '$label${c['weak'] == true ? ' · weak' : ''}'
                      '${c['source'] == 'community' ? ' · nomad' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 10.5)),
                ),
              ),
          ]),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = _urls.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Photos: ${widget.name}', overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, _urls),
              child: const Text('Save',
                  style: TextStyle(fontWeight: FontWeight.w700))),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(padding: const EdgeInsets.all(14), children: [
            if (widget.candidates.isNotEmpty) ...[
              const Text('SUGGESTED',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .8,
                      color: Brand.inkMuted)),
              const SizedBox(height: 4),
              const Text(
                  'The place\'s Google photos and nomads\' photos, best first: '
                  'the ones that show the space, not the food. The numbered '
                  'ones are in. Tap to add or remove; the order is the order '
                  'on the page, the first is the main picture.',
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
              const SizedBox(height: 8),
              _grid(),
              const SizedBox(height: 14),
              const Text('OR PASTE LINKS',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .8,
                      color: Brand.inkMuted)),
              const SizedBox(height: 6),
            ],
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Brand.field, borderRadius: BorderRadius.circular(12)),
              child: Text(
                  widget.candidates.isEmpty
                      ? 'Suggestions arrive a minute or two after queueing. '
                          'Or open the place on Google, right-click a photo, '
                          'choose "Copy image address", and paste it below. '
                          'At least three; the first one is the main picture.'
                      : 'Any photo not in the grid: right-click it on Google, '
                          '"Copy image address", paste into a free slot.',
                  style: const TextStyle(fontSize: 12.5, height: 1.45)),
            ),
            const SizedBox(height: 10),
            // Straight to the place on Google (its panel with the
            // photos), not the directions page.
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: () => launchUrl(
                      Uri.https('www.google.com', '/search',
                          {'q': widget.searchText}),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.travel_explore, size: 18),
                  label: const Text('Open on Google')),
              if (widget.placeId != null)
                OutlinedButton.icon(
                    onPressed: () => launchUrl(
                        Uri.https('www.google.com', '/maps/place/',
                            {'q': 'place_id:${widget.placeId}'}),
                        mode: LaunchMode.externalApplication),
                    icon: const Icon(Icons.photo_outlined, size: 18),
                    label: const Text('Photos on Google Maps')),
            ]),
            const SizedBox(height: 12),
            for (var i = 0; i < 5; i++) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _ctl[i].text.trim().startsWith('http')
                      ? Image.network(_ctl[i].text.trim(),
                          width: 72,
                          height: 54,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                              width: 72,
                              height: 54,
                              color: Brand.field,
                              child: const Icon(Icons.broken_image_outlined,
                                  color: Brand.inkMuted)))
                      : Container(
                          width: 72,
                          height: 54,
                          color: Brand.field,
                          child: Center(
                              child: Text('${i + 1}',
                                  style: const TextStyle(
                                      color: Brand.inkMuted,
                                      fontWeight: FontWeight.w700)))),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _ctl[i],
                    maxLines: 2,
                    minLines: 1,
                    style: const TextStyle(fontSize: 12),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                        labelText: i == 0 ? 'Main photo link' : 'Photo ${i + 1} link',
                        hintText: 'https://...',
                        filled: true,
                        fillColor: Brand.field,
                        suffixIcon: _ctl[i].text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () =>
                                    setState(() => _ctl[i].clear())),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none)),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
            ],
            Text(
                n >= _WebsiteScreenState.minPhotos
                    ? '$n photos. Enough to approve.'
                    : '$n of ${_WebsiteScreenState.minPhotos} needed.',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: n >= _WebsiteScreenState.minPhotos
                        ? Brand.success
                        : Brand.goldTextDark)),
            const SizedBox(height: 10),
            ElevatedButton.icon(
                onPressed: () => Navigator.pop(context, _urls),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save photos')),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ region picker

class _RegionPicker extends StatefulWidget {
  final List<Map<String, dynamic>> regions;
  final String? forName;
  final String? title;
  final String? subtitle;
  /// Offered when nothing matches: pull the site's current items into
  /// the app (for something made in Webflow by hand).
  final Future<void> Function()? onRefresh;
  const _RegionPicker(
      {required this.regions,
      this.forName,
      this.title,
      this.subtitle,
      this.onRefresh});
  @override
  State<_RegionPicker> createState() => _RegionPickerState();
}

class _RegionPickerState extends State<_RegionPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final rows = q.isEmpty
        ? widget.regions
        : widget.regions
            .where((r) =>
                '${r['name']} ${r['country']}'.toLowerCase().contains(q))
            .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 8),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * .7,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                widget.title ??
                    'Which Region is ${widget.forName ?? 'this space'} in?',
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 4),
            Text(
                widget.subtitle ??
                    'Regions are the city pages on nomadwise.io. A city '
                        'without one can be created from the pin menu.',
                style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
            const SizedBox(height: 10),
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search regions',
                  filled: true,
                  fillColor: Brand.field,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none)),
              onChanged: (s) => setState(() => _q = s),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                q.isEmpty
                                    ? 'Nothing here yet.'
                                    : 'Nothing matches "${_q.trim()}".',
                                style: const TextStyle(
                                    fontSize: 13, color: Brand.inkSecondary)),
                            if (widget.onRefresh != null) ...[
                              const SizedBox(height: 6),
                              const Text(
                                  'Made in Webflow recently? The app keeps a '
                                  'copy of the site\'s list; refresh it and '
                                  'reload in a minute or two.',
                                  style: TextStyle(
                                      fontSize: 12.5, color: Brand.inkMuted)),
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                  onPressed: () async {
                                    await widget.onRefresh!();
                                    if (context.mounted) Navigator.pop(context);
                                  },
                                  icon: const Icon(Icons.sync, size: 16),
                                  label: const Text('Refresh from Webflow')),
                            ],
                          ]))
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, i) => ListTile(
                        dense: true,
                        title: Text(rows[i]['name'] ?? ''),
                        subtitle: rows[i]['country'] != null
                            ? Text(rows[i]['country'],
                                style: const TextStyle(fontSize: 12))
                            : null,
                        onTap: () => Navigator.pop(context, rows[i]),
                      ),
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- sitemap

/// Released pages not yet in the custom sitemap, turned into the exact
/// <url> blocks Jonathan pastes into it: priority 0.80, lastmod dated
/// yesterday with a randomised time of day, earliest first.
class _SitemapTab extends StatefulWidget {
  final List<Map<String, dynamic>> pending;
  final Future<void> Function(List<String> ids) onMarked;
  final Future<void> Function(String text, String toast) copy;
  const _SitemapTab(
      {required this.pending, required this.onMarked, required this.copy});
  @override
  State<_SitemapTab> createState() => _SitemapTabState();
}

class _SitemapTabState extends State<_SitemapTab> {
  final Set<String> _excluded = {};
  String? _xml;
  bool _busy = false;

  List<Map<String, dynamic>> get _chosen =>
      widget.pending.where((v) => !_excluded.contains(v['id'])).toList();

  String _generate() {
    // Always yesterday's date; only the time of day is randomised.
    final rnd = Random();
    final y = DateTime.now().toUtc().subtract(const Duration(days: 1));
    final dayStart = DateTime.utc(y.year, y.month, y.day);
    final stamps = _chosen
        .map((v) => (
              slug: v['webflow_slug'] as String,
              at: dayStart.add(Duration(seconds: rnd.nextInt(86400)))
            ))
        .toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    final fmt = DateFormat("yyyy-MM-dd'T'HH:mm:ss");
    return stamps
        .map((s) => '<url>\n'
            '<loc>https://www.nomadwise.io/coworking/${s.slug}</loc>\n'
            '<lastmod>${fmt.format(s.at)}+00:00</lastmod>\n'
            '<priority>0.80</priority>\n'
            '</url>')
        .join('\n');
  }

  Future<void> _alreadyAdded(Map<String, dynamic> v) async {
    setState(() => _busy = true);
    try {
      await widget.onMarked([v['id'] as String]);
      if (mounted) {
        setState(() {
          _excluded.remove(v['id']);
          _xml = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${v['name']} removed. If it is not in the live '
                'sitemap it will be back after tonight\'s check.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pending;
    if (pending.isEmpty) {
      return ListView(padding: const EdgeInsets.all(24), children: const [
        SizedBox(height: 48),
        Icon(Icons.account_tree_outlined, size: 40, color: Brand.inkMuted),
        SizedBox(height: 12),
        Text('Sitemap is up to date',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        SizedBox(height: 6),
        Text(
            'Every released page has its entry. Newly released pages '
            'appear here with a ready-to-paste block.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13.5, color: Brand.inkMuted, height: 1.5)),
      ]);
    }
    return ListView(padding: const EdgeInsets.all(14), children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(2, 6, 2, 10),
        child: Text(
            'Released pages missing from the custom sitemap, checked '
            'against the live sitemap every night. Untick any you want to '
            'leave out, generate, copy, paste into the sitemap in Webflow, '
            'then mark them as added. The tick on the right removes a page '
            'you know is already in the sitemap.',
            style: TextStyle(fontSize: 12.5, color: Brand.inkMuted, height: 1.4)),
      ),
      ...pending.map((v) => CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            value: !_excluded.contains(v['id']),
            title: Text(v['name'] ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('/coworking/${v['webflow_slug']}',
                style: const TextStyle(fontSize: 12)),
            // "Already in the sitemap": drops the page from this list
            // without generating anything. Safe to get wrong: the
            // nightly check reads the live sitemap and brings back any
            // page that is not really there.
            secondary: IconButton(
              tooltip: 'Already in the sitemap',
              icon: const Icon(Icons.playlist_add_check, size: 22),
              onPressed: _busy ? null : () => _alreadyAdded(v),
            ),
            onChanged: (on) => setState(() {
              if (on == true) {
                _excluded.remove(v['id']);
              } else {
                _excluded.add(v['id']);
              }
              _xml = null;
            }),
          )),
      const SizedBox(height: 10),
      Row(children: [
        ElevatedButton.icon(
            onPressed: _chosen.isEmpty
                ? null
                : () => setState(() => _xml = _generate()),
            icon: const Icon(Icons.code, size: 18),
            label: Text('Generate ${_chosen.length} '
                'entr${_chosen.length == 1 ? 'y' : 'ies'}')),
      ]),
      if (_xml != null) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Brand.field, borderRadius: BorderRadius.circular(12)),
          child: SelectableText(_xml!,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 11.5, height: 1.4)),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => widget.copy(_xml!, 'Sitemap entries copied'),
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: const Text('Copy')),
          ElevatedButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      try {
                        await widget.onMarked(
                            _chosen.map((v) => v['id'] as String).toList());
                        if (mounted) setState(() => _xml = null);
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Mark as added to the sitemap')),
        ]),
        const SizedBox(height: 6),
        const Text(
            'Every entry is dated yesterday with a randomised time of '
            'day, earliest first.',
            style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
      ],
      const SizedBox(height: 30),
    ]);
  }
}

// ------------------------------------------------- Region and Location creators

/// A new city page on nomadwise.io. The sync builds it the way the
/// existing ones are (name, label, slug, category label, H2, map
/// centre, Country link), publishes it and puts it in the pickers.
class _NewRegionPage extends StatefulWidget {
  final SupabaseService supabase;
  final List<Map<String, dynamic>> countries;
  final List<Map<String, dynamic>> regions;
  final String? initialName;
  final String? initialCountry;
  final double? lat;
  final double? lng;
  final String? venueId;
  final String? state;
  const _NewRegionPage(
      {required this.supabase,
      required this.countries,
      required this.regions,
      this.initialName,
      this.initialCountry,
      this.state,
      this.lat,
      this.lng,
      this.venueId});
  @override
  State<_NewRegionPage> createState() => _NewRegionPageState();
}

class _NewRegionPageState extends State<_NewRegionPage> {
  late final _name = TextEditingController(text: widget.initialName ?? '');
  late final _lat =
      TextEditingController(text: widget.lat?.toStringAsFixed(4) ?? '');
  late final _lng =
      TextEditingController(text: widget.lng?.toStringAsFixed(4) ?? '');
  final _zoom = TextEditingController(text: '12');
  final _desc = TextEditingController();
  Map<String, dynamic>? _country;
  bool _busy = false;

  // City centre lookup: "Name, Country" -> coordinates, the same thing
  // the founder used to do by hand on a geocoding website. The country
  // is always part of the query so Lancaster, England is not Lancaster,
  // Pennsylvania.
  final _places = PlacesService();
  CityCentre? _found;
  bool _locating = false;
  bool _coordsTouched = false;
  Timer? _lookupTimer;

  // Live preview of the city page's map: the same centre and zoom the
  // page will use, so a wrong Lancaster or a zoom that shows half of
  // Europe is caught here rather than on the live site. Panning the
  // preview and tapping "Use this view" writes the map back into the
  // fields, the other direction.
  GoogleMapController? _map;
  CameraPosition? _camera;

  LatLng? get _point {
    final la = double.tryParse(_lat.text.trim());
    final ln = double.tryParse(_lng.text.trim());
    if (la == null || ln == null || la.abs() > 90 || ln.abs() > 180) {
      return null;
    }
    return LatLng(la, ln);
  }

  double get _zoomValue =>
      (double.tryParse(_zoom.text.trim()) ?? 12).clamp(2, 20).toDouble();

  /// Fields changed (typed, found, or zoom edited): move the preview.
  void _moveMap() {
    final p = _point;
    if (p == null) {
      setState(() {});
      return;
    }
    _map?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: p, zoom: _zoomValue)));
    setState(() {});
  }

  /// The preview's current centre and zoom become the page's.
  void _useMapView() {
    final c = _camera;
    if (c == null) return;
    setState(() {
      _lat.text = c.target.latitude.toStringAsFixed(6);
      _lng.text = c.target.longitude.toStringAsFixed(6);
      _zoom.text = c.zoom.round().toString();
      _coordsTouched = true;
    });
  }

  Widget _mapPreview() {
    final p = _point;
    final border = BorderRadius.circular(12);
    if (p == null) {
      return Container(
        height: 120,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: Brand.field, borderRadius: border),
        child: const Text('The map preview appears once there are coordinates.',
            style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: border,
        child: SizedBox(
          height: 260,
          child: GoogleMap(
            initialCameraPosition: CameraPosition(target: p, zoom: _zoomValue),
            markers: {
              Marker(markerId: const MarkerId('centre'), position: p),
            },
            onMapCreated: (c) => _map = c,
            onCameraMove: (c) => _camera = c,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: true,
            mapToolbarEnabled: false,
            style: '''[
              {"featureType": "poi.business",
               "stylers": [{"visibility": "off"}]}
            ]''',
          ),
        ),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: Text(
              'This is the city page map at zoom ${_zoomValue.round()} (the '
              'full-page map opens two levels closer). Drag or zoom to '
              'adjust, then use that view.',
              style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
            onPressed: _useMapView,
            icon: const Icon(Icons.center_focus_strong, size: 15),
            label: const Text('Use this view')),
      ]),
    ]);
  }

  @override
  void initState() {
    super.initState();
    final want = (widget.initialCountry ?? '').trim().toLowerCase();
    if (want.isNotEmpty) {
      _country = widget.countries
          .where((c) => '${c['name']}'.toLowerCase() == want)
          .firstOrNull;
    }
    _slugCtl.text = _slugSuggestion;
    _scheduleLookup();
  }

  @override
  void dispose() {
    _lookupTimer?.cancel();
    super.dispose();
  }

  String get _lookupQuery {
    final n = _name.text.trim();
    final c = '${_country?['name'] ?? ''}'.trim();
    if (n.isEmpty || c.isEmpty) return '';
    return '$n, $c';
  }

  /// Runs shortly after typing stops, so the API is asked once per
  /// name rather than once per letter. Hand-typed coordinates are never
  /// overwritten; the Find button does that on purpose.
  void _scheduleLookup() {
    _lookupTimer?.cancel();
    if (_coordsTouched || _lookupQuery.isEmpty) return;
    _lookupTimer = Timer(const Duration(milliseconds: 800), _lookup);
  }

  Future<void> _lookup({bool force = false}) async {
    final q = _lookupQuery;
    if (q.isEmpty) {
      if (force) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Type the city name and pick the Country first.')));
      }
      return;
    }
    if (_found != null && _found!.query == q && !force) return;
    setState(() => _locating = true);
    final hit = await _places.cityCentre(q);
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (hit == null) {
        _found = null;
        return;
      }
      _found = CityCentre(
          name: hit.name, address: hit.address, lat: hit.lat, lng: hit.lng,
          query: q);
      if (force || !_coordsTouched) {
        _lat.text = hit.lat.toStringAsFixed(6);
        _lng.text = hit.lng.toStringAsFixed(6);
        _coordsTouched = false;
      }
    });
    _moveMap();
  }

  static String _slug(String x) => _WebsiteScreenState._slugify(x);

  final _slugCtl = TextEditingController();
  bool _slugTouched = false;

  /// The site's convention: country-city, and country-state-city
  /// where the site already does that (United States, India).
  String get _slugSuggestion {
    final c = _country == null ? '' : _slug('${_country!['name']}');
    final n = _slug(_name.text);
    final st = _slug(widget.state ?? '');
    final layered = c == 'united-states' || c == 'india';
    return [c, if (layered && st.isNotEmpty) st, n]
        .where((x) => x.isNotEmpty)
        .join('-');
  }

  /// Existing Regions in the same country, as examples of the pattern.
  List<String> get _siblings {
    final c = _country?['name'];
    if (c == null) return const [];
    return widget.regions
        .where((r) => r['country'] == c && r['slug'] != null)
        .map((r) => '${r['slug']}')
        .where((x) => x.contains('-'))
        .take(3)
        .toList();
  }

  void _refreshSlug() {
    if (!_slugTouched) _slugCtl.text = _slugSuggestion;
    setState(() {});
  }

  String get _slugPreview => _slug(_slugCtl.text);

  /// A Region with this label already exists: no duplicates.
  Map<String, dynamic>? get _existing {
    final n = _name.text.trim().toLowerCase();
    if (n.isEmpty) return null;
    return widget.regions
        .where((r) => '${r['name']}'.trim().toLowerCase() == n)
        .firstOrNull;
  }

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (_) => _RegionPicker(
            regions: widget.countries,
            title: 'Which Country?',
            subtitle: 'The Countries nomadwise.io already has. A new '
                'country still needs creating in Webflow first.'));
    if (picked != null) {
      _country = picked;
      _refreshSlug();
      _scheduleLookup();
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _country == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('A name and a Country are needed.')));
      return;
    }
    if (_slugPreview.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The slug cannot be empty.')));
      return;
    }
    if (widget.regions.any((r) => r['slug'] == _slugPreview)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('A Region already uses /${_slugPreview}.')));
      return;
    }
    if (_existing != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$name already exists on the site. Pick it instead.')));
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.supabase.createTaxonomyRequest({
        'kind': 'region',
        'name': name,
        'country_id': _country!['id'],
        'lat': double.tryParse(_lat.text.trim()),
        'lng': double.tryParse(_lng.text.trim()),
        'zoom': int.tryParse(_zoom.text.trim()),
        'slug': _slugPreview,
        'description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        'venue_id': widget.venueId,
      });
      if (mounted) Navigator.pop(context, name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('That did not save: $e'),
            backgroundColor: Brand.red));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dup = _existing;
    final nameText = _name.text.trim().isEmpty ? '...' : _name.text.trim();
    return Scaffold(
      appBar: AppBar(title: const Text('New Region (city page)')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Text(
                'A Region is a city page on nomadwise.io. The sync creates '
                'it exactly like the existing ones and publishes it within a '
                'minute or two; description and photos can be polished in '
                'Webflow later.',
                style: TextStyle(
                    fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
            const SizedBox(height: 14),
            TextField(
                controller: _name,
                onChanged: (_) {
                  _refreshSlug();
                  _scheduleLookup();
                },
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'City name as shown on the site',
                    hintText: 'e.g. Porto')),
            if (dup != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('${dup['name']} already exists on the site.',
                    style: const TextStyle(fontSize: 12.5, color: Brand.red)),
              ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickCountry,
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Country',
                    suffixIcon: Icon(Icons.arrow_drop_down)),
                child: Text(_country?['name'] ?? 'Choose',
                    style: TextStyle(
                        color: _country == null ? Brand.inkMuted : null)),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _lat,
                      onChanged: (_) {
                        _coordsTouched = true;
                        _moveMap();
                      },
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      decoration:
                          const InputDecoration(labelText: 'Latitude'))),
              const SizedBox(width: 10),
              Expanded(
                  child: TextField(
                      controller: _lng,
                      onChanged: (_) {
                        _coordsTouched = true;
                        _moveMap();
                      },
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      decoration:
                          const InputDecoration(labelText: 'Longitude'))),
              const SizedBox(width: 10),
              SizedBox(
                  width: 80,
                  child: TextField(
                      controller: _zoom,
                      onChanged: (_) => _moveMap(),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Zoom'))),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              OutlinedButton.icon(
                  onPressed: _locating ? null : () => _lookup(force: true),
                  icon: _locating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.my_location, size: 16),
                  label: Text(_locating ? 'Finding' : 'Find city centre')),
              // The by-hand route, for checking the found point or when
              // the lookup draws a blank: opens the site the founder used
              // before, in the browser; paste the numbers back here.
              TextButton.icon(
                  onPressed: () => launchUrl(
                      Uri.https('www.gps-coordinates.net', '/'),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new, size: 15),
                  label: const Text('Look up on gps-coordinates.net')),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: _found == null
                    ? Text(
                        _lookupQuery.isEmpty
                            ? 'Type the city and pick the Country and the '
                                'centre is looked up for you.'
                            : _locating
                                ? 'Looking up $_lookupQuery'
                                : 'Nothing found for $_lookupQuery. Check '
                                    'the spelling or type the coordinates.',
                        style: const TextStyle(
                            fontSize: 11.5, color: Brand.inkMuted))
                    : Text.rich(
                        TextSpan(children: [
                          const TextSpan(text: 'Found '),
                          TextSpan(
                              text: _found!.address.isEmpty
                                  ? _found!.name
                                  : _found!.address,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                          if (_coordsTouched)
                            const TextSpan(
                                text: ' (coordinates edited by hand, tap '
                                    'Find to use the found ones)'),
                        ]),
                        style: const TextStyle(
                            fontSize: 11.5, color: Brand.inkSecondary)),
              ),
            ]),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                  'Map centre of the city page, found from the city name '
                  'and Country (the Country keeps same-named cities apart). '
                  'Zoom 12 suits a city, 10 a large one.',
                  style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
            ),
            const SizedBox(height: 10),
            _mapPreview(),
            const SizedBox(height: 12),
            TextField(
                controller: _desc,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                    labelText: 'About the city (optional)',
                    hintText:
                        'A paragraph or two. Blank line between paragraphs.',
                    alignLabelWithHint: true)),
            const SizedBox(height: 12),
            // The slug is the page address for ever (a rename needs a
            // redirect), so it is shown and editable before creating.
            TextField(
                controller: _slugCtl,
                onChanged: (_) => setState(() => _slugTouched = true),
                decoration: InputDecoration(
                    labelText: 'Slug (page address)',
                    prefixText: '/region/',
                    helperText: 'Site convention: country-city'
                        '${_siblings.isEmpty ? '' : ', like ${_siblings.join(', ')}'}',
                    helperMaxLines: 3,
                    suffixIcon: _slugTouched
                        ? IconButton(
                            tooltip: 'Back to the convention',
                            icon: const Icon(Icons.refresh, size: 18),
                            onPressed: () {
                              _slugTouched = false;
                              _refreshSlug();
                            })
                        : null)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Brand.field, borderRadius: BorderRadius.circular(12)),
              child: Text(
                  'Page: /region/${_slugPreview.isEmpty ? '...' : _slugPreview}\n'
                  'Name: $nameText${_country == null ? '' : ', ${_country!['name']}'}\n'
                  'Label: Cafes & Coworking Spaces in $nameText'
                  '${_country == null ? '' : ', ${_country!['name']}'}',
                  style: const TextStyle(fontSize: 12.5, height: 1.5)),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create on nomadwise.io')),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }
}

/// A new neighbourhood page inside a Region. Built, published and
/// wired into the Region's Locations list by the sync.
class _NewLocationPage extends StatefulWidget {
  final SupabaseService supabase;
  final List<Map<String, dynamic>> regions;
  final List<Map<String, dynamic>> locations;
  final String? initialRegionId;
  final String? initialName;
  final String? venueId;
  const _NewLocationPage(
      {required this.supabase,
      required this.regions,
      this.locations = const [],
      this.initialRegionId,
      this.initialName,
      this.venueId});
  @override
  State<_NewLocationPage> createState() => _NewLocationPageState();
}

class _NewLocationPageState extends State<_NewLocationPage> {
  late final _name = TextEditingController(text: widget.initialName ?? '');
  final _desc = TextEditingController();
  final _slugCtl = TextEditingController();
  bool _slugTouched = false;
  Map<String, dynamic>? _region;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _region = widget.regions
        .where((r) => r['id'] == widget.initialRegionId)
        .firstOrNull;
    _slugCtl.text = _slugSuggestion;
  }

  static String _slug(String x) => _WebsiteScreenState._slugify(x);

  /// The site's convention for areas: country-city-area, whatever the
  /// Region's own (possibly older) slug looks like.
  String get _slugSuggestion {
    final r = _region;
    if (r == null) return _slug(_name.text);
    return [
      _slug('${r['country'] ?? ''}'),
      _slug('${r['name'] ?? ''}'),
      _slug(_name.text),
    ].where((x) => x.isNotEmpty).join('-');
  }

  List<String> get _siblings => _region == null
      ? const []
      : widget.locations
          .where((l) => l['region_id'] == _region!['id'] && l['slug'] != null)
          .map((l) => '${l['slug']}')
          .where((x) => x.contains('-'))
          .take(3)
          .toList();

  void _refreshSlug() {
    if (!_slugTouched) _slugCtl.text = _slugSuggestion;
    setState(() {});
  }

  String get _slugPreview => _slug(_slugCtl.text);

  Future<void> _pickRegion() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (_) => _RegionPicker(
            regions: widget.regions,
            title: 'Inside which Region?',
            subtitle: 'The city page this area belongs to.'));
    if (picked != null) {
      _region = picked;
      _refreshSlug();
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _region == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('A name and a Region are needed.')));
      return;
    }
    if (_slugPreview.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The slug cannot be empty.')));
      return;
    }
    if (widget.locations.any((l) => l['slug'] == _slugPreview)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('A Location already uses /${_slugPreview}.')));
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.supabase.createTaxonomyRequest({
        'kind': 'location',
        'name': name,
        'region_id': _region!['id'],
        'slug': _slugPreview,
        'description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        'venue_id': widget.venueId,
      });
      if (mounted) Navigator.pop(context, name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('That did not save: $e'),
            backgroundColor: Brand.red));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _region;
    final nameText = _name.text.trim().isEmpty ? '...' : _name.text.trim();
    final regionText = r == null ? '' : ', ${r['name']}';
    return Scaffold(
      appBar: AppBar(title: const Text('New Location (area page)')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Text(
                'A Location is a neighbourhood page inside a Region. The sync '
                'creates it like the existing ones, links it both ways with '
                'the Region, publishes it and puts it in the pickers within a '
                'minute or two.',
                style: TextStyle(
                    fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
            const SizedBox(height: 14),
            InkWell(
              onTap: _pickRegion,
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Region (city page)',
                    suffixIcon: Icon(Icons.arrow_drop_down)),
                child: Text(
                    r == null
                        ? 'Choose'
                        : '${r['name']}${r['country'] != null ? ', ${r['country']}' : ''}',
                    style:
                        TextStyle(color: r == null ? Brand.inkMuted : null)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
                controller: _name,
                onChanged: (_) => _refreshSlug(),
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Area name as shown on the site',
                    hintText: 'e.g. Anjos')),
            const SizedBox(height: 12),
            TextField(
                controller: _slugCtl,
                onChanged: (_) => setState(() => _slugTouched = true),
                decoration: InputDecoration(
                    labelText: 'Slug (page address)',
                    prefixText: '/locations/',
                    helperText: 'Site convention: country-city-area'
                        '${_siblings.isEmpty ? '' : ', like ${_siblings.join(', ')}'}',
                    helperMaxLines: 3,
                    suffixIcon: _slugTouched
                        ? IconButton(
                            tooltip: 'Back to the convention',
                            icon: const Icon(Icons.refresh, size: 18),
                            onPressed: () {
                              _slugTouched = false;
                              _refreshSlug();
                            })
                        : null)),
            const SizedBox(height: 12),
            TextField(
                controller: _desc,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                    labelText: 'About the area (optional)',
                    alignLabelWithHint: true)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Brand.field, borderRadius: BorderRadius.circular(12)),
              child: Text(
                  'Page: /locations/${_slugPreview.isEmpty ? '...' : _slugPreview}\n'
                  'Name on the site: $nameText$regionText\n'
                  'Label: Cafes & Coworking Spaces in $nameText$regionText',
                  style: const TextStyle(fontSize: 12.5, height: 1.5)),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create on nomadwise.io')),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }
}

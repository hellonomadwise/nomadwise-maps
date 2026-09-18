import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/venue.dart';
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
  List<Map<String, dynamic>> _locations = [];
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
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
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
          },
          '${v['name']} approved. The draft is created within minutes.');
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
    if (_regions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The list of Regions is copied by the nightly '
              'sync. Try again tomorrow.')));
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (_) => _RegionPicker(regions: _regions, forName: v['name']));
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
    var x = s.trim().toLowerCase();
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
        key: 'released',
        label: 'Released',
        count: _released.length,
        color: Brand.success,
        hint: 'Live on nomadwise.io.',
        empty: 'Nothing released yet.'
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
        key: 'region',
        label: 'Blocked',
        count: g.needsRegion.length,
        color: Brand.goldTextDark,
        hint: 'Blocked: a page needs a Country and a Region, and a slug no '
            'other listing uses. Fix the item to unblock.',
        empty: 'Nothing is blocked.'
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
    ];
    var key = _groupKey;
    if (key == null || groups.firstWhere((x) => x.key == key).count == 0) {
      const steps = ['fresh', 'preparing', 'ready', 'region'];
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
        if (region != null) ...[
          _kv(Icons.place_outlined,
              '${region['name']}${region['country'] != null ? ', ${region['country']}' : ''}'
              '${chosen ? '' : '  (matched from the city; change it if wrong)'}'),
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
          if (p.isNotEmpty) 'website_prepared': next,
        },
        '${saved.length} photo${saved.length == 1 ? '' : 's'} saved.');
  }

  /// The photos row on a card: thumbnails, the count, and the button.
  Widget _photosRow(Map<String, dynamic> v) {
    final urls = _pasted(v);
    final count = _photoCount(v);
    final enough = count >= minPhotos;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Row(children: [
        if (urls.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView.separated(
              shrinkWrap: true,
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
          )
        else
          const Icon(Icons.photo_library_outlined,
              size: 18, color: Brand.inkMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              enough
                  ? '$count photo${count == 1 ? '' : 's'} ready for the page'
                  : '$count of $minPhotos photos needed before Approve',
              style: TextStyle(
                  fontSize: 12.5,
                  color: enough ? Brand.success : Brand.goldTextDark,
                  fontWeight: FontWeight.w600)),
        ),
        TextButton.icon(
            onPressed: () => _editPhotos(v),
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
            label: Text(urls.isEmpty ? 'Add photos' : 'Edit photos')),
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
            ElevatedButton.icon(
                onPressed: () => _dismissAs(v, dismissReasons.first),
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
            'Open Webflow, add the photos and words, publish. The sync '
            'marks it released once the page is live.'),
        ..._drafts.map((v) => _card(
              child: Row(children: [
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
            )),
      ],
      const SizedBox(height: 30),
    ]);
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
  final Map<String, dynamic>? regionGuess;
  final Map<String, dynamic>? locationGuess;
  final List<String> googleAreas;
  final Map<String, dynamic> row;
  const _EditVenuePage(
      {required this.venue,
      required this.supabase,
      required this.regions,
      required this.locations,
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

  Future<String?> _askName(String what) async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('Needs a new $what'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(
                    'Nothing is created from here. The name is recorded, '
                    'the space waits under Blocked, and when you create the '
                    '$what in Webflow with exactly this name it is linked '
                    'automatically.',
                    style: const TextStyle(fontSize: 13, height: 1.4)),
                const SizedBox(height: 12),
                TextField(
                    controller: ctl,
                    autofocus: true,
                    decoration: InputDecoration(
                        labelText: '$what name as it should appear')),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Record')),
              ],
            ));
    final name = ctl.text.trim();
    return ok == true && name.isNotEmpty ? name : null;
  }

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
      final name = await _askName('Region');
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
      final name = await _askName('Location');
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
  const _PhotosPage(
      {required this.name,
      required this.searchText,
      required this.initial,
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
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Brand.field, borderRadius: BorderRadius.circular(12)),
              child: const Text(
                  'Open the place on Google, right-click a photo, choose '
                  '"Copy image address", and paste it below. At least three; '
                  'the first one is the main picture. They go straight into '
                  'the Images entry when the draft is created.',
                  style: TextStyle(fontSize: 12.5, height: 1.45)),
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
  const _RegionPicker(
      {required this.regions, this.forName, this.title, this.subtitle});
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
                    'Regions are the city pages on nomadwise.io. If the city '
                        'has no Region yet, create it in Webflow first.',
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
              child: ListView.builder(
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

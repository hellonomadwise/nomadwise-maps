import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:url_launcher/url_launcher.dart';

import '../screens/nearby_spaces_screen.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

/// Control centre > Clean-up > No Location (migration 173). Every live
/// page on nomadwise.io without a Location, to work through one by one:
/// give it a Location of its Region, make a new Location for it, or
/// say that no Location is fine. Jonathan, 8 Oct 2026: "a list of all
/// spaces in webflow that don't have locations assigned to them, where
/// I can work through them, either assigning that its totally fine that
/// there isn't a location set, that its deliberate, or move through to
/// creating and then assigning a location, and then it getting all
/// linked up with the region and everything within webflow".
///
/// A Location chosen here is put on the Webflow page by the website
/// sync within minutes; nothing changes on the live page before the
/// founder confirms exactly what will change.
class NoLocationTab extends StatefulWidget {
  final SupabaseService supabase;

  /// The app's copy of the site's Locations ({id, name, region_id}).
  final List<Map<String, dynamic>> locations;

  /// Opens the usual "new Location" page, filled in; the name made,
  /// or null when it was left.
  final Future<String?> Function(String regionId, String? name, String venueId)
      newLocation;

  /// Starts the website sync now rather than at its next turn.
  final Future<void> Function() startRun;

  final void Function(int count) onCount;

  const NoLocationTab(
      {super.key,
      required this.supabase,
      required this.locations,
      required this.newLocation,
      required this.startRun,
      required this.onCount});

  @override
  State<NoLocationTab> createState() => _NoLocationTabState();
}

class _NoLocationTabState extends State<NoLocationTab> {
  List<Map<String, dynamic>> _todo = [];
  List<Map<String, dynamic>> _settled = [];
  bool _loading = true;
  String? _error;
  bool _showSettled = false;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  static List<Map<String, dynamic>> _maps(Object? x) => [
        for (final e in (x is List ? x : const []))
          if (e is Map) Map<String, dynamic>.from(e),
      ];

  static String _plain(Object e) => e is PostgrestException
      ? e.message
      : '$e'.replaceFirst('Exception: ', '');

  Future<void> _load() async {
    try {
      final r = await widget.supabase.liveWithoutLocation();
      if (!mounted) return;
      setState(() {
        _todo = _maps(r['todo']);
        _settled = _maps(r['settled']);
        _loading = false;
        _error = null;
      });
      widget.onCount(_todo
          .where((v) => v['applying'] == null && v['waiting_for'] == null)
          .length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _plain(e);
      });
    }
  }

  void _snack(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text),
        duration: Duration(seconds: bad ? 6 : 4),
        backgroundColor: bad ? Brand.red : null));
  }

  Future<bool> _confirm(String title, String body, String yes) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(title),
              content: Text(body),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(yes)),
              ],
            ));
    return ok == true;
  }

  Future<void> _set(Map<String, dynamic> v, String kind,
      {String? locationId, String? name, String? done}) async {
    final id = '${v['id']}';
    setState(() => _busy.add(id));
    try {
      await widget.supabase
          .liveLocationSet(id, kind, locationId: locationId, name: name);
      if (kind == 'location' || kind == 'new') {
        try {
          await widget.startRun();
        } catch (_) {
          // The sync's own next turn picks it up.
        }
      }
      if (done != null) _snack(done);
      await _load();
    } catch (e) {
      _snack('That did not save: ${_plain(e)}', bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  /// An existing Location, after saying exactly what changes.
  Future<void> _useLocation(
      Map<String, dynamic> v, String locationId, String locationName) async {
    final ok = await _confirm(
        'Give ${v['name']} the Location $locationName?',
        'This changes the live page on nomadwise.io: ${v['name']} '
            '(/coworking/${v['slug'] ?? ''}) is filed under $locationName in '
            '${v['region'] ?? 'its Region'}, and appears on the '
            '$locationName page. It is done within minutes.',
        'Yes, set it');
    if (!ok) return;
    await _set(v, 'location',
        locationId: locationId,
        done: '$locationName is being set on ${v['name']}\'s page.');
  }

  Future<void> _noneIsFine(Map<String, dynamic> v) => _set(v, 'none',
      done: '${v['name']}: no Location, on purpose. It is under '
          '"Marked as fine" below.');

  /// A new Location: the usual page to make it, then the live page is
  /// linked to it once it exists.
  Future<void> _newLocation(Map<String, dynamic> v, String? name) async {
    final region = '${v['region_id'] ?? ''}';
    if (region.isEmpty) return;
    final made = await widget.newLocation(region, name, '${v['id']}');
    if (made == null || !mounted) return;
    await _set(v, 'new',
        name: made,
        done: '$made is being made on nomadwise.io; ${v['name']}\'s page is '
            'linked to it once it exists.');
  }

  /// The map of the spaces nearby, with the suggestion, the Locations
  /// around and "Ask Claude".
  Future<void> _choose(Map<String, dynamic> v) async {
    final choice = await Navigator.of(context).push<NearbyChoice>(
        MaterialPageRoute(
            builder: (_) => NearbySpacesScreen(
                venueId: '${v['id']}',
                venueName: '${v['name'] ?? ''}',
                regionId: v['region_id'] as String?)));
    if (choice == null || !mounted) return;
    switch (choice.id) {
      case 'none':
        await _noneIsFine(v);
      case 'new':
        await _newLocation(v, choice.name);
      case 'other':
        await _pickFromList(v);
      default:
        await _useLocation(v, choice.id, choice.name ?? 'that Location');
    }
  }

  /// The Region's Locations as a plain list, plus a new one.
  Future<void> _pickFromList(Map<String, dynamic> v) async {
    final inRegion = widget.locations
        .where((l) => l['region_id'] == v['region_id'])
        .toList()
      ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (ctx) => SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * .6,
                child: ListView(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                    child: Text(
                        'Which Location in ${v['region'] ?? 'the Region'} is '
                        '${v['name']} in?',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
                  ),
                  for (final l in inRegion)
                    ListTile(
                        dense: true,
                        title: Text('${l['name'] ?? ''}'),
                        onTap: () => Navigator.pop(ctx, l)),
                  ListTile(
                      dense: true,
                      leading: const Icon(Icons.add, size: 18),
                      title: const Text('A new Location'),
                      onTap: () => Navigator.pop(ctx, {'id': 'new'})),
                  ListTile(
                      dense: true,
                      leading: const Icon(Icons.check, size: 18),
                      title: const Text('No Location is fine'),
                      onTap: () => Navigator.pop(ctx, {'id': 'none'})),
                ]),
              ),
            ));
    if (picked == null || !mounted) return;
    if (picked['id'] == 'new') {
      await _newLocation(v, null);
    } else if (picked['id'] == 'none') {
      await _noneIsFine(v);
    } else {
      await _useLocation(v, '${picked['id']}', '${picked['name'] ?? ''}');
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Brand.red));
    }
    if (_error != null) {
      return ListView(padding: const EdgeInsets.all(24), children: [
        Text('The list could not be loaded.\n$_error',
            style: const TextStyle(color: Brand.inkSecondary)),
        const SizedBox(height: 10),
        Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(onPressed: _load, child: const Text('Try again'))),
      ]);
    }
    final open = _todo
        .where((v) => v['applying'] == null && v['waiting_for'] == null)
        .length;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 30),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                  open == 0
                      ? 'Every live page has a Location, or is marked as fine '
                          'without one.'
                      : '$open live ${open == 1 ? 'page has' : 'pages have'} '
                          'no Location. For each: choose one (the map shows '
                          'the spaces around it and can ask Claude), make a '
                          'new one, or mark that no Location is fine. A '
                          'Location is set on the live page within minutes.',
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
            ),
            for (final v in _todo) _card(v),
            if (_settled.isNotEmpty) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setState(() => _showSettled = !_showSettled),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(children: [
                    Text('MARKED AS FINE WITHOUT A LOCATION (${_settled.length})',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .4,
                            color: Brand.inkMuted)),
                    const SizedBox(width: 4),
                    Icon(_showSettled ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: Brand.inkMuted),
                  ]),
                ),
              ),
              if (_showSettled)
                for (final v in _settled)
                  ListTile(
                    dense: true,
                    title: Text('${v['name'] ?? ''}'),
                    subtitle: Text('${v['region'] ?? ''}'),
                    trailing: TextButton(
                        onPressed: _busy.contains('${v['id']}')
                            ? null
                            : () => _set(v, 'undo',
                                done: '${v['name']} is back on the list.'),
                        child: const Text('Undo')),
                  ),
            ],
          ]),
    );
  }

  Widget _card(Map<String, dynamic> v) {
    final id = '${v['id']}';
    final busy = _busy.contains(id);
    final region = '${v['region'] ?? ''}';
    final hasRegion = '${v['region_id'] ?? ''}'.isNotEmpty;
    final nLocs = (v['locations_in_region'] as num?)?.toInt() ?? 0;
    final verdict = v['verdict'] is Map
        ? Map<String, dynamic>.from(v['verdict'] as Map)
        : const <String, dynamic>{};
    final kind = '${verdict['verdict'] ?? 'none'}';
    final sugId = '${verdict['location_id'] ?? ''}';
    final sugName = '${verdict['location'] ?? ''}';
    final why = '${verdict['why'] ?? ''}'.trim();
    final applying = v['applying'] is Map ? v['applying'] as Map : null;
    final waiting = '${v['waiting_for'] ?? ''}';
    final error = '${v['error'] ?? ''}';
    final slug = '${v['slug'] ?? ''}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Brand.surface,
          border: Border.all(color: Brand.border),
          borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${v['name'] ?? ''}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 2),
        Text(
            [
              if (region.isNotEmpty) 'Region: $region' else 'No Region on record',
              if (hasRegion)
                nLocs == 0
                    ? 'no Locations in it yet'
                    : '$nLocs ${nLocs == 1 ? 'Location' : 'Locations'} in it',
            ].join(' · '),
            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        if (slug.isNotEmpty)
          InkWell(
            onTap: () =>
                launchUrl(Uri.parse('https://www.nomadwise.io/coworking/$slug')),
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('/coworking/$slug',
                  style: const TextStyle(
                      fontSize: 12,
                      color: Brand.logoNavy,
                      decoration: TextDecoration.underline)),
            ),
          ),
        const SizedBox(height: 8),
        if (applying != null)
          _note('Setting ${applying['name'] ?? 'the Location'} on the live '
              'page. Done within minutes.', Brand.logoTealTint)
        else if (waiting.isNotEmpty)
          _note('Waiting for the new Location "$waiting" to be made on '
              'nomadwise.io; the page is linked to it as soon as it exists.',
              Brand.logoTealTint)
        else if ((kind == 'assign' || kind == 'suggest') && sugId.isNotEmpty)
          _note('Suggested: $sugName. $why', Brand.goldTint)
        else if (why.isNotEmpty && hasRegion)
          _note(why, Brand.field),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Last try did not work: $error',
                style: const TextStyle(fontSize: 12.5, color: Brand.red)),
          ),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (applying != null || waiting.isNotEmpty)
            TextButton(
                onPressed: busy
                    ? null
                    : () => _set(v, 'undo', done: 'Stopped for ${v['name']}.'),
                child: const Text('Undo'))
          else if (!hasRegion)
            const Text('The nightly copy of the site fills in its Region.',
                style: TextStyle(fontSize: 12.5, color: Brand.inkMuted))
          else ...[
            if ((kind == 'assign' || kind == 'suggest') && sugId.isNotEmpty)
              ElevatedButton(
                  onPressed: busy ? null : () => _useLocation(v, sugId, sugName),
                  child: Text('Use $sugName')),
            OutlinedButton.icon(
                onPressed: busy ? null : () => _choose(v),
                icon: const Icon(Icons.map_outlined, size: 16),
                label: const Text('Choose on the map')),
            TextButton(
                onPressed: busy ? null : () => _pickFromList(v),
                child: const Text('From the list')),
            TextButton(
                onPressed: busy ? null : () => _noneIsFine(v),
                child: const Text('No Location is fine')),
          ],
        ]),
      ]),
    );
  }

  Widget _note(String text, Color tint) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration:
            BoxDecoration(color: tint, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.4)),
      );
}

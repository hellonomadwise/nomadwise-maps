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

class _WebsiteScreenState extends State<WebsiteScreen>
    with SingleTickerProviderStateMixin {
  final _supabase = SupabaseService();
  late final TabController _tabs = TabController(length: 4, vsync: this);

  List<Map<String, dynamic>>? _inbox;
  List<Map<String, dynamic>> _drafts = [];
  List<Map<String, dynamic>> _released = [];
  List<Map<String, dynamic>> _sitemap = [];
  List<Map<String, dynamic>> _regions = [];
  List<Map<String, dynamic>> _hidden = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
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
      ]);
      if (!mounted) return;
      setState(() {
        _inbox = results[0];
        _drafts = results[1];
        _released = results[2];
        _sitemap = results[3];
        _regions = results[4];
        _hidden = results[5];
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
      '${v['name']} queued. Its proposal will be ready tomorrow.');

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
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Approve for nomadwise.io?'),
              content: Text(
                  'Tonight a draft page will be created in Webflow at\n\n'
                  '/coworking/${p['slug']}\n\n'
                  'under ${p['region']}. The slug cannot be changed '
                  'afterwards without a redirect. You then add the '
                  'photos and words in Webflow and publish.',
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
            'website_approved_at':
                DateTime.now().toUtc().toIso8601String()
          },
          '${v['name']} approved. The draft is created tonight.');
    }
  }

  Future<void> _editSlug(Map<String, dynamic> v) async {
    final p = _prepared(v);
    final ctl = TextEditingController(text: p['slug'] ?? '');
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
    await _update(
        v,
        {'website_slug_override': slug, 'website_prepared': next},
        'Slug saved.');
  }

  Future<void> _pickRegion(Map<String, dynamic> v) async {
    if (_regions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The list of Regions arrives with tonight\'s '
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
          // Cleared so the card moves to "preparing tonight".
          'website_prepared': null,
        },
        '${picked['name']} chosen. The proposal is prepared tonight.');
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
            builder: (_) => _EditVenuePage(venue: venue, supabase: _supabase)));
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
          preparing.add(v);
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
        title: const Text('nomadwise.io'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700),
          tabs: [
            Tab(child: _tabLabel('Inbox', inbox == null ? null : _inboxCount)),
            Tab(
                child: _tabLabel(
                    'Drafts', _drafts.length + _approvedTonight.length)),
            Tab(child: _tabLabel('Released', _released.length)),
            Tab(child: _tabLabel('Sitemap', _sitemap.length)),
          ],
        ),
      ),
      body: inbox == null && _error == null
          ? const Center(child: CircularProgressIndicator(color: Brand.red))
          : _error != null
              ? _errorView()
              : TabBarView(controller: _tabs, children: [
                  _wrap(_inboxTab()),
                  _wrap(_draftsTab()),
                  _wrap(_releasedTab()),
                  _wrap(_SitemapTab(
                      pending: _sitemap,
                      onMarked: (ids) async {
                        await _supabase.markSitemapAdded(ids);
                        await _load();
                      },
                      copy: _copy)),
                ]),
    );
  }

  Widget _tabLabel(String text, int? count) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text(text),
        if (count != null && count > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
                color: text == 'Inbox' ? Brand.accent : Brand.field,
                borderRadius: BorderRadius.circular(10)),
            child: Text('$count',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: text == 'Inbox' ? Colors.white : Brand.inkSecondary)),
          ),
        ],
      ]);

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

  Widget _inboxTab() {
    final g = _groups();
    if (_inboxCount == 0) {
      return ListView(padding: const EdgeInsets.all(14), children: [
        const SizedBox(height: 48),
        Center(
          child: Container(
            width: 76,
            height: 76,
            decoration: const BoxDecoration(
                color: Brand.successTint, shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_outline,
                size: 36, color: Brand.success),
          ),
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
        if (g.preparing.isNotEmpty) ...[
          const SizedBox(height: 28),
          _preparingSection(g.preparing),
        ],
        _hiddenSection(),
      ]);
    }
    return ListView(padding: const EdgeInsets.all(14), children: [
      if (g.ready.isNotEmpty) ...[
        _section('READY TO APPROVE', g.ready.length,
            'Check the proposal, then Approve. Tonight it becomes a '
            'draft in Webflow.'),
        ...g.ready.map(_readyCard),
      ],
      if (g.needsRegion.isNotEmpty) ...[
        _section('NEEDS A REGION', g.needsRegion.length,
            'The sync could not tell which nomadwise.io Region this '
            'space belongs to.'),
        ...g.needsRegion.map(_needsRegionCard),
      ],
      if (g.fresh.isNotEmpty) ...[
        _section('NEW SPACES, NOT ON THE SITE', g.fresh.length,
            'Verified in the app. Queue the ones worth a page.'),
        ...g.fresh.map(_freshCard),
      ],
      if (g.preparing.isNotEmpty) _preparingSection(g.preparing),
      _hiddenSection(),
      const SizedBox(height: 30),
    ]);
  }

  /// Spaces marked "Not for the site", folded away so the inbox stays
  /// short but nothing is ever lost: any of them can be brought back.
  Widget _hiddenSection() {
    if (_hidden.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 2),
          title: Text('Not for the site  ·  ${_hidden.length}',
              style: const TextStyle(
                  color: Brand.inkSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  letterSpacing: 1.2)),
          subtitle: const Text('Hidden from the inbox, each with its reason. Tap to see them.',
              style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
          children: _hidden
              .map((v) => ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
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
                        onPressed: () => _restore(v),
                        child: const Text('Bring back')),
                    onTap: () => _openVenue(v),
                  ))
              .toList(),
        ),
      ),
    );
  }

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

  Widget _preparingSection(List<Map<String, dynamic>> rows) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _section('PREPARING TONIGHT', rows.length,
              'Queued. The nightly sync writes the proposal; nothing to '
              'do until then.'),
          ...rows.map((v) => Card(
                margin: const EdgeInsets.only(bottom: 10),
                elevation: 0,
                color: Brand.field,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.nightlight_outlined,
                      color: Brand.inkMuted),
                  title: Text(v['name'] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(_where(v),
                      style: const TextStyle(fontSize: 12)),
                  trailing: TextButton(
                      onPressed: () => _unqueue(v),
                      child: const Text('Remove')),
                ),
              )),
        ],
      );

  static String _where(Map<String, dynamic> v) => [
        v['neighbourhood'],
        v['city']
      ].where((x) => x != null && '$x'.isNotEmpty).join(', ');

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
                        '${_where(v).isNotEmpty ? ' · ${_where(v)}' : ''}'
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
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(v, badge: 'NEW', badgeColor: Brand.violet),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (rating != null)
            StatusChip('★ $rating${reviews != null ? ' ($reviews)' : ''}',
                dotColor: Brand.gold),
          if (wifi != null)
            StatusChip('${(wifi as num).round()} Mbps', dotColor: Brand.success),
          StatusChip(hasPlace ? 'Google matched' : 'No Google match',
              dotColor: hasPlace ? Brand.success : Brand.red),
        ]),
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
              onPressed: () => _dismiss(v),
              style: TextButton.styleFrom(foregroundColor: Brand.inkSecondary),
              child: const Text('Not for the site')),
          ElevatedButton.icon(
              onPressed: hasPlace ? () => _queue(v) : null,
              icon: const Icon(Icons.add_to_queue_outlined, size: 18),
              label: Text(hasPlace
                  ? 'Queue for the site'
                  : 'Needs a Google match first')),
        ]),
      ]),
    );
  }

  Widget _needsRegionCard(Map<String, dynamic> v) {
    final p = _prepared(v);
    final names = (p['google_names'] as List?)?.cast<String>() ?? const [];
    final error = p['error'];
    return _card(
      tint: Brand.goldTint,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(v, badge: 'REGION', badgeColor: Brand.goldTextDark),
        const SizedBox(height: 8),
        Text(p['why'] ?? 'Needs a Region.',
            style: const TextStyle(fontSize: 13, height: 1.4)),
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
          if (error == 'no_place_id')
            const Text('Add a Google match in the space first',
                style: TextStyle(fontSize: 12, color: Brand.inkMuted))
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
    final photos = (p['photos'] as num?)?.toInt() ?? 0;
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
        _kv(Icons.title, p['h1'] ?? ''),
        if (hours.isNotEmpty)
          _kv(Icons.schedule_outlined, _hoursSummary(hours))
        else
          _kv(Icons.schedule_outlined, 'No opening hours known',
              muted: true),
        _kv(
            Icons.photo_library_outlined,
            photos == 0
                ? 'No approved community photos yet: add pictures in Webflow'
                : '$photos approved community photo${photos == 1 ? '' : 's'} go in',
            muted: photos == 0),
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
                'above refreshes tonight.',
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
              child: const Text('Send back')),
          ElevatedButton.icon(
              onPressed: () => _approve(v),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Approve')),
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
        _section('APPROVED, CREATED TONIGHT', approved.length,
            'The nightly sync builds the Webflow draft and its Images '
            'entry.'),
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
  const _EditVenuePage({required this.venue, required this.supabase});
  @override
  State<_EditVenuePage> createState() => _EditVenuePageState();
}

class _EditVenuePageState extends State<_EditVenuePage> {
  late final _name = TextEditingController(text: widget.venue.name);
  late final _hood =
      TextEditingController(text: widget.venue.neighbourhood ?? '');
  late final _city = TextEditingController(text: widget.venue.city ?? '');
  late final _website = TextEditingController(text: widget.venue.website ?? '');
  late final _instagram =
      TextEditingController(text: widget.venue.instagram ?? '');
  late final _wifi = TextEditingController(
      text: widget.venue.wifiSpeedMbps?.toString() ?? '');
  late String _type = widget.venue.type;
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
    for (final c in [_name, _hood, _city, _website, _instagram, _wifi]) {
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
          {String? hint, TextInputType? keyboard}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
            controller: c,
            keyboardType: keyboard,
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
            _field(_hood, 'Neighbourhood', hint: 'Used to find the Location'),
            _field(_city, 'City', hint: 'Used to find the Region'),
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

// ------------------------------------------------------------ region picker

class _RegionPicker extends StatefulWidget {
  final List<Map<String, dynamic>> regions;
  final String? forName;
  const _RegionPicker({required this.regions, this.forName});
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
            Text('Which Region is ${widget.forName ?? 'this space'} in?',
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 4),
            const Text(
                'Regions are the city pages on nomadwise.io. If the city '
                'has no Region yet, create it in Webflow first.',
                style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
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
            'Released pages missing from the custom sitemap. Untick any '
            'you want to leave out, generate, copy, paste into the sitemap '
            'in Webflow, then mark them as added.',
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

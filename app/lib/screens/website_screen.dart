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
import '../widgets/candidates_tab.dart';
import '../widgets/control_extras.dart';
import '../widgets/pass_on.dart';
import '../widgets/pricing_picker.dart';
import '../widgets/reply_suggestions.dart';
import '../widgets/phone_field.dart';
import '../widgets/resubmit_changes.dart';
import '../widgets/ui.dart';
import 'admin_analytics_screen.dart';
import 'admin_chats_screen.dart';
import 'admin_prices_screen.dart';
import 'admin_pricing_screen.dart';
import 'admin_outreach_screen.dart';
import 'admin_upgrades_screen.dart';
import 'admin_screen.dart';
import 'admin_users_screen.dart';
import 'claim_journeys_screen.dart';
import 'email_log_screen.dart';
import 'feedback_inbox_screen.dart';
import 'listing_updates_screen.dart';
import 'nearby_spaces_screen.dart';
import 'owner_insights_screen.dart';
import 'owner_screen.dart';
import 'space_trail_screen.dart';
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
  /// Opened from the team's own link (nomadmaps.io/admin) rather than
  /// from the map's menu: then the title bar also carries the other
  /// team tools and the way to the map.
  final bool standalone;

  /// A team tool to open on top as soon as the control centre is up
  /// ("upgrades", "prices", "analytics"...), for the links that go
  /// straight to one (nomadmaps.io/?admin=upgrades).
  final String? openTool;
  const WebsiteScreen({super.key, this.standalone = false, this.openTool});
  @override
  State<WebsiteScreen> createState() => _WebsiteScreenState();
}

class _WebsiteScreenState extends State<WebsiteScreen> {
  final _supabase = SupabaseService();
  final _places = PlacesService();

  // The tab row on a laptop: arrows appear when chips are cut off.
  final _tabScroll = ScrollController();
  bool _tabCanScrollLeft = false;
  bool _tabCanScrollRight = false;

  void _tabScrolled() {
    if (!_tabScroll.hasClients) return;
    final pos = _tabScroll.position;
    final left = pos.pixels > 4;
    final right = pos.pixels < pos.maxScrollExtent - 4;
    if (left != _tabCanScrollLeft || right != _tabCanScrollRight) {
      setState(() {
        _tabCanScrollLeft = left;
        _tabCanScrollRight = right;
      });
    }
  }

  void _tabNudge(bool left) {
    if (!_tabScroll.hasClients) return;
    final pos = _tabScroll.position;
    final target = (pos.pixels + (left ? -260 : 260))
        .clamp(0.0, pos.maxScrollExtent);
    _tabScroll.animateTo(target,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  Widget _tabArrow({required bool left}) => Positioned(
        left: left ? 0 : null,
        right: left ? null : 0,
        top: 0,
        bottom: 0,
        child: Container(
          width: 44,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: left ? Alignment.centerRight : Alignment.centerLeft,
              end: left ? Alignment.centerLeft : Alignment.centerRight,
              colors: [Brand.bg.withValues(alpha: 0), Brand.bg],
            ),
          ),
          alignment: left ? Alignment.centerLeft : Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Material(
              color: Brand.surface,
              shape: const CircleBorder(side: BorderSide(color: Brand.border)),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _tabNudge(left),
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: Icon(
                      left ? Icons.chevron_left : Icons.chevron_right,
                      size: 20,
                      color: Brand.ink),
                ),
              ),
            ),
          ),
        ),
      );

  List<Map<String, dynamic>>? _inbox;
  List<Map<String, dynamic>> _drafts = [];
  List<Map<String, dynamic>> _released = [];
  List<Map<String, dynamic>> _sitemap = [];
  List<Map<String, dynamic>> _sitemapRegions = [];
  List<Map<String, dynamic>> _sitemapLocations = [];
  List<Map<String, dynamic>> _sitemapCountries = [];
  List<Map<String, dynamic>> _regions = [];
  List<Map<String, dynamic>> _hidden = [];
  List<Map<String, dynamic>> _closed = [];
  List<Map<String, dynamic>> _paid = [];

  /// When each space's current owner was approved (latest claim), so
  /// the Owners tab lists the newest first.
  Map<String, DateTime?> _ownerSince = {};
  // Who claimed each space and their phone (venue id -> name, phone),
  // for the WhatsApp buttons on owner cards.
  Map<String, (String, String)> _ownerContact = {};

  /// Newest first: by approval of the owner's claim, else the date paid,
  /// else when the space was added.
  List<Map<String, dynamic>> _newestFirst(List<Map<String, dynamic>> rows) {
    DateTime when(Map<String, dynamic> v) =>
        _ownerSince['${v['id']}'] ??
        DateTime.tryParse('${v['listing_paid_at']}') ??
        DateTime.tryParse('${v['created_at']}') ??
        DateTime(2000);
    return [...rows]..sort((a, b) => when(b).compareTo(when(a)));
  }
  List<Map<String, dynamic>> _enquiries = [];
  List<Map<String, dynamic>> _orders = [];
  // Enquiries waiting to be passed on to a space (migration 113).
  List<Map<String, dynamic>> _passOn = [];
  int _passed30 = 0;
  int _direct30 = 0;
  Map<String, dynamic>? _importNote;
  List<Map<String, dynamic>> _held = [];
  List<Map<String, dynamic>> _started = [];
  List<Map<String, dynamic>> _freeOwned = [];
  List<Map<String, dynamic>> _ownerDrafts = [];
  List<Map<String, dynamic>> _updates = [];
  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _countries = [];
  String? _error;

  /// How many candidates wait (migration 129): places the nightly job
  /// found that look worth a page and are not spaces yet. Read once
  /// for the number on the tab; the tab keeps it right while open.
  int _candidateCount = 0;

  Future<void> _loadCandidateCount() async {
    try {
      final r = await _supabase.adminCandidates(limit: 1);
      if (!mounted) return;
      setState(() => _candidateCount = (r['total'] as num?)?.toInt() ?? 0);
    } catch (_) {
      // Not readable (yet): the tab itself says why when opened.
    }
  }

  @override
  void initState() {
    super.initState();
    _tabScroll.addListener(_tabScrolled);
    // Once laid out, decide whether the right arrow is needed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tabScrolled());
    _load();
    _loadCandidateCount();
    _loadNextUp();
    if (widget.openTool != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showTool(widget.openTool);
      });
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchCtl.dispose();
    _cleanCtl.dispose();
    _tabScroll.dispose();
    _menuBell.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final firstLoad = _inbox == null;
    try {
      final passOnF = _supabase.enquiriesToPassOn();
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
        _supabase.websitePaid(),
        _supabase.enquiries(),
        _supabase.unmatchedStripeOrders(),
        _supabase.sitemapPendingRegions(),
        _supabase.sitemapPendingLocations(),
        _supabase.sitemapPendingCountries(),
        _supabase.heldClaims(),
        _supabase.openClaims(),
        _supabase.ownerDraftsToReview(),
        _supabase.websiteFreeOwned(),
        _supabase.approvedClaimDates(),
        _supabase.listingUpdates(),
      ]);
      final passOn = await passOnF;
      if (!mounted) return;
      setState(() {
        _passOn = [
          for (final r in (passOn['waiting'] as List? ?? const []))
            if (r is Map) Map<String, dynamic>.from(r),
        ];
        _passed30 = (passOn['passed_30d'] as num?)?.toInt() ?? 0;
        _direct30 = (passOn['direct_30d'] as num?)?.toInt() ?? 0;
        _importNote = passOn['import'] is Map
            ? Map<String, dynamic>.from(passOn['import'])
            : null;
        _inbox = results[0];
        _drafts = results[1];
        _released = results[2];
        _sitemap = results[3];
        _regions = results[4];
        _hidden = results[5];
        _locations = results[6];
        _countries = results[7];
        _closed = results[8];
        _paid = results[9];
        _enquiries = results[10];
        _orders = results[11];
        _sitemapRegions = results[12];
        _sitemapLocations = results[13];
        _sitemapCountries = results[14];
        _held = results[15];
        // Claims that stopped before paying, last 30 days: the owner
        // filled in the form, so a founder can still follow up.
        _started = (results[16] as List<Map<String, dynamic>>)
            .where((c) =>
                c['status'] == 'started' &&
                DateTime.tryParse('${c['created_at']}')
                        ?.isAfter(DateTime.now()
                            .subtract(const Duration(days: 30))) ==
                    true)
            .toList();
        _ownerDrafts = results[17];
        _updates = results[20];
        _freeOwned = results[18];
        _ownerSince = {
          for (final r in results[19].reversed)
            '${r['venue_id']}': DateTime.tryParse('${r['approved_at']}'),
        };
        // Newest claim with a phone wins; an approved one over any other.
        final contact = <String, (String, String)>{};
        void note(Map r) {
          final phone = (r['owner_phone'] ?? '').toString().trim();
          if (r['venue_id'] == null || phone.isEmpty) return;
          contact['${r['venue_id']}'] =
              ((r['owner_name'] ?? '').toString().trim(), phone);
        }
        for (final r in (results[16] as List).reversed) {
          if (r['status'] != 'rejected' && r['status'] != 'abandoned') note(r);
        }
        for (final r in results[19].reversed) {
          note(r);
        }
        _ownerContact = contact;
        _error = null;
        // Something was decided in a job opened from "Next up": the
        // next of the turn-taking jobs is up, and the card opens out.
        if (_openedTurn != null) {
          _turn = _turns.indexOf(_openedTurn!) + 1;
          _openedTurn = null;
        }
        _nextUpFolded = false;
      });
      _ringMenu();
      // The first reading was started with the page (initState).
      if (!firstLoad) _loadNextUp();
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

  Future<void> _newCountry() async {
    final made = await Navigator.push<String>(
        context,
        MaterialPageRoute(
            builder: (_) => _NewRegionPage(
                supabase: _supabase,
                countries: _countries,
                regions: _regions,
                country: true)));
    if (made != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$made is being created on nomadwise.io; it appears '
              'in the Country picker within a minute or two.')));
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
    // A hostel, hotel or coliving: off the list, and found again
    // under this reason when the accommodation pages are built
    // (Jonathan, 5 Oct 2026).
    'A place to stay: keep for accommodation',
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
                            onChanged: (_) => setLocal(() {}),
                            decoration: InputDecoration(
                                // "Other" says nothing by itself
                                labelText: reason == 'Other'
                                    ? 'The reason'
                                    : 'Note (optional)',
                                hintText: reason == 'Other'
                                    ? 'In a few words, for later'
                                    : 'Anything worth remembering')),
                      ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  ElevatedButton(
                      onPressed: reason == null ||
                              (reason == 'Other' && note.text.trim().isEmpty)
                          ? null
                          : () => Navigator.pop(ctx, true),
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
    await _applyLocation(v, picked);
  }

  /// The founder's Location for a space ({id, name}; id 'none' for
  /// the Region page only): kept as their choice, and shown at once.
  Future<void> _applyLocation(
      Map<String, dynamic> v, Map<String, dynamic> picked) async {
    final p = _prepared(v);
    final none = picked['id'] == 'none';
    final next = Map<String, dynamic>.from(p)
      ..['location'] = none ? null : picked['name']
      ..['location_id'] = none ? null : picked['id']
      ..['location_chosen'] = true
      ..remove('location_note');
    await _update(
        v,
        {
          'website_location_override': picked['id'],
          if (p.isNotEmpty) 'website_prepared': next,
        },
        none ? 'No Location: Region page only.' : '${picked['name']} chosen.');
  }

  /// The listed places around a space on a map, coloured by Location,
  /// with the verdict on which one it belongs to (migration 155). A
  /// Location chosen there is kept like one chosen from the list.
  Future<void> _openNearby(Map<String, dynamic> v) async {
    final choice = await Navigator.of(context).push<NearbyChoice>(
        MaterialPageRoute(
            builder: (_) => NearbySpacesScreen(
                venueId: '${v['id']}',
                venueName: '${v['name'] ?? ''}',
                regionId: _regionFor(v)?['id'] as String?,
                areaNames: _googleAreas(v))));
    if (choice == null || !mounted) return;
    if (choice.id == 'other') {
      await _pickLocation(v);
      return;
    }
    await _applyLocation(v, {'id': choice.id, 'name': choice.name});
  }

  /// Under the Location line of a space in review: which Location is
  /// suggested and why, or why it was given the one it has, and the
  /// way to the map (migration 155).
  List<Widget> _locationHint(Map<String, dynamic> v, Map<String, dynamic> p) {
    final note = p['location_note'];
    final verdict = note is Map ? '${note['verdict'] ?? ''}' : '';
    final why = note is Map ? '${note['why'] ?? ''}'.trim() : '';
    final name = note is Map ? '${note['location'] ?? ''}'.trim() : '';
    final id = note is Map ? '${note['location_id'] ?? ''}'.trim() : '';
    final chosen = p['location_chosen'] == true;
    final suggested = !chosen &&
        p['location'] == null &&
        verdict == 'suggest' &&
        id.isNotEmpty &&
        name.isNotEmpty;
    final mapButton = TextButton.icon(
        onPressed: () => _openNearby(v),
        icon: const Icon(Icons.map_outlined, size: 16),
        label: const Text('Nearby spaces on a map'));
    if (!suggested) {
      return [
        if (!chosen && why.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 2),
            child: Text(why,
                style: const TextStyle(
                    fontSize: 12, height: 1.4, color: Brand.inkMuted)),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 14, bottom: 4),
          child: Align(alignment: Alignment.centerLeft, child: mapButton),
        ),
      ];
    }
    return [
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 2, bottom: 6),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 2),
        decoration: BoxDecoration(
            color: Brand.goldTint, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Suggested Location: $name',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Brand.goldTextDark)),
          if (why.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(why,
                  style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: Brand.goldTextDark)),
            ),
          Wrap(spacing: 2, children: [
            TextButton(
                onPressed: () => _applyLocation(v, {'id': id, 'name': name}),
                child: Text('Use $name')),
            mapButton,
          ]),
        ]),
      ),
    ];
  }

  Future<void> _copy(String text, String toast) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(toast), duration: const Duration(seconds: 2)));
  }

  /// The log line under a directory page in the Sitemap tab: where it
  /// is, when it was set up, and whether Nomad Maps made it or it was
  /// made by hand in Webflow.
  String _logLine(Map<String, dynamic> row, String where) {
    final bits = <String>[];
    if (where.trim().isNotEmpty) bits.add(where.trim());
    final seen = DateTime.tryParse('${row['first_seen_at'] ?? ''}');
    if (seen != null) {
      final d = seen.toLocal();
      final fmt = DateFormat(
          d.year == DateTime.now().year ? 'd MMM' : 'd MMM yyyy');
      bits.add('set up ${fmt.format(d)}');
    }
    bits.add(row['source'] == 'app'
        ? 'from Nomad Maps'
        : 'made in Webflow');
    return bits.join('  ·  ');
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
    // A laptop has the room for a menu down the left, as in most
    // members' areas (Jonathan, 6 Oct 2026): the tools that sat behind
    // the two buttons at the top right are always in sight, the ones
    // seldom used at the bottom. A phone keeps the two buttons.
    final wide = MediaQuery.sizeOf(context).width >= _menuFrom;
    // Keyed, so that widening or narrowing the window moves the
    // control centre beside the menu (or back) as it is, without
    // starting it afresh.
    final centre = KeyedSubtree(key: _centreKey, child: _centre(wide));
    return wide ? _besideMenu(null, centre) : centre;
  }

  final _centreKey = GlobalKey();

  /// The menu down the left is shown from this width.
  static const double _menuFrom = 1000;

  /// A screen with the menu down its left; [current] is the tool shown
  /// (null: the control centre), so the menu can mark where you are.
  Widget _besideMenu(String? current, Widget screen) => Material(
        color: Brand.surface,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _sideMenu(current),
          Expanded(child: screen),
        ]),
      );

  /// The tools of the team menu, by their key.
  Widget _toolScreen(String k) => switch (k) {
        'analytics' => const AdminAnalyticsScreen(),
        'users' => const AdminUsersScreen(),
        'pricing' => const AdminPricingScreen(),
        'outreach' => const AdminOutreachScreen(),
        'chats' => const AdminChatsScreen(),
        'upgrades' => const AdminUpgradesScreen(),
        'prices' => const AdminPricesScreen(),
        'review' => const AdminScreen(),
        _ => const FeedbackInboxScreen(),
      };

  /// From the menu down the left: the control centre (null) or a
  /// tool. Whatever tool was open is closed first, so the menu always
  /// swaps one screen for another and Back leads to the control
  /// centre. The tool keeps the menu beside it; the pages a tool
  /// opens itself (one page's review, one space's prices) take the
  /// whole screen as before.
  void _showTool(String? k) {
    // The control centre has gone (signed out in another tab, say)
    // while a tool's menu was still on screen.
    if (!mounted) return;
    final nav = Navigator.of(context);
    final home = ModalRoute.of(context);
    if (home != null) nav.popUntil((r) => r == home || r.isFirst);
    if (k == null) {
      _loadNextUp();
      return;
    }
    // Keyed, so the tool is not started afresh when the window is
    // widened or narrowed past the width where the menu appears.
    final toolKey = GlobalKey();
    nav
        .push(PageRouteBuilder<void>(
          // no slide: the screen beside the menu just changes
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (ctx, _, __) {
            final tool = KeyedSubtree(key: toolKey, child: _toolScreen(k));
            return MediaQuery.sizeOf(ctx).width >= _menuFrom
                ? _besideMenu(k, tool)
                : tool;
          },
        ))
        // back at the control centre: a Go given in a tool changes
        // what is next
        .then((_) {
      if (mounted) _loadNextUp();
    });
  }

  /// Rung whenever a number beside the menu may have changed. The
  /// menu beside an open tool is drawn by the tool's own screen, which
  /// does not redraw when the control centre does: it listens here.
  final ValueNotifier<int> _menuBell = ValueNotifier<int>(0);

  /// Messages from owners nobody has opened (migration 161): the
  /// number beside Chats. Read whenever "Next up" is.
  int _chatsUnread = 0;
  void _ringMenu() => _menuBell.value++;

  /// When the tools' numbers were last read because the pointer came
  /// to the menu (at most every fifteen seconds).
  DateTime? _menuReadAt;
  void _menuPointed() {
    if (!mounted) return;
    final now = DateTime.now();
    final last = _menuReadAt;
    if (last != null && now.difference(last) < const Duration(seconds: 15)) {
      return;
    }
    _menuReadAt = now;
    _loadNextUp();
  }

  /// Everything the To do line counts: what waits in the control
  /// centre itself.
  int get _todoCount {
    final g = _groups();
    return _passOn.length +
        _held.length +
        _orders.length +
        _ownerDrafts.length +
        _updates.length +
        g.ready.length +
        g.needsRegion.length +
        g.fresh.length +
        _drafts.length +
        _approvedTonight.length +
        _sitemapCount +
        _closed.length;
  }

  /// What is open behind a menu item (Jonathan, 6 Oct 2026), and what
  /// the number means in words. Zero: no number is shown.
  (int, String) _menuCount(String key) {
    int part(String k, [String f = 'n']) {
      final p = _nextUp?[k];
      return p is Map ? ((p[f] as num?)?.toInt() ?? 0) : 0;
    }

    return switch (key) {
      'home' => (_todoCount, 'waiting in the control centre (its To do line)'),
      'upgrades' => (
          part('drafts'),
          'drafts waiting for your Go, or needing a look'
        ),
      'prices' => (
          part('prices'),
          'price changes waiting for your Go, or needing a look'
        ),
      'outreach' => (
          part('menu', 'outreach'),
          'spaces that replied, follow-ups that have come due and have '
              'not been sent, spaces that looked at claiming, or accounts '
              'on the map that match a space'
        ),
      'review' => (
          part('menu', 'review'),
          'submissions and photos waiting to be checked'
        ),
      'feedback' => (part('menu', 'feedback'), 'messages not marked done'),
      'chats' => (
          _chatsUnread,
          'messages from owners that nobody has opened yet'
        ),
      _ => (0, ''),
    };
  }

  /// The menu down the left on a wide screen: the control centre and
  /// the tools used every day on top, what makes new pages on
  /// nomadwise.io in the middle, the tools seldom used at the bottom.
  Widget _sideMenu(String? current) => !mounted
      // the control centre has gone (signed out elsewhere) while a
      // tool's menu is still on screen: draw it, listen to nothing
      ? _sideMenuNow(current)
      : MouseRegion(
          onEnter: (_) => _menuPointed(),
          child: ValueListenableBuilder<int>(
              valueListenable: _menuBell,
              builder: (context, _, __) => _sideMenuNow(current)),
        );

  Widget _sideMenuNow(String? current) {
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 4),
          child: Text(text,
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .6,
                  color: Brand.inkMuted)),
        );
    Widget item(IconData icon, String label, VoidCallback onTap,
        {bool on = false, bool quiet = false, String? countOf}) {
      final (count, meaning) =
          countOf == null ? (0, '') : _menuCount(countOf);
      final color = on
          ? Brand.accent
          : quiet
              ? Brand.inkMuted
              : Brand.ink;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Material(
          color: on ? Brand.accentTint : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: 10, vertical: quiet ? 7 : 9),
              child: Row(children: [
                Icon(icon, size: quiet ? 17 : 19, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: quiet ? 13 : 14,
                          fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                          color: color)),
                ),
                // How many are open behind it; nothing when none are.
                // Green, not the red of the item you are on: a number
                // is work waiting, not something wrong (Jonathan,
                // 7 Oct 2026: "these should be green", "the numbers").
                if (count > 0)
                  Tooltip(
                    message: '$count $meaning',
                    child: Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 1.5),
                      decoration: BoxDecoration(
                          color: on
                              ? Brand.success
                              : quiet
                                  ? Brand.field
                                  : Brand.successTint,
                          borderRadius: BorderRadius.circular(10)),
                      child: Text(count > 999 ? '999+' : '$count',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: on
                                  ? Colors.white
                                  : quiet
                                      ? Brand.inkSecondary
                                      : Brand.success)),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      );
    }

    Widget tool(String key, IconData icon, String label,
            {bool quiet = false}) =>
        item(icon, label, () {
          if (current != key) _showTool(key);
        }, on: current == key, quiet: quiet, countOf: key);

    final top = <Widget>[
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 18, 12, 10),
        child: Text('Nomadwise',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      item(Icons.dashboard_outlined, 'Control centre', () => _showTool(null),
          on: current == null, countOf: 'home'),
      tool('upgrades', Icons.auto_fix_high_outlined, 'Page upgrades'),
      tool('prices', Icons.sell_outlined, 'Price check'),
      tool('outreach', Icons.mail_outline, 'Outreach'),
      tool('chats', Icons.forum_outlined, 'Chats'),
      heading('CREATE ON NOMADWISE.IO'),
      item(Icons.public, 'Country page', () {
        if (mounted) _newCountry();
      }),
      item(Icons.location_city_outlined, 'City page', () {
        if (mounted) _newRegion();
      }),
      item(Icons.place_outlined, 'Area page', () {
        if (mounted) _newLocation();
      }),
      item(Icons.refresh, 'Refresh from Webflow', () {
        if (mounted) _refreshFromWebflow();
      }),
    ];
    // Seldom used (Jonathan, 6 Oct 2026): at the bottom, smaller.
    final bottom = <Widget>[
      heading('LESS USED'),
      tool('analytics', Icons.insights_outlined, 'Analytics', quiet: true),
      tool('users', Icons.people_outline, 'Users', quiet: true),
      tool('pricing', Icons.payments_outlined, 'Pricing', quiet: true),
      tool('review', Icons.rate_review_outlined, 'Review submissions',
          quiet: true),
      tool('feedback', Icons.feedback_outlined, 'Feedback inbox',
          quiet: true),
      if (widget.standalone)
        item(Icons.map_outlined, 'Open the map', () => _openTool('map'),
            quiet: true),
      const SizedBox(height: 10),
    ];
    return Container(
      width: 232,
      decoration: const BoxDecoration(
          color: Brand.surface,
          border: Border(right: BorderSide(color: Brand.border))),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => box.maxHeight < 640
              // A short window: one list, so nothing is cut off.
              ? ListView(children: [...top, ...bottom])
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                      Expanded(child: ListView(children: top)),
                      const Divider(height: 1, color: Brand.border),
                      ...bottom,
                    ]),
        ),
      ),
    );
  }

  /// The control centre itself. [wide]: the menu down the left carries
  /// the tools, so the two menu buttons at the top right are left out.
  Widget _centre(bool wide) {
    final inbox = _inbox;
    return Scaffold(
      appBar: AppBar(
        // What is waiting now shows in the To do line below, so the
        // title stays short enough for a phone beside the buttons.
        title: const Text('Control centre'),
        actions: [
          IconButton(
              tooltip: 'Search spaces, owners and claims',
              onPressed: _openSearch,
              icon: const Icon(Icons.search)),
          const HealthButton(),
          // The team's other screens. Shown however the control centre
          // was opened (the team link, or the map's menu): Pricing,
          // Outreach and Page upgrades have no other door (Jonathan,
          // 5 Oct 2026). From the map, the back arrow leads to the
          // map, so "Open the map" is only offered on the team link.
          // On a wide screen these are in the menu down the left.
          if (!wide)
          PopupMenuButton<String>(
            tooltip: 'Team tools',
            icon: const Icon(Icons.apps),
            onSelected: _openTool,
            // The ones used every day first, the seldom used below
            // the line (Jonathan, 6 Oct 2026).
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              const PopupMenuItem(
                  value: 'upgrades', child: Text('Page upgrades')),
              const PopupMenuItem(
                  value: 'prices', child: Text('Price check')),
              const PopupMenuItem(
                  value: 'outreach', child: Text('Outreach')),
              PopupMenuItem(
                  value: 'chats',
                  child: Text(_chatsUnread > 0
                      ? 'Chats ($_chatsUnread)'
                      : 'Chats')),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  value: 'analytics', child: Text('Analytics')),
              const PopupMenuItem(value: 'users', child: Text('Users')),
              const PopupMenuItem(value: 'pricing', child: Text('Pricing')),
              const PopupMenuItem(
                  value: 'review', child: Text('Review submissions')),
              const PopupMenuItem(
                  value: 'feedback', child: Text('Feedback inbox')),
              if (widget.standalone) ...const <PopupMenuEntry<String>>[
                PopupMenuDivider(),
                PopupMenuItem(value: 'map', child: Text('Open the map')),
              ],
            ],
          ),
          // The site's taxonomy, made from here: a Region (city page) or
          // a Location (neighbourhood page), built and published by the
          // sync within a minute or two, then in every picker.
          if (!wide)
          PopupMenuButton<String>(
            tooltip: 'Create on nomadwise.io',
            icon: const Icon(Icons.add_location_alt_outlined),
            onSelected: (k) => k == 'region'
                ? _newRegion()
                : k == 'location'
                    ? _newLocation()
                    : k == 'country'
                        ? _newCountry()
                        : _refreshFromWebflow(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'country',
                  child: Text('Create a Country (country page)')),
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
              : SelectionArea(child: _wrap()),
    );
  }

  /// Where a space sits in the control centre, for "Show in list".
  String? _groupOfSpace(String id) {
    bool has(List<Map<String, dynamic>> l, [String f = 'id']) =>
        l.any((x) => '${x[f]}' == id);
    final g = _groups();
    if (has(_held, 'venue_id') || has(_paid) || has(_freeOwned)) return 'paid';
    if (has(_ownerDrafts, 'venue_id')) return 'owner';
    if (has(g.ready)) return 'ready';
    if (has(g.needsRegion)) return 'region';
    if (has(g.preparing)) return 'preparing';
    if (has(g.fresh)) return 'fresh';
    if (has(_drafts) || has(_approvedTonight)) return 'drafts';
    if (has(_closed)) return 'closed';
    if (has(_hidden)) return 'hidden';
    if (has(_sitemap)) return 'sitemap';
    if (has(_released)) return 'released';
    return null;
  }

  static const _groupNames = {
    'paid': 'Owners',
    'enquiries': 'Enquiries',
    'owner': 'Owner changes',
    'candidates': 'Candidates',
    'fresh': 'New spaces',
    'preparing': 'Queued',
    'region': 'Blocked',
    'ready': 'Ready to approve',
    'drafts': 'In Webflow',
    'sitemap': 'Sitemap',
    'closed': 'Closed',
    'hidden': 'Not for the site',
    'released': 'Released',
  };

  static String _pageWords(String? status) => switch (status) {
        'released' => 'Page live',
        'published_hidden' => 'Page not in the sitemap yet',
        'queued' => 'Queued for a page',
        'removed' => 'Removed from the site',
        _ => 'No page yet',
      };

  /// Search across everything: spaces by name, city, page address or
  /// owner email, and claims by space, owner name or email.
  void _openSearch() {
    final ctl = TextEditingController();
    Timer? debounce;
    var busy = false;
    var spaces = <Map<String, dynamic>>[];
    var claims = <Map<String, dynamic>>[];
    var searched = '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        Future<void> run(String q) async {
          if (q.trim().length < 2) {
            setSheet(() {
              spaces = [];
              claims = [];
              searched = '';
            });
            return;
          }
          setSheet(() => busy = true);
          final r = await _supabase.controlSearch(q);
          if (!ctx.mounted) return;
          setSheet(() {
            spaces = r.spaces;
            claims = r.claims;
            searched = q.trim();
            busy = false;
          });
        }

        void go(VoidCallback f) {
          Navigator.pop(ctx);
          f();
        }

        Widget spaceTile(Map<String, dynamic> v) {
          final id = '${v['id']}';
          final where = _groupOfSpace(id);
          final owner = (v['listing_owner_email'] ?? '').toString();
          final tier = (v['listing_tier'] ?? 'free').toString();
          final live = v['website_status'] == 'released' &&
              (v['webflow_slug'] ?? '').toString().isNotEmpty;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${v['name']}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14.5)),
                  Text(
                      [
                        [v['neighbourhood'], v['city']]
                            .where((x) => x != null && '$x'.isNotEmpty)
                            .join(', '),
                        _pageWords(v['website_status']?.toString()),
                        if (tier != 'free') 'Verified',
                        if (owner.isNotEmpty) owner,
                        if (where != null) 'in ${_groupNames[where]}',
                      ].where((x) => x.isNotEmpty).join(' · '),
                      style: const TextStyle(
                          fontSize: 12, color: Brand.inkSecondary)),
                  const SizedBox(height: 4),
                  Wrap(spacing: 4, runSpacing: 0, children: [
                    if (where != null)
                      TextButton(
                          onPressed: () => go(() => _goToGroup(where)),
                          child: const Text('Show in list')),
                    TextButton(
                        onPressed: () => go(() => _openVenue(v)),
                        child: const Text('Open the space')),
                    if (live)
                      TextButton(
                          onPressed: () => launchUrl(
                              Uri.parse('https://www.nomadwise.io/coworking/'
                                  '${v['webflow_slug']}'),
                              mode: LaunchMode.externalApplication),
                          child: const Text('Open page')),
                    if (owner.isNotEmpty)
                      TextButton(
                          onPressed: () => go(() => _openOwnerPreview(id)),
                          child: const Text('Their Owner account')),
                    TextButton(
                        onPressed: () => go(() => _editPlan(v)),
                        child: const Text('Listing plan')),
                    TextButton(
                        onPressed: () =>
                            go(() => _openTrail(id, '${v['name']}')),
                        child: const Text('History')),
                  ]),
                  const Divider(height: 8, color: Brand.hairline),
                ]),
          );
        }

        Widget claimTile(Map<String, dynamic> c) {
          final vid = (c['venue_id'] ?? '').toString();
          final t = DateTime.tryParse('${c['created_at']}');
          final status = switch ('${c['status']}') {
            'started' => 'started, not finished',
            'awaiting_approval' => 'paid, waiting for a decision',
            'free_pending' => 'free, waiting for a decision',
            'paid' => 'Verified, approved',
            'free' => 'free, approved',
            'rejected' => 'turned down',
            'abandoned' => 'abandoned',
            final x => x,
          };
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${c['space_name'] ?? 'A space'}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14.5)),
                  Text(
                      [
                        'Claim by ${c['owner_name'] ?? '?'} '
                            '(${c['owner_email'] ?? ''})',
                        status,
                        if (t != null)
                          DateFormat('d MMM yyyy').format(t.toLocal()),
                      ].join(' · '),
                      style: const TextStyle(
                          fontSize: 12, color: Brand.inkSecondary)),
                  Wrap(spacing: 4, children: [
                    TextButton(
                        onPressed: () => go(() => _goToGroup('paid')),
                        child: const Text('Show in Owners')),
                    if (vid.isNotEmpty) ...[
                      TextButton(
                          onPressed: () => go(() => _openOwnerPreview(vid)),
                          child: const Text('Their Owner account')),
                      TextButton(
                          onPressed: () => go(() => _openTrail(
                              vid, '${c['space_name'] ?? 'this space'}')),
                          child: const Text('History')),
                    ],
                  ]),
                  const Divider(height: 8, color: Brand.hairline),
                ]),
          );
        }

        return Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * .85,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  controller: ctl,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Space, city, page address or owner email',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: busy
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Brand.accent)))
                        : null,
                  ),
                  onChanged: (q) {
                    debounce?.cancel();
                    debounce = Timer(
                        const Duration(milliseconds: 350), () => run(q));
                  },
                  onSubmitted: run,
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    if (searched.isNotEmpty &&
                        spaces.isEmpty &&
                        claims.isEmpty &&
                        !busy)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text('Nothing matches "$searched".',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Brand.inkMuted)),
                      ),
                    if (spaces.isNotEmpty) ...[
                      Text('SPACES (${spaces.length})',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: .6,
                              color: Brand.inkMuted)),
                      ...spaces.map(spaceTile),
                    ],
                    if (claims.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text('CLAIMS (${claims.length})',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: .6,
                              color: Brand.inkMuted)),
                      ...claims.map(claimTile),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        );
      }),
    ).whenComplete(() {
      debounce?.cancel();
    });
  }

  /// From the team link's tools menu: the other team screens.
  void _openTool(String k) {
    if (k == 'map') {
      launchUrl(Uri.parse('/'), webOnlyWindowName: '_self');
      return;
    }
    Navigator.push(
            context, MaterialPageRoute(builder: (_) => _toolScreen(k)))
        // back from a tool: what is waiting may have changed
        .then((_) {
      if (mounted) _loadNextUp();
    });
  }

  /// With this much room beside the menu (the list's 760, a gap and
  /// the card's 300), the "Next up" card stands to the right of the
  /// list and the list starts at the top (Jonathan, 7 Oct 2026,
  /// pointing at the empty space on the right).
  static const double _nextUpBesideFrom = 1066;

  /// Phone: full width. Laptop: a comfortable reading column, and on a
  /// wide screen the "Next up" card beside it. One shape of tree for
  /// both, so widening the window does not start the list afresh.
  Widget _wrap() => RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(builder: (context, c) {
          final beside = c.maxWidth >= _nextUpBesideFrom;
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: beside ? 1066 : 760),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _pipeline(nextUpBeside: beside)),
                    if (beside) ...[
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 300,
                        child: SingleChildScrollView(
                            primary: false,
                            child: _nextUpCard(_groups(), beside: true)),
                      ),
                    ],
                  ]),
            ),
          );
        }),
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

  // Three sections instead of eleven tabs in a row (30 Sep 2026):
  // the people, the pages, and the tidying up.
  static const _sections = [
    ('owners', 'Owners', ['paid', 'enquiries', 'owner']),
    ('pages', 'Pages',
        ['fresh', 'preparing', 'region', 'ready', 'drafts', 'sitemap', 'released',
          'candidates']),
    ('cleanup', 'Clean-up', ['closed', 'hidden']),
  ];

  static String _sectionOf(String groupKey) => _sections
      .firstWhere((s) => s.$3.contains(groupKey),
          orElse: () => _sections[1])
      .$1;

  int get _sitemapCount =>
      _sitemap.length +
      _sitemapRegions.length +
      _sitemapLocations.length +
      _sitemapCountries.length;

  /// What is waiting in each section (not the archive lists).
  int _sectionTodo(String section,
      ({
        List<Map<String, dynamic>> ready,
        List<Map<String, dynamic>> needsRegion,
        List<Map<String, dynamic>> preparing,
        List<Map<String, dynamic>> fresh
      }) g) =>
      switch (section) {
        'owners' => _passOn.length +
            _held.length +
            _orders.length +
            _ownerDrafts.length +
            _updates.length,
        'pages' => g.fresh.length +
            g.preparing.length +
            g.needsRegion.length +
            g.ready.length +
            _drafts.length +
            _approvedTonight.length +
            _sitemapCount,
        _ => _closed.length,
      };

  void _goToGroup(String key) {
    setState(() => _groupKey = key);
    if (_tabScroll.hasClients) _tabScroll.jumpTo(0);
  }

  // ------------------------------------------------------------ next up

  /// What waits outside the control centre's own lists (drafts and
  /// price changes waiting for a Go, the best candidate, the next page
  /// short of photos, the next page to work on): admin_next_up(),
  /// migration 145. Null until read, or when it cannot be.
  Map<String, dynamic>? _nextUp;

  /// Jobs put aside with "Skip for now", until they are shown again
  /// from the card or the control centre is opened afresh.
  final Set<String> _skipped = {};

  /// False until admin_next_up() has answered (or failed): the card
  /// waits for it, so it does not show one job and then swap to
  /// another under the pointer.
  bool _nextUpRead = false;
  int _nextUpReq = 0;

  /// True after a job that lives in this page was opened from the
  /// card: the card folds to one line, out of the way of the list
  /// below, until something is decided.
  bool _nextUpFolded = false;

  /// On a small screen the "Next up" card and the To do line step
  /// aside as soon as the list below is scrolled, and come back at
  /// the top of the list or on "Show" (Jonathan, 6 Oct 2026, on his
  /// phone: the card "prevents me from being able to do anything on
  /// the bottom side").
  bool _topAway = false;

  /// The group the list was showing when it was last scrolled away: a
  /// different group starts at its top, with the card back.
  String? _topAwayKey;

  /// A phone, or a window as narrow as one.
  bool get _smallScreen => MediaQuery.sizeOf(context).width < 700;

  /// True while the list is being moved by a finger (and through the
  /// glide that follows). A mouse wheel never folds the card: it has
  /// no way to pull it back down.
  bool _fingerScroll = false;

  bool _onListScroll(ScrollNotification n) {
    // The list itself, not a row of chips inside it.
    if (n.depth != 0 || n.metrics.axis != Axis.vertical || !_smallScreen) {
      return false;
    }
    if (n is ScrollStartNotification) _fingerScroll = n.dragDetails != null;
    if (!_topAway) {
      // Scrolled down, for real: not the stretch past the end of a
      // list too short to scroll.
      if (n is ScrollUpdateNotification &&
          _fingerScroll &&
          (n.scrollDelta ?? 0) > 0 &&
          n.metrics.pixels > 6 &&
          !n.metrics.outOfRange) {
        setState(() => _topAway = true);
      }
    } else if ((n is OverscrollNotification && n.overscroll < 0) ||
        (n is ScrollUpdateNotification &&
            (n.metrics.pixels < -24 ||
                (n.dragDetails != null &&
                    (n.scrollDelta ?? 0) < 0 &&
                    n.metrics.pixels <= 0)))) {
      // Dragged back to the top of the list, or pulled down past it:
      // the card comes back. (A list that merely settles at its top,
      // because it became short enough to fit, does not ask for it.)
      setState(() => _topAway = false);
    }
    return false;
  }

  /// The jobs that take turns once nobody is waiting on us, in the
  /// order of their turns, and whose turn it is.
  static const _turns = [
    'fresh', 'candidates', 'photos', 'page', 'webflow', 'closed', 'region',
    'sitemap',
  ];
  static int _turn = 0;

  /// The turn-taking job last opened from the card, in this page:
  /// when the page next reloads (something was decided) the turn
  /// moves on.
  String? _openedTurn;

  Future<void> _loadNextUp() async {
    final n = ++_nextUpReq;
    _supabase.adminChatsUnread().then((c) {
      if (!mounted || c == _chatsUnread) return;
      setState(() => _chatsUnread = c);
      _ringMenu();
    });
    final r = await _supabase.adminNextUp();
    // a later reading is on its way: this one is out of date
    if (!mounted || n != _nextUpReq) return;
    setState(() {
      if (r != null) _nextUp = r;
      _nextUpRead = true;
    });
    _ringMenu();
  }

  void _nextUpSay(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 2),
        backgroundColor: bad ? Brand.red : null));
  }

  /// A job of the card that lives in this page: go to its group.
  void _nextUpHere(String kind, String groupKey) {
    if (_turns.contains(kind)) _openedTurn = kind;
    _nextUpFolded = true;
    _goToGroup(groupKey);
  }

  /// A job of the card with a screen of its own: open it, and when
  /// you come back show what is next.
  Future<void> _nextUpOpen(String kind, Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (!mounted) return;
    if (_turns.contains(kind)) {
      setState(() => _turn = _turns.indexOf(kind) + 1);
    }
    await _loadNextUp();
  }

  /// Everything there is to do, the next thing first: people waiting
  /// on us, then what waits for a Go, then the other jobs in turn.
  List<_NextJob> _nextJobs(
      ({
        List<Map<String, dynamic>> ready,
        List<Map<String, dynamic>> needsRegion,
        List<Map<String, dynamic>> preparing,
        List<Map<String, dynamic>> fresh
      }) g) {
    String n(int x, String one, String many) => '$x ${x == 1 ? one : many}';
    Map<String, dynamic> part(String k) {
      final p = _nextUp?[k];
      return p is Map ? Map<String, dynamic>.from(p) : const {};
    }

    int count(Map<String, dynamic> p, [String k = 'n']) =>
        (p[k] as num?)?.toInt() ?? 0;
    String name(Map<String, dynamic> p) {
      final s = '${p['name'] ?? ''}'.trim();
      return s.isEmpty ? 'the next one' : s;
    }

    final drafts = part('drafts');
    final prices = part('prices');
    final candidate = part('candidate');
    final photos = part('photos');
    final page = part('page');
    final look = part('claim_look');
    // Roughly where the visitor was, against the space (migration 154).
    final lookWhere = '${look['where'] ?? ''}'.trim();
    final lookLocal = count(look, 'local');
    final signup = part('signup');
    final webflow = _drafts.length + _approvedTonight.length;

    final first = <_NextJob>[
      // People waiting on us.
      if (_passOn.isNotEmpty)
        _NextJob(
            'enquiries',
            'Pass on an enquiry',
            '${n(_passOn.length, 'nomad has', 'nomads have')} asked a space '
                'something and nobody has passed it on yet.',
            'Open enquiries',
            () => _nextUpHere('enquiries', 'enquiries')),
      if (_held.isNotEmpty)
        _NextJob(
            'claims',
            'Decide a claim',
            '${n(_held.length, 'owner is', 'owners are')} waiting to hear '
                'whether the page is theirs.',
            'Open claims',
            () => _nextUpHere('claims', 'paid')),
      if (_orders.isNotEmpty)
        _NextJob(
            'payments',
            'Match a payment',
            '${n(_orders.length, 'payment has', 'payments have')} come in '
                'and we could not tell which space it is for.',
            'Open payments',
            () => _nextUpHere('payments', 'paid')),
      // A space whose claim page was opened and that did not claim
      // (migration 153): somebody there is interested now.
      if (count(look) > 0)
        _NextJob(
            'claimlook',
            'Follow up: ${name(look)} looked at claiming',
            '${count(look) == 1 ? 'Someone opened the claim page for this space' : 'Someone opened the claim page for ${count(look)} spaces'} '
                'in the last two weeks and did not claim.'
                '${lookWhere.isEmpty ? '' : count(look) == 1 ? ' $lookWhere' : ' ${name(look)}: $lookWhere'}'
                '${count(look) > 1 && lookLocal > 0 ? ' $lookLocal of the ${count(look)} ${lookLocal == 1 ? 'was' : 'were'} seen from the space\'s own area or country.' : ''}'
                ' Ask whether they had a question, by email or WhatsApp.',
            'Open in Outreach',
            () => _nextUpOpen('claimlook',
                const AdminOutreachScreen(initialStep: 'claim_looked'))),
      // An account made on the map that is plainly a listed space's
      // (migration 154).
      if (count(signup) > 0)
        _NextJob(
            'signup',
            'Follow up: ${name(signup)} made an account',
            '${count(signup) == 1 ? 'An account was made on the map that matches this space' : 'Accounts were made on the map that match ${count(signup)} spaces'}, '
                'without claiming. Tell them the page is theirs to claim.',
            'Open in Outreach',
            () => _nextUpOpen('signup',
                const AdminOutreachScreen(initialStep: 'signed_up'))),
      if (_updates.isNotEmpty)
        _NextJob(
            'updates',
            'Look at a suggested update',
            '${n(_updates.length, 'visitor has', 'visitors have')} said '
                'something on a page needs updating.',
            'Open suggested updates',
            () => _nextUpHere('updates', 'owner')),
      if (_ownerDrafts.isNotEmpty)
        _NextJob(
            'ownerchanges',
            'Look at an owner\'s change',
            '${n(_ownerDrafts.length, 'owner has', 'owners have')} sent a '
                'change to their page that waits for you.',
            'Open owner changes',
            () => _nextUpHere('ownerchanges', 'owner')),
      // Waiting for your Go.
      if (g.ready.isNotEmpty)
        _NextJob(
            'ready',
            'Approve a page',
            '${n(g.ready.length, 'new page is', 'new pages are')} prepared '
                'and waiting for your approval.',
            'Open pages to approve',
            () => _nextUpHere('ready', 'ready')),
      if (count(drafts) > 0 && drafts['venue_id'] != null)
        _NextJob(
            'drafts',
            'Give your Go: ${name(drafts)}',
            '${n(count(drafts, 'waiting'), 'draft is', 'drafts are')} waiting '
                'for this page'
                '${count(drafts, 'pages') > 1 ? ' (${count(drafts)} drafts across ${count(drafts, 'pages')} pages in all)' : ''}'
                '. You see what the page says now beside the upgrade.',
            'Review the drafts',
            () => _nextUpOpen(
                'drafts',
                UpgradePageReviewScreen(
                    venueId: '${drafts['venue_id']}', name: name(drafts)))),
      if (count(prices) > 0 && prices['venue_id'] != null)
        _NextJob(
            'prices',
            'Decide price changes: ${name(prices)}',
            '${n(count(prices, 'waiting'), 'price change is', 'price changes are')} '
                'waiting for your Go on this space'
                '${count(prices, 'spaces') > 1 ? ' (${count(prices)} across ${count(prices, 'spaces')} spaces in all)' : ''}'
                '.',
            'Review the changes',
            () => _nextUpOpen(
                'prices',
                PriceSpaceScreen(
                    venueId: '${prices['venue_id']}', name: name(prices)))),
    ];

    // The jobs that take turns, by kind.
    final turn = <String, _NextJob>{
      if (g.fresh.isNotEmpty)
        'fresh': _NextJob(
            'fresh',
            'Decide a new space',
            '${n(g.fresh.length, 'space was', 'spaces were')} added on the '
                'map: for the site, or not?',
            'Open new spaces',
            () => _nextUpHere('fresh', 'fresh')),
      if (count(candidate) > 0 || _candidateCount > 0)
        'candidates': _NextJob(
            'candidates',
            candidate['name'] == null
                ? 'Decide whether to list a place'
                : 'Decide whether to list it: ${name(candidate)}',
            [
              if ('${candidate['area'] ?? ''}'.trim().isNotEmpty)
                '${candidate['area']}'.trim(),
              if (candidate['name'] != null)
                candidate['coworking'] == true ? 'coworking space' : 'cafe',
              if (count(candidate, 'mentions') > 0)
                'named by ${n(count(candidate, 'mentions'), 'other site', 'other sites')}',
              '${n(count(candidate) > 0 ? count(candidate) : _candidateCount, 'place waits', 'places wait')} '
                  'on the list, the best bet on top',
            ].join(' · '),
            'Open the list',
            () => _nextUpHere('candidates', 'candidates')),
      if (count(photos) > 0)
        'photos': _NextJob(
            'photos',
            'Add photos: ${name(photos)}',
            'It shows ${count(photos, 'photos')} of 5 photos. '
                '${n(count(photos), 'live page is', 'live pages are')} short '
                'of photos; it is near the top of the list.',
            'Add photos',
            () => _nextUpOpen('photos', const UpgradePhotoGapsScreen())),
      if (count(page) > 0 && page['venue_id'] != null)
        'page': _NextJob(
            'page',
            'Look at a page: ${name(page)}',
            [
              if ('${page['reason'] ?? ''}'.trim().isNotEmpty)
                '${page['reason']}'.trim(),
              'Change it, request an upgrade, or say there is nothing to '
                  'change.',
            ].join('. '),
            'Open the page',
            () => _nextUpOpen(
                'page',
                UpgradePageReviewScreen(
                    venueId: '${page['venue_id']}', name: name(page))),
            second: 'Nothing to change',
            onSecond: () async {
              try {
                await _supabase.upgradePageDone('${page['venue_id']}',
                    done: true);
                if (!mounted) return;
                setState(() => _turn = _turns.indexOf('page') + 1);
                _nextUpSay('${name(page)}: done for now.');
                await _loadNextUp();
              } catch (e) {
                _nextUpSay('That did not save: $e', bad: true);
              }
            }),
      if (webflow > 0)
        'webflow': _NextJob(
            'webflow',
            'Finish a page in Webflow',
            '${n(webflow, 'approved page is', 'approved pages are')} in '
                'Webflow as a draft, waiting for words and Publish.',
            'Open pages in Webflow',
            () => _nextUpHere('webflow', 'drafts')),
      if (_closed.isNotEmpty)
        'closed': _NextJob(
            'closed',
            'Check a closed place',
            'Google says ${n(_closed.length, 'place has', 'places have')} '
                'closed: retire the page, or say it is still open.',
            'Open closed places',
            () => _nextUpHere('closed', 'closed')),
      if (g.needsRegion.isNotEmpty)
        'region': _NextJob(
            'region',
            'Unblock a page',
            '${n(g.needsRegion.length, 'page cannot', 'pages cannot')} be '
                'prepared until something is fixed (usually the city page).',
            'Open blocked pages',
            () => _nextUpHere('region', 'region')),
      if (_sitemapCount > 0)
        'sitemap': _NextJob(
            'sitemap',
            'Add sitemap entries',
            '${n(_sitemapCount, 'entry is', 'entries are')} waiting to be '
                'added to the sitemap.',
            'Open the sitemap list',
            () => _nextUpHere('sitemap', 'sitemap')),
    };
    final start = _turn % _turns.length;
    return [
      ...first,
      for (var i = 0; i < _turns.length; i++)
        if (turn[_turns[(start + i) % _turns.length]] != null)
          turn[_turns[(start + i) % _turns.length]]!,
    ];
  }

  /// One thing at a time (Jonathan, 5 Oct 2026): the next job, why,
  /// and one button that goes straight to it. "Skip for now" shows
  /// the one after.
  Widget _nextUpCard(
      ({
        List<Map<String, dynamic>> ready,
        List<Map<String, dynamic>> needsRegion,
        List<Map<String, dynamic>> preparing,
        List<Map<String, dynamic>> fresh
      }) g,
      {bool beside = false}) {
    // Typing (a search, a note): the list below needs the room.
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }
    final all = _nextJobs(g);
    final jobs = all.where((j) => !_skipped.contains(j.kind)).toList();
    final hidden = all.length - jobs.length;
    // [beside]: in its own column to the right of the list (a wide
    // screen). On a phone the card is a smaller one: the same job and
    // buttons, less around them (Jonathan, 7 Oct 2026).
    final small = _smallScreen && !beside;
    Widget shell(List<Widget> children) => Container(
          width: double.infinity,
          margin: beside
              ? const EdgeInsets.fromLTRB(0, 12, 14, 4)
              : small
                  ? const EdgeInsets.fromLTRB(12, 8, 12, 2)
                  : const EdgeInsets.fromLTRB(14, 12, 14, 4),
          padding: small
              ? const EdgeInsets.fromLTRB(12, 9, 10, 6)
              : const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Brand.accent, width: 1.5),
          ),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children),
        );
    const label = Text('NEXT UP',
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: .6,
            color: Brand.accent));
    // One line, out of the way of the list below, with the way back.
    Widget oneLine(String text) => Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Brand.accent),
          ),
          child: Row(children: [
            label,
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
            TextButton(
                onPressed: () => setState(() {
                      _nextUpFolded = false;
                      _topAway = false;
                    }),
                child: const Text('Show')),
          ]),
        );
    final away = _topAway && _smallScreen;
    if (!_nextUpRead) {
      if (away) return oneLine('Finding the next thing...');
      return shell([
        label,
        const SizedBox(height: 6),
        const Text('Finding the next thing...',
            style: TextStyle(fontSize: 14, color: Brand.inkSecondary)),
      ]);
    }
    if (jobs.isEmpty) {
      if (away) {
        return oneLine(all.isEmpty
            ? 'Nothing is waiting. All clear.'
            : 'You have skipped everything that is waiting.');
      }
      return shell([
        label,
        const SizedBox(height: 6),
        Text(
            all.isEmpty
                ? 'Nothing is waiting. All clear.'
                : 'You have skipped everything that is waiting.',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        if (all.isNotEmpty) ...[
          const SizedBox(height: 8),
          OutlinedButton(
              onPressed: () => setState(_skipped.clear),
              child: const Text('Start again')),
        ],
      ]);
    }
    final job = jobs.first;
    if ((_nextUpFolded && !beside) || away) {
      // You are in the job, in the list below: it opens again when
      // something is decided, or on "Show". Or, on a phone, you have
      // scrolled the list: it opens again at the top of the list, or
      // on "Show". Beside the list it is in nobody's way and stays.
      return oneLine(job.title);
    }
    final after = jobs.skip(1).take(3).map((j) => j.title).toList();
    // On a phone the buttons are a size smaller.
    final tight = small
        ? const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap)
        : null;
    return shell([
      Row(children: [
        label,
        const Spacer(),
        if (jobs.length > 1)
          Text('${jobs.length - 1} more after this',
              style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
      ]),
      SizedBox(height: small ? 3 : 6),
      Text(job.title,
          style: TextStyle(
              fontSize: small ? 15 : 17, fontWeight: FontWeight.w800)),
      SizedBox(height: small ? 2 : 4),
      Text(job.detail,
          maxLines: small ? 2 : null,
          overflow: small ? TextOverflow.ellipsis : null,
          style: TextStyle(
              fontSize: small ? 12.5 : 13,
              height: small ? 1.35 : 1.45,
              color: Brand.inkSecondary)),
      SizedBox(height: small ? 6 : 10),
      Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ElevatedButton(
                onPressed: job.open, style: tight, child: Text(job.button)),
            if (job.second != null && job.onSecond != null)
              OutlinedButton(
                  onPressed: job.onSecond,
                  style: tight,
                  child: Text(job.second!)),
            TextButton(
                onPressed: () => setState(() => _skipped.add(job.kind)),
                style: TextButton.styleFrom(
                    foregroundColor: Brand.inkSecondary,
                    visualDensity: small ? VisualDensity.compact : null,
                    tapTargetSize:
                        small ? MaterialTapTargetSize.shrinkWrap : null),
                child: Text(small ? 'Skip' : 'Skip for now')),
          ]),
      // What comes after: a list beside the list, one line under the
      // card on a laptop, left out on a phone.
      if (after.isNotEmpty && beside) ...[
        const SizedBox(height: 12),
        const Text('THEN',
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .6,
                color: Brand.inkMuted)),
        for (final t in after)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(t,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.35, color: Brand.inkSecondary)),
          ),
      ] else if (after.isNotEmpty && !small) ...[
        const SizedBox(height: 8),
        Text('Then: ${after.join('  ·  ')}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
      ],
      if (hidden > 0)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              onPressed: () => setState(_skipped.clear),
              style: TextButton.styleFrom(
                  foregroundColor: Brand.inkMuted,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: Text(hidden == 1
                  ? 'Show the 1 you skipped'
                  : 'Show the $hidden you skipped')),
        ),
    ]);
  }

  /// Everything waiting on us, in one line: tap an item to go there.
  Widget _todayStrip(
      ({
        List<Map<String, dynamic>> ready,
        List<Map<String, dynamic>> needsRegion,
        List<Map<String, dynamic>> preparing,
        List<Map<String, dynamic>> fresh
      }) g) {
    String n(int x, String one, String many) => '$x ${x == 1 ? one : many}';
    final items = <(String, String, Color)>[
      if (_passOn.isNotEmpty)
        (n(_passOn.length, 'enquiry to pass on', 'enquiries to pass on'),
            'enquiries', Brand.red),
      if (_held.isNotEmpty)
        (n(_held.length, 'claim to decide', 'claims to decide'), 'paid',
            Brand.success),
      if (_orders.isNotEmpty)
        (n(_orders.length, 'payment to match', 'payments to match'), 'paid',
            Brand.success),
      if (_ownerDrafts.isNotEmpty)
        (n(_ownerDrafts.length, 'owner change', 'owner changes'), 'owner',
            Brand.goldTextDark),
      if (_updates.isNotEmpty)
        (n(_updates.length, 'suggested update', 'suggested updates'), 'owner',
            Brand.goldTextDark),
      if (g.ready.isNotEmpty)
        (n(g.ready.length, 'page to approve', 'pages to approve'), 'ready',
            Brand.accent),
      if (g.needsRegion.isNotEmpty)
        (n(g.needsRegion.length, 'blocked', 'blocked'), 'region',
            Brand.goldTextDark),
      if (g.fresh.isNotEmpty)
        (n(g.fresh.length, 'new space', 'new spaces'), 'fresh', Brand.violet),
      if (_drafts.length + _approvedTonight.length > 0)
        (
          n(_drafts.length + _approvedTonight.length, 'page in Webflow',
              'pages in Webflow'),
          'drafts',
          Brand.inkSecondary
        ),
      if (_sitemapCount > 0)
        (n(_sitemapCount, 'sitemap entry', 'sitemap entries'), 'sitemap',
            Brand.goldTextDark),
      if (_closed.isNotEmpty)
        (n(_closed.length, 'closed place', 'closed places'), 'closed',
            Brand.red),
    ];
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
          color: Brand.surface,
          border: Border(bottom: BorderSide(color: Brand.hairline))),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Row(children: [
          const Text('TO DO',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .6,
                  color: Brand.inkMuted)),
          const SizedBox(width: 10),
          if (items.isEmpty)
            const Text('Nothing waiting. All clear.',
                style: TextStyle(fontSize: 13, color: Brand.success))
          else
            for (final (label, key, color) in items)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  backgroundColor: color.withValues(alpha: .10),
                  side: BorderSide.none,
                  label: Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: color)),
                  onPressed: () => _goToGroup(key),
                ),
              ),
        ]),
      ),
    );
  }

  /// Owners · Pages · Clean-up, each with what is waiting in it.
  Widget _sectionSwitch(
      ({
        List<Map<String, dynamic>> ready,
        List<Map<String, dynamic>> needsRegion,
        List<Map<String, dynamic>> preparing,
        List<Map<String, dynamic>> fresh
      }) g,
      String current) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: Brand.field, borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          for (final (key, label, groupKeys) in _sections)
            Expanded(
              // A pointing hand, and labels that are not picked up as
              // text: the page around them is selectable, which gave
              // these tabs a typing cursor (Jonathan, 5 Oct 2026).
              child: _tapArea(GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (key == current) return;
                  // The first group in it with work, else its first.
                  final todo = <String, int>{
                    'paid': _held.length + _orders.length,
                    'owner': _ownerDrafts.length + _updates.length,
                    'fresh': g.fresh.length,
                    'preparing': g.preparing.length,
                    'region': g.needsRegion.length,
                    'ready': g.ready.length,
                    'drafts': _drafts.length + _approvedTonight.length,
                    'sitemap': _sitemapCount,
                    'closed': _closed.length,
                  };
                  _goToGroup(groupKeys.firstWhere(
                      (k) => (todo[k] ?? 0) > 0,
                      orElse: () => groupKeys.first));
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: key == current ? Brand.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: key == current
                        ? [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: .06),
                                blurRadius: 4,
                                offset: const Offset(0, 1))
                          ]
                        : null,
                  ),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(label,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: key == current
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                color: key == current
                                    ? Brand.ink
                                    : Brand.inkSecondary)),
                        if (_sectionTodo(key, g) > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                                color: Brand.accent,
                                borderRadius: BorderRadius.circular(9)),
                            child: Text('${_sectionTodo(key, g)}',
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white)),
                          ),
                        ],
                      ]),
                ),
              )),
            ),
        ]),
      ),
    );
  }

  /// Something to press that is not a Material button: a pointing
  /// hand over all of it, and its words left out of text selection.
  Widget _tapArea(Widget child) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SelectionContainer.disabled(child: child),
      );

  Widget _pipeline({bool nextUpBeside = false}) {
    final g = _groups();
    final groups = <({String key, String label, int count, Color color,
        String hint, String empty})>[
      // Owners first: the people waiting on us (Jonathan, 29 Sep).
      (
        key: 'paid',
        label: 'Owners',
        count: _held.length + _paid.length + _orders.length + _started.length,
        color: Brand.success,
        hint: 'Everyone who has claimed a page, free or Verified. Claims '
            'waiting for a decision first, then payments needing a match, '
            'then forms started but not finished (last 30 days), then the '
            'Verified listings (paid, or made Verified by us) and the free '
            'pages with an owner on record.',
        empty: 'No claims or owners yet. Open a released page and tap '
            'Listing plan to mark the first one Verified.'
      ),
      (
        key: 'enquiries',
        label: 'Enquiries',
        count: _passOn.length,
        color: Brand.red,
        hint: 'Nomads who used Send an enquiry on a page with no owner yet, '
            'or with a Free owner. Pass each one on to the space: their reply '
            'goes straight to the nomad, and the email invites them to claim '
            'their page (or, on Free, mentions Verified). Verified spaces get '
            'theirs directly and never show here.',
        empty: 'No enquiries waiting. Enquiries for pages without an owner, '
            'or with a Free owner, land here to pass on.'
      ),
      (
        key: 'owner',
        label: 'Owner changes',
        count: _ownerDrafts.length + _updates.length,
        color: Brand.goldTextDark,
        hint: 'Suggested updates from anyone (the "Something need '
            'updating?" link on each page), then changes owners submitted '
            'from their Owner account: '
            'description, prices, hours, facts, photos, contact, and on '
            'Verified pages the message for the advert slot. Nothing is on '
            'the page until you put it there. Send back anything that '
            'oversells; the note reaches the owner.',
        empty: 'No owner changes waiting.'
      ),
      // Before New spaces: places the nightly job found, not spaces yet.
      // A backlog to work through, so it is not counted in To do.
      (
        key: 'candidates',
        label: 'Candidates',
        count: _candidateCount,
        color: Brand.violet,
        hint: '',
        empty: ''
      ),
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
        count: _sitemap.length +
            _sitemapRegions.length +
            _sitemapLocations.length +
            _sitemapCountries.length,
        color: Brand.goldTextDark,
        hint: 'Released listings needing a sitemap entry, plus a log of '
            'every region, location and country page set up since the log '
            'began. The directory pages matter most: one of them carries a '
            'whole city.',
        empty: 'Sitemap is up to date.'
      ),
      (
        key: 'closed',
        label: 'Closed',
        count: _closed.length,
        color: Brand.red,
        hint: 'Google reports these places as no longer operating. '
            'Temporary closures are often worth waiting out; permanently '
            'closed usually means retire. Retire the page (it comes off the '
            'site, the address redirects to the city page) or say it is '
            'still open. Checked about monthly.',
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
    // A group stays chosen when it empties (its empty note shows); the
    // Today strip and the three sections take you to the next work.
    if (key == null || !groups.any((x) => x.key == key)) {
      const steps = ['enquiries', 'fresh', 'preparing', 'region', 'ready'];
      key = groups
          .firstWhere((x) => steps.contains(x.key) && x.count > 0,
              orElse: () => groups.firstWhere((x) => x.key == 'fresh'))
          .key;
    }
    final current = groups.firstWhere((x) => x.key == key);

    final cards = switch (key) {
      'enquiries' => [
          _importLine(),
          if (_passed30 + _direct30 > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                  'Last 30 days: $_passed30 passed on, $_direct30 sent '
                  'straight to Verified spaces.',
                  style: const TextStyle(
                      fontSize: 12.5, color: Brand.inkSecondary)),
            ),
          if (_passOn.isEmpty) _groupEmpty(current.empty),
          for (final e in _passOn)
            PassOnCard(
              key: ValueKey('passon-${e['id']}'),
              e: e,
              supabase: _supabase,
              onDone: _load,
              chooseSpace: (initial) =>
                  showModalBottomSheet<Map<String, dynamic>>(
                      context: context,
                      isScrollControlled: true,
                      shape: const RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.vertical(top: Radius.circular(18))),
                      builder: (_) => _VenueSearchSheet(
                          supabase: _supabase, initial: initial)),
            ),
        ],
      'ready' => g.ready.map(_readyCard).toList(),
      'region' => g.needsRegion.map(_needsRegionCard).toList(),
      'fresh' => g.fresh.map(_freshCard).toList(),
      'preparing' => g.preparing.map(_preparingTile).toList(),
      'hidden' => _hiddenCards(),
      'closed' => _closedCards(),
      'owner' => [
          _updatesCard(),
          if (_ownerDrafts.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 6, 4, 12),
              child: Text('No owner changes waiting.',
                  style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
            ),
          ..._ownerDrafts.map(_ownerDraftCard),
        ],
      'paid' => [
          MoneyCard(verified: _paid),
          _previewCard(),
          _journeysCard(),
          _insightsCard(),
          _emailsCard(),
          if (_held.isNotEmpty) ...[
            _ownersSection('Waiting for your decision', _held.length),
            ..._held.map(_heldCard),
          ],
          if (_orders.isNotEmpty) ...[
            _ownersSection('Payments to match', _orders.length),
            ..._orders.map(_orderCard),
          ],
          if (_started.isNotEmpty) ...[
            _ownersSection('Started the form, did not finish',
                _started.length),
            ..._started.map(_startedCard),
          ],
          _ownersSection('Verified listings', _paid.length),
          ..._newestFirst(_paid).map(_paidCard),
          _ownersSection('Free listings with an owner', _freeOwned.length),
          if (_freeOwned.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text('None yet. An approved free claim lands here.',
                  style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
            ),
          ..._newestFirst(_freeOwned).map(_paidCard),
        ],
      _ => <Widget>[],
    };
    // The later stages have their own list screens.
    final Widget? whole = switch (key) {
      'candidates' => CandidatesTab(
          key: const ValueKey('candidates-tab'),
          supabase: _supabase,
          places: _places,
          regionForCity: (city) =>
              city == null ? null : _regionFor({'city': city}),
          dismissReasons: dismissReasons,
          onQueued: _load,
          onScroll: _onListScroll,
          onCount: (n) {
            if (mounted && n != _candidateCount) {
              setState(() {
                // One was decided from "Next up" (turned down does
                // not reload the page): the next job is up.
                if (n < _candidateCount && _openedTurn == 'candidates') {
                  _turn = _turns.indexOf('candidates') + 1;
                  _openedTurn = null;
                  _nextUpFolded = false;
                }
                _candidateCount = n;
              });
              _loadNextUp();
            }
          },
        ),
      'drafts' => _draftsTab(),
      'released' => _releasedTab(),
      'sitemap' => _SitemapTab(
          onChanged: _load,
          copy: _copy,
          kinds: [
            _SitemapKind(
              key: 'listings',
              label: 'Listings',
              path: 'coworking',
              slugField: 'webflow_slug',
              items: _sitemap,
              mark: _supabase.markSitemapAdded,
              where: (v) => [v['neighbourhood'], v['city']]
                  .where((x) => x != null && '$x'.isNotEmpty)
                  .join(', '),
            ),
            _SitemapKind(
              key: 'regions',
              label: 'Region pages',
              path: 'region',
              slugField: 'slug',
              items: _sitemapRegions,
              mark: (ids) => _supabase.markTaxonomySitemapAdded(
                  'webflow_regions', ids),
              where: (v) => _logLine(v, '${v['country'] ?? ''}'),
            ),
            _SitemapKind(
              key: 'locations',
              label: 'Location pages',
              path: 'locations',
              slugField: 'slug',
              items: _sitemapLocations,
              mark: (ids) => _supabase.markTaxonomySitemapAdded(
                  'webflow_locations', ids),
              where: (v) {
                final r = _regions.firstWhere(
                    (x) => x['id'] == v['region_id'],
                    orElse: () => const <String, dynamic>{});
                return _logLine(
                    v,
                    [r['name'], v['country']]
                        .where((x) => x != null && '$x'.isNotEmpty)
                        .join(', '));
              },
            ),
            _SitemapKind(
              key: 'countries',
              label: 'Country pages',
              path: 'country',
              slugField: 'slug',
              items: _sitemapCountries,
              mark: (ids) => _supabase.markTaxonomySitemapAdded(
                  'webflow_countries', ids),
              where: (v) => _logLine(v, ''),
            ),
          ]),
      _ => null,
    };

    WidgetsBinding.instance.addPostFrameCallback((_) => _tabScrolled());
    final section = _sectionOf(key);
    final shown = groups
        .where((x) => _sectionOf(x.key) == section)
        .toList();
    // Another group starts at the top of its list, so the card and the
    // To do line are back.
    if (_topAwayKey != key) {
      _topAwayKey = key;
      _topAway = false;
    }
    final away = _topAway && _smallScreen;
    return Column(children: [
      SizedBox(
        width: double.infinity,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!nextUpBeside) _nextUpCard(g),
            if (!away) _todayStrip(g),
          ]),
        ),
      ),
      _sectionSwitch(g, section),
      // The groups of the chosen section, side by side: a swipe on a
      // phone, arrows at either end on a laptop (a mouse cannot swipe),
      // which only show when there is more to see in that direction.
      SizedBox(
        height: 50,
        child: Stack(children: [
          ListView.separated(
          controller: _tabScroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
          itemCount: shown.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final x = shown[i];
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
          if (_tabCanScrollLeft) _tabArrow(left: true),
          if (_tabCanScrollRight) _tabArrow(left: false),
        ]),
      ),
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: _onListScroll,
          child: whole ??
              ListView(
                  // its own list per group: each starts at its top
                  key: ValueKey('inbox-$key'),
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 30),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
                      child: Text(current.hint,
                          style: const TextStyle(
                              fontSize: 12,
                              color: Brand.inkMuted,
                              height: 1.4)),
                    ),
                    if (cards.isEmpty)
                      _inboxCount == 0
                          ? _inboxZero()
                          : _groupEmpty(current.empty)
                    else
                      ...cards,
                  ]),
        ),
      ),
    ]);
  }

  /// When the nomadwise.io pop-up was last read, or what went wrong.
  Widget _importLine() {
    final n = _importNote;
    final errors = (n?['errors'] as List?) ?? const [];
    final at = DateTime.tryParse('${n?['at']}')?.toLocal();
    String text;
    Color color = Brand.inkMuted;
    if (n == null || at == null) {
      text = 'The nomadwise.io pop-up has not been read yet. It is checked '
          'with the website push, every ten minutes or so.';
    } else if (errors.isNotEmpty) {
      text = 'Last check of the pop-up had a problem: ${errors.first}';
      color = Brand.red;
    } else {
      final m = DateTime.now().difference(at).inMinutes;
      text = 'nomadwise.io pop-up last checked '
          '${m < 1 ? 'just now' : m < 60 ? '$m min ago' : m < 1440 ? '${m ~/ 60} h ago' : DateFormat('d MMM, HH:mm').format(at)}.';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(text,
          style: TextStyle(fontSize: 12, height: 1.4, color: color)),
    );
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
  // ------------------------------------------------------- owner changes

  /// One submitted draft: what the owner wants on the page, next to
  /// what the page has now, field by field, with the two decisions.
  Widget _ownerDraftCard(Map<String, dynamic> d) {
    final v = Map<String, dynamic>.from(d['venue'] as Map? ?? {});
    final draft = Map<String, dynamic>.from(d['draft'] as Map? ?? {});
    final oc = Map<String, dynamic>.from(v['owner_content'] as Map? ?? {});
    final verified = v['listing_tier'] == 'verified';
    // Submitted again after we sent it back: show what changed since.
    final sentBack = d['sent_back'] is Map
        ? Map<String, dynamic>.from(d['sent_back'] as Map)
        : null;
    String s(dynamic x) => (x ?? '').toString().trim();
    final rows = <(String, String, String)>[]; // label, before, after
    void row(String label, dynamic before, dynamic after) {
      final b = s(before), a = s(after);
      if (a.isEmpty && b.isEmpty) return;
      if (a == b) return;
      rows.add((label, b, a));
    }

    row('Description', oc['description'], draft['description']);
    final np = Map<String, dynamic>.from(draft['prices'] as Map? ?? {});
    final op = Map<String, dynamic>.from(oc['prices'] as Map? ?? {});
    for (final (k, label) in [
      ('day', 'Day pass'),
      ('week', 'Week pass'),
      ('month', 'Month pass'),
      ('coffee', 'Cappuccino')
    ]) {
      row(label, op[k], np[k]);
    }
    final nh = Map<String, dynamic>.from(draft['hours'] as Map? ?? {});
    final oh = Map<String, dynamic>.from(v['opening_hours'] as Map? ?? {});
    for (final (k, label) in [
      ('mon', 'Monday'),
      ('tue', 'Tuesday'),
      ('wed', 'Wednesday'),
      ('thu', 'Thursday'),
      ('fri', 'Friday'),
      ('sat', 'Saturday'),
      ('sun', 'Sunday')
    ]) {
      row(label, oh[k], nh[k]);
    }
    final nf = Map<String, dynamic>.from(draft['facts'] as Map? ?? {});
    final of = Map<String, dynamic>.from(v['facts'] as Map? ?? {});
    for (final (k, label) in [
      ('laptops_allowed', 'Laptops welcome'),
      ('power_outlets', 'Plug sockets'),
      ('good_for_calls', 'Good for calls'),
      ('quiet_space', 'Quiet area'),
      ('comfortable_seating', 'Comfortable seating'),
      ('aircon', 'Aircon'),
      ('access_24h', '24 hour access'),
      ('call_room', 'Call room'),
      ('monitor', 'Monitors'),
      ('office_chairs', 'Office chairs'),
      ('cozy', 'Cozy')
    ]) {
      String yn(dynamic x) => x == null ? '' : (x == true ? 'Yes' : 'No');
      row(label, yn(of[k]), yn(nf[k]));
    }
    row('Website', v['website'], draft['website']);
    row('Instagram', v['instagram'], draft['instagram']);
    row('WhatsApp', oc['whatsapp'], draft['whatsapp']);
    row('Enquiries to', '', draft['enquiry_email']);
    final photos = List<String>.from((draft['photos'] ?? const []) as List);
    final oldPhotos = List<String>.from((oc['photos'] ?? const []) as List);
    final m = Map<String, dynamic>.from(draft['mention'] as Map? ?? {});
    final om = Map<String, dynamic>.from(oc['mention'] as Map? ?? {});
    if (verified) {
      row('Message kind', om['kind'], m['kind']);
      row('Message headline', om['title'], m['title']);
      row('Message text', om['body'], m['body']);
      row('Message button', om['cta'], m['cta']);
      row('Message link', om['url'], m['url']);
    } else if (s(m['title']).isNotEmpty) {
      rows.add(('Message (not applied: free page)', '', s(m['title'])));
    }

    return _card(
      tint: Brand.goldTint,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: Brand.goldTextDark,
                borderRadius: BorderRadius.circular(8)),
            child: const Text('OWNER CHANGES',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                    color: Colors.white)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('${v['name'] ?? 'A space'}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
          ),
          if (d['venue_id'] != null)
            IconButton(
                tooltip: 'Open the space',
                onPressed: () => _openVenue({'id': d['venue_id']}),
                icon: const Icon(Icons.chevron_right)),
        ]),
        Text(
            '${[v['city'], v['country']].where((x) => (x ?? '').toString().isNotEmpty).join(', ')}'
            '  ·  ${verified ? 'Verified' : 'Free'}  ·  ${d['owner_email'] ?? ''}'
            '  ·  submitted ${_ago(d['submitted_at'])}',
            style: const TextStyle(fontSize: 12, color: Brand.inkSecondary)),
        const SizedBox(height: 10),
        if (sentBack != null) ...[
          ResubmitChanges(sentBack: sentBack, current: draft),
          Theme(
            data: Theme.of(context)
                .copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 4),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: const Text('Everything compared with the page today',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Brand.inkSecondary)),
              children: [
        if (rows.isEmpty && photos.isEmpty)
          const Text('Nothing differs from the page. Put it on or send it back.',
              style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        for (final (label, before, after) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: Brand.inkSecondary)),
              if (before.isNotEmpty)
                Text(before,
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: Brand.inkMuted,
                        decoration: TextDecoration.lineThrough)),
              Text(after.isEmpty ? '(cleared)' : after,
                  style: const TextStyle(fontSize: 13, height: 1.4)),
            ]),
          ),
        if (photos.isNotEmpty) ...[
          Text(
              'Photos (${photos.length})'
              '${oldPhotos.isNotEmpty ? ', replacing ${oldPhotos.length} on file' : ''}',
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: Brand.inkSecondary)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in photos)
              InkWell(
                onTap: () => launchUrl(Uri.parse(p),
                    mode: LaunchMode.externalApplication),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(p,
                      width: 96, height: 72, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                          width: 96, height: 72, color: Brand.field)),
                ),
              ),
          ]),
          const SizedBox(height: 8),
        ],
              ],
            ),
          ),
        ] else ...[
        if (rows.isEmpty && photos.isEmpty)
          const Text('Nothing differs from the page. Put it on or send it back.',
              style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        for (final (label, before, after) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: Brand.inkSecondary)),
              if (before.isNotEmpty)
                Text(before,
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: Brand.inkMuted,
                        decoration: TextDecoration.lineThrough)),
              Text(after.isEmpty ? '(cleared)' : after,
                  style: const TextStyle(fontSize: 13, height: 1.4)),
            ]),
          ),
        if (photos.isNotEmpty) ...[
          Text(
              'Photos (${photos.length})'
              '${oldPhotos.isNotEmpty ? ', replacing ${oldPhotos.length} on file' : ''}',
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: Brand.inkSecondary)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in photos)
              InkWell(
                onTap: () => launchUrl(Uri.parse(p),
                    mode: LaunchMode.externalApplication),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(p,
                      width: 96, height: 72, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                          width: 96, height: 72, color: Brand.field)),
                ),
              ),
          ]),
          const SizedBox(height: 8),
        ],
        ],
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed: () => _applyOwnerDraft(d),
              style: FilledButton.styleFrom(backgroundColor: Brand.success),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Put it on the page')),
          TextButton(
              onPressed: () => _declineOwnerDraft(d),
              child: const Text('Send back')),
          ..._whatsappButtons(
              venueId: '${d['venue_id']}',
              space: '${v['name'] ?? 'your space'}',
              country: v['country']?.toString(),
              pagePhone: s(draft['whatsapp']).isNotEmpty
                  ? s(draft['whatsapp'])
                  : s(oc['whatsapp'])),
          TextButton.icon(
              onPressed: () => _openTrail('${d['venue_id']}',
                  '${(d['venue'] as Map?)?['name'] ?? 'this space'}'),
              style: TextButton.styleFrom(foregroundColor: Brand.inkSecondary),
              icon: const Icon(Icons.history, size: 16),
              label: const Text('History')),
        ]),
      ]),
    );
  }

  Future<void> _applyOwnerDraft(Map<String, dynamic> d) async {
    final name = '${(d['venue'] as Map?)?['name'] ?? 'the space'}';
    try {
      await _supabase.ownerApplyDraft('${d['id']}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$name: on its way to the page. The site updates '
              'within a few minutes.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That did not apply: $e'),
          backgroundColor: Brand.red));
    }
  }

  // Ready-made notes for Send back live in widgets/reply_suggestions.dart:
  // replies worked out from what the owner entered, then general ones,
  // so an owner never gets a bare "these changes aren't good"
  // (Jonathan, 29 Sep and 1 Oct).

  Future<void> _declineOwnerDraft(Map<String, dynamic> d) async {
    final name = '${(d['venue'] as Map?)?['name'] ?? 'the space'}';
    final ctl = TextEditingController();
    final suggested = suggestReplies(
        Map<String, dynamic>.from(d['draft'] as Map? ?? {}),
        verified: (d['venue'] as Map?)?['listing_tier'] == 'verified');
    void fill(String text) {
      final now = ctl.text.trim();
      ctl.text = now.isEmpty ? text : '$now\n\n$text';
      ctl.selection = TextSelection.collapsed(offset: ctl.text.length);
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // A readable width on a computer, the full width on a phone,
        // and a note box tall enough to read back what you wrote.
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        title: Text('Send the changes back to $name?'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                      'The page stays as it is. The owner is emailed your note '
                      'with a link to their Owner account, where they can '
                      'edit and submit again.',
                      style: TextStyle(fontSize: 13.5, height: 1.45)),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: Brand.bg,
                        borderRadius: BorderRadius.circular(10)),
                    child: const Text(
                        'The email already opens with "Thank you for updating '
                        '... Before we put your changes on the page, we have a '
                        'small suggestion." and ends with how to sign in, so '
                        'the note only needs the suggestion itself.',
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.45,
                            color: Brand.inkSecondary)),
                  ),
                  const SizedBox(height: 14),
                  // Replies worked out from what they entered.
                  Row(children: [
                    const Icon(Icons.auto_awesome_outlined,
                        size: 16, color: Brand.goldTextDark),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          suggested.isEmpty
                              ? 'Nothing obvious to fix in what they entered. '
                                  'Pick a reply below or write your own.'
                              : 'Suggested from what they entered. Tap one to '
                                  'put it in the reply, then check the words:',
                          style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Brand.ink)),
                    ),
                  ]),
                  if (suggested.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final r in suggested)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              side: const BorderSide(color: Brand.border),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8))),
                          onPressed: () => fill(r.text),
                          child: Row(children: [
                            const Icon(Icons.add_comment_outlined,
                                size: 16, color: Brand.inkSecondary),
                            const SizedBox(width: 8),
                            Text(r.label,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Brand.ink)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(r.why,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, color: Brand.inkMuted)),
                            ),
                          ]),
                        ),
                      ),
                    if (suggested.length > 1)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                            onPressed: () {
                              ctl.text = combineReplies(suggested);
                              ctl.selection = TextSelection.collapsed(
                                  offset: ctl.text.length);
                            },
                            icon: const Icon(Icons.playlist_add, size: 18),
                            label: Text(
                                'Use all ${suggested.length} as one reply')),
                      ),
                  ],
                  const SizedBox(height: 10),
                  const Text('Other replies:',
                      style: TextStyle(
                          fontSize: 12.5, color: Brand.inkSecondary)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final (label, text) in generalReplies)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(label,
                            style: const TextStyle(fontSize: 12.5)),
                        onPressed: () => fill(text),
                      ),
                  ]),
                  const SizedBox(height: 14),
                  TextField(
                      controller: ctl,
                      autofocus: true,
                      minLines: 8,
                      maxLines: 16,
                      maxLength: 2500,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(fontSize: 14.5, height: 1.5),
                      decoration: const InputDecoration(
                          labelText: 'Note to the owner',
                          alignLabelWithHint: true,
                          hintText: 'e.g. Could you add the currency to the '
                              'cappuccino price? Everything else looks great.',
                          border: OutlineInputBorder())),
                ]),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep reviewing')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send back')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _supabase.ownerDeclineDraft('${d['id']}', ctl.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sent back with your note.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That did not send: $e'), backgroundColor: Brand.red));
    }
  }

  // ------------------------------------------------------------ closed

  static String _statusWords(String? bs) => switch (bs) {
        'CLOSED_PERMANENTLY' => 'permanently closed',
        'CLOSED_TEMPORARILY' => 'temporarily closed',
        _ => 'not operating',
      };

  // Two kinds of closure, filtered separately: a temporary closure is
  // usually worth waiting out, a permanent one is a retire.
  static String _closedKind(String? bs) =>
      bs == 'CLOSED_TEMPORARILY' ? 'temp' : 'gone';

  /// 'all', 'temp' or 'gone'.
  String _closedFilter = 'all';

  // The Clean-up search box. It narrows the Closed and Not for the
  // site lists while typing; both lists are already on the screen, so
  // nothing is fetched and there is no wait.
  String _cleanQuery = '';
  final _cleanCtl = TextEditingController();

  /// True when every word typed is found in the space's name, place,
  /// country, page address or (for a hidden space) its reason.
  bool _cleanMatch(Map<String, dynamic> v) {
    final words = _cleanQuery
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return true;
    final text = [
      v['name'],
      v['neighbourhood'],
      v['city'],
      _countryOf(v),
      v['webflow_slug'],
      v['website_dismiss_reason'],
      v['website_dismiss_note'],
    ].where((x) => x != null).join(' ').toLowerCase();
    return words.every((w) => text.contains(w));
  }

  Widget _cleanSearch(String hint) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: _cleanCtl,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: hint,
              isDense: true,
              filled: true,
              fillColor: Brand.field,
              suffixIcon: _cleanQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _cleanCtl.clear();
                        setState(() => _cleanQuery = '');
                      }),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none)),
          onChanged: (t) => setState(() => _cleanQuery = t.trim()),
        ),
      );

  List<Widget> _hiddenCards() {
    if (_hidden.isEmpty) return const [];
    final shown = _hidden.where(_cleanMatch).toList();
    return [
      _cleanSearch('Search by name, place or reason'),
      if (shown.isEmpty)
        _groupEmpty('Nothing here matches "$_cleanQuery".')
      else
        ...shown.map(_hiddenTile),
    ];
  }

  List<Widget> _closedCards() {
    // The search narrows the list first; the three chips then count
    // and show what is left.
    final pool = _closed.where(_cleanMatch).toList();
    final temp =
        pool.where((v) => _closedKind(v['business_status']) == 'temp');
    final gone =
        pool.where((v) => _closedKind(v['business_status']) == 'gone');
    final shown = switch (_closedFilter) {
      'temp' => temp,
      'gone' => gone,
      _ => pool,
    };
    final choices = [
      ('all', 'All', pool.length, Brand.inkSecondary),
      ('temp', 'Temporarily closed', temp.length, Brand.goldTextDark),
      ('gone', 'Permanently closed', gone.length, Brand.red),
    ];
    return [
      if (_closed.isNotEmpty)
        _cleanSearch('Search by name, place or page address'),
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (k, label, n, color) in choices)
              ChoiceChip(
                selected: _closedFilter == k,
                showCheckmark: false,
                onSelected: (_) => setState(() => _closedFilter = k),
                selectedColor: color,
                backgroundColor: Brand.surface,
                side: BorderSide(
                    color: _closedFilter == k ? color : Brand.border),
                labelStyle: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: _closedFilter == k
                        ? Colors.white
                        : Brand.inkSecondary),
                label: Text('$label  $n'),
              ),
          ],
        ),
      ),
      if (shown.isEmpty)
        _groupEmpty(_cleanQuery.isNotEmpty
            ? 'Nothing here matches "$_cleanQuery".'
            : _closedFilter == 'temp'
                ? 'Nothing is temporarily closed.'
                : 'Nothing is permanently closed.')
      else
        ...shown.map(_closedCard),
    ];
  }

  Widget _closedTag(String? bs) {
    final temp = _closedKind(bs) == 'temp';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: temp ? Brand.goldTint : Brand.accentTint,
          borderRadius: BorderRadius.circular(8)),
      child: Text(temp ? 'TEMPORARY' : 'PERMANENT',
          style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: .5,
              color: temp ? Brand.goldTextDark : Brand.red)),
    );
  }

  Future<void> _retire(Map<String, dynamic> v) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: Text('Retire ${v['name']}?'),
              content: Text(
                  'The page comes off nomadwise.io within a minute or two: '
                  'the listing and its Images entry are unpublished and '
                  'archived, the slug /coworking/${v['webflow_slug'] ?? ''} '
                  'is released, and Webflow is asked to add a redirect to '
                  'the city page. Webflow only accepts that on some plans: '
                  'the card says afterwards whether it was added or needs '
                  'adding by hand. A redirect goes live when you next '
                  'publish the site.'),
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

  /// Ticks or unticks one of the founder's own steps on a retired
  /// card. The ticks live in the retire note, so they are still there
  /// after a reload or on another device. Shown at once; put back if
  /// the save fails.
  Future<void> _retireTick(
      Map<String, dynamic> v, String key, bool on) async {
    final before = v['website_retire_note'];
    final note = <String, dynamic>{
      if (before is Map)
        for (final e in before.entries) '${e.key}': e.value,
      key: on,
    };
    setState(() => v['website_retire_note'] = note);
    try {
      await _supabase.updateVenueFields(
          '${v['id']}', {'website_retire_note': note});
    } catch (e) {
      if (!mounted) return;
      setState(() => v['website_retire_note'] = before);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That tick did not save: $e'),
          backgroundColor: Brand.red));
    }
  }

  /// One step on a retired card: a tick, what it is, and anything
  /// worth copying for it.
  Widget _retireStep(Map<String, dynamic> v, String key,
      {required String title,
      required String detail,
      List<Widget> actions = const []}) {
    final note = (v['website_retire_note'] as Map?) ?? const {};
    final on = note[key] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 32,
          height: 32,
          child: Checkbox(
              value: on,
              activeColor: Brand.success,
              onChanged: (x) => _retireTick(v, key, x ?? false)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () => _retireTick(v, key, !on),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 2),
                    child: Text(title,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            decoration:
                                on ? TextDecoration.lineThrough : null,
                            color: on ? Brand.inkMuted : Brand.ink)),
                  ),
                ),
                Text(detail,
                    style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: Brand.inkSecondary)),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 6, children: actions),
                ],
              ]),
        ),
      ]),
    );
  }

  Widget _closedCard(Map<String, dynamic> v) {
    final note = (v['website_retire_note'] as Map?) ?? const {};
    final retired = v['website_retired_at'] != null;
    final asked = v['website_retire_requested_at'] != null && !retired;
    final err = note['error'];
    final url = v['webflow_slug'] == null
        ? null
        : 'https://www.nomadwise.io/coworking/${v['webflow_slug']}';
    final country = _countryOf(v);
    // For a retired card: the two addresses of the redirect, whether
    // Webflow took it from the sync, and the founder's two ticks.
    final from = '${note['from'] ?? ''}';
    final to = '${note['to'] ?? ''}';
    final redirectAdded = '${note['redirect'] ?? ''}'.startsWith('added');
    final stepsDone =
        note['redirect_done'] == true && note['sitemap_done'] == true;
    return _card(
      tint: retired ? Brand.field : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(v['name'] ?? '',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                    ),
                    if (!retired) ...[
                      const SizedBox(width: 8),
                      _closedTag(v['business_status']),
                    ],
                  ]),
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
          const SizedBox(height: 4),
          const Text(
              'Two steps are left for you. Tick each one when it is done, '
              'then mark the card as complete and it leaves this list.',
              style: TextStyle(fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 10),
          _retireStep(v, 'redirect_done',
              title: redirectAdded
                  ? 'Site published, so the redirect is live'
                  : 'Redirect added in Webflow and the site published',
              detail: redirectAdded
                  ? 'Webflow accepted the redirect from $from to $to. It '
                      'goes live when the site is next published.'
                  : 'Webflow did not add this one automatically. Add it '
                      'under Site settings, Publishing, 301 redirects: old '
                      'path $from, redirect to $to. Then publish the site.',
              actions: [
                if (!redirectAdded) ...[
                  OutlinedButton.icon(
                      onPressed: () => _copy(from, 'Old path copied'),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy old path')),
                  OutlinedButton.icon(
                      onPressed: () => _copy(to, 'New path copied'),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy new path')),
                ],
              ]),
          _retireStep(v, 'sitemap_done',
              title: 'Removed from the custom sitemap',
              detail: 'https://www.nomadwise.io$from',
              actions: [
                OutlinedButton.icon(
                    onPressed: () => _copy(
                        'https://www.nomadwise.io$from',
                        'Old address copied'),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy old address')),
              ]),
          Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                    onPressed: stepsDone ? () => _retireDone(v) : null,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Mark as complete')),
                if (!stepsDone)
                  const Text('Tick both steps first.',
                      style: TextStyle(
                          fontSize: 12.5, color: Brand.inkMuted)),
              ]),
        ],
      ]),
    );
  }

  // ------------------------------------------------------------ paid listings

  static DateTime? _day(String? s) => s == null ? null : DateTime.tryParse(s);

  /// Days until the plan renews; negative once it has lapsed.
  static int? _daysToRenewal(Map<String, dynamic> v) {
    final r = _day(v['listing_renews_at']);
    if (r == null) return null;
    return r.difference(DateTime.now()).inDays;
  }

  Future<void> _editPlan(Map<String, dynamic> v) async {
    final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => _ListingPlanPage(supabase: _supabase, venue: v)));
    if (saved == true) await _load();
  }

  List<Map<String, dynamic>> _enquiriesFor(Map<String, dynamic> v) =>
      _enquiries.where((e) => e['venue_id'] == v['id']).toList();

  static String _wantWords(String? w) => switch (w) {
        'day_pass' => 'day pass',
        'desk_month' => 'desk for a month or longer',
        'event' => 'meeting or event',
        _ => 'something else',
      };

  /// The booking requests one listing has had, newest first, with a
  /// re-send for any that did not go out (no Resend key yet, say).
  Future<void> _showEnquiries(Map<String, dynamic> v) async {
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (ctx) {
          final rows = _enquiriesFor(v);
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * .75,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Text('Enquiries for ${v['name']}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 4),
                Text(
                    'Sent to ${(v['listing_enquiry_email'] ?? '').toString().isEmpty ? 'hello@nomadwise.io' : v['listing_enquiry_email']}, '
                    'with a copy to hello@nomadwise.io.',
                    style: const TextStyle(
                        fontSize: 12.5, color: Brand.inkMuted)),
                const SizedBox(height: 10),
                ...rows.map((e) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      elevation: 0,
                      color: e['status'] == 'failed'
                          ? Brand.accentTint
                          : Brand.field,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${e['name']}  ·  ${e['email']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(
                                  [
                                    _wantWords(e['want']),
                                    if ((e['dates'] ?? '').toString().isNotEmpty)
                                      e['dates'],
                                    if (e['people'] != null)
                                      '${e['people']} people',
                                    _ago(e['created_at']),
                                  ].join('  ·  '),
                                  style: const TextStyle(
                                      fontSize: 12, color: Brand.inkSecondary)),
                              if ((e['message'] ?? '').toString().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text('${e['message']}',
                                      style: const TextStyle(
                                          fontSize: 12.5, height: 1.4)),
                                ),
                              if (e['status'] == 'failed') ...[
                                const SizedBox(height: 6),
                                Text('Not delivered: ${e['send_error'] ?? ''}',
                                    style: const TextStyle(
                                        fontSize: 12, color: Brand.red)),
                                TextButton.icon(
                                    onPressed: () async {
                                      try {
                                        await _supabase.resendEnquiry(e['id']);
                                        if (ctx.mounted) Navigator.pop(ctx);
                                        await _load();
                                      } catch (err) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(SnackBar(
                                                  content: Text(
                                                      'Re-send failed: $err')));
                                        }
                                      }
                                    },
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: const Text('Re-send now')),
                              ] else if (e['status'] == 'sent')
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text('Sent to ${e['to_email'] ?? ''}',
                                      style: const TextStyle(
                                          fontSize: 11.5,
                                          color: Brand.inkMuted)),
                                ),
                            ]),
                      ),
                    )),
              ]),
            ),
          );
        });
  }

  Widget _paidCard(Map<String, dynamic> v) {
    final verified = v['listing_tier'] == 'verified';
    final onSite = v['webflow_verified'] == true;
    final days = _daysToRenewal(v);
    final renews = _day(v['listing_renews_at']);
    final pageState = switch (v['website_status']) {
      'released' => 'live and in the sitemap',
      'published_hidden' => 'live, not in the sitemap yet',
      'retired' => 'retired',
      'removed' => 'removed from the site',
      _ => 'not on the site yet',
    };
    final waiting = v['listing_sync_requested_at'] != null &&
        v['listing_synced_at'] == null;
    final country = _countryOf(v);
    final lines = <Widget>[];
    if (!verified && onSite) {
      lines.add(const Text(
          'Verified switch is on in Webflow but there is no plan here '
          '(a legacy premium page). Set a plan, or save it as Free to '
          'switch the badge off.',
          style: TextStyle(fontSize: 12.5, color: Brand.goldTextDark)));
    }
    final who = [
      if ((v['listing_owner_name'] ?? '').toString().isNotEmpty)
        v['listing_owner_name'],
      if ((v['listing_owner_email'] ?? '').toString().isNotEmpty)
        v['listing_owner_email'],
    ].join('  ·  ');
    if (who.isNotEmpty) {
      lines.add(Text('Owner: $who', style: const TextStyle(fontSize: 12.5)));
    }
    if (verified) {
      lines.add(Text(
          'Enquiries to ${(v['listing_enquiry_email'] ?? '').toString().isEmpty ? 'hello@nomadwise.io (none set)' : v['listing_enquiry_email']}',
          style: const TextStyle(fontSize: 12.5)));
      if (renews != null) {
        final when = DateFormat('d MMM yyyy').format(renews);
        final note = days == null
            ? ''
            : days < 0
                ? '  ·  lapsed ${-days} days ago'
                : days <= 30
                    ? '  ·  in $days days'
                    : '';
        lines.add(Text('Renews $when$note',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: days != null && days <= 30
                    ? FontWeight.w700
                    : FontWeight.w400,
                color: days != null && days < 0
                    ? Brand.red
                    : days != null && days <= 30
                        ? Brand.goldTextDark
                        : Brand.ink)));
      }
    }
    lines.add(Text(
        'Page: $pageState'
        '${verified && !onSite && !waiting ? '  ·  badge not on the page yet' : ''}'
        '${waiting ? '  ·  updating Webflow now' : ''}',
        style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)));
    if (v['listing_sync_error'] != null) {
      lines.add(Text('Webflow update failed: ${v['listing_sync_error']}',
          style: const TextStyle(fontSize: 12.5, color: Brand.red)));
    }
    final reqs = _enquiriesFor(v);
    final failed = reqs.where((e) => e['status'] == 'failed').length;
    if (reqs.isNotEmpty) {
      lines.add(Text(
          '${reqs.length} enquir${reqs.length == 1 ? 'y' : 'ies'}, '
          'last one ${_ago(reqs.first['created_at'])}'
          '${failed > 0 ? '  ·  $failed not delivered' : ''}',
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: failed > 0 ? Brand.red : Brand.ink)));
    }
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: verified ? Brand.success : Brand.field,
                borderRadius: BorderRadius.circular(8)),
            child: Text(verified ? 'VERIFIED' : 'FREE',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                    color: verified ? Colors.white : Brand.inkSecondary)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v['name'] ?? '',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
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
        ...lines.map((w) =>
            Padding(padding: const EdgeInsets.only(bottom: 3), child: w)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => _editPlan(v),
              icon: const Icon(Icons.workspace_premium_outlined, size: 18),
              label: const Text('Listing plan')),
          if (reqs.isNotEmpty)
            OutlinedButton.icon(
                onPressed: () => _showEnquiries(v),
                icon: const Icon(Icons.mail_outline, size: 18),
                label: Text('Requests (${reqs.length})')),
          if (v['webflow_slug'] != null)
            TextButton.icon(
                onPressed: () => launchUrl(
                    Uri.parse(
                        'https://www.nomadwise.io/coworking/${v['webflow_slug']}'),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new, size: 15),
                label: const Text('Open page')),
          ..._whatsappButtons(
              venueId: '${v['id']}',
              space: '${v['name'] ?? 'your space'}',
              country: _countryOf(v) ?? v['country']?.toString(),
              pagePhone: (v['owner_whatsapp'] ?? '').toString()),
          TextButton.icon(
              onPressed: () => _openOwnerPreview('${v['id']}'),
              icon: const Icon(Icons.visibility_outlined, size: 16),
              label: const Text('Their Owner account')),
          TextButton.icon(
              onPressed: () => _openTrail('${v['id']}', '${v['name'] ?? 'this space'}'),
              icon: const Icon(Icons.history, size: 16),
              label: const Text('History')),
        ]),
      ]),
    );
  }

  // ------------------------------------------------------------ stripe orders

  /// A paid checkout the sync could not match to a space. One tap
  /// attaches it (search by name) and the plan follows.
  // A paid claim on a page that is already on the site. Nothing on the
  // page has changed yet: Approve makes it Verified, Reject leaves the
  // page alone and points at the Stripe refund.
  Widget _ownersSection(String title, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
        child: Text('${title.toUpperCase()}  ·  $count',
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: .8,
                color: Brand.inkMuted)),
      );

  /// Does the claimant look like the owner? Compares what they typed
  /// with what Google lists for the place: the phone number and the
  /// website. A phone match is strong (only the business changes the
  /// number on its Google listing); a website domain match likewise;
  /// nothing to compare means "ring the number Google lists and ask".
  Widget _ownerCheck(Map<String, dynamic> c, String placeId) {
    final givenPhone = _digits((c['owner_phone'] ?? '').toString());
    final email = (c['owner_email'] ?? '').toString().toLowerCase();
    final domain = email.contains('@') ? email.split('@').last : '';
    final givenSite = (c['space_website'] ?? '').toString();
    String host(String u) => u
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'^www\.'), '')
        .split('/')
        .first
        .toLowerCase();
    return FutureBuilder<PlaceLive?>(
      future: _places.details(placeId),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Checking against the Google listing...',
                style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
          );
        }
        final g = snap.data!;
        final gPhone = _digits(g.phone ?? '');
        final gHost = (g.website ?? '').isEmpty ? '' : host(g.website!);
        final phoneMatch = givenPhone.length >= 7 &&
            gPhone.length >= 7 &&
            (givenPhone.endsWith(gPhone.substring(gPhone.length - 7)) ||
                gPhone.endsWith(givenPhone.substring(givenPhone.length - 7)));
        final siteMatch = gHost.isNotEmpty &&
            ((domain.isNotEmpty && gHost == domain) ||
                (givenSite.isNotEmpty && host(givenSite) == gHost));
        final rows = <(IconData, Color, String)>[
          if (gPhone.isEmpty)
            (Icons.phone_disabled_outlined, Brand.inkMuted,
                'Google lists no phone number for this place.')
          else if (givenPhone.isEmpty)
            (Icons.phone_outlined, Brand.goldTextDark,
                'They gave no phone. Google lists ${g.phone}: message it on WhatsApp and ask for ${c['owner_name']}.')
          else if (phoneMatch)
            (Icons.check_circle_outline, Brand.success,
                'Phone matches the Google listing (${g.phone}).')
          else
            (Icons.error_outline, Brand.goldTextDark,
                'Phone differs from the Google listing (${g.phone}). Message that one on WhatsApp and ask for ${c['owner_name']}.'),
          if (gHost.isEmpty)
            (Icons.language, Brand.inkMuted,
                'Google lists no website for this place.')
          else if (siteMatch)
            (Icons.check_circle_outline, Brand.success,
                'Website matches the Google listing ($gHost).')
          else
            (Icons.language, Brand.goldTextDark,
                'Google lists $gHost; the claim came from $domain. Common with Gmail; '
                '${gPhone.isNotEmpty ? "a WhatsApp to Google's number settles it." : 'a message to their Instagram, or to the email on $gHost, settles it.'}'),
        ];
        final strong = phoneMatch || siteMatch;
        // The check-in message, to the number Google lists (the one
        // only the business could have put there). Calls do not
        // always reach these countries; WhatsApp does.
        final space = (c['space_name'] ??
                (c['venues'] is Map ? c['venues']['name'] : null) ??
                'your space')
            .toString();
        // Warm and clear: who we are, who claimed, one easy question.
        // The role reads "(Manager)" etc.; "Other staff" adds nothing.
        var role = (c['owner_role'] ?? '').toString().trim();
        if (role.startsWith('Other: ')) role = role.substring(7);
        if (role == 'Other staff') role = '';
        final who = role.isEmpty
            ? '${c['owner_name']}'
            : '${c['owner_name']} (${role.toLowerCase()})';
        final ask = "Hi, I hope you're well! I'm Jonathan, co-founder of "
            'Nomadwise (nomadwise.io), where remote workers find great '
            'places to work.\n\n'
            '$who has just claimed the $space page on Nomadwise, so they '
            'can keep it up to date. To keep your page safe, we always '
            "check with the space first: could you confirm they're part "
            'of your team? A quick yes is all we need.\n\n'
            'Thank you, and have a lovely day!';
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    strong
                        ? 'Ownership: strong, the claim matches what Google lists.'
                        : gPhone.isNotEmpty
                            ? 'Ownership: not proven yet, one WhatsApp message away.'
                            : 'Ownership: not proven yet. Google has no phone for '
                                'this place: message their Instagram, or the email '
                                'on their website, and ask for ${c['owner_name']}.',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: strong ? Brand.success : Brand.goldTextDark)),
                if (gPhone.isNotEmpty && !strong)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: OutlinedButton.icon(
                        onPressed: () => launchUrl(
                            Uri.parse('https://wa.me/$gPhone?text='
                                '${Uri.encodeComponent(ask)}'),
                            mode: LaunchMode.platformDefault,
                            webOnlyWindowName: '_blank'),
                        icon: const Icon(Icons.chat_outlined, size: 16),
                        label: Text("WhatsApp Google's number (${g.phone})"),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Brand.goldTextDark,
                            textStyle: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w600))),
                  ),
                for (final r in rows)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(r.$1, size: 15, color: r.$2),
                          const SizedBox(width: 6),
                          Expanded(
                              child: Text(r.$3,
                                  style: TextStyle(
                                      fontSize: 12, color: r.$2))),
                        ]),
                  ),
              ]),
        );
      },
    );
  }

  static String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  /// " EUR 99" or " EUR 0 (code TESTVERIFIED)", from the Stripe order
  /// kept on the claim; empty when it is not known.
  static String _paidAmount(Map<String, dynamic> c) {
    final o = c['order_json'];
    if (o is! Map || o['amount'] == null) return '';
    final amt = (o['amount'] as num?)?.toDouble() ?? 0;
    final cur = '${o['currency'] ?? 'EUR'}';
    final shown = amt == amt.roundToDouble()
        ? amt.toStringAsFixed(0)
        : amt.toStringAsFixed(2);
    final code = (o['promo_code'] ?? '').toString();
    final disc = (o['amount_discount'] as num?)?.toDouble() ?? 0;
    return ' $cur $shown${code.isNotEmpty ? ' (code $code)' : disc > 0 ? ' (with a discount)' : ''}';
  }

  Widget _heldCard(Map<String, dynamic> c) {
    final v = (c['venues'] is Map)
        ? Map<String, dynamic>.from(c['venues'] as Map)
        : <String, dynamic>{};
    final free = c['status'] == 'free_pending';
    final newSpace = c['is_new_space'] == true && v.isEmpty;
    final spaceName = (v['name'] ?? c['space_name'] ?? 'A space').toString();
    final where = [
      v['city'] ?? c['space_city'],
      v['country'] ?? c['space_country']
    ].where((x) => (x ?? '').toString().isNotEmpty).join(', ');
    final who = [
      c['owner_name'],
      if ((c['owner_role'] ?? '').toString().isNotEmpty) c['owner_role'],
      c['owner_email'],
      if ((c['owner_phone'] ?? '').toString().isNotEmpty) c['owner_phone'],
    ].where((x) => (x ?? '').toString().isNotEmpty).join('  ·  ');
    final email = (c['owner_email'] ?? '').toString().toLowerCase();
    final site = (v['website'] ?? c['space_website'] ?? '').toString();
    // The phone from the claim form, as WhatsApp wants it.
    final claimWa = _waNumber((c['owner_phone'] ?? '').toString(),
        (v['country'] ?? c['space_country'] ?? '').toString());
    // A cheap sanity check: does the claimant's email domain match the
    // space's own website? A match is reassuring; a miss is not proof
    // of anything (many owners use Gmail), just a reason to look.
    String host(String u) => u
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'^www\.'), '')
        .split('/')
        .first
        .toLowerCase();
    final domain = email.contains('@') ? email.split('@').last : '';
    final match = site.isNotEmpty && domain.isNotEmpty && host(site) == domain;
    final previous = (v['listing_owner_email'] ?? '').toString();
    final address = (c['space_address'] ?? '').toString();
    // The claim's own place id (a new space) or the listing's.
    final placeId = (c['space_place_id'] ?? '').toString().isNotEmpty
        ? c['space_place_id'].toString()
        : (v['google_place_id'] ?? '').toString();
    final insta = (c['space_instagram'] ?? '').toString().isNotEmpty
        ? c['space_instagram'].toString()
        : (v['instagram'] ?? '').toString();
    final lines = <String>[
      if (who.isNotEmpty) who,
      if (address.isNotEmpty) 'Address: $address',
      if ((c['enquiry_email'] ?? '').toString().isNotEmpty)
        'Enquiries to ${c['enquiry_email']}',
      if ((c['space_website'] ?? '').toString().isNotEmpty)
        'Website given: ${c['space_website']}',
      if ((c['space_instagram'] ?? '').toString().isNotEmpty)
        'Instagram given: ${c['space_instagram']}',
      if ((c['note'] ?? '').toString().isNotEmpty) 'Note: ${c['note']}',
    ];
    return _card(
      tint: free ? Brand.successTint : Brand.goldTint,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: free ? Brand.success : Brand.goldTextDark,
                borderRadius: BorderRadius.circular(8)),
            child: Text(free ? 'FREE CLAIM, APPROVE?' : 'PAID, APPROVE?',
                style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                    color: Colors.white)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(spaceName,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ]),
        if (where.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(where,
                style: const TextStyle(
                    fontSize: 12.5, color: Brand.inkSecondary)),
          ),
        const SizedBox(height: 8),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(l, style: const TextStyle(fontSize: 12.5)),
          ),
        const SizedBox(height: 6),
        Row(children: [
          Icon(match ? Icons.verified_user_outlined : Icons.help_outline,
              size: 16, color: match ? Brand.success : Brand.goldTextDark),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                match
                    ? 'Email domain matches the space\'s website.'
                    : site.isEmpty
                        ? 'No website on file to check the email against.'
                        : 'Email domain does not match the website (${host(site)}). '
                            'Common with Gmail; worth a look.',
                style: TextStyle(
                    fontSize: 12,
                    color: match ? Brand.success : Brand.goldTextDark)),
          ),
        ]),
        if (placeId.isNotEmpty) _ownerCheck(c, placeId),
        if (previous.isNotEmpty && previous != email)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Careful: this page already has an owner on file '
                '($previous).',
                style: const TextStyle(fontSize: 12, color: Brand.red)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              free
                  ? 'Free claim ${_ago(c['created_at'])} through the claim '
                      'form. Approving records them as the owner of the page; '
                      'the plan stays free and nothing visible changes.'
                      '${newSpace ? ' A space not on the map yet: approving creates it in the publishing queue.' : ''}'
                  : 'Paid${_paidAmount(c)} ${_ago(c['paid_at'] ?? c['created_at'])} '
                      'through the claim form. Nothing on the page has changed yet.',
              style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed: () => _approveClaim(c, spaceName),
              style: FilledButton.styleFrom(backgroundColor: Brand.success),
              icon: const Icon(Icons.check, size: 18),
              label: Text(free
                  ? 'Approve, they own the page'
                  : 'Approve, make it Verified')),
          TextButton(
              onPressed: () => _rejectClaim(c, spaceName),
              child: const Text('Reject')),
          if ((v['name'] ?? '').toString().isNotEmpty)
            TextButton(
                onPressed: () => _openVenue({'id': c['venue_id']}),
                child: const Text('Open the space')),
        ]),
        const SizedBox(height: 4),
        // Look them up before deciding: their Google listing (the
        // search result with the business panel, not the map), their
        // Instagram, and a way to write back.
        Wrap(spacing: 4, runSpacing: 0, children: [
          _lookupButton(Icons.search, 'Google',
              'https://www.google.com/search?q='
              '${Uri.encodeQueryComponent('$spaceName ${where.isNotEmpty ? where : ''}'.trim())}'),
          if (placeId.isNotEmpty)
            _lookupButton(Icons.map_outlined, 'Map',
                'https://www.google.com/maps/place/?q=place_id:$placeId'),
          if (insta.isNotEmpty)
            _lookupButton(Icons.camera_alt_outlined, 'Instagram',
                _instagramUrl(insta)),
          if (site.isNotEmpty)
            _lookupButton(Icons.language, 'Website', _withScheme(site)),
          if (email.isNotEmpty)
            _lookupButton(Icons.mail_outline, 'Email',
                'mailto:$email?subject=${Uri.encodeComponent('Your $spaceName listing on nomadwise.io')}'),
          // Opens the chat with the question already typed, to edit
          // or send (Jonathan's wording, 5 Oct 2026). The number is
          // the one given on the claim form.
          if (claimWa != null)
            _lookupButton(Icons.chat_outlined, 'WhatsApp',
                'https://wa.me/$claimWa?text=${Uri.encodeComponent(_claimHello(c, spaceName))}'),
        ]),
      ]),
    );
  }

  /// The first message to someone who has claimed a page: who we are,
  /// who claimed which page, and one easy question.
  static String _claimHello(Map<String, dynamic> c, String spaceName) {
    final name = (c['owner_name'] ?? '').toString().trim();
    return 'Hi, this is Jonathan from nomadwise.io. '
        '${name.isEmpty ? 'Someone' : 'Someone called $name'} has just '
        'claimed the $spaceName page on our directory. Is that you, or '
        'someone from your team? A quick yes is all we need before we '
        'hand over the page. Thanks!';
  }

  Widget _lookupButton(IconData icon, String label, String url) =>
      TextButton.icon(
        onPressed: () => launchUrl(Uri.parse(url),
            mode: LaunchMode.platformDefault, webOnlyWindowName: '_blank'),
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: TextButton.styleFrom(
            foregroundColor: Brand.inkSecondary,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            textStyle:
                const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
      );

  static String _withScheme(String u) =>
      u.startsWith('http') ? u : 'https://$u';

  /// A number WhatsApp can open (digits with the country code), or
  /// null. Numbers typed without a country code get the space's one.
  static String? _waNumber(String? raw, String? country) {
    final t = (raw ?? '').trim();
    if (t.isEmpty) return null;
    final link = RegExp(r'wa\.me/\+?(\d+)').firstMatch(t);
    if (link != null) return link.group(1);
    final digits = t.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 6) return null;
    if (t.startsWith('+')) return digits;
    if (digits.startsWith('00')) return digits.substring(2);
    final iso = PhoneField.isoFor(country);
    final code = PhoneField.dialFor(iso);
    if (code == null) return digits;
    if (digits.startsWith('$code') && !digits.startsWith('0') &&
        digits.length >= 10) {
      return digits; // already has the country code, just no "+"
    }
    return PhoneField.compose(iso, digits).replaceAll(RegExp(r'\D'), '');
  }

  /// WhatsApp buttons for a space: the person who claimed it (their
  /// phone from the claim form) and, when it is a different number,
  /// the WhatsApp on the page. Each opens a chat with a short hello
  /// already typed, to edit or send.
  List<Widget> _whatsappButtons({
    required String venueId,
    required String space,
    String? country,
    String? pagePhone,
  }) {
    final (name, phone) = _ownerContact[venueId] ?? ('', '');
    final person = _waNumber(phone, country);
    final page = _waNumber(pagePhone, country);
    final first = name.split(RegExp(r'\s+')).first;
    Widget button(String label, String number, String hello) =>
        OutlinedButton.icon(
          onPressed: () => launchUrl(
              Uri.parse('https://wa.me/$number?text='
                  '${Uri.encodeQueryComponent(hello)}'),
              mode: LaunchMode.platformDefault,
              webOnlyWindowName: '_blank'),
          style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF128C7E),
              side: const BorderSide(color: Color(0xFF25D366))),
          icon: const Icon(Icons.chat_outlined, size: 17),
          label: Text(label),
        );
    return [
      if (person != null)
        button(first.isEmpty ? 'WhatsApp the owner' : 'WhatsApp $first',
            person,
            "Hi${first.isEmpty ? '' : ' $first'}, it's Jonathan from "
                'Nomadwise, about the $space page. '),
      if (page != null && page != person)
        button('WhatsApp the space', page,
            "Hi, it's Jonathan from Nomadwise, about the $space page. "),
    ];
  }

  /// "@kopi_club" or a full link, either way a link.
  static String _instagramUrl(String raw) {
    final t = raw.trim();
    if (t.startsWith('http')) return t;
    return 'https://www.instagram.com/${t.replaceFirst('@', '')}';
  }

  Future<void> _approveClaim(Map<String, dynamic> c, String spaceName) async {
    try {
      await _supabase.approveClaim(c['id']);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(c['status'] == 'free_pending'
              ? '$spaceName: owner recorded. The plan stays free.'
              : '$spaceName is now Verified. The page updates at '
                  'the next push.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That did not approve: $e'),
          backgroundColor: Brand.red));
    }
  }

  Future<void> _rejectClaim(Map<String, dynamic> c, String spaceName) async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reject the claim on $spaceName?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              c['status'] == 'free_pending'
                  ? 'The page stays exactly as it is. Nothing to refund. '
                      'The reason is kept with the claim so a repeat is '
                      'recognised.'
                  : 'The page stays exactly as it is. Refund the payment in the '
                      'Stripe dashboard (Customers, then the subscription, then '
                      'Cancel and refund). The reason is kept with the claim so a '
                      'repeat is recognised.',
              style: const TextStyle(fontSize: 13.5, height: 1.4)),
          const SizedBox(height: 14),
          TextField(
              controller: ctl,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                  labelText: 'Reason',
                  hintText: 'Wrong space, not the owner, does not fit...',
                  border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              child: const Text('Reject')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _supabase.rejectClaim(c['id'], ctl.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(c['status'] == 'free_pending'
              ? 'Rejected.'
              : 'Rejected. Remember the refund in Stripe.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That did not reject: $e'),
          backgroundColor: Brand.red));
    }
  }

  /// A claim form that was filled in but not paid (yet). The owner
  /// told us who they are and which space; worth a nudge by hand.
  /// The way into the email log: what went to owners, and what
  /// Postmark said about each.
  Widget _emailsCard() => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border),
        ),
        child: ListTile(
          leading: const Icon(Icons.mail_outline, color: Brand.accent),
          title: const Text('Emails to owners',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          subtitle: const Text(
              'Every email the system sent an owner, and whether Postmark '
              'accepted it. Send yourself a test.',
              style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
          trailing: const Icon(Icons.chevron_right, color: Brand.inkMuted),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const EmailLogScreen())),
        ),
      );

  /// The way into What owners tell us: answers to the quick questions
  /// in the Owner account.
  Widget _insightsCard() => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border),
        ),
        child: ListTile(
          leading: const Icon(Icons.insights_outlined, color: Brand.accent),
          title: const Text('What owners tell us',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          subtitle: const Text(
              'What owners voted for us to build next, their own ideas, and '
              'their answers to the quick questions: how people find them, '
              'what they would pay for, monthly or yearly.',
              style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
          trailing: const Icon(Icons.chevron_right, color: Brand.inkMuted),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const OwnerInsightsScreen())),
        ),
      );

  /// The way into Suggested updates: what visitors told us has changed.
  Widget _updatesCard() => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: _updates.isEmpty ? Brand.border : Brand.goldTextDark),
        ),
        child: ListTile(
          leading: const Icon(Icons.edit_note, color: Brand.accent),
          title: Text(
              _updates.isEmpty
                  ? 'Suggested updates'
                  : 'Suggested updates (${_updates.length} open)',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          subtitle: const Text(
              'What visitors told us has changed at a space. Fix the page, '
              'then mark it done, or dismiss it.',
              style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
          trailing: const Icon(Icons.chevron_right, color: Brand.inkMuted),
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ListingUpdatesScreen()));
            _load();
          },
        ),
      );

  /// Any listing's Owner account, as its owner would see it, in a
  /// preview that saves nothing: to judge and improve the member area.
  /// Everything between us and this space's owner, newest first.
  void _openTrail(String venueId, String name) => Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => SpaceTrailScreen(venueId: venueId, name: name)));

  void _openOwnerPreview(String key) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => OwnerScreen(previewKey: key)));

  Widget _previewCard() => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border),
        ),
        child: ListTile(
          leading: const Icon(Icons.visibility_outlined, color: Brand.accent),
          title: const Text('See any Owner account',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          subtitle: const Text(
              'Open the member area for any listing, claimed or not, as '
              'its owner would see it: waiting for the check, free or '
              'Verified. A preview; nothing is saved.',
              style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
          trailing: const Icon(Icons.chevron_right, color: Brand.inkMuted),
          onTap: _pickOwnerPreview,
        ),
      );

  Future<void> _pickOwnerPreview() async {
    final picked = await showDialog<String>(
        context: context, builder: (_) => _PreviewPicker(supabase: _supabase));
    if (picked != null && mounted) _openOwnerPreview(picked);
  }

  /// The way into Claim journeys: every visit to the claim page, step
  /// by step, and where it stopped.
  Widget _journeysCard() => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border),
        ),
        child: ListTile(
          leading: const Icon(Icons.route_outlined, color: Brand.accent),
          title: const Text('Claim journeys',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          subtitle: const Text(
              'Every visit to the claim page: what they did, how far they '
              'got, where they stopped.',
              style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
          trailing: const Icon(Icons.chevron_right, color: Brand.inkMuted),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const ClaimJourneysScreen())),
        ),
      );

  Widget _startedCard(Map<String, dynamic> c) {
    final space = (c['space_name'] ?? '').toString().isNotEmpty
        ? c['space_name']
        : 'Space not named';
    final where = [
      if ((c['space_city'] ?? '').toString().isNotEmpty) c['space_city'],
      if ((c['space_country'] ?? '').toString().isNotEmpty)
        c['space_country'],
    ].join(', ');
    final who = [
      if ((c['owner_name'] ?? '').toString().isNotEmpty) c['owner_name'],
      if ((c['owner_role'] ?? '').toString().isNotEmpty) c['owner_role'],
      if ((c['owner_email'] ?? '').toString().isNotEmpty) c['owner_email'],
      if ((c['owner_phone'] ?? '').toString().isNotEmpty) c['owner_phone'],
    ].join('  ·  ');
    final extra = [
      if ((c['enquiry_email'] ?? '').toString().isNotEmpty)
        'Enquiries to: ${c['enquiry_email']}',
      if ((c['space_website'] ?? '').toString().isNotEmpty)
        'Website: ${c['space_website']}',
      if ((c['space_instagram'] ?? '').toString().isNotEmpty)
        'Instagram: ${c['space_instagram']}',
      if ((c['note'] ?? '').toString().isNotEmpty) 'Note: ${c['note']}',
    ];
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: Brand.inkSecondary,
                borderRadius: BorderRadius.circular(8)),
            child: const Text('STARTED, NOT PAID',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                    color: Colors.white)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(space,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ]),
        if (where.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(where,
                style: const TextStyle(
                    fontSize: 12, color: Brand.inkSecondary)),
          ),
        const SizedBox(height: 8),
        if (who.isNotEmpty)
          Text(who, style: const TextStyle(fontSize: 12.5)),
        for (final line in extra)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(line, style: const TextStyle(fontSize: 12.5)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              'Filled in the claim form ${_ago(c['created_at'])} and stopped '
              'at payment. '
              '${c['is_new_space'] == true ? 'A space not on the map yet. ' : ''}'
              'Nothing on the site changes until they pay.',
              style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if ((c['owner_email'] ?? '').toString().isNotEmpty)
            OutlinedButton.icon(
                onPressed: () => launchUrl(
                    Uri.parse('mailto:${c['owner_email']}'
                        '?subject=${Uri.encodeComponent('Your $space listing on nomadwise.io')}'),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.mail_outline, size: 18),
                label: const Text('Email them')),
          if (c['venue_id'] != null)
            OutlinedButton.icon(
                onPressed: () => _openVenue({'id': c['venue_id']}),
                icon: const Icon(Icons.storefront_outlined, size: 18),
                label: const Text('Open the space')),
          TextButton(
              onPressed: () async {
                await _supabase.abandonClaim('${c['id']}');
                _load();
              },
              child: const Text('Dismiss')),
        ]),
        if (space != 'Space not named') ...[
          const SizedBox(height: 4),
          Wrap(spacing: 4, children: [
            _lookupButton(Icons.search, 'Google',
                'https://www.google.com/search?q='
                '${Uri.encodeQueryComponent('$space $where'.trim())}'),
            if ((c['space_instagram'] ?? '').toString().isNotEmpty)
              _lookupButton(Icons.camera_alt_outlined, 'Instagram',
                  _instagramUrl(c['space_instagram'].toString())),
          ]),
        ],
      ]),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    final who = [
      if ((o['name'] ?? '').toString().isNotEmpty) o['name'],
      if ((o['email'] ?? '').toString().isNotEmpty) o['email'],
    ].join('  ·  ');
    return _card(
      tint: Brand.goldTint,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: Brand.goldTextDark,
                borderRadius: BorderRadius.circular(8)),
            child: const Text('PAID, NEEDS MATCHING',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                    color: Colors.white)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(o['space_name'] ?? 'Space not named',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ]),
        const SizedBox(height: 8),
        if (who.isNotEmpty)
          Text(who, style: const TextStyle(fontSize: 12.5)),
        if ((o['space_link'] ?? '').toString().isNotEmpty)
          InkWell(
            onTap: () => launchUrl(Uri.parse('${o['space_link']}'),
                mode: LaunchMode.externalApplication),
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('${o['space_link']}',
                  style: const TextStyle(
                      fontSize: 12,
                      color: Brand.accent,
                      decoration: TextDecoration.underline)),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
              '${o['currency'] ?? ''} ${(o['amount'] ?? 0).toString()} paid '
              '${_ago(o['created_at'])}. Not matched to a space yet: search '
              'for it below, or add it as a new space first and then attach.',
              style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed: () => _attachOrder(o),
              icon: const Icon(Icons.link, size: 18),
              label: const Text('Attach to a space')),
          TextButton(
              onPressed: () async {
                await _supabase.ignoreStripeOrder(o['id']);
                await _load();
              },
              child: const Text('Ignore')),
        ]),
      ]),
    );
  }

  Future<void> _attachOrder(Map<String, dynamic> o) async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        builder: (_) => _VenueSearchSheet(
            supabase: _supabase, initial: o['space_name'] ?? ''));
    if (picked == null) return;
    try {
      await _supabase.attachStripeOrder(o['id'], picked['id']);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${picked['name']} is now Verified. The page '
              'updates within a minute or two.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That did not attach: $e'),
          backgroundColor: Brand.red));
    }
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

  /// On a page with an owner on record: who they are and what they
  /// told us on the claim form (hours, rooms, sockets...), so the
  /// person publishing the page can put it on without asking twice.
  Widget _ownerNote(Map<String, dynamic> v) {
    final owner = (v['listing_owner_name'] ?? '').toString();
    final email = (v['listing_owner_email'] ?? '').toString();
    final notes = (v['listing_notes'] ?? '').toString().trim();
    if (owner.isEmpty && email.isEmpty && notes.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
          color: Brand.successTint, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            'OWNER ON RECORD'
            '${v['listing_tier'] == 'verified' ? '  ·  VERIFIED' : '  ·  FREE'}',
            style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .5,
                color: Brand.success)),
        if (owner.isNotEmpty || email.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text([owner, email].where((x) => x.isNotEmpty).join('  ·  '),
                style: const TextStyle(fontSize: 12.5)),
          ),
        if (notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(notes,
                style: const TextStyle(
                    fontSize: 12.5, color: Brand.inkSecondary, height: 1.4)),
          ),
      ]),
    );
  }

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
        _ownerNote(v),
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
            // A space that asked to be listed: the plan page holds the
            // owner's details and the ready-made Verified offer.
            TextButton(
                onPressed: () => _editPlan(v),
                style: TextButton.styleFrom(foregroundColor: Brand.inkSecondary),
                child: const Text('Plan')),
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
    // Is the space's country on the site at all? A Region sits inside a
    // Country, so when both are missing the Country comes first; say so
    // rather than only "no Region".
    final country = (v['country'] ?? '').toString().trim();
    final countryMissing = country.isNotEmpty &&
        _countries.isNotEmpty &&
        !_countries.any((c) =>
            '${c['name']}'.trim().toLowerCase() == country.toLowerCase());
    final place = (v['city'] ?? v['neighbourhood'] ?? 'this city').toString();
    final why = awaiting != null
        ? 'Waiting for $awaiting to be created in Webflow. Once it exists '
            'with that exact name, the space is linked to it automatically '
            'and moves on. Or pick an existing one instead.'
        : countryMissing
        ? 'Neither $country nor a Region for "$place" is on nomadwise.io '
            'yet. Create the Country first, then the $place Region inside '
            'it; the space moves on once it has both.'
        : p['why'] ??
            'No Region on nomadwise.io matches "${v['city'] ?? v['neighbourhood'] ?? 'this city'}". '
                'A page needs a Country and a Region, and the slug is built '
                'from the Region, so nothing can be prepared or created until '
                'you pick one.';
    return _card(
      tint: Brand.goldTint,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(v,
            badge: countryMissing && awaiting == null
                ? 'COUNTRY + REGION'
                : 'REGION',
            badgeColor: Brand.goldTextDark),
        _ownerNote(v),
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
          else if (countryMissing) ...[
            OutlinedButton.icon(
                onPressed: _newRegion,
                icon: const Icon(Icons.map_outlined, size: 18),
                label: Text('2. New Region: $place')),
            ElevatedButton.icon(
                onPressed: _newCountry,
                icon: const Icon(Icons.public, size: 18),
                label: Text('1. Create $country')),
          ]
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
        _ownerNote(v),
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
                      '${p['location_chosen'] == true ? ' (your choice)' : (p['location_note'] is Map && (p['location_note'] as Map)['verdict'] == 'assign') ? ' (its area\'s name and the places nearby agree)' : ' (guessed, check it)'}'
                      '  ·  tap to change',
              muted: p['location'] == null && p['location_chosen'] != true),
        ),
        ..._locationHint(v, p),
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
            {VoidCallback? onTap, IconData icon = Icons.expand_more}) =>
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
                  Icon(icon, size: 14, color: Brand.inkMuted),
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
      // The listed places around it, coloured by Location (migration
      // 155): the quickest way to see where it belongs.
      cell('NEARBY', 'On a map', Brand.logoNavy,
          onTap: () => _openNearby(v), icon: Icons.map_outlined),
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

  Future<void> _startPushRun() async {
    String msg;
    try {
      final r = await _supabase.requestWebsitePush();
      msg = r == 'requested'
          ? 'Run requested. GitHub starts it within a minute; pull down '
              'to refresh in a few minutes.'
          : 'No GitHub token in the Supabase Vault (github_actions_token), '
              'so the run has to be started on GitHub: Actions, Website '
              'push, Run workflow.';
    } catch (e) {
      msg = 'Could not request the run: $e';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

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
            'Approving starts a run on GitHub that builds the Webflow '
            'draft and its Images entry, usually within a few minutes. '
            'Pull down to refresh. Still here after ten minutes? Start '
            'the run again.'),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: OutlinedButton.icon(
              onPressed: _startPushRun,
              icon: const Icon(Icons.play_arrow_outlined, size: 18),
              label: const Text('Start the run now')),
        ),
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
  final _searchCtl = TextEditingController();

  /// Search runs against the whole database, not the newest 300 the
  /// screen holds, so any page can be found however long the list gets.
  Timer? _searchTimer;
  List<Map<String, dynamic>>? _searchHits;
  bool _searching = false;

  void _releasedSearch(String text) {
    setState(() => _search = text);
    _searchTimer?.cancel();
    final q = text.trim();
    if (q.length < 2) {
      setState(() {
        _searchHits = null;
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _searchTimer = Timer(const Duration(milliseconds: 400), () async {
      final hits = await _supabase.websiteReleasedSearch(q);
      if (!mounted || _search.trim() != q) return;
      setState(() {
        _searchHits = hits;
        _searching = false;
      });
    });
  }

  Widget _releasedTab() {
    final q = _search.trim();
    final rows = q.length < 2 ? _released : (_searchHits ?? const []);
    return ListView(padding: const EdgeInsets.all(14), children: [
      TextField(
        controller: _searchCtl,
        decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search every released page',
            filled: true,
            fillColor: Brand.field,
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      _searchCtl.clear();
                      _releasedSearch('');
                    }),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none)),
        onChanged: _releasedSearch,
      ),
      const SizedBox(height: 6),
      Text(
          q.length < 2
              ? '${_released.length} newest released page'
                  '${_released.length == 1 ? '' : 's'}. Search to find any '
                  'of the others.'
              : _searching
                  ? 'Searching every released page...'
                  : '${rows.length} match${rows.length == 1 ? '' : 'es'}'
                      '${rows.length >= 100 ? ' (first 100)' : ''}',
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
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(
                  onPressed: () => _editPlan(v),
                  child: Text(
                      v['listing_tier'] == 'verified' ? 'Verified' : 'Plan',
                      style: TextStyle(
                          fontSize: 12,
                          color: v['listing_tier'] == 'verified'
                              ? Brand.success
                              : Brand.inkSecondary))),
              const Icon(Icons.open_in_new, size: 16),
            ]),
            onTap: () => launchUrl(
                Uri.parse(
                    'https://www.nomadwise.io/coworking/${v['webflow_slug']}'),
                mode: LaunchMode.externalApplication),
          )),
      if (rows.isEmpty && !_searching)
        Padding(
          padding: const EdgeInsets.all(30),
          child: Text(
              q.length < 2 ? 'Nothing released yet.' : 'Nothing matches.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Brand.inkMuted)),
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
  // For a page that is already live (Page upgrades): its photos sit
  // in the slots, the aim is five, and saving sends them to the page.
  final bool livePage;
  const _PhotosPage(
      {required this.name,
      required this.searchText,
      required this.initial,
      this.candidates = const [],
      this.placeId,
      this.livePage = false});
  @override
  State<_PhotosPage> createState() => _PhotosPageState();
}

/// The photos page for a listing that is already on nomadwise.io
/// (Page upgrades): [current] are the photos on it now, in page order.
/// Returns the links to put on the page, or null when it was closed
/// without saving.
Future<List<String>?> openLivePagePhotos(BuildContext context,
        {required String name,
        required String searchText,
        String? placeId,
        List<String> current = const []}) =>
    Navigator.push<List<String>>(
        context,
        MaterialPageRoute(
            builder: (_) => _PhotosPage(
                name: name,
                searchText: searchText,
                placeId: placeId,
                initial: current,
                livePage: true)));

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
                  widget.livePage
                      ? 'The photos on the page now are in the slots. Open '
                          'the place on Google, right-click a photo, choose '
                          '"Copy image address", and paste it into a free '
                          'slot. A page holds five; the first one is the '
                          'main picture.'
                      : widget.candidates.isEmpty
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
                widget.livePage
                    ? (n >= 5
                        ? 'Five photos. The page is full.'
                        : '$n of 5. You can save now and add the rest later.')
                    : n >= _WebsiteScreenState.minPhotos
                        ? '$n photos. Enough to approve.'
                        : '$n of ${_WebsiteScreenState.minPhotos} needed.',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: n >= (widget.livePage ? 5 : _WebsiteScreenState.minPhotos)
                        ? Brand.success
                        : Brand.goldTextDark)),
            const SizedBox(height: 10),
            ElevatedButton.icon(
                onPressed: () => Navigator.pop(context, _urls),
                icon: const Icon(Icons.check, size: 18),
                label: Text(widget.livePage
                    ? 'Save and send to the page'
                    : 'Save photos')),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }
}


// ------------------------------------------------------------ listing plan

/// Free or Verified, the owner, where enquiries go, and the dates.
/// Saving asks the sync to write the page's fields within minutes;
/// nothing else about the page changes.
class _ListingPlanPage extends StatefulWidget {
  final SupabaseService supabase;
  final Map<String, dynamic> venue;
  const _ListingPlanPage({required this.supabase, required this.venue});
  @override
  State<_ListingPlanPage> createState() => _ListingPlanPageState();
}

class _ListingPlanPageState extends State<_ListingPlanPage> {
  late String _tier = widget.venue['listing_tier'] ?? 'free';
  late final _ownerName =
      TextEditingController(text: widget.venue['listing_owner_name'] ?? '');
  late final _ownerEmail =
      TextEditingController(text: widget.venue['listing_owner_email'] ?? '');
  late final _enquiryEmail = TextEditingController(
      text: widget.venue['listing_enquiry_email'] ?? '');
  late final _notes =
      TextEditingController(text: widget.venue['listing_notes'] ?? '');
  late DateTime? _paid = _parse(widget.venue['listing_paid_at']);
  late DateTime? _renews = _parse(widget.venue['listing_renews_at']);
  bool _busy = false;

  // What Verified costs for this space's country (migration 115).
  PricingChoice? _pricing;

  @override
  void initState() {
    super.initState();
    widget.supabase.pricingFor('${widget.venue['country'] ?? ''}').then((p) {
      if (mounted && p != null) setState(() => _pricing = PricingChoice(p));
    });
  }

  /// The claim page for this space: it shows the price for its country,
  /// monthly or yearly, and takes the owner to Stripe. The owner's
  /// email is pre-filled when known.
  String get _payLink {
    final v = widget.venue;
    final email = _ownerEmail.text.trim();
    return 'https://nomadmaps.io/?claim='
        '${Uri.encodeQueryComponent('${v['webflow_slug'] ?? v['name'] ?? ''}')}'
        '${email.contains('@') ? '&email=${Uri.encodeQueryComponent(email)}' : ''}';
  }

  /// "10 EUR a month or 99 EUR a year", for the offer email.
  String get _priceWords {
    final p = _pricing;
    if (p == null || p.monthly == null || p.yearly == null) {
      return '99 EUR a year';
    }
    return '${formatMoney(p.monthly!, p.currency)} a month or '
        '${formatMoney(p.yearly!, p.currency)} a year';
  }

  /// The Verified offer, ready to paste into Gmail. It says what the
  /// claim page says (Free keeps its own photos, words and passed-on
  /// enquiries; Verified adds four things), so it reads right to an
  /// owner who has already claimed for free as well as to one who has
  /// not. The page is linked only once it is live (the same rule as
  /// the owner emails, migration 108): a draft's address opens nothing.
  /// Body text says "Nomadwise", never the web address, which mail
  /// apps would turn into a link to the homepage (EMAIL_STYLE.md).
  String get _offerEmail {
    final v = widget.venue;
    final name = v['name'] ?? 'your space';
    final city = (v['city'] ?? '').toString().trim();
    final hood = (v['neighbourhood'] ?? '').toString().trim();
    final slug = (v['webflow_slug'] ?? '').toString().trim();
    final page = slug.isNotEmpty && v['website_status'] == 'released'
        ? 'https://www.nomadwise.io/coworking/$slug'
        : null;
    final who = _ownerName.text.trim().isEmpty ? 'there' : _ownerName.text.trim();
    final where = city.isEmpty
        ? 'your city'
        : (hood.isEmpty || hood.toLowerCase() == city.toLowerCase())
            ? city
            : '$hood and across $city';
    final months = _pricing?.monthsFree.round() ?? 0;
    final saving =
        months >= 1 ? ' ($months month${months == 1 ? '' : 's'} free)' : '';
    return [
      'Subject: $name on Nomadwise',
      '',
      'Hi $who,',
      '',
      if (page != null)
        '$name has a free page on Nomadwise: $page'
      else
        '$name has a free page on Nomadwise. It is being built now, and '
            'the link follows as soon as it is live.',
      '',
      'The free page stays free. Through your Owner account you can '
          "update your listing's details and add or change your own "
          'photos and description, and we pass on any enquiries that '
          'come in.',
      '',
      'Verified adds four things:',
      '',
      '- The green Verified badge on your page and in every list',
      '- A place above every free space in $where',
      '- Enquiries straight to your inbox from the button on your '
          'page, with no commission',
      '- Your own event or offer in the advert slot on your page',
      '',
      'It is $_priceWords$saving. Cancel any time.',
      '',
      'Get Verified: $_payLink',
      '',
      'Any questions, just reply to this email.',
      '',
      'Jonathan',
      'Nomadwise',
    ].join('\n');
  }

  Future<void> _copy(String text, String toast) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(toast), duration: const Duration(seconds: 2)));
  }

  static DateTime? _parse(String? s) => s == null ? null : DateTime.tryParse(s);
  static String _fmt(DateTime? d) =>
      d == null ? 'Not set' : DateFormat('d MMM yyyy').format(d);
  static String? _iso(DateTime? d) =>
      d == null ? null : DateFormat('yyyy-MM-dd').format(d);

  Future<void> _pickDate(bool paid) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
        context: context,
        initialDate: (paid ? _paid : _renews) ?? now,
        firstDate: DateTime(2024),
        lastDate: DateTime(now.year + 3));
    if (picked == null) return;
    setState(() {
      if (paid) {
        _paid = picked;
        // A year from payment unless the renewal was set by hand.
        _renews ??= DateTime(picked.year + 1, picked.month, picked.day);
      } else {
        _renews = picked;
      }
    });
  }

  Future<void> _save() async {
    final enquiry = _enquiryEmail.text.trim();
    if (_tier == 'verified' && enquiry.isNotEmpty && !enquiry.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The enquiry address does not look like an email.')));
      return;
    }
    if (_tier == 'verified' && _paid == null) {
      // Paid today unless told otherwise; the renewal follows.
      final now = DateTime.now();
      _paid = DateTime(now.year, now.month, now.day);
      _renews ??= DateTime(now.year + 1, now.month, now.day);
    }
    setState(() => _busy = true);
    try {
      await widget.supabase.updateVenueFields(widget.venue['id'], {
        'listing_tier': _tier,
        'listing_owner_name':
            _ownerName.text.trim().isEmpty ? null : _ownerName.text.trim(),
        'listing_owner_email':
            _ownerEmail.text.trim().isEmpty ? null : _ownerEmail.text.trim(),
        'listing_enquiry_email': enquiry.isEmpty ? null : enquiry,
        'listing_notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        'listing_paid_at': _tier == 'verified' ? _iso(_paid) : null,
        'listing_renews_at': _tier == 'verified' ? _iso(_renews) : null,
        // Asks the sync to write the page's fields; cleared once done.
        'listing_sync_requested_at': DateTime.now().toUtc().toIso8601String(),
        'listing_synced_at': null,
        'listing_sync_error': null,
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

  /// Takes the owner off this space: Free plan, no owner, claim closed,
  /// waiting changes dropped. The page itself is left as it is.
  Future<void> _removeOwner() async {
    final v = widget.venue;
    final who = (v['listing_owner_email'] ?? '').toString().trim();
    final hasSub = (v['stripe_subscription_id'] ?? '').toString().isNotEmpty;
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove the owner?'),
        content: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${who.isEmpty ? 'The owner' : who} will no longer run '
                    '${v['name'] ?? 'this space'}. The plan goes back to '
                    'Free, their claim is closed and any changes waiting '
                    'for review are dropped. No email is sent.',
                    style: const TextStyle(fontSize: 13.5, height: 1.45)),
                const SizedBox(height: 8),
                const Text(
                    'The page stays as it is: a live page stays live, a '
                    'draft stays a draft.',
                    style: TextStyle(
                        fontSize: 13, height: 1.45, color: Brand.inkSecondary)),
                if (hasSub) ...[
                  const SizedBox(height: 8),
                  const Text(
                      'They have a Stripe subscription. It keeps running '
                      'until you cancel it in Stripe.',
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          fontWeight: FontWeight.w600,
                          color: Brand.goldTextDark)),
                ],
                const SizedBox(height: 12),
                TextField(
                    controller: note,
                    decoration: const InputDecoration(
                        labelText: 'Why (optional, kept in the notes)')),
              ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove owner')),
        ],
      ),
    );
    final why = note.text.trim();
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.supabase.removeOwner(widget.venue['id'],
          note: why.isEmpty ? null : why);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Owner removed. The page is now a free listing.')));
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('That did not work: $e'),
            backgroundColor: Brand.red));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    final onSite = v['webflow_cms_id'] != null;
    final hasOwner =
        (v['listing_owner_email'] ?? '').toString().trim().isNotEmpty ||
            v['listing_tier'] == 'verified';
    return Scaffold(
      appBar: AppBar(title: Text(v['name'] ?? 'Listing plan')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Text(
                'Verified is the paid plan: the badge on the page and the '
                'map pin, a place above every free listing in its city and '
                'area, and the '
                'Send an enquiry button sending enquiries to the address '
                'below. Saving updates the page within a minute or two.',
                style: TextStyle(
                    fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
            if (!onSite)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                    'This space has no page on nomadwise.io yet. The plan is '
                    'kept and written to the page once it exists.',
                    style: TextStyle(fontSize: 12.5, color: Brand.goldTextDark)),
              ),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'free', label: Text('Free')),
                ButtonSegment(
                    value: 'verified',
                    label: Text('Verified'),
                    icon: Icon(Icons.verified, size: 16)),
              ],
              selected: {_tier},
              onSelectionChanged: (s) => setState(() => _tier = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
                controller: _ownerName,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Owner or contact name (optional)')),
            const SizedBox(height: 12),
            TextField(
                controller: _ownerEmail,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'Owner email (billing, reports)')),
            const SizedBox(height: 12),
            TextField(
                controller: _enquiryEmail,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'Enquiry email (enquiries go here)',
                    helperText:
                        'Leave empty to send them to hello@nomadwise.io.',
                    helperMaxLines: 2)),
            if (_tier == 'verified') ...[
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _pickDate(true),
                    borderRadius: BorderRadius.circular(12),
                    child: InputDecorator(
                        decoration: const InputDecoration(
                            labelText: 'Paid on',
                            suffixIcon: Icon(Icons.event, size: 18)),
                        child: Text(_fmt(_paid))),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: () => _pickDate(false),
                    borderRadius: BorderRadius.circular(12),
                    child: InputDecorator(
                        decoration: const InputDecoration(
                            labelText: 'Renews on',
                            suffixIcon: Icon(Icons.event, size: 18)),
                        child: Text(_fmt(_renews))),
                  ),
                ),
              ]),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                    'Renewal is a year after payment unless you set it. '
                    'Once Stripe is connected these fill in on their own.',
                    style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
                controller: _notes,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    hintText: 'How they came in, what was agreed, invoice number.',
                    alignLabelWithHint: true)),
            const SizedBox(height: 20),
            FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.check, size: 18),
                label: Text(_busy ? 'Saving' : 'Save plan')),
            if (_tier != 'verified') ...[
              const SizedBox(height: 28),
              const SectionLabel('Sell Verified'),
              const SizedBox(height: 6),
              Text(
                  'The claim link opens this space\'s claim page, which shows '
                  'the price for its country'
                  '${_pricing != null ? ' (group ${_pricing!.pricing['group']}, $_priceWords)' : ''}'
                  ', monthly or yearly, and takes the owner to payment. '
                  'The offer email has the name, city and link filled in; '
                  'paste it into Gmail and send.',
                  style: TextStyle(
                      fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                    onPressed: () => _copy(_payLink, 'Claim link copied'),
                    icon: const Icon(Icons.link, size: 16),
                    label: const Text('Copy claim link')),
                OutlinedButton.icon(
                    onPressed: () => _copy(_offerEmail, 'Offer email copied'),
                    icon: const Icon(Icons.mail_outline, size: 16),
                    label: const Text('Copy offer email')),
              ]),
            ],
            if (hasOwner) ...[
              const SizedBox(height: 28),
              const SectionLabel('Remove owner'),
              const SizedBox(height: 6),
              const Text(
                  'For a test account, a space that changed hands, or a '
                  'claim by the wrong person. The page stays; the owner, '
                  'their claim and their waiting changes go.',
                  style: TextStyle(
                      fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Brand.red,
                        side: BorderSide(color: Brand.red.withValues(alpha: .5))),
                    onPressed: _busy ? null : _removeOwner,
                    icon: const Icon(Icons.person_remove_outlined, size: 16),
                    label: const Text('Remove owner')),
              ),
            ],
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }
}


// ------------------------------------------------------------ venue search

/// Any space by name, from the whole database (not only the lists the
/// control centre has loaded), for attaching a payment.
class _VenueSearchSheet extends StatefulWidget {
  final SupabaseService supabase;
  final String initial;
  const _VenueSearchSheet({required this.supabase, required this.initial});
  @override
  State<_VenueSearchSheet> createState() => _VenueSearchSheetState();
}

class _VenueSearchSheetState extends State<_VenueSearchSheet> {
  late final _q = TextEditingController(text: widget.initial);
  List<Map<String, dynamic>> _rows = [];
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), _search);
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.length < 2) {
      setState(() => _rows = []);
      return;
    }
    setState(() => _busy = true);
    final rows = await widget.supabase.searchVenues(q);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
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
            const Text('Which space paid?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 4),
            const Text(
                'Search every space in Nomad Maps. If it is not here yet, '
                'add it from the map first, then attach.',
                style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
            const SizedBox(height: 10),
            TextField(
              controller: _q,
              autofocus: true,
              onChanged: (_) => _schedule(),
              decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Space name',
                  filled: true,
                  fillColor: Brand.field,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none)),
            ),
            const SizedBox(height: 6),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView.builder(
                itemCount: _rows.length,
                itemBuilder: (_, i) {
                  final r = _rows[i];
                  final where = [r['neighbourhood'], r['city']]
                      .where((x) => x != null && '$x'.isNotEmpty)
                      .join(', ');
                  return ListTile(
                    dense: true,
                    title: Text(r['name'] ?? ''),
                    subtitle: Text(
                        [
                          if (where.isNotEmpty) where,
                          r['webflow_slug'] != null
                              ? 'on the site'
                              : 'not on the site yet',
                        ].join('  ·  '),
                        style: const TextStyle(fontSize: 12)),
                    onTap: () => Navigator.pop(context, r),
                  );
                },
              ),
            ),
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

/// One kind of page in the custom sitemap: the listings, the region
/// pages, the location pages. Each knows its URL prefix and which
/// table ticks off.
class _SitemapKind {
  final String key;
  final String label;
  final String path; // 'coworking', 'region', 'locations'
  final String slugField;
  final List<Map<String, dynamic>> items;
  final Future<void> Function(List<String> ids) mark;
  final String Function(Map<String, dynamic> row) where;
  const _SitemapKind({
    required this.key,
    required this.label,
    required this.path,
    required this.slugField,
    required this.items,
    required this.mark,
    required this.where,
  });
}

/// Pages that are live on nomadwise.io but missing from the custom
/// sitemap, turned into the exact <url> blocks Jonathan pastes into
/// it: priority 0.80, lastmod dated yesterday with a randomised time
/// of day, earliest first.
///
/// Three kinds sit here. The listings are the volume; the region and
/// location pages are the directory URLs that rank for "coworking in
/// <city>", so one of those left out of the sitemap costs more than a
/// missing listing does.
class _SitemapTab extends StatefulWidget {
  final List<_SitemapKind> kinds;
  final Future<void> Function() onChanged;
  final Future<void> Function(String text, String toast) copy;
  const _SitemapTab(
      {required this.kinds, required this.onChanged, required this.copy});
  @override
  State<_SitemapTab> createState() => _SitemapTabState();
}

class _SitemapTabState extends State<_SitemapTab> {
  final Set<String> _excluded = {};
  String? _kindKey;
  String? _xml;
  bool _busy = false;

  /// The chosen kind, or the first one with anything waiting.
  _SitemapKind get _kind => widget.kinds.firstWhere(
      (x) => x.key == _kindKey,
      orElse: () => widget.kinds.firstWhere((x) => x.items.isNotEmpty,
          orElse: () => widget.kinds.first));

  List<Map<String, dynamic>> get _chosen =>
      _kind.items.where((v) => !_excluded.contains(v['id'])).toList();

  int get _total => widget.kinds.fold(0, (n, k) => n + k.items.length);

  String _generate() {
    // Always yesterday's date; only the time of day is randomised.
    final rnd = Random();
    final y = DateTime.now().toUtc().subtract(const Duration(days: 1));
    final dayStart = DateTime.utc(y.year, y.month, y.day);
    final path = _kind.path;
    final field = _kind.slugField;
    final stamps = _chosen
        .map((v) => (
              slug: '${v[field]}',
              at: dayStart.add(Duration(seconds: rnd.nextInt(86400)))
            ))
        .toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    final fmt = DateFormat("yyyy-MM-dd'T'HH:mm:ss");
    return stamps
        .map((s) => '<url>\n'
            '<loc>https://www.nomadwise.io/$path/${s.slug}</loc>\n'
            '<lastmod>${fmt.format(s.at)}+00:00</lastmod>\n'
            '<priority>0.80</priority>\n'
            '</url>')
        .join('\n');
  }

  Future<void> _alreadyAdded(Map<String, dynamic> v) async {
    setState(() => _busy = true);
    try {
      await _kind.mark([v['id'] as String]);
      await widget.onChanged();
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
    if (_total == 0) {
      return ListView(padding: const EdgeInsets.all(24), children: const [
        SizedBox(height: 48),
        Icon(Icons.account_tree_outlined, size: 40, color: Brand.inkMuted),
        SizedBox(height: 12),
        Text('Sitemap is up to date',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        SizedBox(height: 6),
        Text(
            'Every released listing, region and location page has its '
            'entry. Anything new appears here with a ready-to-paste block.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13.5, color: Brand.inkMuted, height: 1.5)),
      ]);
    }

    final kind = _kind;
    final items = kind.items;
    return ListView(padding: const EdgeInsets.all(14), children: [
      // Which kind of page. The region and location pages are the
      // directory URLs, so they get their own tabs rather than being
      // mixed in with several hundred listings.
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
            children: widget.kinds
                .map((k) => Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 4),
                      child: ChoiceChip(
                        label: Text('${k.label}  ${k.items.length}'),
                        selected: k.key == kind.key,
                        showCheckmark: false,
                        selectedColor: Brand.ink,
                        labelStyle: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: k.key == kind.key
                                ? Colors.white
                                : k.items.isEmpty
                                    ? Brand.inkMuted
                                    : Brand.ink),
                        onSelected: (_) => setState(() {
                          _kindKey = k.key;
                          _excluded.clear();
                          _xml = null;
                        }),
                      ),
                    ))
                .toList()),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 10, 2, 10),
        child: Text(
            kind.key == 'listings'
                ? 'Released pages missing from the custom sitemap, checked '
                    'against the live sitemap every night. Untick any you '
                    'want to leave out, generate, copy, paste into the '
                    'sitemap in Webflow, then mark them as added. The tick '
                    'on the right removes a page you know is already there.'
                : '${kind.label} created in Webflow whose page is not in the '
                    'custom sitemap. These are the directory URLs that rank '
                    'for a whole city or area, so they are worth adding '
                    'promptly. Same routine: generate, copy, paste into the '
                    'sitemap, mark as added.',
            style: const TextStyle(
                fontSize: 12.5, color: Brand.inkMuted, height: 1.4)),
      ),
      if (items.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Text('No ${kind.label.toLowerCase()} waiting.',
              style: const TextStyle(color: Brand.inkMuted, fontSize: 13)),
        ),
      ...items.map((v) => CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            value: !_excluded.contains(v['id']),
            title: Text(v['name'] ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
                '/${kind.path}/${v[kind.slugField]}'
                '${kind.where(v).isEmpty ? '' : '  ·  ${kind.where(v)}'}',
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
                        await kind.mark(
                            _chosen.map((v) => v['id'] as String).toList());
                        await widget.onChanged();
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

  /// True: the same page makes a Country (country page) instead: no
  /// Country picker, slug is the country's name, zoom suits a country.
  final bool country;
  const _NewRegionPage(
      {required this.supabase,
      required this.countries,
      required this.regions,
      this.initialName,
      this.initialCountry,
      this.state,
      this.lat,
      this.lng,
      this.venueId,
      this.country = false});
  @override
  State<_NewRegionPage> createState() => _NewRegionPageState();
}

class _NewRegionPageState extends State<_NewRegionPage> {
  late final _name = TextEditingController(text: widget.initialName ?? '');
  late final _lat =
      TextEditingController(text: widget.lat?.toStringAsFixed(4) ?? '');
  late final _lng =
      TextEditingController(text: widget.lng?.toStringAsFixed(4) ?? '');
  late final _zoom =
      TextEditingController(text: widget.country ? '6' : '12');
  final _desc = TextEditingController();
  Map<String, dynamic>? _country;
  bool get _isCountry => widget.country;
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
    if (_isCountry) return n;
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
    if (_isCountry) return _slug(_name.text);
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
    if (_isCountry) {
      return widget.countries
          .where((c) => c['slug'] != null)
          .map((c) => '${c['slug']}')
          .take(3)
          .toList();
    }
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
    return (_isCountry ? widget.countries : widget.regions)
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
            subtitle: 'The Countries nomadwise.io already has. A new one '
                'is made from the menu: Create a Country.'));
    if (picked != null) {
      _country = picked;
      _refreshSlug();
      _scheduleLookup();
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || (!_isCountry && _country == null)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_isCountry
              ? 'A country name is needed.'
              : 'A name and a Country are needed.')));
      return;
    }
    if (_slugPreview.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The slug cannot be empty.')));
      return;
    }
    if ((_isCountry ? widget.countries : widget.regions)
        .any((r) => r['slug'] == _slugPreview)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${_isCountry ? 'A Country' : 'A Region'} already '
              'uses /${_slugPreview}.')));
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
        'kind': _isCountry ? 'country' : 'region',
        'name': name,
        if (!_isCountry) 'country_id': _country!['id'],
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
      appBar: AppBar(
          title: Text(_isCountry
              ? 'New Country (country page)'
              : 'New Region (city page)')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text(
                _isCountry
                    ? 'A Country is a country page on nomadwise.io, the '
                        'level above the city pages. The sync creates it '
                        'like the existing ones and publishes it within a '
                        'minute or two; then Regions can be made under it.'
                    : 'A Region is a city page on nomadwise.io. The sync creates '
                        'it exactly like the existing ones and publishes it within a '
                        'minute or two; description and photos can be polished in '
                        'Webflow later.',
                style: const TextStyle(
                    fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
            const SizedBox(height: 14),
            TextField(
                controller: _name,
                onChanged: (_) {
                  _refreshSlug();
                  _scheduleLookup();
                },
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: _isCountry
                        ? 'Country name as shown on the site'
                        : 'City name as shown on the site',
                    hintText: _isCountry ? 'e.g. Sri Lanka' : 'e.g. Porto')),
            if (dup != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('${dup['name']} already exists on the site.',
                    style: const TextStyle(fontSize: 12.5, color: Brand.red)),
              ),
            const SizedBox(height: 12),
            if (!_isCountry) ...[
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
            ],
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
                  label: Text(_locating
                      ? 'Finding'
                      : _isCountry ? 'Find country centre' : 'Find city centre')),
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
                            ? (_isCountry
                                ? 'Type the country and its centre is looked '
                                    'up for you.'
                                : 'Type the city and pick the Country and the '
                                    'centre is looked up for you.')
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
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  _isCountry
                      ? 'Map centre of the country page. Zoom 6 suits most '
                          'countries, 5 a large one, 7 a small one.'
                      : 'Map centre of the city page, found from the city name '
                          'and Country (the Country keeps same-named cities apart). '
                          'Zoom 12 suits a city, 10 a large one.',
                  style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
            ),
            const SizedBox(height: 10),
            _mapPreview(),
            const SizedBox(height: 12),
            TextField(
                controller: _desc,
                minLines: 3,
                maxLines: 8,
                decoration: InputDecoration(
                    labelText: _isCountry
                        ? 'About the country (optional)'
                        : 'About the city (optional)',
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
                    prefixText: _isCountry ? '/country/' : '/region/',
                    helperText: _isCountry
                        ? 'Site convention: the country name'
                        : 'Site convention: country-city'
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
                  'Page: /${_isCountry ? 'country' : 'region'}/${_slugPreview.isEmpty ? '...' : _slugPreview}\n'
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


/// Search any listing by name, for the Owner account preview.
class _PreviewPicker extends StatefulWidget {
  final SupabaseService supabase;
  const _PreviewPicker({required this.supabase});
  @override
  State<_PreviewPicker> createState() => _PreviewPickerState();
}

class _PreviewPickerState extends State<_PreviewPicker> {
  List<Map<String, dynamic>> _rows = [];
  Timer? _t;
  bool _busy = false;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  void _search(String q) {
    _t?.cancel();
    if (q.trim().length < 2) {
      setState(() => _rows = []);
      return;
    }
    _t = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _busy = true);
      final rows = await widget.supabase.claimSearch(q.trim());
      if (mounted) {
        setState(() {
          _rows = rows;
          _busy = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Whose Owner account?'),
        content: SizedBox(
          width: 420,
          height: 380,
          child: Column(children: [
            TextField(
              autofocus: true,
              onChanged: _search,
              decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Name of the space',
                  suffixIcon: _busy
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2)))
                      : null),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(children: [
                for (final r in _rows)
                  ListTile(
                    dense: true,
                    title: Text('${r['name'] ?? ''}'),
                    subtitle: Text([r['neighbourhood'], r['city'], r['country']]
                        .where((x) => x != null && '$x'.isNotEmpty)
                        .join(', ')),
                    onTap: () => Navigator.of(context).pop('${r['id']}'),
                  ),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
        ],
      );
}

/// One job on the control centre's "Next up" card: what it is, why,
/// and where its button goes.
class _NextJob {
  const _NextJob(this.kind, this.title, this.detail, this.button, this.open,
      {this.second, this.onSecond});
  final String kind;
  final String title;
  final String detail;
  final String button;
  final VoidCallback open;

  /// A second way to settle it without opening anything ("Nothing to
  /// change" on a page).
  final String? second;
  final VoidCallback? onSecond;
}

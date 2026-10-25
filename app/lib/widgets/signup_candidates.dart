import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/venue.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import 'ui.dart';

/// The top of the Candidates list (migration 188): spaces that signed
/// up through our old forms.app forms and are not on nomadwise.io
/// yet. They asked to be listed, so they come before the places the
/// nightly job found ("next on the list to review", Jonathan, 19 Oct
/// 2026).
///
/// Each card shows what the space told us on the form. A sign-up has
/// no Google place yet, so "Find on Google" comes first: pick the
/// place, check it is the right one, and queue it. From there it is a
/// space like any candidate, and nothing reaches Webflow without the
/// Approve that was always needed. "Not for the site" keeps it with a
/// reason, as for any candidate.
///
/// Since migration 210 the same list also holds places suggested by
/// travellers on nomadmaps.io/?suggest ("Suggested by a visitor"):
/// their name, city, a link and why they recommend it. They come after
/// the sign-ups and are handled the same way.
///
/// Shows nothing at all when no sign-up waits.
class SignupCandidates extends StatefulWidget {
  final SupabaseService supabase;
  final PlacesService places;
  final Map<String, dynamic>? Function(String? city) regionForCity;
  final List<String> dismissReasons;

  /// Called after a sign-up was queued, so the control centre reloads.
  final Future<void> Function() onQueued;

  const SignupCandidates({
    super.key,
    required this.supabase,
    required this.places,
    required this.regionForCity,
    required this.dismissReasons,
    required this.onQueued,
  });

  @override
  State<SignupCandidates> createState() => _SignupCandidatesState();
}

class _SignupCandidatesState extends State<SignupCandidates> {
  List<Map<String, dynamic>> _rows = [];
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.supabase.candidateSignups();
    if (mounted) setState(() => _rows = rows);
  }

  void _snack(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  static String _s(Object? v) => (v ?? '').toString().trim();

  Future<void> _open(String url) async {
    var u = url.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http')) u = 'https://$u';
    final uri = Uri.tryParse(u);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ------------------------------------------------------------ decisions

  /// Find the place on Google, check it, queue it.
  Future<void> _findAndQueue(Map<String, dynamic> s) async {
    final id = _s(s['id']);
    if (_busy.contains(id)) return;
    final start = [s['name'], s['city'], s['country']]
        .map(_s)
        .where((x) => x.isNotEmpty)
        .join(' ');
    // The address the space gave us, to tell branches apart.
    final given = _s(s['address']).isEmpty
        ? ''
        : [s['address'], s['city'], s['country']]
            .map(_s)
            .where((x) => x.isNotEmpty)
            .join(', ');
    // On a phone a panel that slides up from the bottom, clear of the
    // keyboard; on a wide screen the dialog as before (Jonathan, 25 Oct
    // 2026: "the ux can be better on mobile").
    final phone = MediaQuery.sizeOf(context).width < 600;
    final picked = phone
        ? await showModalBottomSheet<(String, PlaceLive)>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            showDragHandle: true,
            backgroundColor: Brand.surface,
            builder: (_) => _FindPlaceDialog(
                places: widget.places,
                start: start,
                given: given,
                sheet: true))
        : await showDialog<(String, PlaceLive)>(
            context: context,
            builder: (_) => _FindPlaceDialog(
                places: widget.places, start: start, given: given));
    if (picked == null || !mounted) return;
    final (placeId, live) = picked;
    setState(() => _busy.add(id));
    try {
      final region = widget.regionForCity(live.city);
      final res = await widget.supabase.candidateSignupQueue(id, placeId, {
        'name': live.displayName ?? _s(s['name']),
        'lat': live.lat,
        'lng': live.lng,
        'rating': live.rating,
        'reviews': live.userRatingCount,
        // The city as the site spells it when it has a page for it.
        'city': region?['name'] ?? live.city,
        'country': region?['country'] ?? live.country,
        'website': live.website,
      });
      if (!mounted) return;
      setState(() => _rows.removeWhere((r) => _s(r['id']) == id));
      if (res['existed'] == true) {
        _snack('${res['name'] ?? s['name']} is already a space. It is '
            'marked as done here; nothing else changed.');
      } else if (region == null) {
        _snack('${s['name']} queued. Its city has no page yet, so it '
            'waits under Blocked until you pick or create one.');
      } else {
        _snack('${s['name']} queued. The full proposal is ready in a few '
            'minutes.');
      }
      await widget.onQueued();
    } catch (e) {
      _snack('That did not save: $e', bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _dismiss(Map<String, dynamic> s, String reason) async {
    final id = _s(s['id']);
    if (_busy.contains(id)) return;
    String? note;
    if (reason == 'Other') {
      final text = TextEditingController();
      note = await showDialog<String>(
          context: context,
          builder: (ctx) => StatefulBuilder(
                builder: (ctx, setLocal) => AlertDialog(
                  title: Text('Why not ${s['name']}?'),
                  content: TextField(
                      controller: text,
                      autofocus: true,
                      maxLength: 200,
                      onChanged: (_) => setLocal(() {}),
                      decoration: const InputDecoration(
                          labelText: 'The reason',
                          hintText: 'In a few words, for later')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel')),
                    ElevatedButton(
                        onPressed: text.text.trim().isEmpty
                            ? null
                            : () => Navigator.pop(ctx, text.text.trim()),
                        child: const Text('Not for the site')),
                  ],
                ),
              ));
      if (note == null || note.trim().isEmpty || !mounted) return;
    }
    setState(() => _busy.add(id));
    try {
      await widget.supabase.candidateSignupDismiss(id, reason, note: note);
      if (!mounted) return;
      setState(() => _rows.removeWhere((r) => _s(r['id']) == id));
      _snack('${s['name']} is off the list: '
          '${note ?? reason.toLowerCase()}.');
      // So the Next up card's count stays right.
      await widget.onQueued();
    } catch (e) {
      _snack('That did not save: $e', bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  // ------------------------------------------------------------ view

  @override
  Widget build(BuildContext context) {
    if (_rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
        child: Text('ASKED TO BE LISTED OR SUGGESTED  ·  ${_rows.length}',
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: .8,
                color: Brand.inkMuted)),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(2, 0, 2, 10),
        child: Text(
            'These places are not on nomadwise.io yet: spaces that signed '
            'up through our old forms, then places travellers suggested. '
            'Find each one on Google, check it is still open and good to '
            'work from, and queue it, or say why it is not for the site.',
            style: TextStyle(
                fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
      ),
      for (final s in _rows) _card(s),
      const SizedBox(height: 6),
      const Divider(height: 1),
      const SizedBox(height: 14),
    ]);
  }

  Widget _line(IconData icon, String text, {VoidCallback? onTap}) {
    final body = Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 15, color: Brand.inkMuted),
        const SizedBox(width: 7),
        Expanded(
          child: onTap == null
              ? SelectableText(text,
                  style: const TextStyle(fontSize: 12.5, height: 1.4))
              : Text(text,
                  style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: Brand.red,
                      decoration: TextDecoration.underline,
                      decorationColor: Brand.red)),
        ),
      ]),
    );
    return onTap == null ? body : InkWell(onTap: onTap, child: body);
  }

  Widget _card(Map<String, dynamic> s) {
    final id = _s(s['id']);
    final busy = _busy.contains(id);
    final kind = _s(s['kind']);
    final where = [s['area'], s['city'], s['country']]
        .map(_s)
        .where((x) => x.isNotEmpty)
        .toSet()
        .join(', ');
    final when = DateTime.tryParse(_s(s['submitted_at']));
    final form = _s(s['form']);
    final contact = [s['contact_name'], s['contact_email'], s['contact_phone']]
        .map(_s)
        .where((x) => x.isNotEmpty)
        .join('  ·  ');
    final wifi = num.tryParse(_s(s['wifi_mbps']));
    final flag = _s(s['flag']);
    final suggested = form == 'Suggested by a visitor';
    final link = _s(s['link']);
    final from = _s(s['suggested_from']);
    return Card(
      key: ValueKey('signup-$id'),
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                  color: Brand.success,
                  borderRadius: BorderRadius.circular(10)),
              child: Text(kind == 'cafe' ? 'CAFE' : 'COWORKING',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(s['name']),
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    if (where.isNotEmpty)
                      Text(where,
                          style: const TextStyle(
                              fontSize: 12, color: Brand.inkMuted)),
                  ]),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            StatusChip(
                [
                  suggested ? 'Suggested by a visitor' : 'Signed up',
                  if (when != null) DateFormat('d MMM yyyy').format(when),
                  if (form.isNotEmpty && !suggested) 'via "$form"',
                ].join(' '),
                dotColor: Brand.success),
            if (flag.isNotEmpty) StatusChip(flag, dotColor: Brand.gold),
          ]),
          const SizedBox(height: 10),
          if (_s(s['address']).isNotEmpty)
            _line(Icons.place_outlined, _s(s['address'])),
          if (contact.isNotEmpty) _line(Icons.person_outline, contact),
          if (_s(s['website']).isNotEmpty)
            _line(Icons.language, _s(s['website']),
                onTap: () => _open(_s(s['website']))),
          if (_s(s['instagram']).isNotEmpty)
            _line(Icons.camera_alt_outlined, _s(s['instagram']),
                onTap: () => _open(_s(s['instagram']))),
          if (_s(s['features']).isNotEmpty)
            _line(Icons.check_circle_outline, _s(s['features'])),
          if (wifi != null && wifi > 0)
            _line(Icons.wifi, 'WiFi ${NumberFormat('#,##0.#').format(wifi)} Mbps '
                '(their own speed test)'),
          if (_s(s['prices']).isNotEmpty)
            _line(Icons.sell_outlined, _s(s['prices'])),
          if (_s(s['history']).isNotEmpty)
            _line(Icons.history, _s(s['history'])),
          // A suggestion: why they recommend it, the link they gave
          // (a Google Maps link is not shown above) and the page they
          // were on.
          if (_s(s['note']).isNotEmpty)
            _line(Icons.format_quote_outlined, '"${_s(s['note'])}"'),
          if (link.isNotEmpty &&
              link != _s(s['website']) &&
              link != _s(s['instagram']))
            _line(Icons.map_outlined, link, onTap: () => _open(link)),
          if (from.isNotEmpty)
            _line(Icons.subdirectory_arrow_right,
                'Suggested from '
                '${from.startsWith('/') ? 'nomadwise.io$from' : from}'),
          const SizedBox(height: 6),
          Wrap(
              spacing: 4,
              runSpacing: 4,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PopupMenuButton<String>(
                  enabled: !busy,
                  tooltip: 'Why it is not for the site',
                  onSelected: (reason) => _dismiss(s, reason),
                  itemBuilder: (_) => [
                    for (final r in widget.dismissReasons)
                      PopupMenuItem<String>(value: r, child: Text(r)),
                  ],
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Text('Not for the site',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: busy ? Brand.inkFaint : Brand.inkSecondary)),
                  ),
                ),
                ElevatedButton.icon(
                    onPressed: busy ? null : () => _findAndQueue(s),
                    icon: const Icon(Icons.travel_explore, size: 18),
                    label: Text(busy ? 'Saving…' : 'Find on Google and queue')),
              ]),
        ]),
      ),
    );
  }
}

/// Search Google for the sign-up's place, then show what Google has
/// for the one picked, so it can be checked before queueing. Returns
/// the place id and Google's details, or null when closed.
class _FindPlaceDialog extends StatefulWidget {
  final PlacesService places;
  final String start;
  /// The address on the sign-up ('' when none): each result shows how
  /// far it is from there, and the nearest close one is marked.
  final String given;
  /// Shown as a bottom panel (a phone) rather than a dialog.
  final bool sheet;
  const _FindPlaceDialog(
      {required this.places,
      required this.start,
      this.given = '',
      this.sheet = false});

  @override
  State<_FindPlaceDialog> createState() => _FindPlaceDialogState();
}

class _FindPlaceDialogState extends State<_FindPlaceDialog> {
  late final _q = TextEditingController(text: widget.start);
  List<PlaceHit> _hits = [];
  bool _searching = false;
  String? _pickedId;
  PlaceLive? _picked;
  bool _loadingPick = false;
  // Where the sign-up's own address is, once Google has placed it.
  CityCentre? _given;

  @override
  void initState() {
    super.initState();
    _search();
    if (widget.given.trim().isNotEmpty) {
      widget.places.cityCentre(widget.given).then((c) {
        if (mounted && c != null) setState(() => _given = c);
      });
    }
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final text = _q.text.trim();
    if (text.length < 2) return;
    setState(() => _searching = true);
    final hits = await widget.places.findPlaces(text);
    if (!mounted) return;
    if (text != _q.text.trim()) {
      setState(() => _searching = false);
      return;
    }
    setState(() {
      _hits = hits;
      _searching = false;
    });
  }

  Future<void> _pick(PlaceHit p) async {
    setState(() {
      _pickedId = p.placeId;
      _picked = null;
      _loadingPick = true;
    });
    final live = await widget.places.details(p.placeId);
    if (!mounted || _pickedId != p.placeId) return;
    setState(() {
      _picked = live;
      _loadingPick = false;
    });
  }

  /// Kilometres from the sign-up's address, or null when either
  /// position is unknown.
  double? _km(double? lat, double? lng) {
    final g = _given;
    if (g == null || lat == null || lng == null) return null;
    const r = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat - g.lat);
    final dLng = rad(lng - g.lng);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(g.lat)) * math.cos(rad(lat)) * math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a.toDouble())));
  }

  static String _kmWords(double km) => km < 1
      ? '${(km * 1000).round()} m from their address'
      : '${km < 10 ? km.toStringAsFixed(1) : km.round()} km from their address';

  /// The result that matches the sign-up's address: the nearest one,
  /// when it is within 1.5 km and clearly nearer than the next.
  String? get _matchId {
    String? best;
    double? bestKm;
    double? second;
    for (final h in _hits) {
      final k = _km(h.lat, h.lng);
      if (k == null) continue;
      if (bestKm == null || k < bestKm) {
        second = bestKm;
        bestKm = k;
        best = h.placeId;
      } else if (second == null || k < second) {
        second = k;
      }
    }
    if (bestKm == null || bestKm > 1.5) return null;
    if (second != null && second - bestKm < 0.5) return null;
    return best;
  }

  List<PlaceHit> get _sorted {
    if (_given == null) return _hits;
    final list = [..._hits];
    list.sort((a, b) {
      final ka = _km(a.lat, a.lng) ?? double.infinity;
      final kb = _km(b.lat, b.lng) ?? double.infinity;
      return ka.compareTo(kb);
    });
    return list;
  }

  Widget _matchLabel() => Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: Brand.success.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(6)),
        child: const Text('Matches their sign-up address',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Brand.success)),
      );

  Widget _hitRow(PlaceHit h, String? match) {
    final km = _km(h.lat, h.lng);
    final isMatch = h.placeId == match;
    return Material(
      color: isMatch ? Brand.success.withValues(alpha: .06) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _pick(h),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.place_outlined,
                  size: 20,
                  color: isMatch ? Brand.success : Brand.inkSecondary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(h.name,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w700)),
                    if (h.address.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(h.address,
                            style: const TextStyle(
                                fontSize: 13,
                                height: 1.35,
                                color: Brand.inkSecondary)),
                      ),
                    if (km != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(_kmWords(km),
                            style: const TextStyle(
                                fontSize: 12, color: Brand.inkMuted)),
                      ),
                    if (isMatch) _matchLabel(),
                  ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _results() {
    final match = _matchId;
    final given = widget.given.trim();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(
        controller: _q,
        autofocus: !widget.sheet,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(
            labelText: 'Name and town',
            suffixIcon: IconButton(
                tooltip: 'Search',
                onPressed: _search,
                icon: const Icon(Icons.search))),
      ),
      if (given.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Their address: $given',
                style:
                    const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
          ),
        ),
      const SizedBox(height: 8),
      if (_searching)
        const Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(color: Brand.red),
        )
      else if (_hits.isEmpty)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
              'Nothing found. Try the name alone, or the name and the street.',
              style: TextStyle(color: Brand.inkMuted)),
        )
      else
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: widget.sheet ? 420 : 340),
          child: ListView(shrinkWrap: true, children: [
            for (final h in _sorted) _hitRow(h, match),
          ]),
        ),
    ]);
  }

  Widget _checkPicked(PlaceLive? picked) {
    if (_loadingPick) {
      return const SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator(color: Brand.red)));
    }
    if (picked == null) {
      return const Text('Google did not answer for that place. Go back and '
          'pick it again, or another one.');
    }
    final km = _km(picked.lat, picked.lng);
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(picked.displayName ?? '',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          if ((picked.address ?? '').isNotEmpty)
            Text(picked.address!, style: const TextStyle(fontSize: 13)),
          if (km != null) ...[
            const SizedBox(height: 4),
            Text(_kmWords(km),
                style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
          ],
          if (_pickedId != null && _pickedId == _matchId) _matchLabel(),
          const SizedBox(height: 6),
          Text(
              [
                if (picked.rating != null)
                  '★ ${picked.rating} (${picked.userRatingCount ?? 0} reviews)',
                if ((picked.primaryType ?? '').isNotEmpty)
                  picked.primaryType!.replaceAll('_', ' '),
                if ((picked.website ?? '').isNotEmpty) picked.website!,
              ].join('  ·  '),
              style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
          if (picked.lat == null) ...[
            const SizedBox(height: 8),
            const Text(
                'Google gave no location for this one, so it cannot go on '
                'the map.',
                style: TextStyle(fontSize: 12.5, color: Brand.red)),
          ],
        ]);
  }

  void _back() => setState(() {
        _pickedId = null;
        _picked = null;
      });

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    final body = _pickedId != null ? _checkPicked(picked) : _results();
    final canQueue = picked != null && picked.lat != null;
    void queue() => Navigator.pop(context, (_pickedId!, picked!));

    if (widget.sheet) {
      // Phone: full-width buttons, the one that acts first.
      return Padding(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Find it on Google',
                    style:
                        TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                body,
                const SizedBox(height: 16),
                if (canQueue) ...[
                  FilledButton(
                      onPressed: queue,
                      style: FilledButton.styleFrom(
                          backgroundColor: Brand.red,
                          minimumSize: const Size.fromHeight(48)),
                      child: const Text('Yes, queue it')),
                  const SizedBox(height: 8),
                ],
                if (_pickedId != null) ...[
                  OutlinedButton(
                      onPressed: _back,
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                      child: const Text('Not this one')),
                  const SizedBox(height: 4),
                ],
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
              ]),
        ),
      );
    }

    return AlertDialog(
      title: const Text('Find it on Google'),
      content: SizedBox(width: 480, child: body),
      actions: [
        if (_pickedId != null)
          TextButton(onPressed: _back, child: const Text('Not this one')),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        if (canQueue)
          ElevatedButton(onPressed: queue, child: const Text('Yes, queue it')),
      ],
    );
  }
}

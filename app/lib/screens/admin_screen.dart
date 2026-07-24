import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/venue.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

/// Admin-only: review incoming new-venue submissions.
/// (Confirmations self-verify via photo + GPS, so they rarely appear here -
/// only ones whose GPS check failed.)
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _supabase = SupabaseService();
  final _places = PlacesService();
  List<Map<String, dynamic>>? _pending;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await _supabase.pendingSubmissions();
    if (mounted) setState(() => _pending = rows);
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    return Scaffold(
      appBar: AppBar(title: const Text('Review submissions')),
      body: pending == null
          ? const Center(child: CircularProgressIndicator(color: Brand.red))
          : pending.isEmpty
              ? Center(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                      Container(
                        width: 76,
                        height: 76,
                        decoration: const BoxDecoration(
                            color: Brand.successTint,
                            shape: BoxShape.circle),
                        child: const Icon(Icons.check_circle_outline,
                            size: 36, color: Brand.success),
                      ),
                      const SizedBox(height: 16),
                      const Text('All caught up',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: Brand.ink)),
                      const SizedBox(height: 6),
                      const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                            'New reviews from nomads will appear here '
                            'for you to approve.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 13.5,
                                color: Brand.inkMuted,
                                height: 1.5)),
                      ),
                    ]))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(14),
                    itemCount: pending.length,
                    itemBuilder: (_, i) => _SubmissionCard(
                        submission: pending[i],
                        supabase: _supabase,
                        places: _places,
                        onDone: _load),
                  ),
                ),
    );
  }
}

class _SubmissionCard extends StatefulWidget {
  final Map<String, dynamic> submission;
  final SupabaseService supabase;
  final PlacesService places;
  final VoidCallback onDone;
  const _SubmissionCard(
      {required this.submission,
      required this.supabase,
      required this.places,
      required this.onDone});

  @override
  State<_SubmissionCard> createState() => _SubmissionCardState();
}

class _SubmissionCardState extends State<_SubmissionCard> {
  Map<String, dynamic>? _stats;
  Venue? _venue;
  bool _busy = false;

  // Google reference data for quality assessment
  List<String> _googlePhotos = [];
  num? _googleRating;
  int? _googleReviewCount;
  Map<String, int> _signals = {};
  List<String> _excerpts = [];

  Map<String, dynamic> get s => widget.submission;
  Map<String, dynamic> get payload =>
      Map<String, dynamic>.from(s['payload'] ?? {});

  @override
  void initState() {
    super.initState();
    _loadContext();
  }

  Future<void> _loadContext() async {
    final stats = await widget.supabase.submitterStats(s['user_id']);
    Venue? venue;
    if (s['venue_id'] != null) {
      venue = await widget.supabase.venueById(s['venue_id']);
    }
    if (mounted) setState(() { _stats = stats; _venue = venue; });

    // Google reference for this place: photos, rating, review evidence.
    final pid = venue?.googlePlaceId;
    if (pid != null) {
      final live = await widget.places.details(pid);
      final signals = await widget.places.nomadSignals(pid);
      final excerpts = await widget.places.keywordExcerpts(pid);
      if (mounted) {
        setState(() {
          _googlePhotos = (live?.photoNames ?? [])
              .take(6)
              .map((n) => PlacesService.photoUrl(n, maxWidth: 400))
              .toList();
          _googleRating = live?.rating;
          _googleReviewCount = live?.userRatingCount;
          _signals = signals;
          _excerpts = excerpts;
        });
      }
    }
  }

  Future<void> _decide(String status) async {
    setState(() => _busy = true);
    try {
      await widget.supabase.setSubmissionStatus(s['id'], status);
      widget.onDone();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editVenue() async {
    final venue = _venue;
    if (venue == null) return;
    final name = TextEditingController(text: venue.name);
    final hood = TextEditingController(text: venue.neighbourhood ?? '');
    final city = TextEditingController(text: venue.city ?? '');
    final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Fix space details'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: name,
                    decoration:
                        const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 10),
                TextField(
                    controller: hood,
                    decoration: const InputDecoration(
                        labelText: 'Neighbourhood')),
                const SizedBox(height: 10),
                TextField(
                    controller: city,
                    decoration:
                        const InputDecoration(labelText: 'City')),
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
    if (saved == true) {
      await widget.supabase.updateVenueFields(venue.id, {
        'name': name.text.trim(),
        'neighbourhood': hood.text.trim(),
        'city': city.text.trim().isEmpty ? null : city.text.trim(),
      });
      await _loadContext();
    }
  }

  Future<void> _toggleFeature(String key, bool? current) async {
    final venue = _venue;
    if (venue == null) return;
    // cycle: unknown -> yes -> no -> unknown
    final next = current == null ? true : (current == true ? false : null);
    await widget.supabase.updateVenueFields(venue.id, {key: next});
    await _loadContext();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = s['kind'] == 'new_venue';
    final stats = _stats;
    final venue = _venue;
    final date = DateTime.tryParse(s['created_at'] ?? '');
    final dist = (s['gps_distance_m'] as num?)?.round();

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: isNew ? Brand.red : Brand.amber,
                  borderRadius: BorderRadius.circular(12)),
              child: Text(switch (s['kind']) {
                    'new_venue' => 'NEW SPACE',
                    'wifi_test' => 'WIFI TEST',
                    'wifi_login' => 'WIFI LOGIN',
                    _ => 'CONFIRMATION',
                  },
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w900)),
            ),
            const SizedBox(width: 8),
            Expanded(
                child: Text(venue?.name ?? payload['name'] ?? 'Unnamed',
                    style:
                        const TextStyle(fontWeight: FontWeight.w700))),
            if (date != null)
              Text(DateFormat('d MMM, HH:mm').format(date),
                  style: TextStyle(
                      color: Colors.grey.shade500, fontSize: 12)),
          ]),
          const SizedBox(height: 10),

          // ---- why a wifi test is waiting here ----
          if (s['kind'] == 'wifi_test') ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Brand.accentTint,
                  borderRadius: BorderRadius.circular(10)),
              child: const Row(children: [
                Icon(Icons.wifi_off, size: 16, color: Brand.accent),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                      'Held back automatically: this test ran on a '
                      'different network than earlier tests at this '
                      'space (or the GPS check failed). Could be a new '
                      'router, could be someone not actually there.',
                      style: TextStyle(fontSize: 12, height: 1.4)),
                ),
              ]),
            ),
            const SizedBox(height: 10),
          ],

          // ---- submitter credibility ----
          if (stats != null)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Brand.lightGrey,
                  borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                const Icon(Icons.person_outline, size: 18),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(stats['display_name'],
                        style: const TextStyle(
                            fontWeight: FontWeight.w500))),
                Text(
                    '${stats['verified_count']} verified · '
                    '${stats['withdrawable']} coins',
                    style: TextStyle(
                        color: Colors.grey.shade700, fontSize: 12)),
              ]),
            ),
          const SizedBox(height: 10),

          // ---- photo ----
          if (s['photo_path'] != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                  widget.supabase.photoUrl(s['photo_path']),
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                      height: 60,
                      color: Brand.lightGrey,
                      child: const Center(
                          child: Text('Photo failed to load')))),
            ),
          const SizedBox(height: 8),
          if (dist != null)
            Row(children: [
              Icon(Icons.gps_fixed,
                  size: 15,
                  color: dist <= 150 ? Colors.green : Brand.red),
              const SizedBox(width: 5),
              Text(
                  'Submitted ${dist < 1000 ? '$dist m' : '${NumberFormat("#,##0").format(dist / 1000)} km'} from the space',
                  style: TextStyle(
                      fontSize: 12,
                      color: dist <= 150
                          ? Colors.green.shade700
                          : Brand.red)),
            ]),
          const SizedBox(height: 8),

          // ---- Google reference: assess the submission's reliability ----
          if (_googlePhotos.isNotEmpty ||
              _googleRating != null ||
              _excerpts.isNotEmpty)
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                dense: true,
                title: Row(children: [
                  const Icon(Icons.travel_explore,
                      size: 17, color: Brand.charcoal),
                  const SizedBox(width: 6),
                  const Text('Compare with Google',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  if (_googleRating != null)
                    Text('★ $_googleRating ($_googleReviewCount)',
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600)),
                ]),
                children: [
                  if (_googlePhotos.isNotEmpty) ...[
                    SizedBox(
                      height: 74,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _googlePhotos.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: 6),
                        itemBuilder: (_, i) => ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(_googlePhotos[i],
                              width: 100,
                              height: 74,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const SizedBox(width: 100)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_signals.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Reviews mention: '
                        '${_signals.entries.map((e) => '${e.key} ×${e.value}').join(' · ')}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ..._excerpts.map((e) => Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text('"$e"',
                            style: TextStyle(
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                                color: Colors.grey.shade700)),
                      )),
                  if (_signals.isEmpty && _excerpts.isEmpty)
                    Text(
                        'No wifi/laptop mentions in its Google reviews.',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),

          // ---- venue features (tap to cycle yes/no/unknown) ----
          if (venue != null) ...[
            Wrap(spacing: 6, runSpacing: 6, children: [
              _featureChip('Laptops', 'laptops_allowed', venue.laptopsAllowed),
              _featureChip('Power', 'power_outlets', venue.powerOutlets),
              _featureChip('Aircon', 'aircon', venue.aircon),
              _featureChip(
                  'Seating', 'comfortable_seating', venue.comfortableSeating),
              _featureChip('Cozy', 'cozy', venue.cozy),
              _featureChip('Quiet', 'quiet_space', venue.quietSpace),
            ]),
            const SizedBox(height: 4),
            Text('Tap a feature to cycle Yes → No → Unknown',
                style:
                    TextStyle(color: Colors.grey.shade500, fontSize: 11)),
            const SizedBox(height: 8),
          ],

          // ---- actions ----
          Row(children: [
            if (venue != null)
              TextButton.icon(
                  onPressed: _busy ? null : _editVenue,
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('Fix details')),
            const Spacer(),
            TextButton(
                onPressed: _busy ? null : () => _decide('rejected'),
                style: TextButton.styleFrom(foregroundColor: Brand.red),
                child: const Text('Reject')),
            const SizedBox(width: 6),
            ElevatedButton.icon(
                onPressed: _busy ? null : () => _decide('verified'),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Approve')),
          ]),
        ]),
      ),
    );
  }

  Widget _featureChip(String label, String key, bool? value) {
    final (color, icon) = switch (value) {
      true => (Colors.green.shade600, Icons.check),
      false => (Brand.red, Icons.close),
      null => (Colors.grey.shade400, Icons.help_outline),
    };
    return ActionChip(
      onPressed: _busy ? null : () => _toggleFeature(key, value),
      avatar: Icon(icon, size: 15, color: color),
      label: Text(label,
          style: TextStyle(fontSize: 12, color: Brand.charcoal)),
      side: BorderSide(color: color.withValues(alpha: .5)),
      backgroundColor: color.withValues(alpha: .07),
    );
  }
}

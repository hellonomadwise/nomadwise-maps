import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../services/google_meter.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

/// What the founder chose on the map: a Location of the Region (its
/// Webflow id and name), 'none' for "Region page only", or 'other' to
/// open the full list of Locations.
class NearbyChoice {
  final String id;
  final String? name;
  const NearbyChoice(this.id, [this.name]);
}

/// The listed places around a space in review, each coloured by its
/// Location, with the verdict on which Location the space belongs to
/// (migration 155). Jonathan, 7 Oct 2026: "I would like to see
/// potential other spaces nearby on a map, because if a previous space
/// has been assigned a location, it makes it easier to decide if the
/// new space should also have that location (but not always)."
///
/// Pops a [NearbyChoice] when a Location is chosen, nothing otherwise.
class NearbySpacesScreen extends StatefulWidget {
  final String venueId;
  final String venueName;

  /// The Region the app shows for the space, and the area names it
  /// holds, for a space the sync has not prepared yet.
  final String? regionId;
  final List<String> areaNames;
  const NearbySpacesScreen(
      {super.key,
      required this.venueId,
      required this.venueName,
      this.regionId,
      this.areaNames = const []});

  @override
  State<NearbySpacesScreen> createState() => _NearbySpacesScreenState();
}

class _NearbySpacesScreenState extends State<NearbySpacesScreen> {
  final _supabase = SupabaseService();

  Map<String, dynamic>? _help;
  String? _error;
  bool _loading = true;
  bool _savingKind = false;

  // The Location picked in the legend (a Webflow id), if any, and
  // whether the founder picked it (and not the suggestion put there
  // to begin with, which follows the verdict when that changes).
  String? _picked;
  bool _pickedByHand = false;

  // One dot per colour, drawn once.
  final Map<int, BitmapDescriptor> _dots = {};
  BitmapDescriptor? _here;

  // Told apart at a glance, also by people who mix up red and green.
  static const _palette = <Color>[
    Color(0xFF1F77B4), // blue
    Color(0xFFFF7F0E), // orange
    Color(0xFF8E44AD), // purple
    Color(0xFF17A2B8), // teal
    Color(0xFFD62728), // red
    Color(0xFF8C564B), // brown
    Color(0xFFE377C2), // pink
    Color(0xFF2CA02C), // green
    Color(0xFFBCBD22), // olive
    Color(0xFF393B79), // navy
  ];
  static const _noLocation = Color(0xFF9AA3AD);
  static const _hereColor = Color(0xFF142032);

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _plain(Object e) => e is PostgrestException
      ? e.message
      : '$e'.replaceFirst('Exception: ', '');

  Future<void> _load() async {
    setState(() {
      // Only the first time: afterwards the map stays where it is.
      _loading = _help == null;
      _error = null;
    });
    try {
      final h = await _supabase.locationHelp(widget.venueId,
          regionId: widget.regionId, areaNames: widget.areaNames);
      // The dots first, so the map appears with its colours.
      final keys = _legend(h).map((e) => e.colorIndex).toSet();
      for (final k in keys) {
        _dots[k] ??= await _dot(k < 0 ? _noLocation : _palette[k]);
      }
      _here ??= await _dot(_hereColor, big: true);
      if (!mounted) return;
      final verdict = h['verdict'];
      final suggested = verdict is Map &&
              (verdict['verdict'] == 'assign' ||
                  verdict['verdict'] == 'suggest')
          ? '${verdict['location_id'] ?? ''}'
          : '';
      setState(() {
        _help = h;
        _loading = false;
        if (!_pickedByHand) _picked = suggested.isEmpty ? null : suggested;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _plain(e);
      });
    }
  }

  void _pick(String? id) => setState(() {
        _picked = id;
        _pickedByHand = true;
      });

  /// A round dot with a white rim, as a map marker.
  Future<BitmapDescriptor> _dot(Color color, {bool big = false}) async {
    try {
      const px = 64.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const centre = Offset(px / 2, px / 2);
      canvas.drawCircle(centre, px / 2 - 2, Paint()..color = Colors.white);
      canvas.drawCircle(centre, px / 2 - 9, Paint()..color = color);
      if (big) {
        canvas.drawCircle(centre, px / 7, Paint()..color = Colors.white);
      }
      final image =
          await recorder.endRecording().toImage(px.toInt(), px.toInt());
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return BitmapDescriptor.defaultMarker;
      final size = big ? 30.0 : 20.0;
      return BitmapDescriptor.bytes(data.buffer.asUint8List(),
          width: size, height: size);
    } catch (_) {
      return BitmapDescriptor.defaultMarker;
    }
  }

  static List<Map<String, dynamic>> _maps(Object? list) => [
        for (final x in (list is List ? list : const []))
          if (x is Map) Map<String, dynamic>.from(x),
      ];

  static double? _num(Object? x) => x is num ? x.toDouble() : null;

  /// The Locations seen among the nearby places, the one with the most
  /// places first, each with its colour; then "No Location".
  List<_LegendEntry> _legend(Map<String, dynamic> h) {
    final spots = _maps(h['spots']);
    final byId = <String, _LegendEntry>{};
    var none = 0;
    for (final s in spots) {
      final id = '${s['location_id'] ?? ''}';
      if (id.isEmpty) {
        none++;
        continue;
      }
      final name = '${s['location'] ?? ''}'.trim();
      final e = byId.putIfAbsent(
          id, () => _LegendEntry(id, name.isEmpty ? 'A Location' : name));
      e.count++;
    }
    final out = byId.values.toList()
      ..sort((a, b) => b.count != a.count
          ? b.count.compareTo(a.count)
          : a.name.compareTo(b.name));
    for (var i = 0; i < out.length; i++) {
      out[i].colorIndex = i % _palette.length;
    }
    if (none > 0) {
      out.add(_LegendEntry('', 'No Location')
        ..count = none
        ..colorIndex = -1);
    }
    return out;
  }

  Color _colorOf(int index) => index < 0 ? _noLocation : _palette[index];

  Future<void> _setKind(String regionId, String kind) async {
    setState(() => _savingKind = true);
    try {
      await _supabase.setRegionKind(regionId, kind);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That did not save: ${_plain(e)}'),
          backgroundColor: Brand.red));
    } finally {
      if (mounted) setState(() => _savingKind = false);
    }
  }

  static String _kindWords(String kind) => switch (kind) {
        'island' => 'an island',
        'rural' => 'a rural or wide area',
        _ => 'a city',
      };

  @override
  Widget build(BuildContext context) {
    final name = widget.venueName.trim().isEmpty
        ? 'this space'
        : widget.venueName.trim();
    return Scaffold(
      appBar: AppBar(title: Text('Spaces near $name')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _help == null
              ? _message('The map could not be loaded.\n$_error', retry: true)
              : _body(_help ?? const {}, name),
    );
  }

  Widget _message(String text, {bool retry = false}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14, height: 1.45, color: Brand.inkSecondary)),
            if (retry) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ]),
        ),
      );

  Widget _body(Map<String, dynamic> h, String name) {
    final venue = h['venue'] is Map
        ? Map<String, dynamic>.from(h['venue'] as Map)
        : const <String, dynamic>{};
    final region = h['region'] is Map
        ? Map<String, dynamic>.from(h['region'] as Map)
        : null;
    final verdict = h['verdict'] is Map
        ? Map<String, dynamic>.from(h['verdict'] as Map)
        : const <String, dynamic>{};
    final lat = _num(venue['lat']);
    final lng = _num(venue['lng']);
    if (lat == null || lng == null) {
      return _message('$name has no position on the map yet, so the '
          'spaces around it cannot be shown.');
    }
    final spots = _maps(h['spots']);
    final legend = _legend(h);
    final colorOf = <String, int>{
      for (final e in legend) e.id: e.colorIndex,
    };
    // Wide enough to see the places that are compared: 1.5 km in a
    // city, 4 km on an island, 8 km in a rural or wide area.
    final compared = _num(verdict['radius_km']) ?? 8;
    final zoom = compared <= 1.5
        ? 13.5
        : compared <= 4
            ? 12.2
            : 11.2;

    final markers = <Marker>{
      for (final s in spots)
        if (_num(s['lat']) != null && _num(s['lng']) != null)
          Marker(
            markerId: MarkerId('${s['id']}'),
            position: LatLng(_num(s['lat'])!, _num(s['lng'])!),
            icon: _dots[colorOf['${s['location_id'] ?? ''}'] ?? -1] ??
                BitmapDescriptor.defaultMarker,
            anchor: const Offset(0.5, 0.5),
            infoWindow: InfoWindow(
                title: '${s['name'] ?? ''}',
                snippet: [
                  '${s['location'] ?? ''}'.trim().isEmpty
                      ? 'No Location'
                      : '${s['location']}',
                  if (region == null && '${s['region'] ?? ''}'.isNotEmpty)
                    '${s['region']}',
                  if (_num(s['km']) != null)
                    '${_num(s['km'])!.toStringAsFixed(1)} km away',
                ].join(' · ')),
            onTap: () {
              final id = '${s['location_id'] ?? ''}';
              if (region != null && id.isNotEmpty) _pick(id);
            },
          ),
      Marker(
        markerId: const MarkerId('this-space'),
        position: LatLng(lat, lng),
        icon: _here ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        // ignore: deprecated_member_use
        zIndex: 10,
        infoWindow: InfoWindow(title: name, snippet: 'The space in review'),
      ),
    };

    final map = GoogleMap(
      initialCameraPosition:
          CameraPosition(target: LatLng(lat, lng), zoom: zoom),
      markers: markers,
      onMapCreated: (_) => GoogleMeter.countMapLoad(),
      myLocationButtonEnabled: false,
      zoomControlsEnabled: true,
      mapToolbarEnabled: false,
      style: '''[
        {"featureType": "poi.business",
         "stylers": [{"visibility": "off"}]}
      ]''',
    );
    final panel = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: _panel(h, region, legend, spots.length, name),
    );
    return LayoutBuilder(builder: (context, box) {
      // A short window (a phone on its side): everything scrolls, the
      // map at a fixed height, so nothing is squeezed to nothing.
      if (box.maxHeight < 460) {
        return ListView(children: [
          _verdictBox(verdict, region),
          if (_savingKind) const LinearProgressIndicator(minHeight: 2),
          SizedBox(height: 240, child: map),
          panel,
        ]);
      }
      return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _verdictBox(verdict, region),
            if (_savingKind) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: map),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight * 0.42),
              child: SingleChildScrollView(child: panel),
            ),
          ]);
    });
  }

  Widget _verdictBox(
      Map<String, dynamic> verdict, Map<String, dynamic>? region) {
    final kind = '${verdict['verdict'] ?? 'none'}';
    final why = '${verdict['why'] ?? ''}'.trim();
    final location = '${verdict['location'] ?? ''}'.trim();
    final (String title, Color tint, Color ink) = switch (kind) {
      'assign' => (
          'Almost certain: $location',
          Brand.successTint,
          Brand.ink
        ),
      'suggest' => ('Suggested: $location', Brand.goldTint, Brand.goldTextDark),
      _ => (
          region == null ? 'No Region yet' : 'No Location suggested',
          Brand.field,
          Brand.inkSecondary
        ),
    };
    return Container(
      width: double.infinity,
      color: tint,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w800, color: ink)),
        if (why.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(why,
                style: TextStyle(fontSize: 12.5, height: 1.4, color: ink)),
          ),
      ]),
    );
  }

  Widget _panel(Map<String, dynamic> h, Map<String, dynamic>? region,
      List<_LegendEntry> legend, int spotCount, String name) {
    final all = _maps(h['locations']);
    final nearIds = {for (final e in legend) e.id};
    final others = [
      for (final l in all)
        if (!nearIds.contains('${l['id']}')) l,
    ];
    String? pickedName;
    if (_picked != null) {
      for (final l in all) {
        if ('${l['id']}' == _picked) pickedName = '${l['name'] ?? ''}';
      }
      if ((pickedName ?? '').isEmpty) {
        for (final e in legend) {
          if (e.id == _picked) pickedName = e.name;
        }
      }
    }
    final regionName = '${region?['name'] ?? ''}';
    final kind = '${region?['kind'] ?? 'city'}';
    final reach = _num((h['verdict'] is Map
            ? (h['verdict'] as Map)['radius_km']
            : null)) ??
        1.5;

    Widget chip(String id, String label, {Color? dot}) {
      final on = region != null && id.isNotEmpty && _picked == id;
      final canPick = region != null && id.isNotEmpty;
      return Material(
        color: on ? Brand.logoTealTint : Brand.surface,
        shape: StadiumBorder(
            side: BorderSide(color: on ? Brand.logoNavy : Brand.border)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: canPick ? () => _pick(on ? null : id) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (dot != null) ...[
                Container(
                  width: 11,
                  height: 11,
                  decoration:
                      BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Text(label,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
          spotCount == 0
              ? 'No listed places are near enough to show.'
              : '$spotCount listed ${spotCount == 1 ? 'place' : 'places'} '
                  'nearby, coloured by Location. The dark dot is $name.'
                  '${region == null ? '' : ' Tap a Location to choose it.'}',
          style: const TextStyle(
              fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
      if (legend.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in legend)
            chip(e.id, '${e.name} (${e.count})',
                dot: _colorOf(e.colorIndex)),
        ]),
      ],
      if (region != null && others.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text('Other Locations in $regionName with no listed places nearby',
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: .4,
                color: Brand.inkMuted)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final l in others) chip('${l['id']}', '${l['name'] ?? ''}'),
        ]),
      ],
      if (region != null) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 4, children: [
          ElevatedButton(
              onPressed: _picked == null || (pickedName ?? '').isEmpty
                  ? null
                  : () => Navigator.of(context)
                      .pop(NearbyChoice(_picked!, pickedName)),
              child: Text((pickedName ?? '').isEmpty
                  ? 'Choose a Location above'
                  : 'Use $pickedName')),
          TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(const NearbyChoice('none')),
              child: const Text('No Location (Region page only)')),
          TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(const NearbyChoice('other')),
              child: const Text('Full list')),
        ]),
        const SizedBox(height: 8),
        Text(
            '$regionName counts as ${_kindWords(kind)}: listed places '
            'within ${reach == reach.roundToDouble() ? reach.round() : reach} '
            'km are compared. If that is the wrong kind of Region:',
            style: const TextStyle(
                fontSize: 12, height: 1.4, color: Brand.inkMuted)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final k in const [
            ('city', 'City (1.5 km)'),
            ('island', 'Island (4 km)'),
            ('rural', 'Rural or wide area (8 km)'),
          ])
            ChoiceChip(
                label: Text(k.$2, style: const TextStyle(fontSize: 12)),
                selected: kind == k.$1,
                onSelected: _savingKind || kind == k.$1
                    ? null
                    : (_) => _setKind('${region['id']}', k.$1)),
        ]),
      ],
    ]);
  }
}

class _LegendEntry {
  final String id;
  final String name;
  int count = 0;
  int colorIndex = -1;
  _LegendEntry(this.id, this.name);
}

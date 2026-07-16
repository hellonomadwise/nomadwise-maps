import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/discovered_place.dart';
import '../models/venue.dart';

class PlaceSuggestion {
  final String placeId;
  final String main;
  final String secondary;
  PlaceSuggestion(
      {required this.placeId, required this.main, required this.secondary});
}

/// Fetches live venue details (rating, review count, open/closed, hours,
/// coordinates) from the Google Places API (New) using each venue's Place ID.
///
/// Results are cached in memory for [cacheMinutes] so panning the map around
/// doesn't burn through API quota.
class PlacesService {
  static const cacheMinutes = 15;
  final Map<String, (DateTime, PlaceLive)> _cache = {};

  static const _fields = [
    'displayName',
    'rating',
    'userRatingCount',
    'currentOpeningHours',
    'regularOpeningHours',
    'location',
    'shortFormattedAddress',
    'photos',
  ];

  /// Turns a Google photo resource name into a loadable image URL.
  static String photoUrl(String photoName, {int maxWidth = 900}) =>
      'https://places.googleapis.com/v1/$photoName/media'
      '?maxWidthPx=$maxWidth&key=${AppConfig.googlePlacesKey}';

  Future<PlaceLive?> details(String placeId) async {
    final hit = _cache[placeId];
    if (hit != null &&
        DateTime.now().difference(hit.$1).inMinutes < cacheMinutes) {
      return hit.$2;
    }
    try {
      final resp = await http.get(
        Uri.parse('https://places.googleapis.com/v1/places/$placeId'),
        headers: {
          'X-Goog-Api-Key': AppConfig.googlePlacesKey,
          'X-Goog-FieldMask': _fields.join(','),
        },
      );
      if (resp.statusCode != 200) return null;
      final live = PlaceLive.fromJson(jsonDecode(resp.body));
      _cache[placeId] = (DateTime.now(), live);
      return live;
    } catch (_) {
      return null;
    }
  }

  /// Find cafes & coworking spaces Google knows about around a point.
  /// Used by "Search this area" — results get cached in Supabase so the
  /// same area never costs a second Google call.
  static const _searchFieldMask =
      'places.id,places.displayName,places.location,'
      'places.primaryType,places.rating,places.userRatingCount';

  Future<List<DiscoveredPlace>> searchNearby(
      double lat, double lng, double radiusM) async {
    final radius = radiusM.clamp(200.0, 50000.0);
    // Cafes and coworking spaces live in different corners of Google's
    // catalogue, so run both lookups in parallel and merge.
    final results = await Future.wait([
      _nearbyCafes(lat, lng, radius),
      _textSearchCoworking(lat, lng, radius),
    ]);
    final seen = <String>{};
    final merged = <DiscoveredPlace>[];
    for (final list in results) {
      for (final p in list) {
        if (seen.add(p.placeId)) merged.add(p);
      }
    }
    return merged;
  }

  Future<List<DiscoveredPlace>> _nearbyCafes(
      double lat, double lng, double radius) async {
    try {
      final resp = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:searchNearby'),
        headers: {
          'X-Goog-Api-Key': AppConfig.googlePlacesKey,
          'Content-Type': 'application/json',
          'X-Goog-FieldMask': _searchFieldMask,
        },
        body: jsonEncode({
          'includedTypes': ['cafe', 'coffee_shop'],
          'maxResultCount': 20,
          'locationRestriction': {
            'circle': {
              'center': {'latitude': lat, 'longitude': lng},
              'radius': radius,
            }
          },
        }),
      );
      if (resp.statusCode != 200) return [];
      final places = (jsonDecode(resp.body)['places'] as List?) ?? [];
      return places
          .map((p) =>
              DiscoveredPlace.fromGoogle(Map<String, dynamic>.from(p)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<DiscoveredPlace>> _textSearchCoworking(
      double lat, double lng, double radius) async {
    try {
      final resp = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:searchText'),
        headers: {
          'X-Goog-Api-Key': AppConfig.googlePlacesKey,
          'Content-Type': 'application/json',
          'X-Goog-FieldMask': _searchFieldMask,
        },
        body: jsonEncode({
          'textQuery': 'coworking space',
          'maxResultCount': 10,
          'locationBias': {
            'circle': {
              'center': {'latitude': lat, 'longitude': lng},
              'radius': radius,
            }
          },
        }),
      );
      if (resp.statusCode != 200) return [];
      final places = (jsonDecode(resp.body)['places'] as List?) ?? [];
      return places.map((p) {
        final d = DiscoveredPlace.fromGoogle(Map<String, dynamic>.from(p));
        // Text search may not set a primary type — mark these as coworking
        // so the review form prefills correctly.
        return DiscoveredPlace(
          placeId: d.placeId,
          name: d.name,
          lat: d.lat,
          lng: d.lng,
          primaryType: d.primaryType ?? 'coworking_space',
          rating: d.rating,
          userRatingCount: d.userRatingCount,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // ---------- nomad-signal pre-screening ----------

  static const _signalWords = {
    'wifi': ['wifi', 'wi-fi', 'wlan', 'internet'],
    'power': ['plug', 'socket', 'outlet', 'steckdose', 'tomada', 'enchufe'],
    'laptop': [
      'laptop', 'notebook', 'digital nomad', 'remote work', 'work from',
      'working from', 'arbeiten', 'trabalhar', 'trabajar', 'study',
      'studying',
    ],
  };

  final Map<String, List<String>> _reviewsCache = {};

  /// The place's Google review texts (up to 5, cached).
  Future<List<String>> _reviewTexts(String placeId) async {
    final hit = _reviewsCache[placeId];
    if (hit != null) return hit;
    try {
      final resp = await http.get(
        Uri.parse('https://places.googleapis.com/v1/places/$placeId'),
        headers: {
          'X-Goog-Api-Key': AppConfig.googlePlacesKey,
          'X-Goog-FieldMask': 'reviews',
        },
      );
      if (resp.statusCode != 200) return [];
      final reviews = (jsonDecode(resp.body)['reviews'] as List?) ?? [];
      final texts = reviews
          .map((r) => (r['text']?['text'] ?? '').toString())
          .where((t) => t.isNotEmpty)
          .toList();
      _reviewsCache[placeId] = texts;
      return texts;
    } catch (_) {
      return [];
    }
  }

  /// Scans a place's Google reviews for signs it might suit nomads.
  /// Returns mention counts per signal, e.g. {wifi: 3, power: 1, laptop: 2}.
  Future<Map<String, int>> nomadSignals(String placeId) async {
    final texts = (await _reviewTexts(placeId))
        .map((t) => t.toLowerCase())
        .toList();
    final counts = <String, int>{};
    _signalWords.forEach((signal, words) {
      var n = 0;
      for (final t in texts) {
        if (words.any(t.contains)) n++;
      }
      if (n > 0) counts[signal] = n;
    });
    return counts;
  }

  /// Short quotes from reviews that mention wifi/plugs/laptops, for the
  /// admin to weigh a submission against. Max [limit] excerpts.
  Future<List<String>> keywordExcerpts(String placeId,
      {int limit = 3}) async {
    final texts = await _reviewTexts(placeId);
    final allWords =
        _signalWords.values.expand((w) => w).toList(growable: false);
    final excerpts = <String>[];
    for (final t in texts) {
      final lower = t.toLowerCase();
      int idx = -1;
      for (final w in allWords) {
        final i = lower.indexOf(w);
        if (i >= 0 && (idx == -1 || i < idx)) idx = i;
      }
      if (idx == -1) continue;
      final start = (idx - 60).clamp(0, t.length);
      final end = (idx + 90).clamp(0, t.length);
      var snippet = t.substring(start, end).replaceAll('\n', ' ').trim();
      if (start > 0) snippet = '…$snippet';
      if (end < t.length) snippet = '$snippet…';
      excerpts.add(snippet);
      if (excerpts.length >= limit) break;
    }
    return excerpts;
  }

  /// Autocomplete for the "Add a venue" search box, biased to the user's
  /// location so nearby places rank first.
  Future<List<PlaceSuggestion>> autocomplete(String input,
      {double? nearLat, double? nearLng, List<String>? types}) async {
    if (input.trim().length < 3) return [];
    try {
      final resp = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
        headers: {
          'X-Goog-Api-Key': AppConfig.googlePlacesKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'input': input,
          if (types != null) 'includedPrimaryTypes': types,
          if (nearLat != null && nearLng != null)
            'locationBias': {
              'circle': {
                'center': {'latitude': nearLat, 'longitude': nearLng},
                'radius': 15000.0,
              }
            },
        }),
      );
      if (resp.statusCode != 200) return [];
      final suggestions =
          (jsonDecode(resp.body)['suggestions'] as List?) ?? [];
      return suggestions
          .map((s) => s['placePrediction'])
          .where((p) => p != null)
          .map((p) => PlaceSuggestion(
                placeId: p['placeId'],
                main: p['structuredFormat']?['mainText']?['text'] ??
                    p['text']?['text'] ??
                    '',
                secondary:
                    p['structuredFormat']?['secondaryText']?['text'] ?? '',
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Load live details for a batch of venues (used when the map loads).
  Future<void> enrich(Iterable<Venue> venues) async {
    await Future.wait(venues
        .where((v) => v.googlePlaceId != null)
        .map((v) async {
      final live = await details(v.googlePlaceId!);
      if (live != null) {
        v.live = live;
        v.lat ??= live.lat;
        v.lng ??= live.lng;
      }
    }));
  }
}

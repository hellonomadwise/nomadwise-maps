import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
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
  ];

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

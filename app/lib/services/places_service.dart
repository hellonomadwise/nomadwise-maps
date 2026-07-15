import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/venue.dart';

/// Fetches live venue details (rating, review count, open/closed, hours,
/// coordinates) from the Google Places API (New) using each venue's Place ID.
///
/// Results are cached in memory for [cacheMinutes] so panning the map around
/// doesn't burn through API quota.
class PlacesService {
  static const cacheMinutes = 15;
  final Map<String, (DateTime, PlaceLive)> _cache = {};

  static const _fields = [
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

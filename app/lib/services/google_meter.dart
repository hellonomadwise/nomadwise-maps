import 'dart:async';

import 'package:http/http.dart' as http;

import 'supabase_service.dart';

/// Counts the app's own Google Places calls by the line they appear
/// under on the Google bill, and saves the tally about once a minute
/// (public.api_usage, source "app"), next to the nightly jobs' counts.
/// The control centre's "Google calls" screen reads both, so a bill
/// can be matched line by line and growth with traffic is visible.
class GoogleMeter extends http.BaseClient {
  GoogleMeter._();
  static final GoogleMeter client = GoogleMeter._();
  final http.Client _inner = http.Client();

  static final Map<String, List<int>> _counts = {};
  static Timer? _timer;

  static const _tiers = <String, int>{
    'id': 0, 'name': 0, 'photos': 0, 'attributions': 0,
    'location': 1, 'addressComponents': 1, 'formattedAddress': 1,
    'shortFormattedAddress': 1, 'types': 1, 'viewport': 1, 'plusCode': 1,
    'displayName': 2, 'businessStatus': 2, 'primaryType': 2,
    'primaryTypeDisplayName': 2, 'googleMapsUri': 2, 'utcOffsetMinutes': 2,
    'rating': 3, 'userRatingCount': 3, 'priceLevel': 3,
    'internationalPhoneNumber': 3, 'nationalPhoneNumber': 3,
    'websiteUri': 3, 'regularOpeningHours': 3, 'currentOpeningHours': 3,
  };
  static const _names = [
    'Essentials (IDs Only)', 'Essentials', 'Pro', 'Enterprise',
    'Enterprise + Atmosphere',
  ];

  static int _tier(String? mask) {
    var top = 0;
    for (var f in (mask ?? '').split(',')) {
      f = f.trim();
      if (f.startsWith('places.')) f = f.substring(7);
      f = f.split('.').first;
      if (f.isEmpty) continue;
      final t = _tiers[f] ?? 4;
      if (t > top) top = t;
    }
    return top;
  }

  /// The Google bill's name for a call, or null if it is not Places.
  static String? billLine(Uri url, String? mask) {
    if (url.host != 'places.googleapis.com') return null;
    final path = url.path.replaceFirst('/v1/', '');
    if (path.endsWith('/media')) return 'Place Details Photos';
    if (path.startsWith('places:autocomplete')) return 'Autocomplete Requests';
    final t = _tier(mask);
    if (path.startsWith('places:searchText')) {
      return 'Text Search ${t == 0 ? _names[0] : _names[t < 2 ? 2 : t]}';
    }
    if (path.startsWith('places:searchNearby')) {
      return 'Nearby Search ${_names[t < 2 ? 2 : t]}';
    }
    return 'Place Details ${_names[t]}';
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    String? line;
    try {
      final mask = request.headers.entries
          .where((e) => e.key.toLowerCase() == 'x-goog-fieldmask')
          .map((e) => e.value)
          .firstOrNull;
      line = billLine(request.url, mask);
    } catch (_) {}
    try {
      final r = await _inner.send(request);
      if (line != null) _count(line, r.statusCode == 200);
      return r;
    } catch (e) {
      if (line != null) _count(line, false);
      rethrow;
    }
  }

  static void _count(String line, bool ok) {
    final row = _counts.putIfAbsent(line, () => [0, 0]);
    row[ok ? 0 : 1]++;
    _timer ??= Timer(const Duration(seconds: 60), _flush);
  }

  static void _flush() {
    _timer = null;
    if (_counts.isEmpty) return;
    final batch = {
      for (final e in _counts.entries)
        e.key: {'calls': e.value[0], 'errors': e.value[1]},
    };
    _counts.clear();
    SupabaseService().recordApiUsage('app', batch);
  }
}

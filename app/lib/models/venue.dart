import 'dart:math' as math;

/// Tri-state for work-friendliness: true / false / unknown (null).
enum WorkFriendly { yes, no, unknown }

class Venue {
  final String id;
  final String name;
  final String type; // 'cafe' | 'coworking'
  final String? neighbourhood;
  final String city;
  final String? googlePlaceId;
  double? lat;
  double? lng;

  final bool? laptopsAllowed;
  final num? wifiSpeedMbps;
  final bool? powerOutlets;
  final bool? aircon;
  final bool? comfortableSeating;
  final bool? cozy;
  final bool? quietSpace;
  final bool? goodForCalls;
  final bool? callRoom;
  final bool? monitorAvailable;
  final bool? officeChairs;
  final bool? access24h;

  final String? website;
  final String? instagram;
  final num? ratingSnapshot;
  final int? reviewsSnapshot;

  /// Fallback opening hours from the seed spreadsheet, e.g.
  /// {"mon": "8:00 AM - 4:00 PM", ..., "sun": "Closed"}
  final Map<String, dynamic>? fallbackHours;

  /// Live data filled in from Google Places at runtime.
  PlaceLive? live;

  /// Distance from the user, metres (computed client-side).
  double? distanceM;

  Venue.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'] ?? '',
        type = j['type'] ?? 'cafe',
        neighbourhood = j['neighbourhood'],
        city = j['city'] ?? 'Lisbon',
        googlePlaceId = j['google_place_id'],
        lat = (j['lat'] as num?)?.toDouble(),
        lng = (j['lng'] as num?)?.toDouble(),
        laptopsAllowed = j['laptops_allowed'],
        wifiSpeedMbps = j['wifi_speed_mbps'],
        powerOutlets = j['power_outlets'],
        aircon = j['aircon'],
        comfortableSeating = j['comfortable_seating'],
        cozy = j['cozy'],
        quietSpace = j['quiet_space'],
        goodForCalls = j['good_for_calls'],
        callRoom = j['call_room'],
        monitorAvailable = j['monitor'],
        officeChairs = j['office_chairs'],
        access24h = j['access_24h'],
        website = j['website'],
        instagram = j['instagram'],
        ratingSnapshot = j['google_rating_snapshot'],
        reviewsSnapshot = j['google_reviews_snapshot'],
        fallbackHours = j['opening_hours'] as Map<String, dynamic>?;

  WorkFriendly get workFriendly {
    if (laptopsAllowed == true) return WorkFriendly.yes;
    if (laptopsAllowed == false) return WorkFriendly.no;
    // Coworking spaces are laptop-friendly by definition.
    if (type == 'coworking') return WorkFriendly.yes;
    return WorkFriendly.unknown;
  }

  num? get rating => live?.rating ?? ratingSnapshot;
  int? get reviewCount => live?.userRatingCount ?? reviewsSnapshot;

  /// Is the venue open right now? Prefers live Google hours,
  /// falls back to the seeded spreadsheet hours.
  bool? get openNow {
    if (access24h == true) return true;
    if (live?.openNow != null) return live!.openNow;
    return _fallbackOpenNow(DateTime.now());
  }

  /// Minutes until the venue closes (null if unknown or closed).
  int? get minutesToClose {
    if (access24h == true) return null; // never closes
    final now = DateTime.now();
    final close = live?.nextCloseTime(now) ?? _fallbackCloseTime(now);
    if (close == null) return null;
    final mins = close.difference(now).inMinutes;
    return mins >= 0 ? mins : null;
  }

  /// True when the venue closes at or after 22:00 today (or is 24h).
  bool get openLate {
    if (access24h == true) return true;
    final now = DateTime.now();
    final close = live?.nextCloseTime(now) ?? _fallbackCloseTime(now);
    if (close == null) return false;
    return close.hour >= 22 || close.day != now.day;
  }

  bool get is24h {
    if (access24h == true) return true;
    final today = _fallbackHoursToday(DateTime.now());
    return today != null && today.toLowerCase().contains('24');
  }

  /// Human label like "Closes in 2 h 15 min" / "Closing soon" / "Open 24 hours".
  String? closingLabel({int soonMinutes = 60}) {
    if (access24h == true || is24h) return 'Open 24 hours';
    if (openNow == false) return 'Closed';
    final mins = minutesToClose;
    if (mins == null) return openNow == true ? 'Open now' : null;
    if (mins <= soonMinutes) return 'Closing soon · ${_fmtMins(mins)}';
    return 'Closes in ${_fmtMins(mins)}';
  }

  static String _fmtMins(int mins) {
    final h = mins ~/ 60, m = mins % 60;
    if (h == 0) return '$m min';
    if (m == 0) return '$h h';
    return '$h h $m min';
  }

  // ---------- fallback (spreadsheet) hours ----------

  static const _dayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

  String? _fallbackHoursToday(DateTime now) {
    if (fallbackHours == null) return null;
    return fallbackHours![_dayKeys[now.weekday - 1]] as String?;
  }

  /// Parses "8:00 AM - 4:00 PM" / "8:30 - 11:30 PM" / "Closed".
  (DateTime, DateTime)? _fallbackRange(DateTime day) {
    final raw = fallbackHours?[_dayKeys[day.weekday - 1]] as String?;
    if (raw == null || raw.toLowerCase().contains('closed')) return null;
    if (raw.toLowerCase().contains('24')) {
      final start = DateTime(day.year, day.month, day.day);
      return (start, start.add(const Duration(days: 1)));
    }
    final m = RegExp(
            r'(\d{1,2}):(\d{2})\s*(AM|PM)?\s*[-–]\s*(\d{1,2}):(\d{2})\s*(AM|PM)?',
            caseSensitive: false)
        .firstMatch(raw);
    if (m == null) return null;
    int h1 = int.parse(m.group(1)!), min1 = int.parse(m.group(2)!);
    int h2 = int.parse(m.group(4)!), min2 = int.parse(m.group(5)!);
    final ap1 = m.group(3)?.toUpperCase(), ap2 = m.group(6)?.toUpperCase();
    if (ap2 == 'PM' && h2 != 12) h2 += 12;
    if (ap2 == 'AM' && h2 == 12) h2 = 0;
    // "8:30 - 11:30 PM": start inherits PM only if that keeps start < end.
    if (ap1 == 'PM' && h1 != 12) h1 += 12;
    if (ap1 == 'AM' && h1 == 12) h1 = 0;
    if (ap1 == null && ap2 == 'PM' && h1 + 12 <= h2 + 12 && h1 < 12) {
      // ambiguous start like "8:30 - 11:30 PM" -> assume same half of day
      // only when a plain reading would make the venue open before 6 AM.
      if (h1 < 6) h1 += 12;
    }
    var open = DateTime(day.year, day.month, day.day, h1, min1);
    var close = DateTime(day.year, day.month, day.day, h2, min2);
    if (!close.isAfter(open)) close = close.add(const Duration(days: 1));
    return (open, close);
  }

  bool? _fallbackOpenNow(DateTime now) {
    if (fallbackHours == null) return null;
    // Check today's range and yesterday's (for past-midnight closers).
    for (final day in [now, now.subtract(const Duration(days: 1))]) {
      final r = _fallbackRange(day);
      if (r != null && now.isAfter(r.$1) && now.isBefore(r.$2)) return true;
    }
    final today = _fallbackHoursToday(now);
    if (today == null) return null;
    return false;
  }

  DateTime? _fallbackCloseTime(DateTime now) {
    for (final day in [now, now.subtract(const Duration(days: 1))]) {
      final r = _fallbackRange(day);
      if (r != null && now.isAfter(r.$1) && now.isBefore(r.$2)) return r.$2;
    }
    return null;
  }

  /// Straight-line distance in metres between two coordinates (haversine).
  static double haversineM(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = _rad(lat2 - lat1), dLng = _rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180;

  String distanceLabel() {
    final d = distanceM;
    if (d == null) return '';
    if (d < 1000) return '${d.round()} m';
    return '${(d / 1000).toStringAsFixed(1)} km';
  }
}

/// Live details fetched from Google Places API (New).
class PlaceLive {
  final String? displayName;
  final num? rating;
  final int? userRatingCount;
  final bool? openNow;
  final double? lat;
  final double? lng;
  final String? address;

  /// regularOpeningHours.periods — [{open:{day,hour,minute}, close:{day,hour,minute}}]
  /// Google day: 0 = Sunday … 6 = Saturday.
  final List<dynamic>? periods;

  /// Pretty per-day descriptions from Google, e.g. "Monday: 8 AM – 4 PM".
  final List<String>? weekdayDescriptions;

  PlaceLive.fromJson(Map<String, dynamic> j)
      : displayName = j['displayName']?['text'],
        rating = j['rating'],
        userRatingCount = j['userRatingCount'],
        openNow = (j['currentOpeningHours'] ?? j['regularOpeningHours'])
            ?['openNow'],
        lat = (j['location']?['latitude'] as num?)?.toDouble(),
        lng = (j['location']?['longitude'] as num?)?.toDouble(),
        address = j['shortFormattedAddress'] ?? j['formattedAddress'],
        periods = (j['currentOpeningHours'] ?? j['regularOpeningHours'])
            ?['periods'],
        weekdayDescriptions =
            ((j['currentOpeningHours'] ?? j['regularOpeningHours'])
                    ?['weekdayDescriptions'] as List?)
                ?.cast<String>();

  /// The next time the venue closes, if it is open now.
  DateTime? nextCloseTime(DateTime now) {
    if (periods == null || openNow != true) return null;
    final googleToday = now.weekday % 7; // Dart Mon=1..Sun=7 -> Google Sun=0
    for (final p in periods!) {
      final open = p['open'], close = p['close'];
      if (open == null) continue;
      if (close == null) return null; // open 24/7
      // Consider periods opening today or yesterday (overnight).
      for (final dayOffset in [0, -1]) {
        final d = now.add(Duration(days: dayOffset));
        if (open['day'] != (d.weekday % 7)) continue;
        var openT = DateTime(d.year, d.month, d.day,
            open['hour'] ?? 0, open['minute'] ?? 0);
        var closeDayShift = (close['day'] - open['day']) % 7;
        if (closeDayShift < 0) closeDayShift += 7;
        var closeT = DateTime(d.year, d.month, d.day,
                close['hour'] ?? 0, close['minute'] ?? 0)
            .add(Duration(days: closeDayShift));
        if (now.isAfter(openT) && now.isBefore(closeT)) return closeT;
      }
    }
    return null;
  }
}

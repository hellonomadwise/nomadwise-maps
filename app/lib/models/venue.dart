import 'dart:math' as math;

/// Tri-state for work-friendliness: true / false / unknown (null).
enum WorkFriendly { yes, no, unknown }

class Venue {
  final String id;
  final String name;
  final String type; // 'cafe' | 'coworking'
  final String? neighbourhood;
  final String? city;
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

  /// Real food (lunch etc.), not just coffee and pastries.
  /// null = the community has not answered yet.
  final bool? servesFood;

  final String? website;
  final String? instagram;
  final num? ratingSnapshot;
  final int? reviewsSnapshot;

  /// Fallback opening hours from the seed spreadsheet, e.g.
  /// {"mon": "8:00 AM - 4:00 PM", ..., "sun": "Closed"}
  final Map<String, dynamic>? fallbackHours;

  /// When the community last confirmed this venue's info.
  final DateTime? lastConfirmedAt;

  /// Google photos curated away (food close-ups etc).
  final List<String> hiddenPhotos;

  /// Google photo names with the curated-away ones removed.
  List<String> get visiblePhotoNames => (live?.photoNames ?? [])
      .where((n) => !hiddenPhotos.contains(n))
      .toList();

  /// Raw database row (kept for offline caching).
  final Map<String, dynamic> raw;

  /// Live data filled in from Google Places at runtime.
  PlaceLive? live;

  /// Distance from the user, metres (computed client-side).
  double? distanceM;

  Venue.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'] ?? '',
        type = j['type'] ?? 'cafe',
        neighbourhood = j['neighbourhood'],
        city = j['city'],
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
        servesFood = j['serves_food'],
        website = j['website'],
        instagram = j['instagram'],
        ratingSnapshot = j['google_rating_snapshot'],
        reviewsSnapshot = j['google_reviews_snapshot'],
        fallbackHours = j['opening_hours'] as Map<String, dynamic>?,
        lastConfirmedAt = j['last_confirmed_at'] != null
            ? DateTime.tryParse(j['last_confirmed_at'])
            : null,
        hiddenPhotos =
            (j['hidden_photos'] as List?)?.cast<String>() ?? const [],
        raw = j {
    // The daily build job caches each venue's Google details in the
    // database (g_details). Loading that copy here means the app does
    // not need to call Google on every map open.
    if (j['g_details'] is Map) {
      live = PlaceLive.fromJson(Map<String, dynamic>.from(j['g_details']));
    }
  }

  /// How many of the core questions are still unanswered, each one is
  /// a coin-earning opportunity for contributors.
  int get unansweredCount => [
        laptopsAllowed,
        wifiSpeedMbps,
        powerOutlets,
        aircon,
        comfortableSeating,
        cozy,
        quietSpace,
      ].where((v) => v == null).length;

  /// "today" / "3 days ago" / "2 months ago", or null if never confirmed.
  String? get confirmedAgoLabel {
    final t = lastConfirmedAt;
    if (t == null) return null;
    final d = DateTime.now().difference(t);
    if (d.inDays < 1) return 'today';
    if (d.inDays == 1) return 'yesterday';
    if (d.inDays < 30) return '${d.inDays} days ago';
    if (d.inDays < 365) {
      final m = (d.inDays / 30).floor();
      return m == 1 ? '1 month ago' : '$m months ago';
    }
    final y = (d.inDays / 365).floor();
    return y == 1 ? '1 year ago' : '$y years ago';
  }

  /// Info older than 6 months (or never confirmed) counts as stale -
  /// which the app presents as an invitation to earn coins.
  bool get infoIsStale =>
      lastConfirmedAt == null ||
      DateTime.now().difference(lastConfirmedAt!).inDays > 180;

  /// Should this venue match the "Food" filter? Community answer wins;
  /// with no answer yet, Google's place types decide (a restaurant or
  /// sandwich shop very likely does real food, a plain cafe may not).
  bool get matchesFood {
    if (servesFood != null) return servesFood!;
    final types = <String>{
      ...?live?.types,
      if (live?.primaryType != null) live!.primaryType!,
    };
    return types.any((t) =>
        t == 'restaurant' ||
        t.endsWith('_restaurant') ||
        const {
          'sandwich_shop',
          'deli',
          'meal_takeaway',
          'meal_delivery',
          'food_court',
          'diner',
          'bistro',
        }.contains(t));
  }

  WorkFriendly get workFriendly {
    if (laptopsAllowed == true) return WorkFriendly.yes;
    if (laptopsAllowed == false) return WorkFriendly.no;
    // Coworking spaces are laptop-friendly by definition.
    if (type == 'coworking') return WorkFriendly.yes;
    return WorkFriendly.unknown;
  }

  /// Wifi speed formatted to one decimal place, e.g. "24.5".
  String? get wifiSpeedLabel {
    final s = wifiSpeedMbps;
    if (s == null) return null;
    return s.toDouble().toStringAsFixed(1);
  }

  num? get rating => live?.rating ?? ratingSnapshot;
  int? get reviewCount => live?.userRatingCount ?? reviewsSnapshot;

  /// Is the venue open right now? Computed from Google's weekly
  /// hours (works from the cached copy, so it stays correct without
  /// asking Google), falling back to the seeded spreadsheet hours.
  bool? get openNow {
    if (access24h == true) return true;
    final computed = live?.openNowAt(DateTime.now());
    if (computed != null) return computed;
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
  final String? city;
  final num? rating;
  final int? userRatingCount;
  final bool? openNow;
  final double? lat;
  final double? lng;
  final String? address;

  /// Google photo resource names (turn into URLs via PlacesService.photoUrl).
  final List<String> photoNames;

  /// Google's classification, e.g. 'cafe', 'restaurant',
  /// 'brunch_restaurant'. Powers the "Food" filter fallback.
  final String? primaryType;
  final List<String>? types;

  /// regularOpeningHours.periods, [{open:{day,hour,minute}, close:{day,hour,minute}}]
  /// Google day: 0 = Sunday … 6 = Saturday.
  final List<dynamic>? periods;

  /// Pretty per-day descriptions from Google, e.g. "Monday: 8 AM – 4 PM".
  final List<String>? weekdayDescriptions;

  PlaceLive.fromJson(Map<String, dynamic> j)
      : displayName = j['displayName']?['text'],
        city = _cityFrom(j['addressComponents']),
        rating = j['rating'],
        userRatingCount = j['userRatingCount'],
        openNow = (j['currentOpeningHours'] ?? j['regularOpeningHours'])
            ?['openNow'],
        lat = (j['location']?['latitude'] as num?)?.toDouble(),
        lng = (j['location']?['longitude'] as num?)?.toDouble(),
        address = j['shortFormattedAddress'] ?? j['formattedAddress'],
        photoNames = ((j['photos'] as List?) ?? [])
            .map((p) => p['name'] as String)
            .toList(),
        primaryType = j['primaryType'],
        types = (j['types'] as List?)?.cast<String>(),
        periods = (j['currentOpeningHours'] ?? j['regularOpeningHours'])
            ?['periods'],
        weekdayDescriptions =
            ((j['currentOpeningHours'] ?? j['regularOpeningHours'])
                    ?['weekdayDescriptions'] as List?)
                ?.cast<String>();

  /// The place's city, from Google's address components.
  static String? _cityFrom(dynamic components) {
    if (components is! List) return null;
    for (final wanted in [
      'locality',
      'postal_town',
      'administrative_area_level_2',
    ]) {
      for (final c in components) {
        final types = (c['types'] as List?)?.cast<String>() ?? [];
        if (types.contains(wanted)) {
          return c['longText'] ?? c['shortText'];
        }
      }
    }
    return null;
  }

  /// Walks the weekly periods and reports (isOpen, closesAt) at [now].
  /// closesAt is null when the place never closes (24/7) or is closed.
  /// Returns null when Google listed no hours at all.
  (bool, DateTime?)? _statusAt(DateTime now) {
    if (periods == null || periods!.isEmpty) return null;
    for (final p in periods!) {
      final open = p['open'], close = p['close'];
      if (open == null) continue;
      if (close == null) return (true, null); // open 24/7
      // Consider periods opening today or yesterday (overnight).
      for (final dayOffset in [0, -1]) {
        final d = now.add(Duration(days: dayOffset));
        if (open['day'] != (d.weekday % 7)) continue;
        final openT = DateTime(d.year, d.month, d.day,
            open['hour'] ?? 0, open['minute'] ?? 0);
        var closeDayShift = (close['day'] - open['day']) % 7;
        if (closeDayShift < 0) closeDayShift += 7;
        final closeT = DateTime(d.year, d.month, d.day,
                close['hour'] ?? 0, close['minute'] ?? 0)
            .add(Duration(days: closeDayShift));
        if (now.isAfter(openT) && now.isBefore(closeT)) {
          return (true, closeT);
        }
      }
    }
    return (false, null);
  }

  /// Open right now? Computed live from the weekly hours, so a
  /// cached copy of this data stays accurate. Null when unknown.
  bool? openNowAt(DateTime now) => _statusAt(now)?.$1;

  /// The next time the venue closes, if it is open now.
  DateTime? nextCloseTime(DateTime now) {
    final s = _statusAt(now);
    if (s == null || !s.$1) return null;
    return s.$2;
  }
}

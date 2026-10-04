/// A place the nightly job found and marked worth a look, waiting in
/// the control centre's Candidates list for a founder's decision
/// (migration 129). Not a space yet: it becomes one, already queued for
/// the site, when a founder taps "Queue for the site".
class Candidate {
  final String placeId;
  final String name;
  final double? lat;
  final double? lng;
  final String? primaryType;
  final bool coworking;
  final num? rating;
  final int? userRatingCount;

  /// How many of Google's reviews (five at most) mention each thing.
  final int wifi;
  final int power;
  final int laptop;
  final int food;

  /// False while the nightly scan has not read this place's reviews
  /// yet (only coworking spaces reach the list that early).
  final bool checked;

  /// Where it stands in the list: strongest evidence first.
  final int score;

  /// The city page it belongs to (the nearest Region within 30 km),
  /// else the city whose sweep found it, else "No city page nearby".
  final String area;
  final String? regionId;
  final String? regionName;
  final String? regionCountry;

  const Candidate({
    required this.placeId,
    required this.name,
    this.lat,
    this.lng,
    this.primaryType,
    this.coworking = false,
    this.rating,
    this.userRatingCount,
    this.wifi = 0,
    this.power = 0,
    this.laptop = 0,
    this.food = 0,
    this.checked = true,
    this.score = 0,
    this.area = '',
    this.regionId,
    this.regionName,
    this.regionCountry,
  });

  factory Candidate.fromJson(Map<String, dynamic> j) => Candidate(
        placeId: '${j['google_place_id']}',
        name: (j['name'] ?? 'Unnamed').toString(),
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        primaryType: j['primary_type'] as String?,
        coworking: j['coworking'] == true,
        rating: j['rating'] as num?,
        userRatingCount: (j['user_rating_count'] as num?)?.toInt(),
        wifi: (j['wifi'] as num?)?.toInt() ?? 0,
        power: (j['power'] as num?)?.toInt() ?? 0,
        laptop: (j['laptop'] as num?)?.toInt() ?? 0,
        food: (j['food'] as num?)?.toInt() ?? 0,
        checked: j['checked'] != false,
        score: (j['score'] as num?)?.toInt() ?? 0,
        area: (j['area'] ?? '').toString(),
        regionId: j['region_id'] as String?,
        regionName: j['region_name'] as String?,
        regionCountry: j['region_country'] as String?,
      );

  /// True when the site has a city page this place would sit under.
  bool get hasCityPage => regionId != null;

  String get typeLabel => coworking ? 'Coworking space' : 'Cafe';

  /// "4.7 (249)" or null when Google has no rating.
  String? get ratingLabel {
    final r = rating;
    if (r == null) return null;
    final n = userRatingCount;
    return '${r.toStringAsFixed(1)}${n != null ? ' ($n)' : ''}';
  }

  static String _mentions(int n, String what) =>
      '$n ${n == 1 ? 'review mentions' : 'reviews mention'} $what';

  /// Why it is on the list, strongest first, in plain words. A
  /// coworking space needs no reason: its card says what it is.
  List<String> get reasons => [
        if (laptop > 0) _mentions(laptop, 'working there'),
        if (power > 0) _mentions(power, 'plugs'),
        if (wifi > 0) _mentions(wifi, 'WiFi'),
        if (!checked) 'Reviews not read yet',
      ];

  /// The place on Google Maps (the full listing: photos, all reviews).
  String get mapsUrl =>
      'https://www.google.com/maps/search/?api=1'
      '&query=${Uri.encodeQueryComponent(name)}'
      '&query_place_id=${Uri.encodeQueryComponent(placeId)}';
}

/// One area in the Candidates picker: a city and how many wait there.
class CandidateArea {
  final String area;
  final int count;

  /// False when the site has no city page for it yet.
  final bool hasPage;

  const CandidateArea(
      {required this.area, required this.count, required this.hasPage});

  factory CandidateArea.fromJson(Map<String, dynamic> j) => CandidateArea(
        area: (j['area'] ?? '').toString(),
        count: (j['n'] as num?)?.toInt() ?? 0,
        hasPage: j['has_page'] == true,
      );
}

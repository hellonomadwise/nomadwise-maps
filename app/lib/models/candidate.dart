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

  /// Google searches a month for its name (Ahrefs, worldwide). Null
  /// when the place was found after the last lookup (migration 137).
  final int? searches;

  /// How far that number can be trusted: 'sure' (the name, or the name
  /// with its city), 'city' (only the name with the city counts),
  /// 'unsure' (the bare name, which may mean something else),
  /// 'general' (too common a name to measure) or 'none'.
  final String? searchConfidence;

  /// The phrase the searches were counted for ("the cluster").
  final String? searchPhrase;

  /// Searches a month for coworking in its city, and how many
  /// coworking spaces the site lists there today.
  final int? citySearches;
  final int cityListed;

  /// Above zero for a coworking space in a city where people search
  /// for coworking and the site lists fewer than eight of them.
  final int gapPoints;

  /// True when Google calls it a hotel, a hostel, a library and the
  /// like: its name is searched for that, not for a place to work.
  final bool otherType;

  /// Where it stands when the list is ordered "best bets first".
  final int priority;

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
    this.searches,
    this.searchConfidence,
    this.searchPhrase,
    this.citySearches,
    this.cityListed = 0,
    this.gapPoints = 0,
    this.otherType = false,
    this.priority = 0,
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
        searches: (j['searches'] as num?)?.toInt(),
        searchConfidence: j['search_confidence'] as String?,
        searchPhrase: j['search_phrase'] as String?,
        citySearches: (j['city_searches'] as num?)?.toInt(),
        cityListed: (j['city_listed'] as num?)?.toInt() ?? 0,
        gapPoints: (j['gap_points'] as num?)?.toInt() ?? 0,
        otherType: j['other_type'] == true,
        priority: (j['priority'] as num?)?.toInt() ?? 0,
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

  /// 1234 as "1,234".
  static String thousands(int n) {
    final digits = n.abs().toString();
    final out = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  /// Google's type in plain words: "guest house" for "guest_house".
  String get typeWords => (primaryType ?? '').replaceAll('_', ' ').trim();

  /// What the search numbers say about it, in plain words, each with
  /// whether it counts in the place's favour. Empty when the place
  /// has not been looked up and its city is not a gap.
  List<(String, bool)> get searchReasons {
    final out = <(String, bool)>[];
    final n = searches ?? 0;
    final phrase = (searchPhrase ?? '').trim();
    final what = phrase.isEmpty ? 'its name' : '"$phrase"';
    final conf = searchConfidence;
    if (conf == 'general') {
      out.add(('Name too common to measure searches', false));
    } else if (conf == 'none') {
      out.add(('No searches found for its name', false));
    } else if (conf == 'sure' || conf == 'city' || conf == 'unsure') {
      final count = 'About ${thousands(n)} searches a month for $what';
      if (n < 10) {
        out.add(('Hardly searched by name', false));
      } else if (otherType) {
        final kind = typeWords;
        final article =
            kind.isNotEmpty && 'aeio'.contains(kind[0]) ? 'an' : 'a';
        out.add((
          kind.isEmpty
              ? '$count, but not as a place to work'
              : '$count, but as $article $kind, not a place to work',
          false
        ));
      } else if (conf == 'unsure') {
        out.add(('$count, which may mean other things', false));
      } else {
        out.add((count, true));
      }
    }
    if (gapPoints > 0) {
      final listed = cityListed == 0
          ? 'no coworking spaces'
          : cityListed == 1
              ? '1 coworking space'
              : '$cityListed coworking spaces';
      out.add((
        'People search for coworking here and we list $listed',
        true
      ));
    }
    return out;
  }

  /// What to type into Google to find it: its name, and its city when
  /// the name does not already say it ("Generator London" stays as it
  /// is; "Hotel Conqueridor" becomes "Hotel Conqueridor Valencia").
  String get googleQuery {
    final n = name.trim();
    final city = (regionName ?? (hasCityPage ? area : area.split(',').first))
        .trim();
    if (city.isEmpty ||
        city == 'No city page nearby' ||
        n.toLowerCase().contains(city.toLowerCase())) {
      return n;
    }
    return '$n $city';
  }

  /// The ordinary Google results page for it (its own website, what
  /// it calls itself, its panel on the right), not Google Maps.
  String get googleUrl =>
      'https://www.google.com/search?q=${Uri.encodeQueryComponent(googleQuery)}';

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

  /// Searches a month for coworking in this city and for cafes to
  /// work from there, and how hard Ahrefs rates the city search
  /// (0 easy, 100 hard). Null when the city has not been looked up.
  final int? coworkingSearches;
  final int? cafeSearches;
  final int? difficulty;

  /// What the site lists there today. Null when not known.
  final int? coworkingListed;
  final int? cafesListed;

  const CandidateArea({
    required this.area,
    required this.count,
    required this.hasPage,
    this.coworkingSearches,
    this.cafeSearches,
    this.difficulty,
    this.coworkingListed,
    this.cafesListed,
  });

  factory CandidateArea.fromJson(Map<String, dynamic> j) => CandidateArea(
        area: (j['area'] ?? '').toString(),
        count: (j['n'] as num?)?.toInt() ?? 0,
        hasPage: j['has_page'] == true,
        coworkingSearches: (j['coworking_searches'] as num?)?.toInt(),
        cafeSearches: (j['cafe_searches'] as num?)?.toInt(),
        difficulty: (j['difficulty'] as num?)?.toInt(),
        coworkingListed: (j['coworking_listed'] as num?)?.toInt(),
        cafesListed: (j['cafes_listed'] as num?)?.toInt(),
      );

  /// The same area with a different number waiting.
  CandidateArea withCount(int n) => CandidateArea(
        area: area,
        count: n,
        hasPage: hasPage,
        coworkingSearches: coworkingSearches,
        cafeSearches: cafeSearches,
        difficulty: difficulty,
        coworkingListed: coworkingListed,
        cafesListed: cafesListed,
      );

  /// One line on what the search numbers say about this city, or null
  /// when it has not been looked up.
  String? get searchLine {
    final cw = coworkingSearches;
    if (cw == null) return null;
    final out = StringBuffer(cw < 10
        ? 'Hardly any searches for coworking in $area.'
        : 'About ${Candidate.thousands(cw)} searches a month for coworking '
            'in $area.');
    final d = difficulty;
    if (d != null && cw >= 10) {
      // Ahrefs' own bands for its difficulty score.
      final band = d <= 10
          ? 'easy'
          : d <= 30
              ? 'medium'
              : d <= 70
                  ? 'hard'
                  : 'very hard';
      out.write(' How hard to rank, by Ahrefs: $band ($d of 100).');
    }
    final listed = coworkingListed;
    if (listed != null) {
      final spaces = listed == 1 ? 'space' : 'spaces';
      final cafes = cafesListed;
      if (cafes == null) {
        out.write(' We list $listed coworking $spaces there.');
      } else {
        final cafeWord = cafes == 1 ? 'cafe' : 'cafes';
        out.write(' We list $listed coworking $spaces and $cafes $cafeWord '
            'there.');
      }
    }
    return out.toString();
  }
}

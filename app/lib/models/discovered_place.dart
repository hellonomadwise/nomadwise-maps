/// A cafe/coworking space Google knows about that nobody has screened yet.
/// Lives in the `discovered_places` cache; becomes a real Venue the moment
/// a user reviews it.
class DiscoveredPlace {
  final String placeId;
  final String name;
  final double lat;
  final double lng;
  final String? primaryType;
  final num? rating;
  final int? userRatingCount;

  /// Review mention counts stored by the nightly job (null = not
  /// checked yet). signalNegative counts reviews arguing AGAINST
  /// working there ("no laptops allowed").
  final int? signalWifi;
  final int? signalPower;
  final int? signalLaptop;
  final int? signalNegative;

  /// Reviews mentioning real food (lunch, brunch, salads...).
  final int? signalFood;

  /// Should this place match the "Food" filter? Review mentions or a
  /// restaurant-style Google type both count.
  bool get foodLikely =>
      (signalFood ?? 0) > 0 ||
      (primaryType != null &&
          (primaryType == 'restaurant' ||
              primaryType!.endsWith('_restaurant') ||
              const {
                'sandwich_shop',
                'deli',
                'meal_takeaway',
                'meal_delivery',
                'food_court',
                'diner',
                'bistro',
              }.contains(primaryType)));

  /// Petrol stations and convenience chains are never work spots,
  /// however Google types them (Circle K sells coffee, it is still a
  /// petrol station). Blocked globally: never shown, never cached.
  /// Migration 44 removes any already stored.
  static final _excludedNames =
      RegExp(r'circle\s*k\b', caseSensitive: false);
  static const _excludedTypes = {'gas_station', 'convenience_store'};

  bool get excluded =>
      _excludedNames.hasMatch(name) ||
      _excludedTypes.contains(primaryType);

  /// True when this place's Google reviews mention wifi, plugs or
  /// laptops positively, with no warnings against working there.
  bool get promising =>
      (signalNegative ?? 0) == 0 &&
      ((signalWifi ?? 0) > 0 ||
          (signalPower ?? 0) > 0 ||
          (signalLaptop ?? 0) > 0);

  DiscoveredPlace({
    required this.placeId,
    required this.name,
    required this.lat,
    required this.lng,
    this.primaryType,
    this.rating,
    this.userRatingCount,
    this.signalWifi,
    this.signalPower,
    this.signalLaptop,
    this.signalNegative,
    this.signalFood,
  });

  /// From a Google Places searchNearby result.
  factory DiscoveredPlace.fromGoogle(Map<String, dynamic> j) =>
      DiscoveredPlace(
        placeId: j['id'],
        name: j['displayName']?['text'] ?? 'Unnamed',
        lat: (j['location']?['latitude'] as num).toDouble(),
        lng: (j['location']?['longitude'] as num).toDouble(),
        primaryType: j['primaryType'],
        rating: j['rating'],
        userRatingCount: j['userRatingCount'],
      );

  /// From a row of our own discovered_places cache.
  factory DiscoveredPlace.fromRow(Map<String, dynamic> r) =>
      DiscoveredPlace(
        placeId: r['google_place_id'],
        name: r['name'],
        lat: (r['lat'] as num).toDouble(),
        lng: (r['lng'] as num).toDouble(),
        primaryType: r['primary_type'],
        rating: r['rating'],
        userRatingCount: r['user_rating_count'],
        signalWifi: r['signal_wifi'],
        signalPower: r['signal_power'],
        signalLaptop: r['signal_laptop'],
        signalNegative: r['signal_negative'],
        signalFood: r['signal_food'],
      );

  Map<String, dynamic> toRow() => {
        'google_place_id': placeId,
        'name': name,
        'lat': lat,
        'lng': lng,
        'primary_type': primaryType,
        'rating': rating,
        'user_rating_count': userRatingCount,
        if (signalWifi != null) 'signal_wifi': signalWifi,
        if (signalPower != null) 'signal_power': signalPower,
        if (signalLaptop != null) 'signal_laptop': signalLaptop,
        if (signalNegative != null) 'signal_negative': signalNegative,
        if (signalFood != null) 'signal_food': signalFood,
        'fetched_at': DateTime.now().toIso8601String(),
      };

  /// A copy carrying freshly scanned review signals: opening a card
  /// promotes the pin immediately instead of waiting for the nightly
  /// scanner to reach this place.
  DiscoveredPlace withSignals(
          {required int wifi,
          required int power,
          required int laptop,
          required int food,
          required int negative}) =>
      DiscoveredPlace(
        placeId: placeId,
        name: name,
        lat: lat,
        lng: lng,
        primaryType: primaryType,
        rating: rating,
        userRatingCount: userRatingCount,
        signalWifi: wifi,
        signalPower: power,
        signalLaptop: laptop,
        signalNegative: negative,
        signalFood: food,
      );
}

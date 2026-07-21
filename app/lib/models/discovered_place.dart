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
      );

  Map<String, dynamic> toRow() => {
        'google_place_id': placeId,
        'name': name,
        'lat': lat,
        'lng': lng,
        'primary_type': primaryType,
        'rating': rating,
        'user_rating_count': userRatingCount,
        'fetched_at': DateTime.now().toIso8601String(),
      };
}

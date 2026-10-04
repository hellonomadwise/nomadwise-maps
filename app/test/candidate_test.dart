import 'package:flutter_test/flutter_test.dart';
import 'package:nomadwise_maps/models/candidate.dart';

/// A row as public.admin_candidates() returns it (migration 129).
Map<String, dynamic> row(Map<String, dynamic> extra) => {
      'google_place_id': 'ChIJ2QxTcyc72jARSx2NolaZ6pw',
      'name': 'HappyBlue Coffee',
      'lat': 18.7878,
      'lng': 98.98311,
      'primary_type': 'coffee_shop',
      'coworking': false,
      'rating': 4.9,
      'user_rating_count': 394,
      'wifi': 2,
      'power': 1,
      'laptop': 3,
      'food': 0,
      'checked': true,
      'score': 19,
      'area': 'Chiang Mai',
      'region_id': 'reg_cnx',
      'region_name': 'Chiang Mai',
      'region_country': 'Thailand',
      ...extra,
    };

void main() {
  group('candidate from the database row', () {
    test('reads every field', () {
      final c = Candidate.fromJson(row({}));
      expect(c.placeId, 'ChIJ2QxTcyc72jARSx2NolaZ6pw');
      expect(c.name, 'HappyBlue Coffee');
      expect(c.lat, closeTo(18.7878, 1e-9));
      expect(c.coworking, isFalse);
      expect(c.userRatingCount, 394);
      expect(c.laptop, 3);
      expect(c.score, 19);
      expect(c.area, 'Chiang Mai');
      expect(c.hasCityPage, isTrue);
      expect(c.typeLabel, 'Cafe');
    });

    test('whole-number ratings and counts sent as doubles still read', () {
      final c = Candidate.fromJson(
          row({'rating': 5, 'user_rating_count': 257.0, 'score': 7.0}));
      expect(c.ratingLabel, '5.0 (257)');
      expect(c.score, 7);
    });

    test('missing values fall back instead of throwing', () {
      final c = Candidate.fromJson({'google_place_id': 'p1'});
      expect(c.name, 'Unnamed');
      expect(c.ratingLabel, isNull);
      expect(c.wifi, 0);
      expect(c.checked, isTrue);
      expect(c.hasCityPage, isFalse);
      expect(c.reasons, isEmpty);
    });
  });

  group('why a place is on the list', () {
    test('strongest evidence first, counted in plain words', () {
      final c = Candidate.fromJson(row({}));
      expect(c.reasons, [
        '3 reviews mention laptops or working',
        '1 review mentions plugs',
        '2 reviews mention WiFi',
      ]);
    });

    test('a coworking space nobody has scanned yet says so', () {
      final c = Candidate.fromJson(row({
        'coworking': true,
        'wifi': 0,
        'power': 0,
        'laptop': 0,
        'checked': false,
      }));
      expect(c.typeLabel, 'Coworking space');
      expect(c.reasons, ['Coworking space', 'Reviews not read yet']);
    });

    test('no city page nearby is flagged', () {
      final c = Candidate.fromJson(row({
        'area': 'No city page nearby',
        'region_id': null,
        'region_name': null,
        'region_country': null,
      }));
      expect(c.hasCityPage, isFalse);
    });
  });

  test('the map link carries the name and the place id', () {
    final c = Candidate.fromJson(row({'name': 'Cafe & Co'}));
    final uri = Uri.parse(c.mapsUrl);
    expect(uri.host, 'www.google.com');
    expect(uri.queryParameters['query'], 'Cafe & Co');
    expect(uri.queryParameters['query_place_id'],
        'ChIJ2QxTcyc72jARSx2NolaZ6pw');
  });

  test('an area reads its count and whether the site has a page', () {
    final a = CandidateArea.fromJson(
        {'area': 'Pai, Thailand', 'n': 12, 'has_page': false});
    expect(a.area, 'Pai, Thailand');
    expect(a.count, 12);
    expect(a.hasPage, isFalse);
  });
}

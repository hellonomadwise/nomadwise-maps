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
        '3 reviews mention working there',
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
      expect(c.reasons, ['Reviews not read yet']);
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

  test('the Google link searches the name, with the city when needed', () {
    // the name already says the city
    final a = Candidate.fromJson(row({
      'name': 'Generator London',
      'area': 'London',
      'region_id': 'r1',
      'region_name': 'London',
      'region_country': 'England',
    }));
    expect(a.googleQuery, 'Generator London');
    final uri = Uri.parse(a.googleUrl);
    expect(uri.host, 'www.google.com');
    expect(uri.path, '/search');
    expect(uri.queryParameters['q'], 'Generator London');
    // it does not: the city is added
    final b = Candidate.fromJson(row({
      'name': 'Hotel Conqueridor',
      'area': 'Valencia',
      'region_id': 'r2',
      'region_name': 'Valencia',
      'region_country': 'Spain',
    }));
    expect(b.googleQuery, 'Hotel Conqueridor Valencia');
    // no city page: the city of the sweep, without its country
    final c = Candidate.fromJson(row({
      'name': 'Cafe & Co',
      'area': 'Pai, Thailand',
      'region_id': null,
      'region_name': null,
      'region_country': null,
    }));
    expect(c.googleQuery, 'Cafe & Co Pai');
    expect(Uri.parse(c.googleUrl).queryParameters['q'], 'Cafe & Co Pai');
    // nothing known about where it is: the name alone
    final d = Candidate.fromJson(row({
      'name': 'Cafe & Co',
      'area': 'No city page nearby',
      'region_id': null,
      'region_name': null,
      'region_country': null,
    }));
    expect(d.googleQuery, 'Cafe & Co');
  });

  test('with an address the Google link finds the one branch', () {
    final c = Candidate.fromJson(row({
      'name': 'WeWork - Office Space & Coworking',
      'area': 'London',
      'region_name': 'London',
      'address': ' 8 Devonshire Square, London ',
    }));
    expect(c.address, '8 Devonshire Square, London');
    expect(c.googleQuery,
        'WeWork - Office Space & Coworking 8 Devonshire Square, London');
    // no address read yet: null, never an empty line on the card
    expect(Candidate.fromJson(row({'address': ''})).address, isNull);
    expect(Candidate.fromJson(row({})).address, isNull);
  });

  group('a brand with several places (migration 139)', () {
    test('its searches are shared, and do not count for one branch', () {
      final c = Candidate.fromJson(row({
        'name': 'WeWork - Office Space & Coworking',
        'coworking': true,
        'searches': 2300,
        'search_confidence': 'city',
        'search_phrase': 'wework london',
        'search_shared': 4,
        'same_name': 4,
      }));
      expect(c.searchReasons, [
        (
          'About 2,300 searches a month for "wework london", shared by 4 '
              'places with this name',
          false
        ),
      ]);
    });

    test('a name several places carry is said when no searches say it', () {
      final c = Candidate.fromJson(row({
        'name': 'CreativeCubes.Co - Carlton',
        'searches': 0,
        'search_confidence': 'none',
        'search_phrase': 'creativecubes co',
        'search_shared': 7,
        'same_name': 7,
      }));
      expect(c.searchReasons, [
        ('No searches found for its name', false),
        ('One of 7 places with this name here', false),
      ]);
    });

    test('a place alone under its name says neither', () {
      final c = Candidate.fromJson(row({
        'searches': 870,
        'search_confidence': 'sure',
        'search_phrase': 'the cluster',
      }));
      expect(c.sameName, 1);
      expect(c.searchShared, 1);
      expect(c.searchReasons,
          [('About 870 searches a month for "the cluster"', true)]);
    });
  });

  group('how sure the reviews make us a cafe is a place to work', () {
    String? grade(int laptop, int power, int wifi, {bool checked = true}) =>
        Candidate.fromJson(row({
          'laptop': laptop,
          'power': power,
          'wifi': wifi,
          'checked': checked,
        })).workEvidence;

    test('strong: two or more reviews talk about working there', () {
      expect(grade(2, 0, 0), 'strong');
      expect(grade(3, 1, 2), 'strong');
    });

    test('some: one talks about working there, or plugs and WiFi both', () {
      expect(grade(1, 0, 0), 'some');
      // one review can say both, so this is not two voices
      expect(grade(1, 1, 0), 'some');
      expect(grade(1, 0, 1), 'some');
      expect(grade(0, 1, 2), 'some');
    });

    test('thin: WiFi alone or plugs alone', () {
      expect(grade(0, 0, 1), 'thin');
      expect(grade(0, 2, 0), 'thin');
      final c = Candidate.fromJson(row({'laptop': 0, 'power': 0, 'wifi': 1}));
      expect(c.workEvidenceLabel,
          'Thin signs people work here: look before you queue');
    });

    test('other sites and Google\'s search count too (migration 140)', () {
      Candidate c(Map<String, dynamic> extra) => Candidate.fromJson(
          row({'laptop': 0, 'power': 0, 'wifi': 0, 'checked': false, ...extra}));
      // one kind twice over
      expect(c({'mentions': 2}).workEvidence, 'strong');
      expect(
          c({
            'work_phrases': ['laptop friendly cafe', 'cafe to work from']
          }).workEvidence,
          'strong');
      // two kinds agreeing
      expect(
          c({
            'mentions': 1,
            'work_phrases': ['cafe to work from']
          }).workEvidence,
          'strong');
      expect(c({'laptop': 1, 'mentions': 1}).workEvidence, 'strong');
      // one of them once
      expect(c({'mentions': 1}).workEvidence, 'some');
      expect(
          c({
            'work_phrases': ['laptop friendly cafe']
          }).workEvidence,
          'some');
      // nothing at all, reviews not read
      expect(c({}).workEvidence, 'unread');
    });

    test('who names it is said in words', () {
      Candidate c(int n, List<String> names) => Candidate.fromJson(
          row({'mentions': n, 'mention_sources': names}));
      expect(c(0, []).outsideReasons, isEmpty);
      expect(c(1, ['Thatsup']).outsideReasons, ['Named by Thatsup']);
      expect(c(2, ['Thatsup', 'Blog']).outsideReasons,
          ['Named by 2 sites: Thatsup and Blog']);
      expect(c(3, ['A', 'B', 'C']).outsideReasons,
          ['Named by 3 sites: A, B and C']);
      expect(c(6, ['A', 'B', 'C', 'D']).outsideReasons,
          ['Named by 6 sites: A, B, C and 3 more']);
      // a count without names still says something
      expect(c(2, []).outsideReasons, ['Named by 2 other sites']);
      expect(
          Candidate.fromJson(row({
            'work_phrases': ['laptop friendly cafe', '', null]
          })).outsideReasons,
          ['Google returns it for "laptop friendly cafe"']);
    });

    test('a coworking space needs no such sign', () {
      final c = Candidate.fromJson(row({'coworking': true}));
      expect(c.workEvidence, isNull);
      expect(c.workEvidenceLabel, isNull);
    });

    test('counts kept by the map mean the reviews were read', () {
      // The map keeps the counts without the day they were read.
      final c = Candidate.fromJson(
          row({'laptop': 0, 'power': 0, 'wifi': 1, 'checked': false}));
      expect(c.reviewsRead, isTrue);
      expect(c.reasons, ['1 review mentions WiFi']);
      final d = Candidate.fromJson(
          row({'laptop': 0, 'power': 0, 'wifi': 0, 'checked': false}));
      expect(d.reviewsRead, isFalse);
      expect(d.workEvidence, 'unread');
      expect(d.workEvidenceLabel, isNull);
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
    // Not looked up: nothing to say about searches.
    expect(a.searchLine, isNull);
  });

  group('what the search numbers say (migration 137)', () {
    test('a row without them says nothing', () {
      final c = Candidate.fromJson(row({}));
      expect(c.searches, isNull);
      expect(c.searchReasons, isEmpty);
    });

    test('a searched name counts in its favour', () {
      final c = Candidate.fromJson(row({
        'searches': 1870,
        'search_confidence': 'sure',
        'search_phrase': 'the cluster',
        'priority': 95,
      }));
      expect(c.priority, 95);
      expect(c.searchReasons, [
        ('About 1,870 searches a month for "the cluster"', true),
      ]);
    });

    test('a name that may mean something else is said so', () {
      final c = Candidate.fromJson(row({
        'searches': 300.0,
        'search_confidence': 'unsure',
        'search_phrase': 'true space',
      }));
      expect(c.searchReasons, [
        (
          'About 300 searches a month for "true space", which may mean '
              'other things',
          false
        ),
      ]);
    });

    test('a hostel is searched for as a hostel', () {
      final c = Candidate.fromJson(row({
        'primary_type': 'guest_house',
        'searches': 9000,
        'search_confidence': 'sure',
        'search_phrase': 'generator london',
        'other_type': true,
      }));
      expect(c.searchReasons, [
        (
          'About 9,000 searches a month for "generator london", but as a '
              'guest house, not a place to work',
          false
        ),
      ]);
    });

    test('no searches, a common name and a quiet name each say so', () {
      Candidate with_(String confidence, int searches) =>
          Candidate.fromJson(row(
              {'searches': searches, 'search_confidence': confidence}));
      expect(with_('none', 0).searchReasons,
          [('No searches found for its name', false)]);
      expect(with_('general', 0).searchReasons,
          [('Name too common to measure searches', false)]);
      expect(with_('city', 5).searchReasons,
          [('Hardly searched by name', false)]);
    });

    test('a coworking space in a gap city says how many we list', () {
      final c = Candidate.fromJson(row({
        'coworking': true,
        'gap_points': 5,
        'city_listed': 1,
        'city_searches': 1800,
      }));
      expect(c.searchReasons, [
        ('People search for coworking here and we list 1 coworking space', true),
      ]);
      final none = Candidate.fromJson(
          row({'coworking': true, 'gap_points': 3, 'city_listed': 0}));
      expect(none.searchReasons, [
        (
          'People search for coworking here and we list no coworking spaces',
          true
        ),
      ]);
    });

    test('thousands are written with commas', () {
      expect(Candidate.thousands(0), '0');
      expect(Candidate.thousands(999), '999');
      expect(Candidate.thousands(1000), '1,000');
      expect(Candidate.thousands(49580), '49,580');
      expect(Candidate.thousands(1234567), '1,234,567');
    });

    test('a city says what people search for there and what we list', () {
      final a = CandidateArea.fromJson({
        'area': 'Lisbon',
        'n': 92,
        'has_page': true,
        'coworking_searches': 850,
        'cafe_searches': 80,
        'difficulty': 0,
        'coworking_listed': 15,
        'cafes_listed': 33,
      });
      expect(
          a.searchLine,
          'About 850 searches a month for coworking in Lisbon. How hard to '
          'rank, by Ahrefs: easy (0 of 100). We list 15 coworking spaces '
          'and 33 cafes there.');
      // One fewer waiting keeps what is known about the city.
      final b = a.withCount(91);
      expect(b.count, 91);
      expect(b.searchLine, a.searchLine);
    });

    test('a hard city, and one with no difficulty known', () {
      final hard = CandidateArea.fromJson({
        'area': 'Barcelona',
        'n': 3,
        'has_page': true,
        'coworking_searches': 3300,
        'difficulty': 74,
        'coworking_listed': 1,
      });
      expect(
          hard.searchLine,
          'About 3,300 searches a month for coworking in Barcelona. How '
          'hard to rank, by Ahrefs: very hard (74 of 100). We list 1 '
          'coworking space there.');
      final plain = CandidateArea.fromJson({
        'area': 'Chiang Mai',
        'n': 29,
        'has_page': true,
        'coworking_searches': 350,
      });
      expect(plain.searchLine,
          'About 350 searches a month for coworking in Chiang Mai.');
    });
  });

  group('the short list (strong candidates, one at a time)', () {
    test('a cafe needs strong signs', () {
      // three reviews about working there: strong
      expect(Candidate.fromJson(row({})).shortlisted, isTrue);
      // WiFi alone: thin
      expect(
          Candidate.fromJson(row({'laptop': 0, 'power': 0, 'wifi': 1}))
              .shortlisted,
          isFalse);
      // one review and one other site: two kinds agreeing
      expect(
          Candidate.fromJson(row({
            'laptop': 1,
            'mentions': 1,
            'mention_sources': ['Laptop Friendly Cafe'],
          })).shortlisted,
          isTrue);
    });

    test('a coworking space needs one sign, or a good rating', () {
      final quiet = row({
        'coworking': true,
        'laptop': 0,
        'power': 0,
        'wifi': 0,
        'rating': 4.0,
        'user_rating_count': 12,
      });
      expect(Candidate.fromJson(quiet).shortlisted, isFalse);
      expect(Candidate.fromJson({...quiet, 'mentions': 1}).shortlisted, isTrue);
      expect(
          Candidate.fromJson(
              {...quiet, 'rating': 4.6, 'user_rating_count': 40}).shortlisted,
          isTrue);
    });

    test('no city page, a hotel or a chain keeps it off', () {
      expect(Candidate.fromJson(row({'region_id': null})).shortlisted, isFalse);
      expect(Candidate.fromJson(row({'other_type': true})).shortlisted, isFalse);
      expect(Candidate.fromJson(row({'same_name': 4})).shortlisted, isFalse);
    });

    test('the strongest comes first', () {
      final listed = Candidate.fromJson(row({'mentions': 3}));
      final plain = Candidate.fromJson(row({}));
      final cowork = Candidate.fromJson(row({'coworking': true}));
      expect(listed.strength, greaterThan(cowork.strength));
      expect(cowork.strength, greaterThan(plain.strength));
    });
  });
}

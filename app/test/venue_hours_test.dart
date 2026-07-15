import 'package:flutter_test/flutter_test.dart';
import 'package:nomadwise_maps/models/venue.dart';

Venue venue(Map<String, dynamic> extra) => Venue.fromJson({
      'id': 'test',
      'name': 'Test Cafe',
      'type': 'cafe',
      ...extra,
    });

void main() {
  group('work-friendly state', () {
    test('laptops allowed -> yes', () {
      expect(venue({'laptops_allowed': true}).workFriendly,
          WorkFriendly.yes);
    });
    test('laptops banned -> no', () {
      expect(venue({'laptops_allowed': false}).workFriendly,
          WorkFriendly.no);
    });
    test('unknown stays unknown for cafes', () {
      expect(venue({}).workFriendly, WorkFriendly.unknown);
    });
    test('coworking spaces are work-friendly by definition', () {
      expect(venue({'type': 'coworking'}).workFriendly, WorkFriendly.yes);
    });
  });

  group('distance', () {
    test('haversine: Baixa to Alcantara is roughly 3.5-4.5 km', () {
      final d = Venue.haversineM(38.7115, -9.1370, 38.7040, -9.1745);
      expect(d, greaterThan(3000));
      expect(d, lessThan(5000));
    });
    test('distance label formats metres and km', () {
      final v = venue({});
      v.distanceM = 850;
      expect(v.distanceLabel(), '850 m');
      v.distanceM = 1500;
      expect(v.distanceLabel(), '1.5 km');
    });
  });

  group('fallback opening hours', () {
    test('24h access flag means always open', () {
      expect(venue({'access_24h': true}).openNow, true);
      expect(venue({'access_24h': true}).closingLabel(), 'Open 24 hours');
    });
    test('closed day parses as closed', () {
      final v = venue({
        'opening_hours': {
          for (final d in ['mon','tue','wed','thu','fri','sat','sun'])
            d: 'Closed'
        }
      });
      expect(v.openNow, false);
    });
    test('all-day range parses', () {
      final v = venue({
        'opening_hours': {
          for (final d in ['mon','tue','wed','thu','fri','sat','sun'])
            d: '12:00 AM - 11:59 PM'
        }
      });
      expect(v.openNow, true);
      expect(v.minutesToClose, isNotNull);
    });
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadwise_maps/models/venue.dart';
import 'package:nomadwise_maps/services/places_service.dart';
import 'package:nomadwise_maps/services/supabase_service.dart';
import 'package:nomadwise_maps/theme.dart';
import 'package:nomadwise_maps/widgets/candidates_tab.dart';

// The Candidates list, opened and used as a founder would, against a
// stand-in for the database and for Google. Drawn at a phone's width
// in the app's own font, so text that would not fit fails the test.

Map<String, dynamic> place(String id, String name, String area,
        {bool coworking = false,
        int wifi = 0,
        int power = 0,
        int laptop = 0,
        bool checked = true,
        int score = 0,
        bool page = true}) =>
    {
      'google_place_id': id,
      'name': name,
      'lat': 18.79,
      'lng': 98.98,
      'primary_type': coworking ? 'coworking_space' : 'coffee_shop',
      'coworking': coworking,
      'rating': 4.8,
      'user_rating_count': 312,
      'wifi': wifi,
      'power': power,
      'laptop': laptop,
      'food': 0,
      'checked': checked,
      'score': score,
      'area': area,
      'region_id': page ? 'reg_$area' : null,
      'region_name': page ? area : null,
      'region_country': page ? 'Thailand' : null,
    };

/// The database, as far as this screen is concerned.
class FakeDatabase extends SupabaseService {
  FakeDatabase(this.places);

  final List<Map<String, dynamic>> places;
  final Map<String, Map<String, dynamic>> queued = {};
  final Map<String, String> dismissed = {};
  final List<String?> areasAsked = [];
  bool fail = false;

  List<Map<String, dynamic>> get _open => places
      .where((p) =>
          !queued.containsKey(p['google_place_id']) &&
          !dismissed.containsKey(p['google_place_id']))
      .toList();

  @override
  Future<Map<String, dynamic>> adminCandidates(
      {String? area, int limit = 60, int offset = 0}) async {
    areasAsked.add(area);
    if (fail) throw Exception('the database is away');
    final all = _open;
    final shown =
        area == null ? all : all.where((p) => p['area'] == area).toList();
    final counts = <String, int>{};
    for (final p in all) {
      counts['${p['area']}'] = (counts['${p['area']}'] ?? 0) + 1;
    }
    return {
      'total': all.length,
      'shown_total': shown.length,
      'areas': [
        for (final e in counts.entries)
          {
            'area': e.key,
            'n': e.value,
            'has_page': e.key != 'No city page nearby',
          },
      ],
      'rows': shown.skip(offset).take(limit).toList(),
      'waiting_scan': 7,
      'dismissed': dismissed.length,
    };
  }

  @override
  Future<Map<String, dynamic>> candidateQueue(
      String placeId, Map<String, dynamic> google) async {
    queued[placeId] = google;
    return {'venue_id': 'venue-$placeId', 'existed': false};
  }

  @override
  Future<void> candidateDismiss(String placeId, String reason,
      {String? note}) async {
    dismissed[placeId] = reason;
  }

  @override
  Future<void> candidateRestore(String placeId) async {
    dismissed.remove(placeId);
  }

  @override
  Future<List<Map<String, dynamic>>> candidatesDismissed() async => [
        for (final e in dismissed.entries)
          {
            'google_place_id': e.key,
            'name': places.firstWhere(
                (p) => p['google_place_id'] == e.key)['name'],
            'reason': e.value,
            'note': null,
          },
      ];

  @override
  Future<List<String>> sweepQueue() async => ['Chiang Mai, Thailand'];

  @override
  Future<List<Map<String, dynamic>>> citySweeps() async => [];
}

/// Google, as far as this screen is concerned.
class FakeGoogle extends PlacesService {
  int detailCalls = 0;
  int quoteCalls = 0;

  @override
  Future<PlaceLive?> details(String placeId) async {
    detailCalls++;
    return PlaceLive.fromJson({
      'displayName': {'text': 'From Google'},
      'websiteUri': 'https://example.com',
      'addressComponents': [
        {
          'longText': 'Chiang Mai',
          'types': ['locality'],
        },
        {
          'longText': 'Thailand',
          'types': ['country'],
        },
      ],
    });
  }

  @override
  Future<List<String>> keywordExcerpts(String placeId,
      {int limit = 3}) async {
    quoteCalls++;
    return ['Great wifi and plugs at every table, stayed all afternoon.'];
  }
}

const reasons = [
  'Not really a place to work from',
  'Chain or not on brand',
  'Other',
];

Future<void> loadAppFont() async {
  final loader = FontLoader('Roboto');
  for (final f in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]) {
    final bytes = await File('assets/fonts/$f').readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

class Harness {
  Harness(this.db, this.google);
  final FakeDatabase db;
  final FakeGoogle google;
  final List<int> counts = [];
  int reloads = 0;
}

Future<Harness> open(WidgetTester tester, List<Map<String, dynamic>> places,
    {Size size = const Size(360, 780), bool fail = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final h = Harness(FakeDatabase(places)..fail = fail, FakeGoogle());
  await tester.pumpWidget(MaterialApp(
    theme: nomadwiseTheme(),
    home: Scaffold(
      body: CandidatesTab(
        supabase: h.db,
        places: h.google,
        // The site has a city page for Chiang Mai and for nothing else.
        regionForCity: (city) => city == 'Chiang Mai'
            ? {'id': 'reg_cnx', 'name': 'Chiang Mai', 'country': 'Thailand'}
            : null,
        dismissReasons: reasons,
        onQueued: () async {
          h.reloads++;
        },
        onCount: h.counts.add,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapText(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFont);

  final chiangMai = [
    place('p1', 'HappyBlue Coffee', 'Chiang Mai',
        wifi: 2, power: 1, laptop: 3, score: 19),
    place('p2', 'One Workspace', 'Chiang Mai',
        coworking: true, checked: false, score: 7),
    place('p3', 'Pai Laptop Cafe', 'No city page nearby',
        wifi: 1, laptop: 2, score: 13, page: false),
  ];

  testWidgets('shows the candidates, why each is there, and the totals',
      (tester) async {
    // Tall enough to draw all three cards at once (a list only builds
    // the cards near the screen).
    final h = await open(tester, chiangMai, size: const Size(360, 2400));

    expect(find.text('HappyBlue Coffee'), findsOneWidget);
    expect(find.text('One Workspace'), findsOneWidget);
    expect(find.text('3 reviews mention working there'), findsOneWidget);
    expect(find.text('1 review mentions plugs'), findsOneWidget);
    expect(find.text('Reviews not read yet'), findsOneWidget);
    expect(find.text('No city page yet'), findsOneWidget);
    expect(find.textContaining('3 places waiting'), findsOneWidget);
    expect(find.textContaining('7 more found'), findsOneWidget);
    expect(find.textContaining('Queued for the nightly sweep: Chiang Mai'),
        findsOneWidget);
    // The city chips, busiest first, and the number for the tab.
    expect(find.text('Everywhere  3'), findsOneWidget);
    expect(find.text('Chiang Mai  2'), findsOneWidget);
    expect(h.counts.last, 3);
    // Nothing asked of Google just for opening the list.
    expect(h.google.detailCalls, 0);
    expect(h.google.quoteCalls, 0);
  });

  testWidgets('Queue for the site sends the place on and clears the card',
      (tester) async {
    final h = await open(tester, chiangMai);

    await tapText(tester, find.text('Queue for the site').first);

    // The first card was HappyBlue; Google was asked once for its city.
    expect(h.google.detailCalls, 1);
    expect(h.db.queued.keys, ['p1']);
    expect(h.db.queued['p1'], {
      'city': 'Chiang Mai',
      'country': 'Thailand',
      'website': 'https://example.com',
    });
    expect(find.text('HappyBlue Coffee'), findsNothing);
    expect(find.text('One Workspace'), findsOneWidget);
    expect(find.textContaining('HappyBlue Coffee queued'), findsOneWidget);
    expect(find.textContaining('2 places waiting'), findsOneWidget);
    expect(h.counts.last, 2);
    // The control centre was told, so Queued shows the new space.
    expect(h.reloads, 1);
  });

  testWidgets('Not for the site asks why, keeps it, and offers a way back',
      (tester) async {
    final h = await open(tester, chiangMai);

    await tapText(tester, find.text('Not for the site').first);
    await tapText(tester, find.text('Chain or not on brand').last);

    expect(h.db.dismissed, {'p1': 'Chain or not on brand'});
    expect(find.text('HappyBlue Coffee'), findsNothing);
    expect(h.google.detailCalls, 0);
    expect(h.reloads, 0);

    // The way back.
    await tapText(tester, find.text('1 turned down'));
    expect(find.text('Turned down'), findsOneWidget);
    expect(find.text('HappyBlue Coffee'), findsOneWidget);
    await tapText(tester, find.text('Bring back'));
    expect(h.db.dismissed, isEmpty);
    // Close the sheet; the list reloads with the place back on it.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('HappyBlue Coffee'), findsOneWidget);
    expect(find.textContaining('3 places waiting'), findsOneWidget);
  });

  testWidgets('a city chip narrows the list to that city', (tester) async {
    final h = await open(tester, chiangMai);

    // The third chip sits off the right edge of a phone: found even
    // so, then scrolled into view by the tap helper.
    await tapText(tester,
        find.text('No city page nearby  1', skipOffstage: false));

    expect(h.db.areasAsked.last, 'No city page nearby');
    expect(find.text('Pai Laptop Cafe'), findsOneWidget);
    expect(find.text('HappyBlue Coffee'), findsNothing);

    // Deciding the last one there returns to every city.
    await tapText(tester, find.text('Queue for the site').first);
    expect(h.db.queued.keys, ['p3']);
    expect(h.db.areasAsked.last, isNull);
    expect(find.text('HappyBlue Coffee'), findsOneWidget);
  });

  testWidgets('review quotes are fetched only when asked for',
      (tester) async {
    final h = await open(tester, chiangMai);
    expect(h.google.quoteCalls, 0);

    await tapText(tester, find.text('What reviews say').first);

    expect(h.google.quoteCalls, 1);
    expect(find.textContaining('Great wifi and plugs'), findsOneWidget);
  });

  testWidgets('an empty list says where candidates come from',
      (tester) async {
    await open(tester, []);
    expect(find.text('No candidates waiting'), findsOneWidget);
    expect(find.textContaining('0 places waiting'), findsOneWidget);
  });

  testWidgets('a failed read says so and can be tried again',
      (tester) async {
    final h = await open(tester, chiangMai, fail: true);
    expect(find.text('The candidates could not be read'), findsOneWidget);

    h.db.fail = false;
    await tapText(tester, find.text('Try again'));

    expect(find.text('HappyBlue Coffee'), findsOneWidget);
  });

  testWidgets('long names and many reasons fit a narrow phone',
      (tester) async {
    await open(
        tester,
        [
          place(
              'p9',
              'The Social Club Chiang Mai - coliving & coworking space '
                  'for digital nomads',
              'Chiang Mai',
              coworking: true,
              wifi: 5,
              power: 5,
              laptop: 5,
              score: 30),
        ],
        size: const Size(320, 640));
    expect(find.textContaining('The Social Club Chiang Mai'), findsOneWidget);
    expect(find.text('5 reviews mention working there'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

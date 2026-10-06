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
        bool page = true,
        int? searches,
        String? confidence,
        String? phrase,
        int gap = 0,
        int listed = 0,
        bool other = false,
        String? address,
        int shared = 1,
        int sameName = 1,
        int mentions = 0,
        List<String> mentionSources = const [],
        List<String> workPhrases = const []}) =>
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
      // The search numbers of migration 137 (none unless given).
      'searches': searches,
      'search_confidence': confidence,
      'search_phrase': phrase,
      'gap_points': gap,
      'city_listed': listed,
      'other_type': other,
      // Where it is and who shares its name (migration 139).
      'address': address,
      'search_shared': shared,
      'same_name': sameName,
      // Other sites and Google's own search (migration 140).
      'mentions': mentions,
      'mention_sources': mentionSources,
      'work_phrases': workPhrases,
    };

/// The database, as far as this screen is concerned.
class FakeDatabase extends SupabaseService {
  FakeDatabase(this.places);

  final List<Map<String, dynamic>> places;
  final Map<String, Map<String, dynamic>> queued = {};
  final Map<String, String> dismissed = {};
  final Map<String, String?> notes = {};
  final List<String?> areasAsked = [];
  final List<String> sortsAsked = [];
  bool fail = false;

  /// What the search numbers say about a city, by area name, and the
  /// day they were looked up (none unless a test sets them).
  Map<String, Map<String, dynamic>> areaFacts = {};
  String? searchDay;

  /// What other sites name (none unless a test sets it).
  Map<String, dynamic>? mentionSummary;

  /// What may be asked of Google for the evidence (none unless set).
  Map<String, dynamic>? evidencePlan;

  List<Map<String, dynamic>> get _open => places
      .where((p) =>
          !queued.containsKey(p['google_place_id']) &&
          !dismissed.containsKey(p['google_place_id']))
      .toList();

  @override
  Future<Map<String, dynamic>> adminCandidates(
      {String? area,
      int limit = 60,
      int offset = 0,
      String sort = 'best'}) async {
    areasAsked.add(area);
    sortsAsked.add(sort);
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
            ...?areaFacts[e.key],
          },
      ],
      'rows': shown.skip(offset).take(limit).toList(),
      'waiting_scan': 7,
      'dismissed': dismissed.length,
      'search_measured': searchDay,
      'without_search': searchDay == null ? 0 : 1,
      if (mentionSummary != null) 'mention_summary': mentionSummary,
      if (evidencePlan != null) 'evidence_plan': evidencePlan,
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
    notes[placeId] = note;
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
    {Size size = const Size(360, 780),
    bool fail = false,
    Map<String, Map<String, dynamic>> areaFacts = const {},
    String? searchDay,
    Map<String, dynamic>? mentionSummary,
    Map<String, dynamic>? evidencePlan,
    bool full = true}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final db = FakeDatabase(places)
    ..fail = fail
    ..areaFacts = areaFacts
    ..searchDay = searchDay
    ..mentionSummary = mentionSummary
    ..evidencePlan = evidencePlan;
  final h = Harness(db, FakeGoogle());
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
        // Most tests are about the full list, as the tab always was.
        startFull: full,
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

  testWidgets('opens on the strongest, one at a time', (tester) async {
    final h = await open(tester, chiangMai, full: false);
    expect(find.text('2 strong candidates'), findsOneWidget);
    expect(find.text('HappyBlue Coffee'), findsOneWidget);
    // no city page: not a strong candidate
    expect(find.text('Pai Laptop Cafe'), findsNothing);
    expect(find.text('Next: One Workspace'), findsOneWidget);
    await tapText(tester, find.text('Later'));
    expect(find.text('Next: HappyBlue Coffee'), findsOneWidget);
    await tapText(tester, find.text('Yes, queue it'));
    expect(h.db.queued.keys, ['p2']);
    expect(find.textContaining('1 decided so far'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('"Other" asks for the reason and keeps it', (tester) async {
    final h = await open(tester, chiangMai);

    await tapText(tester, find.text('Not for the site').first);
    await tapText(tester, find.text('Other').last);

    // Asked, and nothing saved until a reason is typed.
    expect(find.text('Why not HappyBlue Coffee?'), findsOneWidget);
    expect(h.db.dismissed, isEmpty);
    final send = find.widgetWithText(ElevatedButton, 'Not for the site');
    expect(tester.widget<ElevatedButton>(send).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '  Only open weekends ');
    await tester.pumpAndSettle();
    expect(tester.widget<ElevatedButton>(send).onPressed, isNotNull);
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(h.db.dismissed, {'p1': 'Other'});
    expect(h.db.notes, {'p1': 'Only open weekends'});
    expect(find.text('HappyBlue Coffee'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Other" closed without a reason turns nothing down',
      (tester) async {
    final h = await open(tester, chiangMai);

    await tapText(tester, find.text('Not for the site').first);
    await tapText(tester, find.text('Other').last);
    await tapText(tester, find.text('Cancel'));

    expect(h.db.dismissed, isEmpty);
    expect(find.text('HappyBlue Coffee'), findsOneWidget);
  });

  testWidgets('a card says where the place is and how sure the reviews are',
      (tester) async {
    await open(
        tester,
        [
          place('w1', 'WeWork - Office Space & Coworking', 'Chiang Mai',
              coworking: true,
              searches: 2300,
              confidence: 'city',
              phrase: 'wework chiang mai',
              shared: 4,
              sameName: 4,
              address: '8 Devonshire Square'),
          place('w2', 'WeWork - Office Space & Coworking', 'Chiang Mai',
              coworking: true,
              searches: 2300,
              confidence: 'city',
              phrase: 'wework chiang mai',
              shared: 4,
              sameName: 4,
              address: '1 Poultry'),
          place('c1', 'Thin Cafe', 'Chiang Mai', wifi: 1),
          place('c2', 'Sure Cafe', 'Chiang Mai', laptop: 2, power: 1),
        ],
        size: const Size(360, 3000));

    // The two branches can be told apart.
    expect(find.text('8 Devonshire Square'), findsOneWidget);
    expect(find.text('1 Poultry'), findsOneWidget);
    expect(
        find.text('About 2,300 searches a month for "wework chiang mai", '
            'shared by 4 places with this name'),
        findsNWidgets(2));
    // A cafe says how sure the reviews are; a coworking space does not.
    expect(find.text('Thin signs people work here: look before you queue'),
        findsOneWidget);
    expect(find.text('Strong signs people work here'), findsOneWidget);
    // Google and the map, on every card.
    expect(find.text('Google'), findsNWidgets(4));
    expect(find.text('Map'), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a card says who else names it and what Google returns it for',
      (tester) async {
    await open(
        tester,
        [
          place('m1', 'Named Cafe', 'Chiang Mai',
              mentions: 5,
              mentionSources: ['Thatsup', 'LaptopFriendly', 'Blog', 'More'],
              workPhrases: ['laptop friendly cafe', 'cafe to work from']),
          place('m2', 'Once Named', 'Chiang Mai',
              wifi: 1, mentions: 1, mentionSources: ['Thatsup']),
          place('m3', 'Plain Cafe', 'Chiang Mai', wifi: 1),
        ],
        size: const Size(360, 3000),
        mentionSummary: {
          'sources': 38,
          'places': 845,
          'listed': 120,
          'on_site': 95,
          'matched': 300,
          'closed': 20,
          'not_found': 40,
          'several': 12,
          'waiting': 67,
          'parked': 286,
        },
        evidencePlan: {
          'kind': 'Text Search Pro',
          'cities': ['london'],
          'min_points': 2,
          'calls_per_run': 40,
          'calls_per_month': 1000,
          'free_per_month': 5000,
          'keep_back': 1500,
          'used_job': 46,
          'used_all': 310,
          'left_month': 954,
          'left_run': 40,
        });

    expect(find.text('Named by 5 sites: Thatsup, LaptopFriendly, Blog and 2 more'),
        findsOneWidget);
    expect(
        find.text('Google returns it for "laptop friendly cafe" and '
            '"cafe to work from"'),
        findsOneWidget);
    expect(find.text('Named by Thatsup'), findsOneWidget);
    // Two kinds of sign make it strong; one makes it some; WiFi alone thin.
    expect(find.text('Strong signs people work here'), findsOneWidget);
    expect(find.text('Some signs people work here'), findsOneWidget);
    expect(find.text('Thin signs people work here: look before you queue'),
        findsOneWidget);
    // What became of everything the other sites name.
    expect(
        find.text('Other sites: 38 sites name 845 places. 120 are on Nomad '
            'Maps already (95 on the site), 300 were found open and are '
            'candidates, 20 have closed, 40 not found on Google, 12 are '
            'brands with several places, 67 still to check, 286 named by '
            'one ordinary site are not checked for now.'),
        findsOneWidget);
    // How much Google is asked for it, inside the free amount.
    expect(
        find.text('Google lookups for this: 46 of 1,000 this month, at most '
            '40 a day, London only. Google\'s free 5,000 a month for this '
            'kind of call: 310 used by everything, 1,500 kept back for the '
            'app.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no line about other sites when none were read',
      (tester) async {
    await open(tester, chiangMai);
    expect(find.textContaining('Other sites:'), findsNothing);
    expect(find.textContaining('Google lookups for this'), findsNothing);
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

  // ---- the search numbers (migration 137) ----

  final searched = [
    place('s1', 'The Cluster', 'Melbourne',
        coworking: true,
        score: 7,
        searches: 870,
        confidence: 'sure',
        phrase: 'the cluster',
        gap: 5,
        listed: 0),
    place('s2', 'Quiet Corner Cafe', 'Melbourne',
        wifi: 1, score: 5, searches: 0, confidence: 'none'),
    place('s3', 'Found Last Night', 'Chiang Mai', laptop: 1, score: 6),
  ];

  testWidgets('a card says what the search numbers say', (tester) async {
    await open(tester, searched,
        size: const Size(360, 2400), searchDay: '2026-10-05');

    expect(find.text('About 870 searches a month for "the cluster"'),
        findsOneWidget);
    expect(
        find.text('People search for coworking here and we list no '
            'coworking spaces'),
        findsOneWidget);
    expect(find.text('No searches found for its name'), findsOneWidget);
    // A place found after the lookup says nothing about searches.
    expect(find.textContaining('searches a month'), findsOneWidget);
    // Where the numbers come from, and that one place has none yet.
    expect(find.textContaining('Search numbers: Ahrefs'), findsOneWidget);
    expect(find.textContaining('1 place found since then has none yet'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long search reasons fit a narrow phone', (tester) async {
    await open(
        tester,
        [
          place('s9', 'Generator London', 'London',
              power: 2,
              score: 9,
              searches: 9000,
              confidence: 'sure',
              phrase: 'generator london',
              other: true),
        ],
        size: const Size(320, 900));
    expect(find.textContaining('9,000 searches a month'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the order can be switched to most searched', (tester) async {
    final h = await open(tester, searched);
    expect(h.db.sortsAsked.last, 'best');

    await tapText(tester, find.text('Most searched first'));

    expect(h.db.sortsAsked.last, 'searches');
    expect(find.text('The Cluster'), findsOneWidget);
  });

  testWidgets('a chosen city shows what people search for there',
      (tester) async {
    await open(tester, searched, areaFacts: {
      'Melbourne': {
        'coworking_searches': 1800,
        'cafe_searches': 90,
        'difficulty': 4,
        'coworking_listed': 0,
        'cafes_listed': 1,
      },
    });
    // Nothing about a city until one is chosen.
    expect(find.textContaining('searches a month for coworking in'),
        findsNothing);

    await tapText(tester, find.text('Melbourne  2', skipOffstage: false));

    expect(
        find.text('About 1,800 searches a month for coworking in '
            'Melbourne. How hard to rank, by Ahrefs: easy (4 of 100). We '
            'list 0 coworking spaces and 1 cafe there.'),
        findsOneWidget);
  });
}

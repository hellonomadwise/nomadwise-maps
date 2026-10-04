import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadwise_maps/models/venue.dart';
import 'package:nomadwise_maps/services/places_service.dart';
import 'package:nomadwise_maps/services/supabase_service.dart';
import 'package:nomadwise_maps/theme.dart';
import 'package:nomadwise_maps/widgets/candidates_tab.dart';

// Throwaway: draws the Candidates list with sample data to a picture.

Map<String, dynamic> place(String id, String name, num rating, int n,
        {bool coworking = false,
        int wifi = 0,
        int power = 0,
        int laptop = 0,
        bool checked = true,
        int score = 0}) =>
    {
      'google_place_id': id,
      'name': name,
      'lat': 18.79,
      'lng': 98.98,
      'primary_type': coworking ? 'coworking_space' : 'coffee_shop',
      'coworking': coworking,
      'rating': rating,
      'user_rating_count': n,
      'wifi': wifi,
      'power': power,
      'laptop': laptop,
      'food': 0,
      'checked': checked,
      'score': score,
      'area': 'Chiang Mai',
      'region_id': 'reg_cnx',
      'region_name': 'Chiang Mai',
      'region_country': 'Thailand',
    };

class FakeDatabase extends SupabaseService {
  FakeDatabase(this.places);
  final List<Map<String, dynamic>> places;

  @override
  Future<Map<String, dynamic>> adminCandidates(
          {String? area, int limit = 60, int offset = 0}) async =>
      {
        'total': 47,
        'shown_total': area == null ? 47 : places.length,
        'areas': [
          {'area': 'Chiang Mai', 'n': 31, 'has_page': true},
          {'area': 'Lisbon', 'n': 12, 'has_page': true},
          {'area': 'Pai, Thailand', 'n': 4, 'has_page': false},
        ],
        'rows': places,
        'waiting_scan': 118,
        'dismissed': 3,
      };

  @override
  Future<List<String>> sweepQueue() async => ['Bangkok, Thailand'];

  @override
  Future<List<Map<String, dynamic>>> citySweeps() async => [
        {
          'city': 'Chiang Mai, Thailand',
          'places_found': 412,
          'swept_at': '2026-10-04T04:23:00Z',
        },
      ];
}

class FakeGoogle extends PlacesService {
  @override
  Future<PlaceLive?> details(String placeId) async => null;

  @override
  Future<List<String>> keywordExcerpts(String placeId,
          {int limit = 3}) async =>
      [
        '…perfect to work on your laptop or do some reading. They also '
            'have free wifi!',
      ];
}

Future<void> loadFonts() async {
  final roboto = FontLoader('Roboto');
  for (final f in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]) {
    final bytes = await File('assets/fonts/$f').readAsBytes();
    roboto.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await roboto.load();
  final root = Platform.environment['FLUTTER_ROOT'];
  final icons = File(
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons');
    final bytes = await icons.readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('laptop', const Size(900, 900)),
  ]) {
    testWidgets('picture: $name', (tester) async {
      debugDisableShadows = false;
      tester.view.physicalSize = size * 2.0;
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final db = FakeDatabase([
        place('p1', 'HappyBlue Coffee - the neighborhood cafe', 4.9, 394,
            wifi: 2, laptop: 1, score: 11),
        place('p2', 'One Workspace', 5.0, 257,
            coworking: true, wifi: 2, laptop: 3, score: 21),
        place('p3', 'anyday coffee coworking space', 4.9, 171,
            coworking: true, wifi: 3, power: 1, laptop: 2, score: 21),
        place('p4', '4Seas Nimman Coliving Coworking Space', 4.9, 164,
            coworking: true, checked: false, score: 7),
        place('p5', 'Life Space', 4.7, 111,
            coworking: true, wifi: 3, score: 12),
      ]);
      const key = ValueKey('shot');
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: nomadwiseTheme(),
          home: Scaffold(
            appBar: AppBar(title: const Text('Control centre')),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: CandidatesTab(
                  supabase: db,
                  places: FakeGoogle(),
                  regionForCity: (_) => null,
                  dismissReasons: const [
                    'Not really a place to work from',
                    'Chain or not on brand',
                    'Other',
                  ],
                  onQueued: () async {},
                  onCount: (_) {},
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // Narrow to Chiang Mai and open the quotes on the first card.
      await tester.tap(find.text('Chiang Mai  31'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('What reviews say').first);
      await tester.pumpAndSettle();
      await expectLater(
          find.byKey(key), matchesGoldenFile('out/candidates_$name.png'));
      debugDisableShadows = true;
    });
  }
}

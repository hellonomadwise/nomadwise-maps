import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/enquiry_screen.dart';
import 'screens/map_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );
  runApp(const NomadwiseMapsApp());
}

class NomadwiseMapsApp extends StatelessWidget {
  const NomadwiseMapsApp({super.key});

  static String? get _enquireSlug {
    try {
      final s = (Uri.base.queryParameters['enquire'] ?? '').trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nomadwise Maps',
      debugShowCheckedModeBanner: false,
      theme: nomadwiseTheme(),
      // nomadmaps.io/?enquire=<slug> is the Request a booking form a
      // Verified listing on nomadwise.io links to; everything else is
      // the map.
      home: _enquireSlug == null
          ? const MapScreen()
          : EnquiryScreen(slug: _enquireSlug!),
    );
  }
}

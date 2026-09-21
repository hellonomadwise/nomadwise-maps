import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/claim_screen.dart';
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

  static String? _param(String key) {
    try {
      final s = (Uri.base.queryParameters[key] ?? '').trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  static bool _has(String key) {
    try {
      return Uri.base.queryParameters.containsKey(key);
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Three public doors into the app, all query parameters so the
    // static build needs no routing:
    //   ?enquire=<slug>  the Request a booking form on a Verified page
    //   ?claim[=<name or slug>][&from=<page>]  the owner's claim-and-pay flow
    //   ?claimed         where Stripe returns them after paying
    // Anything else is the map.
    final enquire = _param('enquire');
    final Widget home;
    if (enquire != null) {
      home = EnquiryScreen(slug: enquire);
    } else if (_has('claimed')) {
      home = const ClaimedScreen();
    } else if (_has('claim')) {
      home = ClaimScreen(seed: _param('claim'), from: _param('from'));
    } else {
      home = const MapScreen();
    }

    return MaterialApp(
      title: 'Nomadwise Maps',
      debugShowCheckedModeBanner: false,
      theme: nomadwiseTheme(),
      home: home,
    );
  }
}

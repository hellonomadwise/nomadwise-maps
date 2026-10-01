import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/admin_gate.dart';
import 'screens/claim_screen.dart';
import 'screens/owner_screen.dart';
import 'screens/enquiry_screen.dart';
import 'screens/update_screen.dart';
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

  /// The address's path, in case a forwarding page (web/owner,
  /// web/claim) is skipped and the app itself opens on /owner.
  static String get _path {
    try {
      return Uri.base.path;
    } catch (_) {
      return '';
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
    //   ?enquire=<slug>  the Send an enquiry form on a Verified page
    //   ?claim[=<name or slug>][&from=<page>]  the owner's claim-and-pay flow
    //   ?claimed         where Stripe returns them after paying
    //   ?owner           the Owner account (manage my listing)
    //   ?update=<slug>   Something need updating? (anyone; owners are
    //                    pointed to claiming)
    //   ?admin[=analytics|users]  the team's control centre (also
    //                    nomadmaps.io/admin); team accounts only
    // Anything else is the map.
    final enquire = _param('enquire');
    final Widget home;
    if (enquire != null) {
      home = EnquiryScreen(slug: enquire);
    } else if (_has('update')) {
      home = UpdateScreen(slug: _param('update') ?? '');
    } else if (_has('claimed')) {
      home = const ClaimedScreen();
    } else if (_has('claim') || _path.startsWith('/claim')) {
      home = ClaimScreen(
          seed: _param('claim'), from: _param('from'), email: _param('email'));
    } else if (_has('admin') || _path.startsWith('/admin')) {
      home = AdminGate(section: _param('admin'));
    } else if (_has('owner') || _path.startsWith('/owner')) {
      home = OwnerScreen(previewKey: _param('preview'));
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

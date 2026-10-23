import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/admin_gate.dart';
import 'screens/claim_screen.dart';
import 'screens/owner_screen.dart';
import 'screens/sign_in_link_screen.dart';
import 'screens/admin_outreach_screen.dart' show UnsubscribeScreen;
import 'screens/enquiry_screen.dart';
import 'screens/found_screen.dart';
import 'screens/suggest_screen.dart';
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
    //   ?tag=<slug>      Add a tag: asks who you are first; owners go
    //                    to claiming, visitors say what the place has
    //   ?found=<key>     "Did you find a place?" after an enquiry
    //                    (migration 193): where they went
    //   ?suggest[&from=<page>]  Suggest a place (migration 210): a
    //                    cafe or coworking space not on the site yet
    //   ?token_hash=..&type=..  the button in a sign-in email
    //   ?admin[=analytics|users]  the team's control centre (also
    //                    nomadmaps.io/admin); team accounts only
    // Anything else is the map.
    final enquire = _param('enquire');
    final tokenHash = _param('token_hash');
    final Widget home;
    if (tokenHash != null) {
      // The button in a sign-in or confirm email (docs/EMAIL_STYLE.md):
      // signs in on a press, so a mail checker cannot use the link up.
      home = SignInLinkScreen(
          tokenHash: tokenHash,
          type: _param('type') ?? 'magiclink',
          owner: _has('owner') || _path.startsWith('/owner'));
    } else if (enquire != null) {
      home = EnquiryScreen(slug: enquire);
    } else if (_has('update')) {
      home = UpdateScreen(slug: _param('update') ?? '');
    } else if (_has('found')) {
      home = FoundScreen(token: _param('found') ?? '');
    } else if (_has('suggest') || _path.startsWith('/suggest')) {
      home = SuggestScreen(from: _param('from'));
    } else if (_has('tag')) {
      // "Add a tag" on a listing page: who are you first, then the
      // owner claims, a visitor says what the place has.
      home = UpdateScreen(slug: _param('tag') ?? '', tags: true);
    } else if (_has('claimed')) {
      home = const ClaimedScreen();
    } else if (_has('claim') || _path.startsWith('/claim')) {
      home = ClaimScreen(
          seed: _param('claim'), from: _param('from'), email: _param('email'));
    } else if (_has('admin') || _path.startsWith('/admin')) {
      home = AdminGate(section: _param('admin'));
    } else if (_has('unsubscribe')) {
      home = UnsubscribeScreen(token: _param('unsubscribe') ?? '');
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import 'admin_analytics_screen.dart';
import 'admin_prices_screen.dart';
import 'admin_pricing_screen.dart';
import 'admin_outreach_screen.dart';
import 'admin_upgrades_screen.dart';
import 'admin_users_screen.dart';
import 'website_screen.dart';

/// The team's own door: nomadmaps.io/admin opens the control centre
/// straight away (?admin=analytics and ?admin=users open those).
/// Signed out: one "Continue with Google" button that comes back here.
/// Signed in without team rights: a polite note and the way to the map.
/// Nothing here grants anything; the database still checks every call.
class AdminGate extends StatefulWidget {
  final String? section;
  const AdminGate({super.key, this.section});

  @override
  State<AdminGate> createState() => _AdminGateState();
}

class _AdminGateState extends State<AdminGate> {
  final _supabase = SupabaseService();
  StreamSubscription<AuthState>? _sub;
  bool? _admin; // null while checking
  bool _signingIn = false;
  bool _openedSection = false;

  @override
  void initState() {
    super.initState();
    _check();
    // Coming back from Google, the session lands a moment after start.
    // Only signing in or out changes the answer (not the hourly token
    // refresh, which must never close an open control centre).
    _sub = _supabase.authChanges.listen((s) {
      if (s.event == AuthChangeEvent.signedIn ||
          s.event == AuthChangeEvent.signedOut ||
          s.event == AuthChangeEvent.initialSession) {
        _check();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (!_supabase.signedIn) {
      if (mounted) setState(() => _admin = false);
      return;
    }
    // Once confirmed, a failed re-check (a network blip) keeps it open;
    // the database checks every action anyway.
    if (_admin == true) return;
    final a = await _supabase.isAdmin();
    if (mounted) setState(() => _admin = a);
  }

  String get _returnTo {
    final s = widget.section;
    return '${Uri.base.origin}/?admin${s == null ? '' : '=$s'}';
  }

  Future<void> _google() async {
    setState(() => _signingIn = true);
    try {
      await _supabase.signInWithGoogleTo(_returnTo);
    } catch (_) {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_admin == null) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator(color: Brand.red)));
    }
    if (_admin == true) {
      // ?admin=analytics or ?admin=users: that screen opens on top of
      // the control centre, so its back arrow leads there.
      final s = widget.section;
      if (!_openedSection &&
          (s == 'analytics' ||
              s == 'users' ||
              s == 'pricing' ||
              s == 'outreach' ||
              s == 'upgrades' ||
              s == 'prices')) {
        _openedSection = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => s == 'analytics'
                  ? const AdminAnalyticsScreen()
                  : s == 'pricing'
                      ? const AdminPricingScreen()
                      : s == 'outreach'
                          ? const AdminOutreachScreen()
                          : s == 'upgrades'
                              ? const AdminUpgradesScreen()
                              : s == 'prices'
                                  ? const AdminPricesScreen()
                                  : const AdminUsersScreen()));
        });
      }
      return const WebsiteScreen(standalone: true);
    }
    final signedIn = _supabase.signedIn;
    return Scaffold(
      backgroundColor: Brand.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Brand.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Brand.border),
              ),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('nomadwise',
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 22,
                            color: Brand.red)),
                    const SizedBox(height: 4),
                    const Text('Control centre, for the Nomadwise team',
                        style: TextStyle(
                            fontSize: 13, color: Brand.inkSecondary)),
                    const SizedBox(height: 20),
                    if (!signedIn) ...[
                      FilledButton.icon(
                          onPressed: _signingIn ? null : _google,
                          style: FilledButton.styleFrom(
                              backgroundColor: Brand.red,
                              minimumSize: const Size(0, 46)),
                          icon: const Icon(Icons.login, size: 18),
                          label: Text(_signingIn
                              ? 'One moment'
                              : 'Continue with Google')),
                      const SizedBox(height: 10),
                      const Text(
                          'You stay signed in on this device, so next time '
                          'this link opens the control centre straight away.',
                          style: TextStyle(
                              fontSize: 12.5,
                              height: 1.45,
                              color: Brand.inkMuted)),
                    ] else ...[
                      Text(
                          'You are signed in as ${_supabase.userEmail ?? ''}, '
                          'which is not a team account.',
                          style: const TextStyle(fontSize: 14, height: 1.5)),
                      const SizedBox(height: 14),
                      OutlinedButton(
                          onPressed: () async {
                            await _supabase.signOut();
                            _check();
                          },
                          child: const Text('Use another account')),
                    ],
                    const SizedBox(height: 8),
                    TextButton(
                        onPressed: () => launchUrl(Uri.parse('/'),
                            webOnlyWindowName: '_self'),
                        child: const Text('Open the map')),
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}

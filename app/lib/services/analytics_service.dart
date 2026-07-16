import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Sends product analytics events to PostHog (EU cloud).
///
/// Uses PostHog's public capture API directly: no SDK dependency, works on
/// web today and native later. Every event carries app: nomadwise-maps so
/// it's separable from other Nomadwise data in the same project.
/// All calls are fire-and-forget and can never break the app.
class Analytics {
  // Public client key (write-only) for the Nomadwise PostHog project.
  static const _apiKey = 'phc_vZcv4FbDKex8tyKq85MRHd6SgFbEzQoBJpQmvdWY6K4';
  static const _host = 'https://eu.i.posthog.com';

  static String? _distinctId;

  static Future<String> _id() async {
    if (_distinctId != null) return _distinctId!;
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString('ph_distinct_id');
      if (id == null) {
        id = 'anon-${DateTime.now().millisecondsSinceEpoch}-'
            '${Random().nextInt(0xFFFFFF)}';
        await prefs.setString('ph_distinct_id', id);
      }
      _distinctId = id;
      return id;
    } catch (_) {
      return _distinctId = 'anon-fallback';
    }
  }

  static Future<void> _post(Map<String, dynamic> body) async {
    try {
      await http.post(Uri.parse('$_host/capture/'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body));
    } catch (_) {}
  }

  /// Record an event, e.g. Analytics.capture('venue_viewed', {'venue': name})
  static Future<void> capture(String event,
      [Map<String, dynamic>? props]) async {
    final id = await _id();
    await _post({
      'api_key': _apiKey,
      'event': event,
      'distinct_id': id,
      'properties': {'app': 'nomadwise-maps', ...?props},
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Tie this device's activity to a signed-in account.
  static Future<void> identify(String userId,
      {String? email, String? name}) async {
    final anon = await _id();
    _distinctId = userId;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ph_distinct_id', userId);
    } catch (_) {}
    await _post({
      'api_key': _apiKey,
      'event': r'$identify',
      'distinct_id': userId,
      'properties': {
        'app': 'nomadwise-maps',
        r'$anon_distinct_id': anon,
        r'$set': {
          if (email != null) 'email': email,
          if (name != null) 'name': name,
          'app': 'nomadwise-maps',
        },
      },
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Forget the account link (on sign-out).
  static Future<void> reset() async {
    _distinctId = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('ph_distinct_id');
    } catch (_) {}
  }
}

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ua_stub.dart' if (dart.library.html) 'ua_web.dart' as ua;

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
  static bool? _internal;

  /// Ghost mode: opening the app at nomadmaps.io/#internal marks this
  /// browser as an internal device and analytics go fully silent on it
  /// (no PostHog, no in-app analytics, no phone pings). The mark
  /// persists for this browser; nomadmaps.io/#public lifts it again.
  /// Does this visit come from a data-centre address (Amazon, Google
  /// Cloud, hosting providers)? Real homes and cafes never do, but
  /// VPNs can, so this is recorded as a tag rather than a hard block.
  /// Checked once per session, never persisted (VPNs come and go).
  static bool? _dc;
  static final _dcPattern = RegExp(
      r'amazon|aws|google cloud|azure|microsoft corp|digitalocean|'
      r'hetzner|ovh|linode|vultr|oracle cloud|alibaba|tencent|'
      r'cloudflare|akamai|fastly|leaseweb|contabo|m247|choopa|'
      r'hosting|datacenter|data center|server',
      caseSensitive: false);

  static Future<bool> _isDatacenter() async {
    if (_dc != null) return _dc!;
    try {
      final resp = await http
          .get(Uri.parse('https://get.geojs.io/v1/ip/geo.json'))
          .timeout(const Duration(seconds: 4));
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final org = ('${j['organization_name'] ?? ''} '
              '${j['organization'] ?? ''}')
          .toLowerCase()
          .replaceAll('-', ' ');
      return _dc = _dcPattern.hasMatch(org);
    } catch (_) {
      return _dc = false;
    }
  }

  /// Traffic-source tags from the arrival URL (utm_source etc.),
  /// so placements on nomadwise.io and elsewhere can be measured.
  static Map<String, String> _sourceParams() {
    try {
      final qp = Uri.base.queryParameters;
      return {
        for (final k in const [
          'utm_source',
          'utm_medium',
          'utm_campaign',
          'ref'
        ])
          if ((qp[k] ?? '').isNotEmpty) k: qp[k]!,
      };
    } catch (_) {
      return {};
    }
  }

  static final _botPattern = RegExp(
      r'bot|crawl|spider|slurp|headless|lighthouse|phantom|selenium|'
      r'puppeteer|playwright|bingpreview|facebookexternalhit|'
      r'whatsapp|telegram|discord|skype|preview|python|curl|wget|'
      r'monitor|pingdom|uptime',
      caseSensitive: false);

  /// Automated browsers (crawlers, link-preview fetchers, uptime
  /// checkers) are not visitors: keep them out of all analytics.
  static bool get _isBot {
    try {
      return ua.isWebdriver() || _botPattern.hasMatch(ua.userAgent());
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _isInternal() async {
    if (_internal != null) return _internal!;
    if (_isBot) return _internal = true;
    var flag = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      flag = prefs.getBool('internal_device') ?? false;
      final frag = Uri.base.fragment;
      if (frag.contains('internal')) {
        flag = true;
        await prefs.setBool('internal_device', true);
      } else if (frag.contains('public')) {
        flag = false;
        await prefs.setBool('internal_device', false);
      }
    } catch (_) {}
    return _internal = flag;
  }

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
    if (await _isInternal()) return;
    final id = await _id();
    // Record the browser identity, network type, and traffic source
    // with each arrival, so disguised bots can be filtered and the
    // nomadwise.io placements can be measured.
    final merged = <String, dynamic>{
      if (event == 'app_opened' && ua.userAgent().isNotEmpty)
        'ua': ua.userAgent().length > 160
            ? ua.userAgent().substring(0, 160)
            : ua.userAgent(),
      if (event == 'app_opened' && await _isDatacenter()) 'dc': true,
      if (event == 'app_opened') ..._sourceParams(),
      ...?props,
    };
    _mirror(event, id, merged); // in-app admin analytics, best effort
    await _post({
      'api_key': _apiKey,
      'event': event,
      'distinct_id': id,
      'properties': {'app': 'nomadwise-maps', ...merged},
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Mirror the event into Supabase so the admin can browse activity
  /// inside the app. Never blocks, never throws.
  static void _mirror(
      String event, String anonId, Map<String, dynamic>? props) {
    try {
      final db = Supabase.instance.client;
      db.from('app_events').insert({
        'anon_id': anonId,
        if (db.auth.currentUser != null)
          'user_id': db.auth.currentUser!.id,
        'name': event,
        if (props != null && props.isNotEmpty) 'props': props,
      }).then((_) {}, onError: (_) {});
    } catch (_) {}
  }

  /// Tie this device's activity to a signed-in account.
  static Future<void> identify(String userId,
      {String? email, String? name}) async {
    if (await _isInternal()) return;
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

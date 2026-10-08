import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
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
    await geo();
    return _dc ?? false;
  }

  static Future<Map<String, dynamic>>? _geo;

  /// Roughly where this visit comes from, as its internet connection
  /// shows it: country and town (never an address, and the position
  /// only to the nearest tenth of a degree), whether the connection
  /// is a data centre or VPN, and the time zone the device's clock is
  /// set to. Looked up once per session; whatever cannot be read is
  /// left out. Never throws.
  static Future<Map<String, dynamic>> geo() => _geo ??= _lookUpGeo();

  static Map<String, dynamic> _clock() {
    try {
      final tz = ua.timeZone();
      return {if (tz.isNotEmpty) 'tz': tz};
    } catch (_) {
      return {};
    }
  }

  static Future<Map<String, dynamic>> _lookUpGeo() async {
    final out = <String, dynamic>{..._clock()};
    try {
      final resp = await http
          .get(Uri.parse('https://get.geojs.io/v1/ip/geo.json'))
          .timeout(const Duration(seconds: 4));
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      String s(String k) => '${j[k] ?? ''}'.trim();
      if (s('country_code').isNotEmpty) out['cc'] = s('country_code');
      if (s('country').isNotEmpty) out['country'] = s('country');
      if (s('city').isNotEmpty) out['city'] = s('city');
      final lat = double.tryParse(s('latitude'));
      final lng = double.tryParse(s('longitude'));
      if (lat != null && lng != null) {
        out['lat'] = (lat * 10).round() / 10;
        out['lng'] = (lng * 10).round() / 10;
      }
      final org = ('${j['organization_name'] ?? ''} '
              '${j['organization'] ?? ''}')
          .toLowerCase()
          .replaceAll('-', ' ');
      _dc = _dcPattern.hasMatch(org);
      if (_dc == true) out['dc'] = true;
    } catch (_) {
      _dc ??= false;
    }
    return out;
  }

  /// What the claim page tells the phone notice about where the
  /// visitor is (migration 154): [geo], cut short so the notice is
  /// not kept waiting, with the visit it belongs to. A device marked
  /// internal sends no visit, so nothing is kept for it. Never throws.
  static Future<Map<String, dynamic>> claimGeo(String visit) async {
    final out = <String, dynamic>{};
    try {
      out.addAll(await geo().timeout(const Duration(milliseconds: 1500),
          onTimeout: _clock));
    } catch (_) {}
    try {
      if (await _isInternal()) {
        // so the notice can say it was one of our own devices
        out['internal'] = true;
      } else {
        out['visit'] = visit;
        out['anon'] = await _id();
      }
    } catch (_) {}
    return out;
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

  static String _referrerHost() {
    try {
      final host = Uri.tryParse(ua.referrer())?.host ?? '';
      // Moving around inside the app is not a source.
      if (host.isEmpty || host == Uri.base.host) return '';
      return host;
    } catch (_) {
      return '';
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
  static bool get isBot => _isBot;

  static bool get _isBot {
    try {
      return ua.isWebdriver() || _botPattern.hasMatch(ua.userAgent());
    } catch (_) {
      return false;
    }
  }

  /// Is this visit on a network the database has blocked (migration
  /// 164: a crawler's cloud servers)? Then it sends nothing, like one
  /// of our own devices. Asked once per page load. The first events
  /// wait up to five seconds for the answer (a crawler far away is
  /// slow to get it: on 8 Oct its first events went out before the
  /// answer did); an answer that comes later still silences the rest
  /// of the visit. With no answer at all, the visit counts as an
  /// ordinary one.
  static Future<bool> _blockedNetwork() async {
    try {
      final ask = () async {
        final r = await Supabase.instance.client.rpc('visit_blocked');
        final yes = r == true;
        if (yes) _internal = true;
        return yes;
      }();
      return await Future.any<bool>([
        ask.catchError((_) => false),
        Future<bool>.delayed(const Duration(seconds: 5), () => false),
      ]);
    } catch (_) {
      return false;
    }
  }

  static Future<bool>? _internalCheck;

  static Future<bool> _isInternal() async {
    if (_internal != null) return _internal!;
    // (one check at a time: the first events of a visit come together)
    return _internalCheck ??= _checkInternal();
  }

  static Future<bool> _checkInternal() async {
    if (_isBot) return _internal = true;
    if (await _blockedNetwork()) return _internal = true;
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
    // (a late "blocked" may already have arrived meanwhile)
    if (_internal == true) return true;
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
      // The site that linked here (host only), for "where visitors
      // come from"; empty for typed links and many apps.
      if (event == 'app_opened' && _referrerHost().isNotEmpty)
        'referrer': _referrerHost(),
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

  /// Like [capture], but for the moment the visitor leaves the page:
  /// the browser sends it after the page is gone, when an ordinary
  /// request would be cut off. Synchronous, so it can run inside the
  /// browser's pagehide event; uses whatever identity is cached.
  static void beacon(String event, [Map<String, dynamic>? props]) {
    if (_internal ?? false) return;
    final id = _distinctId ?? 'anon-fallback';
    final merged = <String, dynamic>{...?props};
    try {
      ua.sendBeacon(
          '${AppConfig.supabaseUrl}/rest/v1/app_events',
          jsonEncode({
            'anon_id': id,
            'name': event,
            if (merged.isNotEmpty) 'props': merged,
          }),
          {
            'apikey': AppConfig.supabaseAnonKey,
            'Authorization': 'Bearer ${AppConfig.supabaseAnonKey}',
            'Prefer': 'return=minimal',
          });
    } catch (_) {}
    try {
      ua.sendBeacon(
          '$_host/capture/',
          jsonEncode({
            'api_key': _apiKey,
            'event': event,
            'distinct_id': id,
            'properties': {'app': 'nomadwise-maps', ...merged},
            'timestamp': DateTime.now().toUtc().toIso8601String(),
          }));
    } catch (_) {}
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

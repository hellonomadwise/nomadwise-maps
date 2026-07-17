import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config.dart';
import '../models/discovered_place.dart';
import '../models/venue.dart';

/// All reads/writes to the Nomadwise Supabase backend live here.
class SupabaseService {
  SupabaseClient get _db => Supabase.instance.client;

  User? get currentUser => _db.auth.currentUser;
  bool get signedIn => currentUser != null;
  Stream<AuthState> get authChanges => _db.auth.onAuthStateChange;

  // ---------- auth ----------

  Future<void> signInWithEmail(String email, String password) =>
      _db.auth.signInWithPassword(email: email, password: password);

  Future<void> signUpWithEmail(String email, String password) =>
      _db.auth.signUp(
        email: email,
        password: password,
        // The confirmation email's link lands back in the app.
        emailRedirectTo: kIsWeb
            ? '${Uri.base.origin}${Uri.base.path}'
            : AppConfig.authRedirect,
      );

  Future<void> signInWithGoogle() => _db.auth.signInWithOAuth(
        OAuthProvider.google,
        // Web: come back to the page the user is on (the app itself).
        // Mobile: come back into the app via its deep link.
        redirectTo: kIsWeb
            ? '${Uri.base.origin}${Uri.base.path}'
            : AppConfig.authRedirect,
      );

  Future<void> signOut() => _db.auth.signOut();

  // ---------- venues ----------

  static const _venueCacheKey = 'venues_cache_v1';

  Future<List<Venue>> fetchVenues() async {
    final rows = await _db.from('venues').select();
    final list = (rows as List)
        .map((r) => Venue.fromJson(Map<String, dynamic>.from(r)))
        .toList();
    // Remember for instant startup next time.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _venueCacheKey, jsonEncode(list.map((v) => v.raw).toList()));
    } catch (_) {}
    return list;
  }

  /// Venues remembered from the last visit — instant, may be slightly stale.
  Future<List<Venue>> cachedVenues() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_venueCacheKey);
      if (s == null) return [];
      return (jsonDecode(s) as List)
          .map((r) => Venue.fromJson(Map<String, dynamic>.from(r)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ---------- discovery ----------

  /// Unscreened places already cached for a map area.
  Future<List<DiscoveredPlace>> discoveredInBounds(double minLat,
      double maxLat, double minLng, double maxLng) async {
    try {
      final rows = await _db
          .from('discovered_places')
          .select()
          .gte('lat', minLat)
          .lte('lat', maxLat)
          .gte('lng', minLng)
          .lte('lng', maxLng)
          .limit(200);
      return (rows as List)
          .map((r) => DiscoveredPlace.fromRow(Map<String, dynamic>.from(r)))
          .toList();
    } catch (_) {
      return []; // table not created yet
    }
  }

  /// Remember Google results so this area never needs a second Google call.
  Future<void> cacheDiscovered(List<DiscoveredPlace> places) async {
    if (places.isEmpty) return;
    try {
      await _db.from('discovered_places').upsert(
          places.map((p) => p.toRow()).toList(),
          onConflict: 'google_place_id');
    } catch (_) {}
  }

  /// The venue's shared wifi login (signed-in users only; null if none).
  Future<Map<String, dynamic>?> venueWifi(String venueId) async {
    try {
      final rows = await _db
          .from('venue_wifi')
          .select()
          .eq('venue_id', venueId)
          .limit(1);
      if ((rows as List).isEmpty) return null;
      return Map<String, dynamic>.from(rows.first);
    } catch (_) {
      return null;
    }
  }

  /// Community photos for a venue (verified submissions only), newest first.
  Future<List<String>> venuePhotoUrls(String venueId) async {
    try {
      final rows = await _db
          .from('venue_photos')
          .select('photo_path')
          .eq('venue_id', venueId)
          .order('verified_at', ascending: false)
          .limit(10);
      return (rows as List)
          .map((r) => photoUrl(r['photo_path'] as String))
          .toList();
    } catch (_) {
      return []; // view not created yet -> just no community photos
    }
  }

  /// Is this Google place already on the map?
  Future<Venue?> venueByPlaceId(String placeId) async {
    final rows = await _db
        .from('venues')
        .select()
        .eq('google_place_id', placeId)
        .limit(1);
    if ((rows as List).isEmpty) return null;
    return Venue.fromJson(Map<String, dynamic>.from(rows.first));
  }

  /// Insert a brand-new (pending) venue; returns its id.
  Future<String> addPendingVenue(Map<String, dynamic> fields) async {
    fields['status'] = 'pending';
    fields['created_by'] = currentUser!.id;
    final row =
        await _db.from('venues').insert(fields).select('id').single();
    return row['id'] as String;
  }

  // ---------- submissions & coins ----------

  /// Record a submission (photo optional — uploads it when provided).
  /// Coin awards happen automatically in the database (triggers).
  Future<void> submit({
    required String kind, // 'new_venue' | 'confirm'
    String? venueId,
    required Map<String, dynamic> payload,
    Uint8List? photoBytes,
    required double gpsLat,
    required double gpsLng,
    double? gpsDistanceM,
  }) async {
    final uid = currentUser!.id;
    String? path;
    if (photoBytes != null) {
      path = '$uid/${DateTime.now().millisecondsSinceEpoch}.jpg';
      await _db.storage.from('submission-photos').uploadBinary(
          path, photoBytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg'));
    }

    await _db.from('submissions').insert({
      'user_id': uid,
      'venue_id': venueId,
      'kind': kind,
      'payload': payload,
      'photo_path': path,
      'gps_lat': gpsLat,
      'gps_lng': gpsLng,
      'gps_distance_m': gpsDistanceM,
    });
  }

  // ---------- wallet ----------

  Future<({int withdrawable, int pending, int total})> wallet() async {
    final uid = currentUser?.id;
    if (uid == null) return (withdrawable: 0, pending: 0, total: 0);
    final rows =
        await _db.from('wallet').select().eq('user_id', uid);
    if ((rows as List).isEmpty) {
      return (withdrawable: 0, pending: 0, total: 0);
    }
    final r = Map<String, dynamic>.from(rows.first);
    return (
      withdrawable: (r['withdrawable'] as num).toInt(),
      pending: (r['pending'] as num).toInt(),
      total: (r['total'] as num).toInt(),
    );
  }

  // ---------- profile ----------

  /// My profile row: display_name + avatar_url.
  Future<Map<String, dynamic>?> myProfile() async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    try {
      final row = await _db
          .from('profiles')
          .select('display_name, avatar_url')
          .eq('id', uid)
          .single();
      return Map<String, dynamic>.from(row);
    } catch (_) {
      return null;
    }
  }

  /// Upload a new profile image and remember its URL.
  Future<String?> uploadAvatar(Uint8List bytes,
      {String ext = 'jpg', String contentType = 'image/jpeg'}) async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final path =
        '$uid/avatar_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage.from('avatars').uploadBinary(path, bytes,
        fileOptions: FileOptions(contentType: contentType));
    final url = _db.storage.from('avatars').getPublicUrl(path);
    await _db.from('profiles').update({'avatar_url': url}).eq('id', uid);
    return url;
  }

  Future<String?> myDisplayName() async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    try {
      final row = await _db
          .from('profiles')
          .select('display_name')
          .eq('id', uid)
          .single();
      return row['display_name'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> updateDisplayName(String name) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await _db
        .from('profiles')
        .update({'display_name': name}).eq('id', uid);
  }

  // ---------- leaderboard & live activity ----------

  Future<List<Map<String, dynamic>>> leaderboard({int limit = 100}) async {
    try {
      final rows = await _db
          .from('leaderboard')
          .select()
          .gt('coins', 0)
          .order('coins', ascending: false)
          .limit(limit);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> liveActivity() async {
    try {
      final rows = await _db.from('live_activity').select().limit(50);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>?> publicStats(String userId) async {
    try {
      final rows = await _db
          .from('leaderboard')
          .select()
          .eq('user_id', userId)
          .limit(1);
      if ((rows as List).isEmpty) return null;
      return Map<String, dynamic>.from(rows.first);
    } catch (_) {
      return null;
    }
  }

  // ---------- admin ----------

  Future<bool> isAdmin() async {
    final uid = currentUser?.id;
    if (uid == null) return false;
    try {
      final row = await _db
          .from('profiles')
          .select('is_admin')
          .eq('id', uid)
          .single();
      return row['is_admin'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Pending submissions for admin review (needs admin policies).
  Future<List<Map<String, dynamic>>> pendingSubmissions() async {
    final rows = await _db
        .from('submissions')
        .select()
        .eq('status', 'pending')
        .order('created_at', ascending: true);
    return (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Credibility snapshot of a submitter: name, coin totals, verified count.
  Future<Map<String, dynamic>> submitterStats(String userId) async {
    final profile = await _db
        .from('profiles')
        .select('display_name')
        .eq('id', userId)
        .single();
    final walletRows =
        await _db.from('wallet').select().eq('user_id', userId);
    final verified = await _db
        .from('submissions')
        .select('id')
        .eq('user_id', userId)
        .eq('status', 'verified');
    final wallet = (walletRows as List).isEmpty
        ? const {'withdrawable': 0, 'pending': 0}
        : Map<String, dynamic>.from(walletRows.first);
    return {
      'display_name': profile['display_name'] ?? 'Unknown',
      'withdrawable': (wallet['withdrawable'] as num?)?.toInt() ?? 0,
      'pending': (wallet['pending'] as num?)?.toInt() ?? 0,
      'verified_count': (verified as List).length,
    };
  }

  Future<Venue?> venueById(String id) async {
    final rows = await _db.from('venues').select().eq('id', id).limit(1);
    if ((rows as List).isEmpty) return null;
    return Venue.fromJson(Map<String, dynamic>.from(rows.first));
  }

  /// Admin fixes venue fields (spelling, wrong toggles) before approving.
  Future<void> updateVenueFields(
          String venueId, Map<String, dynamic> fields) =>
      _db.from('venues').update(fields).eq('id', venueId);

  Future<void> setSubmissionStatus(String submissionId, String status) =>
      _db.from('submissions').update({
        'status': status,
        if (status == 'verified')
          'verified_at': DateTime.now().toIso8601String(),
      }).eq('id', submissionId);

  String photoUrl(String path) =>
      _db.storage.from('submission-photos').getPublicUrl(path);

  Future<List<Map<String, dynamic>>> ledger() async {
    final uid = currentUser?.id;
    if (uid == null) return [];
    final rows = await _db
        .from('coin_ledger')
        .select()
        .eq('user_id', uid)
        .order('created_at', ascending: false);
    return (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

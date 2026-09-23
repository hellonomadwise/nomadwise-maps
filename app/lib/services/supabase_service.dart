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
        // Always show Google's account picker instead of silently
        // reusing whichever account signed in last time.
        queryParams: const {'prompt': 'select_account'},
      );

  Future<void> signOut() => _db.auth.signOut();

  // ---------- venues ----------

  static const _venueCacheKey = 'venues_cache_v1';

  Future<List<Venue>> fetchVenues() async {
    // A place Google reports closed for good leaves the map, unless a
    // founder has looked and said it is still open.
    final rows = await _db.from('venues').select().or(
        'business_status.is.null,business_status.neq.CLOSED_PERMANENTLY,'
        'closed_dismissed_at.not.is.null');
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

  /// Venues remembered from the last visit, instant, may be slightly stale.
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
          .where((p) => !p.excluded) // petrol/convenience chains
          .toList();
    } catch (_) {
      return []; // table not created yet
    }
  }

  /// Remember Google results so this area never needs a second Google
  /// call. The signed-in searcher is recorded as the discoverer; on
  /// conflict nothing is overwritten, so the FIRST finder keeps the
  /// claim forever.
  Future<void> cacheDiscovered(List<DiscoveredPlace> allPlaces) async {
    final places = allPlaces.where((p) => !p.excluded).toList();
    if (places.isEmpty) return;
    final uid = currentUser?.id;
    Future<void> save(bool withOwner) =>
        _db.from('discovered_places').upsert(
            places.map((p) {
              final r = p.toRow();
              if (withOwner && uid != null) r['discovered_by'] = uid;
              return r;
            }).toList(),
            onConflict: 'google_place_id',
            ignoreDuplicates: true);
    try {
      await save(true);
    } catch (_) {
      // Column not there yet (migration pending): save without it.
      try {
        await save(false);
      } catch (_) {}
    }
    // Browsing without an account? Remember the finds on this device
    // so they can be claimed after signing in.
    if (uid == null) await _rememberAnonFinds(places);
  }

  static const _anonFindsKey = 'anon_finds_v1';

  Future<void> _rememberAnonFinds(List<DiscoveredPlace> places) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cur = prefs.getStringList(_anonFindsKey) ?? [];
      final merged = {...cur, ...places.map((p) => p.placeId)};
      await prefs.setStringList(
          _anonFindsKey, merged.take(300).toList());
    } catch (_) {}
  }

  /// After signing in: unclaimed spaces this device discovered become
  /// yours. Returns how many were claimed.
  Future<int> claimAnonDiscoveries() async {
    final uid = currentUser?.id;
    if (uid == null) return 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_anonFindsKey) ?? [];
      if (ids.isEmpty) return 0;
      final rows = await _db
          .from('discovered_places')
          .update({'discovered_by': uid})
          .inFilter('google_place_id', ids)
          .isFilter('discovered_by', null)
          .select('google_place_id');
      await prefs.remove(_anonFindsKey);
      return (rows as List).length;
    } catch (_) {
      return 0;
    }
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

  /// Record a submission (photo optional, uploads it when provided).
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

  /// Anonymous fingerprint of the network this device is on right now.
  /// Same cafe WiFi = same fingerprint. Null when unavailable.
  Future<String?> networkFingerprint() async {
    try {
      final res = await _db.rpc('network_fingerprint');
      return res as String?;
    } catch (_) {
      return null; // migration not run yet, or signed out
    }
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

  /// Euro balance in cents (converted coins live here).
  Future<int> euroCents() async {
    final uid = currentUser?.id;
    if (uid == null) return 0;
    try {
      final rows =
          await _db.from('euro_ledger').select('cents').eq('user_id', uid);
      return (rows as List)
          .fold<int>(0, (a, r) => a + (r['cents'] as num).toInt());
    } catch (_) {
      return 0; // migration not run yet
    }
  }

  /// Convert the whole withdrawable coin balance into euros.
  /// Returns (coins converted, cents credited), or null on failure.
  Future<({int coins, int cents})?> convertCoins() async {
    try {
      final res = await _db.rpc('convert_coins_to_euros');
      final m = Map<String, dynamic>.from(res);
      if (m['error'] != null) return null;
      return (
        coins: (m['coins'] as num).toInt(),
        cents: (m['cents'] as num).toInt()
      );
    } catch (_) {
      return null;
    }
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

  /// One nomad's recent verified contributions (public, same data as
  /// the live feed).
  Future<List<Map<String, dynamic>>> publicUserActivity(
      String userId) async {
    try {
      final rows = await _db
          .from('live_activity')
          .select()
          .eq('user_id', userId)
          .limit(50);
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

  /// Admin only: recent app activity for the analytics screen.
  Future<List<Map<String, dynamic>>> adminEvents({int days = 7}) async {
    try {
      final since = DateTime.now()
          .toUtc()
          .subtract(Duration(days: days))
          .toIso8601String();
      final rows = await _db
          .from('app_events')
          .select()
          .gte('created_at', since)
          .order('created_at', ascending: false)
          .limit(2000);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Admin only: which accounts belong to which group
  /// ('team' | 'friend'; absent = genuine customer).
  /// Devices (anonymous ids) that have ever signed into a team
  /// account, excluded from analytics even when browsing signed out.
  Future<Set<String>> teamDevices() async {
    try {
      final rows = await _db.from('team_devices').select('anon_id');
      return {for (final r in rows as List) r['anon_id'] as String};
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, String>> profileCohorts() async {
    try {
      final rows = await _db
          .from('profiles')
          .select('id, cohort')
          .not('cohort', 'is', null);
      return {
        for (final r in rows as List)
          r['id'] as String: r['cohort'] as String
      };
    } catch (_) {
      return {}; // column not there yet
    }
  }

  /// Admin only: put an account in a group (null = customer).
  Future<void> setCohort(String userId, String? cohort) async {
    try {
      await _db
          .from('profiles')
          .update({'cohort': cohort}).eq('id', userId);
    } catch (_) {}
  }

  /// Admin only: coin/euro totals across all users.
  /// Who put this space on the map: the discoverer (area search)
  /// and the first verified screener. Public display names only.
  Future<Map<String, dynamic>?> venueCredits(String venueId) async {
    try {
      final res =
          await _db.rpc('venue_credits', params: {'p_venue_id': venueId});
      if (res == null) return null;
      return Map<String, dynamic>.from(res);
    } catch (_) {
      return null;
    }
  }

  /// Admin: replace a venue's list of curated-away Google photos.
  Future<bool> setHiddenPhotos(String venueId, List<String> hidden) async {
    try {
      await _db
          .from('venues')
          .update({'hidden_photos': hidden}).eq('id', venueId);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------- city sweeps (admin) ----------

  Future<List<Map<String, dynamic>>> citySweeps() async {
    try {
      final rows = await _db
          .from('city_sweeps')
          .select()
          .order('swept_at', ascending: false);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<String>> sweepQueue() async {
    try {
      final rows = await _db.from('sweep_queue').select('city');
      return [for (final r in rows as List) r['city'] as String];
    } catch (_) {
      return [];
    }
  }

  Future<bool> queueCitySweep(String city) async {
    try {
      await _db.from('sweep_queue').upsert({
        'city': city,
        if (currentUser != null) 'requested_by': currentUser!.id,
      }, onConflict: 'city');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> adminEconomy() async {
    try {
      final res = await _db.rpc('admin_economy');
      if (res == null) return null;
      return Map<String, dynamic>.from(res);
    } catch (_) {
      return null;
    }
  }

  // ---------- feedback ----------

  Future<bool> sendFeedback(String message, {String? contact}) async {
    try {
      await _db.from('feedback').insert({
        'message': message,
        if (contact != null && contact.trim().isNotEmpty)
          'contact': contact.trim(),
        if (currentUser != null) 'user_id': currentUser!.id,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Admin only: all feedback, newest first.
  Future<List<Map<String, dynamic>>> feedbackInbox() async {
    try {
      final rows = await _db
          .from('feedback')
          .select()
          .order('created_at', ascending: false)
          .limit(200);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> setFeedbackStatus(String id, String status) async {
    try {
      await _db.from('feedback').update({'status': status}).eq('id', id);
    } catch (_) {}
  }

  /// Admin only: names for a set of user ids.
  Future<Map<String, String>> displayNamesFor(
      List<String> userIds) async {
    if (userIds.isEmpty) return {};
    try {
      final rows = await _db
          .from('profiles')
          .select('id, display_name')
          .inFilter('id', userIds);
      return {
        for (final r in rows as List)
          r['id'] as String: (r['display_name'] ?? 'Nomad') as String
      };
    } catch (_) {
      return {};
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

  /// The latest verified submissions (mostly self-verified via GPS),
  /// so auto-approval is visible to the admin, not silent.
  Future<List<Map<String, dynamic>>> recentVerified(
      {int limit = 20}) async {
    try {
      final rows = await _db
          .from('submissions')
          .select('id, kind, verified_at, gps_distance_m, payload, '
              'user_id, venue_id, venues(name)')
          .eq('status', 'verified')
          .order('verified_at', ascending: false)
          .limit(limit);
      final list = (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
      // Names come from profiles in one extra query (no FK for a join).
      final ids = list.map((r) => r['user_id']).toSet().toList();
      if (ids.isNotEmpty) {
        final profs = await _db
            .from('profiles')
            .select('id, display_name')
            .inFilter('id', ids);
        final names = {
          for (final p in (profs as List)) p['id']: p['display_name']
        };
        for (final r in list) {
          r['display_name'] = names[r['user_id']];
        }
      }
      return list;
    } catch (_) {
      return [];
    }
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

  /// Admin only: every account, with email + activity summary.
  Future<List<Map<String, dynamic>>> adminUsers() async {
    final rows = await _db.rpc('admin_users');
    return (rows as List)
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  /// Admin only: one user's submission history with venue names.
  Future<List<Map<String, dynamic>>> adminUserActivity(
      String userId) async {
    final rows =
        await _db.rpc('admin_user_activity', params: {'target': userId});
    return (rows as List)
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  Future<Venue?> venueById(String id) async {
    final rows = await _db.from('venues').select().eq('id', id).limit(1);
    if ((rows as List).isEmpty) return null;
    return Venue.fromJson(Map<String, dynamic>.from(rows.first));
  }

  /// A listing by its nomadwise.io slug, for the booking request form.
  Future<Map<String, dynamic>?> venueBySlug(String slug) async {
    try {
      final rows = await _db
          .from('venues')
          .select('id, name, city, neighbourhood, webflow_slug, listing_tier')
          .eq('webflow_slug', slug)
          .limit(1);
      if ((rows as List).isEmpty) return null;
      return Map<String, dynamic>.from(rows.first);
    } catch (_) {
      return null;
    }
  }

  /// Files a booking request; the database emails it on.
  Future<void> sendEnquiry(Map<String, dynamic> row) =>
      _db.from('enquiries').insert(row);

  // ---------- claiming a listing (public, no account) ----------

  /// The public claim form's search: name, where, and whether the space
  /// already has a page or is already Verified. Nothing else is exposed.
  Future<List<Map<String, dynamic>>> claimSearch(String q) async {
    try {
      final rows = await _db.rpc('claim_search', params: {'p_query': q});
      return (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Someone opened the claim page: logged, and the phone is pinged
  /// with which listing page they came from. Fire and forget.
  Future<void> claimOpened({
    String? seed,
    String? from,
    String? referrer,
    String? userAgent,
  }) async {
    try {
      await _db.rpc('claim_opened', params: {
        'p_seed': seed ?? '',
        'p_from': from ?? '',
        'p_referrer': referrer ?? '',
        'p_user_agent': userAgent ?? '',
      });
    } catch (_) {}
  }

  /// Records a claim before the owner goes to Stripe and returns
  /// {claim_id, venue_id}. The claim id rides along in the payment link.
  Future<Map<String, dynamic>?> startClaim(Map<String, dynamic> p) async {
    final res = await _db.rpc('start_claim', params: {'p': p});
    return res == null ? null : Map<String, dynamic>.from(res as Map);
  }

  /// Claims a founder has not seen resolve yet (control centre).
  Future<List<Map<String, dynamic>>> openClaims({int limit = 100}) async {
    try {
      final rows = await _db
          .from('listing_claims')
          .select('id, venue_id, is_new_space, owner_name, owner_email, '
              'owner_phone, owner_role, enquiry_email, space_name, '
              'space_city, space_country, space_website, space_instagram, '
              'note, status, created_at, paid_at')
          .order('created_at', ascending: false)
          .limit(limit);
      return (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Marks a claim that never paid as abandoned.
  Future<void> abandonClaim(String id) =>
      _db.rpc('abandon_claim', params: {'p_claim': id});

  /// Paid claims on pages already on the site, waiting for a founder
  /// to approve before anything on the page changes.
  Future<List<Map<String, dynamic>>> heldClaims() async {
    try {
      final rows = await _db
          .from('listing_claims')
          .select('id, venue_id, owner_name, owner_email, owner_phone, '
              'owner_role, enquiry_email, space_name, space_website, '
              'space_instagram, note, paid_at, created_at, order_json, '
              'venues(name, city, country, website, listing_owner_email)')
          .eq('status', 'awaiting_approval')
          .order('paid_at', ascending: false)
          .limit(50);
      return (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (_) {
      return [];
    }
  }

  /// The founders looked: it is theirs. Makes the listing Verified.
  Future<Map<String, dynamic>?> approveClaim(String id) async {
    final res = await _db.rpc('approve_claim', params: {'p_claim': id});
    return res == null ? null : Map<String, dynamic>.from(res as Map);
  }

  /// Wrong space or wrong person. The page is untouched; the refund is
  /// done in Stripe.
  Future<void> rejectClaim(String id, String reason) =>
      _db.rpc('reject_claim', params: {'p_claim': id, 'p_reason': reason});

  /// Starts the website push run on GitHub now (founders only).
  /// Returns 'requested', or 'no_token' when the GitHub token is not
  /// in the Vault.
  Future<String> requestWebsitePush() async {
    final res = await _db.rpc('request_website_push');
    return '$res';
  }

  /// Booking requests per listing (admin), newest first.
  Future<List<Map<String, dynamic>>> enquiries({int limit = 400}) async {
    try {
      final rows = await _db
          .from('enquiries')
          .select('id, venue_id, name, email, want, dates, people, message, '
              'status, to_email, sent_at, send_error, created_at')
          .order('created_at', ascending: false)
          .limit(limit);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Re-sends a failed booking request (after the Resend key exists).
  Future<void> resendEnquiry(String id) =>
      _db.rpc('resend_enquiry', params: {'p_id': id});

  /// Admin fixes venue fields (spelling, wrong toggles) before approving.
  Future<void> updateVenueFields(
          String venueId, Map<String, dynamic> fields) =>
      _db.from('venues').update(fields).eq('id', venueId);

  /// Saves plain links for a venue's Google photos (merge, never
  /// overwrite), so later views cost nothing. Any signed-in nomad.
  /// The app found a venue's Google photos dead (names expire after
  /// about four weeks): put it at the front of tonight's refresh.
  Future<void> reportStalePhotos(String venueId) async {
    try {
      await _db.rpc('report_stale_photos', params: {'p_venue': venueId});
    } catch (_) {}
  }

  Future<void> cacheGooglePhotos(String venueId, Map<String, String> urls) async {
    try {
      await _db.rpc('cache_google_photos',
          params: {'p_venue': venueId, 'p_urls': urls});
    } catch (_) {}
  }

  /// What the founder kept and skipped among the suggested photos,
  /// recorded at Approve so the nightly run can learn their taste.
  Future<void> recordPhotoPicks(List<Map<String, dynamic>> rows) =>
      _db.from('photo_picks').insert(rows);

  // ---------- website control centre (nomadwise.io) ----------

  static const _websiteCols =
      'id, name, type, city, neighbourhood, country, google_place_id, status, '
      'website_status, webflow_slug, webflow_cms_id, website_synced_at, '
      'website_prepared, website_prepared_at, website_approved_at, '
      'website_dismissed_at, website_dismiss_reason, website_dismiss_note, '
      'website_region_override, website_location_override, '
      'website_new_region, website_new_location, '
      'website_slug_override, website_photos, sitemap_added_at, created_at, '
      'google_rating_snapshot, google_reviews_snapshot, wifi_speed_mbps, '
      'laptops_allowed, website_photo_candidates, website_photos_auto, '
      'website_publish_requested_at, '
      'business_status, business_status_at, closed_seen_at, '
      'closed_dismissed_at, website_retire_requested_at, website_retired_at, '
      'website_retire_note, website_retire_done_at, '
      'listing_tier, listing_paid_at, listing_renews_at, listing_owner_name, '
      'listing_owner_email, listing_enquiry_email, listing_notes, '
      'listing_sync_requested_at, listing_synced_at, listing_sync_error, '
      'webflow_verified, '
      // Just the address parts of the cached Google details, so the
      // inbox can show the country without loading the whole record.
      'address_components:g_details->addressComponents, '
      'short_address:g_details->>shortFormattedAddress';

  /// Everything that needs a founder's decision about the site: new
  /// verified spaces not yet on nomadwise.io (unless dismissed) and
  /// spaces already queued (waiting for a proposal, a Region, or an
  /// approval). Ordering is done by the screen.
  Future<List<Map<String, dynamic>>> websiteInbox() async {
    final rows = await _db
        .from('venues')
        .select(_websiteCols)
        .eq('status', 'verified')
        .inFilter('website_status', ['not_on_site', 'queued'])
        .isFilter('website_dismissed_at', null)
        .order('created_at', ascending: false);
    return (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Spaces a founder marked "Not for the site" (kept, never deleted).
  Future<List<Map<String, dynamic>>> websiteHidden() async {
    try {
      final rows = await _db
          .from('venues')
          .select(_websiteCols)
          .eq('status', 'verified')
          .eq('website_status', 'not_on_site')
          .not('website_dismissed_at', 'is', null)
          .order('website_dismissed_at', ascending: false);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Spaces Google reports as not operating that still have a page
  /// (until a founder answers), plus pages retired from the app that
  /// still need the founder's last two steps (sitemap, site publish).
  Future<List<Map<String, dynamic>>> websiteClosed() async {
    try {
      final rows = await _db.from('venues').select(_websiteCols).or(
          'and(closed_seen_at.not.is.null,closed_dismissed_at.is.null,'
          'website_retired_at.is.null,'
          'website_status.in.(published_hidden,released)),'
          'and(website_retired_at.not.is.null,website_retire_done_at.is.null)')
          .order('closed_seen_at', ascending: true);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Paid (Verified) listings, soonest renewal first, plus pages whose
  /// Webflow Verified switch is on without a plan in the app (legacy
  /// premium pages), so the two never drift apart unnoticed.
  Future<List<Map<String, dynamic>>> websitePaid() async {
    try {
      final rows = await _db
          .from('venues')
          .select(_websiteCols)
          .or('listing_tier.neq.free,webflow_verified.eq.true')
          .order('listing_renews_at', ascending: true, nullsFirst: false);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Paid Verified checkouts that could not be matched to a space.
  Future<List<Map<String, dynamic>>> unmatchedStripeOrders() async {
    try {
      final rows = await _db
          .from('stripe_orders')
          .select('id, email, name, space_name, space_link, amount, currency, '
              'paid_at, renews_at, created_at')
          .eq('status', 'unmatched')
          .order('created_at', ascending: false);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> attachStripeOrder(String orderId, String venueId) =>
      _db.rpc('attach_stripe_order', params: {'p_order': orderId, 'p_venue': venueId});

  Future<void> ignoreStripeOrder(String orderId) =>
      _db.rpc('ignore_stripe_order', params: {'p_order': orderId});

  /// Released pages matching a search, from the whole database rather
  /// than the latest 300 the screen holds. Name, city or slug.
  Future<List<Map<String, dynamic>>> websiteReleasedSearch(String q,
      {int limit = 100}) async {
    final clean = q.replaceAll(RegExp(r'[,()\\*]'), ' ').trim();
    if (clean.length < 2) return [];
    try {
      final rows = await _db
          .from('venues')
          .select(_websiteCols)
          .eq('website_status', 'released')
          .or('name.ilike.%$clean%,city.ilike.%$clean%,'
              'neighbourhood.ilike.%$clean%,webflow_slug.ilike.%$clean%')
          .order('name', ascending: true)
          .limit(limit);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Spaces by name, for attaching an order (any status, any site state).
  Future<List<Map<String, dynamic>>> searchVenues(String q) async {
    try {
      final rows = await _db
          .from('venues')
          .select('id, name, city, neighbourhood, website_status, webflow_slug')
          .ilike('name', '%$q%')
          .order('name', ascending: true)
          .limit(30);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Quick badge count for the menu; same rule as [websiteInbox].
  Future<int> websiteInboxCount() async {
    try {
      final rows = await _db
          .from('venues')
          .select('id')
          .eq('status', 'verified')
          .inFilter('website_status', ['not_on_site', 'queued'])
          .isFilter('website_dismissed_at', null);
      return (rows as List).length;
    } catch (_) {
      return 0;
    }
  }

  /// Spaces with a Webflow page that is not released yet (drafts the
  /// founders still have to finish and publish in Webflow).
  Future<List<Map<String, dynamic>>> websiteDrafts() async {
    final rows = await _db
        .from('venues')
        .select(_websiteCols)
        .eq('website_status', 'published_hidden')
        .order('website_synced_at', ascending: false);
    return (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Released pages, newest release first.
  Future<List<Map<String, dynamic>>> websiteReleased(
      {int limit = 300}) async {
    final rows = await _db
        .from('venues')
        .select(_websiteCols)
        .eq('website_status', 'released')
        .order('website_synced_at', ascending: false)
        .limit(limit);
    return (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Released pages whose entry has not gone into the custom sitemap.
  Future<List<Map<String, dynamic>>> sitemapPending() async {
    final rows = await _db
        .from('venues')
        .select(_websiteCols)
        .eq('website_status', 'released')
        .isFilter('sitemap_added_at', null)
        .not('webflow_slug', 'is', null)
        .order('name', ascending: true);
    return (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// The nightly copy of the Webflow Regions collection.
  Future<List<Map<String, dynamic>>> webflowRegions() async {
    try {
      final rows = await _db
          .from('webflow_regions')
          .select('id, name, slug, country')
          .order('name', ascending: true);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// The nightly copy of the Webflow Locations collection (the
  /// neighbourhood pages), each with the Region it belongs to.
  /// The Countries collection, copied by the sync, for the Region
  /// creator's picker.
  Future<List<Map<String, dynamic>>> webflowCountries() async {
    try {
      final rows = await _db
          .from('webflow_countries')
          .select('id, name, slug')
          .order('name', ascending: true);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// A Region or Location the founder asked the sync to create in
  /// Webflow. The push run builds, publishes and links it.
  Future<void> createTaxonomyRequest(Map<String, dynamic> row) =>
      _db.from('taxonomy_requests').insert({
        ...row,
        'requested_by': currentUser?.id,
      });

  Future<List<Map<String, dynamic>>> webflowLocations() async {
    try {
      final rows = await _db
          .from('webflow_locations')
          .select('id, name, slug, region_id, country')
          .order('name', ascending: true);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Sitemap tab: which released pages have already been pasted into
  /// the custom sitemap. Also dismissed venues that were released
  /// anyway keep working, since this only touches sitemap_added_at.
  Future<void> markSitemapAdded(List<String> venueIds) async {
    if (venueIds.isEmpty) return;
    await _db.from('venues').update({
      'sitemap_added_at': DateTime.now().toUtc().toIso8601String()
    }).inFilter('id', venueIds);
  }

  /// The log of directory pages set up since it started: regions,
  /// locations and countries first seen in Webflow, newest first,
  /// still waiting for their custom sitemap entry. Pages that predate
  /// the log are untracked and never appear (migration 70).
  Future<List<Map<String, dynamic>>> _sitemapLog(
      String table, String cols) async {
    try {
      final rows = await _db
          .from(table)
          .select(cols)
          .eq('sitemap_tracked', true)
          .isFilter('sitemap_added_at', null)
          .not('slug', 'is', null)
          .order('first_seen_at', ascending: false);
      return (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> sitemapPendingRegions() => _sitemapLog(
      'webflow_regions', 'id, name, slug, country, source, first_seen_at');

  Future<List<Map<String, dynamic>>> sitemapPendingLocations() => _sitemapLog(
      'webflow_locations',
      'id, name, slug, country, region_id, source, first_seen_at');

  Future<List<Map<String, dynamic>>> sitemapPendingCountries() => _sitemapLog(
      'webflow_countries', 'id, name, slug, source, first_seen_at');

  /// Ticks region or location pages off the sitemap list. [table] is
  /// 'webflow_regions' or 'webflow_locations'.
  Future<void> markTaxonomySitemapAdded(
      String table, List<String> ids) async {
    if (ids.isEmpty) return;
    await _db.from(table).update({
      'sitemap_added_at': DateTime.now().toUtc().toIso8601String()
    }).inFilter('id', ids);
  }

  Future<void> setSubmissionStatus(String submissionId, String status) =>
      _db.from('submissions').update({
        'status': status,
        if (status == 'verified')
          'verified_at': DateTime.now().toIso8601String(),
      }).eq('id', submissionId);

  String photoUrl(String path) =>
      _db.storage.from('submission-photos').getPublicUrl(path);

  /// Admin: community photos waiting for a quality/safety check
  /// before they appear on space pages.
  Future<List<Map<String, dynamic>>> pendingPhotos() async {
    try {
      final rows = await _db
          .from('submissions')
          .select('id, photo_path, created_at, venue_id, venues(name)')
          .not('photo_path', 'is', null)
          .eq('photo_status', 'pending')
          .order('created_at', ascending: false)
          .limit(30);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (_) {
      return []; // column not created yet
    }
  }

  /// Admin: approve or reject one community photo.
  Future<void> setPhotoStatus(String submissionId, String status) =>
      _db
          .from('submissions')
          .update({'photo_status': status}).eq('id', submissionId);

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

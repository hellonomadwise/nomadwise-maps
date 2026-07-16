import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config.dart';
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
      _db.auth.signUp(email: email, password: password);

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

  Future<List<Venue>> fetchVenues() async {
    final rows = await _db.from('venues').select();
    return (rows as List)
        .map((r) => Venue.fromJson(Map<String, dynamic>.from(r)))
        .toList();
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

  /// Upload the required photo, then record the submission.
  /// Coin awards happen automatically in the database (triggers).
  Future<void> submit({
    required String kind, // 'new_venue' | 'confirm'
    String? venueId,
    required Map<String, dynamic> payload,
    required Uint8List photoBytes,
    required double gpsLat,
    required double gpsLng,
    double? gpsDistanceM,
  }) async {
    final uid = currentUser!.id;
    final path =
        '$uid/${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _db.storage.from('submission-photos').uploadBinary(
        path, photoBytes,
        fileOptions: const FileOptions(contentType: 'image/jpeg'));

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

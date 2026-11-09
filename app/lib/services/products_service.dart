import 'package:supabase_flutter/supabase_flutter.dart';

/// Products (day pass, month pass, meeting room, ...) and the price
/// check (migration 131). Kept in its own file, away from
/// supabase_service.dart, so two people working on the app at once
/// seldom need the same file.
class ProductsService {
  SupabaseClient get _db => Supabase.instance.client;

  static Map<String, dynamic> _map(dynamic r) =>
      r is Map ? Map<String, dynamic>.from(r) : <String, dynamic>{};

  static List<Map<String, dynamic>> _list(dynamic r) => [
        for (final x in (r as List? ?? const []))
          if (x is Map) Map<String, dynamic>.from(x)
      ];

  /// How many of each currency make one euro (migration 290), and when
  /// the rates were read. Empty until the daily job has run.
  Future<(Map<String, double>, DateTime?)> fxRates() async {
    final rows = _list(await _db.from('fx_rates').select('currency, per_eur, updated_at'));
    final out = <String, double>{};
    DateTime? at;
    for (final r in rows) {
      final v = r['per_eur'];
      final n = v is num ? v.toDouble() : double.tryParse('$v');
      if (n != null && n > 0) out['${r['currency']}'.toUpperCase()] = n;
      final t = DateTime.tryParse('${r['updated_at'] ?? ''}');
      if (t != null && (at == null || t.isAfter(at))) at = t;
    }
    return (out, at);
  }

  /// A message to the space's owner, in their Chats (they are emailed
  /// when they have not seen it within a minute): Price check's "Ask
  /// the owner to check".
  Future<void> askOwner(String venueId, String body) =>
      _db.rpc('admin_chat_send', params: {'p_venue': venueId, 'p_body': body});

  /// The numbers at the top of the Price check screen.
  Future<Map<String, dynamic>> overview() async =>
      _map(await _db.rpc('admin_prices_overview'));

  /// The spaces that have products. [filter]: '' (all), 'requested',
  /// 'waiting', 'unchecked' or 'checked'.
  Future<List<Map<String, dynamic>>> spaces(
          {String query = '', String filter = '', int limit = 60}) async =>
      _list(await _db.rpc('admin_prices_spaces',
          params: {'p_q': query, 'p_filter': filter, 'p_limit': limit}));

  /// One space: its products, what is waiting on each, the request and
  /// the last check.
  Future<Map<String, dynamic>> space(String venueId) async =>
      _map(await _db.rpc('admin_prices_space', params: {'p_venue': venueId}));

  /// Ask for a space's prices to be checked; asking again changes the
  /// note.
  Future<void> requestCheck(String venueId, {String? note}) =>
      _db.rpc('admin_price_check_request',
          params: {'p_venue': venueId, 'p_note': note});

  Future<void> cancelRequest(String venueId) =>
      _db.rpc('admin_price_check_request_cancel', params: {'p_venue': venueId});

  /// Every open request with the space's own website and what we show
  /// today, to pass on.
  Future<List<Map<String, dynamic>>> requests() async =>
      _list(await _db.rpc('admin_price_check_requests'));

  /// Go: this change goes on the public page. With [edited], the
  /// founder's own version of it goes instead.
  Future<void> go(String changeId, {Map<String, dynamic>? edited}) =>
      _db.rpc('admin_product_change_go',
          params: {'p_id': changeId, 'p_final': edited});

  /// Skip: the page stays as it is.
  Future<void> skip(String changeId) =>
      _db.rpc('admin_product_change_skip', params: {'p_id': changeId});

  /// Undo. Returns what the change was before: 'approved' (taken back
  /// before it was written), 'applied' (the old one is being put
  /// back) or 'skipped' (brought back to decide again).
  Future<String> undo(String changeId) async {
    final r = _map(await _db
        .rpc('admin_product_change_undo', params: {'p_id': changeId}));
    return '${r['was'] ?? ''}';
  }

  /// A founder's own change. [action]: 'update', 'add' or 'remove'.
  /// Saving is the Go.
  Future<void> edit(String venueId,
          {String? productId,
          required String action,
          Map<String, dynamic>? product}) =>
      _db.rpc('admin_product_edit', params: {
        'p_venue': venueId,
        'p_product': productId,
        'p_action': action,
        'p_json': product,
      });
}

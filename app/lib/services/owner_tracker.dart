import 'dart:async';
import 'dart:math';

import 'supabase_service.dart';

/// Owner account: what an owner does on one visit, step by step, so we
/// can see what helps and what gets ignored or abandoned (Jonathan,
/// 7 Nov 2026). Steps are kept on the device and sent in small batches
/// (migration 283, owner_track); nothing is sent for a founder's
/// preview. Read in the control centre under Owner activity.
///
/// Kinds of step:
///   session_start   the visit began (device, screen width, link)
///   tab             a tab opened: to, and from + secs on the last one
///   leave           the page went to the background: from + secs
///   space           switched to another location
///   edit_start / edit_save / edit_cancel / edit_close   a part of My
///                   listing (part, secs)
///   ask_shown / ask_open / ask_dismissed / wish_sent    "Looking for
///                   something?"
///   anything else   a button they pressed (see_page, period, ...)
class OwnerTracker {
  OwnerTracker() : session = _uuid();

  final String session;
  final _supabase = SupabaseService();
  final List<Map<String, dynamic>> _queue = [];
  final List<Map<String, dynamic>> _recent = [];
  Map<String, dynamic>? _meta;
  bool started = false;
  bool _sending = false;

  /// May we ask "Looking for something?" (the database says no when
  /// we asked in the last 14 days).
  bool askOk = false;
  bool askedThisVisit = false;

  String? tab;
  DateTime _tabSince = DateTime.now();
  String? editing;
  DateTime _editSince = DateTime.now();
  final DateTime _visitStart = DateTime.now();
  final List<(DateTime, String)> _tabOpens = [];
  int editsStarted = 0;
  int editsLeft = 0;

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  int _secs(DateTime since) => DateTime.now().difference(since).inSeconds;

  void start({
    required String device,
    required int width,
    required String cameFrom,
    required int spaces,
    String? venue,
    required String firstTab,
  }) {
    if (started) return;
    started = true;
    _meta = {
      'device': device,
      'width': width,
      'came_from': cameFrom,
      'spaces': spaces,
      'venue': venue,
    };
    step('session_start', {'device': device, 'width': width, 'from': cameFrom}, venue);
    tab = firstTab;
    _tabSince = DateTime.now();
    _tabOpens.add((DateTime.now(), firstTab));
    step('tab', {'to': firstTab}, venue);
    flush();
  }

  void step(String kind, [Map<String, dynamic>? detail, String? venue]) {
    if (!started && kind != 'session_start') return;
    final e = <String, dynamic>{
      'kind': kind,
      'detail': detail ?? const {},
      'venue': venue,
      'at': DateTime.now(),
    };
    _queue.add(e);
    _recent.add(e);
    if (_recent.length > 12) _recent.removeAt(0);
    if (_queue.length > 400) _queue.removeRange(0, _queue.length - 400);
  }

  void tabChanged(String to, String? venue) {
    if (!started || to == tab) return;
    step('tab', {'from': tab, 'to': to, 'secs': _secs(_tabSince)}, venue);
    tab = to;
    _tabSince = DateTime.now();
    _tabOpens.add((DateTime.now(), to));
  }

  void editStart(String part, String? venue) {
    if (editing == part) return;
    editing = part;
    _editSince = DateTime.now();
    editsStarted++;
    step('edit_start', {'part': part}, venue);
  }

  /// how: save, cancel or close (closed some other way)
  void editEnd(String how, String? venue) {
    final part = editing;
    if (part == null) return;
    editing = null;
    if (how == 'cancel') editsLeft++;
    step('edit_$how', {'part': part, 'secs': _secs(_editSince)}, venue);
  }

  /// The page went to the background or closed: time on the tab so far.
  void hidden(String? venue) {
    if (!started) return;
    step('leave', {'from': tab, 'secs': _secs(_tabSince)}, venue);
    _tabSince = DateTime.now();
    flush();
  }

  void shown() => _tabSince = DateTime.now();

  /// Looks lost: four or more different tabs within two minutes, at
  /// least 40 seconds into the visit, without starting to change
  /// anything.
  bool get looksLost {
    final now = DateTime.now();
    if (now.difference(_visitStart).inSeconds < 40) return false;
    if (editsStarted > 0) return false;
    final recent = _tabOpens
        .where((x) => now.difference(x.$1).inSeconds <= 120)
        .map((x) => x.$2)
        .toSet();
    return recent.length >= 4;
  }

  /// Gave up: left two parts of My listing without saving.
  bool get gaveUp => editsLeft >= 2;

  /// The last steps before they asked, for context.
  List<Map<String, dynamic>> trail() => [
        for (final e in _recent)
          {
            'kind': e['kind'],
            'detail': e['detail'],
            'secs_ago': DateTime.now().difference(e['at'] as DateTime).inSeconds,
          }
      ];

  Future<void> flush({bool beat = false}) async {
    if (!started || _sending) return;
    if (_queue.isEmpty && !beat) return;
    _sending = true;
    final batch = List<Map<String, dynamic>>.from(_queue.take(200));
    final now = DateTime.now();
    try {
      final res = await _supabase.ownerTrack(session, _meta ?? const {}, [
        for (final e in batch)
          {
            'kind': e['kind'],
            'detail': e['detail'],
            'venue': e['venue'],
            'ago_ms': now.difference(e['at'] as DateTime).inMilliseconds,
          }
      ]);
      _queue.removeRange(0, min(batch.length, _queue.length));
      askOk = res['ask_ok'] == true;
    } catch (_) {
      // Kept; the next batch tries again.
    } finally {
      _sending = false;
    }
  }
}

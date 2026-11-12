import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, FilteringTextInputFormatter, TextInputFormatter;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/analytics_service.dart';
import '../services/location_service.dart';
import '../services/speed_test_service.dart';
import '../services/supabase_service.dart';
import '../services/owner_tracker.dart';
import '../theme.dart';
import 'claim_screen.dart';
import '../widgets/billing_panel.dart';
import '../widgets/chat_thread.dart';
import '../widgets/currencies.dart';
import '../widgets/dial_codes.dart';
import '../widgets/map_embed_stub.dart'
    if (dart.library.html) '../widgets/map_embed_web.dart';
import '../widgets/ideas_board.dart';
import '../widgets/owner_question_card.dart';
import '../widgets/phone_field.dart';
import '../widgets/price.dart';
import '../widgets/pricing_picker.dart' show PricingChoice, formatMoney;
import '../widgets/price_checks.dart' show pricePers, perOf, withoutPer, withPer, perFromName;
import '../widgets/email_typo_hint.dart';
import '../widgets/motion.dart';

/// A pop-up in the Owner account's own style. A pop-up is drawn above
/// the page, outside the page's theme, so it used to come out in the
/// app's rounder look (28 px corners, pill buttons, a 20 px box).
/// Opened through here it carries the same 8 px corners, buttons and
/// boxes as the page under it (Jonathan, 12 Nov 2026: "remember for
/// border radius px8").
Future<T?> _ownerDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
}) =>
    showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor ?? Colors.black54,
      builder: (ctx) => Theme(
          data: siteButtons(Theme.of(ctx), radius: 8),
          child: Builder(builder: builder)),
    );

/// The Owner account at nomadmaps.io/?owner ("Nomadwise for Spaces"
/// to the owner; never "members area").
///
/// Sign in with the email an approved claim recorded on the space (a
/// link by email, or Google). Then: My listing (edit a draft of the
/// page with a live preview), the advert-slot message (Verified), and
/// Membership. Every change is a draft until a founder puts it on the
/// page. No analytics, no perks: decided with Leonie.
class OwnerScreen extends StatefulWidget {
  /// Founders only: open this listing's Owner account (venue id or
  /// page slug) in preview, whoever owns it. Nothing is saved.
  final String? previewKey;

  /// With [previewKey]: Team edit (migration 240). The same screen, and
  /// it saves: the team's changes go on the page at once and reach
  /// nomadwise.io with the ten-minute website push. No email goes out.
  final bool team;
  const OwnerScreen({super.key, this.previewKey, this.team = false});

  @override
  State<OwnerScreen> createState() => _OwnerScreenState();
}

const double _wideAt = 960;

enum _Tab { locations, listing, message, membership, badges, performance, settings, ideas, chat }

class _OwnerScreenState extends State<OwnerScreen> {
  final _supabase = SupabaseService();
  StreamSubscription? _auth;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _venues = [];

  // ---- founders' preview (?owner&preview=<slug>) ----
  bool get _isPreview => widget.previewKey != null;
  Map<String, dynamic>? _previewBase; // the listing as it is
  // Every space on the same owner's account, as the owner has them
  // (Jonathan, 12 Nov 2026: "i want to see how the join account works,
  // where they can see the multiple spaces"). Empty for a single space.
  List<Map<String, dynamic>> _previewGroup = const [];
  // What the owner would see: 'waiting_free' / 'waiting_paid' (claimed,
  // not checked yet: the blurred account), 'free' or 'verified'.
  String _previewAs = 'free';
  int _current = 0;
  // What Premium costs where a space is (pricing_for, by country), kept
  // so the Get Premium window can name the price the moment it opens.
  final Map<String, Future<Map<String, dynamic>?>> _planPrices = {};
  Future<Map<String, dynamic>?> _planPriceFor(Map<String, dynamic>? v) {
    final country = '${v?['country'] ?? ''}'.trim();
    return _planPrices[country] ??= _supabase.pricingFor(country);
  }

  // All locations (migration 281): each space's last 30 days, by id;
  // and whether a group owner has been taken to it on arrival.
  Map<String, Map<String, dynamic>> _locStats = const {};
  bool _landed = false;
  // Back from Stripe's billing page (?owner&billing): open Plan & billing.
  // (?owner&chat, from the email that says we wrote: Inbox & support.)
  _Tab _tab = Uri.base.queryParameters.containsKey('billing')
      ? _Tab.membership
      : Uri.base.queryParameters.containsKey('chat')
          ? _Tab.chat
          : _Tab.listing;

  // Inbox & support (migration 161): per space, how many messages
  // from Nomadwise have not been opened; looked up now and then, so
  // the number appears while the account is open on another tab.
  Map<String, int> _chatUnread = const {};
  Timer? _chatTimer;
  // "Still here", every minute while the account is on screen
  // (migration 198), so the founders can see the owner is in.
  Timer? _hereTimer;
  // What they do on this visit, step by step (migration 283): read in
  // the control centre under Owner activity.
  final _trk = OwnerTracker();
  Timer? _trkTimer;
  AppLifecycleListener? _life;
  _Tab? _trkTabSeen;
  int _trkCur = -1;
  bool _askOpen = false;
  // Things they asked for that we have done: "It's here now".
  List<Map<String, dynamic>> _wishNews = const [];
  // Our newest unread message, shown in a small card in the corner
  // while they are elsewhere in the account (migration 198); each
  // message pops up once.
  Map<String, dynamic>? _pop;
  final Set<String> _popSeen = {};
  // The space the email's button names (?chat=<space>), opened once.
  String? _chatSpace = Uri.base.queryParameters['chat'];

  // Sign-in form
  final _email = TextEditingController();
  bool _sending = false;
  bool _linkSent = false;

  /// Claims made with this email that we have not approved yet: shown
  /// with where they stand instead of "no space on this account".
  List<Map<String, dynamic>> _pending = [];

  /// The claim made on this device (email, claim id, and when the
  /// owner came back from Stripe), for the "confirming" state.
  Map<String, dynamic>? _lastClaim;

  /// While a payment is being confirmed, the page checks again by
  /// itself every few seconds.
  Timer? _poll;

  // Editor state (one draft per space, rebuilt when the space changes)
  final _description = TextEditingController();
  static const _descriptionMax = 8000;
  final _priceDay = TextEditingController();
  final _priceWeek = TextEditingController();
  final _priceMonth = TextEditingController();
  final _priceCoffee = TextEditingController();
  // The prices' currency: the country's own unless the owner changes
  // it. Owners type the amount only; the page gets "€3.60" or "900 LKR".
  String _currency = 'EUR';
  // The price list being edited (migration 218): one row per price.
  final List<_PriceRow> _priceRows = [];
  // Paste a price list (migration 242): Claude reads it and the list
  // above fills in. A newer paste, or closing the editor, drops an
  // older answer (_pasteSeq).
  final _pasteText = TextEditingController();
  bool _pasteOpen = false;
  bool _pasteBusy = false;
  String? _pasteError;
  String? _pasteDone;
  int _pasteSeq = 0;
  // "Bookmark this page" tip, until the owner says Got it.
  bool _showTip = false;
  // The small Build next note under the menu, until its X is pressed.
  bool _ideasNoteClosed = false;
  final _website = TextEditingController();
  final _instagram = TextEditingController();
  final _whatsapp = TextEditingController(); // the number, no country code
  // The WhatsApp number's country (ISO code), picked from the list.
  final _waCountry = ValueNotifier<String?>(null);
  // The description as sections: the opening text, then any number of
  // headed sections. Stored as one text with "## " heading lines, which
  // the page turns into headings; owners never see the ## (S3-5).
  final List<(TextEditingController, TextEditingController)> _sections = [];
  final _enquiryEmail = TextEditingController();
  // Free enquiries used and left (migration 212), for the space shown.
  Map<String, dynamic>? _allow;
  final _hours = {for (final d in _days) d: TextEditingController()};
  final _facts = <String, bool?>{};
  List<String> _photos = [];
  // Jonathan, 15 Oct 2026: adding one photo used to replace all five
  // on the page. The editor now opens with the photos the page shows
  // today, slot by slot, so an owner replaces or removes the ones they
  // choose and the rest stay. _photosFromPage: the list started as the
  // page's own photos; _photosTouched: the owner changed it. Only a
  // touched list is saved, so an owner who edits only their prices
  // leaves the page's photos (and our own top-ups) as they are.
  bool _photosFromPage = false;
  bool _photosTouched = false;
  // The slot a dragged photo is over, to show where it will land.
  int? _photoDropAt;
  // The hours Google shows today, when the owner has set none of their
  // own: the form opens with them, and they are only saved as the
  // owner's once a day is changed, so an untouched page keeps
  // following Google.
  Map<String, String> _googleHours = {};
  // The page preview: as a phone shows it, or as a computer does.
  bool _previewComputer = false;
  final _mentionTitle = TextEditingController();
  final _mentionBody = TextEditingController();
  final _mentionCta = TextEditingController();
  final _mentionUrl = TextEditingController();
  String _mentionKind = 'Event';
  bool _dirty = false;
  bool _saving = false;
  bool _closedBusy = false; // CR-36: setting "temporarily closed"
  final Set<String> _badgeCodeShown = {}; // CR-26: View code open
  final Map<String, String> _badgeStyle = {}; // CR-26: shape -> white/red/outline
  // Settings (migration 251): which emails this owner gets.
  Map<String, bool>? _emailPrefs;
  String? _prefBusy; // the switch being saved
  String? _savedNote;
  // Autosave: edits are kept as a draft a few seconds after typing
  // stops, so leaving the page (to Go Verified, say) loses nothing
  // (Leonie's review, 28 Sep).
  Timer? _autoTimer;
  bool _autosaving = false;
  int _editSeq = 0;
  DateTime _lastEdit = DateTime(2000);
  DateTime? _autoSavedAt;

  static const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  static const _dayNames = {
    'mon': 'Monday',
    'tue': 'Tuesday',
    'wed': 'Wednesday',
    'thu': 'Thursday',
    'fri': 'Friday',
    'sat': 'Saturday',
    'sun': 'Sunday',
  };
  static const _factLabels = [
    ('laptops_allowed', 'Laptops welcome'),
    ('power_outlets', 'Plug sockets on most tables'),
    ('good_for_calls', 'Good for calls'),
    ('quiet_space', 'Quiet area'),
    ('comfortable_seating', 'Comfortable seating'),
    ('aircon', 'Aircon'),
    ('access_24h', '24 hour access'),
    ('call_room', 'Call room or booth'),
    ('monitor', 'Monitors available'),
    ('office_chairs', 'Office chairs'),
    ('cozy', 'Cozy'),
    // The page's other tags (migration 218, Jonathan 24 Oct).
    ('swimming_pool', 'Swimming pool'),
    ('no_traffic_noise', 'No traffic noise'),
    ('low_background_music', 'Low background music'),
    ('instagramable', 'Instagramable'),
    ('vegan_friendly', 'Vegan friendly'),
    ('pass_required', 'Pass required'),
  ];

  Map<String, dynamic>? get _venue =>
      _venues.isEmpty ? null : _venues[_current.clamp(0, _venues.length - 1)];
  bool get _verified => _venue?['listing_tier'] == 'verified';
  Map<String, dynamic>? get _draft => (_venue?['draft'] is Map)
      ? Map<String, dynamic>.from(_venue!['draft'] as Map)
      : null;

  /// True while the hours in the form are still Google's, as loaded.
  bool get _hoursUntouched =>
      _googleHours.isNotEmpty &&
      _days.every((d) => _hours[d]!.text.trim() == (_googleHours[d] ?? ''));

  /// The photos on the page today (the website's own copies).
  List<String> get _pagePhotos => [
        for (final u in (_venue?['page_photos'] as List? ?? const []))
          if ('$u'.startsWith('http')) '$u'
      ];

  /// The passes and prices the page shows today: (name, price, kind).
  List<(String, String, String)> get _pageProducts => [
        for (final p in (_venue?['page_products'] as List? ?? const []))
          if (p is Map && '${p['name'] ?? ''}'.trim().isNotEmpty)
            (
              '${p['name']}'.trim(),
              '${p['label'] ?? ''}'.trim(),
              '${p['category'] ?? ''}'
            )
      ];

  @override
  void initState() {
    super.initState();
    _auth = _supabase.authChanges.listen((_) => _load());
    _life = AppLifecycleListener(
      onHide: () => _trk.hidden(_venueId),
      onShow: _trk.shown,
    );
    _load();
    _prefillEmail();
    SharedPreferences.getInstance().then((p) {
      if (mounted) {
        setState(() {
          _showTip = !(p.getBool('owner_bookmark_tip') ?? false);
          _ideasNoteClosed = p.getBool('owner_ideas_note_closed') ?? false;
        });
      }
    }).catchError((_) {});
    for (final c in [
      _description, _priceDay, _priceWeek, _priceMonth, _priceCoffee,
      _website, _instagram, _whatsapp, _enquiryEmail,
      _mentionTitle, _mentionBody, _mentionCta, _mentionUrl,
      ..._hours.values,
    ]) {
      c.addListener(() {
        _editSeq++;
        _lastEdit = DateTime.now();
        if (!_dirty && mounted) setState(() => _dirty = true);
        if (mounted) setState(() {}); // live preview
      });
    }
    _waCountry.addListener(() {
      _editSeq++;
      _lastEdit = DateTime.now();
      if (mounted) setState(() => _dirty = true);
    });
    _autoTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_dirty &&
          DateTime.now().difference(_lastEdit) > const Duration(seconds: 2)) {
        _autosave();
      }
    });
  }

  /// Keep the edits as a draft, quietly. Nothing changes on the page;
  /// the editor is not reloaded (that would move the cursor).
  Future<void> _autosave() async {
    if (_isPreview) return;
    final v = _venue;
    if (v == null || !_dirty || _saving || _autosaving) return;
    if (!_supabase.signedIn) return;
    _autosaving = true;
    final seq = _editSeq;
    final data = _collect();
    if (mounted) setState(() {});
    try {
      final res = await _supabase.ownerSaveDraft(v['id'], data, submit: false);
      if (!mounted) return;
      setState(() {
        if (_editSeq == seq) _dirty = false;
        _autoSavedAt = DateTime.now();
        v['draft'] = {
          ...?(v['draft'] is Map
              ? Map<String, dynamic>.from(v['draft'] as Map)
              : null),
          'id': res['id'],
          'status': res['status'],
          'draft': data,
        };
      });
    } catch (_) {
      // Stays "unsaved"; the next tick tries again.
    } finally {
      _autosaving = false;
      if (mounted) setState(() {});
    }
  }

  /// Save now, then go: for links that leave the page.
  Future<void> _saveThenOpen(String url) async {
    if (_isPreview) {
      setState(() => _savedNote = 'Preview: this would open $url');
      return;
    }
    await _autosave();
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
  }

  Future<void> _loadChatUnread() async {
    if (_isPreview || !_supabase.signedIn) return;
    final m = await _supabase.ownerChatUnread();
    if (!mounted) return;
    if ('$m' != '$_chatUnread') setState(() => _chatUnread = m);
    if (m.values.any((n) => n > 0)) _checkPop();
  }

  bool get _onScreen {
    final life = WidgetsBinding.instance.lifecycleState;
    return life != AppLifecycleState.hidden &&
        life != AppLifecycleState.paused &&
        life != AppLifecycleState.detached;
  }

  void _beat() {
    if (_isPreview || !_supabase.signedIn || _venues.isEmpty) return;
    if (_onScreen) {
      _supabase.ownerHere();
      _trk.flush(beat: true);
    }
  }

  /// A message from us they have not read: shown once in the corner,
  /// unless they are already in that space's inbox.
  Future<void> _checkPop() async {
    if (_isPreview || _pop != null || !_onScreen) return;
    final list = await _supabase.ownerChatWaiting();
    if (!mounted || _pop != null) return;
    final here = '${_venue?['id']}';
    for (final x in list) {
      final id = '${x['id']}';
      if (_popSeen.contains(id)) continue;
      if (_tab == _Tab.chat && '${x['venue_id']}' == here) continue;
      _popSeen.add(id);
      setState(() => _pop = x);
      return;
    }
  }

  void _goTab(_Tab t) => setState(() {
        _tab = t;
        // opening that inbox reads the message: the card goes
        if (t == _Tab.chat && '${_pop?['venue_id']}' == '${_venue?['id']}') {
          _pop = null;
        }
      });

  void _openPop() {
    final x = _pop;
    if (x == null) return;
    final i = _venues.indexWhere((r) => '${r['id']}' == '${x['venue_id']}');
    final other = i >= 0 && i != _current;
    setState(() {
      if (other) _current = i;
      _tab = _Tab.chat;
      _pop = null;
    });
    if (other) _fillEditor();
  }

  Widget _popCard(bool wide) {
    final x = _pop!;
    final who = '${x['author'] ?? ''}'.trim();
    final name = who.isEmpty ? 'Nomadwise' : '$who from Nomadwise';
    final more = ((x['unread'] as num?) ?? 1).toInt() - 1;
    final space = '${x['venue_name'] ?? ''}'.trim();
    return TweenAnimationBuilder<double>(
      key: ValueKey('pop-${x['id']}'),
      tween: Tween(begin: 0, end: 1),
      duration: Motion.of(context, const Duration(milliseconds: 220)),
      curve: Curves.easeOutCubic,
      builder: (_, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, 24 * (1 - t)), child: child)),
      child: Material(
        color: Colors.white,
        elevation: 10,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: wide ? 360 : double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Brand.hairline)),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: Brand.red,
                    child: Text(who.isEmpty ? 'N' : who[0].toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 15)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 14)),
                          if (_venues.length > 1 && space.isNotEmpty)
                            Text('About $space',
                                style: const TextStyle(
                                    fontSize: 12, color: Brand.inkMuted)),
                        ]),
                  ),
                  IconButton(
                      tooltip: 'Close',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _pop = null),
                      icon: const Icon(Icons.close, size: 18)),
                ]),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('${x['body'] ?? ''}'.trim(),
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.45)),
                ),
                if (more > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        more == 1 ? 'and 1 more message' : 'and $more more messages',
                        style: const TextStyle(
                            fontSize: 12, color: Brand.inkMuted)),
                  ),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(
                      onPressed: () => setState(() => _pop = null),
                      child: const Text('Later')),
                  const SizedBox(width: 4),
                  FilledButton(onPressed: _openPop, child: const Text('Reply')),
                  const SizedBox(width: 8),
                ]),
              ]),
        ),
      ),
    );
  }

  /// Unread messages from Nomadwise for the space on screen.
  int get _chatWaiting => _chatUnread['${_venue?['id']}'] ?? 0;

  /// The same for all their spaces together: the number in the menu.
  int get _chatWaitingAll => _chatUnread.values.fold(0, (a, b) => a + b);

  @override
  void dispose() {
    _newHeadingFocus.dispose();
    _auth?.cancel();
    _poll?.cancel();
    _chatTimer?.cancel();
    _hereTimer?.cancel();
    _autoTimer?.cancel();
    _trkTimer?.cancel();
    _life?.dispose();
    _trk.hidden(_venueId);
    for (final (h, b) in _sections) {
      h.dispose();
      b.dispose();
    }
    for (final r in _priceRows) {
      r.dispose();
    }
    _pasteText.dispose();
    super.dispose();
  }

  /// The email they claimed with, from the link (?email=) or from the
  /// claim made on this device, so signing in is one tap.
  Future<void> _prefillEmail() async {
    var em = '';
    try {
      em = Uri.base.queryParameters['email'] ?? '';
    } catch (_) {}
    _lastClaim = await SupabaseService.lastClaim();
    if (mounted) setState(() {});
    if (!em.contains('@')) {
      em = '${_lastClaim?['email'] ?? ''}';
    }
    final found = em.trim().toLowerCase();
    if (found.contains('@') && _email.text.trim().isEmpty && mounted) {
      setState(() => _email.text = found);
    }
  }

  bool _seenSent = false;

  Future<void> _load() async {
    if (!_supabase.signedIn) {
      // Signed out: the next owner to sign in here is a new opening.
      _seenSent = false;
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (_isPreview) return _loadPreview();
    try {
      final rows = await _supabase.ownerVenues();
      final pending = await _supabase.ownerPendingClaims();
      // An owner opened their account: counted (once for this screen;
      // the database also folds reloads within half an hour into one).
      if (rows.isNotEmpty && !_seenSent) {
        _seenSent = true;
        _supabase.ownerSeen();
      }
      if (rows.isNotEmpty) _loadWishNews();
      if (rows.isNotEmpty && _emailPrefs == null) _loadEmailPrefs();
      if (!mounted) return;
      _watchPayments(pending);
      setState(() {
        _venues = rows;
        _pending = pending;
        _loading = false;
        _error = null;
        if (_current >= rows.length) _current = 0;
        // Owners with two or more locations land on All locations
        // (Jonathan, 6 Nov 2026), unless a link asked for a tab.
        if (!_landed && rows.length > 1) {
          final q = Uri.base.queryParameters;
          if (!q.containsKey('billing') && !q.containsKey('chat')) {
            _tab = _Tab.locations;
          }
        }
        _landed = true;
        // the space the email's button named, the first time through
        final want = (_chatSpace ?? '').trim();
        _chatSpace = null;
        if (want.isNotEmpty) {
          final i = rows.indexWhere((r) => '${r['id']}' == want);
          if (i >= 0) _current = i;
        }
      });
      _fillEditor(closeEditing: false);
      if (rows.length > 1) _loadLocStats();
      if (rows.isNotEmpty) {
        _loadChatUnread();
        _chatTimer ??= Timer.periodic(
            const Duration(seconds: 20), (_) => _loadChatUnread());
        _beat();
        _hereTimer ??=
            Timer.periodic(const Duration(seconds: 60), (_) => _beat());
        _trkTimer ??= Timer.periodic(
            const Duration(seconds: 15), (_) => _trk.flush());
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load your spaces: $e';
        });
      }
    }
  }

  Future<void> _loadPreview() async {
    try {
      final v = await _supabase.adminOwnerView(widget.previewKey!);
      if (!mounted) return;
      if (v == null) {
        setState(() {
          _loading = false;
          _error = 'No listing found for "${widget.previewKey}".';
        });
        return;
      }
      _previewBase = v;
      _previewAs = v['listing_tier'] == 'verified' ? 'verified' : 'free';
      // The owner's other spaces, so a founder sees the account as the
      // owner does: All locations first, and the name menu to switch.
      // The space on screen before a reload (Team edit reloads after a
      // save): stay on it.
      final keep = _venues.isEmpty ? null : '${_venue?['id']}';
      var group = const <Map<String, dynamic>>[];
      try {
        group = await _supabase.adminOwnerViewGroup(widget.previewKey!);
      } catch (_) {
        // the one space still shows
      }
      if (!mounted) return;
      _previewGroup = group.length > 1 ? group : const [];
      _applyPreview();
      if (keep != null) {
        final i = _venues.indexWhere((g) => '${g['id']}' == keep);
        if (i >= 0 && i != _current) {
          setState(() => _current = i);
          _fillEditor();
        }
      }
      if (_previewGroup.isNotEmpty && !_landed) {
        _landed = true;
        // The preview opens where the owner lands, on All locations;
        // Team edit opens on the space that was asked for.
        if (!widget.team) setState(() => _tab = _Tab.locations);
        _loadLocStats();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e'.contains('admin only')
              ? 'Only Nomadwise founders can preview Owner accounts. Sign '
                  'in with your founder account.'
              : 'Could not load the preview: $e';
        });
      }
    }
  }

  /// Lay the preview out as the chosen state.
  void _applyPreview() {
    final b = _previewBase;
    if (b == null) return;
    final waiting = _previewAs.startsWith('waiting');
    setState(() {
      _loading = false;
      _error = null;
      final shown = <String, dynamic>{
        ...b,
        'listing_tier': _previewAs == 'verified' ? 'verified' : 'free'
      };
      // A group: every space as it is, the one opened shown in the
      // chosen state.
      _venues = waiting
          ? []
          : _previewGroup.isEmpty
              ? [shown]
              : [
                  for (final g in _previewGroup)
                    '${g['id']}' == '${b['id']}' ? shown : g
                ];
      _pending = waiting
          ? [
              {
                'claim_id': 'preview',
                'venue_id': b['id'],
                'name': b['name'],
                'type': b['type'],
                'city': b['city'],
                'neighbourhood': b['neighbourhood'],
                'plan': _previewAs == 'waiting_paid' ? 'verified' : 'free',
                'status': _previewAs == 'waiting_paid'
                    ? 'awaiting_approval'
                    : 'free_pending',
                'paid': _previewAs == 'waiting_paid',
                // The address the owner claimed with (not the founder's).
                'owner_email': b['listing_owner_email'] ?? b['claim_email'],
              }
            ]
          : [];
      final at = _venues.indexWhere((g) => '${g['id']}' == '${b['id']}');
      _current = at < 0 ? 0 : at;
    });
    if (!waiting) _fillEditor();
  }

  /// The founders' bar above a preview: which state to look at, and
  /// the reminder that nothing here is saved.
  Widget _previewBar() {
    if (widget.team) {
      return Container(
        width: double.infinity,
        color: Brand.red,
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
        child: const Text(
            'TEAM EDIT: SAVING CHANGES THE LIVE PAGE ON NOMADWISE.IO. '
            'NO EMAIL GOES TO THE OWNER.',
            style: TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .4)),
      );
    }
    const states = [
      ('waiting_free', 'Claimed, not checked'),
      ('waiting_paid', 'Paid, not checked'),
      ('free', 'Claimed'),
      ('verified', 'Premium'),
    ];
    // One slim line: the reminder, then the states to look at, which
    // swipe sideways on a phone instead of taking two rows.
    return Container(
      width: double.infinity,
      color: Brand.ink,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          const Text('PREVIEW, NOTHING IS SAVED',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .5)),
          const SizedBox(width: 10),
          // To change the space for real (migration 240).
          TextButton.icon(
            onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                    // the space on screen (a group shows several)
                    builder: (_) => OwnerScreen(
                        previewKey: '${_venue?['id'] ?? widget.previewKey}',
                        team: true))),
            style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.edit_outlined, size: 15),
            label: const Text('Edit for real',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 6),
          for (final (key, label) in states)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(label),
                selected: _previewAs == key,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                selectedColor: Brand.red,
                backgroundColor: Colors.white,
                side: BorderSide.none,
                labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _previewAs == key ? Colors.white : Brand.ink),
                onSelected: (_) {
                  _previewAs = key;
                  _applyPreview();
                },
              ),
            ),
        ]),
      ),
    );
  }

  /// A Verified claim still waiting for its payment: ask for it to be
  /// picked up now (the database lets one request through every two
  /// minutes) and look again every few seconds until it lands.
  void _watchPayments(List<Map<String, dynamic>> pending) {
    final waiting = pending
        .where((c) => c['status'] == 'started' && c['plan'] != 'free')
        .toList();
    if (waiting.isEmpty) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    for (final c in waiting) {
      _supabase.paymentReturned('${c['claim_id']}');
    }
    _poll ??= Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) _load();
    });
  }

  /// This device came back from Stripe for this claim in the last few
  /// hours: the payment is almost certainly on its way.
  bool _justPaid(Map<String, dynamic> c) {
    final lc = _lastClaim;
    if (lc == null || '${lc['claim_id']}' != '${c['claim_id']}') return false;
    final at = DateTime.tryParse('${lc['returned_at'] ?? ''}');
    return at != null && DateTime.now().toUtc().difference(at).inHours < 6;
  }

  /// How many free enquiries the space has left. Only shown once the
  /// rule is switched on (migration 212) and for a free page.
  Future<void> _loadAllowance(String venueId) async {
    final a = await _supabase.ownerEnquiryAllowance(venueId);
    if (!mounted || '${_venue?['id']}' != venueId) return;
    setState(() => _allow = a);
  }

  /// "1 of 2 free enquiries left", with the way to unlimited ones.
  Widget? _allowanceLine() {
    final a = _allow;
    if (a == null || a['on'] != true || _verified) return null;
    final limit = (a['limit'] as num?)?.toInt() ?? 2;
    final left = (a['left'] as num?)?.toInt() ?? 0;
    final held = (a['held'] as num?)?.toInt() ?? 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Brand.field, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$left of $limit free requests left',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        const SizedBox(height: 4),
        Text(
            held > 0
                ? '$held ${held == 1 ? 'request is' : 'requests are'} '
                    'waiting for you. With Premium, '
                    '${held == 1 ? 'it comes' : 'they come'} straight to your '
                    'inbox, and so does every request after.'
                : 'Your free requests go straight to your inbox. With Premium, '
                    'every request does.',
            style: const TextStyle(
                fontSize: 13, height: 1.45, color: Brand.inkSecondary)),
        const SizedBox(height: 6),
        // Roomy, so the hover shade sits around the words; moved left by
        // its padding so the words still line up with the text above.
        Transform.translate(
          offset: const Offset(-12, 0),
          child: TextButton(
              onPressed: () => _getPlus('enquiry'),
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  minimumSize: const Size(0, 40),
                  foregroundColor: _pageRed,
                  textStyle: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8))),
              child: const Text('Get unlimited requests', softWrap: false)),
        ),
      ]),
    );
  }

  /// The editor starts from the draft if there is one, else from what
  /// is on the page today.
  /// A reload in the background (sign-in refresh, payment check) leaves
  /// a part that is open for editing as it is ([closeEditing] false);
  /// switching space closes it.
  void _fillEditor({bool closeEditing = true}) {
    final v = _venue;
    if (v == null) return;
    // A free page: have its Premium price ready for the window.
    if (v['listing_tier'] != 'verified') _planPriceFor(v);
    if (closeEditing) {
      _editing = null;
      _snap = null;
    } else if (_editing != null) {
      return;
    }
    _allow = null;
    _loadAllowance('${v['id']}');
    final draft = _draft;
    final d = (draft != null && draft['status'] != 'applied')
        ? Map<String, dynamic>.from(draft['draft'] as Map? ?? {})
        : <String, dynamic>{};
    final oc = Map<String, dynamic>.from(v['owner_content'] as Map? ?? {});
    String s(dynamic x) => (x ?? '').toString();
    final prices = Map<String, dynamic>.from(
        (d['prices'] ?? oc['prices'] ?? {}) as Map);
    // The page's own description when nothing newer: the owner edits
    // our words instead of starting from a blank box.
    String firstText(List<dynamic> xs) =>
        xs.map(s).firstWhere((t) => t.trim().isNotEmpty, orElse: () => '');
    _description.text = firstText(
        [d['description'], oc['description'], v['page_description']]);
    final stored = [prices['day'], prices['week'], prices['month'], prices['coffee']]
        .map(s)
        .toList();
    _currency = stored.map(Price.codeIn).firstWhere((c) => c != null,
            orElse: () => null) ??
        Price.forCountry('${v['country'] ?? ''}') ??
        'EUR';
    _priceDay.text = Price.amountOf(stored[0]);
    _priceWeek.text = Price.amountOf(stored[1]);
    _priceMonth.text = Price.amountOf(stored[2]);
    _priceCoffee.text = Price.amountOf(stored[3]);
    _website.text = s(d['website'] ?? v['website']);
    _instagram.text = _igHandle(s(d['instagram'] ?? v['instagram'])) ?? '';
    final (waIso, waNumber) = _splitPhone(
        s(d['whatsapp'] ?? oc['whatsapp']), '${v['country'] ?? ''}');
    _waCountry.value = waIso;
    _whatsapp.text = waNumber;
    _enquiryEmail.text = s(d['enquiry_email'] ?? v['listing_enquiry_email']);
    // An empty hours map in a draft means "nothing changed" (that is
    // what an untouched form saves), so the page's own hours still count.
    final draftHours = d['hours'];
    final hours = Map<String, dynamic>.from(
        ((draftHours is Map && draftHours.isNotEmpty)
            ? draftHours
            : v['opening_hours'] ?? {}) as Map);
    // No hours of their own: open with the ones Google shows, which
    // is what the page shows too (Jonathan, 5 Oct 2026).
    final own = _days.any((day) => s(hours[day]).trim().isNotEmpty);
    final google = v['google_hours'] is Map
        ? Map<String, dynamic>.from(v['google_hours'] as Map)
        : const <String, dynamic>{};
    _googleHours = own
        ? {}
        : {
            for (final day in _days)
              if (s(google[day]).trim().isNotEmpty) day: s(google[day]).trim()
          };
    for (final day in _days) {
      _hours[day]!.text = own ? s(hours[day]) : (_googleHours[day] ?? '');
    }
    final facts = Map<String, dynamic>.from(
        (d['facts'] ?? v['facts'] ?? {}) as Map);
    _facts.clear();
    for (final (key, _) in _factLabels) {
      _facts[key] = facts[key] as bool?;
    }
    _photos = List<String>.from(
        (d['photos'] ?? oc['photos'] ?? const []) as List);
    _photosTouched = false;
    _photosFromPage = false;
    if (_photos.isEmpty && _pagePhotos.isNotEmpty) {
      _photos = _pagePhotos.take(5).toList();
      _photosFromPage = true;
    }
    final m = Map<String, dynamic>.from(
        (d['mention'] ?? oc['mention'] ?? {}) as Map);
    _mentionKind = ['Event', 'Offer', 'Announcement'].contains(m['kind'])
        ? m['kind']
        : 'Event';
    _mentionTitle.text = s(m['title']);
    _mentionBody.text = s(m['body']);
    _mentionCta.text = s(m['cta']);
    _mentionUrl.text = s(m['url']);
    _loadSections();
    _dirty = false;
    if (mounted) setState(() {});
  }

  Map<String, dynamic> _collect() => {
        'description': _description.text.trim(),
        'prices': {
          'day': Price.format(Price.cleanAmount(_priceDay.text), _currency),
          'week': Price.format(Price.cleanAmount(_priceWeek.text), _currency),
          'month': Price.format(Price.cleanAmount(_priceMonth.text), _currency),
          'coffee': Price.format(Price.cleanAmount(_priceCoffee.text), _currency),
        },
        // Google's hours, untouched, are not saved as the owner's own.
        'hours': _hoursUntouched
            ? <String, String>{}
            : {
                for (final day in _days)
                  if (_hours[day]!.text.trim().isNotEmpty)
                    day: _hours[day]!.text.trim()
              },
        'facts': {
          for (final e in _facts.entries)
            if (e.value != null) e.key: e.value
        },
        'website': _website.text.trim(),
        'instagram': (_igHandle(_instagram.text) ?? '').isEmpty
            ? ''
            : '@${_igHandle(_instagram.text)}',
        'whatsapp': _whatsapp.text.trim().isEmpty
            ? ''
            : PhoneField.compose(_waCountry.value, _whatsapp.text),
        'enquiry_email': _enquiryEmail.text.trim(),
        // The page's own photos, untouched, are not saved as the
        // owner's (see _photosFromPage).
        'photos':
            _photosFromPage && !_photosTouched ? <String>[] : _photos,
        if (_verified)
          'mention': {
            'kind': _mentionKind,
            'title': _mentionTitle.text.trim(),
            'body': _mentionBody.text.trim(),
            'cta': _mentionCta.text.trim(),
            'url': _mentionUrl.text.trim(),
          },
      };

  /// An Instagram handle without the @, from "@kelp.cowork",
  /// "kelp.cowork" or a profile link; '' when empty, null when it
  /// cannot be a handle.
  static String? _igHandle(String raw) {
    var h = raw.trim();
    if (h.isEmpty) return '';
    final link = RegExp(r'instagram\.com/([^/?#\s]+)', caseSensitive: false)
        .firstMatch(h);
    if (link != null) h = link.group(1)!;
    h = h.replaceFirst(RegExp(r'^@+'), '').trim();
    if (h.isEmpty) return '';
    return RegExp(r'^[A-Za-z0-9._]{1,30}$').hasMatch(h) ? h : null;
  }

  /// "+94 70 646 8666" or a wa.me link into its country (ISO) and the
  /// number without the code; the space's country when no code is given.
  static (String?, String) _splitPhone(String raw, String country) {
    final home = PhoneField.isoFor(country);
    var t = raw.trim();
    final link = RegExp(r'wa\.me/\+?(\d+)').firstMatch(t);
    if (link != null) t = '+${link.group(1)}';
    if (t.isEmpty) return (home, '');
    final digits = t.replaceAll(RegExp(r'\D'), '');
    if (t.startsWith('+') || t.startsWith('00')) {
      final d = t.startsWith('00') ? digits.substring(2) : digits;
      // Longest dial code that matches; the space's own country wins a tie
      // (+1 is shared by the US and Canada, say).
      String? best;
      var bestLen = 0;
      for (final (_, iso, code) in dialCodes) {
        final c = '$code';
        if (d.startsWith(c) &&
            (c.length > bestLen || (c.length == bestLen && iso == home))) {
          best = iso;
          bestLen = c.length;
        }
      }
      if (best != null) return (best, d.substring(bestLen));
    }
    return (home, digits);
  }

  // ---- description sections ----
  (TextEditingController, TextEditingController) _newSection(
      String heading, String body) {
    final h = TextEditingController(text: heading);
    final b = TextEditingController(text: body);
    h.addListener(_sectionsChanged);
    b.addListener(_sectionsChanged);
    return (h, b);
  }

  /// Split the description into the opening text and headed sections.
  void _loadSections() {
    // The old boxes may still be on screen until the next frame, so
    // their controllers are let go only after it.
    final old = List.of(_sections);
    _sections.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final (h, b) in old) {
        h.dispose();
        b.dispose();
      }
    });
    String? heading;
    final body = <String>[];
    final parts = <(String, String)>[];
    void flush() {
      parts.add((heading ?? '', body.join('\n').trim()));
      body.clear();
    }

    for (final line in _description.text.replaceAll('\r', '').split('\n')) {
      final m = RegExp(r'^\s*#{1,6}\s+(.*)$').firstMatch(line);
      if (m != null) {
        flush();
        heading = m.group(1)!.trim();
      } else {
        body.add(line);
      }
    }
    flush();
    // The first part is always the opening text (no heading).
    for (final (h, b) in parts) {
      if (_sections.isNotEmpty && h.isEmpty && b.isEmpty) continue;
      _sections.add(_newSection(h, b));
    }
  }

  /// Put the sections back together as the one description text.
  void _sectionsChanged() {
    final out = <String>[];
    for (var i = 0; i < _sections.length; i++) {
      final (h, b) = _sections[i];
      final head = h.text.replaceAll('\n', ' ').replaceFirst(RegExp(r'^#+\s*'), '').trim();
      final text = b.text.trim();
      if (i == 0) {
        if (text.isNotEmpty) out.add(text);
        continue;
      }
      if (head.isEmpty && text.isEmpty) continue;
      out.add([if (head.isNotEmpty) '## $head', if (text.isNotEmpty) text]
          .join('\n'));
    }
    final joined = out.join('\n\n');
    if (joined != _description.text) _description.text = joined;
  }

  /// The headings an owner can pick for a section (Leonie, 15 Oct
  /// 2026); they can still type their own.
  static const _sectionHeadings = [
    'Location',
    'Desk Setup',
    'Food & Drinks',
    'Wi-Fi & Power',
    'Meeting & Call Rooms',
    'Community & Events',
  ];

  // True right after "My own heading" adds a section, so its heading
  // box opens ready to type in.
  bool _focusNewHeading = false;
  final _newHeadingFocus = FocusNode();
  static const _ownHeading = '\u0000own';

  /// Adds a section, with [heading] already filled in when picked from
  /// the list, or empty for the owner's own.
  void _addSection([String heading = '']) {
    setState(() {
      _focusNewHeading = heading.isEmpty;
      _sections.add(_newSection(heading, ''));
    });
    _sectionsChanged();
    if (heading.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _newHeadingFocus.requestFocus();
      });
    }
  }

  void _removeSection(int i) {
    final (h, b) = _sections.removeAt(i);
    _sectionsChanged();
    setState(() {});
    // After this frame, when the boxes are gone from the screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      h.dispose();
      b.dispose();
    });
  }

  Future<void> _save({required bool submit}) async {
    final v = _venue;
    if (v == null) return;
    if (_isPreview && widget.team) {
      if (_description.text.length > _descriptionMax) {
        setState(() => _savedNote = 'The description is a little long: '
            '8,000 characters at most.');
        return;
      }
      setState(() {
        _saving = true;
        _savedNote = null;
      });
      try {
        await _supabase.adminTeamSave(v['id'], _collect());
        await _loadPreview();
        if (!mounted) return;
        setState(() {
          _dirty = false;
          _savedNote = 'Saved to the page. It shows on nomadwise.io within '
              'about 10 minutes.';
        });
      } catch (e) {
        if (mounted) setState(() => _savedNote = 'That did not save: $e');
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }
    if (_isPreview) {
      setState(() => _savedNote = 'Preview: nothing is saved. For the '
          'owner this would ${submit ? 'send the changes to you for review' : 'save a draft'}.');
      return;
    }
    // (Instagram is a Premium part: a free page has no field to fix it in.)
    if (submit && _verified && _igHandle(_instagram.text) == null) {
      setState(() => _savedNote = 'That Instagram handle does not look '
          'right: letters, numbers, dots and underscores only, like '
          '@yourspace.');
      return;
    }
    // Room for the page's own text, which the form opens with and
    // which can be longer than the 3,000 this allowed until 7 Oct 2026
    // (an owner could not send in a one-sentence change). The same
    // number is in owner_save_draft (migration 156).
    if (_description.text.length > _descriptionMax) {
      setState(() => _savedNote = 'The description is a little long: '
          '8,000 characters at most.');
      return;
    }
    final url = _mentionUrl.text.trim();
    if (submit && _verified && _mentionTitle.text.trim().isNotEmpty &&
        url.isNotEmpty && !url.startsWith('http')) {
      setState(() => _savedNote =
          'The message link needs to start with https://');
      return;
    }
    setState(() {
      _saving = true;
      _savedNote = null;
    });
    try {
      await _supabase.ownerSaveDraft(v['id'], _collect(), submit: submit);
      _cap(submit ? 'owner_submitted' : 'owner_saved',
          {'space': v['name']});
      await _load();
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _autoSavedAt = DateTime.now();
        _savedNote = submit
            ? 'Sent for review. We read every change before it goes on '
                'the page, usually within a day or two.'
            : 'Draft saved. Nothing changes on the page until you submit.';
      });
    } catch (e) {
      if (mounted) setState(() => _savedNote = 'That did not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addPhotos() async {
    if (_isPreview) {
      setState(() => _savedNote = widget.team
          ? 'Photos are changed from the space in the control centre (Photos).'
          : 'Preview: photos cannot be added here.');
      return;
    }
    if (_photos.length >= 5) {
      setState(() => _savedNote = 'Five photos is the limit for a page.');
      return;
    }
    try {
      final picked = await ImagePicker().pickMultiImage(
          maxWidth: 1600, maxHeight: 1600, imageQuality: 85);
      if (picked.isEmpty) return;
      setState(() => _saving = true);
      for (final x in picked.take(5 - _photos.length)) {
        final bytes = await x.readAsBytes();
        final ext = x.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
        final link = await _supabase.ownerUploadPhoto(bytes, ext);
        _photos.add(link);
      }
      _photosTouched = true;
      _dirty = true;
    } catch (e) {
      _savedNote = 'Could not add the photo: $e';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Swaps the photo in slot [i] for one the owner picks; the others
  /// stay where they are.
  Future<void> _replacePhoto(int i) async {
    if (_isPreview) {
      setState(() => _savedNote = widget.team
          ? 'Photos are changed from the space in the control centre (Photos).'
          : 'Preview: photos cannot be changed here.');
      return;
    }
    try {
      final x = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 85);
      if (x == null) return;
      setState(() => _saving = true);
      final bytes = await x.readAsBytes();
      final ext = x.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
      final link = await _supabase.ownerUploadPhoto(bytes, ext);
      if (i < _photos.length) {
        _photos[i] = link;
      } else {
        _photos.add(link);
      }
      _photosTouched = true;
      _dirty = true;
    } catch (e) {
      _savedNote = 'Could not add the photo: $e';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _removePhoto(int i) => setState(() {
        _photos.removeAt(i);
        _photosTouched = true;
        _dirty = true;
      });

  /// Asks before a photo is taken out (the bin under each photo).
  Future<void> _confirmRemovePhoto(int i) async {
    if (i < 0 || i >= _photos.length) return;
    final p = _photos[i];
    final yes = await _ownerDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(p,
                        width: 120,
                        height: 88,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const SizedBox(width: 120, height: 88)),
                  ),
                  const SizedBox(height: 14),
                  const Text('Remove this photo?',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: _edInk)),
                  const SizedBox(height: 6),
                  const Text(
                      'It comes off your page once you save this change and '
                      'Nomadwise approves it. To use it again later, you '
                      'would need to add it again.',
                      style: TextStyle(
                          fontSize: 14, height: 1.5, color: _edMuted)),
                  const SizedBox(height: 18),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            foregroundColor: _edInk,
                            side: const BorderSide(color: _edBorder),
                          ),
                          child: const Text('Keep photo'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            backgroundColor: _pageRed,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Remove photo'),
                        ),
                      ]),
                  ),
                ]),
          ),
        ),
      ),
    );
    if (yes == true && mounted && i < _photos.length && _photos[i] == p) {
      _removePhoto(i);
    }
  }

  /// Moves a dragged photo from slot [from] to slot [to]; the others
  /// shift along. Slot 0 is the large photo on the page.
  void _movePhoto(int from, int to) => setState(() {
        _photoDropAt = null;
        if (from == to || from < 0 || from >= _photos.length) return;
        final p = _photos.removeAt(from);
        _photos.insert(to.clamp(0, _photos.length), p);
        _photosTouched = true;
        _dirty = true;
      });

  /// Moves the photo in slot [i] to the front: the large one on the page.
  void _makeMainPhoto(int i) => setState(() {
        final p = _photos.removeAt(i);
        _photos.insert(0, p);
        _photosTouched = true;
        _dirty = true;
      });

  // ---------------------------------------------------------------- sign in

  Future<void> _sendLink() async {
    final email = _email.text.trim().toLowerCase();
    if (!email.contains('@') || email.length < 5) {
      setState(() => _error = 'A working email address is needed.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _supabase.sendSignInLink(email);
      if (mounted) setState(() => _linkSent = true);
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            'The link could not be sent just now. Try again in a minute, '
            'or sign in with Google below.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ------------------------------------------------------------------ build

  // Buttons drawn the way nomadwise.io draws them (S3-13/14).
  @override
  Widget build(BuildContext context) {
    _trackChanges();
    return Theme(
        data: siteButtons(Theme.of(context), radius: 8),
        child: _page(context));
  }

  Widget _page(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        titleSpacing: 20,
        // The Nomadwise logo itself (the round mark and "nomadwise.io"),
        // then "for spaces" (Jonathan, 12 Nov 2026: the header was the
        // name typed in red, with no logo). The typed name stays as the
        // fallback if the picture cannot load.
        title: Row(children: [
          Image.asset('assets/brand/logo_full.png',
              height: 30,
              filterQuality: FilterQuality.medium,
              semanticLabel: 'Nomadwise',
              errorBuilder: (_, __, ___) => const Text('nomadwise',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      color: Brand.red))),
          const SizedBox(width: 10),
          const Flexible(
            child: Text('for spaces',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    color: Brand.inkSecondary)),
          ),
        ]),
        actions: [
          if (_supabase.signedIn)
            TextButton(
                onPressed: () async {
                  await _supabase.signOut();
                  if (mounted) {
                    setState(() {
                      _venues = [];
                      _pending = [];
                      _linkSent = false;
                    });
                  }
                },
                child: const Text('Sign out')),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(children: [
        Positioned.fill(child: _pageBody()),
        if (_pop != null && _supabase.signedIn && !_isPreview)
          Positioned.fill(child: LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= _wideAt;
            return Align(
              alignment: wide ? Alignment.bottomRight : Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SafeArea(child: _popCard(wide)),
              ),
            );
          })),
      ]),
    );
  }

  Widget _pageBody() {
    return LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= _wideAt;
        if (_loading) {
          return const Center(
              child: CircularProgressIndicator(color: Brand.red));
        }
        if (!_supabase.signedIn) return _signIn(wide);
        if (_isPreview) {
          if (_previewBase == null) {
            return Center(
                child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error ?? 'Nothing to preview.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Brand.inkSecondary)),
            ));
          }
          return Column(children: [
            _previewBar(),
            Expanded(
                child: _venues.isEmpty
                    ? _pendingView(wide)
                    : _account(wide)),
          ]);
        }
        if (_venues.isEmpty && _pending.isNotEmpty) return _pendingView(wide);
        if (_venues.isEmpty) return _noSpaces(wide);
        return _account(wide);
      });
  }

  Widget _frame(bool wide, Widget child, {double maxWidth = 1100}) =>
      SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(wide ? 28 : 16, wide ? 22 : 12,
            wide ? 28 : 16, 40),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth), child: child),
        ),
      );

  /// A white card. On a phone the padding is 16 so the boxes inside
  /// keep their width; corners are small and crisp everywhere.
  Widget _panel({required Widget child, Color? tint, double? pad}) =>
      Container(
        padding: EdgeInsets.all(pad ??
            (MediaQuery.sizeOf(context).width < _wideAt ? 16 : 22)),
        decoration: BoxDecoration(
          color: tint ?? Brand.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Brand.border),
        ),
        child: child,
      );

  Widget _signIn(bool wide) => _frame(
        wide,
        maxWidth: 520,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: wide ? 60 : 16),
          const Text('FOR COWORKING SPACES AND CAFES',
              style: TextStyle(
                  color: Brand.red,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8)),
          const SizedBox(height: 6),
          Text('Business sign-in',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: wide ? 30 : 24,
                  letterSpacing: -0.5)),
          const SizedBox(height: 8),
          const Text(
              'Manage your listing on Nomadwise: your description, '
              'prices, hours, photos and amenities. Sign in with the email your '
              'space was claimed with; no password.',
              style: TextStyle(
                  color: Brand.inkSecondary, fontSize: 14.5, height: 1.5)),
          const SizedBox(height: 22),
          _panel(
            child: _linkSent
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        const Icon(Icons.mark_email_read_outlined,
                            color: Brand.success, size: 30),
                        const SizedBox(height: 10),
                        const Text('Check your inbox',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16)),
                        const SizedBox(height: 6),
                        Text(
                            'We sent a sign-in link to ${_email.text.trim()}. '
                            'Open it on this device and you are in. It can '
                            'take a minute; check spam if it does not show.',
                            style: const TextStyle(
                                fontSize: 13.5,
                                height: 1.5,
                                color: Brand.inkSecondary)),
                        const SizedBox(height: 12),
                        TextButton(
                            onPressed: () => setState(() => _linkSent = false),
                            child: const Text('Use a different email')),
                      ])
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                              labelText: 'Your email',
                              hintText: 'you@yourspace.com',
                              border: OutlineInputBorder()),
                          onSubmitted: (_) => _sendLink(),
                        ),
                        EmailTypoHint(controller: _email),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(_error!,
                                style: const TextStyle(
                                    color: Brand.red, fontSize: 13)),
                          ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: _sending ? null : _sendLink,
                          style: FilledButton.styleFrom(
                              backgroundColor: Brand.red,
                              minimumSize: const Size.fromHeight(50)),
                          child: Text(
                              _sending ? 'One moment' : 'Email me a sign-in link',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 15)),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () => _supabase.signInWithGoogleTo(
                              AppConfig.ownerAccountUrl +
                                  SupabaseService.ownerReturnChat,
                              loginHint: _email.text.trim()),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(46)),
                          icon: const Icon(Icons.login, size: 18),
                          label: const Text('Continue with Google'),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                            'Google works when your space was claimed with a '
                            'Google address. Otherwise use the email link.',
                            style: TextStyle(
                                color: Brand.inkMuted, fontSize: 12)),
                      ]),
          ),
          const SizedBox(height: 18),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Not claimed your space yet?',
                style: TextStyle(color: Brand.inkMuted, fontSize: 12.5)),
            TextButton(
                onPressed: () => launchUrl(
                    Uri.parse('https://nomadmaps.io/?claim'),
                    webOnlyWindowName: '_self'),
                child: const Text('Claim it for free')),
          ]),
          const Text('Questions: spaces@nomadwise.io',
              style: TextStyle(color: Brand.inkMuted, fontSize: 12.5)),
        ]),
      );

  // ------------------------------------------------------ claim pending

  /// Signed in, claim made, not approved yet: the space, where the
  /// claim stands, and the account laid out but locked, so the owner
  /// sees they are almost there.
  Widget _pendingView(bool wide) {
    final c = _pending.first;
    final name = '${c['name'] ?? 'Your space'}';
    final kind = SupabaseService.spaceKind('${c['type'] ?? ''}');
    final verified = c['plan'] != 'free';
    final paid = c['paid'] == true;
    // Back from Stripe, payment not seen yet: it is being confirmed,
    // not "unfinished".
    final confirming =
        c['status'] == 'started' && verified && _justPaid(c);
    final started = c['status'] == 'started' && !confirming;
    final where = [c['neighbourhood'], c['city']]
        .where((x) => x != null && '$x'.isNotEmpty)
        .join(', ');

    final steps = <(String, _Step)>[
      ('Claimed', _Step.done),
      if (verified)
        (
          confirming ? 'Payment confirming' : 'Paid',
          paid ? _Step.done : confirming ? _Step.now : _Step.todo
        ),
      (
        "We check it's you",
        (started || confirming) && verified ? _Step.todo : _Step.now
      ),
      (verified ? 'Premium is on' : 'Yours to manage', _Step.todo),
    ];

    return _frame(
      wide,
      maxWidth: 1000,
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.storefront_outlined,
              size: 18, color: Brand.inkSecondary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(name,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          ),
          if (where.isNotEmpty) ...[
            const SizedBox(width: 10),
            Flexible(
              child: Text(where,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Brand.inkSecondary, fontSize: 13.5)),
            ),
          ],
        ]),
        const SizedBox(height: 14),
        _panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                started && verified
                    ? "You've started claiming your $kind"
                    : "You've claimed your $kind, you're almost there",
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
            const SizedBox(height: 16),
            _stepsRow(steps, wide),
            const SizedBox(height: 16),
            Text(
                confirming
                    ? 'Your payment is being confirmed with Stripe. This '
                        'page updates by itself as soon as it is; then we '
                        'check you are with the team and Premium goes on.'
                    : started && verified
                    ? 'We have not received a payment yet. If you have just '
                        'paid, it shows here as soon as Stripe confirms it; '
                        'if not, finish your claim below.'
                    : 'We check every claim comes from the business (the '
                        'owner or someone on the team) before handing the '
                        'page over, usually with one quick message to the '
                        "business's own Instagram, WhatsApp or email. We email "
                        'you at ${(c['owner_email'] ?? '').toString().contains('@') ? c['owner_email'] : (_supabase.userEmail ?? 'this address')} as '
                        'soon as that is done, and everything below opens.',
                style: const TextStyle(
                    fontSize: 14, height: 1.55, color: Brand.inkSecondary)),
            if (confirming) ...[
              const SizedBox(height: 12),
              const Row(children: [
                SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Brand.goldTextDark)),
                SizedBox(width: 10),
                Text('Checking with Stripe',
                    style: TextStyle(
                        fontSize: 13, color: Brand.goldTextDark)),
              ]),
            ],
            if (started && verified) ...[
              const SizedBox(height: 14),
              FilledButton(
                  onPressed: () => launchUrl(
                      Uri.parse('https://nomadmaps.io/?claim='
                          '${Uri.encodeQueryComponent(name)}'),
                      webOnlyWindowName: '_self'),
                  style: FilledButton.styleFrom(backgroundColor: Brand.red),
                  child: const Text('Finish my claim')),
            ],
            if (c['page_url'] != null) ...[
              const SizedBox(height: 10),
              TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse('${c['page_url']}')),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('See the page as it is today')),
            ],
          ]),
        ),
        const SizedBox(height: 18),
        _lockedAccount(name, wide),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              onPressed: _load, child: const Text('Check again')),
        ),
      ]),
    );
  }

  Widget _stepsRow(List<(String, _Step)> steps, bool wide) {
    Widget dot(_Step st) => Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: switch (st) {
              _Step.done => Brand.success,
              _Step.now => Brand.goldTint,
              _Step.todo => Brand.field,
            },
            border: st == _Step.now
                ? Border.all(color: Brand.goldTextDark, width: 1.5)
                : null,
          ),
          child: switch (st) {
            _Step.done =>
              const Icon(Icons.check, size: 16, color: Colors.white),
            _Step.now => const Icon(Icons.hourglass_top,
                size: 14, color: Brand.goldTextDark),
            _Step.todo => null,
          },
        );
    final items = [
      for (final (label, st) in steps)
        Row(mainAxisSize: MainAxisSize.min, children: [
          dot(st),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: st == _Step.todo ? FontWeight.w500 : FontWeight.w700,
                  color: st == _Step.todo ? Brand.inkMuted : Brand.ink)),
        ]),
    ];
    return Wrap(
      spacing: wide ? 26 : 16,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }

  /// The account as it will be, blurred and locked.
  Widget _lockedAccount(String name, bool wide) {
    Widget field(String label) => Container(
          height: 44,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Brand.border),
          ),
          child: Text(label,
              style: const TextStyle(color: Brand.inkMuted, fontSize: 13)),
        );
    Widget section(String title, List<String> fields) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 14.5)),
            const SizedBox(height: 8),
            for (final f in fields) field(f),
            const SizedBox(height: 10),
          ],
        );
    final mock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      section('Your listing details', ['What makes your space special?']),
      section('Photos', ['Add your own photos']),
      section('Passes and prices', ['Day pass', 'Week pass', 'Month pass']),
      section('Opening hours', ['Monday', 'Tuesday', 'Wednesday']),
      section('Promotions and events', ['An event or offer for your page']),
    ]);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(children: [
        Container(
          padding: const EdgeInsets.all(22),
          color: Brand.bg,
          child: IgnorePointer(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 3.5, sigmaY: 3.5),
              child: Opacity(opacity: 0.8, child: mock),
            ),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              constraints: const BoxConstraints(maxWidth: 420),
              decoration: BoxDecoration(
                color: Brand.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Brand.border),
                boxShadow: const [
                  BoxShadow(color: Color(0x14000000), blurRadius: 16)
                ],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock_outline, color: Brand.inkSecondary),
                const SizedBox(height: 8),
                Text("Opens as soon as we've confirmed you're with $name",
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14.5)),
                const SizedBox(height: 4),
                const Text(
                    'Your description, photos, prices, hours and your own '
                    'message for the page.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, height: 1.45, color: Brand.inkSecondary)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _noSpaces(bool wide) => _frame(
        wide,
        maxWidth: 520,
        _panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('No space on this account yet',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 8),
            Text(
                'You are signed in as ${_supabase.userEmail ?? ''}. A space '
                'appears here once a claim made with this email has been '
                'approved. If you claimed with a different address, sign '
                'out and use that one. If you have not claimed yet, the '
                'claim form takes two minutes.',
                style: const TextStyle(
                    fontSize: 13.5, height: 1.5, color: Brand.inkSecondary)),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(
                  onPressed: () => launchUrl(
                      Uri.parse('https://nomadmaps.io/?claim'),
                      webOnlyWindowName: '_self'),
                  style: FilledButton.styleFrom(backgroundColor: Brand.red),
                  child: const Text('Claim my space')),
              OutlinedButton(
                  onPressed: _load, child: const Text('Check again')),
            ]),
          ]),
        ),
      );

  // ---------------------------------------------------------------- account

  Widget _account(bool wide) {
    final v = _venue!;
    final nav = _nav(wide);
    // Every tab has the same shape: the main panel on the left, the
    // page preview on the right, so switching tabs never moves the
    // furniture.
    final main = switch (_tab) {
      _Tab.locations => _locationsTab(wide),
      _Tab.listing => _listingTab(wide),
      _Tab.message => _messageTab(wide),
      _Tab.membership => BillingPanel(
          key: ValueKey('bill-${v['id']}-$_verified'),
          venueId: '${v['id']}',
          venueName: '${v['name'] ?? ''}',
          preview: _isPreview,
          tierOverride: _isPreview ? (_verified ? 'verified' : 'free') : null,
          country: '${v['country'] ?? ''}',
          onMessage: () => _goTab(_Tab.chat),
          onGoVerified: () => _saveThenOpen(
              'https://nomadmaps.io/?claim=${Uri.encodeComponent('${v['webflow_slug'] ?? v['name']}')}')),
      _Tab.ideas => IdeasBoard(
          key: ValueKey('ideas-${v['id']}'),
          venueId: '${v['id']}',
          preview: _isPreview),
      _Tab.badges => _badgesTab(),
      _Tab.performance => _performanceTab(wide),
      _Tab.settings => _settingsTab(wide),
      _Tab.chat => _chatTab(wide),
    };
    // (My listing is the page itself: no preview beside it.)
    final fullWidth = _tab == _Tab.ideas ||
        _tab == _Tab.locations ||
        _tab == _Tab.chat ||
        _tab == _Tab.listing ||
        _tab == _Tab.performance ||
        _tab == _Tab.settings;
    final Widget preview = fullWidth
        ? const SizedBox.shrink()
        : _tab == _Tab.message && _verified
            ? _messagePreview()
            : _preview();
    // One quick question now and then, above the page preview (not in
    // a founder's preview: those answers would be ours).
    final side = _isPreview || fullWidth
        ? preview
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            OwnerQuestionCard(
                key: ValueKey('q-${v['id']}'), venueId: '${v['id']}'),
            preview,
          ]);
    final body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_showTip && !_isPreview) _bookmarkTip(),
          if (_wishNews.isNotEmpty && !_isPreview) _wishNewsCard(),
          // My listing saves part by part (Save change); the bar stays
          // for Promotions and events.
          if (_tab == _Tab.message && _verified) _actionBar(wide),
          if (_tab != _Tab.locations) _statusBanner(),
          // Build next is a board of its own, full width; so is the
          // inbox.
          if (fullWidth)
            main
          else if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: main),
              const SizedBox(width: 18),
              Expanded(flex: 2, child: side),
            ])
          else ...[
            main,
            const SizedBox(height: 16),
            side,
          ],
        ]);
    // On a computer the menu is a full-height column down the left
    // edge, as in most members' areas (Jonathan, 3 Nov 2026: the
    // labels were cut off in the narrow card, "this left sidebar
    // should be all on the left side").
    if (wide) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          width: 252,
          decoration: const BoxDecoration(
              color: Brand.surface,
              border: Border(right: BorderSide(color: Brand.border))),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 20, 12, 24),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  nav,
                  if (!_ideasNoteClosed && _tab != _Tab.ideas) ...[
                    const SizedBox(height: 12),
                    _ideasNote(),
                  ],
                ]),
          ),
        ),
        Expanded(
          child: _frame(
            wide,
            maxWidth: 1180,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_tab != _Tab.locations) ...[
                _spaceHeader(v, wide),
                const SizedBox(height: 14),
              ],
              body,
            ]),
          ),
        ),
      ]);
    }
    return _frame(
      wide,
      maxWidth: 1180,
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_tab != _Tab.locations) ...[
          _spaceHeader(v, wide),
          const SizedBox(height: 14),
        ],
        if (wide)
          const SizedBox.shrink()
        else ...[
          nav,
          if (!_ideasNoteClosed && _tab != _Tab.ideas) ...[
            const SizedBox(height: 12),
            _ideasNote(),
          ],
          const SizedBox(height: 14),
          body,
          if (!_isPreview) ...[
            const SizedBox(height: 24),
            Center(child: _lookingLink()),
          ],
        ],
      ]),
    );
  }


  // ------------------------------------------------------------ activity

  String? get _venueId => _venue == null ? null : '${_venue!['id']}';

  /// The PostHog event as before, and a step in Owner activity.
  void _cap(String event, [Map<String, dynamic>? props]) {
    Analytics.capture(event, props);
    _trk.step(event.replaceFirst('owner_', ''), props, _venueId);
  }

  /// Called on every build: notes a new visit, a tab opened, another
  /// location chosen, or a part closed some other way. Nothing for a
  /// founder's preview.
  void _trackChanges() {
    if (_isPreview || _venues.isEmpty || !_supabase.signedIn) return;
    if (!_trk.started) {
      final w = MediaQuery.sizeOf(context).width;
      final q = Uri.base.queryParameters;
      final from = <String>[
        if (q.containsKey('email')) 'email link',
        if (q.containsKey('utm_source')) '${q['utm_source']}',
        if (q.containsKey('utm_campaign')) '${q['utm_campaign']}',
        if (q.containsKey('billing')) 'billing link',
        if (q.containsKey('chat')) 'message link',
      ].join(', ');
      _trk.start(
        device: w < 700 ? 'phone' : (w < 1100 ? 'tablet' : 'computer'),
        width: w.round(),
        cameFrom: from.isEmpty ? 'direct' : from,
        spaces: _venues.length,
        venue: _venueId,
        firstTab: _tab.name,
      );
      _trkTabSeen = _tab;
      _trkCur = _current;
      if (Uri.base.queryParameters.containsKey('ask')) _maybeAsk();
      return;
    }
    if (_tab != _trkTabSeen) {
      _trkTabSeen = _tab;
      _trk.tabChanged(_tab.name, _venueId);
      _maybeAsk();
    }
    if (_current != _trkCur) {
      _trkCur = _current;
      _trk.step('space', {'spaces': _venues.length}, _venueId);
    }
    if (_editing == null && _trk.editing != null) {
      _trk.editEnd('close', _venueId);
    }
  }

  /// "Looking for something?" asks itself only when they seem stuck:
  /// four or more tabs in two minutes without changing anything, or
  /// two parts left without saving. At most once a visit and once in
  /// 14 days (the database decides). ?ask in the link shows it, to try.
  void _maybeAsk() {
    if (_isPreview || _askOpen || _trk.askedThisVisit || _pop != null) return;
    final force = Uri.base.queryParameters.containsKey('ask');
    if (!force && !_trk.askOk) return;
    final why = _trk.gaveUp
        ? 'gave_up'
        : _trk.looksLost
            ? 'lost'
            : force
                ? 'test'
                : null;
    if (why == null) return;
    _trk.askedThisVisit = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _askWish(why);
    });
  }

  Future<void> _askWish(String trigger) async {
    final id = _venueId;
    if (id == null || _askOpen) return;
    _askOpen = true;
    final asked = trigger != 'menu';
    _trk.step(asked ? 'ask_shown' : 'ask_open', {'trigger': trigger}, id);
    if (asked) _trk.flush();
    final text = TextEditingController();
    var stage = 'ask'; // ask, sending, thanks
    String? error;
    final title = trigger == 'gave_up'
        ? 'Anything getting in the way?'
        : 'Looking for something?';
    final lead = trigger == 'gave_up'
        ? "If something didn't work the way you expected, tell us in a "
            'few words.'
        : "Tell us what you'd like to do, in your own words.";
    var sent = false;
    await _ownerDialog<void>(
      context: context,
      barrierColor: Colors.black38,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Future<void> send() async {
          final t = text.text.trim();
          if (t.length < 2) {
            set(() => error = 'Please type a few words.');
            return;
          }
          set(() {
            stage = 'sending';
            error = null;
          });
          try {
            await _supabase.ownerWishSend(id, t, {
              'trigger': trigger,
              'tab': _tab.name,
              'session': _trk.session,
              'trail': _trk.trail(),
            });
            sent = true;
            _trk.step('wish_sent', {'trigger': trigger, 'chars': t.length}, id);
            _trk.flush();
            set(() => stage = 'thanks');
          } catch (e) {
            set(() {
              stage = 'ask';
              error = 'That did not send. Please try again.';
            });
          }
        }

        final thanks = stage == 'thanks';
        return Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(thanks ? 'Thank you, we have it' : title,
                        style: const TextStyle(
                            fontSize: 19, fontWeight: FontWeight.w800, color: Brand.ink)),
                    const SizedBox(height: 8),
                    Text(
                        thanks
                            ? 'We read every message. When it is sorted, '
                                "you'll see it here in your account."
                            : '$lead We read every message, and when it is '
                                "sorted you'll see it here.",
                        style: const TextStyle(
                            fontSize: 14, height: 1.45, color: Brand.inkSecondary)),
                    if (!thanks) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: text,
                        autofocus: true,
                        minLines: 3,
                        maxLines: 6,
                        maxLength: 2000,
                        enabled: stage == 'ask',
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText:
                              'For example: I want to show our holiday opening hours',
                          hintStyle: const TextStyle(color: Brand.inkMuted, fontSize: 14),
                          counterText: '',
                          filled: true,
                          fillColor: Brand.field,
                          contentPadding: const EdgeInsets.all(14),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none),
                        ),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(error!,
                            style: const TextStyle(fontSize: 13, color: _perfRed)),
                      ],
                    ],
                    const SizedBox(height: 18),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: stage == 'sending'
                              ? null
                              : () => Navigator.of(ctx).pop(),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 46),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8))),
                          child: Text(thanks ? 'Close' : 'Not now'),
                        ),
                      ),
                      if (!thanks) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: stage == 'sending' ? null : send,
                            style: FilledButton.styleFrom(
                                backgroundColor: Brand.red,
                                minimumSize: const Size(0, 46),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8))),
                            child: Text(stage == 'sending' ? 'Sending...' : 'Send'),
                          ),
                        ),
                      ],
                    ]),
                  ]),
            ),
          ),
        );
      }),
    );
    _askOpen = false;
    if (!sent) _trk.step('ask_dismissed', {'trigger': trigger}, id);
    text.dispose();
  }

  /// A quiet way in for everyone: under the menu on a computer, at the
  /// foot of the page on a phone.
  Widget _lookingLink() => InkWell(
        onTap: () => _askWish('menu'),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.help_outline, size: 18, color: Brand.inkSecondary),
            const SizedBox(width: 10),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
                Text("Can't find something?",
                    style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
                Text('Tell us what you need',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w700, color: _perfRed)),
              ]),
            ),
          ]),
        ),
      );

  Future<void> _loadWishNews() async {
    if (_isPreview) return;
    try {
      final list = await _supabase.ownerWishNews();
      if (mounted) setState(() => _wishNews = list);
    } catch (_) {} // migration 283 not run yet: nothing to show
  }

  /// Our answer to something they asked for, once each: Planned ("We're
  /// working on this") and Done ("It's here now"), until they close it.
  Widget _wishNewsCard() {
    final w = _wishNews.first;
    final done = '${w['status']}' == 'done';
    var reply = '${w['reply'] ?? ''}'.trim();
    if (!done && reply.isEmpty) {
      reply = "Thanks for telling us. We'll show you here when it's ready.";
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      decoration: BoxDecoration(
        color: done ? Brand.successTint : Brand.goldTint,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: done ? const Color(0x333AA657) : const Color(0x33F4B23E)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(done ? Icons.check_circle_outline : Icons.schedule,
              size: 20, color: done ? Brand.success : Brand.goldTextDark),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                done
                    ? "You asked for this. It's here now."
                    : "We're working on what you asked for.",
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w800, color: Brand.ink)),
            const SizedBox(height: 4),
            Text('"${w['text']}"',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontStyle: FontStyle.italic, color: Brand.inkSecondary, height: 1.4)),
            if (reply.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(reply,
                  style: const TextStyle(fontSize: 14, color: Brand.ink, height: 1.45)),
            ],
          ]),
        ),
        TextButton(
          onPressed: () {
            final id = '${w['id']}';
            _trk.step('wish_news_seen', null, _venueId);
            setState(() => _wishNews = _wishNews.skip(1).toList());
            _supabase.ownerWishSeen(id).catchError((_) {});
          },
          child: const Text('Got it'),
        ),
      ]),
    );
  }

  /// A quiet note from Nomadwise under the menu: what should we build
  /// next? Opens the Build next board; the X puts it away for good on
  /// this device.
  Widget _ideasNote() => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE8EBEF)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.lightbulb_outline, size: 16, color: _edMuted),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'What should we build next for spaces like yours?',
                      style: TextStyle(
                          fontSize: 12.5, height: 1.4, color: _edMuted)),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () => _goTab(_Tab.ideas),
                    child: const Text('Share an idea',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: _pageRed)),
                  ),
                ]),
          ),
          IconButton(
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            onPressed: () {
              setState(() => _ideasNoteClosed = true);
              SharedPreferences.getInstance()
                  .then((p) => p.setBool('owner_ideas_note_closed', true))
                  .catchError((_) => false);
            },
            icon: const Icon(Icons.close, color: _edMuted),
          ),
        ]),
      );

  String _area(Map<String, dynamic> v) => [
        for (final k in ['neighbourhood', 'city'])
          if ('${v[k] ?? ''}'.trim().isNotEmpty) '${v[k]}'.trim()
      ].join(', ');

  /// The space's name as a menu, for every owner (Jonathan, 6 Nov
  /// 2026, option E): their location or locations, a tick on the one
  /// shown, All locations for a group, and Add another location. One
  /// space or ten, adding and switching live in the same spot.
  Widget _spaceMenu(Map<String, dynamic> v, TextStyle nameStyle) {
    final many = _venues.length > 1;
    return PopupMenuButton<int>(
      tooltip: many ? 'Your locations' : 'Your location',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      color: Colors.white,
      surfaceTintColor: Colors.white,
      constraints: const BoxConstraints(minWidth: 300, maxWidth: 400),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onOpened: () => _trk.step('name_menu', null, _venueId),
      onSelected: (i) {
        if (i == -1) {
          _addLocation();
        } else if (i == -2) {
          _loadLocStats();
          _goTab(_Tab.locations);
        } else if (i >= 0 && i < _venues.length) {
          setState(() => _current = i);
          _fillEditor();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<int>(
          enabled: false,
          height: 30,
          child: Text(many ? 'YOUR LOCATIONS' : 'YOUR LOCATION',
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: Brand.inkSecondary)),
        ),
        for (var i = 0; i < _venues.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${_venues[i]['name'] ?? ''}',
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600, color: Brand.ink)),
                      if (_area(_venues[i]).isNotEmpty)
                        Text(_area(_venues[i]),
                            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
                    ]),
              ),
              if (i == _current) ...[
                const SizedBox(width: 10),
                const Icon(Icons.check, size: 18, color: _perfRed),
              ],
            ]),
          ),
        if (many)
          const PopupMenuItem<int>(
            value: -2,
            child: Row(children: [
              Icon(Icons.grid_view_outlined, size: 18, color: Brand.inkSecondary),
              SizedBox(width: 10),
              Text('See all locations',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Brand.ink)),
            ]),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<int>(
          value: -1,
          child: Row(children: [
            Icon(Icons.add, size: 20, color: _perfRed),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Add another location',
                        style: TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w700, color: _perfRed)),
                    Text('Run more than one space? Free, checked within an hour or two.',
                        style: TextStyle(fontSize: 12.5, height: 1.35, color: Brand.inkSecondary)),
                  ]),
            ),
          ]),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _edBorder),
            borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text('${v['name'] ?? ''}',
                overflow: TextOverflow.ellipsis, style: nameStyle),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.keyboard_arrow_down, size: 20, color: Brand.ink),
        ]),
      ),
    );
  }

  Future<void> _loadLocStats() async {
    if (_isPreview && _previewGroup.isEmpty) return;
    try {
      final r = _isPreview
          ? await _supabase.adminOwnerLocations(widget.previewKey!)
          : await _supabase.ownerLocations();
      if (mounted) setState(() => _locStats = r);
    } catch (_) {
      // the rows show without numbers; the next visit tries again
    }
  }

  /// All locations (Jonathan, 6 Nov 2026, option G): the home page for
  /// owners with two or more spaces. One row per location with its plan
  /// and last 30 days, Add a location at the top; a row opens that
  /// location's page.
  Widget _locationsTab(bool wide) {
    String n(Map<String, dynamic>? st, String k) =>
        st == null ? '' : _perfNum(_perfInt(st[k]));
    const label = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Brand.inkSecondary);
    const numStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Brand.ink);
    void open(int i) {
      setState(() => _current = i);
      _fillEditor();
      _goTab(_Tab.listing);
    }

    final addButton = OutlinedButton.icon(
      onPressed: _addLocation,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        foregroundColor: _edInk,
        backgroundColor: Colors.white,
        side: const BorderSide(color: _edBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      icon: const Icon(Icons.add, size: 18, color: _perfRed),
      label: const Text('Add a location', softWrap: false),
    );
    final intro = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Your locations',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Brand.ink)),
      const SizedBox(height: 4),
      Text(
          '${_venues.length} locations. Numbers are for the last 30 days. '
          'Open one to see and change its page.',
          style: const TextStyle(fontSize: 14, height: 1.45, color: Brand.inkSecondary)),
    ]);
    Widget nameBlock(Map<String, dynamic> v) => Row(children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: Brand.accentTint, borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.storefront_outlined, size: 18, color: _perfRed),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${v['name'] ?? ''}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: Brand.ink)),
              if (_area(v).isNotEmpty)
                Text(_area(v),
                    style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
            ]),
          ),
        ]);
    Widget plan(Map<String, dynamic> v) => v['listing_tier'] == 'verified'
        ? _chip('Premium', Brand.success)
        : _chip('Free', Brand.inkSecondary);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (wide)
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: intro),
          const SizedBox(width: 16),
          addButton,
        ])
      else ...[
        intro,
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerLeft, child: addButton),
      ],
      const SizedBox(height: 18),
      Container(
        decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Brand.border),
            borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (wide)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 10),
              child: Row(children: [
                Expanded(child: Text('Location', style: label)),
                SizedBox(width: 90, child: Text('Plan', style: label)),
                SizedBox(width: 110, child: Text('Page views', textAlign: TextAlign.right, style: label)),
                SizedBox(width: 140, child: Text('Shown in Google', textAlign: TextAlign.right, style: label)),
                SizedBox(width: 100, child: Text('Requests', textAlign: TextAlign.right, style: label)),
                SizedBox(width: 36),
              ]),
            ),
          for (var i = 0; i < _venues.length; i++)
            InkWell(
              onTap: () => open(i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                    border: (wide || i > 0)
                        ? const Border(top: BorderSide(color: Color(0xFFECEDF0)))
                        : null),
                child: wide
                    ? Row(children: [
                        Expanded(child: nameBlock(_venues[i])),
                        SizedBox(width: 90, child: Align(alignment: Alignment.centerLeft, child: plan(_venues[i]))),
                        SizedBox(width: 110, child: Text(n(_locStats['${_venues[i]['id']}'], 'views'), textAlign: TextAlign.right, style: numStyle)),
                        SizedBox(width: 140, child: Text(n(_locStats['${_venues[i]['id']}'], 'google'), textAlign: TextAlign.right, style: numStyle)),
                        SizedBox(width: 100, child: Text(n(_locStats['${_venues[i]['id']}'], 'requests'), textAlign: TextAlign.right, style: numStyle)),
                        const SizedBox(
                            width: 36,
                            child: Align(
                                alignment: Alignment.centerRight,
                                child: Icon(Icons.chevron_right, size: 20, color: Brand.inkSecondary))),
                      ])
                    : Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            nameBlock(_venues[i]),
                            const SizedBox(height: 8),
                            Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                              plan(_venues[i]),
                              if (_locStats['${_venues[i]['id']}'] != null)
                                Text(
                                    '${n(_locStats['${_venues[i]['id']}'], 'views')} page views, '
                                    '${n(_locStats['${_venues[i]['id']}'], 'google')} in Google, '
                                    '${n(_locStats['${_venues[i]['id']}'], 'requests')} requests',
                                    style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
                            ]),
                          ]),
                        ),
                        const Icon(Icons.chevron_right, size: 20, color: Brand.inkSecondary),
                      ]),
              ),
            ),
        ]),
      ),
    ]);
  }

  /// The space's name, its plan and "See my page". On a phone the link
  /// goes on its own line under the name, so nothing is cut off; long
  /// names wrap. The link shows only when the page is live, like the
  /// emails (a saved page address alone may be a page in the making).
  Widget _spaceHeader(Map<String, dynamic> v, bool wide) {
    final pageLive = (v['webflow_slug'] ?? '').toString().isNotEmpty &&
        v['website_status'] == 'released';
    const nameStyle = TextStyle(fontWeight: FontWeight.w700, fontSize: 15);
    final Widget name = _spaceMenu(v, nameStyle);
    final title = Row(children: [
      const Icon(Icons.storefront_outlined,
          size: 18, color: Brand.inkSecondary),
      const SizedBox(width: 8),
      Flexible(child: name),
      const SizedBox(width: 8),
      _chip(_verified ? 'Premium' : 'Free',
          _verified ? Brand.success : Brand.inkSecondary),
    ]);
    final Widget? seePage = pageLive
        ? TextButton.icon(
            onPressed: () {
              _trk.step('see_page', null, _venueId);
              _trk.flush();
              launchUrl(
                  Uri.parse(
                      'https://www.nomadwise.io/coworking/${v['webflow_slug']}'),
                  mode: LaunchMode.externalApplication);
            },
            style: wide
                ? null
                : TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 0),
                    minimumSize: const Size(0, 36)),
            icon: const Icon(Icons.open_in_new, size: 15),
            label: const Text('See my page'))
        : null;
    if (wide) {
      return Row(children: [
        Expanded(child: title),
        if (seePage != null) ...[const SizedBox(width: 12), seePage],
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      title,
      if (seePage != null) ...[const SizedBox(height: 4), seePage],
    ]);
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w800, color: color)),
      );

  Widget _nav(bool wide) {
    final items = [
      // Owners with two or more spaces: All locations first (Jonathan,
      // 6 Nov 2026, option G).
      if (_venues.length > 1)
        (_Tab.locations, Icons.grid_view_outlined, 'All locations'),
      (_Tab.listing, Icons.edit_note_outlined, 'My listing'),
      (_Tab.message, Icons.campaign_outlined, 'Promotions and events'),
      (_Tab.membership, Icons.workspace_premium_outlined, 'Plan & billing'),
      // CR-26: the badges for their own website. A placeholder until
      // the designs are agreed with Leonie (Jonathan, 24 Oct).
      (_Tab.badges, Icons.language, 'Website badges'),
      // Jonathan, 5 Nov 2026: Performance in the left menu, Settings
      // under it.
      (_Tab.performance, Icons.insights_outlined, 'Performance'),
      (_Tab.settings, Icons.settings_outlined, 'Settings'),
      (_Tab.chat, Icons.forum_outlined, 'Inbox & support'),
      // Build next is a small note under the menu instead (Jonathan,
      // 24 Oct): see _ideasNote.
    ];
    // The number beside Inbox & support: messages from Nomadwise not
    // opened yet. Nothing when there are none.
    Widget badge(_Tab t) {
      // (not while the inbox itself is open: opening it is reading)
      final n = t == _Tab.chat && _tab != _Tab.chat ? _chatWaitingAll : 0;
      if (n <= 0) return const SizedBox.shrink();
      return Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
            color: Brand.red, borderRadius: BorderRadius.circular(9)),
        child: Text('$n',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800)),
      );
    }

    Widget tile((_Tab, IconData, String) it) {
      final on = _tab == it.$1;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _goTab(it.$1),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
              color: on ? Brand.accentTint : Colors.transparent,
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Icon(it.$2, size: 19, color: on ? Brand.red : Brand.inkSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(it.$3,
                  style: TextStyle(
                      fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                      color: on ? Brand.red : Brand.ink,
                      fontSize: 14)),
            ),
            badge(it.$1),
          ]),
        ),
      );
    }

    if (!wide) {
      // On a phone: one row of tabs with a line under the chosen one,
      // like the apps people use every day, instead of big pills
      // over two rows. Swipes sideways if the screen is narrow.
      return Container(
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Brand.hairline))),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final it in items)
              InkWell(
                onTap: () => _goTab(it.$1),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 9),
                  margin: const EdgeInsets.only(right: 18),
                  decoration: BoxDecoration(
                      border: Border(
                          bottom: BorderSide(
                              color: _tab == it.$1
                                  ? Brand.red
                                  : Colors.transparent,
                              width: 2))),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(it.$2,
                        size: 17,
                        color:
                            _tab == it.$1 ? Brand.red : Brand.inkSecondary),
                    const SizedBox(width: 6),
                    Text(it.$3,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: _tab == it.$1 ? Brand.ink : Brand.inkSecondary)),
                    badge(it.$1),
                  ]),
                ),
              ),
          ]),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...items.map(tile),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                  'Signed in as\n${_supabase.userEmail ?? ''}\n\n'
                  'You stay signed in on this device. Bookmark '
                  'nomadmaps.io/owner to come straight back.',
                  style: const TextStyle(
                      fontSize: 11.5, color: Brand.inkMuted, height: 1.4)),
            ),
            if (_enquiriesOn) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                    'Requests go to\n${_enquiryEmail.text.trim().isNotEmpty ? _enquiryEmail.text.trim() : _signInEmail.isNotEmpty ? _signInEmail : 'the email you sign in with'}',
                    style: const TextStyle(
                        fontSize: 11.5, color: Brand.inkMuted, height: 1.4)),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _saving ? null : _changeEnquiryEmail,
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                  child: const Text('Change'),
                ),
              ),
            ],
            // A quiet second way to add a location (Jonathan, 6 Nov
            // 2026, option F); the first is in the space's name menu.
            const SizedBox(height: 8),
            const Divider(height: 1, color: Brand.hairline),
            const SizedBox(height: 4),
            // Looking for something? (Jonathan, 7 Nov 2026)
            if (!_isPreview) _lookingLink(),
            InkWell(
              onTap: _addLocation,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  const Icon(Icons.add_business_outlined, size: 18, color: Brand.inkSecondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_venues.length > 1 ? 'Another space?' : 'Run another space?',
                          style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
                      const Text('Add a location',
                          style: TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w700, color: _perfRed)),
                    ]),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 6),
          ]),
    );
  }

  // --------------------------------------------------------------- listing

  Widget _statusBanner() {
    final d = _draft;
    if (d == null) return const SizedBox.shrink();
    final status = d['status'];
    final (Color color, IconData icon, String text) = switch (status) {
      'submitted' => (
          Brand.goldTextDark,
          Icons.hourglass_top,
          'Waiting for Nomadwise approval. Your page shows your changes '
              'here; the live page stays as it is until we approve them. '
              'You can keep editing: saving again replaces what we have.'
        ),
      'declined' => (
          Brand.red,
          Icons.undo,
          'We sent your last changes back'
              '${(d['review_note'] ?? '').toString().isNotEmpty ? ': ${d['review_note']}' : '.'}'
              ' Edit the part and press Save change when ready.'
        ),
      'applied' => (
          Brand.success,
          Icons.check_circle_outline,
          'Your last changes are on the page.'
        ),
      _ => (
          Brand.inkSecondary,
          Icons.edit_outlined,
          'You have changes that are not sent yet. Your page shows them '
              'here, but the live page stays as it is until they are sent '
              'and approved.'
        ),
    };
    final unsent = status != 'submitted' &&
        status != 'declined' &&
        status != 'applied';
    // My listing has no Submit button any more: a draft left without
    // Save change can be sent from here. On a phone the button goes
    // under the words, so they keep the full width.
    final send = unsent && _tab == _Tab.listing && _editing == null
        ? FilledButton(
            onPressed: _saving ? null : () => _save(submit: true),
            style: FilledButton.styleFrom(
                backgroundColor: Brand.red, minimumSize: const Size(0, 40)),
            child: Text(
                _saving
                    ? 'Sending'
                    : widget.team
                        ? 'Save to the page'
                        : 'Send my changes',
                softWrap: false))
        : null;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final words = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 10),
      Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 13, height: 1.45, color: color))),
      if (send != null && !narrow) ...[const SizedBox(width: 10), send],
    ]);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(8)),
      child: send != null && narrow
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              words,
              const SizedBox(height: 10),
              Padding(padding: const EdgeInsets.only(left: 28), child: send),
            ])
          : words,
    );
  }

  /// Once, after signing in: signing in is not needed every time.
  Widget _bookmarkTip() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        decoration: BoxDecoration(
          color: Brand.successTint,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          const Icon(Icons.bookmark_add_outlined, color: Brand.success),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
                'You stay signed in on this device, so next time there is no '
                'link to wait for. Bookmark this page (nomadmaps.io/owner), or '
                'on a phone add it to your home screen, to come straight back.',
                style: TextStyle(fontSize: 13, height: 1.45)),
          ),
          TextButton(
              onPressed: () {
                setState(() => _showTip = false);
                SharedPreferences.getInstance()
                    .then((p) => p.setBool('owner_bookmark_tip', true))
                    .catchError((_) => false);
              },
              child: const Text('Got it')),
        ]),
      );

  /// Save draft and Submit for review, at the top where they are easy
  /// to find, with what has happened to the edits so far.
  Widget _actionBar(bool wide) {
    final err = _savedNote != null &&
        (_savedNote!.startsWith('That') ||
            _savedNote!.startsWith('The ') ||
            _savedNote!.startsWith('Could') ||
            _savedNote!.startsWith('Five'));
    final (IconData icon, Color color, String text) = _saving || _autosaving
        ? (Icons.sync, Brand.inkSecondary, 'Saving your draft')
        : err
            ? (Icons.error_outline, Brand.red, _savedNote!)
            : _dirty
                ? (Icons.edit_outlined, Brand.goldTextDark, 'Unsaved changes')
                : _autoSavedAt != null
                    ? (Icons.cloud_done_outlined, Brand.success,
                        'Draft saved. Nothing changes on your page until '
                            'you submit for review.')
                    : (Icons.info_outline, Brand.inkSecondary,
                        'Edits are saved as a draft as you go. Submit for '
                            'review when you are ready.');
    final buttons = Wrap(spacing: 8, runSpacing: 8, children: [
      if (!widget.team)
        OutlinedButton(
            onPressed: _saving ? null : () => _save(submit: false),
            child: const Text('Save draft')),
      FilledButton(
          onPressed: _saving ? null : () => _save(submit: true),
          style: FilledButton.styleFrom(backgroundColor: Brand.red),
          child: Text(_saving
              ? 'One moment'
              : widget.team
                  ? 'Save to the page'
                  : 'Submit for review')),
    ]);
    final status = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 17, color: color),
      const SizedBox(width: 8),
      Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: color))),
    ]);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.border),
      ),
      child: wide
          ? Row(children: [
              Expanded(child: status),
              const SizedBox(width: 12),
              buttons,
            ])
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [status, const SizedBox(height: 8), buttons]),
    );
  }

  InputDecoration _dec(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      isDense: true);

  // ------------------------------------------------ prices, as on the page
  // The Prices part of My listing shows the price list the way the live
  // page draws it (prices.js, migration 243): groups with a photo, the
  // "from" price and a Request on every price; tabs on a phone (Jonathan,
  // 5 Nov 2026: "this prices section should reflect how it looks on
  // live"). The rules below are prices.js's shape(), kept in step.

  int _priceTab = 0;

  static const _lpGroups = [
    ('coworking', 'Coworking'),
    ('private_office', 'Private offices'),
    ('meeting_room', 'Meeting rooms'),
    ('other', 'Other'),
  ];
  static const _lpPer = {
    'hour': '/hr', 'half day': '/half day', 'day': '/day', 'week': '/wk',
    'month': '/mo', 'year': '/yr'
  };
  static const _lpPerLong = {
    'hour': '/hour', 'half day': '/half day', 'day': '/day', 'week': '/week',
    'month': '/month', 'year': '/year'
  };
  static const _lpBy = {
    'hour': 'the hour', 'half day': 'the half day', 'day': 'the day',
    'week': 'the week', 'month': 'the month', 'year': 'the year'
  };

  static String? _lpPeriod(String name, List<String> details, String cat) {
    final n = name.toLowerCase().replaceAll('-', ' ');
    final b = RegExp(r'\((hour|half day|day|week|month|year)\)\s*$').firstMatch(n);
    if (b != null) return b.group(1);
    if (RegExp(r'\b\d+\s*(hour|day|week|month)s?\b').hasMatch(n)) return null;
    if (RegExp(r'\bhalf day\b').hasMatch(n)) return 'half day';
    if (RegExp(r'\bhourly\b|\bper hour\b').hasMatch(n)) return 'hour';
    if (RegExp(r'\bmonth(ly)?\b').hasMatch(n)) return 'month';
    if (RegExp(r'\bweek(ly)?\b').hasMatch(n)) return 'week';
    if (RegExp(r'\byear(ly)?\b|\bannual\b').hasMatch(n)) return 'year';
    if (RegExp(r'\bday pass\b|\bfull day\b|\bdaily\b|\b1 day\b').hasMatch(n)) return 'day';
    final d = details.join(' | ').toLowerCase();
    if (RegExp(r'\b(price )?per hour\b|\ban hour\b').hasMatch(d)) return 'hour';
    if (RegExp(r'\b(price )?per month\b|\ba month\b|^monthly\b|\| monthly\b').hasMatch(d)) return 'month';
    if (RegExp(r'\b(price )?per week\b|\ba week\b').hasMatch(d)) return 'week';
    if (RegExp(r'\b(price )?per day\b').hasMatch(d)) return 'day';
    if (cat == 'meeting_room') return 'hour';
    if (cat == 'private_office') return 'month';
    return null;
  }

  /// The groups the page shows: (title, spec, from word, price, per,
  /// items); each item (name, note, price text).
  List<(String, String, bool, String, String, List<(String, String, String)>)>
      _lpShape() {
    final byCat = <String, List<Map<String, dynamic>>>{};
    for (final raw in (_venue?['page_products'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final p = Map<String, dynamic>.from(raw);
      final cat0 = '${p['category'] ?? ''}';
      final cat = _lpGroups.any((g) => g.$1 == cat0) ? cat0 : 'other';
      final details = [
        for (final x in (p['details'] is List ? p['details'] as List : const []))
          if ('$x'.trim().isNotEmpty) '$x'.trim()
      ];
      final rawName = '${p['name'] ?? ''}';
      final period = _lpPeriod(rawName, details, cat);
      var name = rawName
          .replaceAll(RegExp(r'\s*\((hour|half day|day|week|month|year)\)\s*$', caseSensitive: false), '')
          .trim();
      if (cat == 'meeting_room' && RegExp(r'^meeting room\s+\S', caseSensitive: false).hasMatch(name)) {
        name = name.replaceFirst(RegExp(r'^meeting room\s+', caseSensitive: false), '');
      }
      final amount = p['amount'] is num ? (p['amount'] as num).toDouble() : double.tryParse('${p['amount'] ?? ''}');
      final label = '${p['label'] ?? ''}'.trim().isNotEmpty
          ? '${p['label']}'.trim()
          : amount == null
              ? 'Price on request'
              : Price.format('${amount % 1 == 0 ? amount.toInt() : amount}', '${p['currency'] ?? _currency}').trim();
      var from = false;
      final notes = <String>[];
      for (final d in details) {
        final l = d.toLowerCase();
        if (RegExp(r'^(per|a|an) (hour|day|week|month|year)$|^monthly$|^daily$|^hourly$').hasMatch(l)) continue;
        if (RegExp(r'\bvat\b').hasMatch(l) && d.length < 30) continue;
        if (RegExp(r'^from\b').hasMatch(l) && l.contains(label.toLowerCase())) {
          from = true;
          continue;
        }
        notes.add(d);
      }
      (byCat[cat] ??= []).add({
        'name': name.isEmpty ? (rawName.isEmpty ? 'Price' : rawName) : name,
        'note': notes.take(2).join(' · '),
        'amount': amount,
        'currency': '${p['currency'] ?? ''}',
        'label': label,
        'period': period,
        'from': from,
        'text': '${from ? 'from ' : ''}$label${period != null && amount != null ? ' ${_lpPer[period]}' : ''}',
      });
    }
    final out = <(String, String, bool, String, String, List<(String, String, String)>)>[];
    for (final (key, title) in _lpGroups) {
      final items = byCat[key];
      if (items == null || items.isEmpty) continue;
      final priced = items.where((i) => i['amount'] != null).toList();
      final oneCur = priced.every((i) => i['currency'] == (priced.isEmpty ? null : priced.first['currency']));
      Map<String, dynamic>? low;
      if (priced.isNotEmpty) {
        low = oneCur
            ? (priced.toList()..sort((a, b) => (a['amount'] as double).compareTo(b['amount'] as double))).first
            : priced.first;
      }
      final periods = <String>[];
      for (final i in items) {
        final pr = i['period'] as String?;
        if (pr != null && !periods.contains(pr)) periods.add(pr);
      }
      final caps = <int>[];
      for (final i in items) {
        final c = RegExp(r'up to (\d+)', caseSensitive: false).firstMatch('${i['note']}');
        if (c != null && !caps.contains(int.parse(c.group(1)!))) caps.add(int.parse(c.group(1)!));
      }
      var spec = caps.length > 1
          ? '${caps.reduce((a, b) => a < b ? a : b)} to ${caps.reduce((a, b) => a > b ? a : b)} people'
          : '${items.length} ${items.length == 1 ? 'option' : 'options'}';
      if (periods.isNotEmpty) {
        spec += ' · by ${periods.map((x) => _lpBy[x]).join(' or ').replaceAll(' or the ', ' or ')}';
      }
      out.add((
        title,
        spec,
        low != null && (items.length > 1 || low['from'] == true),
        low != null ? '${low['label']}' : 'Ask',
        low != null && low['period'] != null ? _lpPerLong[low['period']]! : '',
        [for (final i in items) ('${i['name']}', '${i['note']}', '${i['text']}')],
      ));
    }
    return out;
  }

  /// The price list as the live page draws it, or null when the space
  /// has no prices on the page yet.
  Widget? _livePrices(List<String> photos) {
    final groups = _lpShape();
    if (groups.isEmpty) return null;
    const line = Color(0x1F142032);
    const soft = Color(0xFFF5F6F8);
    const muted = Color(0xFF5E6670);
    String? photoFor(int gi) =>
        photos.isEmpty ? null : photos[(gi + 1) % photos.length];
    Widget request() => Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _pageRed, width: 1.5)),
          child: const Text('Request',
              style: TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFFD42F3A))),
        );
    Widget img(String? url, double w, double h) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: url == null
              ? Container(width: w, height: h, color: const Color(0xFFE6E9ED))
              : Image.network(url,
                  width: w,
                  height: h,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      Container(width: w, height: h, color: const Color(0xFFE6E9ED))),
        );
    Widget row((String, String, String) it, {bool phone = false}) => Container(
          padding: EdgeInsets.symmetric(vertical: phone ? 10 : 9),
          decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0x0D000000)))),
          child: Row(children: [
            Expanded(
              child: phone
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(it.$1,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w700, color: _pageInk)),
                      if (it.$2.isNotEmpty)
                        Text(it.$2, style: const TextStyle(fontSize: 13, color: muted)),
                    ])
                  : Text.rich(TextSpan(children: [
                      TextSpan(
                          text: it.$1,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (it.$2.isNotEmpty)
                        TextSpan(
                            text: '  · ${it.$2}',
                            style: const TextStyle(fontSize: 13, color: muted)),
                    ]), style: const TextStyle(fontSize: 14.5, height: 1.35, color: _pageInk)),
            ),
            const SizedBox(width: 12),
            Text(it.$3,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w700, color: _pageInk)),
            const SizedBox(width: 12),
            request(),
          ]),
        );
    final space = '${_venue?['name'] ?? 'this space'}';
    return LayoutBuilder(builder: (context, box) {
      final phone = box.maxWidth < 560;
      Widget list;
      if (!phone) {
        list = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var gi = 0; gi < groups.length; gi++)
            Container(
              decoration: BoxDecoration(
                  border: gi == 0 ? null : const Border(top: BorderSide(color: line))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(
                  color: soft,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(children: [
                    img(photoFor(gi), 88, 66),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(groups[gi].$1,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700, color: _pageInk)),
                        const SizedBox(height: 2),
                        Text(groups[gi].$2,
                            style: const TextStyle(fontSize: 13, color: muted)),
                      ]),
                    ),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      if (groups[gi].$3)
                        const Text('FROM',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: .8,
                                color: muted)),
                      Text.rich(TextSpan(children: [
                        TextSpan(
                            text: groups[gi].$4,
                            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                        TextSpan(
                            text: groups[gi].$5,
                            style: const TextStyle(fontSize: 13, color: muted)),
                      ]), style: const TextStyle(color: _pageInk)),
                    ]),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(children: [for (final it in groups[gi].$6) row(it)]),
                ),
              ]),
            ),
        ]);
      } else {
        final gi = _priceTab.clamp(0, groups.length - 1);
        list = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (groups.length > 1)
            Container(
              color: soft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (var i = 0; i < groups.length; i++)
                    InkWell(
                      onTap: () => setState(() => _priceTab = i),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 56),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: i == gi ? Colors.white : Colors.transparent,
                          border: Border(
                              bottom: BorderSide(
                                  color: i == gi ? _pageRed : Colors.transparent, width: 3)),
                        ),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(groups[i].$1,
                                  style: const TextStyle(
                                      fontSize: 14.5, fontWeight: FontWeight.w700, color: _pageInk)),
                              Text(
                                  '${groups[i].$3 ? 'from ' : ''}${groups[i].$4}'
                                  '${groups[i].$5.replaceAll('/month', '/mo').replaceAll('/hour', '/hr')}',
                                  style: const TextStyle(fontSize: 12.5, color: muted)),
                            ]),
                      ),
                    ),
                ]),
              ),
            ),
          if (photoFor(gi) != null)
            AspectRatio(
              aspectRatio: 16 / 10,
              child: Image.network(photoFor(gi)!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(color: const Color(0xFFE6E9ED))),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
            child: Column(children: [for (final it in groups[gi].$6) row(it, phone: true)]),
          ),
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Prices set by $space. Sending a request is free and there\'s no obligation.',
            style: const TextStyle(fontSize: 14, height: 1.45, color: muted)),
        const SizedBox(height: 14),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: line)),
          child: list,
        ),
      ]);
    });
  }

  static const _priceKinds = [
    ('coworking', 'Coworking passes'),
    ('meeting_room', 'Meeting rooms'),
    ('private_office', 'Private offices'),
    ('other', 'Other'),
  ];

  /// One tap adds these, already in the right group (Jonathan, 24 Oct:
  /// choosing a type for every price was too much work).
  static const _pricePresets = [
    ('Day pass', 'coworking'),
    ('Week pass', 'coworking'),
    ('Month pass', 'coworking'),
    ('Hot desk', 'coworking'),
    ('Dedicated desk', 'coworking'),
    ('Meeting room', 'meeting_room'),
    ('Private office', 'private_office'),
    ('Monitor rental', 'other'),
    ('Locker', 'other'),
    ('Virtual office', 'other'),
  ];

  /// The group a price belongs in, from its name, for one the owner
  /// names themselves.
  static String _guessPriceType(String name) {
    final n = name.toLowerCase();
    if (RegExp(r'virtual|locker|monitor|parking|mail|print|storage|podcast|'
            r'studio|event|kitchen|gym|shower')
        .hasMatch(n)) {
      return 'other';
    }
    if (RegExp(r'meeting|conference|board ?room|training room').hasMatch(n)) {
      return 'meeting_room';
    }
    if (RegExp(r'office|suite|cabin|team room').hasMatch(n)) {
      return 'private_office';
    }
    return 'coworking';
  }

  /// Adds a price (a preset, or an empty one to name) and puts the
  /// cursor where the next thing to type is.
  void _addPriceRow({String name = '', String? type}) {
    if (_priceRows.length >= 40) return;
    final r = _PriceRow(
        name: name,
        category: type ?? 'coworking',
        autoType: type == null,
        per: perFromName(name));
    setState(() {
      _priceRows.add(r);
      _dirty = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (name.isEmpty ? r.nameFocus : r.priceFocus).requestFocus();
    });
  }

  /// The prices on the page, with what the editor needs (migration
  /// 218 adds the id, amount and the rest).
  List<Map<String, dynamic>> get _pageProductRows => [
        for (final p in (_venue?['page_products'] as List? ?? const []))
          if (p is Map && '${p['name'] ?? ''}'.trim().isNotEmpty)
            Map<String, dynamic>.from(p)
      ];

  /// Fills the price list from the page; with none there yet, from a
  /// day, week or month pass the owner typed before (those boxes are
  /// gone: the list replaces them).
  void _loadPriceRows() {
    for (final r in _priceRows) {
      r.dispose();
    }
    _priceRows.clear();
    final page = _pageProductRows;
    for (final p in page) {
      final amt = p['amount'];
      final details = [for (final x in (p['details'] as List? ?? const [])) '$x'];
      _priceRows.add(_PriceRow(
        id: (p['id'] ?? '').toString().isEmpty ? null : '${p['id']}',
        category: '${p['category'] ?? 'coworking'}',
        from: p['starting_from'] == true,
        per: perOf(details) ?? perFromName('${p['name']}'),
        name: '${p['name']}',
        amount: amt == null ? '' : Price.cleanAmount('$amt'),
        note: withoutPer(details).join(' '),
      ));
      final cur = '${p['currency'] ?? ''}'.trim().toUpperCase();
      if (cur.length == 3) _currency = cur;
    }
    if (page.isEmpty && _venue?['type'] != 'cafe') {
      for (final (c, label) in [
        (_priceDay, 'Day pass'),
        (_priceWeek, 'Week pass'),
        (_priceMonth, 'Month pass'),
      ]) {
        if (c.text.trim().isNotEmpty) {
          _priceRows.add(_PriceRow(
              name: label, amount: c.text.trim(), per: perFromName(label)));
        }
      }
    }
    // The list replaces the three boxes, so they are not sent as well.
    _priceDay.clear();
    _priceWeek.clear();
    _priceMonth.clear();
  }

  /// The description has a price list in it: a currency sign or code
  /// right by a number, at least twice (OUR HQ's: "hot desks £89,
  /// dedicated desks £99").
  bool get _descriptionHasPrices {
    final t = _description.text;
    final codes = currencyNames.keys.join('|');
    final re = RegExp(
        '([£€\$¥₹฿₩₱₫₺]\\s?\\d)'
        '|(\\d\\s?[£€₹฿])'
        '|(\\b($codes)\\s?\\d)|(\\d\\s?($codes)\\b)');
    return re.allMatches(t).length >= 2;
  }

  /// The description as plain text for the paste box (no "## ").
  String get _descriptionPlain => _description.text
      .replaceAll(RegExp(r'^\s*#{1,6}\s+', multiLine: true), '')
      .trim();

  /// A database message without the technical wrapping.
  static String _plainError(Object e) {
    final s = '$e';
    final m = RegExp(r'message: (.*?), code:').firstMatch(s);
    return (m?.group(1) ?? s).replaceFirst('Exception: ', '');
  }

  /// "Turn into prices": the pasted list goes to Claude (migration
  /// 242); the answer is read every two seconds for up to a minute and
  /// a half, then fills the list.
  Future<void> _readPastedPrices() async {
    final text = _pasteText.text.trim();
    if (text.length < 3) {
      setState(() => _pasteError = 'Paste your price list into the box first.');
      return;
    }
    final seq = ++_pasteSeq;
    setState(() {
      _pasteBusy = true;
      _pasteError = null;
      _pasteDone = null;
    });
    bool stale() => !mounted || seq != _pasteSeq || _editing != 'prices';
    try {
      final id =
          await _supabase.ownerPriceRead('${_venue?['id']}', text, _currency);
      for (var i = 0; i < 45; i++) {
        await Future.delayed(const Duration(seconds: 2));
        if (stale()) return;
        Map<String, dynamic> a;
        try {
          a = await _supabase.ownerPriceReadAnswer(id);
        } catch (_) {
          continue; // a blip in the connection: ask again
        }
        if (stale()) return;
        final status = '${a['status'] ?? ''}';
        if (status == 'waiting') continue;
        if (status == 'done') {
          _fillFromPaste(a);
        } else {
          setState(() {
            _pasteBusy = false;
            _pasteError =
                '${a['error'] ?? 'Something went wrong. Please try again.'}';
          });
        }
        return;
      }
      if (stale()) return;
      setState(() {
        _pasteBusy = false;
        _pasteError = 'No answer after a minute and a half. Please try again.';
      });
    } catch (e) {
      if (stale()) return;
      setState(() {
        _pasteBusy = false;
        _pasteError = _plainError(e);
      });
    }
  }

  /// Puts the prices Claude read into the list. A price with the same
  /// name as one already there updates it; the rest are added (up to
  /// the 40 the list holds). Empty rows go first.
  void _fillFromPaste(Map<String, dynamic> a) {
    final found = [
      for (final p in (a['prices'] as List? ?? const []))
        if (p is Map) Map<String, dynamic>.from(p)
    ];
    if (found.isEmpty) {
      setState(() {
        _pasteBusy = false;
        _pasteError = 'We could not find any prices in that text. Check it '
            'has the amounts in it, or add the prices below.';
      });
      return;
    }
    final blank = _priceRows.where((r) => r.isBlank).toList();
    var added = 0, updated = 0, full = 0;
    setState(() {
      for (final r in blank) {
        _priceRows.remove(r);
      }
      // Matched by name against the prices there before this paste
      // only, so two of the same name in the pasted list both stay.
      final before = _priceRows.toList();
      for (final p in found) {
        final name = '${p['name'] ?? ''}'.trim();
        if (name.length < 2) continue;
        final amount = '${p['amount'] ?? ''}'.trim();
        final from = p['from'] == true;
        var note = '${p['note'] ?? ''}'.trim();
        if (note.length > 120) note = note.substring(0, 120).trim();
        final cat = '${p['category'] ?? 'coworking'}';
        final same = before
            .where((r) =>
                r.name.text.trim().toLowerCase() == name.toLowerCase())
            .firstOrNull;
        if (same != null) {
          if (amount.isNotEmpty) same.amount.text = Price.cleanAmount(amount);
          same.from = from;
          if (note.isNotEmpty && same.note.text.trim().isEmpty) {
            same.note.text = note;
          }
          updated++;
          continue;
        }
        if (_priceRows.length >= 40) {
          full++;
          continue;
        }
        _priceRows.add(_PriceRow(
          category: cat,
          from: from,
          name: name,
          amount: amount.isEmpty ? '' : Price.cleanAmount(amount),
          note: note,
        ));
        added++;
      }
      final cur = '${a['currency'] ?? ''}'.trim().toUpperCase();
      final curChanged = cur.length == 3 &&
          cur != _currency &&
          currencyNames.containsKey(cur);
      if (curChanged) _currency = cur;
      final parts = [
        if (added > 0) 'added ${added == 1 ? '1 price' : '$added prices'}',
        if (updated > 0)
          'updated ${updated == 1 ? '1 price' : '$updated prices'} you had already',
      ];
      if (parts.isEmpty) {
        _pasteBusy = false;
        _pasteError = full > 0
            ? 'Your list already has 40 prices, the most it holds. Remove '
                'some below, then try again.'
            : 'We could not find any prices in that text. Check it has the '
                'amounts in it, or add the prices below.';
        return;
      }
      final said = parts.join(' and ');
      _pasteDone = '${said[0].toUpperCase()}${said.substring(1)} from your '
          'list${curChanged ? ', in ${Price.name(cur)}' : ''}. Please check '
          'each one below and change anything that is not right, then press '
          'Save.'
          '${full > 0 ? ' $full more did not fit: the list holds 40 prices.' : ''}'
          '${'${a['note'] ?? ''}'.trim().isEmpty ? '' : ' Note: ${'${a['note']}'.trim()}'}';
      _pasteBusy = false;
      _pasteOpen = false;
      _pasteText.clear();
      _dirty = true;
      _editSeq++;
      _lastEdit = DateTime.now();
    });
    // The empty rows' boxes are still on screen in this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final r in blank) {
        r.dispose();
      }
    });
  }

  /// The "paste your price list" card at the top of the price editor.
  Widget _pasteCard() {
    final hasDesc = _descriptionHasPrices;
    final done = _pasteDone;
    if (!_pasteOpen) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (done != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFEAF6EE),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFB9DFC5)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.check_circle,
                  size: 20, color: Color(0xFF2E7D4F)),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(done,
                      style: const TextStyle(
                          fontSize: 14, height: 1.45, color: _edInk))),
            ]),
          ),
        OutlinedButton.icon(
          onPressed: _saving
              ? null
              : () => setState(() {
                    _pasteOpen = true;
                    _pasteError = null;
                    _pasteDone = null;
                  }),
          icon: const Icon(Icons.content_paste, size: 18),
          label: const Text('Paste your price list'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _edInk,
            side: const BorderSide(color: _edBorder),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ]);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _edBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Paste your price list',
            style: TextStyle(
                fontSize: 15.5, fontWeight: FontWeight.w700, color: _edInk)),
        const SizedBox(height: 4),
        const Text(
            'Copy your prices from your website, a brochure or anywhere '
            'else, and paste them here. We turn them into separate prices '
            'for you to check before you save.',
            style: TextStyle(fontSize: 13.5, height: 1.45, color: _edMuted)),
        if (hasDesc) ...[
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: _pasteBusy
                ? null
                : () => setState(() {
                      _pasteText.text = _descriptionPlain;
                      _pasteError = null;
                    }),
            icon: const Icon(Icons.subdirectory_arrow_right, size: 18),
            label: const Text('Use the prices in my description'),
            style: TextButton.styleFrom(
                foregroundColor: _pageRed,
                padding: const EdgeInsets.symmetric(horizontal: 4)),
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: _pasteText,
          enabled: !_pasteBusy,
          minLines: 5,
          maxLines: 12,
          maxLength: 6000,
          buildCounter: _nearLimit,
          keyboardType: TextInputType.multiline,
          decoration: _dec('Your price list',
              hint: 'Day pass 18\nHot desk 89 a month\nMeeting room from 15 an hour'),
        ),
        if (_pasteError != null) ...[
          const SizedBox(height: 6),
          Text(_pasteError!,
              style: const TextStyle(
                  fontSize: 13.5, color: Color(0xFFB3261E), height: 1.4)),
        ],
        const SizedBox(height: 10),
        Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _pasteBusy || _saving ? null : _readPastedPrices,
                icon: _pasteBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.auto_awesome, size: 18),
                label: Text(_pasteBusy
                    ? 'Reading your prices...'
                    : 'Turn into prices'),
                style: FilledButton.styleFrom(
                  backgroundColor: _pageRed,
                  disabledBackgroundColor: _pageRed.withValues(alpha: 0.6),
                  disabledForegroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _pasteSeq++; // drops an answer still on its way
                  _pasteOpen = false;
                  _pasteBusy = false;
                  _pasteError = null;
                }),
                child: const Text('Close',
                    style: TextStyle(color: _edMuted)),
              ),
            ]),
      ]),
    );
  }

  /// Asks before a price that is on the page now is taken out.
  Future<void> _removePriceRow(_PriceRow r) async {
    if (r.id != null) {
      final yes = await _ownerDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove this price?'),
          content: DialogBody(child: Text(
              '"${r.name.text.trim()}" comes off your page once you save '
              'and Nomadwise approves the change.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Keep it')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(backgroundColor: _pageRed),
                child: const Text('Remove price')),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    setState(() {
      _priceRows.remove(r);
      _dirty = true;
    });
    // Its boxes are still on screen in this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => r.dispose());
  }

  /// One price in the editor, on one line where there is room: the
  /// name, the price, "from", and a menu (add a note, move to another
  /// group, remove). The group comes from where the price sits.
  Widget _priceRowEditor(_PriceRow r, double maxW) {
    final narrow = maxW < 520;
    final name = Focus(
      onFocusChange: (on) {
        // A price the owner named: filed by its name until moved.
        if (!on && r.autoType && r.name.text.trim().isNotEmpty) {
          final t = _guessPriceType(r.name.text);
          if (t != r.category) setState(() => r.category = t);
        }
        // "Day pass" is per day: filled in when not chosen yet.
        if (!on && r.per == null) {
          final p = perFromName(r.name.text);
          if (p != null) setState(() => r.per = p);
        }
      },
      child: TextField(
          controller: r.name,
          focusNode: r.nameFocus,
          // So a preset typed by hand leaves the quick-add list.
          onChanged: (_) => setState(() {}),
          maxLength: 80,
          buildCounter: _nearLimit,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.next,
          decoration: _dec('Name', hint: 'Day pass')),
    );
    final amount = SizedBox(
      width: narrow ? 150 : 170,
      child: Focus(
        onFocusChange: (on) {
          if (!on) {
            final clean = Price.cleanAmount(r.amount.text);
            if (clean != r.amount.text) r.amount.text = clean;
          }
        },
        child: TextField(
          controller: r.amount,
          focusNode: r.priceFocus,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,kK ]')),
          ],
          decoration: _dec('Price', hint: 'Amount').copyWith(
              prefixText: Price.prefixFor(_currency),
              suffixText: Price.suffixFor(_currency)),
        ),
      ),
    );
    // Per what (Jonathan, 9 Nov 2026: a hot desk at 90,000 did not say
    // per day or per month, and we had to ask).
    final perBox = Container(
      height: 48,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: r.per == null && r.amount.text.trim().isNotEmpty
                ? Brand.gold
                : const Color(0x33142032)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: r.per,
          hint: const Text('Per…', style: TextStyle(fontSize: 14, color: _edMuted)),
          icon: const Icon(Icons.expand_more, size: 20, color: _edMuted),
          borderRadius: BorderRadius.circular(8),
          style: const TextStyle(fontSize: 14, color: _edInk),
          items: [
            for (final p in pricePers)
              DropdownMenuItem<String?>(value: p.$1, child: Text(p.$2.toLowerCase())),
          ],
          onChanged: _saving
              ? null
              : (x) => setState(() {
                    r.per = x;
                    _dirty = true;
                  }),
        ),
      ),
    );
    final from = Tooltip(
      message: 'Shows as "from" this price',
      child: InkWell(
        onTap: () => setState(() {
          r.from = !r.from;
          _dirty = true;
        }),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(
                value: r.from,
                visualDensity: VisualDensity.compact,
                onChanged: (x) => setState(() {
                      r.from = x == true;
                      _dirty = true;
                    })),
            const Text('From', style: TextStyle(fontSize: 14, color: _edInk)),
          ]),
        ),
      ),
    );
    final menu = PopupMenuButton<String>(
      tooltip: 'More',
      enabled: !_saving,
      icon: const Icon(Icons.more_vert, size: 20, color: _edMuted),
      onSelected: (x) {
        if (x == 'note') {
          setState(() => r.showNote = true);
          WidgetsBinding.instance
              .addPostFrameCallback((_) => r.noteFocus.requestFocus());
        } else if (x == 'remove') {
          _removePriceRow(r);
        } else if (x.startsWith('move:')) {
          setState(() {
            r.category = x.substring(5);
            r.autoType = false;
            _dirty = true;
          });
        }
      },
      itemBuilder: (_) => [
        if (!r.showNote && r.note.text.trim().isEmpty)
          const PopupMenuItem(value: 'note', child: Text('Add a note')),
        for (final (k, label) in _priceKinds)
          if (k != r.category)
            PopupMenuItem(value: 'move:$k', child: Text('Move to $label')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'remove', child: Text('Remove this price')),
      ],
    );
    final showNote = r.showNote || r.note.text.trim().isNotEmpty;
    return Padding(
      key: ObjectKey(r),
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (narrow) ...[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: name),
            menu,
          ]),
          Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [amount, perBox, from]),
        ] else
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: name),
            const SizedBox(width: 10),
            amount,
            const SizedBox(width: 8),
            perBox,
            const SizedBox(width: 4),
            Padding(padding: const EdgeInsets.only(top: 4), child: from),
            Padding(padding: const EdgeInsets.only(top: 4), child: menu),
          ]),
        if (showNote)
          Padding(
            padding: EdgeInsets.only(top: 8, right: narrow ? 48 : 0),
            child: TextField(
                controller: r.note,
                focusNode: r.noteFocus,
                maxLength: 120,
                buildCounter: _nearLimit,
                decoration: _dec('Note (optional)',
                    hint: 'Per hour, up to 6 people')),
          ),
      ]),
    );
  }

  /// One price box: the amount only, with the currency shown beside it.
  Widget _priceField(TextEditingController c, String label,
          {double width = 200}) =>
      SizedBox(
        width: width,
        // One way of writing numbers: "1.000" and "1,000" both become
        // 1,000, and "3,60" becomes 3.60, when the owner leaves the box
        // (S3-7).
        child: Focus(
          onFocusChange: (on) {
            if (!on) {
              final clean = Price.cleanAmount(c.text);
              if (clean != c.text) c.text = clean;
            }
          },
          child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,kK ]')),
            // No "1,,2" or "33....3": a second dot or comma in a row is
            // simply not typed.
            TextInputFormatter.withFunction((old, now) =>
                RegExp(r'[.,]\s*[.,]').hasMatch(now.text) ? old : now),
          ],
          decoration: _dec(label, hint: 'Amount').copyWith(
              prefixText: Price.prefixFor(_currency),
              suffixText: Price.suffixFor(_currency)),
          ),
        ),
      );

  /// One currency for every price, as a dropdown you can type into
  /// ("rupee", "LKR"), the space's own currency first (S3-6).
  Widget _currencyPicker() {
    final home = Price.forCountry('${_venue?['country'] ?? ''}');
    final codes = currencyNames.keys.toList()..sort();
    if (home != null && codes.remove(home)) codes.insert(0, home);
    if (!codes.contains(_currency)) codes.insert(0, _currency);
    return DropdownMenu<String>(
      key: ValueKey('cur-${_venue?['id']}-$_currency'),
      initialSelection: _currency,
      width: 320,
      label: const Text('Currency'),
      enableFilter: true,
      requestFocusOnTap: true,
      menuHeight: 320,
      leadingIcon: const Icon(Icons.payments_outlined, size: 18),
      dropdownMenuEntries: [
        for (final c in codes)
          DropdownMenuEntry(value: c, label: '$c  ·  ${Price.name(c)}'),
      ],
      onSelected: (c) {
        if (c == null || c == _currency) return;
        setState(() {
          _currency = c;
          _dirty = true;
          _editSeq++;
          _lastEdit = DateTime.now();
        });
      },
    );
  }

  /// The description as an opening paragraph plus headed sections the
  /// owner adds, instead of typing "##" (S3-5).
  Widget _descriptionEditor({bool heading = true}) {
    final total = _description.text.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (heading) ...[
        const Text('About your space',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
      ],
      const Text(
          'What makes it special: the workspace, the atmosphere, the people. '
          'Plain words work best. The more detail you add, the easier it is '
          'for people to find you through search engines and AI assistants. '
          'Add sections if it helps: choose a heading like Location or Desk '
          'Setup, or write your own.',
          style: TextStyle(color: Brand.inkMuted, fontSize: 12, height: 1.4)),
      const SizedBox(height: 10),
      for (var i = 0; i < _sections.length; i++)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: i == 0 ? EdgeInsets.zero : const EdgeInsets.all(12),
          decoration: i == 0
              ? null
              : BoxDecoration(
                  color: Brand.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Brand.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (i > 0) ...[
              Row(children: [
                Expanded(
                  // Pick a heading from the list (the arrow) or type
                  // your own.
                  child: TextField(
                    controller: _sections[i].$1,
                    focusNode: _focusNewHeading && i == _sections.length - 1
                        ? _newHeadingFocus
                        : null,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                    decoration: _dec('Section heading',
                            hint: 'Choose one or type your own')
                        .copyWith(
                      suffixIcon: PopupMenuButton<String>(
                        tooltip: 'Choose a heading',
                        icon: const Icon(Icons.arrow_drop_down),
                        onSelected: (h) => _sections[i].$1.text = h,
                        itemBuilder: (_) => [
                          for (final h in _sectionHeadings)
                            PopupMenuItem(value: h, child: Text(h)),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                    tooltip: 'Remove this section',
                    onPressed: () => _removeSection(i),
                    icon: const Icon(Icons.delete_outline,
                        color: Brand.inkMuted)),
              ]),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _sections[i].$2,
              minLines: i == 0 ? 4 : 3,
              maxLines: 12,
              decoration: _dec(i == 0 ? 'Opening text' : 'Text for this section',
                  hint: i == 0
                      ? 'A few lines on what it is like to work here.'
                      : null),
            ),
          ]),
        ),
      // The count sits under the text, on its own line, so the button
      // keeps the full width on a phone.
      Align(
        alignment: Alignment.centerRight,
        child: Text('$total of 8,000 characters',
            style: TextStyle(
                fontSize: 12,
                color: total > _descriptionMax ? Brand.red : Brand.inkMuted)),
      ),
      const SizedBox(height: 10),
      // Add a section: pick its heading from the list, or "My own
      // heading" to type one.
      Align(
        alignment: Alignment.centerLeft,
        child: PopupMenuButton<String>(
          tooltip: 'Add a section',
          onSelected: (h) => _addSection(h == _ownHeading ? '' : h),
          itemBuilder: (_) {
            final used = {
              for (final (h, _) in _sections) h.text.trim().toLowerCase()
            };
            return [
              for (final h in _sectionHeadings)
                if (!used.contains(h.toLowerCase()))
                  PopupMenuItem(value: h, child: Text(h)),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  value: _ownHeading,
                  child: Row(children: [
                    Icon(Icons.edit_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('My own heading'),
                  ])),
            ];
          },
          child: IgnorePointer(
            child: ExcludeFocus(
              child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add a section')),
            ),
          ),
        ),
      ),
    ]);
  }

  // ---- opening hours: picked, never typed (S3-8) ----
  static final List<String> _times = [
    for (var m = 0; m < 24 * 60; m += 30) _clock(m),
  ];

  static String _clock(int minutes) {
    final h24 = (minutes ~/ 60) % 24;
    final m = minutes % 60;
    final h = h24 % 12 == 0 ? 12 : h24 % 12;
    return '$h:${m.toString().padLeft(2, '0')} ${h24 < 12 ? 'AM' : 'PM'}';
  }

  static final _range = RegExp(
      r'^\s*(\d{1,2}):(\d{2})\s*([AaPp][Mm])\s*[-–]\s*(\d{1,2}):(\d{2})\s*([AaPp][Mm])\s*$');

  static String _tidy(String h, String m, String ap) =>
      '${int.parse(h)}:$m ${ap.toUpperCase()}';

  /// What a day's stored text means: 'unset', 'closed', '24h', 'open'
  /// (with from and to), or 'custom' (split hours and the like, kept
  /// exactly as written).
  (String, String, String) _dayState(String text) {
    final t = text.trim();
    if (t.isEmpty) return ('unset', '', '');
    if (t.toLowerCase() == 'closed') return ('closed', '', '');
    if (t.toLowerCase().contains('24 hours')) return ('24h', '', '');
    final m = _range.firstMatch(t);
    if (m != null) {
      return (
        'open',
        _tidy(m.group(1)!, m.group(2)!, m.group(3)!),
        _tidy(m.group(4)!, m.group(5)!, m.group(6)!)
      );
    }
    return ('custom', t, '');
  }

  Widget _timeBox(String value, ValueChanged<String> onPick) {
    final options = [..._times];
    if (!options.contains(value)) options.insert(0, value);
    return DropdownButton<String>(
      value: value,
      isDense: true,
      underline: const SizedBox.shrink(),
      menuMaxHeight: 320,
      items: [
        for (final t in options)
          DropdownMenuItem(
              value: t, child: Text(t, style: const TextStyle(fontSize: 14))),
      ],
      onChanged: (t) {
        if (t != null) onPick(t);
      },
    );
  }

  Widget _dayHours(String day) {
    final c = _hours[day]!;
    final (state, from, to) = _dayState(c.text);
    Widget box(Widget child) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Brand.border),
          ),
          child: child,
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 6,
          children: [
            SizedBox(
                width: 96,
                child: Text(_dayNames[day]!,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14))),
            box(DropdownButton<String>(
              value: state,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: 'unset', child: Text('Not set')),
                const DropdownMenuItem(value: 'open', child: Text('Open')),
                const DropdownMenuItem(value: 'closed', child: Text('Closed')),
                const DropdownMenuItem(
                    value: '24h', child: Text('Open 24 hours')),
                if (state == 'custom')
                  DropdownMenuItem(
                      value: 'custom',
                      child: Text(from, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) {
                c.text = switch (v) {
                  'open' => '9:00 AM - 6:00 PM',
                  'closed' => 'Closed',
                  '24h' => 'Open 24 hours',
                  'custom' => c.text,
                  _ => '',
                };
              },
            )),
            if (state == 'open') ...[
              box(_timeBox(from, (t) => c.text = '$t - $to')),
              const Text('to', style: TextStyle(color: Brand.inkSecondary)),
              box(_timeBox(to, (t) => c.text = '$from - $t')),
            ],
          ]),
    );
  }

  void _copyMondayHours() {
    final mon = _hours['mon']!.text;
    for (final d in _days) {
      if (d != 'mon') _hours[d]!.text = mon;
    }
  }

  // ------------------------------------------------- edit on the page
  // CR-22, 23 Oct 2026 (Leonie's idea, mockup approved): My listing is
  // the page as travellers see it, with an Edit button on each part.
  // Edit opens that part's form in place (a red frame); Save change
  // sends the listing to Nomadwise for review; Cancel puts the part
  // back as it was. Nothing on the live page changes until approved.

  /// The part being edited ('photos', 'tags', 'about', 'prices',
  /// 'hours', 'links'), and what it held when Edit was pressed.
  String? _editing;
  Map<String, dynamic>? _snap;

  /// Parts sent for review in this visit: they show "Waiting for
  /// Nomadwise approval" until the page reloads with the change.
  final Set<String> _sentParts = {}; // '<space id>:<part>'

  bool _sent(String part) => _sentParts.contains('${_venue?['id']}:$part');

  Map<String, dynamic> _snapshot(String part) => switch (part) {
        'photos' => {'list': List<String>.of(_photos), 'touched': _photosTouched},
        'tags' => {'facts': Map<String, bool?>.of(_facts)},
        'about' => {'text': _description.text},
        'prices' || 'coffee' => {
            'day': _priceDay.text,
            'week': _priceWeek.text,
            'month': _priceMonth.text,
            'coffee': _priceCoffee.text,
            'currency': _currency,
          },
        'hours' => {for (final d in _days) d: _hours[d]!.text},
        'links' => {
            'web': _website.text,
            'ig': _instagram.text,
            'wa': _whatsapp.text,
            'wac': _waCountry.value,
          },
        'enquiries' => {'enq': _enquiryEmail.text},
        _ => const {},
      };

  void _restore(String part, Map<String, dynamic> s) {
    switch (part) {
      case 'photos':
        _photos = List<String>.from(s['list'] as List);
        _photosTouched = s['touched'] == true;
      case 'tags':
        _facts
          ..clear()
          ..addAll(Map<String, bool?>.from(s['facts'] as Map));
      case 'about':
        _description.text = '${s['text']}';
        _loadSections();
      case 'prices' || 'coffee':
        _priceDay.text = '${s['day']}';
        _priceWeek.text = '${s['week']}';
        _priceMonth.text = '${s['month']}';
        _priceCoffee.text = '${s['coffee']}';
        _currency = '${s['currency']}';
      case 'hours':
        for (final d in _days) {
          _hours[d]!.text = '${s[d]}';
        }
      case 'links':
        _website.text = '${s['web']}';
        _instagram.text = '${s['ig']}';
        _whatsapp.text = '${s['wa']}';
        _waCountry.value = s['wac'] as String?;
      case 'enquiries':
        _enquiryEmail.text = '${s['enq']}';
    }
  }

  /// Edit pressed: another open part is put back first (one at a time).
  void _startEdit(String part) {
    if (_editing != null && _editing != part) {
      _trk.editEnd('close', _venueId); // moved on, not given up
      _cancelEdit();
    }
    // The snapshot first: Cancel puts back the old boxes the list
    // empties.
    final snap = _snapshot(part);
    if (part == 'prices') {
      _loadPriceRows();
      // A paste still being read from an earlier visit is dropped.
      _pasteSeq++;
      _pasteOpen = false;
      _pasteBusy = false;
      _pasteError = null;
      _pasteDone = null;
    }
    setState(() {
      _snap = snap;
      _editing = part;
      _savedNote = null;
    });
    _trk.editStart(part, _venueId);
    // On a phone the form can open partly off screen: bring its top
    // into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _partKeys[part]?.currentContext;
      if (c != null && mounted) {
        Scrollable.ensureVisible(c,
            duration: Motion.of(context, const Duration(milliseconds: 220)),
            curve: Curves.easeOut,
            alignment: 0.02,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
      }
    });
  }

  final _partKeys = <String, GlobalKey>{};
  Widget _keyed(String part, Widget child) => KeyedSubtree(
      key: _partKeys.putIfAbsent(part, () => GlobalKey()), child: child);

  void _cancelEdit() {
    final part = _editing;
    final s = _snap;
    _trk.editEnd('cancel', _venueId);
    _maybeAsk();
    if (part != null && s != null) _restore(part, s);
    setState(() {
      _editing = null;
      _snap = null;
      _savedNote = null;
      _dirty = true;
      _editSeq++;
      _lastEdit = DateTime.now();
    });
  }

  /// Save change: the listing goes to Nomadwise for review (the same
  /// as Submit for review). The part closes once it has gone.
  Future<void> _saveEdit() async {
    final part = _editing;
    if (part == null) return;
    final enq = _enquiryEmail.text.trim();
    if (part == 'enquiries' &&
        enq.isNotEmpty &&
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(enq)) {
      setState(() => _savedNote = 'Please check the email address.');
      return;
    }
    if (part == 'prices' && _pasteBusy) {
      setState(() => _savedNote =
          'Please wait until your price list has been read, then save.');
      return;
    }
    if (part == 'prices' && !_isPreview && !_saving) {
      // The price list goes to the founders' Price check, one change
      // per price (migration 218); the rest of the listing as before.
      final rows = [
        for (final r in _priceRows)
          if (!r.isBlank) r.toJson()
      ];
      final missing = _priceRows
          .where((r) => !r.isBlank && r.name.text.trim().length < 2)
          .length;
      if (missing > 0) {
        setState(() => _savedNote = 'Please give every price a name.');
        return;
      }
      setState(() => _saving = true);
      try {
        final res = await _supabase.ownerProposeProducts(
            '${_venue?['id']}', rows, _currency);
        final problems = (res['problems'] as List? ?? const []);
        if (problems.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _saving = false;
            _savedNote = 'Please check: ${problems.map((p) => '${(p as Map)['name']}: ${p['why']}').join('; ')}.';
          });
          return;
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _savedNote = 'Could not send your prices: $e';
        });
        return;
      }
      if (!mounted) return;
      setState(() => _saving = false);
    }
    await _save(submit: true);
    if (!mounted) return;
    final sent = (_savedNote ?? '').startsWith('Sent') ||
        (_savedNote ?? '').startsWith('Saved to the page') ||
        (_savedNote ?? '').startsWith('Preview');
    if (sent) {
      _trk.editEnd('save', _venueId);
      setState(() {
        _sentParts.add('${_venue?['id']}:$part');
        _editing = null;
        _snap = null;
      });
    }
  }

  static const _edBorder = Color(0xFFCBD2D9);
  static const _edInk = Color(0xFF142032);
  static const _edMuted = Color(0xFF5C6773);
  static const _edRed = Color(0xFFD92D38);

  /// Enquiries reach the space by email (a Premium page, or a free page
  /// with its free enquiries on).
  bool get _enquiriesOn => _verified || _allow?['on'] == true;

  String get _signInEmail => (_isPreview
          ? (_venue?['listing_owner_email'] ?? _venue?['claim_email'] ?? '')
          : (_supabase.userEmail ?? ''))
      .toString();

  /// Change where enquiries are sent, in a small window: the page
  /// itself stays as nomads see it (Jonathan, 24 Oct).
  Future<void> _changeEnquiryEmail() async {
    // Saving sends the whole listing: a part half edited would go too.
    if (_editing != null) {
      setState(() => _savedNote =
          'Please save or cancel the part you are editing first.');
      return;
    }
    final c = TextEditingController(text: _enquiryEmail.text.trim());
    final signIn = _signInEmail;
    final picked = await _ownerDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final t = c.text.trim();
        final bad = t.isNotEmpty &&
            !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t);
        return AlertDialog(
          title: const Text('Where requests go'),
          content: SizedBox(
            width: 420,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'Every request a nomad sends from your page is emailed '
                      'to this address. Use the inbox your team checks most.',
                      style: TextStyle(
                          fontSize: 14, height: 1.45, color: _edMuted)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: c,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    onChanged: (_) => setD(() {}),
                    decoration: _dec('Email for requests',
                            hint: 'hello@yourspace.com')
                        .copyWith(
                            errorText: bad
                                ? 'This does not look like an email address'
                                : null,
                            helperText: signIn.isEmpty
                                ? 'Leave it empty to use the email you sign '
                                    'in with.'
                                : 'Leave it empty to use the email you sign '
                                    'in with ($signIn).',
                            helperMaxLines: 3),
                  ),
                  EmailTypoHint(controller: c, onUse: () => setD(() {})),
                  const SizedBox(height: 10),
                  const Text(
                      'Nomadwise approves the change first; until then '
                      'requests keep going where they go now.',
                      style: TextStyle(fontSize: 12.5, color: _edMuted)),
                ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: bad ? null : () => Navigator.of(ctx).pop(t),
                style: FilledButton.styleFrom(backgroundColor: _pageRed),
                child: const Text('Send for approval')),
          ],
        );
      }),
    );
    // The window is still closing for a few frames.
    Future.delayed(const Duration(milliseconds: 400), c.dispose);
    if (picked == null || !mounted) return;
    if (picked == _enquiryEmail.text.trim()) return;
    final before = _enquiryEmail.text;
    _enquiryEmail.text = picked;
    await _save(submit: true);
    if (!mounted) return;
    final sent = (_savedNote ?? '').startsWith('Sent') ||
        (_savedNote ?? '').startsWith('Saved to the page') ||
        (_savedNote ?? '').startsWith('Preview');
    setState(() {
      if (sent) {
        _sentParts.add('${_venue?['id']}:enquiries');
      } else {
        _enquiryEmail.text = before;
      }
    });
  }

  // ------------------------------------------------ temporarily closed
  // CR-36 (migration 250): the owner says the space is closed for a
  // while by picking the day it opens again. It goes on the page at
  // once, without review, and the page goes back to normal by itself
  // on that day. Google's own "temporarily closed" is separate.

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];
  static const _weekdayNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday'
  ];
  String _longDay(DateTime d) =>
      '${_weekdayNames[d.weekday - 1]} ${d.day} ${_monthNames[d.month - 1]} ${d.year}';

  DateTime? get _reopensOn {
    final raw = '${_venue?['reopens_on'] ?? ''}';
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> _pickReopenDay() async {
    if (_isPreview && !widget.team) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Preview: nothing is saved. For the owner this '
              'would mark the page temporarily closed straight away.')));
      return;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final first = today.add(const Duration(days: 1));
    final last = today.add(const Duration(days: 365));
    var initial = _reopensOn ?? today.add(const Duration(days: 7));
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: 'WHEN DO YOU OPEN AGAIN?',
      confirmText: 'Save',
    );
    if (picked == null || !mounted) return;
    await _setReopenDay(picked);
  }

  Future<void> _setReopenDay(DateTime? day) async {
    final v = _venue;
    if (v == null) return;
    if (_isPreview && !widget.team) return;
    setState(() => _closedBusy = true);
    try {
      await _supabase.ownerSetClosed('${v['id']}', day);
      if (!mounted) return;
      String two(int n) => n.toString().padLeft(2, '0');
      // Only this part changes, so nothing being edited elsewhere is lost.
      setState(() {
        _venues[_current.clamp(0, _venues.length - 1)] = {
          ...v,
          'reopens_on': day == null
              ? null
              : '${day.year}-${two(day.month)}-${two(day.day)}',
        };
      });
      _cap(day == null ? 'owner_reopened' : 'owner_closed_until',
          {'space': v['name']});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(day == null
              ? 'Done. Your page no longer says you are closed.'
              : 'Done. Your page now says you are temporarily closed and '
                  'open again on ${_longDay(day)}.')));
    } catch (e) {
      if (!mounted) return;
      final msg = '$e'.replaceFirst(RegExp(r'^.*?message: '), '');
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('That did not save: $msg')));
    } finally {
      if (mounted) setState(() => _closedBusy = false);
    }
  }

  Widget _closedPart() {
    if (_venue == null) return const SizedBox.shrink();
    final until = _reopensOn;
    if (until == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _closedBusy ? null : _pickReopenDay,
          style: TextButton.styleFrom(
              foregroundColor: Brand.inkSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
          icon: const Icon(Icons.event_busy_outlined, size: 18),
          label: const Text('Closing for a while? Mark as temporarily closed',
              style: TextStyle(fontSize: 13.5)),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
          color: const Color(0xFFFFF6E5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFF3D28B))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.schedule, size: 18, color: Color(0xFFB26B00)),
          SizedBox(width: 8),
          Text('Temporarily closed',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: Color(0xFF3A2700))),
        ]),
        const SizedBox(height: 6),
        Text(
            'Your page says you open again on ${_longDay(until)}. It goes '
            'back to normal by itself on that day.',
            style: const TextStyle(
                fontSize: 13.5, height: 1.45, color: Color(0xFF4A3200))),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [
          OutlinedButton(
              onPressed: _closedBusy ? null : _pickReopenDay,
              child: const Text('Change the day')),
          TextButton(
              onPressed: _closedBusy ? null : () => _setReopenDay(null),
              style: TextButton.styleFrom(foregroundColor: Brand.red),
              child: const Text('We are open again')),
        ]),
      ]),
    );
  }

  /// Where the page's enquiries are sent, with Change: at the top of
  /// Inbox & support, not on the page (the live page does not show it).
  Widget _enquiriesCard() {
    final set = _enquiryEmail.text.trim();
    final shown = set.isNotEmpty ? set : _signInEmail;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8EBEF)),
      ),
      child: Row(children: [
        const Icon(Icons.mail_outline, size: 20, color: _edMuted),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Requests from your page are emailed to',
                style: TextStyle(fontSize: 12.5, color: _edMuted)),
            const SizedBox(height: 2),
            Text(shown.isEmpty ? 'the email you sign in with' : shown,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600, color: _edInk)),
            if (_sent('enquiries'))
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Your change is waiting for Nomadwise approval.',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFF8A5A00))),
              ),
          ]),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: _saving ? null : _changeEnquiryEmail,
          child: const Text('Change',
              style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }

  /// The Edit button: 40px tall, its words never wrap.
  Widget _editButton(String part, {String label = 'Edit'}) => OutlinedButton.icon(
        onPressed: () => _startEdit(part),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          foregroundColor: _edInk,
          backgroundColor: Colors.white,
          side: const BorderSide(color: _edBorder),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        icon: const Icon(Icons.edit_outlined, size: 15),
        label: Text(label, softWrap: false),
      );

  /// "Test your Wi-Fi", in the same style as Edit: the speed is
  /// measured at the space, not typed (Jonathan, 6 Nov 2026; before,
  /// owners sent us a number). The name and the location are asked
  /// for in Settings (Jonathan, 5 Nov).
  Widget _requestButton() => OutlinedButton.icon(
        onPressed: _wifiTest,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          foregroundColor: _edInk,
          backgroundColor: Colors.white,
          side: const BorderSide(color: _edBorder),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        icon: const Icon(Icons.wifi, size: 15),
        label: const Text('Test your Wi-Fi', softWrap: false),
      );

  /// A short message to Nomadwise about one thing we check: the Wi-Fi
  /// speed (from My listing and Performance), or the name or location
  /// (from Settings). One thing per window, no choice to make (Jonathan,
  /// 5 Nov 2026). It arrives in Inbox & support like any other message.
  Future<void> _requestChange([String kind = 'wifi']) async {
    final v = _venue;
    if (v == null) return;
    // title, intro, field label, example, name in the message to us
    final (title, intro, label, hint, what) = switch (kind) {
      'name' => (
          'Change your name',
          'Your name on Nomadwise is checked by us before it changes on '
              'your page. Tell us the new name and we will look at it.',
          'New name',
          'For example: our name is now Sunrise Coworking.',
          'Name'
        ),
      'location' => (
          'Change your location',
          'Your address and pin on the map are checked by us before they '
              'change on your page. Tell us where you are now.',
          'New address',
          'For example: we moved to Jalan Pantai 12, two streets further '
              'down.',
          'Location'
        ),
      _ => (
          'Update your Wi-Fi speed',
          'The Wi-Fi speed on your page is checked by Nomadwise. Tell us '
              'your speed and we will update it.',
          'Your Wi-Fi speed',
          'For example: 300 Mbps since we upgraded in October.',
          'Wi-Fi speed'
        ),
    };
    final note = TextEditingController();
    var sending = false;
    String? error;
    final sent = await _ownerDialog<bool>(
      context: context,
      // Closed only with Cancel or after sending, so a send in progress
      // always finishes inside the dialog.
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => PopScope(
          canPop: !sending,
          child: AlertDialog(
          scrollable: true,
          title: Text(title),
          content: SizedBox(
            width: 440,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(intro,
                      style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.45,
                          color: Brand.inkSecondary)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: note,
                    autofocus: true,
                    minLines: 3,
                    maxLines: 6,
                    maxLength: 1000,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: label,
                      hintText: hint,
                      hintMaxLines: 3,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(error!,
                          style: const TextStyle(
                              fontSize: 13, color: Brand.red)),
                    ),
                  const SizedBox(height: 6),
                  const Text(
                      'This sends a message to Nomadwise in Inbox & '
                      'support. Your page stays as it is until we change '
                      'it.',
                      style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
                ]),
          ),
          actions: [
            TextButton(
                onPressed: sending ? null : () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _edRed),
              onPressed: sending
                  ? null
                  : () async {
                      final text = note.text.trim();
                      if (text.length < 3) {
                        setD(() => error = 'Write what should change.');
                        return;
                      }
                      if (_isPreview) {
                        Navigator.pop(ctx, true);
                        return;
                      }
                      setD(() {
                        sending = true;
                        error = null;
                      });
                      try {
                        await _supabase.ownerChatSend(
                            '${v['id']}', 'Change request ($what): $text');
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (_) {
                        if (!ctx.mounted) return;
                        setD(() {
                          sending = false;
                          error = 'That did not send. Please try again.';
                        });
                      }
                    },
              child: Text(sending ? 'Sending' : 'Send to Nomadwise',
                  softWrap: false),
            ),
          ],
        ),
        ),
      ),
    );
    // After the closing animation, so the field is gone first.
    Future.delayed(const Duration(milliseconds: 400), note.dispose);
    if (sent == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_isPreview
              ? 'Preview: the owner\'s request goes to Inbox & support.'
              : 'Sent. We will reply in Inbox & support.')));
    }
  }

  /// Test your Wi-Fi (Jonathan, 6 Nov 2026; migration 262). The owner
  /// stands in the space on its Wi-Fi: the app finds where the device
  /// is, measures the speed itself (nothing to type), and the database
  /// checks the test was done within 250 m of the space's pin. Only
  /// such a test can go on the page. Owners who cannot test there send
  /// a Speedtest result link instead, which the team checks by hand.
  Future<void> _wifiTest() async {
    final v = _venue;
    if (v == null) return;
    final space = (v['name'] ?? 'your space').toString();
    var stage = 'intro'; // intro, testing, result, link
    var progress = 0.0;
    var phase = '';
    Map<String, dynamic>? result;
    String? error;
    var busy = false;
    var open = true;
    int? applied;
    var linkSent = false;
    final link = TextEditingController();

    String away(num m) => m < 1000
        ? '${m.round()} m'
        : '${(m / 1000).toStringAsFixed(1)} km';

    String why(Map<String, dynamic> r) {
      final d = r['distance_m'] as num?;
      return switch (r['verdict']) {
        'too_far' =>
          'This test was done about ${d == null ? 'far' : away(d)} from '
              '$space\'s pin on the map, so it cannot go on your page. '
              'Run it again at the space.',
        'no_location' =>
          'We could not see where this test was done. Allow location for '
              'nomadmaps.io when your browser asks, then try again.',
        'rough_location' =>
          'This device could only tell roughly where it is. Try again on '
              'your phone, which knows its location better.',
        'no_pin' =>
          'Your space has no pin on our map yet, so we cannot check where '
              'the test was done. Send us a Speedtest result instead.',
        'mobile_data' =>
          'This test ran on mobile data, not your Wi-Fi. Connect to your '
              'Wi-Fi and try again.',
        _ => 'This test cannot go on your page. Please try again.',
      };
    }

    Future<void> run(StateSetter setD) async {
      void upd(VoidCallback f) {
        if (open) setD(f);
      }

      upd(() => error = null);
      // Mobile data? Android phones can tell us; iPhones cannot, which
      // is why the location check matters.
      var conn = 'unknown';
      try {
        final c = await Connectivity().checkConnectivity();
        if (c.contains(ConnectivityResult.wifi)) {
          conn = 'wifi';
        } else if (c.contains(ConnectivityResult.mobile)) {
          conn = 'cellular';
        }
      } catch (_) {}
      if (conn == 'cellular') {
        upd(() => error = 'This device is on mobile data. Connect to your '
            'space\'s Wi-Fi and try again.');
        return;
      }
      upd(() {
        stage = 'testing';
        busy = true;
        progress = 0;
        phase = 'Finding where you are';
      });
      final pos = _isPreview ? null : await LocationService.current();
      upd(() => phase = 'Measuring your Wi-Fi');
      final mbps = _isPreview
          ? 312.0
          : await SpeedTestService.measureMbpsParallel(
              onProgress: (p) => upd(() => progress = p));
      if (mbps == null) {
        upd(() {
          busy = false;
          stage = 'intro';
          error = 'The test could not finish. Check the Wi-Fi and try '
              'again.';
        });
        return;
      }
      upd(() {
        phase = 'Checking';
        progress = 1;
      });
      try {
        final r = _isPreview
            ? <String, dynamic>{
                'verdict': 'at_space',
                'mbps': 312,
                'distance_m': 40,
              }
            : await _supabase.ownerWifiTest('${v['id']}', mbps,
                lat: pos?.latitude,
                lng: pos?.longitude,
                accuracy: pos?.accuracy,
                connection: conn);
        _cap('owner_wifi_test',
            {'verdict': r['verdict'], 'mbps': r['mbps']});
        upd(() {
          busy = false;
          result = r;
          stage = 'result';
        });
      } catch (e) {
        upd(() {
          busy = false;
          stage = 'intro';
          error = _friendly(e);
        });
      }
    }

    Future<void> apply(BuildContext ctx, StateSetter setD) async {
      final r = result;
      if (r == null) return;
      setD(() {
        busy = true;
        error = null;
      });
      try {
        final mb = _isPreview
            ? (r['mbps'] as num).toInt()
            : ((await _supabase.ownerWifiTestApply('${r['id']}'))['mbps']
                    as num)
                .toInt();
        applied = mb;
        if (ctx.mounted) Navigator.pop(ctx);
      } catch (e) {
        if (open) {
          setD(() {
            busy = false;
            error = _friendly(e);
          });
        }
      }
    }

    Future<void> sendLink(BuildContext ctx, StateSetter setD) async {
      final t = link.text.trim();
      if (!RegExp(r'(speedtest\.net|ookla\.com)/', caseSensitive: false)
          .hasMatch(t)) {
        setD(() => error = 'Paste the result link from Speedtest. It starts '
            'with https://www.speedtest.net/result/');
        return;
      }
      setD(() {
        busy = true;
        error = null;
      });
      try {
        if (!_isPreview) {
          await _supabase.ownerChatSend('${v['id']}',
              'Change request (Wi-Fi speed): Speedtest result $t');
        }
        linkSent = true;
        if (ctx.mounted) Navigator.pop(ctx);
      } catch (_) {
        if (open) {
          setD(() {
            busy = false;
            error = 'That did not send. Please try again.';
          });
        }
      }
    }

    const muted = TextStyle(fontSize: 13.5, height: 1.45, color: Brand.inkSecondary);
    Widget step(String n, String text) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: const Color(0xFFFFF0F1),
                  borderRadius: BorderRadius.circular(11)),
              child: Text(n,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: _edRed)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 14, height: 1.45))),
          ]),
        );
    Widget errorLine() => error == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(error!,
                style: const TextStyle(fontSize: 13, height: 1.4, color: Brand.red)),
          );
    final redButton = FilledButton.styleFrom(
        backgroundColor: _edRed,
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)));
    final plainButton = OutlinedButton.styleFrom(
        foregroundColor: _edInk,
        minimumSize: const Size(0, 44),
        side: const BorderSide(color: _edBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)));

    await _ownerDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final r = result;
        final ok = r?['verdict'] == 'at_space';
        final Widget body;
        final List<Widget> buttons;
        switch (stage) {
          case 'testing':
            body = Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                    value: progress <= 0 ? null : progress,
                    minHeight: 8,
                    color: _edRed,
                    backgroundColor: const Color(0xFFFFE3E5)),
              ),
              const SizedBox(height: 12),
              Text(phase, style: muted),
              const SizedBox(height: 4),
              const Text('Keep this window open.',
                  style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
            ]);
            buttons = const [];
          case 'result':
            body = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${r?['mbps']} Mbps',
                      style: const TextStyle(
                          fontSize: 40, fontWeight: FontWeight.w800, height: 1.1)),
                  const SizedBox(height: 10),
                  if (ok)
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.check_circle, size: 18, color: Color(0xFF1E7A46)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            'Tested at $space'
                            '${r?['distance_m'] == null ? '' : ', ${away(r!['distance_m'] as num)} from your pin'}. '
                            'It can go on your page now.',
                            style: muted),
                      ),
                    ])
                  else
                    Text(why(r ?? const {}), style: muted),
                  errorLine(),
                ]);
            buttons = ok
                ? [
                    OutlinedButton(
                        style: plainButton,
                        onPressed: busy ? null : () => Navigator.pop(ctx),
                        child: const Text('Not now')),
                    FilledButton(
                        style: redButton,
                        onPressed: busy ? null : () => apply(ctx, setD),
                        child: Text(busy ? 'Saving' : 'Put it on my page',
                            softWrap: false)),
                  ]
                : [
                    OutlinedButton(
                        style: plainButton,
                        onPressed: () => setD(() {
                              stage = 'link';
                              error = null;
                            }),
                        child: const Text('Send a link', softWrap: false)),
                    FilledButton(
                        style: redButton,
                        onPressed: () => run(setD),
                        child: const Text('Try again', softWrap: false)),
                  ];
          case 'link':
            body = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'At your space, on your Wi-Fi, open speedtest.net and '
                      'press Go. When it finishes, press Share and copy the '
                      'result link. We check it and update your page.',
                      style: muted),
                  const SizedBox(height: 14),
                  TextField(
                    controller: link,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Speedtest result link',
                      hintText: 'https://www.speedtest.net/result/…',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  errorLine(),
                ]);
            buttons = [
              OutlinedButton(
                  style: plainButton,
                  onPressed: busy ? null : () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              FilledButton(
                  style: redButton,
                  onPressed: busy ? null : () => sendLink(ctx, setD),
                  child: Text(busy ? 'Sending' : 'Send to Nomadwise',
                      softWrap: false)),
            ];
          default:
            body = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      'Run this at $space, so the speed on your page is the '
                      'speed people get.',
                      style: muted),
                  const SizedBox(height: 4),
                  step('1', 'Be at your space.'),
                  step('2', 'Connect this phone or laptop to your Wi-Fi, not '
                      'mobile data.'),
                  step('3', 'Press Start test and allow your location when '
                      'asked. It shows the test was done at the space.'),
                  const SizedBox(height: 12),
                  const Text('It takes about 20 seconds.',
                      style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
                  errorLine(),
                  const SizedBox(height: 10),
                  // Roomy, so the hover shade sits around the words with
                  // 8px corners; moved left by its padding so the words
                  // still line up with the text above.
                  Transform.translate(
                    offset: const Offset(-12, 0),
                    child: TextButton(
                      onPressed: () => setD(() {
                        stage = 'link';
                        error = null;
                      }),
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          minimumSize: const Size(0, 40),
                          foregroundColor: _perfRed,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          textStyle: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600)),
                      child: const Text(
                          'Not at the space? Send a Speedtest result instead'),
                    ),
                  ),
                ]);
            buttons = [
              OutlinedButton(
                  style: plainButton,
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              FilledButton(
                  style: redButton,
                  onPressed: () => run(setD),
                  child: const Text('Start test', softWrap: false)),
            ];
        }
        return PopScope(
          canPop: !busy,
          child: AlertDialog(
            scrollable: true,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            title: Text(stage == 'link'
                ? 'Send a Speedtest result'
                : 'Test your Wi-Fi'),
            content: SizedBox(width: 440, child: body),
            actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            actions: buttons.isEmpty
                ? null
                : [
                    Row(children: [
                      for (var i = 0; i < buttons.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(child: buttons[i]),
                      ]
                    ]),
                  ],
          ),
        );
      }),
    );
    open = false;
    Future.delayed(const Duration(milliseconds: 400), link.dispose);
    if (!mounted) return;
    if (applied != null) {
      setState(() => _venue?['wifi_speed_mbps'] = applied);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_isPreview
              ? 'Preview: the owner\'s page would show $applied Mbps.'
              : 'Done. Your page will show $applied Mbps shortly.')));
    } else if (linkSent) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_isPreview
              ? 'Preview: the link goes to Inbox & support.'
              : 'Sent. We check it and update your page.')));
    }
  }

  /// A database message as an owner should read it.
  String _friendly(Object e) {
    final s = e.toString();
    final m = RegExp(r'message: ([^,}]+)').firstMatch(s);
    final msg = (m?.group(1) ?? '').trim();
    return msg.isNotEmpty && !msg.contains('function')
        ? msg
        : 'Something went wrong. Please try again.';
  }

  Widget _waitingChip() => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: const Color(0xFFFDF3DF),
            borderRadius: BorderRadius.circular(8)),
        child: const Text('Waiting for Nomadwise approval',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6E5212))),
      );

  /// A part's heading on the page, with its Edit button.
  Widget _partHead(String title, String part,
          {double size = 22, String label = 'Edit'}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: Text(title,
                style: TextStyle(
                    fontSize: size,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: _pageInk)),
          ),
          const SizedBox(width: 10),
          _editButton(part, label: label),
        ]),
        if (_sent(part)) _waitingChip(),
      ]);

  /// The red frame a part's form opens in, with Cancel and Save change
  /// and a line saying what saving does.
  Widget _editFrame(String title, Widget form) {
    final err = _savedNote != null &&
        !_savedNote!.startsWith('Sent') &&
        !_savedNote!.startsWith('Draft') &&
        !_savedNote!.startsWith('Preview');
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(narrow ? 14 : 18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _edRed, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title,
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: _edInk)),
        const SizedBox(height: 12),
        form,
        const SizedBox(height: 16),
        const Divider(height: 1, color: Color(0xFFEEF0F2)),
        const SizedBox(height: 14),
        if (err)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_savedNote!,
                style: const TextStyle(fontSize: 13, color: Brand.red)),
          ),
        Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: const Text(
                    'Saving sends this to Nomadwise. It goes live once '
                    'approved; until then your page stays as it is.',
                    style: TextStyle(
                        fontSize: 12.5, height: 1.45, color: _edMuted)),
              ),
              Row(mainAxisSize: MainAxisSize.min, children: [
                OutlinedButton(
                  onPressed: _saving ? null : _cancelEdit,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    foregroundColor: _edInk,
                    side: const BorderSide(color: _edBorder),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Cancel', softWrap: false),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _saveEdit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    backgroundColor: _edRed,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    textStyle: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  child: Text(_saving ? 'Sending' : 'Save change',
                      softWrap: false),
                ),
              ]),
            ]),
      ]),
    );
  }

  /// A white card like the page's own.
  Widget _liveCard(Widget child, {EdgeInsets? pad}) => Container(
        width: double.infinity,
        padding: pad ?? const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE4E6EB)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );

  /// The page's tags, as nomadwise.io draws them: white with a thin
  /// border and 6px corners.
  /// The round link icons nomadwise.io uses (the template's own images
  /// on the Webflow CDN), so the Owner account shows the same ones.
  static const _siteIconBase =
      'https://cdn.prod.website-files.com/64b6780f84d27e4bfd91f236/';
  static const _siteIcons = {
    'link': '653f63d8d113b66f1016f267_hyperlink.png',
    'map': '65586cf6ac631f1984695fa8_location-pin.png',
    'instagram': '65d0b5c67ea7d2d0ef2d3eb7_instagram.png',
    'whatsapp': '65d0c06cfee042d9b2d76c09_whatsapp-logo-4454.png',
  };

  /// One of those icons; greyed for a locked (Premium) one. Falls back to
  /// a drawn icon if the image cannot load.
  Widget _siteIcon(String key, IconData fallback, Color color,
      {double size = 22, bool grey = false}) {
    Widget img = Image.network('$_siteIconBase${_siteIcons[key]}',
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Icon(fallback,
            size: size * .9, color: grey ? const Color(0xFF8A94A0) : color));
    if (grey) {
      img = Opacity(
        opacity: .55,
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix(<double>[
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: img,
        ),
      );
    }
    return img;
  }

  /// The tags as the page shows them, in its order (the template's tag
  /// list): Laptop Friendly, No Traffic Noise and Pass Required are not
  /// in it, so they are not offered here either.
  static const _liveTagOrder = [
    'aircon',
    'comfortable_seating',
    'low_background_music',
    'access_24h',
    'power_outlets',
    'good_for_calls',
    'quiet_space',
    'office_chairs',
    'cozy',
    'instagramable',
    'monitor',
    'swimming_pool',
    'call_room',
    'vegan_friendly',
  ];

  /// The icon the page's tag snippet gives a tag, by its words.
  static IconData _tagIcon(String t) {
    final s = t.toLowerCase();
    if (RegExp(r'skype|call room|phone booth').hasMatch(s)) {
      return Icons.headset_mic_outlined;
    }
    if (RegExp(r'air ?con|cooling').hasMatch(s)) return Icons.ac_unit;
    if (RegExp(r'seat|sofa|couch').hasMatch(s)) return Icons.weekend_outlined;
    if (RegExp(r'24|hour').hasMatch(s)) return Icons.schedule;
    if (RegExp(r'plug|socket|power').hasMatch(s)) return Icons.power_outlined;
    if (s.contains('call')) return Icons.call_outlined;
    if (RegExp(r'quiet|silent').hasMatch(s)) return Icons.volume_off_outlined;
    if (s.contains('chair')) return Icons.chair_outlined;
    if (RegExp(r'cozy|cosy|coffee').hasMatch(s)) return Icons.coffee_outlined;
    if (RegExp(r'monitor|screen').hasMatch(s)) {
      return Icons.desktop_windows_outlined;
    }
    return Icons.check;
  }

  Widget _liveTags(List<String> tags, {bool edit = false}) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final t in tags)
          Container(
            padding: const EdgeInsets.fromLTRB(11, 7, 14, 7),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE4E6EB)),
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x0A142032),
                    blurRadius: 2,
                    offset: Offset(0, 1)),
              ],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_tagIcon(t), size: 16, color: const Color(0xFFE0442E)),
              const SizedBox(width: 7),
              Text(t,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                      color: Color(0xFF2B2F36))),
            ]),
          ),
        if (edit)
          InkWell(
            onTap: () => _startEdit('tags'),
            borderRadius: BorderRadius.circular(6),
            child: CustomPaint(
              painter: _DashedBorder(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(11, 7, 14, 7),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.edit_outlined,
                      size: 15, color: Color(0xFF6B7280)),
                  const SizedBox(width: 6),
                  Text(tags.isEmpty ? 'Add tags' : 'Edit tags',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.2,
                          color: Color(0xFF6B7280))),
                ]),
              ),
            ),
          ),
      ]);

  // ------------------------------------------- locked Premium parts (step 2)
  // CR-22 step 2: on a free page the Premium parts show greyed with a lock
  // (the Verified badge, Instagram and WhatsApp, Promotions and events,
  // the advert with Remove ad). Pressing one opens the Get Premium window,
  // in the words agreed on 23 Oct (CR-29).

  static const _lockBorder = Color(0xFFAEB7C1);
  static const _lockFill = Color(0xFFF1F3F5);

  static const _plusWhy = {
    'social': (
      'Add your Instagram and WhatsApp',
      'Free pages show your website and directions. With Nomadwise Premium, '
          'nomads can also reach you on Instagram and WhatsApp straight from '
          'your page.'
    ),
    'ad': (
      'Remove the ad from your page',
      'With Nomadwise Premium, the advert on your page goes, and your own '
          'events and offers can take its place.'
    ),
    'promo': (
      'Promote your events and offers',
      'With Nomadwise Premium, your next event, an offer or your news takes '
          'the place of the advert on your page.'
    ),
    'enquiry': (
      'Unlimited requests from nomads',
      'Your free page includes 2 requests from nomads. With Nomadwise '
          'Premium, you can receive an unlimited number of requests straight '
          'to your inbox.'
    ),
    'badge': (
      'Get the Verified by Nomadwise badge',
      'Nomadwise Premium pages carry the Verified by Nomadwise badge, on the '
          'page and in every list.'
    ),
  };

  static const _plusPerks = [
    'Verified by Nomadwise badge, on your page and for your own website and Instagram',
    "Top positioning on your region's page",
    'Promote your events and offers on your page',
    'Unlimited requests from nomads, straight to your inbox',
    'Your Instagram and WhatsApp on your page',
    'Remove ads from your page',
  ];

  /// The Get Premium window. "See the Premium plan" opens Plan & billing,
  /// where the price for their country is shown before anything is
  /// charged.
  Future<void> _getPlus(String why) {
    final (title, rawLead) = _plusWhy[why] ?? _plusWhy['promo']!;
    // The free limit as set (migration 212), not a fixed 2.
    final limit = (_allow?['limit'] as num?)?.toInt() ?? 2;
    final lead = rawLead.replaceFirst('includes 2 requests',
        'includes $limit ${limit == 1 ? 'request' : 'requests'}');
    _cap('owner_plus_window', {'why': why});
    return _ownerDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                          color: const Color(0xFFFFECED),
                          borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.lock_outline,
                          color: _pageRed, size: 22),
                    ),
                    const Spacer(),
                    IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close)),
                  ]),
                  const SizedBox(height: 12),
                  Text(title,
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                          color: _edInk)),
                  const SizedBox(height: 6),
                  Text(lead,
                      style: const TextStyle(
                          fontSize: 15, height: 1.5, color: Color(0xFF3F4954))),
                  const SizedBox(height: 16),
                  const Text('Everything in Free, plus:',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF3F4954))),
                  const SizedBox(height: 8),
                  for (final t in _plusPerks)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Icon(Icons.check,
                                  size: 18, color: Color(0xFF22663A)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                                child: Text(t,
                                    style: const TextStyle(
                                        fontSize: 15, color: _edInk))),
                          ]),
                    ),
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8, bottom: 6),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: const Color(0xFFF7F7F7),
                        borderRadius: BorderRadius.circular(8)),
                    // The price itself, for this space's country, and
                    // that it can be cancelled (Jonathan, 12 Nov 2026:
                    // no "price of a day pass", which "varies quite a
                    // lot"; "just clear on what the pricing is, and that
                    // they can cancel at anytime"). No figure when the
                    // price cannot be read: never another country's.
                    child: FutureBuilder<Map<String, dynamic>?>(
                        future: _planPriceFor(_venue),
                        builder: (_, snap) {
                          var head = 'Premium is a monthly or yearly '
                              'subscription';
                          var sub = 'Cancel any time. Your price is on the '
                              'next page.';
                          final p = snap.data;
                          if (p != null && p['mapped'] == true) {
                            final c = PricingChoice(p);
                            final m = c.monthly, y = c.yearly;
                            if (m != null && y != null) {
                              head = 'Premium is '
                                  '${formatMoney(m, c.currency)} a month, or '
                                  '${formatMoney(y, c.currency)} a year';
                              sub = 'Pay monthly or yearly, and cancel any '
                                  'time.';
                            }
                          }
                          return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(head,
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: _edInk)),
                                const SizedBox(height: 2),
                                Text(sub,
                                    style: const TextStyle(
                                        fontSize: 13, color: _edMuted)),
                              ]);
                        }),
                  ),
                  const Text(
                      'Nothing is charged until you confirm. Your free page '
                      'stays as it is if you do not.',
                      style: TextStyle(fontSize: 12.5, color: _edMuted)),
                  const SizedBox(height: 18),
                  Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            foregroundColor: _edInk,
                            side: const BorderSide(color: _edBorder),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text('Not now', softWrap: false),
                        ),
                        FilledButton(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _goTab(_Tab.membership);
                          },
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            backgroundColor: _edRed,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                            textStyle: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          child:
                              const Text('See the Premium plan', softWrap: false),
                        ),
                      ]),
                ]),
          ),
        ),
      ),
    );
  }

  /// A greyed part with a lock: pressing it opens the Get Premium window.
  Widget _lockedChip(String label, String why, {IconData icon = Icons.lock_outline}) =>
      Semantics(
        button: true,
        label: '$label, locked. See what Premium adds',
        child: InkWell(
          onTap: () => _getPlus(why),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
                color: _lockFill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _lockBorder)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 14, color: _edMuted),
              const SizedBox(width: 6),
              Text(label,
                  softWrap: false,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _edMuted)),
            ]),
          ),
        ),
      );

  /// Promotions and events in the sidebar: locked on a free page; on a
  /// Premium page the message as it shows, with Edit (Promotions and events tab).
  Widget _promoPart() {
    if (!_verified) {
      return Semantics(
        button: true,
        label: 'Promotions and events, locked. See what Premium adds',
        child: InkWell(
          onTap: () => _getPlus('promo'),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            decoration: BoxDecoration(
                color: _lockFill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _lockBorder, width: 1.5)),
            child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.lock_outline, size: 18, color: _edInk),
                    SizedBox(width: 8),
                    Text('Promotions and events',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _edInk)),
                  ]),
                  SizedBox(height: 6),
                  Text(
                      'Show your next event, an offer or news here, in place '
                      'of the advert below.',
                      style: TextStyle(
                          fontSize: 14, height: 1.45, color: Color(0xFF3F4954))),
                  SizedBox(height: 10),
                  Text('See what Premium adds',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: _pageRed)),
                ]),
          ),
        ),
      );
    }
    final has = _mentionTitle.text.trim().isNotEmpty;
    final edit = OutlinedButton.icon(
      onPressed: () => _goTab(_Tab.message),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        foregroundColor: _edInk,
        backgroundColor: Colors.white,
        side: const BorderSide(color: _edBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      icon: Icon(has ? Icons.edit_outlined : Icons.add, size: 15),
      label: Text(has ? 'Edit' : 'Add one', softWrap: false),
    );
    return _liveCard(
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Expanded(child: _promoLabel),
            edit,
          ]),
          const SizedBox(height: 10),
          if (has)
            _mentionCard(card: false)
          else
            const Text(
                'Show your next event, an offer or news here. It shows on '
                'your page in place of an advert.',
                style: TextStyle(fontSize: 14, height: 1.45, color: _edMuted)),
        ]),
        pad: const EdgeInsets.fromLTRB(20, 18, 20, 18));
  }

  /// The partner adverts nomadwise.io shows in a free page's sidebar
  /// (Webflow's Ad Visibilities, lowest Order first): Ubigi for the
  /// countries it has a banner for, else SafetyWing.
  static const _adBase =
      'https://cdn.prod.website-files.com/64b6780f84d27e4bfd91f2d6/';
  static const _adAsia = '68628fc900d45a3390a90cce_Banner_EN_Asia_200x600.webp';
  static const _adEurope =
      '6862786288a17bc32f58ddf7_Banner_EN_Europe_200x600.webp';
  static const _adSpain = '68628b7eb63b4a0b098ed39e_Banner_EN_Spain_200x600.webp';
  static const _adDefault = '6a57a9b549b2fbe54414964b_SafetyWing%20Banner%202.webp';
  static const _adByCountry = {
    'indonesia': _adAsia,
    'thailand': _adAsia,
    'japan': _adAsia,
    'vietnam': _adAsia,
    'portugal': _adEurope,
    'united kingdom': _adEurope,
    'england': _adEurope,
    'scotland': _adEurope,
    'wales': _adEurope,
    'northern ireland': _adEurope,
    'spain': _adSpain,
  };

  /// The advert as it shows on a free page: the real partner banner, in
  /// full colour, with Remove ad (Leonie, 2 Nov 2026: a grey box gives
  /// no reason to remove it).
  Widget _partnerAdvert() {
    final country = '${_venue?['country'] ?? ''}'.trim().toLowerCase();
    final ad = _adByCountry[country] ?? _adDefault;
    return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFD5DAE0)),
              borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              color: Colors.white,
              constraints: const BoxConstraints(maxHeight: 560),
              child: Image.network('$_adBase$ad',
                  fit: BoxFit.contain,
                  semanticLabel: 'The partner advert on your page',
                  errorBuilder: (_, __, ___) => _advertPlaceholder()),
            ),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    const Text('This advert shows on your page.',
                        style: TextStyle(
                            fontSize: 13, color: Color(0xFF3F4954))),
                    FilledButton.icon(
                      onPressed: () => _getPlus('ad'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        backgroundColor: _edRed,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        textStyle: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('Remove ad', softWrap: false),
                    ),
                  ]),
            ),
          ]),
        ),
      );
  }

  /// What shows if the advert image cannot load.
  Widget _advertPlaceholder() => Container(
              constraints: const BoxConstraints(minHeight: 200),
              color: const Color(0xFFE3E7EB),
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ADVERT',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: .8,
                            color: _edMuted)),
                    SizedBox(height: 8),
                    Text('A partner advert, for example an eSIM for travellers',
                        style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            height: 1.2,
                            color: Color(0xFF4A5562))),
                    SizedBox(height: 8),
                    Text(
                        'Your live page shows a partner advert here.',
                        style: TextStyle(fontSize: 13, color: _edMuted)),
                  ]),
            );

  Widget _listingTab(bool wide) {
    final v = _venue!;
    final area = [v['neighbourhood'], v['city']]
        .where((x) => (x ?? '').toString().isNotEmpty)
        .join(', ');
    final country = (v['country'] ?? '').toString();
    final title = [
      '${v['name']}${country.isNotEmpty ? ' in $country' : ''}',
      if ((v['neighbourhood'] ?? '').toString().isNotEmpty) v['neighbourhood'],
    ].join(' - ');
    final isCafe = v['type'] == 'cafe';
    // In the live page's order, and only the tags the page shows.
    final tags = [
      for (final key in _liveTagOrder)
        if (_facts[key] == true) _siteTags[key] ?? key
    ];
    final photos = _photos.isNotEmpty
        ? _photos
        : _pagePhotos.isNotEmpty
            ? _pagePhotos
            : List<String>.from((v['google_photos'] ?? const []) as List);
    final prices = [
      for (final (name, price, _) in _pageProducts) (name, price),
      if (_priceDay.text.trim().isNotEmpty)
        ('Day pass', Price.format(_priceDay.text, _currency).trim()),
      if (_priceWeek.text.trim().isNotEmpty)
        ('Week pass', Price.format(_priceWeek.text, _currency).trim()),
      if (_priceMonth.text.trim().isNotEmpty)
        ('Month pass', Price.format(_priceMonth.text, _currency).trim()),
      if (_priceCoffee.text.trim().isNotEmpty)
        ('Cappuccino', Price.format(_priceCoffee.text, _currency).trim()),
    ];
    const body = TextStyle(fontSize: 15, height: 1.6, color: _pageInk);
    const muted = TextStyle(fontSize: 13, height: 1.45, color: _edMuted);

    Widget stat(IconData icon, String text, {Color color = _pageInk}) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(text,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: _pageInk)),
        ]);

    // ---- photos ----
    final photosPart = _editing == 'photos'
        ? _editFrame(
            'Photos',
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  'Up to five. The first is the large photo at the top of '
                  'your page. Drag a photo to change the order (on a '
                  'phone, press and hold it first), or press the star to '
                  'make it the main one.',
                  style: muted),
              const SizedBox(height: 12),
              // Two across on a phone, so five photos are not a long
              // column of one each.
              LayoutBuilder(builder: (context, box) {
                final w = box.maxWidth < 2 * _slotW + 10
                    ? (box.maxWidth - 10) / 2
                    : _slotW;
                return Wrap(spacing: 10, runSpacing: 10, children: [
                  for (var i = 0; i < _photos.length; i++) _photoSlot(i, w: w),
                  if (_photos.length < 5) _addPhotoSlot(w: w),
                ]);
              }),
            ]))
        : Stack(children: [
            _photoGrid(photos, height: wide ? 320 : 200),
            Positioned(
                right: 10,
                top: 10,
                child: _editButton('photos', label: 'Edit photos')),
          ]);

    // ---- tags ----
    final tagsPart = _editing == 'tags'
        ? _editFrame(
            'What is true for your space?',
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                  'Each one you tick shows as a tag on your page. Tick only '
                  'what a visitor would find true today.',
                  style: muted),
              const SizedBox(height: 6),
              Wrap(spacing: 4, runSpacing: 0, children: [
                for (final key in _liveTagOrder)
                  for (final (k, label) in _factLabels)
                    if (k == key)
                    SizedBox(
                      width: 280,
                      child: CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(_siteTags[key] ?? label,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        subtitle: Text(_factGuide[key] ?? '',
                            style: const TextStyle(fontSize: 12.5)),
                        value: _facts[key] == true,
                        onChanged: (x) => setState(() {
                          _facts[key] = x == true;
                          _dirty = true;
                          _editSeq++;
                          _lastEdit = DateTime.now();
                        }),
                      ),
                    ),
              ]),
            ]))
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Drawn like the page: white tags with their icons, and in
            // place of the page's dashed "Add a tag", "Edit tags".
            _liveTags(tags, edit: true),
            if (_sent('tags')) _waitingChip(),
          ]);

    // ---- about ----
    final aboutPart = _editing == 'about'
        ? _editFrame('About your space', _descriptionEditor(heading: false))
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _partHead('About ${v['name']}', 'about'),
            const SizedBox(height: 10),
            if (_description.text.trim().isEmpty)
              const Text(
                  'No description yet. Press Edit to say what makes your '
                  'space special.',
                  style: muted)
            else
              for (final line
                  in _description.text.split('\n').map((l) => l.trim()))
                if (line.isNotEmpty)
                  line.startsWith('## ')
                      ? Padding(
                          padding: const EdgeInsets.only(top: 10, bottom: 4),
                          child: Text(line.substring(3),
                              style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: _pageInk)),
                        )
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(line, style: body),
                        ),
          ]);

    // ---- prices ----
    final pricesPart = _editing == 'prices'
        ? _editFrame(
            isCafe ? 'Prices' : 'Passes and prices',
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  'Every price on your page. Tap to add the usual ones, '
                  'then type the amount, like 350 or 1,500. Each change '
                  'goes live once Nomadwise approves it.',
                  style: muted),
              const SizedBox(height: 12),
              _pasteCard(),
              const SizedBox(height: 16),
              _currencyPicker(),
              const SizedBox(height: 16),
              // The prices, grouped as the page groups them.
              LayoutBuilder(builder: (context, box) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (k, label) in _priceKinds)
                      if (_priceRows.any((r) => r.category == k)) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10, top: 4),
                          child: Text(label,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: _edInk)),
                        ),
                        for (final r in _priceRows)
                          if (r.category == k)
                            _priceRowEditor(r, box.maxWidth),
                        const SizedBox(height: 6),
                      ],
                  ])),
              // One tap for the usual ones; a preset already in the list
              // is not offered again.
              Text(_priceRows.isEmpty ? 'Add your prices' : 'Add more',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _edMuted)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (label, type) in _pricePresets)
                  if (!_priceRows.any((r) =>
                      r.name.text.trim().toLowerCase() == label.toLowerCase()))
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16, color: _edInk),
                      label: Text(label),
                      labelStyle: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: _edInk),
                      backgroundColor: Colors.white,
                      side: const BorderSide(color: _edBorder),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      onPressed: _priceRows.length >= 40
                          ? null
                          : () => _addPriceRow(name: label, type: type),
                    ),
                ActionChip(
                  avatar: const Icon(Icons.edit_outlined,
                      size: 16, color: _pageRed),
                  label: const Text('Something else'),
                  labelStyle: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: _pageRed),
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: _edBorder),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  onPressed:
                      _priceRows.length >= 40 ? null : () => _addPriceRow(),
                ),
              ]),
              if (isCafe) ...[
                const SizedBox(height: 16),
                _priceField(_priceCoffee, 'Cappuccino', width: 220),
              ],
            ]))
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _partHead('Prices', 'prices'),
            const SizedBox(height: 10),
            if (((_venue?['price_changes_waiting'] as num?) ?? 0) > 0 &&
                !_sent('prices'))
              _waitingChip(),
            if (prices.isEmpty &&
                _descriptionHasPrices &&
                !_sent('prices') &&
                ((_venue?['price_changes_waiting'] as num?) ?? 0) == 0)
              // Spaces that typed their price list into the
              // description (OUR HQ, 3 Nov 2026): one tap to turn it
              // into prices (migration 242).
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text(
                    'Your description has prices in it. We can turn them '
                    'into a price list for you to check.',
                    style: muted),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _saving
                      ? null
                      : () {
                          _startEdit('prices');
                          setState(() {
                            _pasteOpen = true;
                            _pasteDone = null;
                            _pasteError = null;
                            _pasteText.text = _descriptionPlain;
                          });
                          _readPastedPrices();
                        },
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Turn them into prices'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _pageRed,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ])
            else if (prices.isEmpty)
              const Text('No prices yet. Press Edit to add one.',
                  style: muted)
            else if (_livePrices(photos) != null)
              _livePrices(photos)!
            else
              for (final (name, price) in prices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(name, style: body)),
                        const SizedBox(width: 12),
                        Text(price,
                            style: body.copyWith(fontWeight: FontWeight.w700)),
                      ]),
                ),
          ]);

    // ---- a cafe: only the cappuccino price ----
    // A price list is for coworking spaces (Jonathan, 6 Nov 2026). A
    // cafe keeps the one cappuccino price, a feel for how pricey the
    // place is.
    final coffeeNow = _priceCoffee.text.trim();
    final coffeePart = _editing == 'coffee'
        ? _editFrame(
            'Cappuccino price',
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                  'What a cappuccino costs at your cafe. It gives people a '
                  'feel for your prices. It goes live once Nomadwise '
                  'approves it.',
                  style: muted),
              const SizedBox(height: 16),
              _currencyPicker(),
              const SizedBox(height: 16),
              _priceField(_priceCoffee, 'Cappuccino', width: 220),
            ]))
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _partHead('Cappuccino price', 'coffee'),
            const SizedBox(height: 10),
            if (_sent('coffee')) _waitingChip(),
            Text(
                coffeeNow.isEmpty
                    ? 'Not added yet. Press Edit to add it.'
                    : 'A cappuccino costs '
                        '${Price.format(Price.cleanAmount(coffeeNow), _currency)}.',
                style: coffeeNow.isEmpty ? muted : body),
          ]);

    final main = _liveCard(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: TextStyle(
                  fontSize: wide ? 30 : 24,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                  color: _pageInk)),
          const SizedBox(height: 10),
          // Where it is and its WiFi, with Request change on the right
          // (Leonie, 2 Nov 2026): owners do not edit these, they ask us.
          // No "Managed by its owner" mark: dropped from the live page
          // on 26 Oct, so not here either.
          Builder(builder: (context) {
            final facts = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                    Wrap(
                        spacing: 18,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (area.isNotEmpty)
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.location_on, size: 18, color: _pageRed),
                              const SizedBox(width: 4),
                              Text(area,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: _pageRed)),
                            ]),
                          if (country.isNotEmpty)
                            Text(country,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: _pageInk)),
                          // The live page shows Leonie's green chip here
                          // (verified-chip, 5 Nov 2026, the verified-badge
                          // class in Webflow).
                          if (_verified)
                            Image.network(
                                'https://nomadmaps.io/badges/verified-chip.png',
                                width: 171,
                                height: 27,
                                semanticLabel: 'Verified by nomadwise.io',
                                errorBuilder: (_, __, ___) => const Text(
                                    'Verified by nomadwise.io',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: _pageRed)))
                          else
                            _lockedChip('Verified badge', 'badge'),
                        ]),
                  const SizedBox(height: 10),
                    Wrap(spacing: 20, runSpacing: 8, children: [
                      if (v['wifi_speed_mbps'] != null)
                        stat(Icons.wifi, '${v['wifi_speed_mbps']}Mbps'),
                      if (v['google_rating_snapshot'] != null)
                        stat(
                            Icons.star,
                            '${v['google_rating_snapshot']} '
                            '(${v['google_reviews_snapshot'] ?? 0})',
                            color: const Color(0xFFF4B23E)),
                      stat(Icons.laptop, isCafe ? 'Cafe' : 'Coworking Space'),
                    ]),
                ]);
            return wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: facts),
                    const SizedBox(width: 12),
                    _requestButton(),
                  ])
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        facts,
                        const SizedBox(height: 10),
                        _requestButton(),
                      ]);
          }),
          const SizedBox(height: 8),
          const Text(
              'Wi-Fi speed is measured at your space with Test your '
              'Wi-Fi. To change your name or location, go to Settings.',
              style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
          const SizedBox(height: 18),
          _keyed('photos', photosPart),
          if (_sent('photos')) _waitingChip(),
          const SizedBox(height: 22),
          _keyed('tags', tagsPart),
          const SizedBox(height: 28),
          _keyed('about', aboutPart),
          const SizedBox(height: 28),
          _keyed('prices', isCafe ? coffeePart : pricesPart),
          const SizedBox(height: 28),
          _mapBlock(v, area),
        ]),
        pad: EdgeInsets.all(wide ? 28 : 18));

    // ---- sidebar: hours, links, enquiries, advert ----
    final days = [
      for (final day in _days)
        if (_hours[day]!.text.trim().isNotEmpty) day
    ];
    final hoursPart = _editing == 'hours'
        ? _editFrame(
            'Opening hours',
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  _hoursUntouched
                      ? 'These are the hours Google shows for you today. '
                          'Change any day that is wrong.'
                      : 'Pick the times for each day. "Not set" keeps what '
                          'Google shows.',
                  style: muted),
              const SizedBox(height: 10),
              for (final day in _days) _dayHours(day),
              TextButton.icon(
                  onPressed: _copyMondayHours,
                  icon: const Icon(Icons.copy_all_outlined, size: 16),
                  label: const Text('Use Monday\'s hours for every day')),
            ]))
        : _liveCard(
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _partHead('Opening Hours', 'hours', size: 22),
              const SizedBox(height: 10),
              if (days.isEmpty)
                const Text('No opening hours yet.', style: muted)
              else
                for (final day in days)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(children: [
                      SizedBox(
                        width: 100,
                        child: Text(_dayNames[day]!,
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _pageInk)),
                      ),
                      Expanded(
                        child: Text(_hours[day]!.text.trim(),
                            style: const TextStyle(
                                fontSize: 14, color: Color(0xFF3F4954))),
                      ),
                    ]),
                  ),
            ]),
            pad: const EdgeInsets.fromLTRB(20, 18, 20, 18));

    Widget circle(String key, IconData icon, Color color) => Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.only(right: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFE0E0E0))),
          child: _siteIcon(key, icon, color, size: 22),
        );
    Widget lockedCircle(String key, IconData icon, String what) => Semantics(
          button: true,
          label: '$what link, locked. See what Premium adds',
          child: InkWell(
            onTap: () => _getPlus('social'),
            customBorder: const CircleBorder(),
            child: Container(
              width: 44,
              height: 44,
              margin: const EdgeInsets.only(right: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: _lockFill,
                  shape: BoxShape.circle,
                  border: Border.all(color: _lockBorder)),
              child: _siteIcon(key, icon, const Color(0xFF8A94A0),
                  size: 20, grey: true),
            ),
          ),
        );
    // Premium, not filled in yet: the link is unlocked and waiting to
    // be added (Jonathan, 12 Nov 2026: on Premium the two icons were
    // simply missing; "as if to say these are unlocked, you can now add
    // them"). Its own colours, faint, with a red plus; pressing it
    // opens Links and contact.
    Widget addCircle(String key, IconData icon, Color color, String what) =>
        Tooltip(
          message: 'Add your $what',
          child: Semantics(
            button: true,
            label: 'Add your $what',
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: InkWell(
                onTap: () => _startEdit('links'),
                customBorder: const CircleBorder(),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Stack(clipBehavior: Clip.none, children: [
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: _pageRed, width: 1.5)),
                      child: Opacity(
                          opacity: .5,
                          child: _siteIcon(key, icon, color, size: 22)),
                    ),
                    Positioned(
                      right: -3,
                      top: -3,
                      child: Container(
                        width: 18,
                        height: 18,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: _pageRed,
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: Colors.white, width: 1.5)),
                        child: const Icon(Icons.add,
                            size: 12, color: Colors.white),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        );
    final linksPart = _editing == 'links'
        ? _editFrame(
            'Links and contact',
            Wrap(spacing: 10, runSpacing: 12, children: [
              SizedBox(
                  width: 260,
                  child: TextField(
                      controller: _website,
                      decoration: _dec('Website', hint: 'yourspace.com'))),
              if (_verified) ...[
                SizedBox(
                    width: 260,
                    child: TextField(
                        controller: _instagram,
                        decoration: _dec('Instagram handle', hint: 'yourspace')
                            .copyWith(
                                prefixText: '@',
                                helperText:
                                    'Just the handle, like @kelp.cowork',
                                errorText: _igHandle(_instagram.text) == null
                                    ? 'Letters, numbers, dots and underscores only'
                                    : null))),
                SizedBox(
                    width: 420,
                    child: PhoneField(
                        number: _whatsapp,
                        country: _waCountry,
                        label: 'WhatsApp (optional)',
                        helper: 'Leave empty if you do not use WhatsApp.')),
              ] else
                // Agreed 23 Oct: Instagram and WhatsApp come with Premium.
                SizedBox(
                  width: 420,
                  child: InkWell(
                    onTap: () => _getPlus('social'),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: _lockFill,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _lockBorder)),
                      child: const Row(children: [
                        Icon(Icons.lock_outline, size: 18, color: _edMuted),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text.rich(TextSpan(children: [
                            TextSpan(
                                text: 'Instagram and WhatsApp\n',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: _edInk)),
                            TextSpan(
                                text: 'Come with Premium. See what Premium adds',
                                style: TextStyle(fontSize: 13)),
                          ]), style: TextStyle(
                              fontSize: 14, color: Color(0xFF3F4954))),
                        ),
                      ]),
                    ),
                  ),
                ),
            ]))
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // A Wrap: on a narrow phone with large text the Edit
            // button moves under the circles instead of running off.
            Wrap(
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (_website.text.trim().isNotEmpty)
                    circle('link', Icons.link, _pageInk),
                  circle('map', Icons.location_on, _pageRed),
                  if (_verified)
                    _instagram.text.trim().isNotEmpty
                        ? circle('instagram', Icons.camera_alt_outlined,
                            const Color(0xFFD62976))
                        : addCircle('instagram', Icons.camera_alt_outlined,
                            const Color(0xFFD62976), 'Instagram'),
                  if (_verified)
                    _whatsapp.text.trim().isNotEmpty
                        ? circle('whatsapp', Icons.chat_outlined,
                            const Color(0xFF25D366))
                        : addCircle('whatsapp', Icons.chat_outlined,
                            const Color(0xFF25D366), 'WhatsApp'),
                  if (!_verified) ...[
                    lockedCircle(
                        'instagram', Icons.camera_alt_outlined, 'Instagram'),
                    lockedCircle('whatsapp', Icons.chat_outlined, 'WhatsApp'),
                  ],
                  const SizedBox(width: 6),
                  _editButton('links'),
                ]),
            if (_sent('links')) _waitingChip(),
          ]);

    final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _keyed('hours', hoursPart),
      if (_sent('hours')) _waitingChip(),
      const SizedBox(height: 10),
      _closedPart(),
      const SizedBox(height: 16),
      _keyed('links', linksPart),
      // Every page has Send a request; a free one shows how many of its
      // free enquiries are left under it (CR-31).
      const SizedBox(height: 16),
      _pageButton('Send a request', wide: true),
      if (_allowanceLine() != null) ...[
        const SizedBox(height: 12),
        _allowanceLine()!,
      ],
      const SizedBox(height: 16),
      _promoPart(),
      // A Premium page shows no adverts.
      if (!_verified) ...[
        const SizedBox(height: 16),
        _partnerAdvert(),
      ],
    ]);

    final help = Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text.rich(
          const TextSpan(children: [
            TextSpan(text: 'This is your page as travellers see it. Press '),
            TextSpan(
                text: 'Edit', style: TextStyle(fontWeight: FontWeight.w700)),
            TextSpan(
                text: ' on any part to change it there. Nomadwise approves '
                    'each change before it goes live.'),
          ]),
          style: const TextStyle(fontSize: 14, color: Color(0xFF3F4954))),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!_isPreview)
        OwnerQuestionCard(
            key: ValueKey('q-${v['id']}'), venueId: '${v['id']}'),
      help,
      LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= 820) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: main),
            const SizedBox(width: 22),
            SizedBox(width: 300, child: side),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          main,
          const SizedBox(height: 18),
          side,
        ]);
      }),
    ]);
  }

  /// A plain picture of what the page will show, updated as they type.
  // The page's own words for the work-friendly facts (its tags).
  static const _siteTags = {
    'power_outlets': 'Enough Plug Sockets',
    'aircon': 'Aircon',
    'comfortable_seating': 'Comfortable Seating',
    'cozy': 'Cozy',
    'quiet_space': 'Quiet Space',
    'good_for_calls': 'Good for Calls',
    'call_room': 'Skype Room',
    'monitor': 'Monitor Available',
    'office_chairs': 'Office Chairs',
    'access_24h': '24 Hour Access',
    'laptops_allowed': 'Laptop Friendly',
    'swimming_pool': 'Swimming Pool',
    'no_traffic_noise': 'No Traffic Noise',
    'low_background_music': 'Low Background Music',
    'instagramable': 'Instagramable',
    'vegan_friendly': 'Vegan Friendly',
    'pass_required': 'Pass Required',
  };

  static const _pageRed = Color(0xFFE8464E); // the site's button red
  static const _pageInk = Color(0xFF333333);

  /// The listing page as nomadwise.io draws it (28 Sep screenshots of
  /// Nomio Coworking Lounge), in the order a phone shows it: the main
  /// column, then the sidebar (hours, links, enquiry button, advert).
  Widget _preview() {
    final v = _venue!;
    final area = [v['neighbourhood'], v['city']]
        .where((x) => (x ?? '').toString().isNotEmpty)
        .join(', ');
    final country = (v['country'] ?? '').toString();
    final title = [
      '${v['name']}${country.isNotEmpty ? ' in $country' : ''}',
      if ((v['neighbourhood'] ?? '').toString().isNotEmpty) v['neighbourhood'],
    ].join(' - ');
    final tags = [
      for (final key in _liveTagOrder)
        if (_facts[key] == true) _siteTags[key] ?? key
    ];
    // Their own photos once added; else the ones on the page today;
    // else Google's.
    final photos = _photos.isNotEmpty
        ? _photos
        : _pagePhotos.isNotEmpty
            ? _pagePhotos
            : List<String>.from((v['google_photos'] ?? const []) as List);
    final pageProducts = _pageProducts;
    final prices = [
      if (_priceDay.text.trim().isNotEmpty)
        ('Day pass', Price.format(_priceDay.text, _currency)),
      if (_priceWeek.text.trim().isNotEmpty)
        ('Week pass', Price.format(_priceWeek.text, _currency)),
      if (_priceMonth.text.trim().isNotEmpty)
        ('Month pass', Price.format(_priceMonth.text, _currency)),
      if (_priceCoffee.text.trim().isNotEmpty)
        ('Cappuccino', Price.format(_priceCoffee.text, _currency)),
    ];
    final isCafe = v['type'] == 'cafe';

    Widget stat(IconData icon, String text, {Color color = Brand.inkSecondary}) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 4),
          Text(text,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: _pageInk)),
        ]);

    // The main column of the page. On a computer the photos stand
    // taller; in the full-size view the tags are not buttons.
    Widget page({required bool computer, bool tappable = true}) => _pageCard(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 19,
              height: 1.2,
              color: _pageInk)),
      const SizedBox(height: 8),
      Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (area.isNotEmpty)
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.location_on, size: 15, color: _pageRed),
                Text(area,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _pageRed)),
              ]),
            if (country.isNotEmpty)
              Text(country,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _pageInk)),
            if (_verified)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: const Color(0xFFE4F2EA),
                    borderRadius: BorderRadius.circular(8)),
                child: const Text('Verified',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F6B41))),
              ),
          ]),
      const SizedBox(height: 8),
      Wrap(spacing: 14, runSpacing: 6, children: [
        if (v['wifi_speed_mbps'] != null)
          stat(Icons.wifi, '${v['wifi_speed_mbps']}Mbps'),
        if (v['google_rating_snapshot'] != null)
          stat(Icons.star, '${v['google_rating_snapshot']} '
              '(${v['google_reviews_snapshot'] ?? 0})',
              color: const Color(0xFFF4B23E)),
        stat(Icons.laptop, isCafe ? 'Cafe' : 'Coworking Space'),
      ]),
      const SizedBox(height: 12),
      _photoGrid(photos, height: computer ? 250 : 130),
      const SizedBox(height: 12),
      if (_verified) ...[
        Align(
            alignment: Alignment.centerLeft,
            child: _pageButton('Send a request')),
        const SizedBox(height: 12),
      ],
      _tagsBlock(tags, tappable: tappable),
      const SizedBox(height: 12),
      const Text('Something need updating? Let us know.',
          style: TextStyle(
              fontSize: 11.5,
              color: _pageRed,
              decoration: TextDecoration.underline,
              decorationColor: _pageRed)),
      const SizedBox(height: 14),
      ..._descriptionBlocks(),
      if (prices.isNotEmpty || pageProducts.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Text('Prices',
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: 15, color: _pageInk)),
        const SizedBox(height: 6),
        // The passes the page shows today, then what is typed here.
        for (final (name, price, _) in pageProducts)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text.rich(TextSpan(children: [
              TextSpan(
                  text: price.isEmpty ? name : '$name: ',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: price),
            ]), style: const TextStyle(fontSize: 12.5, color: _pageInk)),
          ),
        for (final (label, val) in prices)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text.rich(TextSpan(children: [
              TextSpan(
                  text: '$label: ',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: val.trim()),
            ]), style: const TextStyle(fontSize: 12.5, color: _pageInk)),
          ),
      ],
      const SizedBox(height: 14),
      _drawnMap(v, area),
    ]));

    return _panel(
      tint: Brand.bg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Page preview',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const Spacer(),
          if (_dirty)
            const Text('Unsaved edits',
                style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
        ]),
        const SizedBox(height: 8),
        _previewToggle(),
        const SizedBox(height: 8),
        Text(
            _previewComputer
                ? 'Your page as a computer shows it, made smaller to fit '
                    'here. The hours, links and advert sit in a column on '
                    'the right.'
                : 'Your page as a phone shows it: one column, with the '
                    'hours, links and advert under the map.',
            style: const TextStyle(
                fontSize: 11.5, color: Brand.inkMuted, height: 1.4)),
        const SizedBox(height: 12),
        if (_previewComputer) ...[
          SizedBox(
            width: double.infinity,
            child: FittedBox(
                fit: BoxFit.fitWidth,
                alignment: Alignment.topLeft,
                child: _computerLayout(
                    page(computer: true, tappable: false))),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => _openComputerPreview(
                    _computerLayout(page(computer: true, tappable: false))),
                icon: const Icon(Icons.open_in_full, size: 16),
                label: const Text('Open full size')),
          ),
        ] else ...[
          page(computer: false),
          const SizedBox(height: 10),
          _sidebar(),
        ],
      ]),
    );
  }

  /// Phone or Computer, above the page preview (Jonathan, 5 Oct 2026).
  Widget _previewToggle() {
    Widget side(bool computer, IconData icon, String label) {
      final on = _previewComputer == computer;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _previewComputer = computer),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: on ? Brand.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              boxShadow: on ? Brand.shadowResting : null,
            ),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon,
                      size: 16, color: on ? Brand.ink : Brand.inkSecondary),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                          color: on ? Brand.ink : Brand.inkSecondary)),
                ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: Brand.field, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        side(false, Icons.phone_iphone, 'Phone'),
        side(true, Icons.computer, 'Computer'),
      ]),
    );
  }

  /// The page as a computer lays it out: the main column, and the
  /// hours, links, enquiry button and advert in a column on the right.
  static const double _computerWidth = 940;

  Widget _computerLayout(Widget main) => SizedBox(
        width: _computerWidth,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: main),
          const SizedBox(width: 16),
          SizedBox(width: 290, child: _sidebar()),
        ]),
      );

  /// The computer view at its real size, in a window over the page
  /// (made smaller only when the screen is narrower than the page).
  Future<void> _openComputerPreview(Widget layout) => _ownerDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          backgroundColor: Brand.bg,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _computerWidth + 40),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 8, 2),
                child: Row(children: [
                  const Expanded(
                    child: Text('Your page on a computer',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                  IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close)),
                ]),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.topCenter,
                      child: layout),
                ),
              ),
            ]),
          ),
        ),
      );

  /// What each tag means, for the list that opens from the preview.
  static const _factGuide = {
    'laptops_allowed': 'People are welcome to work on a laptop here.',
    'power_outlets': 'There is a socket within reach of most seats.',
    'good_for_calls':
        'Someone can take a video call without disturbing others.',
    'quiet_space': 'There is an area where people keep their voices down.',
    'comfortable_seating': 'Seats someone can work in for a few hours.',
    'aircon': 'The work area is air conditioned.',
    'access_24h': 'Members can get in at any hour.',
    'call_room': 'There is a room or booth for a private call.',
    'monitor': 'There are screens people can plug a laptop into.',
    'office_chairs': 'Proper desk chairs, not only cafe chairs.',
    'cozy': 'A warm, relaxed feel.',
    'swimming_pool': 'Guests can use a pool.',
    'no_traffic_noise': 'No road noise in the work area.',
    'low_background_music': 'Music, if any, is kept quiet.',
    'instagramable': 'A space people like to take photos of.',
    'vegan_friendly': 'Vegan food or drinks are on the menu.',
    'pass_required': 'Visitors need a day pass or membership to work here.',
  };

  /// The page's tags, with room for more: the ones ticked, then two or
  /// three that are not, shown faintly. Tapping any of them opens the
  /// list of what a space can say about itself (Jonathan, 5 Oct 2026).
  Widget _tagsBlock(List<String> tags, {bool tappable = true}) {
    // Drawn like the live page's tags (white, icon), a little smaller
    // for this preview; a suggestion is dashed, like "Add a tag".
    Widget chip(String text, {bool faint = false}) {
      final row = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(faint ? Icons.add : _tagIcon(text),
            size: 13,
            color: faint ? const Color(0xFF6B7280) : const Color(0xFFE0442E)),
        const SizedBox(width: 5),
        Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.2,
                color: faint
                    ? const Color(0xFF6B7280)
                    : const Color(0xFF2B2F36))),
      ]);
      const pad = EdgeInsets.fromLTRB(8, 5, 10, 5);
      if (faint) {
        return CustomPaint(
            painter: _DashedBorder(),
            child: Padding(padding: pad, child: row));
      }
      return Container(
        padding: pad,
        decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFE4E6EB)),
            borderRadius: BorderRadius.circular(8)),
        child: row,
      );
    }
    // "Laptop Friendly" is left out of the suggestions and of the list
    // that opens: every listing is a place to work by definition, and
    // it is not one of the tags an owner's change writes to the page.
    final missing = [
      for (final key in _liveTagOrder)
        if (_facts[key] != true) _siteTags[key] ?? key
    ];
    if (!tappable) {
      // The full-size view shows the page only: the tags it has.
      return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final t in tags) chip(t)]);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openTagGuide,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in tags) chip(t),
            for (final t in missing.take(tags.isEmpty ? 3 : 2))
              chip(t, faint: true),
          ]),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
                tags.isEmpty
                    ? 'No tags on your page yet. Tap to add the ones that '
                        'are true for your space.'
                    : 'Tap the tags to add more that are true for your '
                        'space.',
                style: const TextStyle(fontSize: 11, color: Brand.inkMuted)),
          ],
        ]),
      ),
    );
  }

  /// "What is true for your space?": every tag with what it means, to
  /// tick. The same facts as the list in the form.
  Future<void> _openTagGuide() => _ownerDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, redraw) => Theme(
            data: siteButtons(Theme.of(ctx), radius: 8),
            child: AlertDialog(
            title: const Text('What is true for your space?'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          'Each one you tick shows as a tag on your page '
                          'once you submit and we have read the change. '
                          'Tick only what a visitor would find true today.',
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: Brand.inkSecondary)),
                      const SizedBox(height: 8),
                      for (final (key, label) in _factLabels)
                        if (_liveTagOrder.contains(key))
                          CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(_siteTags[key] ?? label,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                          subtitle: Text(_factGuide[key] ?? label,
                              style: const TextStyle(fontSize: 12.5)),
                          value: _facts[key] == true,
                          onChanged: (x) {
                            setState(() {
                              _facts[key] = x == true;
                              _dirty = true;
                              _editSeq++;
                              _lastEdit = DateTime.now();
                            });
                            redraw(() {});
                          },
                        ),
                    ]),
              ),
            ),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: FilledButton.styleFrom(backgroundColor: Brand.red),
                  child: const Text('Done')),
            ],
          )),
        ),
      );

  /// The passes and prices already on the page, to look at. Changing
  /// them from the Owner account is not built yet (they are checked
  /// against the space's own website: docs/PRICE_CHECK.md).
  Widget _pageCard(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFEDEDED)),
        ),
        child: child,
      );

  Widget _pageButton(String label, {bool wide = false}) => Container(
        width: wide ? double.infinity : null,
        alignment: wide ? Alignment.center : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
            color: _pageRed, borderRadius: BorderRadius.circular(8)),
        child: Text(label,
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: Colors.white)),
      );

  static const double _slotW = 164, _slotH = 120;

  /// One photo in the editor: the picture, "Main photo" on the first,
  /// and Replace, Make main and Remove under it.
  Widget _photoSlot(int i, {double w = _slotW}) {
    final p = _photos[i];
    final h = w * _slotH / _slotW;
    final pic = Stack(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(p,
                width: w,
                height: h,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                    width: w,
                    height: h,
                    color: Brand.field,
                    child: const Icon(Icons.broken_image_outlined))),
          ),
          if (i == 0)
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .62),
                    borderRadius: BorderRadius.circular(6)),
                child: const Text('Main photo',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ),
        ]);
    // Drag a photo onto another to put it there. On a phone or tablet
    // it is press and hold first, so the page still scrolls under a
    // finger.
    final platform = Theme.of(context).platform;
    final touch = platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS;
    final feedback = Material(
      color: Colors.transparent,
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(p,
            width: w * .9,
            height: h * .9,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => SizedBox(width: w * .9, height: h * .9)),
      ),
    );
    final faded = Opacity(opacity: .35, child: pic);
    final Widget handle = _saving
        ? pic
        : touch
            ? LongPressDraggable<int>(
                data: i,
                feedback: feedback,
                childWhenDragging: faded,
                onDragEnd: (_) => setState(() => _photoDropAt = null),
                child: pic)
            : Draggable<int>(
                data: i,
                feedback: feedback,
                childWhenDragging: faded,
                onDragEnd: (_) => setState(() => _photoDropAt = null),
                child: MouseRegion(cursor: SystemMouseCursors.grab, child: pic));
    final target = DragTarget<int>(
      onWillAcceptWithDetails: (d) {
        if (d.data == i) return false;
        if (_photoDropAt != i) setState(() => _photoDropAt = i);
        return true;
      },
      onLeave: (_) {
        if (_photoDropAt == i) setState(() => _photoDropAt = null);
      },
      onAcceptWithDetails: (d) => _movePhoto(d.data, i),
      // Drawn over the photo, so the slot keeps its size.
      builder: (context, _, __) => Container(
        foregroundDecoration: _photoDropAt == i
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _pageRed, width: 3),
              )
            : null,
        child: handle,
      ),
    );
    return SizedBox(
      width: w,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        target,
        const SizedBox(height: 4),
        Row(children: [
          TextButton.icon(
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 32),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontSize: 12.5)),
            onPressed: _saving ? null : () => _replacePhoto(i),
            icon: const Icon(Icons.swap_horiz, size: 16),
            label: const Text('Replace'),
          ),
          const Spacer(),
          if (i > 0)
            IconButton(
              tooltip: 'Make this the main photo',
              style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: _saving ? null : () => _makeMainPhoto(i),
              icon: const Icon(Icons.star_outline),
            ),
          // The last photo stays: an empty list would leave the page's
          // photos as they are, the opposite of what removing means.
          IconButton(
            tooltip: _photos.length == 1
                ? 'A page needs at least one photo'
                : 'Remove this photo',
            style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: _saving || _photos.length == 1
                ? null
                : () => _confirmRemovePhoto(i),
            icon: const Icon(Icons.delete_outline),
          ),
        ]),
      ]),
    );
  }

  /// The free space after the photos: tap to add one or more.
  Widget _addPhotoSlot({double w = _slotW}) => SizedBox(
        width: w,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _saving ? null : _addPhotos,
          child: Container(
            height: w * _slotH / _slotW,
            decoration: BoxDecoration(
              color: Brand.field,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Brand.border),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.add_photo_alternate_outlined,
                  color: Brand.inkSecondary),
              const SizedBox(height: 4),
              Text(_photos.isEmpty ? 'Add photos' : 'Add a photo',
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Brand.inkSecondary)),
            ]),
          ),
        ),
      );

  /// One large photo and four small ones, as on the page.
  Widget _photoGrid(List<String> photos, {double height = 130}) {
    Widget img(int i) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: i < photos.length
              ? Image.network(photos[i],
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  errorBuilder: (_, __, ___) => Container(color: Brand.field))
              : Container(color: Brand.field),
        );
    if (photos.isEmpty) {
      return Container(
          height: 120,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: Brand.field, borderRadius: BorderRadius.circular(8)),
          child: const Text('No photos yet',
              style: TextStyle(color: Brand.inkMuted)));
    }
    return SizedBox(
      height: height,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(flex: 2, child: img(0)),
        const SizedBox(width: 4),
        Expanded(
          flex: 2,
          child: Column(children: [
            Expanded(
                child: Row(children: [
              Expanded(child: img(1)),
              const SizedBox(width: 4),
              Expanded(child: img(2)),
            ])),
            const SizedBox(height: 4),
            Expanded(
                child: Row(children: [
              Expanded(child: img(3)),
              const SizedBox(width: 4),
              Expanded(child: img(4)),
            ])),
          ]),
        ),
      ]),
    );
  }

  /// The description as the page sets it: a line starting "## " is a
  /// section heading ("Working at ..."), the rest are paragraphs.
  List<Widget> _descriptionBlocks() {
    final text = _description.text.trim();
    if (text.isEmpty) {
      return const [
        Text('Your description appears here.',
            style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
      ];
    }
    return [
      for (final line in text.split('\n').map((l) => l.trim()))
        if (line.isNotEmpty)
          line.startsWith('## ')
              ? Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: Text(line.substring(3),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          height: 1.25,
                          color: _pageInk)),
                )
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(line,
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.5, color: _pageInk)),
                ),
    ];
  }

  /// The sidebar: opening hours, the round link buttons, the enquiry
  /// button (Verified) and the advert slot.
  Widget _sidebar() {
    Widget circle(String key, IconData icon, Color color) => Container(
          width: 34,
          height: 34,
          margin: const EdgeInsets.only(right: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFE0E0E0))),
          child: _siteIcon(key, icon, color, size: 17),
        );
    final days = [
      for (final day in _days)
        if (_hours[day]!.text.trim().isNotEmpty) day
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _pageCard(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Opening Hours',
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: 15, color: _pageInk)),
        const SizedBox(height: 8),
        if (days.isEmpty)
          const Text('Your opening hours appear here.',
              style: TextStyle(fontSize: 12, color: Brand.inkMuted))
        else
          for (final day in days)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(children: [
                SizedBox(
                  width: 90,
                  child: Text(_dayNames[day]!,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _pageInk)),
                ),
                Expanded(
                  child: Text(_hours[day]!.text.trim(),
                      style: const TextStyle(fontSize: 12, color: _pageInk)),
                ),
              ]),
            ),
      ])),
      const SizedBox(height: 10),
      Row(children: [
        if (_website.text.trim().isNotEmpty)
          circle('link', Icons.link, _pageInk),
        circle('map', Icons.location_on, _pageRed),
        // Instagram shows on Premium pages only (agreed 23 Oct).
        if (_verified && _instagram.text.trim().isNotEmpty)
          circle('instagram', Icons.camera_alt_outlined,
              const Color(0xFFD62976)),
        if (_verified && _instagram.text.trim().isNotEmpty)
          Flexible(
            child: Text(_igShown(_instagram.text),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
          ),
      ]),
      if (_verified) ...[
        const SizedBox(height: 10),
        _pageButton('Send a request', wide: true),
      ],
      const SizedBox(height: 10),
      _advertSlot(),
    ]);
  }

  /// "@handle" however it was typed (a link, with or without the @).
  static String _igShown(String raw) {
    var h = raw.trim();
    final m = RegExp(r'instagram\.com/([^/?#\s]+)', caseSensitive: false)
        .firstMatch(h);
    if (m != null) h = m.group(1)!;
    return '@${h.replaceFirst(RegExp(r'^@+'), '')}';
  }

  /// The Google map, as the live page shows it: Google's free map
  /// embed (no key, no charge), searched by the space's name and
  /// area so it opens on the place with its card. Away from the web,
  /// the drawn stand-in below.
  Widget _mapBlock(Map<String, dynamic> v, String area) {
    final q = [
      '${v['name'] ?? ''}'.trim(),
      area,
      '${v['country'] ?? ''}'.trim(),
    ].where((x) => x.isNotEmpty).join(', ');
    if (q.isEmpty) return _drawnMap(v, area);
    final url = 'https://maps.google.com/maps?q=${Uri.encodeComponent(q)}'
        '&z=15&hl=en&output=embed';
    return MapEmbedView(url: url, height: 300, fallback: _drawnMap(v, area));
  }

  /// Where the Google map sits on the page, drawn like it: the place
  /// card top left, the red pin in the middle.
  Widget _drawnMap(Map<String, dynamic> v, String area) => Container(
        height: 150,
        decoration: BoxDecoration(
          color: const Color(0xFFE3F1E6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Stack(children: [
          Positioned(
            left: 8,
            top: 8,
            right: 60,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: Brand.shadowResting),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${v['name']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w700)),
                    if (area.isNotEmpty)
                      Text(area,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10.5, color: Brand.inkSecondary)),
                  ]),
            ),
          ),
          const Align(
            alignment: Alignment(0, 0.35),
            child: Icon(Icons.location_on, color: Color(0xFFD93025), size: 30),
          ),
          const Positioned(
            bottom: 6,
            left: 0,
            right: 0,
            child: Text('Google map',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10.5, color: Brand.inkMuted)),
          ),
        ]),
      );

  /// The advert slot as it shows today: a Premium page's own promotion
  /// or event when one is written, else the partner advert.
  Widget _advertSlot() {
    if (_verified && _mentionTitle.text.trim().isNotEmpty) {
      return _mentionCard();
    }
    // A free page: the real partner advert, as on the live page.
    if (!_verified) {
      final country = '${_venue?['country'] ?? ''}'.trim().toLowerCase();
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: Colors.white,
          constraints: const BoxConstraints(maxHeight: 420),
          child: Image.network(
              '$_adBase${_adByCountry[country] ?? _adDefault}',
              fit: BoxFit.contain,
              semanticLabel: 'The partner advert on this page',
              errorBuilder: (_, __, ___) => _advertPlaceholder()),
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF4A5A66),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Advert',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
        const SizedBox(height: 4),
        Text(
            _verified
                ? 'Your own event or offer replaces this advert. Write it '
                    'under Promotions and events.'
                : 'A partner advert shows here. Premium pages show their '
                    'own event or offer instead.',
            style: const TextStyle(
                fontSize: 12, height: 1.4, color: Color(0xFFDCE3E8))),
      ]),
    );
  }

  /// The card's small grey title, as on the live page.
  static const _promoLabel = Text('PROMOTIONS AND EVENTS',
      style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: .8,
          color: Color(0xFF757575)));

  /// The owner's promotion or event as nomadwise.io draws it in the
  /// sidebar of a Premium page (the site footer snippet, 24 Oct): a small
  /// red type tag, the headline, the text and an outlined red button.
  /// [card] adds the white card and its "Promotions and events" title,
  /// as the page shows it.
  Widget _mentionCard({bool card = true}) {
    final cta = _mentionCta.text.trim().isEmpty
        ? 'Find out more'
        : _mentionCta.text.trim();
    final item = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: const Color(0xFFFFF0F1),
            borderRadius: BorderRadius.circular(6)),
        child: Text(_mentionKind,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE0353F))),
      ),
      const SizedBox(height: 8),
      Text(_mentionTitle.text.trim(),
          style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              height: 1.3,
              color: Color(0xFF2B2F36))),
      if (_mentionBody.text.trim().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_mentionBody.text.trim(),
              style: const TextStyle(
                  fontSize: 14, height: 1.5, color: Color(0xFF555555))),
        ),
      if (_mentionUrl.text.trim().isNotEmpty) ...[
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFFF444F)),
              borderRadius: BorderRadius.circular(8)),
          child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
            Flexible(
              child: Text(cta,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFFFF444F))),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward, size: 16, color: Color(0xFFFF444F)),
          ]),
        ),
      ],
    ]);
    if (!card) return item;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE4E6EB)),
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _promoLabel,
        const SizedBox(height: 12),
        item,
      ]),
    );
  }

  // --------------------------------------------------------------- message

  /// Inbox & support (migration 161): the owner's chat with Nomadwise
  /// about this space. Opening it marks our messages as seen, which
  /// is what turns the number off and gives us the two ticks.
  Widget _chatTab(bool wide) {
    final v = _venue!;
    final id = '${v['id']}';
    final name = '${v['name'] ?? 'your space'}';
    final h = MediaQuery.sizeOf(context).height;
    return _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Inbox & support',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 4),
        Text(
            'Questions, changes you cannot make yourself, anything about '
            '$name on Nomadwise: write to us here.',
            style: const TextStyle(
                fontSize: 13.5, height: 1.45, color: Brand.inkSecondary)),
        const SizedBox(height: 14),
        if (_enquiriesOn) _enquiriesCard(),
        // An owner of several spaces: a message about another one
        // would otherwise wait unseen behind the space on screen.
        for (var i = 0; i < _venues.length; i++)
          if (i != _current && (_chatUnread['${_venues[i]['id']}'] ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(
                        'You also have an unread message about '
                        '${_venues[i]['name'] ?? 'another space'}.',
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                    TextButton(
                      onPressed: () {
                        setState(() => _current = i);
                        _fillEditor();
                      },
                      child: const Text('Open that chat'),
                    ),
                  ]),
            ),
        if (_isPreview)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
                'Preview: the owner writes to us here. Their messages '
                'and your answers are under Chats in the team tools.',
                style: TextStyle(fontSize: 13.5, color: Brand.inkMuted)),
          )
        else
          SizedBox(
            // room to read a few messages, without the box leaving
            // the screen on a phone
            height: (h - (wide ? 330 : 300)).clamp(340.0, 640.0).toDouble(),
            child: ChatThread(
              key: ValueKey('chat-$id'),
              team: false,
              load: () => _supabase.ownerChat(id),
              send: (body) => _supabase.ownerChatSend(id, body),
              onLoaded: (_) {
                // seen now: the number goes
                if (_chatWaiting > 0) _loadChatUnread();
              },
              note: 'Your message goes straight to the Nomadwise team. '
                  'Our reply appears here and is also emailed to you, so '
                  'you will not miss it.',
              emptyTitle: 'Write to Nomadwise',
              emptyText: 'Ask us anything about $name or its page. '
                  'Everything said here stays in this inbox.',
            ),
          ),
      ]),
    );
  }

  // ---------------------------------------------------- performance
  // Performance (migration 252, Jonathan 5 Nov 2026): how people find
  // and use the page. Shown in Google search (Search Console, a few
  // days behind), page views and Directions taps (our own counter in
  // prices.js, since 5 Nov 2026) and requests. A number that is 0 is
  // left out, and so is a card with nothing in it: only activity worth
  // showing. Always ends with "Get more from your page": what to add
  // next and the checklist (the same parts as the monthly email).

  static const _perfRed = Color(0xFFD42F3A); // red for small text
  static const _perfPeriods = [
    (30, 'Last 30 days', 'the 30 days before'),
    (91, '3 months', 'the 3 months before'),
    (365, '12 months', 'the 12 months before'),
  ];
  // The parts of a page, in checklist order: label, why it helps, the
  // part of My listing that adds it.
  static const _perfParts = {
    'photos': ('Photos', 'The first thing people look at', 'photos'),
    'hours': ('Opening hours', 'So people know when to come', 'hours'),
    'description': ('Description', 'What makes your space different', 'about'),
    'prices': ('Prices', 'People can pick one and ask about it', 'prices'),
    'wifi': ('Wi-Fi speed', 'The question remote workers ask most', ''),
  };
  // The next step, as a title, why it helps and the button.
  static const _perfNext = {
    'prices': (
      'Add your prices',
      'With prices on your page, people pick a day pass, desk or meeting '
          'room and send you a request about it in one go. It is the '
          'quickest way to turn a page view into a request.',
      'Add prices'
    ),
    'photos': (
      'Add photos',
      'Photos are the first thing people look at. Show your desks, the '
          'light and the coffee, so people can picture working there.',
      'Add photos'
    ),
    'description': (
      'Write your description',
      'Tell people what makes your space different: the feel, who works '
          'there and what is close by.',
      'Write it'
    ),
    'wifi': (
      'Test your Wi-Fi speed',
      'It is the first thing remote workers ask. Run the test at your '
          'space and the speed goes straight on your page.',
      'Run the test'
    ),
    'hours': (
      'Add your opening hours',
      'So people know when they can come.',
      'Add hours'
    ),
  };

  Map<String, dynamic>? _perf; // the numbers shown
  String? _perfShown; // venue and period the numbers are for
  String? _perfLoading; // venue and period being loaded
  String? _perfFailed; // venue and period that did not load
  int _perfDays = 30;

  String get _perfKey => '${_venue?['id']}-$_perfDays';

  Future<void> _loadPerf() async {
    final v = _venue;
    if (v == null) return;
    final key = _perfKey;
    if (_perfLoading == key) return;
    setState(() {
      _perfLoading = key;
      _perfFailed = null;
    });
    try {
      final r = await _supabase.ownerPerformance('${v['id']}', _perfDays);
      if (!mounted || _perfLoading != key) return;
      setState(() {
        _perf = r;
        _perfShown = key;
      });
    } catch (_) {
      if (mounted && _perfLoading == key) setState(() => _perfFailed = key);
    } finally {
      if (mounted && _perfLoading == key) setState(() => _perfLoading = null);
    }
  }

  static int _perfInt(Object? x) => x is num ? x.toInt() : int.tryParse('$x') ?? 0;

  /// 1234 as "1,234".
  static String _perfNum(int n) {
    final s = n.abs().toString();
    final b = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  /// "2 November" from "2026-11-02".
  String _perfDay(Object? raw) {
    final d = DateTime.tryParse('${raw ?? ''}');
    if (d == null) return '';
    return '${d.day} ${_monthNames[d.month - 1]}';
  }

  /// "Up 24% on the 30 days before", only when it went up.
  String? _perfUp(int now, Object? prevRaw) {
    if (prevRaw == null) return null;
    final prev = _perfInt(prevRaw);
    if (prev <= 0 || now <= prev) return null;
    final pct = ((now - prev) * 100 / prev).round();
    if (pct < 1) return null;
    final p = _perfPeriods.firstWhere((x) => x.$1 == _perfDays);
    return 'Up $pct% on ${p.$3}';
  }

  /// Opens My listing with that part ready to edit.
  void _perfAdd(String part) {
    if (part.isEmpty) {
      _wifiTest(); // measured at the space (migration 262)
      return;
    }
    _goTab(_Tab.listing);
    _startEdit(part);
  }

  Widget _performanceTab(bool wide) {
    final failed = _perfFailed == _perfKey;
    if (_perfShown != _perfKey && _perfLoading != _perfKey && !failed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tab == _Tab.performance) _loadPerf();
      });
    }
    final p = _perfShown == _perfKey ? _perf : null;
    final header = _perfHeader(wide);
    Widget body;
    if (p == null) {
      body = _panel(
        child: failed
            ? Row(children: [
                const Expanded(
                  child: Text('Your numbers did not load.',
                      style: TextStyle(fontSize: 14, color: Brand.inkSecondary)),
                ),
                TextButton(onPressed: _loadPerf, child: const Text('Try again')),
              ])
            : const SizedBox(
                height: 120,
                child: Center(
                    child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.5)))),
      );
    } else {
      body = _perfBody(p, wide);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      const SizedBox(height: 16),
      body,
    ]);
  }

  Widget _perfHeader(bool wide) {
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Performance',
          style: TextStyle(
              fontSize: wide ? 24 : 21,
              fontWeight: FontWeight.w800,
              color: Brand.ink)),
      const SizedBox(height: 4),
      const Text('How people find and use your page on nomadwise.io.',
          style: TextStyle(fontSize: 14, height: 1.45, color: Brand.inkSecondary)),
    ]);
    // Three equal buttons; on a phone they fill the width.
    final periods = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: Brand.field, borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: wide ? MainAxisSize.min : MainAxisSize.max, children: [
        for (final x in _perfPeriods)
          _perfPeriodButton(x.$1, x.$2, wide),
      ]),
    );
    if (wide) {
      return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(child: title),
        const SizedBox(width: 16),
        periods,
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      title,
      const SizedBox(height: 12),
      periods,
    ]);
  }

  Widget _perfPeriodButton(int days, String label, bool wide) {
    final on = _perfDays == days;
    final b = Semantics(
      button: true,
      selected: on,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: on
            ? null
            : () {
                _trk.step('period', {'days': days}, _venueId);
                setState(() => _perfDays = days);
              },
        child: Container(
          width: wide ? 112 : null,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: on
                ? const [BoxShadow(color: Color(0x14000000), blurRadius: 3, offset: Offset(0, 1))]
                : null,
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                  color: on ? Brand.ink : Brand.inkSecondary)),
        ),
      ),
    );
    return wide ? b : Expanded(child: b);
  }

  Widget _perfBody(Map<String, dynamic> p, bool wide) {
    final live = p['live'] == true;
    final plus = p['plus'] == true;
    final google = _perfInt(p['google']);
    final views = _perfInt(p['views']);
    final dirs = _perfInt(p['directions']);
    final sent = _perfInt(p['requests']);
    final held = _perfInt(p['requests_held']);
    const upNote = TextStyle(
        fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E7A46));
    const plainNote = TextStyle(fontSize: 13, height: 1.4, color: Brand.inkSecondary);
    // label, number, note, note style
    final stats = <(String, int, String, TextStyle)>[
      if (google > 0)
        (
          'Shown in Google',
          google,
          _perfUp(google, p['google_prev']) ?? 'Times your page was in Google results',
          _perfUp(google, p['google_prev']) != null ? upNote : plainNote
        ),
      if (views > 0)
        (
          'Page views',
          views,
          _perfUp(views, p['views_prev']) ?? 'Times people opened your page',
          _perfUp(views, p['views_prev']) != null ? upNote : plainNote
        ),
      if (dirs > 0)
        ('Directions', dirs, 'Tapped Directions on your page', plainNote),
      if (sent + held > 0)
        (
          'Requests',
          sent + held,
          held > 0
              ? '$sent sent to you, $held waiting for Premium'
              : sent == 1
                  ? 'Sent to you by email'
                  : 'All sent to you by email',
          held > 0
              ? const TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600, color: _perfRed)
              : plainNote
        ),
    ];

    final months = [
      for (final m in (p['months'] as List? ?? const []))
        if (m is Map) Map<String, dynamic>.from(m)
    ];
    final monthsWithData =
        months.where((m) => _perfInt(m['google']) > 0 || _perfInt(m['views']) > 0).length;
    final queries = [
      for (final q in (p['queries'] as List? ?? const []))
        if (q is Map && '${q['q'] ?? ''}'.trim().isNotEmpty && _perfInt(q['n']) > 0)
          ('${q['q']}'.trim(), _perfInt(q['n']))
    ];
    final latest = [
      for (final r in (p['latest'] as List? ?? const []))
        if (r is Map) Map<String, dynamic>.from(r)
    ];
    final free = p['free'] is Map ? Map<String, dynamic>.from(p['free'] as Map) : const <String, dynamic>{};
    final freeUsed = _perfInt(free['used']);
    final freeLimit = _perfInt(free['limit']);
    final showFree = !plus && free['on'] == true && freeLimit > 0 && freeUsed > 0;

    final children = <Widget>[];
    if (!live) {
      children.add(_panel(
        tint: Brand.field,
        child: const Text(
            'Your page is not live on nomadwise.io yet. Your numbers start '
            'here once it is.',
            style: TextStyle(fontSize: 14, height: 1.5, color: Brand.ink)),
      ));
    } else if (stats.isEmpty) {
      final period = _perfPeriods.firstWhere((x) => x.$1 == _perfDays).$2.toLowerCase();
      children.add(_panel(
        child: Text(
            'Nothing to show for the ${period == 'last 30 days' ? period : 'last $period'} '
            'yet. New pages take a few weeks to show up in Google. Each part '
            'you add below gives Google and people more reason to pick your page.',
            style: const TextStyle(fontSize: 14, height: 1.5, color: Brand.ink)),
      ));
    } else {
      children.add(LayoutBuilder(builder: (context, c) {
        // Four to a row on a computer, two on a phone; a lone number
        // keeps its card size instead of stretching across the page.
        // Cards in a row share one height, so they line up (Jonathan,
        // 6 Nov 2026: Shown in Google and Page views were uneven).
        final cols = c.maxWidth >= 720 ? 4 : 2;
        const gap = 12.0;
        final rows = <Widget>[];
        for (var i = 0; i < stats.length; i += cols) {
          if (rows.isNotEmpty) rows.add(const SizedBox(height: gap));
          rows.add(IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var j = 0; j < cols; j++) ...[
                if (j > 0) const SizedBox(width: gap),
                Expanded(
                    child: i + j < stats.length
                        ? _perfStat(stats[i + j].$1, stats[i + j].$2,
                            stats[i + j].$3, stats[i + j].$4)
                        : const SizedBox.shrink()),
              ],
            ]),
          ));
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
      }));
    }
    if (showFree) {
      children.add(const SizedBox(height: 12));
      children.add(_perfFreeNote(freeUsed, freeLimit));
    }

    final chart = monthsWithData >= 2 && live
        ? _perfMonths(months, '${p['unit'] ?? 'month'}')
        : null;
    final searches = queries.isNotEmpty ? _perfSearches(queries) : null;
    final reqs = latest.isNotEmpty ? _perfLatest(latest) : null;
    final more = _perfMore(p['parts']);

    Widget pair(Widget? a, Widget? b, {int fa = 3, int fb = 2}) {
      if (a == null && b == null) return const SizedBox.shrink();
      if (a == null || b == null) return a ?? b!;
      if (!wide) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          a,
          const SizedBox(height: 16),
          b,
        ]);
      }
      return IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(flex: fa, child: a),
          const SizedBox(width: 16),
          Expanded(flex: fb, child: b),
        ]),
      );
    }

    if (chart != null || searches != null) {
      children.add(const SizedBox(height: 16));
      children.add(pair(chart, searches));
    }
    children.add(const SizedBox(height: 16));
    children.add(pair(reqs, more, fa: 1, fb: 1));

    // Where the numbers come from.
    final notes = <String>[
      if (p['google_to'] != null)
        'Google numbers come from Google Search Console and run a few days '
            'behind (latest day: ${_perfDay(p['google_to'])}).',
      if (p['views_from'] != null)
        'Page views and Directions taps are counted by Nomadwise since '
            '${_perfDay(p['views_from'])}, without cookies. Page views '
            'before then come from our website statistics, also without '
            'cookies.',
    ];
    if (notes.isNotEmpty && live) {
      children.add(const SizedBox(height: 16));
      children.add(Text(notes.join(' '),
          style: const TextStyle(fontSize: 12.5, height: 1.5, color: Brand.inkMuted)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _perfStat(String label, int n, String note, TextStyle noteStyle) => Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Brand.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Brand.inkSecondary)),
          const SizedBox(height: 8),
          Text(_perfNum(n),
              style: const TextStyle(
                  fontSize: 30, height: 1.1, fontWeight: FontWeight.w800, color: Brand.ink)),
          const SizedBox(height: 6),
          Text(note, style: noteStyle),
        ]),
      );

  Widget _perfFreeNote(int used, int limit) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(
            color: Brand.accentTint, borderRadius: BorderRadius.circular(8)),
        child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                  'You have used ${used > limit ? limit : used} of your $limit free requests. '
                  'With Premium, every request comes straight to you.',
                  style: const TextStyle(fontSize: 13.5, height: 1.45, color: Brand.ink)),
              TextButton(
                onPressed: () => _goTab(_Tab.membership),
                style: TextButton.styleFrom(
                    foregroundColor: _perfRed,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                child: const Text('See what Premium adds'),
              ),
            ]),
      );

  /// The last 6 months: Shown in Google (red) and page views (dark),
  /// side by side, on one scale. This month is so far.
  /// The chart under the numbers. It follows the period buttons
  /// (Jonathan, 6 Nov 2026): Last 30 days by day, 3 months by week,
  /// 12 months by month (owner_performance's 'unit', migration 270).
  Widget _perfMonths(List<Map<String, dynamic>> months, String unit) {
    var top = 1;
    for (final m in months) {
      top = [top, _perfInt(m['google']), _perfInt(m['views'])].reduce((a, b) => a > b ? a : b);
    }
    const h = 150.0;
    DateTime at(int i) => DateTime.tryParse('${months[i]['month']}') ?? DateTime(2026);
    String mon(DateTime d) => _monthNames[d.month - 1].substring(0, 3);
    String label(int i) => switch (unit) {
          'day' => '${at(i).day}',
          'week' => '${at(i).day} ${mon(at(i))}',
          _ => mon(at(i)),
        };
    String tip(int i) {
      final d = at(i);
      final last = i == months.length - 1;
      final when = switch (unit) {
        'day' => last ? 'Today' : '${d.day} ${mon(d)}',
        'week' => last ? 'This week so far' : 'Week of ${d.day} ${mon(d)}',
        _ => '${_monthNames[d.month - 1]}${last ? ' so far' : ''}',
      };
      return '$when: ${_perfNum(_perfInt(months[i]['google']))} in Google, '
          '${_perfNum(_perfInt(months[i]['views']))} page views';
    }

    Widget key(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 6),
          Text(t, style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        ]);
    return _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 14,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(switch (unit) { 'day' => 'By day', 'week' => 'By week', _ => 'By month' },
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: Brand.ink)),
              key(Brand.red, 'Shown in Google'),
              key(Brand.ink, 'Page views'),
            ]),
        const SizedBox(height: 18),
        LayoutBuilder(builder: (context, c) {
          final n = months.isEmpty ? 1 : months.length;
          final slot = c.maxWidth / n;
          // Two bars per slot, as wide as there is room for (thin for
          // 30 days on a phone, 14px for 12 months on a computer).
          final gap = slot >= 14 ? 3.0 : 1.0;
          final barW = ((slot * 0.7 - gap) / 2).clamp(2.0, 14.0);
          // About one label per 44px, counted back from the newest.
          final every = (44 / slot).ceil().clamp(1, n);
          Widget bar(int v, Color col) => Container(
                width: barW,
                height: v <= 0 ? 0.0 : (h * v / top).clamp(3.0, h),
                decoration: BoxDecoration(
                    color: col,
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(barW >= 8 ? 4 : 2))),
              );
          return Column(children: [
            SizedBox(
              height: h,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                for (var i = 0; i < months.length; i++)
                  Expanded(
                    child: Tooltip(
                      message: tip(i),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            bar(_perfInt(months[i]['google']), Brand.red),
                            SizedBox(width: gap),
                            bar(_perfInt(months[i]['views']), Brand.ink),
                          ]),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 16,
              child: Row(children: [
                for (var i = 0; i < months.length; i++)
                  Expanded(
                    child: (months.length - 1 - i) % every == 0
                        ? OverflowBox(
                            maxWidth: 60,
                            child: Text(label(i),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: i == months.length - 1
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: Brand.inkSecondary)),
                          )
                        : const SizedBox.shrink(),
                  ),
              ]),
            ),
          ]);
        }),
        const SizedBox(height: 6),
        Text(
            switch (unit) {
              'day' => 'Google runs a few days behind, so the newest days show page '
                  'views only.',
              'week' => 'This week is so far.',
              _ => 'This month is so far.',
            },
            style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
      ]),
    );
  }

  Widget _perfSearches(List<(String, int)> qs) {
    final top = qs.first.$2 <= 0 ? 1 : qs.first.$2;
    return _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('What people searched for',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Brand.ink)),
        const SizedBox(height: 4),
        const Text('Google searches that showed your page, last 3 months',
            style: TextStyle(fontSize: 13, color: Brand.inkSecondary)),
        const SizedBox(height: 14),
        for (final q in qs) ...[
          Row(children: [
            Expanded(
              child: Text(q.$1,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, color: Brand.ink)),
            ),
            const SizedBox(width: 10),
            Text(_perfNum(q.$2),
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700, color: Brand.ink)),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: q.$2 / top,
              minHeight: 6,
              backgroundColor: Brand.field,
              valueColor: const AlwaysStoppedAnimation(Brand.red),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ]),
    );
  }

  Widget _perfLatest(List<Map<String, dynamic>> rows) {
    Widget chip(String t, Color fg, Color bg) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
          child: Text(t,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: fg)),
        );
    return _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Latest requests',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Brand.ink)),
        const SizedBox(height: 6),
        for (var i = 0; i < rows.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : const Border(top: BorderSide(color: Color(0xFFECEDF0)))),
            child: Row(children: [
              SizedBox(
                width: 54,
                child: Text(
                    () {
                      final d = DateTime.tryParse('${rows[i]['at'] ?? ''}')?.toLocal();
                      return d == null
                          ? ''
                          : '${d.day} ${_monthNames[d.month - 1].substring(0, 3)}';
                    }(),
                    style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
              ),
              Expanded(
                child: Text(
                    rows[i]['status'] == 'held'
                        ? 'A request is waiting for you'
                        : '${rows[i]['what'] ?? ''}'.trim().isNotEmpty
                            ? '${rows[i]['what']}'
                            : 'A request from your page',
                    style: const TextStyle(fontSize: 14, height: 1.35, color: Brand.ink)),
              ),
              const SizedBox(width: 8),
              switch ('${rows[i]['status']}') {
                'held' => chip('Held for Premium', _perfRed, Brand.accentTint),
                'sent' => chip('Sent to you', const Color(0xFF1E7A46), Brand.successTint),
                _ => chip('On its way', Brand.inkSecondary, Brand.field),
              },
            ]),
          ),
      ]),
    );
  }

  /// "Get more from your page": the next part to add, why it helps,
  /// and the checklist (Jonathan: paint the picture that adding more
  /// brings more).
  Widget _perfMore(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    final parts = [
      for (final x in (m['parts'] as List? ?? const []))
        if (x is Map && _perfParts.containsKey('${x['key']}'))
          ('${x['key']}', x['done'] == true, (x['count'] as num?)?.toInt() ?? 0)
    ];
    final done = parts.where((x) => x.$2).length;
    final total = parts.isEmpty ? 5 : parts.length;
    final next = '${m['next'] ?? ''}';
    var step = _perfNext[next];
    // Photos count as done at five, the page's gallery (Jonathan,
    // 6 Nov 2026; migration 266): with one to four, say how many more.
    final photoCount = parts.fold<int>(0, (n, x) => x.$1 == 'photos' ? x.$3 : n);
    if (next == 'photos' && photoCount >= 1 && photoCount < 5) {
      final more = 5 - photoCount;
      step = (
        'Add $more more photo${more == 1 ? '' : 's'}',
        'Your page has room for five photos and shows $photoCount. A full '
            'gallery shows people what it is like to work there, and photos '
            'are the first thing they look at.',
        'Add photos'
      );
    }
    return _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(
            child: Text('Get more from your page',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Brand.ink)),
          ),
          Text('$done of $total done',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: Brand.inkSecondary)),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: done / total,
            minHeight: 8,
            backgroundColor: const Color(0xFFECEDF0),
            valueColor: const AlwaysStoppedAnimation(Brand.red),
          ),
        ),
        const SizedBox(height: 14),
        if (step != null)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Brand.red, width: 1.5)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('NEXT STEP',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .8,
                      color: _perfRed)),
              const SizedBox(height: 6),
              Text(step.$1,
                  style: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w700, color: Brand.ink)),
              const SizedBox(height: 4),
              Text(step.$2,
                  style: const TextStyle(fontSize: 13.5, height: 1.5, color: Brand.inkSecondary)),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () => _perfAdd(_perfParts[next]!.$3),
                style: FilledButton.styleFrom(
                    backgroundColor: Brand.red,
                    minimumSize: const Size(0, 40),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: Text(step.$3),
              ),
            ]),
          )
        else
          const Text(
              'Your page has everything people look for. Keep your prices and '
              'photos up to date, and it keeps working for you.',
              style: TextStyle(fontSize: 13.5, height: 1.5, color: Brand.inkSecondary)),
        const SizedBox(height: 12),
        for (var i = 0; i < parts.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : const Border(top: BorderSide(color: Color(0xFFECEDF0)))),
            child: Row(children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: parts[i].$2 ? const Color(0xFF1E7A46) : Colors.white,
                  border: parts[i].$2
                      ? null
                      : Border.all(color: const Color(0xFFC9CED4), width: 2),
                ),
                child: parts[i].$2
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_perfParts[parts[i].$1]!.$1,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: parts[i].$2 ? FontWeight.w400 : FontWeight.w600,
                          color: parts[i].$2 ? Brand.inkSecondary : Brand.ink)),
                  const SizedBox(height: 2),
                  Text(
                      parts[i].$1 == 'photos' && !parts[i].$2 && parts[i].$3 > 0
                          ? '${parts[i].$3} of 5 added. The first thing people look at'
                          : _perfParts[parts[i].$1]!.$2,
                      style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
                ]),
              ),
              if (!parts[i].$2)
                TextButton(
                  onPressed: () => _perfAdd(_perfParts[parts[i].$1]!.$3),
                  style: TextButton.styleFrom(
                      foregroundColor: _perfRed,
                      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  child: Text(parts[i].$1 == 'wifi' ? 'Test' : 'Add'),
                ),
            ]),
          ),
      ]),
    );
  }

  // ------------------------------------------------------- settings
  // Settings (migration 251): the sign-in email, where requests go, and
  // which emails the owner gets. New requests and the emails about their
  // claim and page are always sent; the others have a switch. Laid out
  // as one column, so it reads the same on a phone.

  Future<void> _loadEmailPrefs() async {
    if (_isPreview) return;
    try {
      final p = await _supabase.ownerEmailPrefs();
      if (mounted) setState(() => _emailPrefs = p);
    } catch (_) {
      // the switches show their defaults; a change tries again
    }
  }

  Future<void> _setEmailPref(String key, bool on) async {
    if (_isPreview) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Preview: nothing is saved. The owner turns '
              'their emails on and off here.')));
      return;
    }
    final before = _emailPrefs;
    setState(() {
      _prefBusy = key;
      _emailPrefs = {...?_emailPrefs, key: on};
    });
    try {
      final p = await _supabase.ownerSetEmailPref(key, on);
      if (mounted) setState(() => _emailPrefs = p);
    } catch (e) {
      if (!mounted) return;
      setState(() => _emailPrefs = before);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That did not save. Please try again.')));
    } finally {
      if (mounted) setState(() => _prefBusy = null);
    }
  }

  Widget _settingRow(String title, String note,
      {String? key, bool first = false}) {
    final on = key == null ? true : (_emailPrefs?[key] ?? true);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
          border: first
              ? null
              : const Border(top: BorderSide(color: Color(0xFFECEDF0)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600, color: Brand.ink)),
            const SizedBox(height: 3),
            Text(note,
                style: const TextStyle(
                    fontSize: 13, height: 1.45, color: Brand.inkSecondary)),
          ]),
        ),
        const SizedBox(width: 12),
        if (key == null)
          const Text('Always on',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Brand.inkSecondary))
        else
          Semantics(
            label: title,
            toggled: on,
            child: Switch(
              value: on,
              activeColor: Colors.white,
              activeTrackColor: Brand.red,
              onChanged:
                  _prefBusy == key ? null : (v) => _setEmailPref(key, v),
            ),
          ),
      ]),
    );
  }

  /// One line of "Your space" in Settings: what it is now, and a way to
  /// ask for a change.
  Widget _spaceRow(String title, String now, String kind, {bool first = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
            border: first
                ? null
                : const Border(top: BorderSide(color: Color(0xFFECEDF0)))),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
              const SizedBox(height: 2),
              Text(now.isEmpty ? 'Not set' : now,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w600, color: Brand.ink)),
            ]),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: () => _requestChange(kind),
            style: TextButton.styleFrom(
                foregroundColor: _perfRed,
                textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            child: const Text('Request a change'),
          ),
        ]),
      );

  /// Add a location (Jonathan, 6 Nov 2026): from the space's name
  /// menu, the link at the foot of the side menu and All locations. The
  /// claim form opens inside the app with the sign-in email filled in,
  /// so the new place lands in this account once Nomadwise has checked it.
  Future<void> _addLocation() async {
    if (_isPreview) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Preview: the owner would go to the claim form to '
              'add a location.')));
      return;
    }
    _cap('owner_add_location', {'spaces': _venues.length});
    final email = _signInEmail;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ClaimScreen(
            addLocation: true, email: email.contains('@') ? email : null)));
    if (mounted) _load(); // an approved new location shows straight away
  }

  Widget _settingsTab(bool wide) {
    const head = TextStyle(
        fontWeight: FontWeight.w700, fontSize: 16, color: Brand.ink);
    const muted = TextStyle(
        fontSize: 13.5, height: 1.5, color: Brand.inkSecondary);
    final email = _signInEmail;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Account', style: head),
            const SizedBox(height: 12),
            const Text('You sign in with',
                style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
            const SizedBox(height: 2),
            Text(email.isEmpty ? 'Your email' : email,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600, color: Brand.ink)),
            const SizedBox(height: 16),
            _enquiriesCard(),
          ]),
        ),
        const SizedBox(height: 16),
        // Name and location: owners ask, we check (Jonathan, 5 Nov 2026:
        // these belong in Settings, not on the listing).
        _panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Your space', style: head),
            const SizedBox(height: 4),
            const Text(
                'Nomadwise checks these before they change on your page.',
                style: muted),
            const SizedBox(height: 8),
            _spaceRow('Name', '${_venue?['name'] ?? ''}', 'name', first: true),
            _spaceRow(
                'Location',
                [
                  for (final k in ['neighbourhood', 'city', 'country'])
                    if ('${_venue?[k] ?? ''}'.trim().isNotEmpty)
                      '${_venue?[k]}'.trim()
                ].join(', '),
                'location'),
          ]),
        ),
        const SizedBox(height: 16),
        _panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Emails from Nomadwise', style: head),
            const SizedBox(height: 4),
            Text(
                _isPreview
                    ? 'Preview: these are the owner\'s switches. Nothing changes here.'
                    : 'Turn off anything you do not want. Changes save straight away.',
                style: muted),
            const SizedBox(height: 8),
            _settingRow('New requests from people',
                'Each request someone sends from your page. You need these to reply to them.',
                first: true),
            _settingRow('Updates about your page',
                'When your page is approved, a change goes live, or something needs your answer.'),
            _settingRow('Replies from Nomadwise',
                'When we answer a message you sent in Inbox & support. You can always read them there.',
                key: 'chat_replies'),
            _settingRow('Monthly performance',
                'At the start of each month: how often your page was seen and asked about, and what to add next.',
                key: 'monthly'),
            _settingRow('Tips for your page',
                'Now and then: the next thing to add, your numbers when you have been away, and your first request.',
                key: 'tips'),
          ]),
        ),
      ]),
    );
  }

  // ------------------------------------------------ website badges
  // CR-26 (5 Nov 2026): Leonie's badges with the Nomadwise logo (her
  // final files, 5 Nov: pill 210/212x44, square 104x104, corners 8px).
  // Free pages get "Find us on nomadwise.io", Premium pages "Verified by
  // nomadwise.io" with the red tick. Each comes as one line or square,
  // with code to paste on the space's website (a plain link to its
  // page) and a media pack ZIP for Instagram and Facebook. The images are
  // in app/web/badges (nomadmaps.io/badges/...). The code on the owner's
  // website uses the SVG (sharp at any size); the preview here and the
  // media pack use PNGs made from the same SVGs.

  static const _badgeBase = 'https://nomadmaps.io/badges/';

  String _badgeCode(String file, int w, int h, String alt) {
    final v = _venue ?? const {};
    final page = 'https://www.nomadwise.io/coworking/${v['webflow_slug']}';
    final name = '${v['name'] ?? 'Our space'}'
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;');
    // Gets smaller in a narrow space (a phone, a thin sidebar), never
    // bigger than its own size.
    return '<a href="$page" target="_blank" rel="noopener" '
        'title="$name on Nomadwise" style="display:inline-block;'
        'max-width:100%;line-height:0"><img src="$_badgeBase$file.svg" '
        'alt="$alt" width="$w" height="$h" '
        'style="border:0;max-width:100%;height:auto"></a>';
  }

  // Leonie's three styles (2 Nov): White works on any website; Red stands
  // out on light ones; Outline (white lines, see-through) for dark websites
  // and photos.
  static const _badgeStyles = [
    ('white', 'White', '', 'Works on any website'),
    ('red', 'Red', '-red', 'Stands out on light websites'),
    ('outline', 'Outline', '-outline', 'For dark websites and photos'),
  ];

  Widget _badgeCard(String title, String note, String base, int w, int h,
      String alt) {
    final style = _badgeStyle[base] ?? 'white';
    final pick = _badgeStyles.firstWhere((x) => x.$1 == style);
    final file = '$base${pick.$3}';
    return Container(
        // fits a phone: never wider than the screen allows
        width: (MediaQuery.sizeOf(context).width - 64).clamp(220.0, 320.0),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Brand.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 4),
          Text(note,
              style: const TextStyle(
                  fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final st in _badgeStyles)
              ChoiceChip(
                label: Text(st.$2),
                selected: style == st.$1,
                showCheckmark: false,
                selectedColor: Brand.ink,
                labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: style == st.$1 ? Colors.white : Brand.ink),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                onSelected: (_) =>
                    setState(() => _badgeStyle[base] = st.$1),
              ),
          ]),
          const SizedBox(height: 6),
          Text(pick.$4,
              style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
          const SizedBox(height: 10),
          Container(
            height: 150,
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: style == 'outline'
                    ? const Color(0xFF151A21)
                    : Brand.bg,
                borderRadius: BorderRadius.circular(8)),
            child: Image.network('$_badgeBase$file.png',
                width: w.toDouble(),
                height: h.toDouble(),
                semanticLabel: alt,
                errorBuilder: (_, __, ___) => Text(alt,
                    style: const TextStyle(color: Brand.inkSecondary))),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 6, children: [
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                    ClipboardData(text: _badgeCode(file, w, h, alt)));
                _cap('owner_badge_copied',
                    {'space': _venue?['name'], 'badge': file});
                // at once, so the founders' ping is not 15 seconds late
                _trk.flush();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Code copied. Paste it into your website '
                        'where you want the badge to show.')));
              },
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              icon: const Icon(Icons.code, size: 18),
              label: const Text('Copy code'),
            ),
            OutlinedButton(
              onPressed: () => setState(() {
                if (!_badgeCodeShown.remove(file)) _badgeCodeShown.add(file);
              }),
              child: Text(
                  _badgeCodeShown.contains(file) ? 'Hide code' : 'View code'),
            ),
          ]),
          if (_badgeCodeShown.contains(file)) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: const Color(0xFF151A21),
                  borderRadius: BorderRadius.circular(8)),
              child: SelectableText(_badgeCode(file, w, h, alt),
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.5,
                      color: Color(0xFFD7E3EC))),
            ),
          ],
        ]),
      );
  }

  Widget _badgesTab() {
    final v = _venue;
    final live = v != null &&
        '${v['webflow_slug'] ?? ''}'.isNotEmpty &&
        v['website_status'] == 'released';
    final kind = _verified ? 'verified' : 'find';
    final words = _verified ? 'Verified by' : 'Find us on';
    const help = TextStyle(
        fontSize: 13.5, height: 1.5, color: Brand.inkSecondary);
    return _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Website badges',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 8),
        Text(
            _verified
                ? 'Show visitors to your website that your space is '
                    'Verified by nomadwise.io. The badge links to your page '
                    'on Nomadwise.'
                : 'Show visitors to your website that they can find your '
                    'space on nomadwise.io. The badge links to your page on '
                    'Nomadwise.',
            style: help),
        const SizedBox(height: 18),
        if (!live)
          const Text(
              'Your badge will be ready here as soon as your page is live '
              'on nomadwise.io.',
              style: help)
        else ...[
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 660),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            // Neutral, with green ticks: these are benefits, and a red
            // box reads as a warning (Jonathan, 12 Nov 2026).
            decoration: BoxDecoration(
                color: const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE8EBEF))),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Why add a badge?',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14.5)),
                  const SizedBox(height: 6),
                  Text(
                      _verified
                          ? 'It shows visitors that Nomadwise, a guide for '
                              'remote workers, has verified your space, which '
                              'builds trust.'
                          : 'It shows visitors that your space is listed on '
                              'a guide for remote workers, which builds '
                              'trust.',
                      style: const TextStyle(
                          fontSize: 13.5, height: 1.5, color: Brand.ink)),
                  const SizedBox(height: 8),
                  for (final line in const [
                    'Copy and paste, no technical skills needed',
                    'Works on phones and computers',
                    'White, red or outline, to match your website',
                    'Gets smaller by itself in narrow spaces',
                    'Links to your page on Nomadwise, with your photos and '
                        'reviews',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Icon(Icons.check,
                                  size: 16, color: Brand.success),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(line,
                                  style: const TextStyle(
                                      fontSize: 13.5,
                                      height: 1.45,
                                      color: Brand.inkSecondary)),
                            ),
                          ]),
                    ),
                ]),
          ),
          const SizedBox(height: 18),
          Wrap(spacing: 16, runSpacing: 16, children: [
            _badgeCard(
                'One line',
                'Fits a footer or a sidebar. ${_verified ? 212 : 210} pixels '
                    'wide.',
                '$kind-line',
                _verified ? 212 : 210,
                44,
                '$words nomadwise.io'),
            _badgeCard(
                'Square',
                'For a corner or a column. 104 by 104 pixels.',
                '$kind-square',
                104,
                104,
                '$words nomadwise.io'),
          ]),
          const SizedBox(height: 18),
          const Text('How to add it to your website',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 6),
          const Text(
              'Press Copy code, then paste it into an HTML or embed block '
              'on your website, for example in your footer. On Wix that is '
              'Embed HTML, on Squarespace a Code block and on WordPress a '
              'Custom HTML block.',
              style: help),
          const SizedBox(height: 22),
          const Text('Download media pack',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 6),
          const Text(
              'For Instagram, Facebook or anywhere else that does not take '
              'code: both badges in all three styles, as large PNG images, '
              'plus SVG files for designers.',
              style: help),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {
              _cap('owner_badge_pack',
                  {'space': _venue?['name'], 'plan': kind});
              _trk.flush();
              launchUrl(Uri.parse('${_badgeBase}nomadwise-media-pack-'
                  '${_verified ? 'premium' : 'free'}.zip'));
            },
            style: FilledButton.styleFrom(backgroundColor: Brand.ink),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('Download media pack (ZIP)'),
          ),
          const SizedBox(height: 10),
          const Text(
              'Free to use. If you post it, tag @nomadwise.io on Instagram '
              'and we will share it.',
              style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
          if (!_verified) ...[
            const SizedBox(height: 14),
            const Text(
                'Premium spaces get the Verified by nomadwise.io badge, '
                'with a red tick.',
                style: TextStyle(fontSize: 13, color: Brand.inkMuted)),
          ],
        ],
      ]),
    );
  }

  Widget _messageTab(bool wide) {
    if (!_verified) {
      return _panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Promotions and events, in place of an advert',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 8),
          const Text(
              'Premium pages carry the space\'s own event, offer or '
              'announcement where nomadwise.io would otherwise show an '
              'advert. Yours shows the advert. Get Premium and this tab '
              'opens up, along with the Verified by Nomadwise badge, top '
              'positioning on your region\'s page and unlimited '
              'requests straight to your inbox.',
              style: TextStyle(
                  fontSize: 13.5, height: 1.5, color: Brand.inkSecondary)),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: () => _saveThenOpen('https://nomadmaps.io/?claim='
                  '${Uri.encodeComponent('${_venue?['webflow_slug'] ?? _venue?['name'] ?? ''}')}'),
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              // Jonathan, 12 Nov 2026: "maybe this says 'Unlock with
              // Premium'" (was "Get Premium").
              child: const Text('Unlock with Premium')),
        ]),
      );
    }
    final editor = _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Promotions and events, in place of an advert',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 4),
        const Text(
            'An event, an offer or an announcement. It replaces the advert '
            'slot on your page. Other placements on the site stay. We read '
            'it before it goes on, like everything else.',
            style: TextStyle(
                color: Brand.inkSecondary, fontSize: 12.5, height: 1.45)),
        const SizedBox(height: 18),
        SizedBox(
          width: 260,
          child: DropdownButtonFormField<String>(
            value: _mentionKind,
            decoration: _dec('Type'),
            items: const [
              DropdownMenuItem(value: 'Event', child: Text('Event')),
              DropdownMenuItem(value: 'Offer', child: Text('Offer')),
              DropdownMenuItem(
                  value: 'Announcement', child: Text('Announcement')),
            ],
            onChanged: (x) => setState(() {
              _mentionKind = x ?? 'Event';
              _dirty = true;
            }),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
            controller: _mentionTitle,
            maxLength: 90,
            buildCounter: _nearLimit,
            decoration: _dec('Headline',
                    hint: 'Join our Friday community lunch')
                .copyWith(
                    helperText: 'Short and specific, like the name of the '
                        'event or the offer.')),
        const SizedBox(height: 14),
        TextField(
            controller: _mentionBody,
            minLines: 3,
            maxLines: 6,
            maxLength: 300,
            buildCounter: _nearLimit,
            decoration: _dec('Message',
                    hint: 'Meet other remote workers over a relaxed lunch at '
                        'our space. Everyone is welcome.')
                .copyWith(
                    helperText: 'A sentence or two: what, when, and who it '
                        'is for.')),
        const SizedBox(height: 14),
        // The button and where it goes, side by side when there is
        // room; their helper lines keep the two the same height.
        LayoutBuilder(builder: (context, box) {
          final cta = TextField(
              controller: _mentionCta,
              maxLength: 40,
              buildCounter: _nearLimit,
              decoration: _dec('Button label', hint: 'Book a spot')
                  .copyWith(helperText: 'What the button says.'));
          final link = TextField(
              controller: _mentionUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration:
                  _dec('Button link', hint: 'https://yourspace.com/events')
                      .copyWith(helperText: 'Where the button takes people.'));
          if (box.maxWidth < 520) {
            return Column(children: [cta, const SizedBox(height: 14), link]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 220, child: cta),
            const SizedBox(width: 12),
            Expanded(child: link),
          ]);
        }),
        const SizedBox(height: 16),
        if (_savedNote != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_savedNote!,
                style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
          ),
        // Save draft and Submit also sit at the top (the action bar);
        // this one saves scrolling back up after the last field.
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
              onPressed: _saving ? null : () => _save(submit: true),
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              child: Text(_saving
                  ? 'One moment'
                  : widget.team
                      ? 'Save to the page'
                      : 'Submit for review')),
        ),
        const SizedBox(height: 8),
        const Text('To take the message down, clear the headline and submit.',
            style: TextStyle(color: Brand.inkMuted, fontSize: 12)),
      ]),
    );
    return editor;
  }

  /// A field's character count, shown only once it is close to the
  /// limit (an always-on "0/40" pushed the fields out of line).
  Widget? _nearLimit(BuildContext context,
          {required int currentLength,
          required bool isFocused,
          required int? maxLength}) =>
      maxLength == null || currentLength < (maxLength * .8).floor()
          ? null
          : Text('${maxLength - currentLength} characters left',
              style: TextStyle(
                  fontSize: 12,
                  color: currentLength >= maxLength
                      ? const Color(0xFFB42318)
                      : Brand.inkMuted));

  Widget _messagePreview() => _panel(
        tint: Brand.bg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('What nomads see',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 4),
          const Text(
              'Your promotion or event takes the advert\'s place at the '
              'foot of your '
              'page\'s sidebar: on the right on a computer, after the '
              'details on a phone.',
              style: TextStyle(color: Brand.inkMuted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 12),
          if (_mentionTitle.text.trim().isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Brand.logoTealTint,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                    'Write a headline and your message replaces the advert '
                    'below.',
                    style: TextStyle(fontSize: 12.5, color: Brand.logoNavy)),
              ),
            ),
          _sidebar(),
        ]),
      );

}

enum _Step { done, now, todo }


/// One price in the Owner account's price list (migration 218).
class _PriceRow {
  final String? id; // the price on the page; null for a new one
  String category;
  bool from;

  /// Per hour, day, week, month or year; null when not said. Kept as
  /// the first detail line on the page ("Per month").
  String? per;
  // Named by the owner: filed by its name until they move it.
  bool autoType;
  bool showNote = false;
  final nameFocus = FocusNode();
  final priceFocus = FocusNode();
  final noteFocus = FocusNode();
  final TextEditingController name;
  final TextEditingController amount;
  final TextEditingController note;
  _PriceRow({
    this.id,
    this.category = 'coworking',
    this.from = false,
    this.per,
    this.autoType = false,
    String name = '',
    String amount = '',
    String note = '',
  })  : name = TextEditingController(text: name),
        amount = TextEditingController(text: amount),
        note = TextEditingController(text: note);

  bool get isBlank =>
      id == null &&
      name.text.trim().isEmpty &&
      amount.text.trim().isEmpty &&
      note.text.trim().isEmpty;

  /// The amount as a plain number for the database: "1,500" is 1500,
  /// "40k" is 40000; empty is "price on request".
  String get _plainAmount {
    // Tidied the way the box tidies it when left, in case Save is
    // pressed while still typing ("3,6" is 3.60, "1.000" is 1,000).
    var t = Price.cleanAmount(amount.text).replaceAll(',', '');
    final k = RegExp(r'^(\d+(?:\.\d+)?)[kK]$').firstMatch(t);
    if (k != null) {
      final n = double.parse(k.group(1)!) * 1000;
      t = n == n.roundToDouble() ? '${n.round()}' : n.toStringAsFixed(2);
    }
    return t;
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name.text.trim(),
        'category': category,
        'amount': _plainAmount,
        'starting_from': from,
        'details': withPer(per, [
          if (note.text.trim().isNotEmpty) note.text.trim(),
        ]),
      };

  void dispose() {
    name.dispose();
    amount.dispose();
    note.dispose();
    nameFocus.dispose();
    priceFocus.dispose();
    noteFocus.dispose();
  }
}


/// The page's dashed "Add a tag" outline (1px #C9CDD4, 6px corners).
class _DashedBorder extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFC9CDD4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, const Radius.circular(6)));
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 4), paint);
        d += 7;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

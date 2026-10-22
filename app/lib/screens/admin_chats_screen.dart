import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/chat_thread.dart';
import '../widgets/site_chats_pane.dart';

/// The founders' side of the chat with owners (migration 161): every
/// space that has an owner, the chats waiting for an answer first.
/// Jonathan, 7 Oct 2026: "a list of open chats ... a link I can save
/// down to my home screen on my phone" (nomadmaps.io/chats). On a
/// phone a chat opens over the list; on a wide screen it sits beside
/// it. The list looks again every quarter of a minute.
class AdminChatsScreen extends StatefulWidget {
  /// Opened by itself from nomadmaps.io/chats (no control centre
  /// underneath): the bar then offers the way there.
  final bool standalone;
  const AdminChatsScreen({super.key, this.standalone = false});

  @override
  State<AdminChatsScreen> createState() => _AdminChatsScreenState();
}

class _AdminChatsScreenState extends State<AdminChatsScreen> {
  final _supabase = SupabaseService();
  final _search = TextEditingController();
  Timer? _timer;
  List<Map<String, dynamic>> _chats = const [];
  bool _loading = true;
  bool _looking = false;
  String? _error;
  String? _open; // the space whose chat is beside the list (wide)

  // Owners (migration 202): Open (anything not marked done) or Done,
  // as on the Website tab. The spaces with no messages yet are kept
  // folded away at the bottom of Open (Jonathan, 22 Oct 2026).
  bool _doneView = false;
  bool _showQuiet = false;

  static bool _isDone(Map<String, dynamic> c) => c['done'] == true;

  // The phone notice that an owner is in their Owner account opens
  // /chats/#space-<id>, which arrives here as ?space=<id> (migration
  // 198): that chat opens once the list is in.
  String? _wantSpace = _startSpace();

  static String? _startSpace() {
    try {
      final s = (Uri.base.queryParameters['space'] ?? '').trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  // Owners (migration 161) or Website (the chat box on nomadwise.io,
  // migration 190). A phone notice about a website chat opens
  // /chats/#site, which lands on the Website tab.
  String _tab = _startTab();
  int _siteWaiting = 0;

  static String _startTab() {
    try {
      // nomadmaps.io/chats/#site forwards to /?admin=chats&tab=site
      return Uri.base.queryParameters['tab'] == 'site' ? 'site' : 'owners';
    } catch (_) {
      return 'owners';
    }
  }

  static const double _wideFrom = 860;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
    _supabase.adminSiteChatsWaiting().then((n) {
      if (mounted) setState(() => _siteWaiting = n);
    });
  }

  /// Owners | Website: a segmented switch with room above it, so it
  /// does not sit on the bar's line, and looks different from the
  /// Open / Done filters under it (Jonathan, 22 Oct 2026).
  Widget _tabs() {
    Widget seg(String text, String key, {int count = 0}) {
      final on = _tab == key;
      return GestureDetector(
        onTap: () => setState(() => _tab = key),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            decoration: BoxDecoration(
              color: on ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              boxShadow: on
                  ? const [
                      BoxShadow(
                          color: Color(0x1F142032),
                          blurRadius: 6,
                          offset: Offset(0, 1)),
                    ]
                  : null,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(text,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                      color: on ? Brand.ink : Brand.inkSecondary)),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                      color: Brand.red,
                      borderRadius: BorderRadius.circular(10)),
                  child: Text('$count',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w800)),
                ),
              ],
            ]),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
              color: Brand.field,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Brand.border)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            seg('Owners', 'owners'),
            seg('Website', 'site', count: _siteWaiting),
          ]),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_looking) return;
    _looking = true;
    try {
      final rows = await _supabase.adminChats();
      if (!mounted) return;
      // the Website tab's number, also while the Owners tab is open
      _supabase.adminSiteChatsWaiting().then((n) {
        if (mounted && n != _siteWaiting) setState(() => _siteWaiting = n);
      });
      setState(() {
        _chats = rows;
        _loading = false;
        _error = null;
      });
      final want = _wantSpace;
      if (want != null) {
        _wantSpace = null;
        final c = rows.where((x) => '${x['venue_id']}' == want).firstOrNull;
        if (c != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _openChat(c, MediaQuery.sizeOf(context).width >= _wideFrom);
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      // only the first failure is worth a word; the next look is near
      if (_loading) {
        setState(() {
          _loading = false;
          _error = 'The chats could not be loaded: $e';
        });
      }
    } finally {
      _looking = false;
    }
  }

  static String _short(DateTime at) {
    final now = DateTime.now();
    final day = DateTime.utc(at.year, at.month, at.day);
    final today = DateTime.utc(now.year, now.month, now.day);
    final days = today.difference(day).inDays;
    if (days == 0) return DateFormat('HH:mm').format(at);
    if (days == 1) return 'Yesterday';
    return DateFormat(at.year == now.year ? 'd MMM' : 'd MMM y').format(at);
  }

  String _who(Map<String, dynamic> c) {
    final name = '${c['owner_name'] ?? ''}'.trim();
    final place = [
      '${c['city'] ?? ''}'.trim(),
      '${c['country'] ?? ''}'.trim(),
    ].where((x) => x.isNotEmpty).join(', ');
    return [if (name.isNotEmpty) name, if (place.isNotEmpty) place]
        .join(' · ');
  }

  /// First lines for "Say hello" (migration 198), the best fit first:
  /// after a change they made, while they are here, or just checking in.
  static List<String> _starters(Map<String, dynamic> c) {
    final first = '${c['owner_name'] ?? ''}'.trim().split(' ').first;
    final hi = first.isEmpty ? 'Hi there' : 'Hi $first';
    final changed = DateTime.tryParse('${c['changed_at'] ?? ''}');
    final recent = changed != null &&
        DateTime.now().toUtc().difference(changed.toUtc()).inHours < 48;
    final lines = <String>[
      if (recent)
        "$hi, I hope you're having a good day. I just saw that you made some "
            'updates to your listing. Is everything okay, and is there '
            'anything you need?',
      "$hi, I hope you're having a good day. I'm around now if you have "
          'any questions about your Owner account or your page.',
      '$hi, I hope all is well. Just checking in: is there anything we can '
          'help with on your Nomadwise page?',
    ];
    return lines;
  }

  static const _hereColor = Color(0xFF1E8E3E);

  static Widget _hereLine({double size = 12}) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                  color: _hereColor, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text('In their Owner account now',
              style: TextStyle(
                  fontSize: size,
                  fontWeight: FontWeight.w600,
                  color: _hereColor)),
        ],
      );

  Widget _thread(Map<String, dynamic> c) {
    final id = '${c['venue_id']}';
    final owner = '${c['owner_name'] ?? ''}'.trim();
    final hasOwner = '${c['owner_email'] ?? ''}'.trim().isNotEmpty;
    return ChatThread(
      key: ValueKey('chat-$id'),
      team: true,
      load: () async =>
          SupabaseService.chatRowsOf(await _supabase.adminChat(id)),
      send: (body) async =>
          SupabaseService.chatRowsOf(await _supabase.adminChatSend(id, body)),
      onLoaded: (_) {
        // opened: their messages are seen, so the list's number goes
        final i = _chats.indexWhere((x) => '${x['venue_id']}' == id);
        if (i >= 0 && ((_chats[i]['unread'] as num?) ?? 0) > 0) _load();
      },
      note: 'What you write appears in their Owner account, and is '
          'emailed to them about a minute after your last message, '
          'unless they are reading along here.',
      emptyTitle: 'No messages yet',
      emptyText: owner.isEmpty
          ? 'Write first if you like. They are emailed what you write.'
          : 'Write to $owner first if you like. They are emailed what '
              'you write.',
      closedText: hasOwner
          ? null
          : 'This space has no owner any more, so nothing can be sent.',
      starters: hasOwner ? _starters(c) : const [],
    );
  }

  Future<void> _setDone(Map<String, dynamic> c, bool done) async {
    final id = '${c['venue_id']}';
    try {
      await _supabase.adminChatDone(id, done);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(done
              ? 'Chat closed. A new message reopens it.'
              : 'Chat reopened.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That did not save: $e'),
          backgroundColor: Brand.red));
    }
  }

  /// Mark done / Reopen, for a chat with messages.
  Widget? _doneButton(Map<String, dynamic> c) {
    if (c['last_at'] == null) return null;
    final done = _isDone(c);
    return TextButton.icon(
        onPressed: () => _setDone(c, !done),
        icon: Icon(done ? Icons.undo : Icons.check_circle_outline, size: 16),
        label: Text(done ? 'Reopen chat' : 'Close chat'));
  }

  Widget _header(Map<String, dynamic> c) {
    final email = '${c['owner_email'] ?? ''}'.trim();
    final who = _who(c);
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
      Text('${c['name'] ?? 'Space'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
      if (c['here'] == true)
        Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 1),
            child: _hereLine(size: 12.5)),
      if (who.isNotEmpty || email.isNotEmpty)
        Text([if (who.isNotEmpty) who, if (email.isNotEmpty) email].join('  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
                color: Brand.inkSecondary)),
    ]);
  }

  void _openChat(Map<String, dynamic> c, bool wide) {
    final id = '${c['venue_id']}';
    if (wide) {
      setState(() => _open = id);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Brand.surface,
          appBar: AppBar(titleSpacing: 0, title: _header(c), actions: [
            if (c['last_at'] != null)
              IconButton(
                  tooltip: _isDone(c) ? 'Reopen chat' : 'Close chat',
                  onPressed: () async {
                    await _setDone(c, !_isDone(c));
                    // back to the list, which now shows it in its place
                    if (mounted) Navigator.of(context).maybePop();
                  },
                  icon: Icon(_isDone(c) ? Icons.undo : Icons.check)),
          ]),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: _thread(c),
            ),
          ),
        ),
      ),
    ).then((_) {
      if (mounted) _load();
    });
  }

  Widget _row(Map<String, dynamic> c, bool wide) {
    final id = '${c['venue_id']}';
    final unread = ((c['unread'] as num?) ?? 0).toInt();
    final at = DateTime.tryParse('${c['last_at'] ?? ''}')?.toLocal();
    final last = '${c['last_body'] ?? ''}'.trim();
    final mineLast = c['last_team'] == true;
    final on = wide && _open == id;
    final who = _who(c);
    return InkWell(
      onTap: () => _openChat(c, wide),
      child: Container(
        color: on ? Brand.accentTint : null,
        padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${c['name'] ?? 'Space'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight:
                              unread > 0 ? FontWeight.w800 : FontWeight.w700)),
                  if (c['here'] == true)
                    Padding(
                        padding: const EdgeInsets.only(top: 1, bottom: 1),
                        child: _hereLine()),
                  if (who.isNotEmpty)
                    Text(who,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Brand.inkMuted)),
                  if (last.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text('${mineLast ? 'You: ' : ''}$last',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.35,
                              fontWeight: unread > 0
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: unread > 0
                                  ? Brand.ink
                                  : Brand.inkSecondary)),
                    ),
                ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (at != null)
              Text(_short(at),
                  style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
            if (unread > 0)
              Container(
                margin: const EdgeInsets.only(top: 5),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                decoration: BoxDecoration(
                    color: Brand.red, borderRadius: BorderRadius.circular(10)),
                child: Text('$unread',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800)),
              ),
          ]),
        ]),
      ),
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 12, 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .8,
                color: Brand.inkMuted)),
      );

  Widget _list(bool wide) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Brand.red));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final q = _search.text.trim().toLowerCase();
    bool hit(Map<String, dynamic> c) =>
        q.isEmpty ||
        '${c['name'] ?? ''} ${c['owner_name'] ?? ''} '
                '${c['owner_email'] ?? ''} ${c['city'] ?? ''} '
                '${c['country'] ?? ''}'
            .toLowerCase()
            .contains(q);
    final everyone = _chats.where(hit).toList();
    final searching = q.isNotEmpty;
    Widget chip(String text, bool on, VoidCallback tap) => ChoiceChip(
        label: Text(text,
            style: TextStyle(
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                color: on ? Colors.white : Brand.ink)),
        selected: on,
        showCheckmark: false,
        selectedColor: Brand.ink,
        backgroundColor: Brand.surface,
        onSelected: (_) => tap());
    final doneCount = everyone.where(_isDone).length;
    final filters = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Wrap(spacing: 6, children: [
        chip('Open chats', !_doneView, () {
          if (_doneView) setState(() => _doneView = false);
        }),
        chip(doneCount > 0 ? 'Closed chats ($doneCount)' : 'Closed chats',
            _doneView, () {
          if (!_doneView) setState(() => _doneView = true);
        }),
      ]),
    );
    final searchBox = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search, size: 20),
            hintText: 'Search by space or owner',
            isDense: true,
            border: OutlineInputBorder()),
      ),
    );

    // Done: the chats marked done (newest first), nothing else.
    if (_doneView && !searching) {
      final done = everyone.where(_isDone).toList()
        ..sort((a, b) => '${b['done_at'] ?? ''}'.compareTo('${a['done_at'] ?? ''}'));
      return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        filters,
        searchBox,
        if (done.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
                'No closed chats yet. Open a chat and press Close chat '
                'when it needs nothing more; a new message brings it back.',
                style: TextStyle(color: Brand.inkSecondary, height: 1.45)),
          )
        else ...[
          _heading('CLOSED FOR NOW'),
          for (final c in done) _row(c, wide),
        ],
      ]);
    }

    // Open (or a search, which looks through everything).
    // Online now shows even a chat marked done: that is when a hello
    // is most natural.
    final here = everyone.where((c) => c['here'] == true).toList();
    final rest = everyone
        .where((c) => c['here'] != true && (searching || !_isDone(c)))
        .toList();
    final waiting = rest.where((c) => c['waiting'] == true).toList();
    final going = rest
        .where((c) => c['waiting'] != true && c['last_at'] != null)
        .toList();
    final quiet = rest.where((c) => c['last_at'] == null).toList();
    final showQuiet = _showQuiet || searching;
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      filters,
      searchBox,
      if (everyone.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
              q.isNotEmpty
                  ? 'No space or owner matches that.'
                  : 'No chats yet. A space appears here once it has an '
                      'owner; they write to you from Inbox & support in '
                      'their Owner account, or you write first.',
              style: const TextStyle(
                  color: Brand.inkSecondary, height: 1.45)),
        )
      else if (here.isEmpty && waiting.isEmpty && going.isEmpty && !searching)
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 18, 24, 6),
          child: Text('All caught up: no open chats.',
              style: TextStyle(color: Brand.inkSecondary, height: 1.45)),
        ),
      if (here.isNotEmpty) ...[
        _heading('IN THEIR OWNER ACCOUNT NOW'),
        for (final c in here) _row(c, wide),
      ],
      if (waiting.isNotEmpty) ...[
        _heading('WAITING FOR YOU'),
        for (final c in waiting) _row(c, wide),
      ],
      if (going.isNotEmpty) ...[
        _heading(waiting.isNotEmpty
            ? 'ANSWERED'
            : here.isNotEmpty
                ? 'OTHER CHATS'
                : 'CHATS'),
        for (final c in going) _row(c, wide),
      ],
      // The spaces with an owner and no messages yet: folded away, to
      // write first when wanted.
      if (quiet.isNotEmpty) ...[
        if (!searching)
          InkWell(
            onTap: () => setState(() => _showQuiet = !_showQuiet),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 12, 6),
              child: Row(children: [
                Text('NO MESSAGES YET (${quiet.length})',
                    style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .8,
                        color: Brand.inkMuted)),
                const SizedBox(width: 4),
                Icon(_showQuiet ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: Brand.inkMuted),
                const Spacer(),
                Text(_showQuiet ? 'Hide' : 'Show, to write first',
                    style: const TextStyle(
                        fontSize: 12, color: Brand.inkMuted)),
              ]),
            ),
          )
        else
          _heading('NO MESSAGES YET'),
        if (showQuiet) for (final c in quiet) _row(c, wide),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= _wideFrom;
      final open = wide && _open != null
          ? _chats.where((c) => '${c['venue_id']}' == _open).firstOrNull
          : null;
      return Scaffold(
        backgroundColor: Brand.surface,
        appBar: AppBar(
          title: const Text('Chats'),
          actions: [
            // Do chat notices reach the phone, with a sound? One test
            // notice (migration 207).
            IconButton(
                tooltip: 'Send a test notice to my phone',
                onPressed: () async {
                  final m = ScaffoldMessenger.of(context);
                  try {
                    await _supabase.adminNotifyTest();
                    m.showSnackBar(const SnackBar(
                        duration: Duration(seconds: 8),
                        content: Text('Test notice sent. It should arrive on '
                            'your phone within a few seconds, with a sound. '
                            'Nothing? Open the ntfy app and check it is '
                            'subscribed to nomadmaps-83076iwunm, with '
                            'notifications and sound allowed.')));
                  } catch (e) {
                    m.showSnackBar(SnackBar(
                        content: Text('Could not send it: $e'),
                        backgroundColor: Brand.red));
                  }
                },
                icon: const Icon(Icons.notifications_active_outlined)),
            IconButton(
                tooltip: 'Look again',
                onPressed: _load,
                icon: const Icon(Icons.refresh)),
            if (widget.standalone)
              IconButton(
                  tooltip: 'Control centre',
                  onPressed: () => launchUrl(Uri.parse('/?admin'),
                      webOnlyWindowName: '_self'),
                  icon: const Icon(Icons.dashboard_outlined)),
          ],
        ),
        body: SafeArea(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _tabs(),
            Expanded(
          child: _tab == 'site'
              ? SiteChatsPane(
                  onCount: (n) {
                    if (mounted && n != _siteWaiting) {
                      setState(() => _siteWaiting = n);
                    }
                  })
              : !wide
              ? _list(false)
              : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(width: 360, child: _list(true)),
                  const VerticalDivider(width: 1, color: Brand.hairline),
                  Expanded(
                    child: open == null
                        ? const Center(
                            child: Text('Choose a chat on the left.',
                                style: TextStyle(color: Brand.inkMuted)),
                          )
                        : Padding(
                            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(child: _header(open)),
                                        if (_doneButton(open) != null)
                                          _doneButton(open)!,
                                      ]),
                                  const Divider(height: 18, color: Brand.hairline),
                                  Expanded(child: _thread(open)),
                                ]),
                          ),
                  ),
                ]),
            ),
          ]),
        ),
      );
    });
  }
}

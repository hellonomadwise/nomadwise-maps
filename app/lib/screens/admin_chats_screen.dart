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

  // Colours set here: left to the theme, the chosen chip was dark text
  // on a dark chip and could not be read (seen on a phone, 20 Oct).
  static Widget _chip(String text, bool on, VoidCallback tap) => ChoiceChip(
      label: Text(text,
          style: TextStyle(
              fontSize: 13.5,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              color: on ? Colors.white : Brand.ink)),
      selected: on,
      showCheckmark: false,
      selectedColor: Brand.ink,
      backgroundColor: Brand.surface,
      onSelected: (_) => tap());

  Widget _tabs() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(children: [
          _chip('Owners', _tab == 'owners',
              () => setState(() => _tab = 'owners')),
          const SizedBox(width: 8),
          _chip(_siteWaiting > 0 ? 'Website ($_siteWaiting)' : 'Website',
              _tab == 'site', () => setState(() => _tab = 'site')),
        ]),
      );

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
    );
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
          appBar: AppBar(titleSpacing: 0, title: _header(c)),
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
    final all = _chats.where(hit).toList();
    final waiting = all.where((c) => c['waiting'] == true).toList();
    final going = all
        .where((c) => c['waiting'] != true && c['last_at'] != null)
        .toList();
    final quiet = all.where((c) => c['last_at'] == null).toList();
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
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
      ),
      if (all.isEmpty)
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
        ),
      if (waiting.isNotEmpty) ...[
        _heading('WAITING FOR YOU'),
        for (final c in waiting) _row(c, wide),
      ],
      if (going.isNotEmpty) ...[
        _heading(waiting.isEmpty ? 'CHATS' : 'ANSWERED'),
        for (final c in going) _row(c, wide),
      ],
      if (quiet.isNotEmpty) ...[
        _heading('NO MESSAGES YET'),
        for (final c in quiet) _row(c, wide),
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
                                  _header(open),
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

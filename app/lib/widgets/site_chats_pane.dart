import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/site_chat_blog_pages_screen.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import 'chat_thread.dart';
import 'phone_field.dart';

/// The chats from the chat box on nomadwise.io (migration 190), on the
/// Chats screen's Website tab. Jonathan, 20 Oct 2026: "A Chats inbox
/// in the nomadmaps admin, in the same tick-off style as the control
/// centre. From there I can take over any conversation and reply live,
/// or by email if they've left the site."
///
/// The ones waiting for a founder come first (the assistant asked for
/// a person, or they wrote after a founder took over). Each row has a
/// tick to mark it done; done chats are one tap away and can be
/// reopened. Writing in a chat takes it over from the assistant.
class SiteChatsPane extends StatefulWidget {
  /// Told how many chats are waiting, for the tab's number.
  final void Function(int waiting)? onCount;
  const SiteChatsPane({super.key, this.onCount});

  @override
  State<SiteChatsPane> createState() => _SiteChatsPaneState();
}

class _SiteChatsPaneState extends State<SiteChatsPane> {
  final _supabase = SupabaseService();
  Timer? _timer;
  List<Map<String, dynamic>> _chats = const [];
  bool _done = false;
  bool _loading = true;
  bool _looking = false;
  String? _error;
  String? _open; // the chat beside the list (wide)
  // The open chat's details (mode, email, page), as last loaded.
  final Map<String, Map<String, dynamic>> _meta = {};
  // Ticks whenever _meta changes, so a chat opened over the list (on a
  // phone, a page of its own) redraws its header too.
  final _metaTick = ValueNotifier<int>(0);

  void _setMeta(String id, Map<String, dynamic> meta) {
    if (!mounted) return;
    setState(() => _meta[id] = meta);
    _metaTick.value++;
  }

  static const double _wideFrom = 860;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _metaTick.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_looking) return;
    _looking = true;
    final done = _done;
    try {
      final rows = await _supabase.adminSiteChats(done: done);
      if (!mounted) return;
      if (done != _done) {
        // Open / Done was switched while this look was on its way.
        _looking = false;
        unawaited(_load());
        return;
      }
      setState(() {
        _chats = rows;
        _loading = false;
        _error = null;
      });
      if (!_done) {
        widget.onCount?.call(rows.where((c) => c['waiting'] == true).length);
      }
    } catch (e) {
      if (!mounted) return;
      if (_loading) {
        setState(() {
          _loading = false;
          _error = 'The website chats could not be loaded: $e';
        });
      }
    } finally {
      _looking = false;
    }
  }

  void _snack(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  Future<void> _set(String id,
      {String? mode,
      String? status,
      String? email,
      String? phone,
      String? toast}) async {
    try {
      final r = await _supabase.adminSiteChatSet(id,
          mode: mode, status: status, email: email, phone: phone);
      if (!mounted) return;
      _setMeta(id, Map<String, dynamic>.from((r['chat'] as Map?) ?? const {}));
      if (toast != null) _snack(toast);
      await _load();
    } catch (e) {
      _snack('That did not save: $e', bad: true);
    }
  }

  /// Their email and their WhatsApp or phone number, by hand
  /// (migration 200: the assistant asks for the best way to reach
  /// them, and either is fine).
  Future<void> _askContact(String id, String? email, String? phone) async {
    final em = TextEditingController(text: email ?? '');
    final ph = TextEditingController(text: phone ?? '');
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('How to reach them'),
              content: SizedBox(
                width: 420,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: em,
                      autofocus: true,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                          labelText: 'Email',
                          hintText: 'name@example.com',
                          helperText: 'Your replies are emailed here once '
                              'they have left the site.')),
                  const SizedBox(height: 12),
                  TextField(
                      controller: ph,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                          labelText: 'WhatsApp or phone',
                          hintText: '+44 7700 900123',
                          helperText: 'With the country code. Nothing is sent '
                              'to it automatically: Open WhatsApp to write.')),
                ]),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Save')),
              ],
            ));
    final e = em.text.trim();
    final p = ph.text.trim();
    // after the dialog has finished closing
    Future.delayed(const Duration(milliseconds: 500), () {
      em.dispose();
      ph.dispose();
    });
    if (ok != true) return;
    await _set(id, email: e, phone: p, toast: 'Saved.');
  }

  /// A WhatsApp chat with this number, in a new tab (migration 201).
  /// A number without a country code (07591 915767) asks which country
  /// it is from first, and is saved with the code, so next time it is
  /// one press.
  Future<void> _openWhatsApp(String id, String phone) async {
    var digits = PhoneField.whatsAppDigits(phone);
    String? fixed;
    if (digits == null) {
      fixed = await _askCountry(phone);
      if (fixed == null) return;
      digits = PhoneField.whatsAppDigits(fixed);
      if (digits == null) return;
    }
    // Opened first: a browser may block a new tab opened after a wait.
    await launchUrl(Uri.parse('https://wa.me/$digits'),
        mode: LaunchMode.externalApplication);
    if (fixed != null) await _set(id, phone: fixed, toast: 'Saved as $fixed.');
  }

  /// "Which country is this number from?", with the number as it will
  /// be saved shown before anything happens.
  Future<String?> _askCountry(String phone) async {
    String? iso;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final code = PhoneField.dialFor(iso);
        final result = iso == null ? null : PhoneField.withCountry(iso, phone);
        return AlertDialog(
          title: const Text('Which country is this number from?'),
          content: SizedBox(
            width: 420,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('They wrote: $phone',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  const Text(
                      'WhatsApp needs the country code. Choose the country and '
                      'the number is saved with it, so next time it opens '
                      'straight away.',
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.45,
                          color: Brand.inkSecondary)),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final c = await PhoneField.pickCountry(ctx);
                      if (c != null) setD(() => iso = c);
                    },
                    icon: const Icon(Icons.public, size: 16),
                    label: Text(code == null
                        ? 'Choose the country'
                        : '${PhoneField.nameFor(iso) ?? iso} (+$code)'),
                  ),
                  if (result != null) ...[
                    const SizedBox(height: 10),
                    Text('It will be saved as $result',
                        style: const TextStyle(
                            fontSize: 13, color: Brand.inkSecondary)),
                  ],
                ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed:
                    result == null ? null : () => Navigator.pop(ctx, result),
                child: const Text('Save and open WhatsApp')),
          ],
        );
      }),
    );
  }

  static String _short(DateTime at) {
    final now = DateTime.now();
    final day = DateTime(at.year, at.month, at.day);
    final today = DateTime(now.year, now.month, now.day);
    final days = today.difference(day).inDays;
    if (days == 0) return DateFormat('HH:mm').format(at);
    if (days == 1) return 'Yesterday';
    return DateFormat(at.year == now.year ? 'd MMM' : 'd MMM y').format(at);
  }

  static String _title(Map<String, dynamic> c) {
    final name = '${c['visitor_name'] ?? ''}'.trim();
    final email = '${c['visitor_email'] ?? ''}'.trim();
    final phone = '${c['visitor_phone'] ?? ''}'.trim();
    if (name.isNotEmpty) return name;
    if (email.isNotEmpty) return email;
    if (phone.isNotEmpty) return phone;
    return c['who'] == 'owner' ? 'A space owner' : 'A visitor';
  }

  static String _page(Map<String, dynamic> c) {
    final space = '${c['space_name'] ?? ''}'.trim();
    if (space.isNotEmpty) return space;
    var t = '${c['page_title'] ?? ''}'.trim();
    t = t.replaceAll(RegExp(r'\s*[|]\s*Nomadwise.*$'), '');
    if (t.isNotEmpty) return t;
    final u = '${c['page_url'] ?? ''}'.replaceFirst(RegExp(r'^https?://'), '');
    return u;
  }

  Widget _chip(String text, Color fg, Color bg) => Container(
        margin: const EdgeInsets.only(right: 5, top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
      );

  /// Started on a blog article (migration 192), not a coworking page.
  static bool _blog(Map<String, dynamic> c) =>
      '${c['page_url'] ?? ''}'.contains('/blog/');

  List<Widget> _chips(Map<String, dynamic> c) => [
        if (c['waiting'] == true) _chip('Needs you', Colors.white, Brand.red),
        if (_blog(c)) _chip('Blog article', Brand.violet, Brand.field),
        if (c['here'] == true)
          _chip('On the site now', Brand.success, Brand.successTint),
        if (c['who'] == 'owner')
          _chip('Runs a space', Brand.goldTextDark, Brand.goldTint),
        if (c['who'] == 'visitor' && !_blog(c))
          _chip('Looking for a place', Brand.inkSecondary, Brand.field),
        if (c['mode'] == 'team')
          _chip('You are answering', Brand.ink, Brand.accentTint)
        else
          _chip('Assistant answering', Brand.inkSecondary, Brand.field),
      ];

  Widget _thread(Map<String, dynamic> c) {
    final id = '${c['id']}';
    return ChatThread(
      key: ValueKey('site-chat-$id'),
      team: true,
      load: () async {
        final r = await _supabase.adminSiteChat(id);
        final meta = Map<String, dynamic>.from((r['chat'] as Map?) ?? const {});
        _setMeta(id, meta);
        return SupabaseService.siteChatRowsOf(r);
      },
      send: (body) async {
        final r = await _supabase.adminSiteChatSend(id, body);
        final meta = Map<String, dynamic>.from((r['chat'] as Map?) ?? const {});
        _setMeta(id, meta);
        unawaited(_load());
        return SupabaseService.siteChatRowsOf(r);
      },
      note: 'Writing here takes the chat over from the assistant. If they '
          'are on the site they see it straight away. If they have left: '
          'with an email, it is emailed to them a minute after your last '
          'message; with only a WhatsApp number, use Open WhatsApp.',
      emptyTitle: 'No messages yet',
      emptyText: 'Nothing has been written in this chat.',
    );
  }

  /// "Returning visitor: earlier chat on 20 Oct (6 messages, closed)".
  static String _returning(Map<String, dynamic> p) {
    final at = DateTime.tryParse('${p['started_at'] ?? ''}')?.toLocal();
    final n = ((p['messages'] as num?) ?? 0).toInt();
    final when = at == null ? '' : ' on ${DateFormat('d MMM').format(at)}';
    final state = p['status'] == 'done' ? 'closed' : 'still open';
    return 'Returning visitor: earlier chat$when '
        '($n message${n == 1 ? '' : 's'}, $state)';
  }

  Widget _header(Map<String, dynamic> c) {
    final id = '${c['id']}';
    final m = {...c, ...?_meta[id]};
    final email = '${m['visitor_email'] ?? ''}'.trim();
    final phone = '${m['visitor_phone'] ?? ''}'.trim();
    final url = '${m['page_url'] ?? ''}'.trim();
    final team = m['mode'] == 'team';
    final done = m['status'] == 'done';
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_title(m),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
          Text(
              [
                if (email.isNotEmpty) email,
                if (phone.isNotEmpty) phone,
                if (email.isEmpty && phone.isEmpty) 'No contact details yet',
                if (_page(m).isNotEmpty) 'on ${_page(m)}',
              ].join('  ·  '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w400,
                  color: Brand.inkSecondary)),
          // A returning visitor (migration 206): when their last chat was.
          if (m['previous'] is Map)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                  _returning(Map<String, dynamic>.from(m['previous'] as Map)),
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Brand.violet)),
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            if (team)
              OutlinedButton.icon(
                  onPressed: () => _set(id,
                      mode: 'bot',
                      toast: 'The assistant answers this chat again.'),
                  icon: const Icon(Icons.smart_toy_outlined, size: 16),
                  label: const Text('Let the assistant answer'))
            else
              FilledButton.icon(
                  onPressed: () => _set(id,
                      mode: 'team',
                      toast: 'Taken over: the assistant stops here.'),
                  icon: const Icon(Icons.front_hand_outlined, size: 16),
                  label: const Text('Take over')),
            if (phone.replaceAll(RegExp(r'[^0-9]'), '').length >= 7)
              OutlinedButton.icon(
                  onPressed: () => _openWhatsApp(id, phone),
                  icon: const Icon(Icons.chat_outlined, size: 16),
                  label: const Text('Open WhatsApp')),
            OutlinedButton.icon(
                onPressed: () => _askContact(id, email.isEmpty ? null : email,
                    phone.isEmpty ? null : phone),
                icon: const Icon(Icons.contact_mail_outlined, size: 16),
                label: Text(email.isEmpty && phone.isEmpty
                    ? 'Add contact details'
                    : 'Contact details')),
            // Only for someone who runs a space: a visitor's chat was
            // started on a page that is not theirs (Jonathan, 20 Oct
            // 2026: "Their page isn't relevant if it's a user").
            if (url.startsWith('http') && m['who'] == 'owner')
              TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(url)),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Their page')),
            TextButton.icon(
                onPressed: () => _set(id,
                    status: done ? 'open' : 'done',
                    toast: done
                        ? 'Chat reopened.'
                        : 'Chat closed. A new message reopens it.'),
                icon: Icon(done ? Icons.undo : Icons.check_circle_outline, size: 16),
                label: Text(done ? 'Reopen chat' : 'Close chat')),
          ]),
        ]);
  }

  void _openChat(Map<String, dynamic> c, bool wide) {
    final id = '${c['id']}';
    if (wide) {
      setState(() => _open = id);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ValueListenableBuilder<int>(
          valueListenable: _metaTick,
          builder: (ctx, _, __) => Scaffold(
            backgroundColor: Brand.surface,
            appBar: AppBar(titleSpacing: 0, title: const Text('Website chat')),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(c),
                      const Divider(height: 16, color: Brand.hairline),
                      Expanded(child: _thread(c)),
                    ]),
              ),
            ),
          ),
        ),
      ),
    ).then((_) {
      if (mounted) _load();
    });
  }

  Widget _row(Map<String, dynamic> c, bool wide) {
    final id = '${c['id']}';
    final unread = ((c['unread'] as num?) ?? 0).toInt();
    final at = DateTime.tryParse('${c['last_at'] ?? ''}')?.toLocal();
    final last = '${c['last_body'] ?? ''}'.trim();
    final role = '${c['last_role'] ?? ''}';
    final on = wide && _open == id;
    final done = c['status'] == 'done';
    final prefix = role == 'team'
        ? 'You: '
        : role == 'bot'
            ? 'Assistant: '
            : '';
    return InkWell(
      onTap: () => _openChat(c, wide),
      child: Container(
        color: on ? Brand.accentTint : null,
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_title(c),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: c['waiting'] == true
                              ? FontWeight.w800
                              : FontWeight.w700)),
                  if (_page(c).isNotEmpty)
                    Text(_page(c),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Brand.inkMuted)),
                  if (last.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text('$prefix$last',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.35,
                              fontWeight: role == 'visitor'
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: role == 'visitor'
                                  ? Brand.ink
                                  : Brand.inkSecondary)),
                    ),
                  Wrap(children: _chips(c)),
                ]),
          ),
          const SizedBox(width: 6),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (at != null)
              Text(_short(at),
                  style:
                      const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
            if (unread > 0 && !done)
              Container(
                margin: const EdgeInsets.only(top: 5),
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                decoration: BoxDecoration(
                    color: Brand.red, borderRadius: BorderRadius.circular(10)),
                child: Text('$unread',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800)),
              ),
            IconButton(
                tooltip: done ? 'Reopen chat' : 'Close chat',
                visualDensity: VisualDensity.compact,
                onPressed: () => _set(id,
                    status: done ? 'open' : 'done',
                    toast: done
                        ? 'Chat reopened.'
                        : 'Chat closed. A new message reopens it.'),
                icon: Icon(
                    done ? Icons.undo : Icons.check_circle_outline,
                    size: 22,
                    color: done ? Brand.inkMuted : Brand.success)),
          ]),
        ]),
      ),
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .8,
                color: Brand.inkMuted)),
      );

  Widget _list(bool wide) {
    final waiting = _chats.where((c) => c['waiting'] == true).toList();
    final rest = _chats.where((c) => c['waiting'] != true).toList();
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 0),
        child: Row(children: [
          Expanded(
            child: Wrap(spacing: 6, children: [
          ChoiceChip(
              label: Text('Open chats',
                  style: TextStyle(
                      fontWeight: !_done ? FontWeight.w700 : FontWeight.w500,
                      color: !_done ? Colors.white : Brand.ink)),
              selected: !_done,
              showCheckmark: false,
              selectedColor: Brand.ink,
              backgroundColor: Brand.surface,
              onSelected: (_) {
                if (!_done) return;
                setState(() {
                  _done = false;
                  _loading = true;
                  _open = null;
                });
                _load();
              }),
          ChoiceChip(
              label: Text('Closed chats',
                  style: TextStyle(
                      fontWeight: _done ? FontWeight.w700 : FontWeight.w500,
                      color: _done ? Colors.white : Brand.ink)),
              selected: _done,
              showCheckmark: false,
              selectedColor: Brand.ink,
              backgroundColor: Brand.surface,
              onSelected: (_) {
                if (_done) return;
                setState(() {
                  _done = true;
                  _loading = true;
                  _open = null;
                });
                _load();
              }),
            ]),
          ),
          // Which blog articles show the chat (Jonathan, 20 Oct 2026).
          TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SiteChatBlogPagesScreen())),
              icon: const Icon(Icons.article_outlined, size: 17),
              label: const Text('Blog articles')),
        ]),
      ),
      if (_loading)
        const Padding(
          padding: EdgeInsets.all(30),
          child: Center(child: CircularProgressIndicator(color: Brand.red)),
        )
      else if (_error != null)
        Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, textAlign: TextAlign.center))
      else if (_chats.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
              _done
                  ? 'No closed chats yet.'
                  : 'No open chats. When someone writes in the chat box on '
                      'nomadwise.io, it appears here and your phone is told.',
              style: const TextStyle(color: Brand.inkSecondary, height: 1.45)),
        )
      else ...[
        if (waiting.isNotEmpty) ...[
          _heading('WAITING FOR YOU'),
          for (final c in waiting) _row(c, wide),
        ],
        if (rest.isNotEmpty) ...[
          _heading(_done
              ? 'CLOSED FOR NOW'
              : waiting.isEmpty
                  ? 'OPEN CHATS'
                  : 'THE ASSISTANT HAS THESE'),
          for (final c in rest) _row(c, wide),
        ],
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= _wideFrom;
      final open = wide && _open != null
          ? _chats.where((c) => '${c['id']}' == _open).firstOrNull
          : null;
      if (!wide) return _list(false);
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: 380, child: _list(true)),
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
      ]);
    });
  }
}

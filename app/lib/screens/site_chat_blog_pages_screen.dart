import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// The blog articles that show the chat box on nomadwise.io
/// (migration 192), from Chats, Website, "Blog articles".
///
/// Jonathan, 20 Oct 2026: try the chat on a few articles that get
/// readers but few clicks to providers, never on the ones that already
/// sell well, to see whether a question answered leads to a sale.
/// Paste an article's address to add it; take it off with the minus.
/// The site picks up a change within the hour.
class SiteChatBlogPagesScreen extends StatefulWidget {
  const SiteChatBlogPagesScreen({super.key});

  @override
  State<SiteChatBlogPagesScreen> createState() =>
      _SiteChatBlogPagesScreenState();
}

class _SiteChatBlogPagesScreenState extends State<SiteChatBlogPagesScreen> {
  final _supabase = SupabaseService();
  final _ctl = TextEditingController();
  List<Map<String, dynamic>>? _pages;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await _supabase.adminSiteChatPages();
      if (mounted) setState(() => _pages = r);
    } catch (e) {
      if (mounted) setState(() => _error = 'The list could not be loaded: $e');
    }
  }

  void _snack(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  /// "Some message" from a database error, without the code around it.
  static String _plain(Object e) {
    final s = '$e';
    final m = RegExp(r'message: ([^,]+)').firstMatch(s);
    return m?.group(1) ?? s;
  }

  Future<void> _add() async {
    final url = _ctl.text.trim();
    if (url.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final r = await _supabase.adminSiteChatPageAdd(url);
      if (!mounted) return;
      setState(() => _pages = r);
      _ctl.clear();
      _snack('Added. The chat shows there within the hour.');
    } catch (e) {
      _snack(_plain(e), bad: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String path) async {
    try {
      final r = await _supabase.adminSiteChatPageRemove(path);
      if (!mounted) return;
      setState(() => _pages = r);
      _snack('Taken off ${_name(path)}. It goes within the hour.');
    } catch (e) {
      _snack('That did not save: ${_plain(e)}', bad: true);
    }
  }

  static String _name(String path) => path.replaceFirst('/blog/', '');

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Chat on blog articles')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
              children: [
                const Text(
                    'The chat box shows on these articles, and on the '
                    'homepage, About us and the coworking pages. Choose '
                    'articles that get readers but few clicks to providers, '
                    'and leave the ones that already sell well alone. On an '
                    'article the box asks "Need a hand with anything?" and '
                    'the assistant helps with that guide. Every new chat '
                    'tells your phone.',
                    style: TextStyle(
                        fontSize: 13, height: 1.45, color: Brand.inkSecondary)),
                const SizedBox(height: 14),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: TextField(
                      controller: _ctl,
                      onSubmitted: (_) => _add(),
                      decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          hintText:
                              'https://www.nomadwise.io/blog/best-esims-japan'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: _busy ? null : _add,
                      child: const Text('Add')),
                ]),
                const SizedBox(height: 16),
                if (_error != null)
                  Text(_error!, style: const TextStyle(color: Brand.red))
                else if (pages == null)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Center(
                        child: CircularProgressIndicator(color: Brand.red)),
                  )
                else if (pages.isEmpty)
                  const Text('No articles yet: the chat is on no blog article.',
                      style: TextStyle(color: Brand.inkMuted))
                else ...[
                  Text(
                      '${pages.length} ${pages.length == 1 ? 'ARTICLE' : 'ARTICLES'}',
                      style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .8,
                          color: Brand.inkMuted)),
                  const SizedBox(height: 6),
                  for (final p in pages) _row(p),
                ],
              ]),
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> p) {
    final path = '${p['path']}';
    final chats = (p['chats'] as num?)?.toInt() ?? 0;
    final last = DateTime.tryParse('${p['last_chat'] ?? ''}')?.toLocal();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Brand.border)),
      child: ListTile(
        dense: true,
        title: Text(_name(path),
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        subtitle: Text(
            chats == 0
                ? 'No chats yet'
                : '$chats ${chats == 1 ? 'chat' : 'chats'}'
                    '${last == null ? '' : ', the last on ${DateFormat('d MMM').format(last)}'}',
            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
              tooltip: 'Open the article',
              onPressed: () =>
                  launchUrl(Uri.parse('https://www.nomadwise.io$path')),
              icon: const Icon(Icons.open_in_new, size: 18)),
          IconButton(
              tooltip: 'Take the chat off this article',
              onPressed: () => _remove(path),
              icon: const Icon(Icons.remove_circle_outline,
                  size: 20, color: Brand.inkSecondary)),
        ]),
      ),
    );
  }
}

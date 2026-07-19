import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Admin only: everything users have sent through Send feedback.
class FeedbackInboxScreen extends StatefulWidget {
  const FeedbackInboxScreen({super.key});
  @override
  State<FeedbackInboxScreen> createState() =>
      _FeedbackInboxScreenState();
}

class _FeedbackInboxScreenState extends State<FeedbackInboxScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _items;
  Map<String, String> _names = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _supabase.feedbackInbox();
    final ids = items
        .map((f) => f['user_id'] as String?)
        .whereType<String>()
        .toSet()
        .toList();
    final names = await _supabase.displayNamesFor(ids);
    if (mounted) {
      setState(() {
        _items = items;
        _names = names;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final newCount =
        items?.where((f) => f['status'] == 'new').length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text('Feedback'),
          if (items != null && newCount > 0) ...[
            const SizedBox(width: 8),
            Text('$newCount new',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Brand.accent)),
          ],
        ]),
      ),
      body: items == null
          ? const Center(
              child: CircularProgressIndicator(color: Brand.accent))
          : items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                        'Nothing yet. Feedback from the menu lands '
                        'here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Brand.inkMuted)),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(
                        height: 1, color: Brand.hairline),
                    itemBuilder: (_, i) => _tile(items[i]),
                  ),
                ),
    );
  }

  Widget _tile(Map<String, dynamic> f) {
    final isNew = f['status'] == 'new';
    final date = DateTime.tryParse(f['created_at'] ?? '');
    final who = f['user_id'] != null
        ? (_names[f['user_id']] ?? 'Nomad')
        : 'Anonymous';
    final sub = [
      who,
      if (f['contact'] != null) f['contact'],
      if (date != null) DateFormat('d MMM, HH:mm').format(date),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child:
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          margin: const EdgeInsets.only(top: 6),
          width: 9,
          height: 9,
          decoration: BoxDecoration(
              color: isNew ? Brand.accent : Brand.inkFaint,
              shape: BoxShape.circle),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(f['message'] ?? '',
                    style: TextStyle(
                        fontSize: 14.5,
                        height: 1.45,
                        fontWeight:
                            isNew ? FontWeight.w600 : FontWeight.w400)),
                const SizedBox(height: 4),
                Text(sub,
                    style: const TextStyle(
                        fontSize: 12, color: Brand.inkMuted)),
              ]),
        ),
        TextButton(
          onPressed: () async {
            await _supabase.setFeedbackStatus(
                f['id'] as String, isNew ? 'done' : 'new');
            _load();
          },
          child: Text(isNew ? 'Done' : 'Reopen',
              style: const TextStyle(fontSize: 13)),
        ),
      ]),
    );
  }
}

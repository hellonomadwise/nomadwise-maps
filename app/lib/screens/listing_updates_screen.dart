import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Admin only: what visitors told us has changed at a space, from the
/// "Something need updating?" link on each nomadwise.io page. Open
/// ones by default; fix the page, then mark it done, or dismiss it.
class ListingUpdatesScreen extends StatefulWidget {
  const ListingUpdatesScreen({super.key});
  @override
  State<ListingUpdatesScreen> createState() => _ListingUpdatesScreenState();
}

class _ListingUpdatesScreenState extends State<ListingUpdatesScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _rows;
  bool _all = false;

  static const _kindLabels = {
    'closed': 'It has closed',
    'temporarily_closed': 'Temporarily closed',
    'hours': 'Opening hours',
    'wifi': 'Wifi',
    'laptops': 'Laptop rules',
    'plugs': 'Plug sockets',
    'prices': 'Prices',
    'photos': 'Photos',
    'address': 'Name or address',
    'other': 'Something else',
  };
  static const _visitLabels = {
    'today': 'today',
    'this_week': 'this week',
    'this_month': 'this month',
    'longer': 'longer ago',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await _supabase.listingUpdates(openOnly: !_all);
    if (mounted) setState(() => _rows = rows);
  }

  Future<void> _set(Map<String, dynamic> r, String status) async {
    try {
      await _supabase.setListingUpdateStatus('${r['id']}', status);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not saved: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Suggested updates'), actions: [
        TextButton(
            onPressed: () {
              setState(() {
                _all = !_all;
                _rows = null;
              });
              _load();
            },
            child: Text(_all ? 'Open only' : 'Show all')),
      ]),
      body: rows == null
          ? const Center(child: CircularProgressIndicator(color: Brand.red))
          : rows.isEmpty
              ? const Center(
                  child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'Nothing waiting. When someone uses "Something need '
                      'updating?" on a page, it lands here and pings your '
                      'phone.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Brand.inkMuted, height: 1.5)),
                ))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 30),
                      children: rows.map(_card).toList()),
                ),
    );
  }

  Widget _card(Map<String, dynamic> r) {
    final when = DateTime.tryParse('${r['created_at']}')?.toLocal();
    final kinds = ((r['kinds'] as List?) ?? const [])
        .map((k) => _kindLabels['$k'] ?? '$k')
        .toList();
    final visit = _visitLabels['${r['last_visit']}'];
    final who = [
      if ((r['name'] ?? '').toString().isNotEmpty) r['name'],
      if ((r['email'] ?? '').toString().isNotEmpty) r['email'],
    ].join(', ');
    final status = '${r['status']}';
    final slug = (r['slug'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${r['space_name'] ?? 'Unknown space'}',
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
          if (status != 'open')
            Text(status == 'done' ? 'Done' : 'Dismissed',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Brand.inkMuted)),
        ]),
        if (when != null)
          Text(DateFormat('d MMM, HH:mm').format(when),
              style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
        if (kinds.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final k in kinds)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: Brand.bg, borderRadius: BorderRadius.circular(20)),
                child: Text(k,
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w600)),
              ),
          ]),
        ],
        if ((r['details'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText('${r['details']}',
              style: const TextStyle(fontSize: 13.5, height: 1.45)),
        ],
        const SizedBox(height: 6),
        Text(
            [
              if (visit != null) 'Last there $visit',
              who.isEmpty ? 'No name left' : 'From $who',
            ].join(' · '),
            style: const TextStyle(fontSize: 12, color: Brand.inkSecondary)),
        Wrap(spacing: 4, children: [
          if (slug.isNotEmpty)
            TextButton.icon(
                onPressed: () => launchUrl(
                    Uri.parse('https://www.nomadwise.io/coworking/$slug')),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open the page')),
          if (status == 'open') ...[
            TextButton.icon(
                onPressed: () => _set(r, 'done'),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Mark done')),
            TextButton(
                onPressed: () => _set(r, 'dismissed'),
                child: const Text('Dismiss',
                    style: TextStyle(color: Brand.inkMuted))),
          ] else
            TextButton(
                onPressed: () => _set(r, 'open'),
                child: const Text('Reopen')),
        ]),
      ]),
    );
  }
}

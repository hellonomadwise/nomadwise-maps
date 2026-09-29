import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import 'space_trail_screen.dart';

/// Admin only: every email the system sent (or tried to send) an
/// owner, newest first, with what Postmark answered. A test button
/// sends one to the founder's own address to prove the pipe.
class EmailLogScreen extends StatefulWidget {
  const EmailLogScreen({super.key});
  @override
  State<EmailLogScreen> createState() => _EmailLogScreenState();
}

class _EmailLogScreenState extends State<EmailLogScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _rows;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _supabase.adminEmailLog(limit: 100);
      if (mounted) {
        setState(() {
          _rows = rows;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _rows = [];
          _error = '$e';
        });
      }
    }
  }

  Future<void> _test() async {
    final to = _supabase.userEmail;
    if (to == null || to.isEmpty) return;
    setState(() => _sending = true);
    try {
      await _supabase.adminSendTestEmail(to);
      await Future<void>.delayed(const Duration(seconds: 3));
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Test sent to $to. The row below says what '
                'happened; give Postmark a few seconds.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not send: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static const _kinds = {
    'claim_received': 'Claim received',
    'payment_received': 'Payment received',
    'approved_verified': 'Approved, Verified',
    'approved_free': 'Approved, free',
    'rejected': 'Rejected',
    'page_live': 'Page is live',
    'changes_live': 'Changes on the page',
    'changes_back': 'Changes sent back',
    'finish_claim': 'Finish your claim (nudge)',
    'test': 'Test',
  };

  /// One line that says what happened, from the two records.
  (String, Color) _verdict(Map<String, dynamic> r) {
    final status = '${r['status']}';
    final http = r['http_status'];
    final body = '${r['http_body'] ?? ''}';
    if (status == 'skipped') {
      return ('Not sent: ${r['error']}', Brand.goldTextDark);
    }
    if (status == 'failed') {
      return ('Failed before sending: ${r['error']}', Brand.red);
    }
    if (http == null) {
      return ('Handed to Postmark; no answer recorded yet (answers are '
              'kept a few hours).',
          Brand.inkSecondary);
    }
    if (http == 200) return ('Postmark accepted it.', Brand.success);
    return ('Postmark refused it ($http): $body', Brand.red);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Emails to owners'), actions: [
        TextButton.icon(
          onPressed: _sending ? null : _test,
          icon: const Icon(Icons.send_outlined, size: 18),
          label: Text(_sending ? 'Sending...' : 'Send me a test'),
        ),
        const SizedBox(width: 6),
      ]),
      body: rows == null
          ? const Center(
              child: CircularProgressIndicator(color: Brand.accent))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
                children: [
                  if (_error != null)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                          color: Brand.goldTint,
                          borderRadius: BorderRadius.circular(12)),
                      child: Text(
                          _error!.contains('admin_email_log')
                              ? 'The email log is not installed yet: '
                                  'migration 82 has not run. Check the '
                                  'last build on GitHub.'
                              : 'Could not load the log: $_error',
                          style: const TextStyle(
                              fontSize: 13, color: Brand.goldTextDark)),
                    ),
                  if (_error == null && rows.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                          'Nothing sent yet. If a claim came in and '
                          'nothing is here, the email trigger (migration '
                          '81) is not installed; the build log on GitHub '
                          'says why.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Brand.inkMuted)),
                    ),
                  ...rows.map(_card),
                ],
              ),
            ),
    );
  }

  /// The whole email, as the owner got it (text kept from migration 101).
  void _openEmail(Map<String, dynamic> r) {
    final body = (r['body'] ?? '').toString();
    final venueId = (r['venue_id'] ?? '').toString();
    final venue = (r['venue_name'] ?? '').toString();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        title: Text('${r['subject'] ?? ''}'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('To ${r['to_email']}',
                      style: const TextStyle(
                          fontSize: 13, color: Brand.inkSecondary)),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: Brand.bg,
                        borderRadius: BorderRadius.circular(10)),
                    child: SelectableText(
                        body.isEmpty
                            ? 'The full text is kept for emails sent from 29 '
                                'September 2026 onwards; this one shows its '
                                'subject only.'
                            : body,
                        style: TextStyle(
                            fontSize: 13.5,
                            height: 1.55,
                            color: body.isEmpty ? Brand.inkMuted : Brand.ink)),
                  ),
                ]),
          ),
        ),
        actions: [
          if (venueId.isNotEmpty)
            TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SpaceTrailScreen(
                          venueId: venueId,
                          name: venue.isEmpty ? 'this space' : venue)));
                },
                icon: const Icon(Icons.history, size: 18),
                label: Text(venue.isEmpty ? 'History' : 'History of $venue')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> r) {
    final (line, color) = _verdict(r);
    final when = DateTime.tryParse('${r['created_at']}')?.toLocal();
    return InkWell(
      onTap: () => _openEmail(r),
      borderRadius: BorderRadius.circular(14),
      child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(_kinds['${r['kind']}'] ?? '${r['kind']}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13.5)),
          ),
          if (when != null)
            Text(DateFormat('d MMM, HH:mm').format(when),
                style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
        ]),
        const SizedBox(height: 3),
        Text('To ${r['to_email']}  ·  ${r['subject']}',
            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        const SizedBox(height: 6),
        Text(line,
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
        if ((r['venue_name'] ?? '').toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${r['venue_name']}  ·  tap to read the email',
                style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
          ),
      ]),
    ),
    );
  }
}

import 'package:flutter/material.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// nomadmaps.io/?found=<key>: the page behind the "Did you find a
/// place to work?" email (migration 193). Someone who sent an enquiry
/// through nomadwise.io says where they went: one of the spaces they
/// asked, still looking, or somewhere else, with a note if they like.
/// They can change their answer. The phone is told.
class FoundScreen extends StatefulWidget {
  final String token;
  const FoundScreen({super.key, required this.token});

  @override
  State<FoundScreen> createState() => _FoundScreenState();
}

class _FoundScreenState extends State<FoundScreen> {
  final _supabase = SupabaseService();
  final _note = TextEditingController();
  Map<String, dynamic>? _view;
  bool _loading = true;
  bool _busy = false;
  bool _thanks = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _supabase.enquiryFollowup(widget.token).then((v) {
      if (!mounted) return;
      setState(() {
        _view = v;
        _loading = false;
      });
    }).catchError((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _answer(String choice, {String? enquiryId}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final v = await _supabase.answerEnquiryFollowup(widget.token, choice,
          enquiryId: enquiryId,
          note: _note.text.trim().isEmpty ? null : _note.text.trim());
      if (!mounted) return;
      setState(() {
        if (v != null) _view = v;
        _thanks = true;
      });
    } catch (e) {
      final m = RegExp(r'message: ([^,]+)').firstMatch('$e')?.group(1);
      if (mounted) setState(() => _error = m ?? 'That did not save. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _view;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Nomadwise')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: Brand.red))
              : v == null
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                          'This link is not valid any more. If you are still '
                          'looking for a place to work, write to '
                          'hello@nomadwise.io and we will help.',
                          style: TextStyle(fontSize: 16, height: 1.5)),
                    )
                  : _form(v),
        ),
      ),
    );
  }

  Widget _form(Map<String, dynamic> v) {
    final first = (v['first'] ?? '').toString();
    final spaces = [
      for (final s in (v['spaces'] as List? ?? const []))
        if (s is Map) Map<String, dynamic>.from(s)
    ];
    final answer = v['answer']?.toString();
    final chosen = v['chosen']?.toString();

    Widget option(String label, VoidCallback onTap, {bool on = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SizedBox(
            width: double.infinity,
            child: on
                ? FilledButton(
                    onPressed: _busy ? null : onTap,
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        alignment: Alignment.centerLeft),
                    child: Text(label))
                : OutlinedButton(
                    onPressed: _busy ? null : onTap,
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 16),
                        alignment: Alignment.centerLeft,
                        foregroundColor: Brand.ink),
                    child: Text(label)),
          ),
        );

    return ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 40), children: [
      Text(first.isEmpty ? 'Did you find a place?' : 'Did you find a place, $first?',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      const Text(
          'Tap where you went. It helps us know which spaces reply, so we '
          'can point other remote workers the right way.',
          style: TextStyle(fontSize: 14.5, height: 1.5, color: Brand.inkSecondary)),
      const SizedBox(height: 20),
      for (final s in spaces)
        option('I went with ${s['name']}',
            () => _answer('space', enquiryId: '${s['id']}'),
            on: answer == 'booked' && chosen == '${s['id']}'),
      option('I am still looking', () => _answer('looking'),
          on: answer == 'looking'),
      option('I found somewhere else', () => _answer('elsewhere'),
          on: answer == 'elsewhere'),
      const SizedBox(height: 10),
      TextField(
        controller: _note,
        maxLength: 500,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(
            labelText: 'Anything to add? (optional)',
            hintText: 'How it went, or what you are looking for',
            border: OutlineInputBorder()),
      ),
      if (_error != null)
        Text(_error!, style: const TextStyle(color: Brand.red)),
      if (_thanks)
        Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Brand.successTint, borderRadius: BorderRadius.circular(10)),
          child: Text(
              answer == 'looking'
                  ? 'Thank you. Reply to our email and tell us what you need, '
                      'and we will help you find somewhere.'
                  : 'Thank you, that helps. Enjoy your work!',
              style: const TextStyle(
                  fontSize: 14.5, height: 1.45, color: Brand.success)),
        ),
    ]);
  }
}

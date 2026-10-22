import 'package:flutter/material.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import 'email_html_stub.dart' if (dart.library.html) 'email_html_web.dart';

/// One space an enquiry is about to go to: the enquiry and the address.
class EnquiryTarget {
  final String id;
  final String venueName;
  final String to;
  const EnquiryTarget(this.id, this.venueName, this.to);
}

/// What happened when the emails were sent.
class EnquiryReviewResult {
  final int passed;
  final List<String> failed;
  final bool customerTold;
  final bool customerSkipped;
  const EnquiryReviewResult(
      this.passed, this.failed, this.customerTold, this.customerSkipped);
}

/// "Check before sending" (migration 194; Jonathan, 22 Oct 2026: "I
/// need to see if they are styled or not ... what a preview will look
/// like", "the ability to update / edit any of the details"). Every
/// email an enquiry sends, shown exactly as it will arrive (the same
/// styled template), each with Edit for the address, subject and
/// words. Nothing is sent until Send.
class EnquiryReviewScreen extends StatefulWidget {
  final SupabaseService supabase;
  final List<EnquiryTarget> targets;

  /// Also email the customer (one email listing every space).
  final bool tellCustomer;
  final String customerName;

  const EnquiryReviewScreen({
    super.key,
    required this.supabase,
    required this.targets,
    required this.tellCustomer,
    required this.customerName,
  });

  @override
  State<EnquiryReviewScreen> createState() => _EnquiryReviewScreenState();
}

class _Draft {
  final String? enquiryId; // null: the email to the customer
  final String label;
  final String replyTo;
  final TextEditingController to;
  final TextEditingController subject;
  final TextEditingController body;
  final String originalSubject;
  final String originalBody;
  _Draft(this.enquiryId, this.label, this.replyTo, String to, String subject,
      String body)
      : to = TextEditingController(text: to),
        subject = TextEditingController(text: subject),
        body = TextEditingController(text: body),
        originalSubject = subject,
        originalBody = body;

  bool get edited =>
      subject.text.trim() != originalSubject.trim() ||
      body.text.trim() != originalBody.trim();

  void dispose() {
    to.dispose();
    subject.dispose();
    body.dispose();
  }
}

class _EnquiryReviewScreenState extends State<EnquiryReviewScreen> {
  List<_Draft>? _drafts;
  String? _error;
  bool _sending = false;

  String get _first {
    final n = widget.customerName.trim().split(' ').first;
    return n.isEmpty || n == 'Someone' ? 'the customer' : n;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final d in _drafts ?? const <_Draft>[]) {
      d.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.supabase
          .enquiryDrafts([for (final t in widget.targets) t.id]);
      final spaces = {
        for (final s in (r['spaces'] as List? ?? const []))
          if (s is Map) '${s['id']}': Map<String, dynamic>.from(s)
      };
      final nomad = r['nomad'] is Map
          ? Map<String, dynamic>.from(r['nomad'] as Map)
          : null;
      final drafts = <_Draft>[
        for (final t in widget.targets)
          if (spaces[t.id] != null)
            _Draft(
                t.id,
                'To ${t.venueName}',
                'Replies go to $_first',
                t.to,
                '${spaces[t.id]!['subject'] ?? ''}',
                '${spaces[t.id]!['body'] ?? ''}'),
        if (widget.tellCustomer && nomad != null)
          _Draft(null, 'To $_first', 'Replies come to hello@nomadwise.io',
              '${nomad['to'] ?? ''}', '${nomad['subject'] ?? ''}',
              '${nomad['body'] ?? ''}'),
      ];
      if (mounted) setState(() => _drafts = drafts);
    } catch (e) {
      if (mounted) setState(() => _error = 'The emails could not be prepared: $e');
    }
  }

  Future<void> _send() async {
    final drafts = _drafts;
    if (drafts == null || _sending) return;
    setState(() => _sending = true);
    final done = <String>[];
    final failed = <String>[];
    for (final d in drafts.where((d) => d.enquiryId != null)) {
      try {
        await widget.supabase.passOnEnquiry(d.enquiryId!, d.to.text.trim(),
            tellNomad: false,
            subject: d.edited ? d.subject.text.trim() : null,
            body: d.edited ? d.body.text.trim() : null);
        done.add(d.enquiryId!);
      } catch (_) {
        failed.add(d.label.replaceFirst('To ', ''));
      }
    }
    var told = false;
    var skipped = false;
    final customer = drafts.where((d) => d.enquiryId == null).firstOrNull;
    if (customer != null && done.isNotEmpty) {
      // An edited list would name a space that did not get it: then the
      // customer's email waits for a founder.
      if (failed.isNotEmpty && customer.edited) {
        skipped = true;
      } else {
        try {
          told = await widget.supabase.tellNomadMany(done,
                  to: customer.to.text.trim(),
                  subject: customer.edited ? customer.subject.text.trim() : null,
                  body: customer.edited ? customer.body.text.trim() : null) >
              0;
        } catch (_) {
          skipped = true;
        }
      }
    }
    if (!mounted) return;
    Navigator.pop(
        context, EnquiryReviewResult(done.length, failed, told, skipped));
  }

  @override
  Widget build(BuildContext context) {
    final drafts = _drafts;
    final n = drafts?.where((d) => d.enquiryId != null).length ?? 0;
    final ready = drafts != null &&
        drafts.every((d) => d.to.text.contains('@') && d.body.text.trim().isNotEmpty);
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title: const Text('Step 2 of 2: check and send'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
                onPressed: ready && !_sending ? _send : null,
                icon: _sending
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, size: 16),
                label: Text(_sending
                    ? 'Sending'
                    : 'Send ${drafts?.length ?? ''} ${drafts?.length == 1 ? 'email' : 'emails'}')),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!, style: const TextStyle(color: Brand.red)))
              : drafts == null
                  ? const Center(
                      child: CircularProgressIndicator(color: Brand.red))
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
                      children: [
                          Text(
                              '${n == 1 ? 'One space' : '$n spaces'}'
                              '${widget.tellCustomer ? ' and $_first' : ''}. '
                              'Each email is shown as it will arrive. Use Edit '
                              'to change the address, subject or words; nothing '
                              'is sent until you press Send.',
                              style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.45,
                                  color: Brand.inkSecondary)),
                          const SizedBox(height: 12),
                          for (final d in drafts)
                            _EmailCard(
                                key: ValueKey(d.enquiryId ?? 'customer'),
                                draft: d,
                                supabase: widget.supabase,
                                onChanged: () => setState(() {})),
                        ]),
        ),
      ),
    );
  }
}

/// One email: as it will arrive, or (Edit) its address, subject and
/// words.
class _EmailCard extends StatefulWidget {
  final _Draft draft;
  final SupabaseService supabase;
  final VoidCallback onChanged;
  const _EmailCard(
      {super.key,
      required this.draft,
      required this.supabase,
      required this.onChanged});

  @override
  State<_EmailCard> createState() => _EmailCardState();
}

class _EmailCardState extends State<_EmailCard> {
  bool _editing = false;
  String? _html;
  String _htmlOf = '';

  @override
  void initState() {
    super.initState();
    _render();
  }

  Future<void> _render() async {
    final text = widget.draft.body.text;
    if (text == _htmlOf && _html != null) return;
    try {
      final h = await widget.supabase.emailPreview(text);
      if (!mounted) return;
      setState(() {
        _html = h;
        _htmlOf = text;
      });
    } catch (_) {
      if (mounted) setState(() => _html = '');
    }
  }

  InputDecoration _field(String label) => InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        fillColor: Brand.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    Widget meta(String k, String v) => Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: '$k  ',
                    style: const TextStyle(color: Brand.inkMuted)),
                TextSpan(text: v),
              ]),
              style: const TextStyle(fontSize: 13)),
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
          child: Row(children: [
            Expanded(
              child: Text(d.label,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800)),
            ),
            if (d.edited)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Text('Edited',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Brand.goldTextDark)),
              ),
            TextButton.icon(
                onPressed: () {
                  setState(() => _editing = !_editing);
                  if (!_editing) _render();
                },
                icon: Icon(_editing ? Icons.visibility_outlined : Icons.edit_outlined,
                    size: 16),
                label: Text(_editing ? 'Preview' : 'Edit')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: _editing
              ? Column(children: [
                  TextField(
                      controller: d.to,
                      keyboardType: TextInputType.emailAddress,
                      onChanged: (_) => widget.onChanged(),
                      decoration: _field('To')),
                  const SizedBox(height: 10),
                  TextField(
                      controller: d.subject,
                      onChanged: (_) => widget.onChanged(),
                      decoration: _field('Subject')),
                  const SizedBox(height: 10),
                  TextField(
                      controller: d.body,
                      minLines: 10,
                      maxLines: 30,
                      onChanged: (_) => widget.onChanged(),
                      style: const TextStyle(fontSize: 14, height: 1.5),
                      decoration: _field('Words').copyWith(
                          alignLabelWithHint: true,
                          helperText:
                              'A blank line starts a new paragraph. Web addresses '
                              'become links.')),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  meta('From', 'Jonathan at Nomadwise <hello@nomadwise.io>'),
                  meta('To', d.to.text),
                  meta('Reply', d.replyTo),
                  meta('Subject', d.subject.text),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      decoration: BoxDecoration(
                          border: Border.all(color: Brand.hairline)),
                      child: _html == null
                          ? const SizedBox(
                              height: 120,
                              child: Center(
                                  child: CircularProgressIndicator(
                                      color: Brand.red)))
                          : _html!.isEmpty
                              // the styled version could not be made: the words
                              ? Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: SelectableText(d.body.text,
                                      style: const TextStyle(
                                          fontSize: 14, height: 1.5)))
                              : EmailHtmlView(
                                  html: _html!, text: d.body.text, height: 560),
                    ),
                  ),
                ]),
        ),
      ]),
    );
  }
}

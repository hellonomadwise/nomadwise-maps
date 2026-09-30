import 'package:flutter/material.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Owner account, "Build next": owners vote for the tools they would
/// like us to make (as many as they like, a tap turns a vote on or
/// off) and can write their own idea. Ideas live in the database
/// (owner_ideas, migration 106), so the list changes without an app
/// update. In a founder's preview nothing is saved.
class IdeasBoard extends StatefulWidget {
  final String venueId;
  final bool preview;
  const IdeasBoard({super.key, required this.venueId, this.preview = false});
  @override
  State<IdeasBoard> createState() => _IdeasBoardState();
}

class _IdeasBoardState extends State<IdeasBoard> {
  final _supabase = SupabaseService();
  final _idea = TextEditingController();
  List<Map<String, dynamic>>? _ideas;
  final Set<String> _busy = {};
  bool _sending = false;
  String? _note;
  bool _noteOk = true;

  static const _icons = <String, IconData>{
    'event_available': Icons.event_available_outlined,
    'inbox': Icons.inbox_outlined,
    'celebration': Icons.celebration_outlined,
    'local_offer': Icons.local_offer_outlined,
    'wifi': Icons.wifi,
    'rate_review': Icons.rate_review_outlined,
    'card_membership': Icons.card_membership_outlined,
    'group_add': Icons.group_add_outlined,
    'photo_library': Icons.photo_library_outlined,
    'star': Icons.star_outline,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(IdeasBoard old) {
    super.didUpdateWidget(old);
    if (old.venueId != widget.venueId) _load();
  }

  @override
  void dispose() {
    _idea.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final rows = await _supabase.ownerIdeas(widget.venueId);
    if (mounted) setState(() => _ideas = rows);
  }

  int get _votes => (_ideas ?? []).where((i) => i['voted'] == true).length;

  Future<void> _toggle(Map<String, dynamic> idea) async {
    final key = '${idea['key']}';
    if (_busy.contains(key)) return;
    final on = idea['voted'] != true;
    // Show it straight away; put it back if saving fails.
    setState(() {
      idea['voted'] = on;
      _busy.add(key);
    });
    if (widget.preview) {
      setState(() => _busy.remove(key));
      return;
    }
    try {
      await _supabase.ownerVoteIdea(widget.venueId, key, on);
    } catch (_) {
      if (mounted) {
        setState(() {
          idea['voted'] = !on;
          _note = 'That vote did not save. Please try again.';
          _noteOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _send() async {
    final t = _idea.text.trim();
    if (t.length < 3) return;
    if (widget.preview) {
      setState(() {
        _note = 'Preview: nothing is saved.';
        _noteOk = true;
      });
      return;
    }
    setState(() => _sending = true);
    try {
      await _supabase.ownerSuggestIdea(widget.venueId, t);
      if (!mounted) return;
      _idea.clear();
      setState(() {
        _note = 'Thank you! Your idea is with the team. We read every one.';
        _noteOk = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _note = 'That did not send. Please try again.';
          _noteOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ideas = _ideas;
    return Container(
      padding:
          EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 16 : 22),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
                color: Brand.logoTealTint, shape: BoxShape.circle),
            child: const Icon(Icons.lightbulb_outline,
                size: 19, color: Brand.logoNavy),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Help us decide what we build next',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          ),
        ]),
        const SizedBox(height: 10),
        const Text(
            'We are building Nomadwise to help spaces like yours fill more '
            'desks and do well. You know best what would make a difference, '
            'so we would love your help: vote for every idea you would use. '
            'Pick as many as you like. The most wanted are built first, and '
            'we will let you know when one you voted for is ready.',
            style: TextStyle(
                fontSize: 14, height: 1.55, color: Brand.inkSecondary)),
        const SizedBox(height: 18),
        if (ideas == null)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
                child: CircularProgressIndicator(color: Brand.red)),
          )
        else if (ideas.isEmpty)
          const Text('The ideas are on their way. Please check back soon.',
              style: TextStyle(color: Brand.inkMuted))
        else ...[
          LayoutBuilder(builder: (context, box) {
            final two = box.maxWidth >= 620;
            final w = two ? (box.maxWidth - 12) / 2 : box.maxWidth;
            return Wrap(spacing: 12, runSpacing: 12, children: [
              for (final i in ideas) SizedBox(width: w, child: _card(i)),
            ]);
          }),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
                key: ValueKey(_votes),
                _votes == 0
                    ? 'Tap an idea to vote for it. Tap again to take the vote back.'
                    : 'Thank you! You voted for $_votes '
                        'idea${_votes == 1 ? '' : 's'}. You can change your '
                        'votes any time.',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: _votes == 0 ? FontWeight.w400 : FontWeight.w600,
                    color: _votes == 0 ? Brand.inkMuted : Brand.logoNavy)),
          ),
        ],
        const SizedBox(height: 26),
        const Divider(height: 1, color: Brand.hairline),
        const SizedBox(height: 22),
        const Text('Have an idea of your own?',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 6),
        const Text(
            'Something that would save you time, bring in more people or '
            'make remote workers love your space even more. Big or small, '
            'tell us in your own words.',
            style: TextStyle(
                fontSize: 13.5, height: 1.5, color: Brand.inkSecondary)),
        const SizedBox(height: 12),
        TextField(
          controller: _idea,
          minLines: 3,
          maxLines: 8,
          maxLength: 1500,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'e.g. A way to show which desks are free today',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 4),
        Row(children: [
          FilledButton.icon(
              onPressed: _sending || _idea.text.trim().length < 3
                  ? null
                  : _send,
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_outlined, size: 17),
              label: const Text('Send my idea')),
        ]),
        if (_note != null) ...[
          const SizedBox(height: 10),
          Text(_note!,
              style: TextStyle(
                  fontSize: 13,
                  color: _noteOk ? Brand.logoNavy : Brand.red,
                  fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }

  Widget _card(Map<String, dynamic> i) {
    final on = i['voted'] == true;
    final icon = _icons['${i['icon']}'] ?? Icons.lightbulb_outline;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _toggle(i),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: on ? Brand.logoTealTint : Brand.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: on ? Brand.logoNavy : Brand.border, width: on ? 1.6 : 1),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 22, color: on ? Brand.logoNavy : Brand.inkSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${i['title']}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14.5)),
                    if ('${i['blurb'] ?? ''}'.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('${i['blurb']}',
                          style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.45,
                              color: Brand.inkSecondary)),
                    ],
                  ]),
            ),
            const SizedBox(width: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: Icon(
                  on ? Icons.check_circle : Icons.radio_button_unchecked,
                  key: ValueKey(on),
                  size: 22,
                  color: on ? Brand.logoNavy : Brand.inkFaint),
            ),
          ]),
        ),
      ),
    );
  }
}

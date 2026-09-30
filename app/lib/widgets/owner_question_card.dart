import 'dart:async';

import 'package:flutter/material.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Owner account: one quick question at a time, answered with a tap.
/// Not a survey: a single friendly card that asks what would help,
/// shows up at most every few days, and disappears when there is
/// nothing to ask. Answers go to the control centre ("What owners
/// tell us"). The questions themselves live in the database
/// (owner_questions, migration 104), so they can change without an
/// app update.
class OwnerQuestionCard extends StatefulWidget {
  final String venueId;
  const OwnerQuestionCard({super.key, required this.venueId});
  @override
  State<OwnerQuestionCard> createState() => _OwnerQuestionCardState();
}

enum _Stage { loading, asking, sending, thanks, gone }

class _OwnerQuestionCardState extends State<OwnerQuestionCard> {
  final _supabase = SupabaseService();
  final _other = TextEditingController();
  Map<String, dynamic>? _q;
  _Stage _stage = _Stage.loading;
  final Set<String> _picked = {};
  bool _otherOpen = false;
  int _remaining = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(OwnerQuestionCard old) {
    super.didUpdateWidget(old);
    if (old.venueId != widget.venueId) _load();
  }

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    setState(() => _stage = _Stage.loading);
    final q = await _supabase.ownerNextQuestion(widget.venueId, more: more);
    if (!mounted) return;
    setState(() {
      _q = q;
      _picked.clear();
      _other.clear();
      _otherOpen = false;
      _error = null;
      _remaining = (q?['remaining'] as num?)?.toInt() ?? 0;
      _stage = q == null ? _Stage.gone : _Stage.asking;
    });
  }

  bool get _multi => _q?['multi'] == true;
  List<String> get _options =>
      List<String>.from((_q?['options'] ?? const []) as List);

  Future<void> _send({bool skip = false}) async {
    final q = _q;
    if (q == null) return;
    setState(() {
      _stage = _Stage.sending;
      _error = null;
    });
    try {
      await _supabase.ownerAnswerQuestion(
        venueId: widget.venueId,
        key: '${q['key']}',
        choices: skip ? const [] : _picked.toList(),
        other: skip ? null : _other.text.trim(),
        skip: skip,
        shown: {
          'prompt': q['prompt'],
          'options': q['options'],
          'price': q['price'],
          'currency': q['currency'],
        },
      );
      if (!mounted) return;
      setState(() {
        _remaining = _remaining > 0 ? _remaining - 1 : 0;
        _stage = skip ? _Stage.gone : _Stage.thanks;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.asking;
        _error = 'That did not save. Please try again.';
      });
    }
  }

  void _tap(String o) {
    if (_stage != _Stage.asking) return;
    if (_multi) {
      setState(() => _picked.contains(o) ? _picked.remove(o) : _picked.add(o));
      return;
    }
    // One answer: a tap is the answer (a short beat so the choice shows).
    setState(() {
      _picked
        ..clear()
        ..add(o);
      _otherOpen = false;
      _other.clear();
    });
    Timer(const Duration(milliseconds: 220), () {
      if (mounted) _send();
    });
  }

  bool get _canSend =>
      _picked.isNotEmpty || (_otherOpen && _other.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final child = switch (_stage) {
      _Stage.loading || _Stage.gone => const SizedBox.shrink(),
      _Stage.thanks => _thanks(),
      _ => _asking(),
    };
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
                position: Tween(
                        begin: const Offset(0, .04), end: Offset.zero)
                    .animate(a),
                child: c)),
        child: KeyedSubtree(
            key: ValueKey('${_stage == _Stage.sending ? 'asking' : _stage.name}'
                '-${_q?['key']}'),
            child: child),
      ),
    );
  }

  Widget _shell({required Widget child}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Brand.border),
          boxShadow: Brand.shadowResting,
        ),
        child: child,
      );

  Widget _asking() {
    final q = _q!;
    final help = '${q['help'] ?? ''}'.trim();
    final busy = _stage == _Stage.sending;
    return _shell(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 26,
            height: 26,
            decoration: const BoxDecoration(
                color: Brand.accentTint, shape: BoxShape.circle),
            child: const Icon(Icons.auto_awesome, size: 14, color: Brand.accent),
          ),
          const SizedBox(width: 9),
          const Expanded(
            child: Text('HELP SHAPE YOUR OWNER ACCOUNT',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .6,
                    color: Brand.inkSecondary)),
          ),
          TextButton(
              onPressed: busy ? null : () => _send(skip: true),
              style: TextButton.styleFrom(
                  foregroundColor: Brand.inkMuted,
                  visualDensity: VisualDensity.compact),
              child: const Text('Not now', style: TextStyle(fontSize: 12.5))),
        ]),
        const SizedBox(height: 8),
        Text('${q['prompt']}',
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, height: 1.35)),
        if (help.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(help,
              style: const TextStyle(
                  fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final o in _options) _option(o, _picked.contains(o), () => _tap(o)),
          if (q['allow_other'] != false)
            _option(_otherOpen ? 'Something else' : 'Something else…',
                _otherOpen, () {
              if (busy) return;
              setState(() {
                _otherOpen = !_otherOpen;
                if (!_multi) _picked.clear();
              });
            }),
        ]),
        if (_otherOpen) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _other,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'In your own words',
              isDense: true,
              filled: true,
              fillColor: Brand.field,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
            ),
          ),
        ],
        if (_multi || _otherOpen) ...[
          const SizedBox(height: 6),
          Row(children: [
            FilledButton(
                onPressed: _canSend && !busy ? () => _send() : null,
                style: FilledButton.styleFrom(
                    backgroundColor: Brand.accent,
                    padding: const EdgeInsets.symmetric(horizontal: 18)),
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Send')),
            if (_multi) ...[
              const SizedBox(width: 10),
              Text(
                  _picked.isEmpty
                      ? 'Pick one or more'
                      : '${_picked.length} picked',
                  style: const TextStyle(
                      fontSize: 12, color: Brand.inkMuted)),
            ],
          ]),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!,
              style: const TextStyle(fontSize: 12.5, color: Brand.accent)),
        ],
        const SizedBox(height: 8),
        const Text(
            'One quick question now and then. Only the Nomadwise team sees '
            'your answers.',
            style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
      ]),
    );
  }

  Widget _option(String label, bool on, VoidCallback onTap) => Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: on ? Brand.ink : Brand.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: on ? Brand.ink : Brand.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (on && _multi) ...[
                const Icon(Icons.check, size: 15, color: Colors.white),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: on ? Colors.white : Brand.ink)),
              ),
            ]),
          ),
        ),
      );

  Widget _thanks() => _shell(
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
                color: Brand.successTint, shape: BoxShape.circle),
            child: const Icon(Icons.check, size: 18, color: Brand.success),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
                'Thank you, that helps us decide what to build next.',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.4)),
          ),
          if (_remaining > 0)
            TextButton(
                onPressed: () => _load(more: true),
                child: const Text('Another quick one')),
          IconButton(
              tooltip: 'Close',
              onPressed: () => setState(() => _stage = _Stage.gone),
              icon: const Icon(Icons.close, size: 18, color: Brand.inkMuted)),
        ]),
      );
}

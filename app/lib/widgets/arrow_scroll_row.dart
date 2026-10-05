import 'package:flutter/material.dart';

import '../theme.dart';

/// A row of chips (or anything) that scrolls sideways: a swipe on a
/// phone, and on a laptop, where a mouse cannot swipe, a round arrow
/// at either end. An arrow only shows when there is more to see in
/// that direction.
class ArrowScrollRow extends StatefulWidget {
  final List<Widget> children;
  final double height;
  final EdgeInsets padding;

  /// The colour the row sits on; the arrows fade into it.
  final Color background;

  const ArrowScrollRow({
    super.key,
    required this.children,
    this.height = 44,
    this.padding = EdgeInsets.zero,
    this.background = Brand.bg,
  });

  @override
  State<ArrowScrollRow> createState() => _ArrowScrollRowState();
}

class _ArrowScrollRowState extends State<ArrowScrollRow> {
  final _scroll = ScrollController();
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_measure);
    _measureSoon();
  }

  @override
  void didUpdateWidget(covariant ArrowScrollRow old) {
    super.didUpdateWidget(old);
    // The chips may have changed: look again once they are laid out.
    _measureSoon();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _measureSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    // Asked for outside a frame (a resized window): make sure one
    // comes, so the callback runs.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _measure() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final left = pos.pixels > 4;
    final right = pos.pixels < pos.maxScrollExtent - 4;
    if (left != _canLeft || right != _canRight) {
      setState(() {
        _canLeft = left;
        _canRight = right;
      });
    }
  }

  void _nudge(bool left) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final target =
        (pos.pixels + (left ? -260 : 260)).clamp(0.0, pos.maxScrollExtent);
    _scroll.animateTo(target,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  Widget _arrow({required bool left}) => Positioned(
        left: left ? 0 : null,
        right: left ? null : 0,
        top: widget.padding.top,
        bottom: widget.padding.bottom,
        child: Container(
          width: 44,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: left ? Alignment.centerRight : Alignment.centerLeft,
              end: left ? Alignment.centerLeft : Alignment.centerRight,
              colors: [
                widget.background.withValues(alpha: 0),
                widget.background
              ],
            ),
          ),
          alignment: left ? Alignment.centerLeft : Alignment.centerRight,
          child: Material(
            color: Brand.surface,
            shape: const CircleBorder(side: BorderSide(color: Brand.border)),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _nudge(left),
              child: SizedBox(
                width: 30,
                height: 30,
                child: Icon(left ? Icons.chevron_left : Icons.chevron_right,
                    size: 20, color: Brand.ink),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Stack(children: [
        // A wider or narrower window changes what fits: measure again.
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _measureSoon();
            return false;
          },
          child: ListView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: widget.padding,
              children: widget.children),
        ),
        if (_canLeft) _arrow(left: true),
        if (_canRight) _arrow(left: false),
      ]),
    );
  }
}

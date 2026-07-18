import 'package:flutter/material.dart';

import '../theme.dart';

/// Shared components from the "Nomad Maps Polish" handoff.
/// One visual language for coins, buttons, labels, toggles and avatars.

/// Gold pill with a coin dot: "+50", "490", etc.
class CoinChip extends StatelessWidget {
  final String text;

  /// solid = gold background w/ navy text (on the navy wifi CTA);
  /// onRed = white overlay pill (inside the red CTA);
  /// default = goldTint pill w/ goldText.
  final bool solid;
  final bool onRed;
  final double height;
  const CoinChip(this.text,
      {super.key, this.solid = false, this.onRed = false, this.height = 24});

  @override
  Widget build(BuildContext context) {
    final bg = solid
        ? Brand.gold
        : onRed
            ? Colors.white.withValues(alpha: .18)
            : Brand.goldTint;
    final fg = solid
        ? Brand.ink
        : onRed
            ? Colors.white
            : Brand.goldTextDark;
    return Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: height * .4),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(height)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        CoinDot(size: height * .5),
        SizedBox(width: height * .22),
        Text(text,
            style: TextStyle(
                fontSize: height * .5,
                fontWeight: FontWeight.w700,
                color: fg)),
      ]),
    );
  }
}

/// The gold coin: rimmed circle stamped with a dollar sign.
class CoinDot extends StatelessWidget {
  final double size;
  const CoinDot({super.key, this.size = 12});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Brand.gold,
          shape: BoxShape.circle,
          border: Border.all(
              color: const Color(0xFFE39B1F), width: size * .09),
        ),
        child: Text('\$',
            style: TextStyle(
                fontSize: size * .58,
                fontWeight: FontWeight.w900,
                color: const Color(0xFF8A5A10),
                height: 1)),
      );
}

/// 38x38 square icon button, radius 12. White + border on the map,
/// field-gray in headers, navy for the wallet button.
class IconSquareButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color? bg;
  final Color? fg;
  final bool floating; // stronger shadow for on-map use
  final Widget? child; // overrides icon when set
  final double size;
  const IconSquareButton(
      {super.key,
      required this.icon,
      this.onTap,
      this.bg,
      this.fg,
      this.floating = false,
      this.child,
      this.size = 38});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: bg ?? Brand.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: bg == null
                ? Border.all(color: Brand.border)
                : null,
            boxShadow:
                floating ? Brand.shadowFloating : null,
          ),
          child: Center(
              child: child ??
                  Icon(icon, size: 20, color: fg ?? Brand.ink)),
        ),
      ),
    );
  }
}

/// "WIFI ────────" section label with hairline filling the row.
/// Optional trailing widget (e.g. an "up to +120" gold hint).
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Row(children: [
        Text(text,
            style: const TextStyle(
                color: Brand.ink,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                letterSpacing: 1.2)),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: Brand.hairline)),
        if (trailing != null) ...[const SizedBox(width: 10), trailing!],
      ]);
}

/// Yes / No / ? toggle: field-gray track, white sliding thumb.
class YesNoToggle extends StatelessWidget {
  final bool? value;
  final ValueChanged<bool?> onChanged;
  const YesNoToggle(
      {super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, bool? v, double w) {
      final selected = value == v;
      return GestureDetector(
        onTap: () => onChanged(v),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: w,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Brand.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: selected ? Brand.shadowResting : null,
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? Brand.ink : Brand.inkMuted)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: Brand.field, borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('Yes', true, 48),
        seg('No', false, 48),
        seg('?', null, 36),
      ]),
    );
  }
}

/// Field label shown ABOVE its input, with optional "· optional" suffix.
class FieldLabel extends StatelessWidget {
  final String text;
  final bool optional;
  const FieldLabel(this.text, {super.key, this.optional = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Text(text,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Brand.inkSecondary)),
          if (optional)
            const Text(' · optional',
                style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
        ]),
      );
}

/// Gray status pill with a dot ("Not screened by nomads yet").
class StatusChip extends StatelessWidget {
  final String text;
  final Color? dotColor;
  const StatusChip(this.text, {super.key, this.dotColor});
  @override
  Widget build(BuildContext context) => Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
            color: Brand.field,
            borderRadius: BorderRadius.circular(13)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                  color: dotColor ?? Brand.inkMuted,
                  shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(text,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Brand.inkSecondary)),
        ]),
      );
}

/// Tinted-initial avatar (photo when available). Tint is stable per name.
class NomadAvatar extends StatelessWidget {
  final String? name;
  final String? photoUrl;
  final double radius;
  const NomadAvatar(
      {super.key, this.name, this.photoUrl, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    final n = (name == null || name!.isEmpty) ? 'N' : name!;
    final tint =
        Brand.avatarTints[n.codeUnits.fold(0, (a, b) => a + b) %
            Brand.avatarTints.length];
    return CircleAvatar(
      radius: radius,
      backgroundColor: tint.$1,
      backgroundImage:
          photoUrl != null ? NetworkImage(photoUrl!) : null,
      child: photoUrl == null
          ? Text(n.substring(0, 1).toUpperCase(),
              style: TextStyle(
                  fontSize: radius * .8,
                  fontWeight: FontWeight.w600,
                  color: tint.$2))
          : null,
    );
  }
}

/// Dashed rounded border (the "Add a photo" row, empty states).
class DashedBorderBox extends StatelessWidget {
  final Widget child;
  final double radius;
  final Color color;
  const DashedBorderBox(
      {super.key,
      required this.child,
      this.radius = 14,
      this.color = const Color(0x33142032)});
  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _DashPainter(radius: radius, color: color),
        child: child,
      );
}

class _DashPainter extends CustomPainter {
  final double radius;
  final Color color;
  _DashPainter({required this.radius, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    const dash = 5.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
            metric.extractPath(d, (d + dash).clamp(0, metric.length)),
            paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashPainter old) =>
      old.color != color || old.radius != radius;
}

/// The screen's one main action: red (or navy) bar with an embedded
/// coin chip.
class PrimaryCta extends StatelessWidget {
  final String label;
  final String? coins; // "+50"
  final VoidCallback? onPressed;
  final bool navy;
  final IconData? icon;
  final Widget? busyChild; // replaces content while working
  const PrimaryCta(
      {super.key,
      required this.label,
      this.coins,
      this.onPressed,
      this.navy = false,
      this.icon,
      this.busyChild});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      width: double.infinity,
      decoration: BoxDecoration(
        color: navy ? Brand.ink : Brand.accent,
        borderRadius: BorderRadius.circular(14),
        boxShadow: onPressed == null
            ? null
            : (navy ? Brand.shadowNavyCta : Brand.shadowRedCta),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Center(
            child: busyChild ??
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20, color: Colors.white),
                    const SizedBox(width: 8),
                  ],
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  if (coins != null) ...[
                    const SizedBox(width: 10),
                    CoinChip(coins!, solid: navy, onRed: !navy),
                  ],
                ]),
          ),
        ),
      ),
    );
  }
}

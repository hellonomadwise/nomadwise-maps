import 'package:flutter/material.dart';

import '../theme.dart';

/// Headline numbers that fill the width they are given (Jonathan,
/// 8 Nov 2026, on the Claim plan on a phone: "Is there wasted space
/// here?"). Three across on a phone, as many as fit on a computer, each
/// the same width, so no half-empty rows of fixed-width boxes.
class StatGrid extends StatelessWidget {
  /// (number, words under it, colour of the number or null)
  final List<(String, String, Color?)> stats;

  /// White boxes with a line round them (on a grey page), or grey boxes
  /// (inside a white card).
  final bool boxed;
  const StatGrid({super.key, required this.stats, this.boxed = false});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final narrow = box.maxWidth < 520;
        const gap = 8.0;
        final fit = (box.maxWidth / 170).floor();
        final cols = narrow ? 3 : (fit < 3 ? 3 : (fit > stats.length ? stats.length : fit));
        // Rows, not a Wrap, so every box in a row is as tall as the
        // tallest one beside it (Jonathan, 11 Nov 2026: "these
        // containers should be consistent"). A label that runs to two
        // lines used to make its own box taller than its neighbours.
        Widget cell(int i) => Container(
              padding: EdgeInsets.all(narrow ? 10 : 14),
              decoration: BoxDecoration(
                color: boxed ? Colors.white : Brand.bg,
                borderRadius: BorderRadius.circular(8),
                border: boxed ? Border.all(color: Brand.border) : null,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(stats[i].$1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: narrow ? 19 : 24,
                        fontWeight: FontWeight.w800,
                        color: stats[i].$3)),
                const SizedBox(height: 2),
                Text(stats[i].$2,
                    style: TextStyle(
                        fontSize: narrow ? 11.5 : 12.5, height: 1.3, color: Brand.inkSecondary)),
              ]),
            );
        return Column(mainAxisSize: MainAxisSize.min, children: [
          for (var r = 0; r < stats.length; r += cols) ...[
            if (r > 0) const SizedBox(height: gap),
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var c = 0; c < cols; c++) ...[
                  if (c > 0) const SizedBox(width: gap),
                  // an empty place keeps a short last row in line
                  Expanded(child: r + c < stats.length ? cell(r + c) : const SizedBox()),
                ],
              ]),
            ),
          ],
        ]);
      });
}

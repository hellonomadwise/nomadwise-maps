import 'package:flutter/material.dart';

/// Away from the web there is no way to show the styled email here:
/// the words are shown instead.
class EmailHtmlView extends StatelessWidget {
  final String html;
  final String text;
  final double height;
  const EmailHtmlView(
      {super.key, required this.html, required this.text, this.height = 560});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText(text,
            style: const TextStyle(fontSize: 14, height: 1.5)),
      );
}

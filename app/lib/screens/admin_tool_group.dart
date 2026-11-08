import 'package:flutter/material.dart';

import '../theme.dart';

/// Control centre: tools that do one job, as tabs in one place
/// (Jonathan, 8 Nov 2026: "would it make sense for some things to live
/// inside others? ... reduce the potential for it to become
/// overwhelming"). Outreach holds Plan, Cards and Sequences; Owners
/// holds Activity, Flow and What they tell us; Chats holds the owners'
/// chats and the Feedback inbox.
///
/// A thin row of tabs above the tool; each tool keeps its own title bar.
/// A tab is only built the first time it is opened, then kept, so
/// moving between tabs does not load it again.
class ToolGroupScreen extends StatefulWidget {
  final List<(String, WidgetBuilder)> tabs;
  final int initial;
  const ToolGroupScreen({super.key, required this.tabs, this.initial = 0});
  @override
  State<ToolGroupScreen> createState() => _ToolGroupScreenState();
}

class _ToolGroupScreenState extends State<ToolGroupScreen> {
  late int _on = widget.initial.clamp(0, widget.tabs.length - 1);
  final Map<int, Widget> _built = {};

  @override
  Widget build(BuildContext context) {
    _built.putIfAbsent(_on, () => widget.tabs[_on].$2(context));
    return Material(
      color: Brand.bg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: Brand.surface,
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFFECEEF1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < widget.tabs.length; i++)
                  Semantics(
                    button: true,
                    selected: i == _on,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => setState(() => _on = i),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 34),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        decoration: BoxDecoration(
                          color: i == _on ? Colors.white : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: i == _on
                              ? const [BoxShadow(color: Color(0x1F142032), blurRadius: 2, offset: Offset(0, 1))]
                              : null,
                        ),
                        child: Text(widget.tabs[i].$1,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: i == _on ? FontWeight.w700 : FontWeight.w600,
                                color: i == _on ? Brand.ink : Brand.inkSecondary)),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        const Divider(height: 1, color: Brand.border),
        // The tool's own title bar sits under the tabs: kept a little
        // lower here, so the two do not take a fifth of a phone screen.
        Expanded(
          child: Theme(
            data: Theme.of(context).copyWith(
                appBarTheme: Theme.of(context).appBarTheme.copyWith(toolbarHeight: 48)),
            child: IndexedStack(index: _on, children: [
            for (var i = 0; i < widget.tabs.length; i++)
              _built[i] ?? const SizedBox.shrink(),
            ]),
          ),
        ),
      ]),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:url_launcher/url_launcher.dart';

import '../services/products_service.dart';
import '../theme.dart';
import '../widgets/price.dart';

/// The database's own words for a refused action.
String _plainError(Object e) {
  if (e is PostgrestException) return e.message;
  final s = '$e';
  final m = RegExp(r'message: (.*?), code: ', dotAll: true).firstMatch(s);
  return m?.group(1)?.trim() ?? s;
}

String _when(dynamic iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '';
  return DateFormat('d MMM yyyy').format(d.toLocal());
}

/// A day the database keeps as midnight UTC (the day a price was
/// checked): shown as that day wherever the reader is.
String _day(dynamic iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '';
  return DateFormat('d MMM yyyy').format(d.toUtc());
}

String _monthYear(dynamic iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '';
  return DateFormat('MMM yyyy').format(d.toLocal());
}

int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

String _num(int n) => NumberFormat.decimalPattern().format(n);

String _withScheme(String u) => u.startsWith('http') ? u : 'https://$u';

void _openLink(String url) {
  final u = Uri.tryParse(_withScheme(url.trim()));
  if (u != null) launchUrl(u, webOnlyWindowName: '_blank');
}

const _categories = <(String, String)>[
  ('coworking', 'Coworking'),
  ('meeting_room', 'Meeting room'),
  ('private_office', 'Private office'),
  ('other', 'Other'),
];

String _catLabel(dynamic k) => switch ('$k') {
      'coworking' => 'Coworking',
      'meeting_room' => 'Meeting room',
      'private_office' => 'Private office',
      _ => 'Other',
    };

/// The detail lines of a product, as text.
List<String> _details(dynamic v) => [
      if (v is List)
        for (final x in v)
          if ('$x'.trim().isNotEmpty) '$x'.trim()
    ];

Map<String, dynamic> _asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// The price as the page shows it.
String _priceOf(Map<String, dynamic> p) {
  final label = '${p['label'] ?? ''}'.trim();
  return label.isEmpty ? 'No price shown' : label;
}

/// An amount as it is typed into the price box ("1,500", "12.50").
String _amountText(dynamic amount) {
  if (amount is! num) return '';
  final whole = amount == amount.roundToDouble();
  return Price.cleanAmount(
      whole ? amount.toInt().toString() : amount.toStringAsFixed(2));
}

/// The price as the database writes it by itself from an amount and
/// a currency: "€25", "A$25", "100,000 IDR", or "Price on request".
String _autoLabel(num? amount, String code) {
  if (amount == null) return 'Price on request';
  final a = _amountText(amount);
  final c = code.trim().toUpperCase();
  if (c.isEmpty) return a;
  return c == 'AUD' ? 'A\$$a' : Price.format(a, c);
}

/// What differs between two versions of a product, in words.
List<String> _differences(Map<String, dynamic> a, Map<String, dynamic> b) {
  final out = <String>[];
  if ('${a['name'] ?? ''}' != '${b['name'] ?? ''}') {
    out.add('Name: "${a['name'] ?? ''}" becomes "${b['name'] ?? ''}"');
  }
  if (_priceOf(a) != _priceOf(b)) {
    out.add('Price: ${_priceOf(a)} becomes ${_priceOf(b)}');
  }
  if ('${a['category'] ?? ''}' != '${b['category'] ?? ''}') {
    out.add('Category: ${_catLabel(a['category'])} becomes '
        '${_catLabel(b['category'])}');
  }
  final da = _details(a['details']), db = _details(b['details']);
  if (da.join('\n') != db.join('\n')) {
    out.add(db.isEmpty
        ? 'Details: removed'
        : da.isEmpty
            ? 'Details: added'
            : 'Details: reworded');
  }
  return out;
}

Widget _chip(String text, {Color? bg, Color? fg}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: bg ?? Brand.field, borderRadius: BorderRadius.circular(20)),
      child: Text(text,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: fg ?? Brand.inkSecondary)),
    );

/// What the page has now on the left, what is proposed on the right;
/// one under the other where the screen is narrow.
Widget _compare(Widget left, Widget right) => LayoutBuilder(
      builder: (ctx, box) => box.maxWidth >= 620
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: left),
              const SizedBox(width: 10),
              Expanded(child: right),
            ])
          : Column(children: [left, right]),
    );

/// One version of a product in a box: name, price, details.
Widget _productBox(String label, Map<String, dynamic> p,
    {required bool proposed, String? foot, String? instead}) {
  final details = _details(p['details']);
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
        color: proposed ? Brand.logoTealTint : Brand.field,
        borderRadius: BorderRadius.circular(8)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label.toUpperCase(),
          style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.4,
              fontWeight: FontWeight.w800,
              color: proposed ? Brand.logoNavy : Brand.inkMuted)),
      const SizedBox(height: 4),
      if (instead != null)
        Text(instead,
            style: const TextStyle(
                fontSize: 13.5, height: 1.45, color: Brand.ink))
      else ...[
        SelectableText('${p['name'] ?? ''}',
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: proposed ? Brand.ink : Brand.inkSecondary)),
        const SizedBox(height: 2),
        SelectableText(_priceOf(p),
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: proposed ? Brand.ink : Brand.inkSecondary)),
        Text(_catLabel(p['category']),
            style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
        if (details.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final d in details)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('• $d',
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: proposed ? Brand.ink : Brand.inkSecondary)),
            ),
        ],
      ],
      if (foot != null && foot.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(foot,
            style: const TextStyle(
                fontSize: 11.5, height: 1.4, color: Brand.inkMuted)),
      ],
    ]),
  );
}

/// The note that goes with "Request a price check". Returns the note
/// (it may be empty), or null when the box was closed without asking.
Future<String?> _askCheckNote(
    BuildContext context, String name, String start) async {
  final note = TextEditingController(text: start);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Request a price check for $name'),
      content: SizedBox(
        width: 480,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'The space is put on the list to be checked: each price '
                  'on our page is compared with the space\'s own website. '
                  'What matches is marked as checked. What differs comes '
                  'back here, the current price next to the one on their '
                  'website, and waits for your Go.',
                  style: TextStyle(fontSize: 13.5, height: 1.45)),
              const SizedBox(height: 14),
              TextField(
                controller: note,
                maxLines: 3,
                maxLength: 400,
                decoration: const InputDecoration(
                    labelText: 'Anything to know (optional)',
                    hintText: 'Their prices are on the Membership page.',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
            ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Request a check')),
      ],
    ),
  );
  // The controller is left to the garbage collector: the dialog reads
  // it while it closes.
  if (ok != true) return null;
  return note.text.trim();
}

/// The box to correct a product, or to type a new one. Returns the
/// fields to save, or null when it was closed without saving.
Future<Map<String, dynamic>?> _askProduct(BuildContext context,
    {required String title,
    required Map<String, dynamic> start,
    required String currency,
    required String action}) async {
  final name = TextEditingController(text: '${start['name'] ?? ''}');
  final amount = TextEditingController(text: _amountText(start['amount']));
  final cur = TextEditingController(
      text: '${start['currency'] ?? currency}'.toUpperCase());
  // The price as shown is only kept in the box when it was written by
  // hand ("£40 + VAT"); otherwise it follows the amount.
  final startLabel = '${start['label'] ?? ''}'.trim();
  final startCode = '${start['currency'] ?? currency}'.toUpperCase();
  // What the database writes by itself for this amount (with the
  // product's own currency, which a few have none of).
  final autoLabel = _autoLabel(
      start['amount'] is num ? start['amount'] as num : null,
      '${start['currency'] ?? ''}');
  final custom = startLabel.isNotEmpty &&
      startLabel.replaceAll(' ', '') != autoLabel.replaceAll(' ', '');
  final label = TextEditingController(text: custom ? startLabel : '');
  final details =
      TextEditingController(text: _details(start['details']).join('\n'));
  var category = '${start['category'] ?? 'coworking'}';
  if (!_categories.any((c) => c.$1 == category)) category = 'coworking';
  String? problem;

  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setInner) {
        void save() {
          final n = name.text.trim();
          if (n.length < 2) {
            setInner(() => problem = 'The product needs a name.');
            return;
          }
          final typed = amount.text.trim();
          num? value;
          if (typed.isNotEmpty) {
            value = num.tryParse(
                Price.cleanAmount(typed).replaceAll(',', ''));
            if (value == null) {
              setInner(() => problem =
                  'Type the price as a number, like 25 or 1,500.');
              return;
            }
          }
          final code = cur.text.trim().toUpperCase();
          if ((value != null || code.isNotEmpty) &&
              !RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
            setInner(() => problem =
                'The currency is three letters, like EUR, GBP or IDR.');
            return;
          }
          var shown = label.text.trim();
          if (custom &&
              shown == startLabel &&
              (value != start['amount'] || code != startCode)) {
            setInner(() => problem =
                'The price changed, but "Shown on the page as" still says '
                '"$startLabel". Update it, or clear it to have it written '
                'from the price.');
            return;
          }
          if (custom && shown.isEmpty) {
            // A hand-written label was cleared: write it from the
            // price here, since the database keeps the old one while
            // the amount has not moved.
            shown = _autoLabel(value, code);
          }
          Navigator.pop(ctx, <String, dynamic>{
            'name': n,
            'category': category,
            'amount': value,
            if (code.isNotEmpty) 'currency': code,
            // Empty: the database writes it from the amount.
            'label': shown,
            'details': [
              for (final line in details.text.split('\n'))
                if (line.trim().isNotEmpty) line.trim()
            ],
          });
        }

        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: name,
                      autofocus: true,
                      maxLength: 80,
                      decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'Day Pass',
                          border: OutlineInputBorder(),
                          isDense: true),
                    ),
                    const SizedBox(height: 4),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final c in _categories)
                        ChoiceChip(
                          label: Text(c.$2),
                          showCheckmark: false,
                          selectedColor: Brand.ink,
                          labelStyle: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: category == c.$1
                                  ? Colors.white
                                  : Brand.ink),
                          selected: category == c.$1,
                          onSelected: (_) => setInner(() => category = c.$1),
                        ),
                    ]),
                    const SizedBox(height: 14),
                    Row(children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          onChanged: (_) => setInner(() {}),
                          decoration: const InputDecoration(
                              labelText: 'Price (the number only)',
                              hintText: '25',
                              border: OutlineInputBorder(),
                              isDense: true),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: cur,
                          maxLength: 3,
                          textCapitalization: TextCapitalization.characters,
                          onChanged: (_) => setInner(() {}),
                          decoration: const InputDecoration(
                              labelText: 'Currency',
                              hintText: 'EUR',
                              counterText: '',
                              border: OutlineInputBorder(),
                              isDense: true),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    TextField(
                      controller: label,
                      maxLength: 40,
                      decoration: InputDecoration(
                          labelText: 'Shown on the page as (optional)',
                          // What will be written, when the amount
                          // reads as a number.
                          hintText: amount.text.trim().isEmpty
                              ? 'Price on request'
                              : num.tryParse(Price.cleanAmount(amount.text)
                                          .replaceAll(',', '')) ==
                                      null
                                  ? null
                                  : _autoLabel(
                                      num.parse(Price.cleanAmount(amount.text)
                                          .replaceAll(',', '')),
                                      cur.text),
                          helperText: 'Leave empty and it is written from the '
                              'price. Fill it in only for something like '
                              '"£40 + VAT".',
                          helperMaxLines: 2,
                          border: const OutlineInputBorder(),
                          isDense: true),
                    ),
                    const SizedBox(height: 4),
                    TextField(
                      controller: details,
                      minLines: 3,
                      maxLines: 8,
                      decoration: const InputDecoration(
                          labelText: 'Details, one per line (optional)',
                          hintText: 'Valid for one day\nIncludes coffee',
                          border: OutlineInputBorder(),
                          isDense: true),
                    ),
                    if (problem != null) ...[
                      const SizedBox(height: 10),
                      Text(problem!,
                          style: const TextStyle(
                              fontSize: 13, color: Brand.red)),
                    ],
                    const SizedBox(height: 10),
                    const Text(
                        'Only what the space\'s own website shows: the same '
                        'currency, the same unit, nothing worked out from '
                        'another price.',
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: Brand.inkSecondary)),
                  ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(onPressed: save, child: Text(action)),
          ],
        );
      },
    ),
  );
  // The controllers are left to the garbage collector: the dialog is
  // still on screen while it closes, and reads them until then.
  return result;
}

/// Price check (migration 131): the products each coworking page
/// shows (day pass, month pass, meeting room, ...) and whether their
/// prices still match the space's own website. Taken one space at a
/// time: a founder requests a check, the check comes back with what
/// matches marked as checked and what differs laid out current next
/// to proposed, and each change has its own Go. Nothing reaches the
/// public page until a founder presses Go; the website push then
/// writes it within minutes, and Undo puts the old one back.
/// Founders only.
class AdminPricesScreen extends StatefulWidget {
  const AdminPricesScreen({super.key});
  @override
  State<AdminPricesScreen> createState() => _AdminPricesScreenState();
}

class _AdminPricesScreenState extends State<AdminPricesScreen> {
  final _api = ProductsService();
  final _search = TextEditingController();
  Map<String, dynamic>? _overview;
  List<Map<String, dynamic>>? _rows;
  String _filter = '';
  String? _error;
  int _limit = 60;
  final Set<String> _busy = {};
  bool _copying = false;
  int _req = 0;

  static const _filters = <(String, String)>[
    ('', 'All spaces'),
    ('waiting', 'Waiting for your Go'),
    ('requested', 'Requested'),
    ('unchecked', 'Never checked'),
    ('checked', 'Checked'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final n = ++_req;
    try {
      final rows = await _api.spaces(
          query: _search.text.trim(), filter: _filter, limit: _limit);
      final overview = await _api.overview();
      if (!mounted || n != _req) return;
      setState(() {
        _rows = rows;
        _overview = overview;
        _error = null;
      });
    } catch (e) {
      if (mounted && n == _req) setState(() => _error = _plainError(e));
    }
  }

  void _snack(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  Future<void> _request(Map<String, dynamic> r) async {
    final id = '${r['id']}';
    if (_busy.contains(id)) return;
    final open = r['request'];
    final note = await _askCheckNote(context, '${r['name'] ?? 'this space'}',
        open is Map ? '${open['note'] ?? ''}' : '');
    if (note == null || !mounted) return;
    setState(() => _busy.add(id));
    try {
      await _api.requestCheck(id, note: note.isEmpty ? null : note);
      _snack('${r['name']}: requested. Use "Copy requests" to pass the '
          'list on.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _withdraw(Map<String, dynamic> r) async {
    final id = '${r['id']}';
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await _api.cancelRequest(id);
      _snack('${r['name']}: request withdrawn.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _open(Map<String, dynamic> r) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => _PriceSpacePage(
                venueId: '${r['id']}', name: '${r['name'] ?? ''}')));
    if (!mounted) return;
    await _load();
  }

  /// The requested spaces as text to paste into a chat: each with its
  /// page, its own website and what our page shows today.
  Future<void> _copyRequests() async {
    if (_copying) return;
    setState(() => _copying = true);
    try {
      final rows = await _api.requests();
      if (rows.isEmpty) {
        _snack('No price check has been requested yet.');
        return;
      }
      final lines = <String>['Price check requests (${rows.length}):'];
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        final site = '${r['website'] ?? ''}'.trim();
        final note = '${r['note'] ?? ''}'.trim();
        lines
          ..add('')
          ..add('${i + 1}. ${r['name']}')
          ..add('   Slug: ${r['slug'] ?? ''}')
          ..add('   Our page: ${r['page'] ?? '(not on the website)'}')
          ..add('   Their website: ${site.isEmpty ? '(none on file)' : _withScheme(site)}');
        if (note.isNotEmpty) lines.add('   Note: $note');
        lines.add('   On our page now:');
        final products = r['products'];
        if (products is List) {
          for (final p in products) {
            if (p is! Map) continue;
            final label = '${p['label'] ?? ''}'.trim();
            lines.add('   - [${p['id']}] ${p['name']}: '
                '${label.isEmpty ? 'no price shown' : label} '
                '(${_catLabel(p['category'])})');
          }
        }
      }
      final text = lines.join('\n');
      var copied = true;
      try {
        await Clipboard.setData(ClipboardData(text: text));
      } catch (_) {
        // A browser may refuse the clipboard after a wait: show the
        // list to copy by hand instead.
        copied = false;
      }
      if (!mounted) return;
      if (copied) {
        _snack('${rows.length} copied. Paste the list to Claude to have '
            'the prices checked.');
      } else {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Requested price checks'),
            content: SizedBox(
              width: 620,
              child: SingleChildScrollView(child: SelectableText(text)),
            ),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Done')),
            ],
          ),
        );
      }
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  void _showHelp() {
    Widget step(String n, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: Brand.ink, shape: BoxShape.circle),
              child: Text(n,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(body,
                        style: const TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: Brand.inkSecondary)),
                  ]),
            ),
          ]),
        );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('How the price check works'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'The rule: a price on our page is the price on the '
                      'space\'s own website. If a space ever asks, the '
                      'answer is "it is the one on your site".',
                      style: TextStyle(fontSize: 13.5, height: 1.45)),
                  const SizedBox(height: 14),
                  step('1', 'Request a check',
                      'Press "Request a price check" on a space, then "Copy '
                          'requests" and paste the list to Claude.'),
                  step('2', 'The check',
                      'Each product on our page is compared with the '
                          'space\'s own website. Never with another '
                          'directory, a review or Google.'),
                  step('3', 'What comes back',
                      'A price that matches is marked as checked, with the '
                          'day and the page it was seen on. A price that '
                          'differs is shown next to the one on their '
                          'website. A product they no longer offer, or a '
                          'new one, is proposed too.'),
                  step('4', 'Your Go',
                      'Go puts that one change on the public page within '
                          'minutes. Edit lets you change it first. Skip '
                          'leaves the page as it is. Undo puts the old one '
                          'back.'),
                  const Text(
                      'Until a space is checked, its prices stay on the '
                      'page exactly as they are. You can also correct, add '
                      'or remove a product yourself at any time.',
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: Brand.inkSecondary)),
                ]),
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Got it')),
        ],
      ),
    );
  }

  Widget _numbers(Map<String, dynamic> o) {
    final products = _int(o['products']);
    final checked = _int(o['checked']);
    final oldest = _monthYear(o['oldest']);
    final pulled = _when(o['pulled_at']);
    Widget tile(String big, String small, {Color? color}) => Container(
          width: 150,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: Brand.surface,
              border: Border.all(color: Brand.border),
              borderRadius: BorderRadius.circular(10)),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(big,
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: color ?? Brand.ink)),
                const SizedBox(height: 2),
                Text(small,
                    style: const TextStyle(
                        fontSize: 12, height: 1.3, color: Brand.inkSecondary)),
              ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        tile(_num(products), 'products on ${_num(_int(o['spaces']))} pages'),
        tile('${_num(checked)} of ${_num(products)}',
            'checked against the space\'s own website',
            color: checked == 0 ? Brand.goldTextDark : Brand.success),
        tile(_num(_int(o['waiting'])), 'changes waiting for your Go',
            color: _int(o['waiting']) > 0 ? Brand.logoNavy : null),
        tile(_num(_int(o['requested'])), 'checks requested'),
        if (_int(o['failed']) > 0)
          tile(_num(_int(o['failed'])), 'need a look', color: Brand.red),
      ]),
      const SizedBox(height: 8),
      Text(
          [
            if (oldest.isNotEmpty)
              'The oldest unchecked price has been on the website since '
                  '$oldest.',
            if (pulled.isNotEmpty) 'Last copied from the website: $pulled.',
          ].join(' '),
          style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
    ]);
  }

  Widget _card(Map<String, dynamic> r) {
    final id = '${r['id']}';
    final name = '${r['name'] ?? ''}'.trim();
    final where = [r['city'], r['country']]
        .map((x) => '${x ?? ''}'.trim())
        .where((x) => x.isNotEmpty)
        .join(', ');
    final busy = _busy.contains(id);
    final open = r['request'];
    final requested = open is Map;
    final note = requested ? '${open['note'] ?? ''}'.trim() : '';
    final waiting = _int(r['waiting']);
    final onWay = _int(r['on_the_way']);
    final failed = _int(r['failed']);
    final products = _int(r['products']);
    final checked = _int(r['checked']);
    final seen = _int(r['seen']);
    final page = '${r['page'] ?? ''}'.trim();
    final site = '${r['website'] ?? ''}'.trim();
    final since = _monthYear(r['site_oldest']);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Brand.surface,
        border: Border.all(color: Brand.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(name.isEmpty ? 'A space' : name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15.5)),
              if (waiting > 0)
                _chip('$waiting WAITING FOR YOUR GO',
                    bg: Brand.logoTealTint, fg: Brand.logoNavy),
              if (requested)
                _chip('REQUESTED', bg: Brand.goldTint, fg: Brand.goldTextDark),
              if (failed > 0)
                _chip('$failed NEED A LOOK', bg: Brand.accentTint, fg: Brand.red),
              if (onWay > 0) _chip('$onWay ON THE WAY'),
              if (r['owned'] == true)
                _chip('HAS AN OWNER',
                    bg: Brand.goldTint, fg: Brand.goldTextDark),
              if (r['page_live'] != true) _chip('PAGE NOT LIVE'),
            ]),
        const SizedBox(height: 3),
        Text(
            [
              if (where.isNotEmpty) where,
              '$products ${products == 1 ? 'product' : 'products'}',
              if (since.isNotEmpty) 'on the website since $since',
            ].join(' · '),
            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        const SizedBox(height: 4),
        Text(
            seen == 0
                ? 'Never checked against their website.'
                : checked == products
                    ? 'All $products checked against their website, last on '
                        '${_when(r['last_seen'])}.'
                    : '$checked of $products match their website; last '
                        'looked at on ${_when(r['last_seen'])}.',
            style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: seen == 0
                    ? Brand.inkMuted
                    : checked == products
                        ? Brand.success
                        : Brand.goldTextDark)),
        if (requested)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                'Requested on ${_when(open['at'])}. Waiting to be checked.'
                '${note.isEmpty ? '' : ' "$note"'}',
                style: const TextStyle(
                    fontSize: 12.5, height: 1.4, color: Brand.goldTextDark)),
          ),
        const SizedBox(height: 8),
        Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                  onPressed: () => _open(r),
                  icon: const Icon(Icons.sell_outlined, size: 18),
                  label: Text(waiting + failed > 0 ? 'Review' : 'Open')),
              if (!requested)
                OutlinedButton(
                    onPressed: busy ? null : () => _request(r),
                    child: const Text('Request a price check'))
              else ...[
                TextButton(
                    onPressed: busy ? null : () => _request(r),
                    child: const Text('Change the note')),
                TextButton(
                    onPressed: busy ? null : () => _withdraw(r),
                    child: const Text('Withdraw')),
              ],
              if (page.isNotEmpty)
                TextButton.icon(
                    onPressed: () => _openLink(page),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Our page')),
              if (site.isNotEmpty)
                TextButton.icon(
                    onPressed: () => _openLink(site),
                    icon: const Icon(Icons.language, size: 16),
                    label: const Text('Their website')),
            ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final overview = _overview;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Price check'),
        actions: [
          IconButton(
              tooltip: 'How it works',
              onPressed: _showHelp,
              icon: const Icon(Icons.help_outline)),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, style: const TextStyle(color: Brand.red)),
                  const SizedBox(height: 12),
                  OutlinedButton(
                      onPressed: () {
                        setState(() => _error = null);
                        _load();
                      },
                      child: const Text('Try again')),
                ]),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
                      children: [
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Expanded(
                                child: Text(
                                    'The passes, rooms and offices each '
                                    'coworking page shows, and whether their '
                                    'prices still match the space\'s own '
                                    'website. One space at a time: request a '
                                    'check, then decide each change yourself. '
                                    'Changes waiting for your Go come first, '
                                    'then the spaces not looked at yet. A '
                                    'space that has been looked at moves to '
                                    'the bottom, the longest ago first, and '
                                    'is under "Checked".',
                                    style: TextStyle(
                                        fontSize: 13,
                                        height: 1.45,
                                        color: Brand.inkSecondary)),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                  onPressed: _copying ? null : _copyRequests,
                                  icon: const Icon(Icons.copy, size: 16),
                                  label: const Text('Copy requests')),
                            ]),
                        const SizedBox(height: 12),
                        if (overview != null) _numbers(overview),
                        const SizedBox(height: 12),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final f in _filters)
                            ChoiceChip(
                              label: Text(f.$2),
                              showCheckmark: false,
                              selectedColor: Brand.ink,
                              labelStyle: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: _filter == f.$1
                                      ? Colors.white
                                      : Brand.ink),
                              selected: _filter == f.$1,
                              onSelected: (_) {
                                setState(() {
                                  _filter = f.$1;
                                  _limit = 60;
                                  _rows = null;
                                });
                                _load();
                              },
                            ),
                        ]),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) {
                            setState(() => _rows = null);
                            _load();
                          },
                          decoration: InputDecoration(
                            hintText: 'Search by space, city or country, '
                                'then press Enter',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _search.clear();
                                      setState(() => _rows = null);
                                      _load();
                                    }),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (rows == null)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(
                                child: CircularProgressIndicator(
                                    color: Brand.red)),
                          )
                        else if (rows.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text(
                                  switch (_search.text.trim().isNotEmpty
                                      ? 'search'
                                      : _filter) {
                                    'search' => 'No space matches that.',
                                    'requested' =>
                                      'No price check has been requested yet.',
                                    'waiting' =>
                                      'Nothing is waiting for your Go.',
                                    'unchecked' =>
                                      'Every space has been looked at.',
                                    'checked' =>
                                      'No space has been checked yet.',
                                    _ => 'No space matches that.',
                                  },
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Brand.inkSecondary)),
                            ),
                          )
                        else ...[
                          for (final r in rows) _card(r),
                          if (rows.length >= _limit && _limit < 300)
                            Center(
                              child: TextButton(
                                  onPressed: () {
                                    setState(() => _limit =
                                        _limit + 60 > 300 ? 300 : _limit + 60);
                                    _load();
                                  },
                                  child: const Text('Show more')),
                            ),
                        ],
                      ]),
                ),
              ),
            ),
    );
  }
}

/// One space: every product its page shows, with what the last check
/// found, and the changes waiting for a Go.
class _PriceSpacePage extends StatefulWidget {
  final String venueId;
  final String name;
  const _PriceSpacePage({required this.venueId, required this.name});
  @override
  State<_PriceSpacePage> createState() => _PriceSpacePageState();
}

class _PriceSpacePageState extends State<_PriceSpacePage> {
  final _api = ProductsService();
  Map<String, dynamic>? _data;
  String? _error;
  // Changes and products with an action on its way, so a second tap
  // does nothing.
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.space(widget.venueId);
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // With the page already on screen, a failed reload says so and
      // leaves what is there.
      if (_data != null) {
        _snack('Could not reload: ${_plainError(e)}', bad: true);
      } else {
        setState(() => _error = _plainError(e));
      }
    }
  }

  void _snack(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  /// The currency a new product starts with: the one the space's
  /// other products use, else its country's.
  String get _currency {
    final v = _asMap(_data?['venue']);
    final used = '${v['currency'] ?? ''}'.trim().toUpperCase();
    if (used.isNotEmpty) return used;
    return Price.forCountry('${v['country'] ?? ''}') ?? 'EUR';
  }

  /// Runs one action with the busy guard, the message and the reload.
  Future<void> _run(String key, Future<String?> Function() action) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      final said = await action();
      if (said != null) _snack(said);
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
      await _load();
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _go(Map<String, dynamic> c) => _run('${c['id']}', () async {
        await _api.go('${c['id']}');
        return 'On its way to the website. It takes a few minutes.';
      });

  Future<void> _skip(Map<String, dynamic> c) => _run('${c['id']}', () async {
        await _api.skip('${c['id']}');
        return 'Skipped. The page stays as it is.';
      });

  /// Edit a proposal, then send that version.
  Future<void> _editChange(Map<String, dynamic> c) async {
    final start = _asMap(c['final'] ?? c['proposed']);
    final edited = await _askProduct(context,
        title: '${c['action']}' == 'add'
            ? 'New product'
            : 'Change "${start['name'] ?? 'this product'}"',
        start: start,
        currency: _currency,
        action: 'Go with this');
    if (edited == null || !mounted) return;
    await _run('${c['id']}', () async {
      await _api.go('${c['id']}', edited: edited);
      return 'On its way to the website. It takes a few minutes.';
    });
  }

  Future<void> _undo(Map<String, dynamic> c, String name) async {
    final status = '${c['status']}';
    if (status == 'applied') {
      final what = switch ('${c['action']}') {
        'remove' => '"$name" goes back on the page, as it was.',
        'add' => '"$name" is taken off the page again.',
        _ => '"$name" goes back to what the page showed before this change.',
      };
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Undo this change?'),
          content: Text('$what It takes a few minutes.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep the change')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Undo it')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _run('${c['id']}', () async {
      final was = await _api.undo('${c['id']}');
      return switch (was) {
        'applied' => 'The earlier version is being put back.',
        'approved' => 'Taken back before it was written.',
        _ => 'Back to decide again.',
      };
    });
  }

  /// A founder's own correction to a product on the page.
  Future<void> _editProduct(Map<String, dynamic> p) async {
    final edited = await _askProduct(context,
        title: 'Correct "${p['name'] ?? 'this product'}"',
        start: p,
        currency: _currency,
        action: 'Save and put on the page');
    if (edited == null || !mounted) return;
    await _run('${p['id']}', () async {
      await _api.edit(widget.venueId,
          productId: '${p['id']}', action: 'update', product: edited);
      return 'Saved. On its way to the website.';
    });
  }

  Future<void> _removeProduct(Map<String, dynamic> p) async {
    final headline = p['starting_from'] == true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Take "${p['name']}" off the page?'),
        content: Text(
            'It is removed from the public page within minutes. It is kept '
            'in Webflow, archived, so Undo can put it back.'
            '${headline ? '\n\nThis is the product whose price shows as '
                '"starting from" on the page. Without it the page has no '
                'starting price until another product is chosen in '
                'Webflow.' : ''}',
            style: const TextStyle(height: 1.45)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Take it off')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run('${p['id']}', () async {
      await _api.edit(widget.venueId,
          productId: '${p['id']}', action: 'remove');
      return 'On its way: "${p['name']}" is being taken off the page.';
    });
  }

  Future<void> _addProduct() async {
    final made = await _askProduct(context,
        title: 'Add a product',
        start: const <String, dynamic>{},
        currency: _currency,
        action: 'Save and put on the page');
    if (made == null || !mounted) return;
    await _run('add', () async {
      await _api.edit(widget.venueId, action: 'add', product: made);
      return 'Saved. On its way to the website.';
    });
  }

  Future<void> _request() async {
    final open = _data?['request'];
    final note = await _askCheckNote(context, widget.name,
        open is Map ? '${open['note'] ?? ''}' : '');
    if (note == null || !mounted) return;
    await _run('request', () async {
      await _api.requestCheck(widget.venueId,
          note: note.isEmpty ? null : note);
      return 'Requested. Use "Copy requests" on the list to pass it on.';
    });
  }

  Future<void> _withdraw() => _run('request', () async {
        await _api.cancelRequest(widget.venueId);
        return 'Request withdrawn.';
      });

  /// "Based on": where the check saw it, and when.
  Widget _basedOn(Map<String, dynamic> c) {
    final note = '${c['note'] ?? ''}'.trim();
    final url = '${c['source_url'] ?? ''}'.trim();
    final on = _when(c['checked_on']);
    if ('${c['source']}' != 'check') {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('Your own change.',
            style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            'Based on: ${note.isEmpty ? 'their website' : note}'
            '${on.isEmpty ? '' : ' (checked $on)'}',
            style: const TextStyle(
                fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
        if (url.isNotEmpty)
          InkWell(
            onTap: () => _openLink(url),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(url,
                  style: const TextStyle(
                      fontSize: 12.5,
                      color: Brand.logoNavy,
                      decoration: TextDecoration.underline)),
            ),
          ),
      ]),
    );
  }

  /// The buttons under a change, by where it stands.
  Widget _changeButtons(Map<String, dynamic> c, String name) {
    final id = '${c['id']}';
    final busy = _busy.contains(id);
    final status = '${c['status']}';
    final isRemove = '${c['action']}' == 'remove';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (status == 'proposed' || status == 'failed') ...[
              FilledButton.icon(
                  onPressed: busy ? null : () => _go(c),
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(status == 'failed' ? 'Go again' : 'Go')),
              if (!isRemove)
                OutlinedButton(
                    onPressed: busy ? null : () => _editChange(c),
                    child: const Text('Edit')),
              TextButton(
                  onPressed: busy ? null : () => _skip(c),
                  child: const Text('Skip')),
            ],
            if (status == 'approved') ...[
              const Text('On its way to the website.',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Brand.logoNavy)),
              TextButton(
                  onPressed: busy ? null : () => _undo(c, name),
                  child: const Text('Take it back')),
            ],
            if (status == 'undo_requested')
              Text(
                  switch ('${c['action']}') {
                    'add' => 'It is being taken off the page again.',
                    'remove' => 'It is being put back on the page.',
                    _ => 'The earlier version is being put back.',
                  },
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Brand.logoNavy)),
          ]),
    );
  }

  /// A product whose price is a discount agreed with the space: the
  /// original price and the saving shown beside it live in Webflow.
  Widget _discountNote(Map<String, dynamic> p) {
    if (p['discount'] != true) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(top: 8),
      child: Text(
          'This price is a Nomadwise discount. A new price here replaces '
          'the discounted price only; the original price and the saving '
          'shown beside it are changed in Webflow.',
          style: TextStyle(
              fontSize: 12.5, height: 1.4, color: Brand.goldTextDark)),
    );
  }

  /// What the last look at this product found.
  String _checkedLine(Map<String, dynamic> p) {
    final since = _when(p['site_updated_at']);
    final result = '${p['check_result'] ?? ''}';
    final note = '${p['check_note'] ?? ''}'.trim();
    final seen = _when(p['check_seen_at']);
    final parts = <String>[
      if (since.isNotEmpty) 'On the website since $since.',
    ];
    if (result == 'same' && p['checked_at'] != null) {
      parts.add('Checked ${_day(p['checked_at'])}: the same as on their '
          'website.');
    } else if (result == 'changed' && p['checked_at'] != null) {
      parts.add('Corrected to match their website, as checked on '
          '${_day(p['checked_at'])}.');
    } else if (result == 'differs') {
      parts.add('Looked at${seen.isEmpty ? '' : ' on $seen'}: their website '
          'shows something different, and the page was left as it is.'
          '${note.isEmpty ? '' : ' $note'}');
    } else if (result == 'not_found') {
      parts.add('Looked for${seen.isEmpty ? '' : ' on $seen'}: not found on '
          'their website.${note.isEmpty ? '' : ' $note'}');
    } else {
      parts.add('Not checked against their website yet.');
    }
    return parts.join(' ');
  }

  Widget _frame({required Widget child, Color? border}) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Brand.surface,
          border: Border.all(color: border ?? Brand.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );

  Widget _statusChip(Map<String, dynamic> c) => switch ('${c['status']}') {
        'proposed' => _chip('WAITING FOR YOUR GO',
            bg: Brand.logoTealTint, fg: Brand.logoNavy),
        'approved' => _chip('ON THE WAY'),
        'undo_requested' => _chip('BEING PUT BACK'),
        'failed' => _chip('NEEDS A LOOK', bg: Brand.accentTint, fg: Brand.red),
        _ => const SizedBox.shrink(),
      };

  Widget _failure(Map<String, dynamic> c) {
    final error = '${c['error'] ?? ''}'.trim();
    if (error.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
          '${c['status']}' == 'failed'
              ? 'It could not be written: $error'
              : error,
          style: const TextStyle(fontSize: 12.5, height: 1.4, color: Brand.red)),
    );
  }

  /// One product on the page, with the change in hand if there is one.
  Widget _productCard(Map<String, dynamic> p) {
    final id = '${p['id']}';
    final name = '${p['name'] ?? ''}';
    final open = p['open'] is Map ? _asMap(p['open']) : null;
    final last = p['last'] is Map ? _asMap(p['last']) : null;
    final busy = _busy.contains(id);
    final result = '${p['check_result'] ?? ''}';
    final checkedUrl = '${p['checked_url'] ?? ''}'.trim();

    final head = Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(name,
              style:
                  const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          if (open != null) _statusChip(open),
          if (open == null && result == 'same' && p['checked_at'] != null)
            _chip('CHECKED', bg: Brand.successTint, fg: Brand.success),
          if (open == null && result == 'changed' && p['checked_at'] != null)
            _chip('CHECKED', bg: Brand.successTint, fg: Brand.success),
          if (open == null && result == 'differs')
            _chip('DIFFERS FROM THEIR SITE',
                bg: Brand.goldTint, fg: Brand.goldTextDark),
          if (open == null && result == 'not_found')
            _chip('NOT FOUND ON THEIR SITE',
                bg: Brand.goldTint, fg: Brand.goldTextDark),
          if (p['starting_from'] == true) _chip('"STARTING FROM" PRICE'),
          if (p['discount'] == true)
            _chip('NOMADWISE DISCOUNT',
                bg: Brand.goldTint, fg: Brand.goldTextDark),
          if (p['affiliate'] == true) _chip('AFFILIATE LINK'),
        ]);

    if (open != null) {
      final action = '${open['action']}';
      // An undo on its way goes back to what the page had before.
      final undoing = '${open['status']}' == 'undo_requested';
      final target = _asMap(
          undoing ? open['before'] : (open['final'] ?? open['proposed']));
      final diffs = action == 'update' ? _differences(p, target) : <String>[];
      return _frame(
        border: '${open['status']}' == 'proposed'
            ? Brand.logoTeal
            : '${open['status']}' == 'failed'
                ? Brand.red
                : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          head,
          _compare(
            _productBox('On our page now', p, proposed: false),
            undoing && action == 'add'
                ? _productBox('Being undone', const <String, dynamic>{},
                    proposed: true,
                    instead: 'This product is being taken off the page '
                        'again.')
                : action == 'remove'
                    ? _productBox('Proposed', const <String, dynamic>{},
                        proposed: true,
                        instead: 'Take this product off the page: it is no '
                            'longer offered.')
                    : _productBox(
                        undoing
                            ? 'Going back to'
                            : '${open['source']}' == 'check'
                                ? 'On their website'
                                : 'Your change',
                        target,
                        proposed: true,
                        foot: diffs.join('\n')),
          ),
          if (!undoing) _basedOn(open),
          _discountNote(p),
          _failure(open),
          _changeButtons(open, name),
        ]),
      );
    }

    return _frame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        head,
        _productBox('On our page', p, proposed: false, foot: _checkedLine(p)),
        if (checkedUrl.isNotEmpty && p['checked_at'] != null)
          InkWell(
            onTap: () => _openLink(checkedUrl),
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Seen on: $checkedUrl',
                  style: const TextStyle(
                      fontSize: 12.5,
                      color: Brand.logoNavy,
                      decoration: TextDecoration.underline)),
            ),
          ),
        _discountNote(p),
        if (last != null) _failure(last),
        const SizedBox(height: 8),
        Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                  onPressed: busy ? null : () => _editProduct(p),
                  child: const Text('Correct it')),
              TextButton(
                  onPressed: busy ? null : () => _removeProduct(p),
                  child: const Text('Take it off the page')),
              if (last != null && '${last['status']}' == 'applied')
                TextButton(
                    onPressed: _busy.contains('${last['id']}')
                        ? null
                        : () => _undo(last, name),
                    child: Text('Undo the change of '
                        '${_when(last['applied_at'])}')),
              if (last != null &&
                  '${last['status']}' == 'skipped' &&
                  '${last['source']}' == 'check')
                TextButton(
                    onPressed: _busy.contains('${last['id']}')
                        ? null
                        : () => _undo(last, name),
                    child: const Text('Bring the skipped change back')),
            ]),
      ]),
    );
  }

  /// A product proposed for the page, not on it yet.
  Widget _addCard(Map<String, dynamic> c) {
    final target = _asMap(c['final'] ?? c['proposed']);
    final name = '${target['name'] ?? 'New product'}';
    final status = '${c['status']}';
    return _frame(
      border: status == 'proposed'
          ? Brand.logoTeal
          : status == 'failed'
              ? Brand.red
              : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
              _chip('NEW', bg: Brand.logoTealTint, fg: Brand.logoNavy),
              if (status == 'skipped') _chip('SKIPPED') else _statusChip(c),
            ]),
        _productBox(
            '${c['source']}' == 'check'
                ? 'On their website, not on our page'
                : 'Your new product',
            target,
            proposed: true),
        _basedOn(c),
        _failure(c),
        if (status == 'skipped' && '${c['source']}' == 'check')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton(
                onPressed: _busy.contains('${c['id']}')
                    ? null
                    : () => _undo(c, name),
                child: const Text('Bring it back')),
          )
        else if (status != 'skipped')
          _changeButtons(c, name),
      ]),
    );
  }

  /// A product taken off the page lately, with its Undo.
  Widget _removedCard(Map<String, dynamic> p) {
    final name = '${p['name'] ?? ''}';
    final open = p['open'] is Map ? _asMap(p['open']) : null;
    final last = p['last'] is Map ? _asMap(p['last']) : null;
    final change = open ?? last;
    return _frame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: Brand.inkSecondary)),
              _chip('OFF THE PAGE'),
              if (open != null) _statusChip(open),
            ]),
        const SizedBox(height: 4),
        Text(
            [
              _priceOf(p),
              if (last != null && _when(last['applied_at']).isNotEmpty)
                'taken off on ${_when(last['applied_at'])}',
            ].join(' · '),
            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        if (change != null) _failure(change),
        if (open != null)
          _changeButtons(open, name)
        else if (last != null && '${last['status']}' == 'applied')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton(
                onPressed: _busy.contains('${last['id']}')
                    ? null
                    : () => _undo(last, name),
                child: Text('${last['action']}' == 'remove'
                    ? 'Put it back on the page'
                    : 'Undo')),
          ),
      ]),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 8),
        child: Text(title.toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                letterSpacing: 0.5,
                fontWeight: FontWeight.w800,
                color: Brand.inkMuted)),
      );

  @override
  Widget build(BuildContext context) {
    final d = _data;
    Widget body;
    if (_error != null && d == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, style: const TextStyle(color: Brand.red)),
            const SizedBox(height: 12),
            OutlinedButton(
                onPressed: () {
                  setState(() => _error = null);
                  _load();
                },
                child: const Text('Try again')),
          ]),
        ),
      );
    } else if (d == null) {
      body = const Center(child: CircularProgressIndicator(color: Brand.red));
    } else {
      final v = _asMap(d['venue']);
      final where = [v['city'], v['country']]
          .map((x) => '${x ?? ''}'.trim())
          .where((x) => x.isNotEmpty)
          .join(', ');
      final page = '${v['page'] ?? ''}'.trim();
      final site = '${v['website'] ?? ''}'.trim();
      final request = d['request'] is Map ? _asMap(d['request']) : null;
      final requestNote = '${request?['note'] ?? ''}'.trim();
      final check = d['last_check'] is Map ? _asMap(d['last_check']) : null;
      final products = [
        for (final x in (d['products'] as List? ?? const []))
          if (x is Map) Map<String, dynamic>.from(x)
      ];
      final adds = [
        for (final x in (d['adds'] as List? ?? const []))
          if (x is Map) Map<String, dynamic>.from(x)
      ];
      final removed = [
        for (final x in (d['removed'] as List? ?? const []))
          if (x is Map) Map<String, dynamic>.from(x)
      ];
      // What needs a decision first, then the rest in page order.
      final waiting = [
        for (final p in products)
          if (p['open'] is Map) p
      ];
      final settled = [
        for (final p in products)
          if (p['open'] is! Map) p
      ];
      final openAdds = [
        for (final c in adds)
          if ('${c['status']}' != 'skipped') c
      ];
      final skippedAdds = [
        for (final c in adds)
          if ('${c['status']}' == 'skipped') c
      ];
      final found = check == null ? null : _asMap(check['result']);
      final checkUrl = '${check?['checked_url'] ?? ''}'.trim();
      final summary = '${check?['summary'] ?? ''}'.trim();

      body = RefreshIndicator(
        onRefresh: _load,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
                children: [
                  Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('${v['name'] ?? widget.name}',
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                        if (v['owned'] == true)
                          _chip('HAS AN OWNER',
                              bg: Brand.goldTint, fg: Brand.goldTextDark),
                        if (v['page_live'] != true) _chip('PAGE NOT LIVE'),
                      ]),
                  if (where.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(where,
                          style: const TextStyle(
                              fontSize: 13, color: Brand.inkSecondary)),
                    ),
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 6, children: [
                    if (page.isNotEmpty)
                      OutlinedButton.icon(
                          onPressed: () => _openLink(page),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('Our page')),
                    if (site.isNotEmpty)
                      OutlinedButton.icon(
                          onPressed: () => _openLink(site),
                          icon: const Icon(Icons.language, size: 16),
                          label: const Text('Their website')),
                    if (request == null)
                      FilledButton.tonal(
                          onPressed:
                              _busy.contains('request') ? null : _request,
                          child: const Text('Request a price check')),
                  ]),
                  if (request != null)
                    Container(
                      margin: const EdgeInsets.only(top: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: Brand.goldTint,
                          borderRadius: BorderRadius.circular(10)),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                'A price check was requested on '
                                '${_when(request['at'])}. It is waiting to '
                                'be done.'
                                '${requestNote.isEmpty ? '' : ' "$requestNote"'}',
                                style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.45,
                                    color: Brand.goldTextDark)),
                            Wrap(spacing: 4, children: [
                              TextButton(
                                  onPressed: _busy.contains('request')
                                      ? null
                                      : _request,
                                  child: const Text('Change the note')),
                              TextButton(
                                  onPressed: _busy.contains('request')
                                      ? null
                                      : _withdraw,
                                  child: const Text('Withdraw')),
                            ]),
                          ]),
                    ),
                  if (check != null)
                    Container(
                      margin: const EdgeInsets.only(top: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: Brand.field,
                          borderRadius: BorderRadius.circular(10)),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                'Last check: '
                                '${_when(check['checked_on'] ?? check['done_at'])}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            if (found != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                    [
                                      '${_int(found['same'])} the same',
                                      '${_int(found['changed'])} different',
                                      '${_int(found['not_found'])} not found',
                                      '${_int(found['gone'])} no longer '
                                          'offered',
                                      '${_int(found['new'])} new',
                                    ].join(' · '),
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: Brand.inkSecondary)),
                              ),
                            if (summary.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(summary,
                                    style: const TextStyle(
                                        fontSize: 13, height: 1.45)),
                              ),
                            if (checkUrl.isNotEmpty)
                              InkWell(
                                onTap: () => _openLink(checkUrl),
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(checkUrl,
                                      style: const TextStyle(
                                          fontSize: 12.5,
                                          color: Brand.logoNavy,
                                          decoration:
                                              TextDecoration.underline)),
                                ),
                              ),
                          ]),
                    ),
                  if (v['owned'] == true)
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text(
                          'This page has an owner. They can tell us their '
                          'prices in the Owner account; anything changed '
                          'here still goes on the page.',
                          style: TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              color: Brand.goldTextDark)),
                    ),
                  if (waiting.isNotEmpty || openAdds.isNotEmpty) ...[
                    _section('To decide'),
                    for (final p in waiting) _productCard(p),
                    for (final c in openAdds) _addCard(c),
                  ],
                  if (waiting.isEmpty || settled.isNotEmpty)
                    _section(waiting.isEmpty
                        ? 'On the page (${products.length})'
                        : 'On the page, nothing to decide '
                            '(${settled.length})'),
                  if (products.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('This page shows no products.',
                          style: TextStyle(color: Brand.inkSecondary)),
                    ),
                  for (final p in settled) _productCard(p),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                        onPressed: _busy.contains('add') ? null : _addProduct,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add a product')),
                  ),
                  if (removed.isNotEmpty || skippedAdds.isNotEmpty) ...[
                    _section('Taken off or skipped lately'),
                    for (final p in removed) _removedCard(p),
                    for (final c in skippedAdds) _addCard(c),
                  ],
                ]),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.name.isEmpty ? 'Prices' : widget.name)),
      body: body,
    );
  }
}

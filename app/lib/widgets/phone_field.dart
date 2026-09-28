import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'dial_codes.dart';

/// A phone number in two parts: the country code, picked from a
/// searchable list (people typed wrong codes by hand), and the number
/// itself, digits only. [country] holds the ISO code (e.g. 'PT');
/// [number] the digits. [PhoneField.compose] joins them for saving.
class PhoneField extends StatefulWidget {
  final TextEditingController number;
  final ValueNotifier<String?> country;
  final String label;
  final String? helper;
  const PhoneField({
    super.key,
    required this.number,
    required this.country,
    this.label = 'Phone or WhatsApp (optional)',
    this.helper,
  });

  /// The ISO code for a country name as we store it on venues
  /// ('Portugal', 'UK', 'Viet Nam'...), or null.
  static String? isoFor(String? countryName) {
    final n = (countryName ?? '').trim().toLowerCase();
    if (n.isEmpty) return null;
    const alias = {
      'uk': 'GB',
      'england': 'GB',
      'scotland': 'GB',
      'wales': 'GB',
      'usa': 'US',
      'united states of america': 'US',
      'viet nam': 'VN',
      'czech republic': 'CZ',
      'the netherlands': 'NL',
      'holland': 'NL',
      'uae': 'AE',
      'korea': 'KR',
      'bali': 'ID',
    };
    if (alias.containsKey(n)) return alias[n];
    for (final (name, iso, _) in dialCodes) {
      if (name.toLowerCase() == n) return iso;
    }
    return null;
  }

  static int? dialFor(String? iso) {
    if (iso == null) return null;
    for (final (_, i, code) in dialCodes) {
      if (i == iso) return code;
    }
    return null;
  }

  /// "+351 912345678", or '' when no number was given. A national
  /// leading 0 is dropped (07700 900123 in the UK is +44 7700 900123),
  /// except in Italy, where it belongs to the number.
  static String compose(String? iso, String number) {
    var digits = number.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    final code = dialFor(iso);
    if (code == null) return digits;
    if (digits.startsWith('00$code')) digits = digits.substring(2 + '$code'.length);
    if (iso != 'IT' && digits.startsWith('0')) digits = digits.substring(1);
    return '+$code $digits';
  }

  /// Null when fine, or what is wrong, in plain words.
  static String? problem(String? iso, String number) {
    final digits = number.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null; // optional
    if (iso == null) return 'Pick the country code for your phone number.';
    if (digits.length < 6 || digits.length > 15) {
      return 'That phone number looks too ${digits.length < 6 ? 'short' : 'long'}.';
    }
    return null;
  }

  @override
  State<PhoneField> createState() => _PhoneFieldState();
}

class _PhoneFieldState extends State<PhoneField> {
  @override
  void initState() {
    super.initState();
    widget.country.addListener(_changed);
  }

  @override
  void dispose() {
    widget.country.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _pick() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => const _DialPicker(),
    );
    if (chosen != null) widget.country.value = chosen;
  }

  @override
  Widget build(BuildContext context) {
    final code = PhoneField.dialFor(widget.country.value);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 104,
        child: InkWell(
          onTap: _pick,
          borderRadius: BorderRadius.circular(10),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Code',
              filled: true,
              fillColor: Brand.surface,
            ),
            child: Row(children: [
              Expanded(
                child: Text(
                    code == null
                        ? 'Pick'
                        : '${widget.country.value} +$code',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        color: code == null ? Brand.inkMuted : Brand.ink)),
              ),
              const Icon(Icons.arrow_drop_down,
                  size: 20, color: Brand.inkSecondary),
            ]),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: TextField(
          controller: widget.number,
          keyboardType: TextInputType.phone,
          inputFormatters: [
            // Numbers only (spaces allowed for reading); the code is
            // picked on the left.
            FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
            LengthLimitingTextInputFormatter(20),
          ],
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: 'Number, without the country code',
            helperText: widget.helper,
            filled: true,
            fillColor: Brand.surface,
          ),
        ),
      ),
    ]);
  }
}

class _DialPicker extends StatefulWidget {
  const _DialPicker();
  @override
  State<_DialPicker> createState() => _DialPickerState();
}

class _DialPickerState extends State<_DialPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase().replaceAll('+', '');
    final rows = dialCodes
        .where((r) =>
            q.isEmpty ||
            r.$1.toLowerCase().contains(q) ||
            r.$2.toLowerCase() == q ||
            '${r.$3}'.startsWith(q))
        .toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _q = v),
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Country, or code like 351',
                  border: OutlineInputBorder()),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (_, i) {
                final (name, iso, code) = rows[i];
                return ListTile(
                  dense: true,
                  title: Text(name),
                  trailing: Text('+$code',
                      style: const TextStyle(
                          color: Brand.inkSecondary,
                          fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.of(context).pop(iso),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

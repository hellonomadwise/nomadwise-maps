/// Suggested replies for Send back (owner changes), worked out from what
/// the owner actually entered: a short description, salesy words, a phone
/// number in the description, prices with symbols, a WhatsApp number with
/// no country code, and so on. Each one is a friendly, specific note the
/// founder can tap into the reply box, read, adjust and send.
///
/// The owner email already opens with "Thank you for updating ... we have
/// a small suggestion" and ends with how to sign in, so each note is only
/// the suggestion itself. House rules for owner-facing words: no dashes
/// as punctuation, no time promises, no overselling.
class ReplySuggestion {
  /// Short button label, e.g. "Short description".
  final String label;

  /// Why it was suggested, in a few words, e.g. "12 words".
  final String why;

  /// The note itself, ready to send.
  final String text;

  const ReplySuggestion(this.label, this.why, this.text);
}

String _s(dynamic x) => (x ?? '').toString().trim();

int _words(String t) =>
    t.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).length;

const _salesy = [
  'the best',
  'best coworking',
  'best cafe',
  'best coffee',
  'number one',
  'no. 1',
  '#1',
  'cheapest',
  'unbeatable',
  'world class',
  'world-class',
  'ultimate',
  'perfect place',
  'guaranteed',
  'like no other',
  'second to none',
];

const _englishMarkers = {
  'the', 'and', 'to', 'a', 'of', 'in', 'is', 'for', 'with', 'we', 'you',
  'our', 'are', 'on', 'at', 'your', 'it', 'or', 'from', 'has', 'have', 'all',
};

/// Works out the replies that fit this submission. [draft] is what the
/// owner submitted; [verified] says whether the page is Verified (the
/// message in the advert slot only exists there).
List<ReplySuggestion> suggestReplies(Map<String, dynamic> draft,
    {bool verified = false}) {
  final out = <ReplySuggestion>[];
  final desc = _s(draft['description']);
  final lower = desc.toLowerCase();
  final n = _words(desc);

  // ---------------------------------------------------- description
  if (desc.isEmpty) {
    out.add(const ReplySuggestion(
        'No description',
        'description is empty',
        'Could you add a few sentences about the space itself: the desks, '
            'the WiFi and what a working day there is like? That is what '
            'remote workers look for first, and it is what makes your page '
            'stand out.'));
  } else if (n < 25) {
    out.add(ReplySuggestion(
        'Short description',
        '$n words',
        'Thank you for the description, it is a good start. Could you add '
            'two or three more sentences about the space itself: the desks, '
            'the WiFi and what a working day there is like? That is what '
            'remote workers look for first.'));
  } else if (n > 350) {
    out.add(ReplySuggestion(
        'Long description',
        '$n words',
        'Thank you for such a full description. Could you trim it to the '
            'essentials, ideally under 250 words? Nomads tend to skim on '
            'their phones, so the desks, the WiFi and the feel of the place '
            'are the parts that matter most.'));
  }

  if (desc.isNotEmpty) {
    final found = _salesy.where((p) => lower.contains(p)).toList();
    final shouting = RegExp(r'\b[A-Z]{4,}\b')
        .allMatches(desc)
        .map((m) => m.group(0)!)
        .where((w) => !const {'WIFI', 'HTTP', 'HTTPS'}.contains(w))
        .length;
    final bangs = '!'.allMatches(desc).length;
    if (found.isNotEmpty || shouting >= 3 || bangs >= 3) {
      final quote = found.isNotEmpty ? '"${found.first}"' : null;
      out.add(ReplySuggestion(
          'Too salesy',
          quote ?? (shouting >= 3 ? 'capital letters' : 'exclamation marks'),
          'We keep every page factual, so could you describe the space in '
              'plain words${quote != null ? ', without phrases like $quote' : ''}'
              '${quote == null && shouting >= 3 ? ', without words in capitals' : ''}'
              '${quote == null && shouting < 3 && bangs >= 3 ? ', with fewer exclamation marks' : ''}? '
              'Nomads trust pages that read like a friend\'s tip.'));
    }

    final hasEmail = RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+').hasMatch(desc);
    final hasLink =
        RegExp(r'(https?://|www\.)|\b[\w-]+\.(com|net|org|io|co|pt|es|de)\b',
                caseSensitive: false)
            .hasMatch(desc);
    final hasPhone = RegExp(r'(\+?\d[\d\s().-]{7,}\d)').hasMatch(desc);
    if (hasEmail || hasLink || hasPhone) {
      final what = [
        if (hasPhone) 'phone number',
        if (hasEmail) 'email address',
        if (hasLink) 'link',
      ].join(' and ');
      out.add(ReplySuggestion(
          'Contact details in text',
          what,
          'Could you take the $what out of the description? There are '
              'separate boxes for your website, Instagram and WhatsApp, and '
              'they show on the page as buttons, which is easier for nomads '
              'to tap.'));
    }

    if (n >= 15) {
      final ws = lower
          .split(RegExp(r'[^a-zà-ÿ]+'))
          .where((w) => w.isNotEmpty)
          .toList();
      final english = ws.where(_englishMarkers.contains).length;
      if (ws.isNotEmpty && english / ws.length < 0.06) {
        out.add(const ReplySuggestion(
            'Not in English',
            'description language',
            'Could you write the description in English? Most nomads read '
                'the page in English, and you are welcome to add a line in '
                'your own language at the end.'));
      }
    }
  }

  // --------------------------------------------------------- prices
  final prices = Map<String, dynamic>.from(draft['prices'] as Map? ?? {});
  final symbols = <String>[];
  double? price(String k) {
    final v = _s(prices[k]);
    if (v.isEmpty) return null;
    if (RegExp(r'[^\d\s.,]').hasMatch(v)) symbols.add(v);
    final m = RegExp(r'\d+(?:[.,]\d+)?').firstMatch(v);
    return m == null ? null : double.tryParse(m.group(0)!.replaceAll(',', '.'));
  }

  final day = price('day'), week = price('week'), month = price('month');
  price('coffee');
  if (symbols.isNotEmpty) {
    out.add(ReplySuggestion(
        'Prices as numbers',
        '"${symbols.first}"',
        'Could you enter your prices as plain numbers, for example 15 '
            'rather than "${symbols.first}"? The currency is set once, just '
            'above the prices, and the page adds it for you.'));
  }
  if ((day != null && month != null && day > month) ||
      (day != null && week != null && day > week) ||
      (week != null && month != null && week > month)) {
    out.add(const ReplySuggestion(
        'Prices look swapped',
        'a shorter pass costs more',
        'Could you check your pass prices? A shorter pass looks more '
            'expensive than a longer one, so two of them may have been '
            'swapped.'));
  }

  // --------------------------------------------------------- photos
  final photos = (draft['photos'] as List? ?? const []);
  if (draft.containsKey('photos') && photos.isNotEmpty && photos.length < 3) {
    out.add(ReplySuggestion(
        'More photos',
        '${photos.length} photo${photos.length == 1 ? '' : 's'}',
        'Thank you for the photo${photos.length == 1 ? '' : 's'}. Could you '
            'add a few more of the workspace itself, ideally in daylight: '
            'the desks, the seating and the coffee? Three or more makes the '
            'page much more convincing.'));
  }

  // -------------------------------------------------------- contact
  final wa = _s(draft['whatsapp']);
  if (wa.isNotEmpty) {
    final digits = wa.replaceAll(RegExp(r'\D'), '');
    if ((!wa.startsWith('+') && !wa.startsWith('00')) ||
        digits.length < 8 ||
        digits.length > 15) {
      out.add(const ReplySuggestion(
          'WhatsApp number',
          'country code missing',
          'Could you add your WhatsApp number with the country code, for '
              'example +351 912 345 678? Without it, the WhatsApp button on '
              'your page cannot open the chat.'));
    }
  }

  final ig = _s(draft['instagram']);
  if (ig.isNotEmpty) {
    final handle = ig
        .replaceAll(RegExp(r'^https?://(www\.)?instagram\.com/'), '')
        .replaceAll('@', '')
        .replaceAll(RegExp(r'/.*$'), '');
    if (ig.contains(' ') ||
        (ig.contains('.') && !ig.toLowerCase().contains('instagram.com') &&
            RegExp(r'\.(com|net|org)').hasMatch(ig)) ||
        !RegExp(r'^[A-Za-z0-9._]{1,30}$').hasMatch(handle)) {
      out.add(const ReplySuggestion(
          'Instagram name',
          'does not look like a handle',
          'Could you check your Instagram name? We need just the name, for '
              'example @yourspace, so the button on your page opens the '
              'right profile.'));
    }
  }

  final web = _s(draft['website']);
  if (web.isNotEmpty) {
    final l = web.toLowerCase();
    if (l.contains(' ') || !l.contains('.')) {
      out.add(const ReplySuggestion(
          'Website address',
          'not a web address',
          'Could you check your website address? It should look like '
              'yourspace.com, so the button on your page opens your site.'));
    } else if (RegExp(r'instagram\.com|facebook\.com|wa\.me|linktr\.ee')
        .hasMatch(l)) {
      out.add(const ReplySuggestion(
          'Website is a social link',
          'social link in the website box',
          'The website box has a social media link in it. If you have your '
              'own website, could you add that instead? Instagram and '
              'WhatsApp have their own boxes and show as separate buttons.'));
    }
  }

  final enq = _s(draft['enquiry_email']);
  if (enq.isNotEmpty &&
      !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(enq)) {
    out.add(const ReplySuggestion(
        'Enquiry email',
        'not an email address',
        'Could you check the email address for enquiries? It does not look '
            'quite right, and we want every enquiry to reach you.'));
  }

  // ----------------------------------------------- Verified message
  if (verified) {
    final m = Map<String, dynamic>.from(draft['mention'] as Map? ?? {});
    final title = _s(m['title']);
    final body = _s(m['body']);
    if (title.length > 60) {
      out.add(ReplySuggestion(
          'Message headline',
          '${title.length} characters',
          'Could you shorten the headline of your message to a few words? '
              'It sits in a small box beside your page, so something like '
              '"Free coffee on your first day" works best.'));
    }
    final ml = '$title $body'.toLowerCase();
    if (_salesy.any(ml.contains) && !out.any((x) => x.label == 'Too salesy')) {
      out.add(const ReplySuggestion(
          'Message too salesy',
          'message wording',
          'Could you word your message plainly, as an offer or a piece of '
              'news? Nomads respond best to something concrete, like a free '
              'first coffee or a quiet room for calls.'));
    }
  }

  return out;
}

/// The general replies, for anything the checks cannot see.
const generalReplies = <(String, String)>[
  (
    'About the space',
    'Could you add a few sentences about the space itself: the desks, the '
        'WiFi and what a working day there is like? That is what remote '
        'workers look for first.'
  ),
  (
    'Prices',
    'Could you add your prices as plain numbers, for example a day pass and '
        'a month pass? The currency is set once, just above the prices.'
  ),
  (
    'Photos',
    'Could you add a few photos of the workspace itself, ideally in '
        'daylight: the desks, the seating and the coffee? Photos of the '
        'space do more than logos or menus.'
  ),
  (
    'Too salesy',
    'We keep every page factual, so could you describe the space in plain '
        'words, without "the best" or "number one"? Nomads trust pages that '
        'read like a friend\'s tip.'
  ),
  (
    'Opening hours',
    'Could you check your opening hours? One of the days looks different '
        'from what we expected, and we want nomads to arrive when you are '
        'open.'
  ),
  (
    'Contact details',
    'Could you check your WhatsApp number and Instagram name? One of them '
        'did not look quite right.'
  ),
  (
    'In English',
    'Could you write the description in English? Most nomads read the '
        'page in English, and you are welcome to add a line in your own '
        'language at the end.'
  ),
];

/// Several notes as one reply, in the order given.
String combineReplies(List<ReplySuggestion> s) {
  if (s.isEmpty) return '';
  if (s.length == 1) return s.first.text;
  return 'A few small things:\n\n${s.map((x) => x.text).join('\n\n')}';
}

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/flow_sound_stub.dart'
    if (dart.library.html) '../services/flow_sound_web.dart' as sound;
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/motion.dart';
import 'admin_email_flow_screen.dart';
import 'admin_outreach_screen.dart';
import 'admin_sequences_screen.dart';
import 'claim_journeys_screen.dart';

/// Owner flow (migration 203): the space-owner journey as a map, top
/// to bottom, on real numbers.
///
/// Jonathan, 29 Oct 2026: "I want to be able to see where it gets
/// blocked ... so that I am able to go, okay, we need to make this
/// particular area better ... for each of the points where we lose
/// them, I'm looking for us to see what steps we can take to push them
/// along." Calm, minimal, top to bottom on every screen.
///
/// One bead per real owner runs down the map (team tests left out):
/// lead in (website or outreach) -> claim page -> claimed -> logs in,
/// or the reminder sequence -> owner account -> submits an edit ->
/// our review -> approved and live -> comes back (Active), or not
/// (Dormant), or Premium. The amber boxes are where owners stop. Tap
/// any box to see who is there, what would push them along (manual or
/// a system to build), and a tick per owner once the step is done
/// (owner_flow_ticks, so it is the same on the phone and the laptop).
class AdminOwnerFlowScreen extends StatefulWidget {
  const AdminOwnerFlowScreen({super.key});

  @override
  State<AdminOwnerFlowScreen> createState() => _AdminOwnerFlowScreenState();
}

// ---------------------------------------------------------------------
// The map: boxes and the lines between them, on a 400 x 1100 canvas
// that is scaled to fit.

class _Node {
  final String key;
  final String label;
  final String? sub;
  final double x, y, w;
  final bool block; // an amber stop
  final bool bar; // a system that runs by itself (reminders, review)
  final bool strip; // the cafe / coworking gate
  final bool off; // not yet (co-living)
  final String? result; // premium | active | dormant | waiting | lost
  const _Node(this.key, this.label, this.x, this.y, this.w,
      {this.sub,
      this.block = false,
      this.bar = false,
      this.strip = false,
      this.off = false,
      this.result});
  bool get tappable => !strip;
}

const double _kH = 30; // box height on the canvas

const List<_Node> _kNodes = [
  _Node('web', 'WEBSITE', 120, 48, 120, sub: 'CLAIM BUTTON ON LISTING'),
  _Node('out', 'OUTREACH', 280, 48, 120, sub: 'WE EMAIL THE OWNER'),
  _Node('cafe', 'CAFÉ', 60, 138, 68, strip: true),
  _Node('cowork', 'COWORKING', 200, 138, 90, strip: true),
  _Node('coliv', 'CO-LIVING', 340, 138, 80, sub: 'LATER', off: true, strip: true),
  _Node('claim', 'CLAIM PAGE', 200, 238, 120),
  _Node('noclaim', 'NO CLAIM', 355, 238, 86, block: true),
  _Node('followup', 'CLAIM-PAGE SIGNAL', 315, 328, 150,
      sub: '"WAS THIS YOU?" EMAIL', bar: true),
  _Node('claimed', 'CLAIMED', 150, 328, 100, sub: 'FREE PROFILE'),
  _Node('loginnow', 'LOGS IN', 100, 428, 100),
  _Node('nologin', 'NO LOGIN', 300, 428, 100),
  _Node('remind', 'REMINDER SEQUENCE', 290, 518, 210, sub: 'EMAIL 1 · 2 · 3', bar: true),
  _Node('never', 'NEVER', 355, 618, 86, block: true),
  _Node('cc', 'OWNER ACCOUNT', 100, 618, 130),
  _Node('updated', 'SUBMITS EDIT', 100, 718, 120),
  _Node('left', 'LOOKS ONLY', 215, 718, 86, sub: 'NO EDIT', block: true),
  _Node('review', 'YOUR REVIEW', 100, 808, 150, bar: true),
  _Node('approved', 'APPROVED · LIVE', 100, 898, 130, sub: 'CHANGES-LIVE EMAIL'),
  _Node('declined', 'DECLINED', 262, 898, 76, block: true),
  // after approval, by time (Jonathan, 3 Nov 2026): new under 14 days
  // since approval, active when seen in the last 30, quiet 30 to 60
  // days since last seen, dormant after 60
  _Node('premium', 'PREMIUM', 42, 985, 58, result: 'premium'),
  _Node('new', 'NEW', 106, 985, 58, sub: 'UNDER 14 D', result: 'new'),
  _Node('active', 'ACTIVE', 170, 985, 58, sub: 'SEEN < 30 D', result: 'active'),
  _Node('quiet', 'QUIET', 234, 985, 58, sub: '30 TO 60 D', result: 'quiet'),
  _Node('dormant', 'DORMANT', 298, 985, 58, sub: 'OVER 60 D', result: 'dormant'),
  _Node('lost', 'LOST', 362, 985, 58, result: 'lost'),
];

const List<List<String>> _kEdges = [
  ['web', 'claim'],
  ['out', 'claim'],
  ['claim', 'noclaim'],
  ['claim', 'claimed'],
  ['claimed', 'loginnow'],
  ['claimed', 'nologin'],
  ['nologin', 'remind'],
  ['remind', 'cc'],
  ['remind', 'never'],
  ['loginnow', 'cc'],
  ['cc', 'updated'],
  ['cc', 'left'],
  ['updated', 'review'],
  ['review', 'approved'],
  ['review', 'declined'],
  ['approved', 'premium'],
  ['approved', 'new'],
  ['approved', 'active'],
  ['approved', 'quiet'],
  ['approved', 'dormant'],
  ['declined', 'new'],
  ['declined', 'quiet'],
  ['declined', 'dormant'],
  ['left', 'new'],
  ['left', 'quiet'],
  ['left', 'dormant'],
  ['never', 'lost'],
  ['noclaim', 'followup'],
  ['followup', 'claimed'],
  ['followup', 'lost'],
];

/// Where a line turns, when the midpoint would cross something.
const Map<String, double> _kVia = {
  'web>claim': 195,
  'out>claim': 195,
  'followup>lost': 378,
  // everything after review joins one rail above the results
  'left>new': 950,
  'left>quiet': 950,
  'left>dormant': 950,
  'declined>new': 950,
  'declined>quiet': 950,
  'declined>dormant': 950,
  'approved>premium': 950,
  'approved>new': 950,
  'approved>active': 950,
  'approved>quiet': 950,
  'approved>dormant': 950,
  'never>lost': 962,
};

/// Row labels down the left.
const List<(String, double)> _kRows = [
  ('LEAD SOURCE', 27),
  ('SPACE OWNER', 117),
  ('CLAIM', 217),
  ('LOG IN', 407),
  ('USE', 597),
  ('REVIEW', 787),
  ('RESULT', 964),
];

final Map<String, _Node> _kByKey = {for (final n in _kNodes) n.key: n};

/// A high pentatonic run (C6 D6 E6 G6 A6 C7 D7 E7): one note a hop.
const List<double> _kScale = [1046.5, 1174.7, 1318.5, 1568, 1760, 2093, 2349.3, 2637];

Path _edgePath(String a, String b) {
  final na = _kByKey[a]!, nb = _kByKey[b]!;
  final p = Path();
  if ((na.y - nb.y).abs() < 1) {
    final d = nb.x > na.x ? 1 : -1;
    p.moveTo(na.x + d * na.w / 2, na.y);
    p.lineTo(nb.x - d * nb.w / 2, nb.y);
    return p;
  }
  final y1 = na.y + _kH / 2, y2 = nb.y - _kH / 2;
  final ym = _kVia['$a>$b'] ?? (y1 + y2) / 2;
  p.moveTo(na.x, y1);
  p.lineTo(na.x, ym);
  p.lineTo(nb.x, ym);
  p.lineTo(nb.x, y2);
  return p;
}

// ---------------------------------------------------------------------
// What pushes owners along at each stop: the lever. Manual means
// Jonathan does it; system means something to build once.

class _Lever {
  final String title;
  final String text;
  final List<(String, bool)> tags; // (label, isSystem)
  const _Lever(this.title, this.text, this.tags);
}

const Map<String, _Lever> _kLevers = {
  'noclaim': _Lever(
      'Saw the claim page, did not claim',
      'Nomad Maps records who lands on the claim page and what they did '
          'there. Email the space: someone looked at claiming this profile, '
          'was it you? On the page itself: show the owner their own listing '
          'and ask for as little as possible before the claim goes through.',
      [('MANUAL · "WAS THIS YOU?" EMAIL', false), ('SYSTEM · SIGNAL CAPTURE', true)]),
  'never': _Lever(
      'Claimed, never logged in, reminders done',
      'The sequence has had its go. One personal note from you, not the '
          'sequence: what would make it worth logging in? A stat about their '
          'page, a review, or a wifi speed to confirm.',
      [('MANUAL · PERSONAL NOTE', false)]),
  'waiting': _Lever(
      'Claimed, not logged in yet, reminders still going',
      'Nothing to do by hand. Check reminder 1 goes out on schedule; each '
          'email should give one reason to log in now, not a generic nudge.',
      [('SYSTEM · REMINDER SEQUENCE', true)]),
  'left': _Lever(
      'Opened the owner account, changed nothing',
      'The first screen should ask for one quick edit (prices, wifi, photos) '
          'so the first visit ends with a submitted change, not a look. For a '
          'draft left unsent: a nudge that it is one click from being sent.',
      [('SYSTEM · FIRST-VISIT SCREEN', true), ('MANUAL · DRAFT NUDGE', false)]),
  'declined': _Lever(
      'Edit declined',
      'A declined edit with no way forward is a dead end. Tell them what '
          'was declined and how to fix it, kindly, with the link back in.',
      [('MANUAL · EXPLAIN AND INVITE BACK', false)]),
  'new': _Lever(
      'Approved less than 14 days ago',
      'Too early to judge. The changes-live email has done its job; give them '
          'a fortnight before reading anything into silence. Nothing to do.',
      [('SYSTEM · CHANGES-LIVE EMAIL', true)]),
  'active': _Lever(
      'Seen in the last 30 days',
      'Healthy. These are the owners who get value from the free tier, and '
          'where the Premium conversation belongs.',
      [('MANUAL · PREMIUM CONVERSATION', false)]),
  'quiet': _Lever(
      '30 to 60 days since they were last here',
      'The nudge window: a short note from you with one real number about '
          'their page (views this month) earns its keep here. This is where a '
          'regular email, if we test one, would land.',
      [('MANUAL · A NOTE WITH ONE NUMBER', false), ('SYSTEM · REGULAR EMAIL, IF TESTED', true)]),
  'dormant': _Lever(
      'More than 60 days since they were last here',
      'Gone, for now. One note; if nothing comes back, leave them and let the '
          'listing carry on as it is.',
      [('MANUAL · ONE NOTE', false)]),
  'premium': _Lever(
      'Paying', 'Keep them warm: the monthly numbers, and a reply within a day.',
      [('SYSTEM · MONTHLY NUMBERS EMAIL', true)]),
  'remind': _Lever(
      'In the reminder sequence now',
      'Nothing to do by hand while the sequence runs. Email 1 should give '
          'one reason to log in now (a stat, a review, a wifi speed to confirm), '
          'not a generic nudge. After email 3 with no login the owner goes to Never.',
      [('SYSTEM · REMINDER SEQUENCE', true)]),
  'followup': _Lever(
      'The claim-page signal',
      'Who landed on the claim page and what they did there, dropped into '
          'the outreach queue so the "was this you?" email is one tap.',
      [('SYSTEM · SIGNAL CAPTURE', true), ('MANUAL · SEND', false)]),
  'review': _Lever(
      'Your review',
      'Fast today. The risk is the week you are travelling. Auto-approve the '
          'low-risk fields (wifi, hours, prices) so only text and photos wait.',
      [('MANUAL · YOU APPROVE', false), ('SYSTEM · AUTO-APPROVE SAFE FIELDS', true)]),
  'lost': _Lever(
      'Gone, for now',
      'Lost at the claim page, or claimed and never logged in after the '
          'reminders. The "was this you?" email and one personal note are '
          'the two ways back.',
      [('MANUAL · ONE NOTE', false)]),
};

// ---------------------------------------------------------------------

class _Owner {
  final Map<String, dynamic> m;
  final List<String> path;
  _Owner(this.m)
      : path = [
          for (final x in (m['path'] as List? ?? const []))
            if ('$x' != 'waiting') '$x'
        ],
        waiting = (m['path'] as List? ?? const []).contains('waiting');
  /// Still inside the reminder sequence: no result yet.
  final bool waiting;

  String get email => '${m['email'] ?? ''}';
  DateTime? get claimedAt => DateTime.tryParse('${m['claimed_at'] ?? ''}')?.toLocal();
  String get space => '${m['space'] ?? ''}'.trim().isEmpty ? email : '${m['space']}';
  String get who => '${m['who'] ?? ''}';
  String get city => '${m['city'] ?? ''}';
  String get type => m['type'] == 'cafe' ? 'café' : 'coworking';
  String get src => m['src'] == 'out' ? 'outreach' : 'website';
  String get end => waiting ? 'waiting' : (path.isEmpty ? '' : path.last);
  bool has(String k) => path.contains(k);
  int _n(String k) => (m[k] is num) ? (m[k] as num).toInt() : 0;
  Map<String, dynamic>? get tick =>
      m['tick'] is Map ? Map<String, dynamic>.from(m['tick']) : null;
  bool get done => tick != null;

  /// The stop this owner is at: the box the next step is about.
  String get stop {
    if (has('noclaim')) return 'noclaim';
    if (has('never')) return 'never';
    if (waiting) return 'waiting';
    if (has('left') && end == 'new') return 'left';
    if (has('declined') && end == 'new') return 'declined';
    return end;
  }

  /// One line on what happened, from the numbers.
  String get what {
    final b = <String>[];
    if (!has('claimed')) {
      b.add('Opened the claim page, did not finish the claim.');
    } else {
      b.add(has('loginnow')
          ? 'Logged in'
          : has('cc')
              ? 'Logged in after reminder ${_n('reminders') > 0 ? 1 : ''}'.trim()
              : 'Never logged in');
      if (_n('login_days') > 0) b.add('${_n('login_days')} login day${_n('login_days') == 1 ? '' : 's'}');
      if (_n('reminders') > 0) b.add('${_n('reminders')} reminder${_n('reminders') == 1 ? '' : 's'} sent');
      if (_n('applied') > 0) b.add('${_n('applied')} edit${_n('applied') == 1 ? '' : 's'} approved');
      if (_n('declined') > 0) b.add('${_n('declined')} declined');
      if (_n('unsent') > 0) b.add('a draft never sent');
      if (has('approved')) {
        final r = m['returned_30'];
        b.add(r == true ? 'came back within 30 days of approval' : r == false ? 'did not come back within 30 days' : 'approved recently');
      }
      final q = m['days_quiet'];
      if (q is num && q >= 1) b.add('last here ${q.round()} day${q.round() == 1 ? '' : 's'} ago');
    }
    return b.join(' · ');
  }

  /// The next step, in Jonathan's words.
  String get next => switch (stop) {
        'noclaim' => 'Send the "was this you?" email.',
        'never' => 'One personal note from you (not the sequence): what would make it worth logging in?',
        'waiting' => '',
        'left' => _n('unsent') > 0
            ? 'Nudge: "your draft is still waiting, one click to send it".'
            : 'Nudge: one quick edit (wifi, prices, photos).',
        'declined' => 'Tell them what was declined and how to fix it.',
        'new' => '',
        'quiet' => 'Write to them: ask how the page is working for them, and give them one number (views this month).',
        'dormant' => 'One note; if nothing comes back, leave them.',
        'active' => 'Premium conversation.',
        'premium' => 'Write to them: a short check-in, and one number.',
        _ => '',
      };
}

enum _Verdict { ok, watch, problem, early }

enum _StepKind { now, look, system, build }

class _Step {
  final String label, detail;
  final _StepKind kind;
  final VoidCallback? onTap;
  const _Step(this.label, this.kind, this.detail, this.onTap);
  /// For build steps, the ask text, to show "on Monday's page" once asked.
  String get askItem => switch (label) {
        '"Was this you?" email' => 'Was this you? email',
        'Rewrite email 1 with one reason to log in' => 'Rewrite reminder email 1 with one reason to log in',
        'First visit asks for one edit' => 'First-visit screen asks for one quick edit',
        'Auto-approve safe fields' => 'Auto-approve safe fields (wifi, hours, prices)',
        'Regular email to claimed owners' => 'Regular transactional email to claimed owners (test)',
        _ => label,
      };
}

/// A stage of the map with its measure against its target.
class _Stage {
  final String key, title, targetKey, measure, nowText;
  final double now, target;
  final int sample; // how many the measure rests on; under 4 is too early
  final bool upIsGood;
  const _Stage(this.key, this.title, this.targetKey, this.now, this.target, this.measure, this.nowText,
      {required this.sample, this.upIsGood = true});
  _Verdict get verdict {
    if (sample < 4) return _Verdict.early;
    if (upIsGood) {
      if (now >= target) return _Verdict.ok;
      if (now >= target * .7) return _Verdict.watch;
      return _Verdict.problem;
    }
    if (now <= target) return _Verdict.ok;
    if (now <= target * 1.3) return _Verdict.watch;
    return _Verdict.problem;
  }
  /// How far from healthy, as a share of the target, for ranking.
  double get gap => target == 0 ? 0 : (upIsGood ? (target - now) : (now - target)) / target;
  String get targetText {
    final v = target % 1 == 0 ? target.toInt().toString() : target.toString();
    return switch (targetKey) {
      'claim_rate' || 'login_rate' || 'edit_rate' || 'review_24h' || 'return_30' => '$v%',
      'quiet_share' => 'at most $v%',
      'outreach_sent_week' => '$v a week',
      'claims_month' => '$v a month',
      _ => v,
    };
  }
}

class _Bead {
  final _Owner owner;
  final int index;
  int seg = 0; // which hop
  double k = 0; // progress along the hop
  bool finished = false;
  bool typed = false; // counted at the cafe / coworking gate
  _Bead(this.owner, this.index);
  bool get amber {
    if (seg >= owner.path.length - 1) return false;
    final b = _kByKey[owner.path[seg + 1]];
    return b != null && (b.block || b.result == 'lost' || b.result == 'dormant' || b.result == 'quiet');
  }
}

class _AdminOwnerFlowScreenState extends State<AdminOwnerFlowScreen>
    with SingleTickerProviderStateMixin {
  final _supabase = SupabaseService();
  bool _loading = true;
  String? _error;
  List<_Owner> _all = const []; // every real owner, as of now
  List<_Owner> _all7 = const []; // as the map stood 7 days ago
  List<_Owner> _all30 = const []; // and 30 days ago
  /// The period: owners by when they claimed. all | month | last | three
  String _period = 'all';
  /// Movement against 7 or 30 days ago.
  int _against = 7;
  List<_Owner> get _owners => _inPeriod(_all);
  List<_Owner> get _prev => _inPeriod(_against == 7 ? _all7 : _all30);
  (DateTime?, DateTime?) get _periodRange {
    final now = DateTime.now();
    switch (_period) {
      case 'week':
        // Monday to today
        final mon = DateTime(now.year, now.month, now.day - (now.weekday - 1));
        return (mon, null);
      case 'month':
        return (DateTime(now.year, now.month, 1), null);
      case 'last':
        return (DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 1));
      case 'three':
        return (DateTime(now.year, now.month - 2, 1), null);
    }
    return (null, null);
  }
  List<_Owner> _inPeriod(List<_Owner> xs) {
    final (from, to) = _periodRange;
    if (from == null && to == null) return xs;
    return [
      for (final o in xs)
        if (o.claimedAt != null &&
            (from == null || !o.claimedAt!.isBefore(from)) &&
            (to == null || o.claimedAt!.isBefore(to)))
          o
    ];
  }
  int _visitors = 0;
  Map<String, dynamic> _review = const {};
  Map<String, dynamic> _sig = const {}; // the numbers behind the verdicts (migration 206)
  Map<String, dynamic> _targets = const {}; // key -> {value, label, unit}
  DateTime? _since;

  late final AnimationController _ticker;
  Duration _last = Duration.zero;
  final List<_Bead> _beads = [];
  int _nextBead = 0;
  double _sinceLaunch = 0; // ms since the last bead set off
  double _speed = 0.5;
  bool _soundOn = false;
  final Map<String, int> _counts = {}; // box -> beads that reached it
  final Map<String, double> _lit = {}; // box -> ms left glowing
  final Map<String, bool> _slots = {}; // owner email -> finished
  String? _selected; // the tapped box
  bool _showDone = false;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(vsync: this, duration: const Duration(days: 1))
      ..addListener(_tick);
    _load();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final now = DateTime.now();
      final rs = await Future.wait([
        _supabase.adminOwnerFlow(asOf: now),
        _supabase.adminOwnerFlow(asOf: now.subtract(const Duration(days: 7))),
        _supabase.adminOwnerFlow(asOf: now.subtract(const Duration(days: 30))),
        _supabase.adminOwnerFlowSignals(),
      ]);
      final r = rs[0];
      final sig = rs[3];
      List<_Owner> parse(Map<String, dynamic> x) => [
            for (final o in (x['owners'] as List? ?? const []))
              if (o is Map) _Owner(Map<String, dynamic>.from(o))
          ];
      if (!mounted) return;
      setState(() {
        _all = parse(rs[0]);
        _all7 = parse(rs[1]);
        _all30 = parse(rs[2]);
        _visitors = (r['visitors'] as num?)?.toInt() ?? 0;
        _review = r['review'] is Map ? Map<String, dynamic>.from(r['review']) : {};
        _sig = sig;
        _targets = sig['targets'] is Map ? Map<String, dynamic>.from(sig['targets']) : {};
        _since = DateTime.tryParse('${r['since'] ?? ''}')?.toLocal();
        _loading = false;
        _error = null;
      });
      _replay();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the owner flow. $e';
      });
    }
  }

  // ---------- the animation ----------

  void _replay() {
    _beads.clear();
    _counts.clear();
    _lit.clear();
    _slots.clear();
    _nextBead = 0;
    _sinceLaunch = 1e9;
    if (Motion.reduced(context)) {
      for (final o in _owners) {
        _settle(o);
      }
      setState(() {});
      return;
    }
    _last = Duration.zero;
    _ticker
      ..stop()
      ..value = 0
      ..forward();
  }

  /// Count an owner at every box on its path, with no bead.
  void _settle(_Owner o) {
    for (final k in o.path) {
      final n = _kByKey[k];
      if (n != null && (n.block || n.result != null || n.strip)) {
        _counts[k] = (_counts[k] ?? 0) + 1;
      }
    }
    if (o.waiting) _counts['remind'] = (_counts['remind'] ?? 0) + 1;
    final t = _kByKey[o.m['type'] == 'cafe' ? 'cafe' : 'cowork'];
    if (t != null) _counts[t.key] = (_counts[t.key] ?? 0) + 1;
    _slots[o.email] = true;
  }

  void _tick() {
    final now = _ticker.lastElapsedDuration ?? Duration.zero;
    final dt = (now - _last).inMicroseconds / 1000.0;
    _last = now;
    if (dt <= 0 || dt > 500) return;
    final step = dt * _speed;
    // one bead sets off every 900 ms (at speed x1)
    _sinceLaunch += step;
    if (_nextBead < _owners.length && _sinceLaunch >= 900) {
      _beads.add(_Bead(_owners[_nextBead], _nextBead));
      _nextBead++;
      _sinceLaunch = 0;
    }
    for (final b in _beads) {
      if (b.finished) continue;
      final path = b.owner.path;
      if (b.seg >= path.length - 1) {
        _finish(b);
        continue;
      }
      final metric = _edgePath(path[b.seg], path[b.seg + 1]).computeMetrics().first;
      final dur = math.max(220.0, metric.length * 4);
      b.k += step / dur;
      if (b.k >= 1) {
        b.k = 0;
        final arrived = path[b.seg + 1];
        _lit[arrived] = 700;
        if (_soundOn) {
          final nb = _kByKey[arrived]!;
          final amber = nb.block || nb.result == 'lost' || nb.result == 'dormant' || nb.result == 'quiet';
          if (amber) {
            sound.playNote(392, 1.2, .06);
          } else {
            sound.playNote(_kScale[b.seg % _kScale.length], .9, .07);
          }
        }
        b.seg++;
        if (b.seg >= path.length - 1) _finish(b);
      }
      if (!b.typed) {
        final pos = metric.getTangentForOffset(metric.length * b.k.clamp(0, 1))?.position;
        if (pos != null && pos.dy > _kByKey['cafe']!.y) {
          b.typed = true;
          final t = b.owner.m['type'] == 'cafe' ? 'cafe' : 'cowork';
          _counts[t] = (_counts[t] ?? 0) + 1;
          _lit[t] = 600;
        }
      }
    }
    for (final k in _lit.keys.toList()) {
      _lit[k] = _lit[k]! - step;
      if (_lit[k]! <= 0) _lit.remove(k);
    }
    final allDone = _nextBead >= _owners.length && _beads.every((b) => b.finished);
    if (allDone && _lit.isEmpty) _ticker.stop();
    setState(() {});
  }

  void _finish(_Bead b) {
    if (b.finished) return;
    b.finished = true;
    final o = b.owner;
    for (final k in o.path) {
      final n = _kByKey[k];
      if (n != null && (n.block || n.result != null)) {
        _counts[k] = (_counts[k] ?? 0) + 1;
      }
    }
    if (o.waiting) _counts['remind'] = (_counts['remind'] ?? 0) + 1;
    _slots[o.email] = true;
    if (_soundOn) {
      if (o.end == 'premium' || o.end == 'active') {
        final notes = o.end == 'premium' ? [1046.5, 1318.5, 1568.0, 2093.0] : [1046.5, 1568.0];
        for (var i = 0; i < notes.length; i++) {
          sound.playNote(notes[i], 2.2, .08, delay: i * .09);
        }
      }
    }
  }

  // ---------- ticks ----------

  Future<void> _toggle(_Owner o) async {
    if (_busy.contains(o.email)) return;
    setState(() => _busy.add(o.email));
    try {
      await _supabase.adminOwnerFlowTick(o.email, !o.done, o.next);
      // keep the map where it is: refresh the owners' ticks only
      final r = await _supabase.adminOwnerFlow(asOf: DateTime.now());
      final fresh = {
        for (final x in (r['owners'] as List? ?? const []))
          if (x is Map) '${x['email']}': x['tick']
      };
      if (!mounted) return;
      setState(() {
        for (final ow in _all) {
          ow.m['tick'] = fresh[ow.email];
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('That did not save. $e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(o.email));
    }
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title: const Text('Owner flow'),
        actions: [
          // Every email to owners and what happened after it (migration 272).
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminEmailFlowScreen())),
            icon: const Icon(Icons.mail_outline, size: 18),
            label: const Text('Emails'),
          ),
          TextButton(
            onPressed: _loading ? null : () {
              setState(() => _speed = _speed == 0.5 ? 1 : _speed == 1 ? 2 : 0.5);
            },
            child: Text('Speed ×${_speed == 0.5 ? '0.5' : _speed.toInt()}'),
          ),
          IconButton(
              tooltip: _soundOn ? 'Sound off' : 'Sound on',
              onPressed: _loading ? null : () {
                setState(() => _soundOn = !_soundOn);
                if (_soundOn) sound.playNote(1046.5, .6, .07);
              },
              icon: Icon(_soundOn ? Icons.volume_up_outlined : Icons.volume_off_outlined)),
          IconButton(
              tooltip: 'Replay',
              onPressed: _loading ? null : _replay,
              icon: const Icon(Icons.replay)),
          IconButton(
              tooltip: 'Look again',
              onPressed: _load,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Brand.red))))
                : wide
                    ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          flex: 11,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(24, 20, 12, 40),
                            child: Column(children: [
                              _intro(),
                              const SizedBox(height: 12),
                              _mapCard(),
                            ]),
                          ),
                        ),
                        Expanded(
                          flex: 7,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(12, 20, 24, 40),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: _side()),
                          ),
                        ),
                      ])
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                        children: [
                          _intro(),
                          const SizedBox(height: 12),
                          _mapCard(),
                          const SizedBox(height: 16),
                          ..._side(),
                        ],
                      ),
      ),
    );
  }

  Widget _intro() {
    Widget chip(String k, String label) {
      final on = _period == k;
      return ChoiceChip(
        label: Text(label),
        selected: on,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: on ? Colors.white : Brand.inkSecondary),
        selectedColor: Brand.ink,
        backgroundColor: Brand.surface,
        side: BorderSide(color: on ? Brand.ink : Brand.border),
        onSelected: (_) {
          if (_period == k) return;
          setState(() {
            _period = k;
            _selected = null;
          });
          _replay();
        },
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        chip('all', 'All time'),
        chip('week', 'This week'),
        chip('month', 'This month'),
        chip('last', 'Last month'),
        chip('three', 'Last 3 months'),
        const SizedBox(width: 6),
        Text(_periodLabel(), style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
      ]),
      const SizedBox(height: 6),
      Builder(builder: (_) {
        final b = _bottleneck;
        if (b == null) {
          return const Text('Every stage is healthy or too early to tell. Tap any box for its numbers and steps.',
              style: TextStyle(fontSize: 12, color: Brand.inkMuted));
        }
        final color = b.verdict == _Verdict.problem ? Brand.accent : Brand.goldTextDark;
        return InkWell(
          onTap: () => setState(() => _selected = _firstNodeOf(b.key)),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: b.verdict == _Verdict.problem ? 'Bottleneck: ' : 'Watch: ', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
            TextSpan(text: '${b.title}, ${b.nowText}, healthy is ${b.targetText}. ', style: const TextStyle(fontSize: 12.5, color: Brand.ink)),
            const TextSpan(text: 'Tap for the steps.', style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
          ])),
        );
      }),
    ]);
  }

  static String _firstNodeOf(String stage) => switch (stage) {
        'lead' => 'web', 'claim' => 'claim', 'login' => 'claimed', 'use' => 'cc',
        'review' => 'review', 'return' => 'active', 'quiet' => 'quiet', 'premium' => 'premium', _ => 'claim',
      };

  /// The verdict colour for each box, drawn as a dot on the map.
  Map<String, Color> _verdictDots() {
    final m = <String, Color>{};
    for (final st in _stages) {
      final c = switch (st.verdict) {
        _Verdict.ok => Brand.success,
        _Verdict.watch => Brand.gold,
        _Verdict.problem => Brand.accent,
        _Verdict.early => null,
      };
      if (c == null) continue;
      final k = _firstNodeOf(st.key);
      m[k] = c;
      if (st.key == 'lead') m['out'] = c;
      if (st.key == 'quiet') m['dormant'] = c;
    }
    return m;
  }

  /// "11 owners · claimed 21 Sep to 30 Oct"
  String _periodLabel() {
    final xs = _owners;
    if (xs.isEmpty) return 'no owners claimed in this period';
    final ds = [for (final o in xs) if (o.claimedAt != null) o.claimedAt!]..sort();
    if (ds.isEmpty) return '${xs.length} owners';
    final f = DateFormat('d MMM');
    return '${xs.length} owner${xs.length == 1 ? '' : 's'} · claimed ${f.format(ds.first)} to ${f.format(ds.last)}';
  }

  /// What each box's count was [against] days ago, so the map can show
  /// movement. Null while the beads are still running.
  Map<String, int>? _prevCounts() {
    if (_nextBead < _owners.length || !_beads.every((b) => b.finished)) return null;
    final m = <String, int>{};
    for (final o in _prev) {
      for (final k in o.path) {
        final n = _kByKey[k];
        if (n != null && (n.block || n.result != null)) m[k] = (m[k] ?? 0) + 1;
      }
      if (o.waiting) m['remind'] = (m['remind'] ?? 0) + 1;
    }
    return m;
  }

  /// "11 owners: 3 active · 5 dormant · 0 lost · 3 in reminders"
  String _footer() {
    final xs = _owners;
    int n(String e) => xs.where((o) => o.end == e).length;
    final parts = <String>[];
    if (n('premium') > 0) parts.add('${n('premium')} premium');
    parts.add('${n('new')} new');
    parts.add('${n('active')} active');
    parts.add('${n('quiet')} quiet');
    parts.add('${n('dormant')} dormant');
    parts.add('${n('lost')} lost');
    parts.add('${n('waiting')} in reminders');
    return '${xs.length} OWNERS: ${parts.join(' · ').toUpperCase()}';
  }

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Brand.border),
        ),
        child: child,
      );

  Widget _mapCard() => _card(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: LayoutBuilder(builder: (context, c) {
          final w = math.min(c.maxWidth - 16, 760.0);
          final scale = w / 400;
          return Center(
            child: SizedBox(
              width: w,
              height: 1135 * scale,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) {
                  final p = d.localPosition / scale;
                  for (final n in _kNodes) {
                    if (!n.tappable) continue;
                    final r = Rect.fromCenter(center: Offset(n.x, n.y), width: n.w + 8, height: _kH + 20);
                    if (r.contains(p)) {
                      setState(() => _selected = _selected == n.key ? null : n.key);
                      return;
                    }
                  }
                },
                child: CustomPaint(
                  painter: _FlowPainter(
                    scale: scale,
                    beads: _beads,
                    counts: _counts,
                    lit: _lit,
                    selected: _selected,
                    slots: [for (final o in _owners) _slots[o.email] == true ? o.end : ''],
                    prev: _prevCounts(),
                    against: _against,
                    footer: _footer(),
                    header: _periodLabel().toUpperCase(),
                    dots: _verdictDots(),
                  ),
                ),
              ),
            ),
          );
        }),
      );

  List<Widget> _side() => [
        if (_selected != null) ...[_detail(_selected!), const SizedBox(height: 16)],
        _stats(),
        const SizedBox(height: 16),
        _inbox(),
      ];

  // ---------- who is at a box, and what pushes them along ----------

  // ---------- stages: is it a problem, why, what to press ----------

  /// Which stage a box belongs to.
  static String _stageOf(String k) => switch (k) {
        'web' || 'out' => 'lead',
        'claim' || 'noclaim' || 'followup' => 'claim',
        'claimed' || 'loginnow' || 'nologin' || 'remind' || 'never' || 'lost' => 'login',
        'cc' || 'updated' || 'left' => 'use',
        'review' || 'approved' || 'declined' => 'review',
        'new' || 'active' => 'return',
        'quiet' || 'dormant' => 'quiet',
        'premium' => 'premium',
        _ => '',
      };

  num _t(String key, num fallback) {
    final t = _targets[key];
    return (t is Map && t['value'] is num) ? t['value'] as num : fallback;
  }
  int _s(String key) => (_sig[key] is num) ? (_sig[key] as num).toInt() : 0;

  /// The verdict for a stage from its main measure against its target.
  _Stage _stage(String key) {
    int n(bool Function(_Owner) f) => _owners.where(f).length;
    final now = DateTime.now();
    switch (key) {
      case 'lead':
        final sent = _s('outreach_sent_7d');
        return _Stage(key, 'Lead in', 'outreach_sent_week', sent.toDouble(), _t('outreach_sent_week', 25).toDouble(),
            'Outreach emails sent this week', '$sent sent', sample: 99);
      case 'claim':
        final v = _s('visitors_30d'), c = _s('claims_30d');
        final rate = v == 0 ? 0.0 : c * 100 / v;
        return _Stage(key, 'Claim', 'claim_rate', rate, _t('claim_rate', 25).toDouble(),
            'Claim-page visitors who claim, last 30 days', '$c of $v (${rate.round()}%)', sample: v);
      case 'login':
        final old = _owners.where((o) => o.has('claimed') && o.claimedAt != null && now.difference(o.claimedAt!).inDays >= 14).toList();
        final inn = old.where((o) => o.has('cc')).length;
        final rate = old.isEmpty ? 0.0 : inn * 100 / old.length;
        return _Stage(key, 'Log in', 'login_rate', rate, _t('login_rate', 60).toDouble(),
            'Claimed 14+ days ago who have logged in', '$inn of ${old.length} (${rate.round()}%)', sample: old.length);
      case 'use':
        final inn = n((o) => o.has('cc')), ed = n((o) => o.has('updated'));
        final rate = inn == 0 ? 0.0 : ed * 100 / inn;
        return _Stage(key, 'Use', 'edit_rate', rate, _t('edit_rate', 60).toDouble(),
            'Logged-in owners who submitted an edit', '$ed of $inn (${rate.round()}%)', sample: inn);
      case 'review':
        final rv = (_review['reviewed'] as num?)?.toInt() ?? 0, w = (_review['within_24h'] as num?)?.toInt() ?? 0;
        final rate = rv == 0 ? 0.0 : w * 100 / rv;
        return _Stage(key, 'Your review', 'review_24h', rate, _t('review_24h', 90).toDouble(),
            'Edits reviewed within 24 hours', '$w of $rv (${rate.round()}%), average ${_review['avg_hours'] ?? '-'} h', sample: rv);
      case 'return':
        final known = n((o) => o.m['returned_30'] != null), back = n((o) => o.m['returned_30'] == true);
        final rate = known == 0 ? 0.0 : back * 100 / known;
        return _Stage(key, 'Comes back', 'return_30', rate, _t('return_30', 50).toDouble(),
            'Back within 30 days of approval', '$back of $known (${rate.round()}%)', sample: known);
      case 'quiet':
        final ap = n((o) => o.has('approved')), q = n((o) => o.end == 'quiet' || o.end == 'dormant');
        final rate = ap == 0 ? 0.0 : q * 100 / ap;
        return _Stage(key, 'Quiet or dormant', 'quiet_share', rate, _t('quiet_share', 25).toDouble(),
            'Approved owners who have gone quiet or dormant', '$q of $ap (${rate.round()}%)', sample: ap, upIsGood: false);
      case 'premium':
        final pm = n((o) => o.end == 'premium');
        return _Stage(key, 'Premium', 'premium_count', pm.toDouble(), _t('premium_count', 1).toDouble(),
            'Paying owners', '$pm', sample: 99);
    }
    return _Stage(key, key, '', 0, 0, '', '', sample: 0);
  }

  List<_Stage> get _stages => [for (final k in const ['lead', 'claim', 'login', 'use', 'review', 'return', 'quiet', 'premium']) _stage(k)];

  /// The worst stage, for the line above the map.
  _Stage? get _bottleneck {
    final xs = _stages.where((x) => x.verdict == _Verdict.problem).toList()
      ..sort((a, b) => a.gap.compareTo(b.gap));
    if (xs.isNotEmpty) return xs.last;
    final ws = _stages.where((x) => x.verdict == _Verdict.watch).toList()
      ..sort((a, b) => a.gap.compareTo(b.gap));
    return ws.isEmpty ? null : ws.last;
  }

  /// One or two lines on why, from the signals.
  String _why(String stage) {
    switch (stage) {
      case 'lead':
        return '${_s('outreach_picked_waiting')} picked by Outreach 5 are still unsent; ${_s('outreach_ready')} spaces with an email are ready to write to. '
            '${_s('outreach_sent_30d')} sent in 30 days brought ${_s('outreach_replies_30d')} replies and ${_s('from_outreach_30d')} claims.';
      case 'claim':
        final st = _sig['claim_stops_30d'] is Map ? Map<String, dynamic>.from(_sig['claim_stops_30d']) : <String, dynamic>{};
        int g(String k) => (st[k] as num?)?.toInt() ?? 0;
        final parts = <String>[];
        if (g('opened') > 0) parts.add('${g('opened')} opened and did nothing');
        if (g('find') > 0) parts.add('${g('find')} stopped at Find');
        if (g('about') + g('details') > 0) parts.add('${g('about') + g('details')} stopped at About');
        if (g('plans') + g('plan') > 0) parts.add('${g('plans') + g('plan')} stopped at the plan');
        if (g('add_space') > 0) parts.add('${g('add_space')} were adding a new space');
        return 'Of the visitors who did not claim in the last 30 days: ${parts.isEmpty ? 'no detail yet' : parts.join(', ')}. '
            '${_s('from_outreach_30d')} of the claims came from our outreach.';
      case 'login':
        final w = _owners.where((o) => o.waiting).length, nv = _owners.where((o) => o.has('never')).length;
        return 'Reminder sequence is ${_sig['seq_enabled'] == true ? 'on' : 'OFF'}: ${_s('seq_step1_30d')} first emails and ${_s('seq_step2_30d')} second emails in 30 days. '
            '$w owners are inside it now; $nv never logged in after it finished.';
      case 'use':
        final left = _owners.where((o) => o.has('left')).length, un = _owners.where((o) => o._n('unsent') > 0).length;
        return '$left logged in and changed nothing; $un left a draft unsent. The first screen does not yet ask for one quick edit.';
      case 'review':
        return 'Average ${_review['avg_hours'] ?? '-'} h, slowest ${_review['max_hours'] ?? '-'} h. The risk is the week you are travelling.';
      case 'return':
        final nw = _owners.where((o) => o.end == 'new').length;
        return '$nw approved in the last 14 days are too new to count. After the changes-live email nothing from us reaches an owner again.';
      case 'quiet':
        final q = _owners.where((o) => o.end == 'quiet').map((o) => o.space).join(', ');
        return q.isEmpty ? 'Nobody has gone quiet yet.' : 'Quiet now: $q. No email from us since their changes went live.';
      case 'premium':
        final a = _owners.where((o) => o.end == 'active').length;
        return '$a owners are active, the ones a Premium conversation fits. Nobody has been asked yet.';
    }
    return '';
  }

  /// The steps for a stage, each with what pressing it does.
  List<_Step> _steps(String stage) {
    void outreach([String? q]) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AdminOutreachScreen(initialQuery: q)));
    void sequences() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminSequencesScreen()));
    void journeys() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ClaimJourneysScreen()));
    switch (stage) {
      case 'lead':
        return [
          _Step('Send today\'s five', _StepKind.now, 'Outreach, Reply, Send. ${_s('outreach_picked_waiting')} waiting.', () => outreach()),
          _Step('More spaces with an email', _StepKind.system, 'The scout finds addresses every Wednesday; ${_s('outreach_ready')} ready now.', null),
        ];
      case 'claim':
        return [
          _Step('See where visitors stop', _StepKind.look, 'Claim journeys: every visit, step by step.', journeys),
          _Step('Send today\'s five', _StepKind.now, 'More owners on the page who already know us.', () => outreach()),
          _Step('"Was this you?" email', _StepKind.build, 'Visitor looked at claiming a space but did not: one tap to email the space.', () => _ask('claim', 'Was this you? email')),
        ];
      case 'login':
        return [
          _Step('Open the reminder sequence', _StepKind.look, 'Who is in it, each email, switches.', sequences),
          _Step('Rewrite email 1 with one reason to log in', _StepKind.build, 'A stat, a review, a wifi speed to confirm; not a nudge.', () => _ask('login', 'Rewrite reminder email 1 with one reason to log in')),
        ];
      case 'use':
        return [
          _Step('First visit asks for one edit', _StepKind.build, 'The owner account opens on wifi, prices, photos so the first visit ends with a change.', () => _ask('use', 'First-visit screen asks for one quick edit')),
        ];
      case 'review':
        return [
          _Step('Auto-approve safe fields', _StepKind.build, 'Wifi, hours and prices go live at once; only text and photos wait for you.', () => _ask('review', 'Auto-approve safe fields (wifi, hours, prices)')),
        ];
      case 'return':
      case 'quiet':
        return [
          _Step('Regular email to claimed owners', _StepKind.build, 'Very specific, approved by us, one switch. On Monday\'s page.', () => _ask(stage, 'Regular transactional email to claimed owners (test)')),
        ];
      case 'premium':
        return [
          _Step('Premium conversation', _StepKind.now, 'Start with the active owners below.', () => outreach()),
        ];
    }
    return const [];
  }

  Future<void> _ask(String stage, String item) async {
    try {
      final r = await _supabase.adminOwnerFlowAsk(stage, item);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r['new'] == true
                ? 'Added to Monday\'s Daily page: "$item". The review brings the numbers.'
                : 'Already on Monday\'s page: "$item".')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save. $e')));
    }
  }

  Future<void> _editTarget(_Stage st) async {
    final ctl = TextEditingController(text: st.target % 1 == 0 ? st.target.toInt().toString() : st.target.toString());
    final t = _targets[st.targetKey];
    final label = (t is Map ? t['label'] : null) ?? st.measure;
    final unit = (t is Map ? '${t['unit'] ?? ''}' : '');
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What counts as healthy?', style: TextStyle(fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$label', style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
          const SizedBox(height: 10),
          TextField(controller: ctl, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(suffixText: unit, border: const OutlineInputBorder(), isDense: true)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(ctl.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    if (v == null) return;
    try {
      await _supabase.adminOwnerFlowTargetSet(st.targetKey, v);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save. $e')));
    }
  }

  Widget _verdictChip(_Verdict v) {
    final (label, color, bg) = switch (v) {
      _Verdict.ok => ('HEALTHY', Brand.success, Brand.successTint),
      _Verdict.watch => ('WATCH', Brand.goldTextDark, Brand.goldTint),
      _Verdict.problem => ('PROBLEM', Brand.accent, Brand.accentTint),
      _Verdict.early => ('TOO EARLY', Brand.inkMuted, Brand.field),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(fontSize: 9.5, letterSpacing: 1, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _detail(String k) {
    final n = _kByKey[k]!;
    final rows = k == 'remind'
        ? _owners.where((o) => o.waiting).toList()
        : _owners.where((o) => o.has(k)).toList();
    final lever = _kLevers[k];
    final stageKey = _stageOf(k);
    final st = stageKey.isEmpty ? null : _stage(stageKey);
    final openAsks = {for (final a in (_sig['open_asks'] as List? ?? const [])) if (a is Map) '${a['item']}'};
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: n.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, letterSpacing: .4)),
              TextSpan(text: '   ${rows.length} owner${rows.length == 1 ? '' : 's'}', style: const TextStyle(color: Brand.inkMuted, fontSize: 12.5)),
            ])),
          ),
          if (st != null) _verdictChip(st.verdict),
          IconButton(
              tooltip: 'Close',
              onPressed: () => setState(() => _selected = null),
              icon: const Icon(Icons.close, size: 18, color: Brand.inkMuted)),
        ]),
        if (st != null) ...[
          const SizedBox(height: 8),
          // now vs healthy
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(st.measure, style: const TextStyle(fontSize: 11, color: Brand.inkMuted, letterSpacing: .4)),
                Text(st.nowText, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ]),
            ),
            InkWell(
              onTap: () => _editTarget(st),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  const Text('HEALTHY', style: TextStyle(fontSize: 9.5, color: Brand.inkMuted, letterSpacing: 1)),
                  Text.rich(TextSpan(children: [
                    TextSpan(text: st.targetText, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Brand.inkSecondary)),
                    const WidgetSpan(child: Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.edit_outlined, size: 13, color: Brand.inkMuted))),
                  ])),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text(_why(stageKey), style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary, height: 1.45)),
          const SizedBox(height: 10),
          const Text('STEPS', style: TextStyle(fontSize: 9.5, color: Brand.inkMuted, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          for (final sp in _steps(stageKey)) _stepRow(sp, asked: openAsks.contains(sp.askItem)),
          const Divider(height: 24, color: Brand.hairline),
        ],
        if (lever != null) ...[
          Text(lever.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 4),
          Text(lever.text, style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary, height: 1.45)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [for (final t in lever.tags) _tag(t.$1, t.$2)]),
          const Divider(height: 24, color: Brand.hairline),
        ],
        if (rows.isEmpty)
          const Text('No owners here.', style: TextStyle(fontSize: 12.5, color: Brand.inkMuted))
        else
          for (final o in rows) _ownerRow(o),
      ]),
    );
  }

  Widget _stepRow(_Step sp, {required bool asked}) {
    final (kindLabel, color) = switch (sp.kind) {
      _StepKind.now => ('DO IT NOW', Brand.accent),
      _StepKind.look => ('LOOK AT', Brand.ink),
      _StepKind.system => ('RUNS ITSELF', Brand.inkMuted),
      _StepKind.build => ('BUILD IT', Brand.goldTextDark),
    };
    final done = sp.kind == _StepKind.build && asked;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(kindLabel, style: TextStyle(fontSize: 8.5, letterSpacing: 1, fontWeight: FontWeight.w700, color: color)),
              const SizedBox(width: 6),
              Expanded(child: Text(sp.label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
            ]),
            Text(sp.detail, style: const TextStyle(fontSize: 11.5, color: Brand.inkSecondary)),
          ]),
        ),
        const SizedBox(width: 8),
        if (sp.onTap != null)
          done
              ? const Padding(padding: EdgeInsets.only(top: 4), child: Text('ON MONDAY\'S PAGE', style: TextStyle(fontSize: 9, letterSpacing: .8, color: Brand.success, fontWeight: FontWeight.w700)))
              : OutlinedButton(
                  onPressed: sp.onTap,
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                  child: Text(sp.kind == _StepKind.build ? 'Add to Monday' : sp.kind == _StepKind.look ? 'Open' : 'Go'),
                ),
      ]),
    );
  }

  Widget _tag(String label, bool system) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: system ? Brand.ink : Brand.inkFaint),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 9.5, letterSpacing: .8, fontWeight: FontWeight.w600,
                color: system ? Brand.ink : Brand.inkSecondary)),
      );

  Widget _ownerRow(_Owner o) {
    final done = o.done;
    final busy = _busy.contains(o.email);
    final muted = done ? Brand.inkMuted : Brand.inkSecondary;
    String when = '';
    if (done) {
      final d = DateTime.tryParse('${o.tick!['at'] ?? ''}')?.toLocal();
      if (d != null) when = 'done ${DateFormat('d MMM').format(d)}';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 28,
          height: 28,
          child: busy
              ? const Padding(padding: EdgeInsets.all(6), child: CircularProgressIndicator(strokeWidth: 2))
              : Checkbox(
                  value: done,
                  onChanged: o.next.isEmpty ? null : (_) => _toggle(o),
                  activeColor: Brand.success,
                  visualDensity: VisualDensity.compact,
                ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(o.space,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: done ? Brand.inkMuted : Brand.ink,
                    decoration: done ? TextDecoration.lineThrough : null)),
            Text(
                [o.who, o.city, o.type, o.email].where((s) => s.isNotEmpty).join(' · '),
                style: TextStyle(fontSize: 11.5, color: muted)),
            Text(
                'claimed ${_day(o.m['claimed_at'])} · last seen ${o.m['last_login'] == null ? 'never' : _day(o.m['last_login'])} · via ${o.src}',
                style: TextStyle(fontSize: 11.5, color: muted)),
            if (o.what.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(o.what, style: TextStyle(fontSize: 12.5, color: done ? Brand.inkMuted : Brand.ink)),
              ),
            if (o.next.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('→ ${o.next}',
                    style: TextStyle(fontSize: 12.5, color: done ? Brand.inkMuted : Brand.accent, fontWeight: FontWeight.w500)),
              ),
            if (o.next.isNotEmpty && !done)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => AdminOutreachScreen(initialQuery: o.space))),
                  icon: const Icon(Icons.send_rounded, size: 15),
                  label: const Text('Write to them'),
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
            if (when.isNotEmpty)
              Text(when, style: const TextStyle(fontSize: 11, color: Brand.inkMuted)),
          ]),
        ),
      ]),
    );
  }

  static String _day(dynamic v) {
    final d = v == null ? null : DateTime.tryParse('$v')?.toLocal();
    return d == null ? '' : DateFormat('d MMM').format(d);
  }

  // ---------- the numbers ----------

  Widget _stats() {
    int n(bool Function(_Owner) f) => _owners.where(f).length;
    int np(bool Function(_Owner) f) => _prev.where(f).length;
    final pOwners = _prev.length;
    final pClaimed = np((o) => o.has('claimed'));
    final pLogin = np((o) => o.has('cc'));
    final pSubmitted = np((o) => o.has('updated'));
    final pApproved = np((o) => o.has('approved'));
    final pBack = np((o) => o.m['returned_30'] == true);
    final pBackKnown = np((o) => o.m['returned_30'] != null);
    final pPremium = np((o) => o.end == 'premium');
    final pWaiting = np((o) => o.end == 'waiting');
    final pLost = np((o) => o.end == 'lost' || o.end == 'dormant');
    final pQuiet = np((o) => o.end == 'quiet');
    final claimed = n((o) => o.has('claimed'));
    final recovered = n((o) => o.has('followup') && o.has('claimed'));
    final login = n((o) => o.has('cc'));
    final submitted = n((o) => o.has('updated'));
    final approved = n((o) => o.has('approved'));
    final back = n((o) => o.m['returned_30'] == true);
    final backKnown = n((o) => o.m['returned_30'] != null);
    final premium = n((o) => o.end == 'premium');
    final waiting = n((o) => o.end == 'waiting');
    final lost = n((o) => o.end == 'lost' || o.end == 'dormant');
    final quiet = n((o) => o.end == 'quiet');

    final leaks = <(String, int)>[
      ('Claim page: visited, no claim, follow-up did not bring them back', n((o) => o.has('noclaim') && !o.has('claimed'))),
      ('Login: claimed, never logged in, even after reminders', n((o) => o.has('never'))),
      ('First visit: logged in, looked, changed nothing', n((o) => o.has('left'))),
      ('Review: edit declined, owner has gone quiet', n((o) => o.has('declined') && (o.end == 'quiet' || o.end == 'dormant'))),
      ('After approval: changes went live, owner has gone quiet (30 to 60 days)', n((o) => o.has('approved') && o.end == 'quiet')),
      ('After approval: owner dormant (over 60 days)', n((o) => o.has('approved') && o.end == 'dormant')),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final top = leaks.first;

    final avg = _review['avg_hours'];
    final within = _review['within_24h'];
    final reviewed = _review['reviewed'];

    // movement: the change since [_against] days ago, green when it is
    // good news, amber when it is not (more lost or dormant)
    Widget row(String k, int v, {Color? color, int? prev, bool upIsGood = true}) {
      Widget delta = const SizedBox(width: 44);
      if (prev != null) {
        final d = v - prev;
        final good = d == 0 ? null : (d > 0) == upIsGood;
        delta = SizedBox(
          width: 44,
          child: Text(
            d == 0 ? '·' : (d > 0 ? '+$d' : '$d'),
            textAlign: TextAlign.right,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: good == null ? Brand.inkFaint : (good ? Brand.success : Brand.goldTextDark),
                fontFeatures: const [ui.FontFeature.tabularFigures()]),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary))),
          Text('$v', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color ?? Brand.ink, fontFeatures: const [ui.FontFeature.tabularFigures()])),
          delta,
        ]),
      );
    }
    Widget againstChip(int d) {
      final on = _against == d;
      return InkWell(
        onTap: () => setState(() => _against = d),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text('vs $d days ago',
              style: TextStyle(fontSize: 10.5, letterSpacing: .6, fontWeight: FontWeight.w600,
                  color: on ? Brand.ink : Brand.inkFaint,
                  decoration: on ? TextDecoration.underline : null)),
        ),
      );
    }

    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('THE NUMBERS', style: TextStyle(fontSize: 10.5, letterSpacing: 1.2, fontWeight: FontWeight.w600, color: Brand.inkMuted))),
          againstChip(7),
          againstChip(30),
        ]),
        const SizedBox(height: 8),
        row('Claim-page visitors (distinct, all time)', _visitors),
        row('Owners who started a claim', _owners.length, prev: pOwners),
        row('Claimed profile', claimed, prev: pClaimed),
        if (recovered > 0) row('… of which recovered by the "was this you?" email', recovered),
        row('Logged in (now or after reminders)', login, prev: pLogin),
        row('Submitted an edit', submitted, prev: pSubmitted),
        row('Edit approved by you', approved, prev: pApproved),
        row('Returned within 30 days of approval${backKnown > 0 ? ' (of $backKnown we can tell)' : ''}', back, prev: pBackKnown > 0 ? pBack : null),
        row('Premium (paying)', premium, color: Brand.success, prev: pPremium),
        row('Still in the reminder sequence', waiting, prev: pWaiting, upIsGood: false),
        row('Quiet (30 to 60 days)', quiet, color: Brand.goldTextDark, prev: pQuiet, upIsGood: false),
        row('Lost or dormant', lost, color: Brand.goldTextDark, prev: pLost, upIsGood: false),
        if (reviewed != null) ...[
          const SizedBox(height: 8),
          Text('Your review: average ${avg ?? '-'} h, $within of $reviewed edits within 24 h.',
              style: const TextStyle(fontSize: 12, color: Brand.inkSecondary)),
        ],
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Brand.goldTint,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Brand.gold.withValues(alpha: .5)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('BIGGEST LEAK', style: TextStyle(fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: Brand.goldTextDark)),
            const SizedBox(height: 3),
            Text(top.$2 == 0 ? 'Nothing leaking yet.' : '${top.$1} (${top.$2} of ${_owners.length})',
                style: const TextStyle(fontSize: 12.5, color: Brand.goldTextDark, height: 1.4)),
          ]),
        ),
      ]),
    );
  }

  // ---------- next steps, as an inbox ----------

  Widget _inbox() {
    final open = _owners.where((o) => !o.done && o.next.isNotEmpty).toList();
    final done = _owners.where((o) => o.done).toList();
    final show = _showDone ? [...open, ...done] : open;
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text.rich(TextSpan(children: [
              const TextSpan(text: 'NEXT STEPS', style: TextStyle(fontSize: 10.5, letterSpacing: 1.2, fontWeight: FontWeight.w600, color: Brand.inkMuted)),
              TextSpan(text: '   ${open.length} open · ${done.length} done', style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
            ])),
          ),
          TextButton(
            onPressed: () => setState(() => _showDone = !_showDone),
            child: Text(_showDone ? 'Hide done' : 'Show done', style: const TextStyle(fontSize: 12)),
          ),
        ]),
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text('Write to them opens Outreach on that space. Tick the box once you have done the step; it drops off the list.',
              style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
        ),
        if (show.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Everything ticked.', style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
          )
        else
          for (final o in show) _ownerRow(o),
      ]),
    );
  }
}

// ---------------------------------------------------------------------
// Drawing the map.

class _FlowPainter extends CustomPainter {
  final double scale;
  final List<_Bead> beads;
  final Map<String, int> counts;
  final Map<String, double> lit;
  final String? selected;
  final List<String> slots; // one per owner: the result, or '' while running
  final Map<String, int>? prev; // each box's count [against] days ago, once the run is over
  final int against;
  final String footer; // the totals line under the squares
  final String header; // the period, top right
  final Map<String, Color> dots; // verdict colour per box

  _FlowPainter({
    required this.scale,
    required this.beads,
    required this.counts,
    required this.lit,
    required this.selected,
    required this.slots,
    required this.prev,
    required this.against,
    required this.footer,
    required this.header,
    required this.dots,
  });

  static const _flow = Color(0xFF2B8FBF); // the owner's path
  static const _flowSoft = Color(0x332B8FBF);
  static const _amber = Brand.gold;
  static const _amberSoft = Color(0x33F4B23E);
  static const _line = Color(0xFFDCE1E7);

  void _text(Canvas c, String s, Offset at, double size,
      {Color color = Brand.ink, FontWeight weight = FontWeight.w700, double spacing = .6,
      TextAlign align = TextAlign.center}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: weight, letterSpacing: spacing, fontFamily: 'Roboto')),
      textDirection: ui.TextDirection.ltr,
      textAlign: align,
    )..layout();
    final dx = align == TextAlign.center ? at.dx - tp.width / 2 : align == TextAlign.right ? at.dx - tp.width : at.dx;
    tp.paint(c, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);

    // faint grid, as on the page
    final grid = Paint()..color = const Color(0x0A142032)..strokeWidth = .6;
    for (double x = 0; x <= 400; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, 1135), grid);
    }
    for (double y = 0; y <= 1135; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(400, y), grid);
    }

    // the period, top right
    _text(canvas, header, const Offset(396, 12), 6.8, color: Brand.inkMuted, weight: FontWeight.w600, spacing: 1, align: TextAlign.right);
    // row labels
    for (final r in _kRows) {
      _text(canvas, r.$1, Offset(4, r.$2), 7.5, color: Brand.inkMuted, weight: FontWeight.w500, spacing: 1.1, align: TextAlign.left);
    }

    // edges
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = _line;
    final edgeOff = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = _line.withValues(alpha: .6);
    for (final e in _kEdges) {
      final off = _kByKey[e[0]]!.off || _kByKey[e[1]]!.off;
      canvas.drawPath(_edgePath(e[0], e[1]), off ? edgeOff : edge);
    }

    // trails of the beads on their way
    for (final b in beads) {
      final path = b.owner.path;
      for (var s = 0; s <= b.seg && s < path.length - 1; s++) {
        final full = _edgePath(path[s], path[s + 1]);
        final metric = full.computeMetrics().first;
        final to = s < b.seg ? metric.length : metric.length * b.k;
        if (to <= 0) continue;
        final nb = _kByKey[path[s + 1]]!;
        final amber = nb.block || nb.result == 'lost' || nb.result == 'dormant' || nb.result == 'quiet';
        final fade = b.finished ? .35 : 1.0;
        final glow = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round
          ..color = (amber ? _amberSoft : _flowSoft).withValues(alpha: .2 * fade);
        final line = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = (amber ? _amber : _flow).withValues(alpha: fade);
        final part = metric.extractPath(0, to);
        canvas.drawPath(part, glow);
        canvas.drawPath(part, line);
      }
    }

    // boxes
    for (final n in _kNodes) {
      final r = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(n.x, n.y), width: n.w, height: _kH), const Radius.circular(6));
      final isLit = lit.containsKey(n.key);
      final isSel = selected == n.key;
      Color fill = Brand.surface, stroke = _line, text = Brand.ink, sub = Brand.inkMuted;
      if (n.block) {
        fill = Brand.goldTint;
        stroke = _amber;
        text = Brand.goldTextDark;
        sub = Brand.goldTextDark;
      } else if (n.bar) {
        fill = const Color(0xFFEAF4F9);
        stroke = _flow;
      } else if (n.strip) {
        fill = Colors.transparent;
        text = Brand.inkSecondary;
      } else if (n.result == 'premium') {
        stroke = Brand.success;
      } else if (n.result == 'quiet' || n.result == 'dormant') {
        stroke = _amber;
        text = Brand.goldTextDark;
      }
      if (n.off) {
        text = Brand.inkFaint;
        sub = Brand.inkFaint;
      }
      if (isLit) {
        canvas.drawRRect(r.inflate(3), Paint()..color = (n.block ? _amberSoft : _flowSoft).withValues(alpha: .35));
        stroke = n.block ? _amber : _flow;
      }
      if (isSel) stroke = Brand.ink;
      canvas.drawRRect(r, Paint()..color = fill);
      final dot = dots[n.key];
      if (dot != null) {
        final c = Offset(n.x + n.w / 2 - 1, n.y - _kH / 2 + 1);
        canvas.drawCircle(c, 3.6, Paint()..color = Brand.surface);
        canvas.drawCircle(c, 2.6, Paint()..color = dot);
      }
      final sp = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSel ? 2 : 1.2
        ..color = stroke;
      if (n.off) {
        // dashed
        final p = Path()..addRRect(r);
        for (final m in p.computeMetrics()) {
          double d = 0;
          while (d < m.length) {
            canvas.drawPath(m.extractPath(d, math.min(d + 3, m.length)), sp);
            d += 6;
          }
        }
      } else {
        canvas.drawRRect(r, sp);
      }
      final tx = n.key == 'remind' ? n.x - 28 : n.x;
      _text(canvas, n.label, Offset(tx, n.y + (n.sub != null ? -4 : 0)), n.result != null ? 8.5 : 9.5,
          color: text, weight: n.strip ? FontWeight.w500 : FontWeight.w700);
      if (n.sub != null) {
        _text(canvas, n.sub!, Offset(tx, n.y + 7), 6.8, color: sub, weight: FontWeight.w400, spacing: .8);
      }
      final count = counts[n.key];
      if (count != null && (n.block || n.result != null || (n.strip && !n.off) || n.key == 'remind')) {
        final was = prev?[n.key];
        final d = (prev != null && !n.strip) ? count - (was ?? 0) : 0;
        final bad = n.block || n.result == 'lost' || n.result == 'dormant' || n.result == 'quiet';
        final good = (d > 0) != bad;
        if (n.key == 'remind') {
          // held inside the bar: a badge on its right, clear of the line down
          final label = '$count WAITING';
          final tp = TextPainter(
            text: TextSpan(text: label, style: const TextStyle(fontSize: 7.5, color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: .8, fontFamily: 'Roboto')),
            textDirection: ui.TextDirection.ltr,
          )..layout();
          final bw = tp.width + 12, bh = 14.0;
          final bx = n.x + n.w / 2 - bw - 6, by = n.y - bh / 2;
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(7)), Paint()..color = _flow);
          tp.paint(canvas, Offset(bx + 6, by + (bh - tp.height) / 2));
          if (d != 0) {
            _text(canvas, d > 0 ? '+$d' : '$d', Offset(n.x + n.w / 2 + 6, n.y), 7.5,
                color: good ? Brand.success : Brand.goldTextDark, weight: FontWeight.w600, spacing: 0, align: TextAlign.left);
          }
        } else {
          _text(canvas, '$count', Offset(n.x, n.y + _kH / 2 + 11), 9.5,
              color: n.block ? Brand.goldTextDark : _flow);
          // movement since [against] days ago, beside the count
          if (d != 0) {
            _text(canvas, d > 0 ? '+$d' : '$d', Offset(n.x + 12, n.y + _kH / 2 + 11), 6.5,
                color: good ? Brand.success : Brand.goldTextDark, weight: FontWeight.w600, spacing: 0, align: TextAlign.left);
          }
        }
      }
    }

    // percentages on the forks, from the beads that have finished
    final finished = beads.where((b) => b.finished).map((b) => b.owner).toList();
    if (finished.isNotEmpty) {
      final outs = <String, int>{};
      for (final e in _kEdges) {
        outs[e[0]] = (outs[e[0]] ?? 0) + 1;
      }
      for (final e in _kEdges) {
        if ((outs[e[0]] ?? 0) < 2) continue;
        final at = finished.where((o) => o.has(e[0])).length;
        if (at == 0) continue;
        final took = finished.where((o) {
          final i = o.path.indexOf(e[0]);
          return i >= 0 && i + 1 < o.path.length && o.path[i + 1] == e[1];
        }).length;
        if (took == 0) continue; // an unused branch gets no label
        final nb = _kByKey[e[1]]!;
        // the results row has its counts under the boxes; several sources
        // land on one box there, so no percentages (they piled up)
        if (nb.result != null) continue;
        final m = _edgePath(e[0], e[1]).computeMetrics().first;
        final at2 = m.getTangentForOffset(m.length / 2)!.position.translate(0, -6);
        _text(canvas, '${(took * 100 / at).round()}%', at2, 6.2, color: Brand.inkFaint, weight: FontWeight.w500, spacing: 0);
      }
    }

    // the beads
    for (final b in beads) {
      if (b.finished || b.seg >= b.owner.path.length - 1) continue;
      final m = _edgePath(b.owner.path[b.seg], b.owner.path[b.seg + 1]).computeMetrics().first;
      final pos = m.getTangentForOffset(m.length * b.k.clamp(0, 1))?.position;
      if (pos == null) continue;
      final amber = b.amber;
      canvas.drawCircle(pos, 9, Paint()..color = (amber ? _amber : _flow).withValues(alpha: .18));
      canvas.drawCircle(pos, 5, Paint()..color = amber ? _amber : _flow);
      canvas.drawCircle(pos, 2.2, Paint()..color = Colors.white);
      final t = b.owner.m['type'] == 'cafe' ? 'CAFÉ' : 'COWORKING';
      _text(canvas, t, Offset(pos.dx + 12, pos.dy - 8), 6.5, color: Brand.inkMuted, weight: FontWeight.w500, spacing: 1, align: TextAlign.left);
    }

    // the whole dataset: one small square per owner, and the totals
    _text(canvas, footer, const Offset(20, 1062), 7, color: Brand.inkMuted, weight: FontWeight.w600, spacing: 1, align: TextAlign.left);
    final rows = (slots.length / 24).ceil();
    if (prev != null) {
      _text(canvas, 'GREEN AND AMBER FIGURES: CHANGE SINCE $against DAYS AGO', Offset(20, 1076 + rows * 15.0 + 10), 6.2, color: Brand.inkFaint, weight: FontWeight.w500, spacing: 1, align: TextAlign.left);
    }
    for (var i = 0; i < slots.length; i++) {
      final r = Rect.fromLTWH(20 + (i % 24) * 15.0, 1076 + (i ~/ 24) * 15.0, 11, 11);
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(2));
      final end = slots[i];
      Color? fill;
      Color stroke = _line;
      switch (end) {
        case 'premium':
          fill = Brand.success;
          stroke = Brand.success;
        case 'new':
          stroke = _flow;
        case 'active':
          fill = _flow;
          stroke = _flow;
        case 'quiet':
          fill = Brand.goldTint;
          stroke = Brand.gold;
        case 'dormant':
          fill = Brand.inkFaint;
          stroke = Brand.inkFaint;
        case 'lost':
          fill = Brand.goldTint;
          stroke = _amber;
        case 'waiting':
          stroke = Brand.ink;
      }
      if (fill != null) canvas.drawRRect(rr, Paint()..color = fill);
      canvas.drawRRect(rr, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = stroke);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FlowPainter old) => true;
}

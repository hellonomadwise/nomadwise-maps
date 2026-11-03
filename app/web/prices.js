/* Price cards and one-price enquiries on nomadwise.io listing pages
 * (migration 243; mockup approved by Jonathan, 3 Nov 2026).
 *
 * Loaded on every nomadwise.io page from https://nomadmaps.io/prices.js
 * by a small Webflow site script; does something only on a coworking
 * listing page (/coworking/<slug>) whose prices are switched on in Nomad
 * Maps (sync_settings 'price_cards': OUR HQ first, then every page).
 *
 * Under the description it shows one card per group of prices
 * (Coworking, Private offices, Meeting rooms, Other) with the page's own
 * photos, the group's "From" price and every price as a choice. The
 * visitor picks ONE price, then says how many people and when (a
 * calendar; for a meeting room also the time and how long), their name
 * and email. On a computer the enquiry sits beside the cards; on a
 * phone a bar at the bottom opens it full screen.
 *
 * Sending goes through the page's own enquiry form (the "Research
 * Form" pop-up), so it reaches Nomad Maps like every enquiry does: the
 * import every ten minutes, then to the space or held for Premium
 * (free pages: 2 enquiries, migration 215). Nothing else on the page is
 * changed; the old booking-engine parts stay hidden as they are.
 *
 * The build fills in the two values below (scripts/export_map.py).
 */
(function () {
  'use strict';
  var URL_ = '__NW_SUPABASE_URL__';
  var KEY = '__NW_SUPABASE_KEY__';
  if (URL_.indexOf('__') === 0 || KEY.indexOf('__') === 0) return;
  if (window.__nwPrices) return;
  var m = /^\/coworking\/([a-z0-9-]+)\/?$/i.exec(location.pathname || '');
  if (!m) return;
  window.__nwPrices = true;
  var SLUG = m[1].toLowerCase();

  var RED = '#FF444F', TEAL = '#05434F';
  var GROUPS = [
    ['coworking', 'Coworking'],
    ['private_office', 'Private offices'],
    ['meeting_room', 'Meeting rooms'],
    ['other', 'Other']
  ];
  var PER = { hour: '/hr', 'half day': '/half day', day: '/day', week: '/wk', month: '/mo', year: '/yr' };
  var PER_LONG = { hour: '/hour', 'half day': '/half day', day: '/day', week: '/week', month: '/month', year: '/year' };
  var BY = { hour: 'the hour', 'half day': 'the half day', day: 'the day', week: 'the week', month: 'the month', year: 'the year' };

  var data = null;      // {space, groups:[...]} once loaded
  var root = null;      // our section
  var sheet = null;     // the phone enquiry sheet
  var S = {
    filter: 'all', picked: null, sent: false, sending: false, error: '',
    calOpen: false, monthOffset: 0, date: null, flexible: false,
    people: 'Just me', time: '10:00', length: '1 hour',
    name: '', email: '', message: '', sheetOpen: false, focusKey: null
  };

  // ------------------------------------------------------------ helpers
  function esc(t) {
    return String(t == null ? '' : t).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function track(ev, props) {
    try { if (window.posthog && window.posthog.capture) window.posthog.capture(ev, props || {}); } catch (e) {}
  }
  function today0() { var d = new Date(); d.setHours(0, 0, 0, 0); return d; }
  function addDays(d, n) { var x = new Date(d); x.setDate(x.getDate() + n); return x; }
  function nextMonday() { var t = today0(); return addDays(t, ((8 - t.getDay()) % 7) || 7); }
  function sameDay(a, b) { return a && b && a.getTime() === b.getTime(); }
  function fmtDate(d, long) {
    return d.toLocaleDateString('en-GB', long
      ? { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }
      : { weekday: 'short', day: 'numeric', month: 'long' });
  }
  function money(amount, currency, label) {
    if (label) return String(label).trim();
    if (amount == null || amount === '') return 'Price on request';
    var n = Number(amount);
    try {
      return new Intl.NumberFormat('en-GB', { style: 'currency', currency: currency || 'EUR',
        maximumFractionDigits: n % 1 ? 2 : 0 }).format(n);
    } catch (e) { return n + ' ' + (currency || ''); }
  }

  // What a price is for: its period, a shorter name and its note.
  function periodOf(name, details, cat) {
    var n = String(name || '').toLowerCase().replace(/-/g, ' ');
    var b = /\((hour|half day|day|week|month|year)\)\s*$/.exec(n);
    if (b) return b[1];
    // A bundle ("10 Day Passes", "Hourly Pass - 100 Hours") is one price
    // for the lot: no period.
    if (/\b\d+\s*(hour|day|week|month)s?\b/.test(n)) return null;
    // The name first, then the price's own words, exact phrases only.
    if (/\bhalf day\b/.test(n)) return 'half day';
    if (/\bhourly\b|\bper hour\b/.test(n)) return 'hour';
    if (/\bmonth(ly)?\b/.test(n)) return 'month';
    if (/\bweek(ly)?\b/.test(n)) return 'week';
    if (/\byear(ly)?\b|\bannual\b/.test(n)) return 'year';
    if (/\bday pass\b|\bfull day\b|\bdaily\b|\b1 day\b/.test(n)) return 'day';
    var d = details.join(' | ').toLowerCase();
    if (/\b(price )?per hour\b|\ban hour\b/.test(d)) return 'hour';
    if (/\b(price )?per month\b|\ba month\b|^monthly\b|\| monthly\b/.test(d)) return 'month';
    if (/\b(price )?per week\b|\ba week\b/.test(d)) return 'week';
    if (/\b(price )?per day\b/.test(d)) return 'day';
    if (cat === 'meeting_room') return 'hour';
    if (cat === 'private_office') return 'month';
    return null;
  }
  function shape(raw) {
    var groups = {};
    var vatWords = null, vatSame = true;
    (raw.prices || []).forEach(function (p, pi) {
      var cat = GROUPS.some(function (g) { return g[0] === p.category; }) ? p.category : 'other';
      var details = (p.details || []).map(function (x) { return String(x || '').trim(); }).filter(Boolean);
      var period = periodOf(p.name, details, cat);
      var name = String(p.name || '').replace(/\s*\((hour|half day|day|week|month|year)\)\s*$/i, '').trim();
      if (cat === 'meeting_room' && /^meeting room\s+\S/i.test(name)) name = name.replace(/^meeting room\s+/i, '');
      var label = money(p.amount, p.currency, p.label);
      // Webflow's "Starting from" marks the price shown on a phone, not
      // a "from" price: "from" comes only from the price's own words.
      var from = false;
      var vat = null;
      var notes = details.filter(function (d) {
        var l = d.toLowerCase();
        if (/^(per|a|an) (hour|day|week|month|year)$|^monthly$|^daily$|^hourly$/.test(l)) return false;
        if (/\bvat\b/.test(l) && d.length < 30) { vat = d; return false; }
        if (/^from\b/.test(l) && l.indexOf(label.toLowerCase()) >= 0) { from = true; return false; }
        return true;
      });
      if (pi === 0) vatWords = vat; else if (vatWords !== vat) vatSame = false;
      var item = {
        id: p.id, cat: cat, name: name || String(p.name || 'Price'),
        full: cat === 'meeting_room' && name && !/meeting|room/i.test(name) ? 'Meeting room ' + name : (name || p.name),
        amount: p.amount == null ? null : Number(p.amount), currency: p.currency,
        label: label, period: period, from: from,
        note: notes.slice(0, 2).join(' · '),
        priceText: (from ? 'from ' : '') + label + (period && p.amount != null ? ' ' + PER[period] : '')
      };
      (groups[cat] = groups[cat] || []).push(item);
    });
    var out = [];
    GROUPS.forEach(function (g) {
      var items = groups[g[0]];
      if (!items || !items.length) return;
      var priced = items.filter(function (i) { return i.amount != null; });
      var cur0 = priced.length ? priced[0].currency : null;
      var oneCur = priced.every(function (i) { return i.currency === cur0; });
      var low = oneCur ? priced.slice().sort(function (a, b) { return a.amount - b.amount; })[0] : priced[0];
      var periods = [];
      items.forEach(function (i) { if (i.period && periods.indexOf(i.period) < 0) periods.push(i.period); });
      var caps = [];
      items.forEach(function (i) {
        var c = /up to (\d+)/i.exec(i.note); if (c) caps.push(+c[1]);
      });
      var spec;
      if (caps.length > 1) spec = Math.min.apply(null, caps) + ' to ' + Math.max.apply(null, caps) + ' people';
      else spec = items.length + (items.length === 1 ? ' option' : ' options');
      if (periods.length) spec += ' · by ' + periods.map(function (x) { return BY[x]; }).join(' or ').replace(/ or the /g, ' or ');
      out.push({
        key: g[0], title: g[1], items: items, spec: spec,
        fromWord: low && (items.length > 1 || low.from) ? 'From' : '',
        price: low ? low.label : 'Ask',
        per: low && low.period ? PER_LONG[low.period] : ''
      });
    });
    return { space: raw.space || 'this space', groups: out, vat: vatSame && vatWords ? vatWords : '' };
  }

  function pickedItem() {
    if (!data || !S.picked) return null;
    for (var i = 0; i < data.groups.length; i++) {
      for (var j = 0; j < data.groups[i].items.length; j++) {
        if (data.groups[i].items[j].id === S.picked) return data.groups[i].items[j];
      }
    }
    return null;
  }
  function kindOf(it) {
    if (!it) return 'start';
    if (it.period === 'day') return 'day';
    if (it.period === 'hour' || it.period === 'half day' || (it.cat === 'meeting_room' && !it.period)) return 'hour';
    return 'start';
  }

  // ------------------------------------------------------------- styles
  function addStyles() {
    var css = [
      '.nwp{margin:36px 0 8px;font-family:inherit;color:#2C2C2C}',
      '.nwp *{box-sizing:border-box}',
      '.nwp h2.nwp-h{margin:0 0 6px;font-size:26px;font-weight:700;line-height:1.25}',
      '.nwp-sub{margin:0 0 16px;font-size:15px;color:#5E6670}',
      '.nwp-chips{display:flex;gap:8px;flex-wrap:wrap;margin:0 0 18px}',
      '.nwp-chip{min-height:42px;padding:0 16px;border-radius:10px;font-family:inherit;font-weight:500;font-size:15px;cursor:pointer;background:#fff;color:#2C2C2C;border:1px solid #C9CED4}',
      '.nwp-chip[aria-pressed="true"]{background:' + TEAL + ';color:#fff;border-color:' + TEAL + '}',
      '.nwp-wrap{display:flex;gap:24px;align-items:flex-start}',
      '.nwp-cards{flex:1 1 0;min-width:0;display:flex;flex-direction:column;gap:18px}',
      '.nwp-card{background:#fff;border:1px solid rgba(0,0,0,.08);border-radius:10px;overflow:hidden}',
      '.nwp-photo{display:block;width:100%;height:150px;object-fit:cover;background:#ECEEF1}',
      '.nwp-top{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;padding:16px 16px 6px}',
      '.nwp-title{margin:0;font-size:20px;font-weight:700;line-height:1.25}',
      '.nwp-spec{font-size:14px;color:#5E6670;margin-top:3px}',
      '.nwp-big{text-align:right;white-space:nowrap}',
      '.nwp-from{display:block;font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:#5E6670}',
      '.nwp-amt{font-size:26px;font-weight:900;line-height:1.1}',
      '.nwp-per{font-size:14px;font-weight:500;color:#5E6670}',
      '.nwp-list{list-style:none;margin:0;padding:4px 10px 12px;display:flex;flex-direction:column;gap:6px}',
      '.nwp-row{display:flex;align-items:center;gap:12px;padding:10px;min-height:48px;border-radius:10px;cursor:pointer;border:1.5px solid transparent}',
      '.nwp-row:hover{background:#F8F8FA}',
      '.nwp-row.on{background:#FFF1F2;border-color:' + RED + '}',
      '.nwp-row input{width:20px;height:20px;margin:0;accent-color:' + RED + ';flex-shrink:0}',
      '.nwp-rname{display:block;font-size:15px;font-weight:700}',
      '.nwp-rnote{display:block;font-size:13px;color:#5E6670;margin-top:1px}',
      '.nwp-rmain{flex:1 1 auto;min-width:0}',
      '.nwp-rprice{font-size:15px;font-weight:700;white-space:nowrap}',
      '.nwp-panel{flex:0 0 360px;position:sticky;top:96px;background:#fff;border:1px solid rgba(0,0,0,.08);border-radius:10px;padding:20px;box-shadow:0 6px 24px rgba(0,0,0,.06)}',
      '.nwp-f{display:flex;flex-direction:column;gap:14px}',
      '.nwp-ph{margin:0;font-size:19px;font-weight:700}',
      '.nwp-empty{margin:0;padding:14px;border-radius:10px;background:#F8F8FA;font-size:15px;line-height:1.5;color:#5E6670}',
      '.nwp-pick{padding:12px 14px;border-radius:10px;background:#FFF1F2;border:1px solid #FFC9CC;display:flex;align-items:center;gap:10px}',
      '.nwp-pick small{display:block;font-size:12px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:#5E6670}',
      '.nwp-pick b{display:block;font-size:16px}',
      '.nwp-pick span.nwp-pp{display:block;font-size:14px;color:#5E6670}',
      '.nwp-lab{display:flex;flex-direction:column;gap:6px;font-size:14px;font-weight:500}',
      '.nwp-in{height:46px;border:1px solid #C9CED4;border-radius:10px;padding:0 12px;font-family:inherit;font-weight:400;font-size:16px;background:#fff;color:#2C2C2C;width:100%}',
      'textarea.nwp-in{height:auto;padding:10px 12px;resize:vertical}',
      '.nwp-two{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}',
      '.nwp-when{display:flex;align-items:center;gap:10px;height:46px;padding:0 12px;border-radius:10px;background:#fff;cursor:pointer;border:1.5px solid #C9CED4;font-family:inherit;font-weight:400;font-size:16px;color:#2C2C2C;width:100%;text-align:left}',
      '.nwp-when[aria-expanded="true"]{border-color:' + TEAL + '}',
      '.nwp-cal{border:1px solid #C9CED4;border-radius:10px;padding:12px;display:flex;flex-direction:column;gap:10px;margin-top:6px}',
      '.nwp-quick{display:flex;gap:6px;flex-wrap:wrap}',
      '.nwp-q{min-height:36px;padding:0 12px;border-radius:10px;font-family:inherit;font-weight:500;font-size:14px;cursor:pointer;background:#F8F8FA;color:#2C2C2C;border:1.5px solid #F8F8FA}',
      '.nwp-q.on{background:#FFF1F2;border-color:' + RED + '}',
      '.nwp-mh{display:flex;align-items:center;justify-content:space-between}',
      '.nwp-mh b{font-size:15px}',
      '.nwp-nav{width:40px;height:40px;border:0;border-radius:10px;background:#F8F8FA;color:#2C2C2C;cursor:pointer;display:flex;align-items:center;justify-content:center}',
      '.nwp-nav:disabled{color:#B4BAC1;cursor:default}',
      '.nwp-grid{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:4px}',
      '.nwp-wd{text-align:center;font-size:12px;font-weight:700;color:#5E6670;padding-bottom:2px}',
      '.nwp-d{height:40px;border-radius:10px;font-family:inherit;font-weight:400;font-size:15px;cursor:pointer;background:#fff;color:#2C2C2C;border:1px solid transparent;padding:0}',
      '.nwp-d:hover:not(:disabled){border-color:#C9CED4}',
      '.nwp-d.today{font-weight:700;border-color:' + TEAL + '}',
      '.nwp-d.on{background:' + RED + ';color:#fff;font-weight:700;border-color:' + RED + '}',
      '.nwp-d:disabled{color:#B4BAC1;cursor:default;text-decoration:line-through;background:transparent}',
      '.nwp-d.blank{visibility:hidden}',
      '.nwp-send{min-height:52px;border:0;border-radius:10px;font-family:inherit;font-weight:700;font-size:19px;cursor:pointer;background:' + RED + ';color:#fff;width:100%}',
      '.nwp-send:disabled{background:#ECEEF1;color:#5E6670;cursor:default}',
      '.nwp-small{margin:0;font-size:13px;line-height:1.5;color:#5E6670}',
      '.nwp-small a{color:' + TEAL + '}',
      '.nwp-err{margin:0;font-size:14px;color:#B3261E}',
      '.nwp-done{display:flex;flex-direction:column;gap:12px}',
      '.nwp-tick{width:48px;height:48px;border-radius:10px;background:#E6F4EA;color:#1E7A43;display:flex;align-items:center;justify-content:center}',
      '.nwp-link{min-height:44px;border:0;border-radius:10px;background:transparent;color:' + TEAL + ';font-family:inherit;font-weight:500;font-size:15px;cursor:pointer}',
      '.nwp-bar{position:fixed;left:0;right:0;bottom:0;z-index:9990;background:#fff;border-top:1px solid rgba(0,0,0,.08);box-shadow:0 -6px 18px rgba(0,0,0,.06);padding:12px 16px calc(12px + env(safe-area-inset-bottom));display:none;align-items:center;gap:12px;font-family:Roboto,sans-serif;color:#2C2C2C}',
      '.nwp-bar b{display:block;font-size:15px}.nwp-bar span{display:block;font-size:13px;color:#5E6670}',
      '.nwp-bar button{min-height:50px;padding:0 22px;border:0;border-radius:10px;background:' + RED + ';color:#fff;font:700 19px Roboto,sans-serif;cursor:pointer}',
      '.nwp-sheet{position:fixed;inset:0;z-index:9995;background:#fff;display:none;flex-direction:column;font-family:Roboto,sans-serif;color:#2C2C2C}',
      '.nwp-sheet.open{display:flex}',
      '.nwp-sh{display:flex;align-items:center;gap:8px;padding:10px 8px;border-bottom:1px solid rgba(0,0,0,.08)}',
      '.nwp-sh h2{margin:0;font-size:18px;font-weight:700}',
      '.nwp-x{width:44px;height:44px;border:0;border-radius:10px;background:transparent;color:#2C2C2C;cursor:pointer;display:flex;align-items:center;justify-content:center}',
      '.nwp-sb{flex:1 1 auto;overflow-y:auto;padding:14px 16px 24px}',
      '@media (max-width: 991px){.nwp-panel{display:none}.nwp-bar.show{display:flex}}',
      '@media (min-width: 992px){.nwp-sheet{display:none !important}}'
    ].join('\n');
    var st = document.createElement('style');
    st.id = 'nwp-css';
    st.textContent = css;
    document.head.appendChild(st);
  }

  // ------------------------------------------------------------ the page
  var ICON_CAL = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#5E6670" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5" width="18" height="16" rx="2"></rect><path d="M3 10h18M8 3v4M16 3v4"></path></svg>';
  var ICON_L = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>';
  var ICON_R = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 18l6-6-6-6"></path></svg>';
  var ICON_TICK = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"></path></svg>';

  function photos() {
    var out = [];
    document.querySelectorAll('.gallery__image').forEach(function (img) {
      var src = img.currentSrc || img.src;
      if (src && out.indexOf(src) < 0) out.push(src);
    });
    return out;
  }

  function cardsHtml() {
    var pics = photos();
    var html = '';
    data.groups.forEach(function (g, gi) {
      if (S.filter !== 'all' && S.filter !== g.key) return;
      var pic = pics.length ? pics[(gi + 1) % pics.length] : '';
      html += '<article class="nwp-card">' +
        (pic ? '<img class="nwp-photo" src="' + esc(pic) + '" alt="" loading="lazy">' : '') +
        '<div class="nwp-top"><div><h3 class="nwp-title">' + esc(g.title) + '</h3>' +
        '<div class="nwp-spec">' + esc(g.spec) + '</div></div>' +
        '<div class="nwp-big">' + (g.fromWord ? '<span class="nwp-from">' + g.fromWord + '</span>' : '') +
        '<span class="nwp-amt">' + esc(g.price) + '</span><span class="nwp-per">' + esc(g.per) + '</span></div></div>' +
        '<ul class="nwp-list">';
      g.items.forEach(function (it) {
        var on = S.picked === it.id;
        html += '<li><label class="nwp-row' + (on ? ' on' : '') + '">' +
          '<input type="radio" name="nwp-price" value="' + esc(it.id) + '" data-k="r-' + esc(it.id) + '"' + (on ? ' checked' : '') + '>' +
          '<span class="nwp-rmain"><span class="nwp-rname">' + esc(it.name) + '</span>' +
          (it.note ? '<span class="nwp-rnote">' + esc(it.note) + '</span>' : '') + '</span>' +
          '<span class="nwp-rprice">' + esc(it.priceText) + '</span></label></li>';
      });
      html += '</ul></article>';
    });
    return html;
  }

  function calendarHtml(kind) {
    var t = today0();
    var first = new Date(t.getFullYear(), t.getMonth() + S.monthOffset, 1);
    var title = first.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
    var lead = (first.getDay() + 6) % 7;
    var inMonth = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
    var cells = Math.ceil((lead + inMonth) / 7) * 7;
    var nm = nextMonday();
    var firstNext = new Date(t.getFullYear(), t.getMonth() + 1, 1);
    var quick = kind === 'start'
      ? [['Next Monday', nm], ['1st of next month', firstNext], ["I'm flexible", 'flex']]
      : [['Today', t], ['Tomorrow', addDays(t, 1)], ['Next Monday', nm], ["I'm flexible", 'flex']];
    var h = '<div class="nwp-cal"><div class="nwp-quick">';
    quick.forEach(function (q, i) {
      var on = q[1] === 'flex' ? S.flexible : (!S.flexible && sameDay(S.date, q[1]));
      h += '<button type="button" class="nwp-q' + (on ? ' on' : '') + '" data-a="quick" data-v="' + (q[1] === 'flex' ? 'flex' : q[1].getTime()) + '" data-k="q' + i + '">' + esc(q[0]) + '</button>';
    });
    h += '</div><div class="nwp-mh"><button type="button" class="nwp-nav" data-a="prev" data-k="prev" aria-label="Previous month"' + (S.monthOffset <= 0 ? ' disabled' : '') + '>' + ICON_L + '</button>' +
      '<b aria-live="polite">' + esc(title) + '</b>' +
      '<button type="button" class="nwp-nav" data-a="next" data-k="next" aria-label="Next month"' + (S.monthOffset >= 11 ? ' disabled' : '') + '>' + ICON_R + '</button></div>' +
      '<div class="nwp-grid" role="group" aria-label="' + esc(title) + '">';
    ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'].forEach(function (w) { h += '<span class="nwp-wd" aria-hidden="true">' + w + '</span>'; });
    for (var i = 0; i < cells; i++) {
      var n = i - lead + 1;
      if (n < 1 || n > inMonth) { h += '<span class="nwp-d blank" aria-hidden="true"></span>'; continue; }
      var d = new Date(first.getFullYear(), first.getMonth(), n);
      var past = d < t, isT = sameDay(d, t), on = !S.flexible && sameDay(d, S.date);
      h += '<button type="button" class="nwp-d' + (isT ? ' today' : '') + (on ? ' on' : '') + '" data-a="day" data-v="' + d.getTime() + '" data-k="d' + d.getTime() + '"' +
        (past ? ' disabled' : '') + ' aria-pressed="' + on + '" aria-label="' + esc(fmtDate(d, true) + (isT ? ', today' : '')) + '">' + n + '</button>';
    }
    return h + '</div></div>';
  }

  function formHtml(where) {
    var it = pickedItem();
    if (S.sent) {
      return '<div class="nwp-done"><div class="nwp-tick">' + ICON_TICK + '</div>' +
        '<h3 class="nwp-ph">Sent to ' + esc(data.space) + '</h3>' +
        '<p class="nwp-small" style="font-size:15px;color:#2C2C2C">You asked about ' + esc(S.sentAbout) + '. ' + esc(data.space) +
        ' replies to you by email, at ' + esc(S.email) + '.</p>' +
        '<button type="button" class="nwp-link" data-a="again" data-k="again">Ask about something else</button></div>';
    }
    var kind = kindOf(it);
    var whenLabel = kind === 'start' ? 'When would you like to start?' : 'Which day?';
    var whenText = S.flexible ? "I'm flexible on dates" : (S.date ? fmtDate(S.date) : 'Pick a date');
    var h = '<div class="nwp-f">';
    if (where === 'panel') h += '<h3 class="nwp-ph">Ask ' + esc(data.space) + '</h3>';
    if (!it) {
      h += '<p class="nwp-empty">Pick a price to start. You can ask about one thing at a time.</p>';
    } else {
      h += '<div class="nwp-pick"><span style="flex:1 1 auto"><small>You\'re asking about</small><b>' + esc(it.full) + '</b>' +
        '<span class="nwp-pp">' + esc(it.priceText) + (it.note ? ' · ' + esc(it.note) : '') + '</span></span>' +
        (where === 'sheet' ? '<button type="button" class="nwp-link" data-a="close" data-k="change">Change</button>' : '') + '</div>';
    }
    h += '<label class="nwp-lab">How many people<select class="nwp-in" data-f="people" data-k="people">';
    ['Just me', '2', '3 to 5', '6 to 10', 'More than 10'].forEach(function (o) {
      h += '<option' + (S.people === o ? ' selected' : '') + '>' + o + '</option>';
    });
    h += '</select></label>';
    var wid = 'nwp-when-' + where;
    h += '<div class="nwp-lab"><span id="' + wid + '">' + whenLabel + '</span>' +
      '<button type="button" class="nwp-when" data-a="cal" data-k="cal" aria-labelledby="' + wid + '" aria-expanded="' + S.calOpen + '">' + ICON_CAL +
      '<span style="flex:1 1 auto">' + esc(whenText) + '</span></button>' +
      (S.calOpen ? calendarHtml(kind) : '') + '</div>';
    if (kind === 'hour') {
      h += '<div class="nwp-two"><label class="nwp-lab">From<select class="nwp-in" data-f="time" data-k="time">';
      for (var hr = 7; hr <= 20; hr++) {
        var tt = (hr < 10 ? '0' : '') + hr + ':00';
        h += '<option' + (S.time === tt ? ' selected' : '') + '>' + tt + '</option>';
      }
      h += '</select></label><label class="nwp-lab">For how long<select class="nwp-in" data-f="length" data-k="length">';
      ['1 hour', '2 hours', '3 hours', 'Half a day', 'All day'].forEach(function (o) {
        h += '<option' + (S.length === o ? ' selected' : '') + '>' + o + '</option>';
      });
      h += '</select></label></div>';
    }
    h += '<label class="nwp-lab">Your name<input class="nwp-in" type="text" autocomplete="name" maxlength="120" data-f="name" data-k="name" value="' + esc(S.name) + '"></label>' +
      '<label class="nwp-lab">Your email<input class="nwp-in" type="email" autocomplete="email" maxlength="200" data-f="email" data-k="email" value="' + esc(S.email) + '"></label>' +
      '<label class="nwp-lab"><span>Anything to add? <span style="font-weight:400;color:#5E6670">(optional)</span></span>' +
      '<textarea class="nwp-in" rows="2" maxlength="1500" data-f="message" data-k="message">' + esc(S.message) + '</textarea></label>';
    if (S.error) h += '<p class="nwp-err" role="alert">' + esc(S.error) + '</p>';
    h += '<button type="button" class="nwp-send" data-a="send" data-k="send"' + (!it || S.sending ? ' disabled' : '') + '>' +
      (S.sending ? 'Sending...' : (it ? 'Send enquiry' : 'Pick a price to start')) + '</button>' +
      '<p class="nwp-small">Free, with no obligation. ' + esc(data.space) + ' replies to you by email. By sending you agree to our <a href="/legal-information" target="_blank" rel="noopener">terms</a>.</p>';
    return h + '</div>';
  }

  function render() {
    if (!root || !data) return;
    var active = document.activeElement;
    var key = S.focusKey || (active && active.getAttribute && active.getAttribute('data-k'));
    var chips = '';
    if (data.groups.length > 1) {
      chips = '<div class="nwp-chips" role="group" aria-label="Show prices for">';
      [['all', 'All prices']].concat(data.groups.map(function (g) { return [g.key, g.title]; })).forEach(function (c) {
        chips += '<button type="button" class="nwp-chip" data-a="filter" data-v="' + c[0] + '" data-k="f-' + c[0] + '" aria-pressed="' + (S.filter === c[0]) + '">' + esc(c[1]) + '</button>';
      });
      chips += '</div>';
    }
    root.innerHTML =
      '<h2 class="nwp-h">Passes and prices at ' + esc(data.space) + '</h2>' +
      '<p class="nwp-sub">Pick what you\'re looking for and ask ' + esc(data.space) + ' about it.' +
      (data.vat ? ' All prices ' + esc(data.vat.replace(/^prices?\s+/i, '')) + '.' : '') + ' Prices are set by ' + esc(data.space) + '.</p>' +
      chips +
      '<div class="nwp-wrap"><div class="nwp-cards" role="radiogroup" aria-label="Choose one price">' + cardsHtml() + '</div>' +
      '<aside class="nwp-panel" aria-label="Your enquiry">' + formHtml('panel') + '</aside></div>';
    // the phone bar and sheet
    var it = pickedItem();
    var bar = document.getElementById('nwp-bar');
    if (bar) {
      bar.className = 'nwp-bar' + (it && !S.sent ? ' show' : '');
      bar.innerHTML = it ? '<span style="flex:1 1 auto;min-width:0"><b>' + esc(it.full) + '</b><span>' + esc(it.priceText) + ' · ' + esc(data.space) + '</span></span>' +
        '<button type="button" data-a="open" data-k="open">Enquire</button>' : '';
    }
    if (sheet) {
      sheet.className = 'nwp-sheet' + (S.sheetOpen ? ' open' : '');
      sheet.querySelector('.nwp-sb').innerHTML = formHtml('sheet');
    }
    if (key) {
      var scope = S.sheetOpen && sheet ? sheet : root;
      var el = scope.querySelector('[data-k="' + key + '"]') || root.querySelector('[data-k="' + key + '"]');
      if (el && el.focus) { try { el.focus({ preventScroll: true }); } catch (e) { el.focus(); } }
    }
    S.focusKey = null;
  }

  // ------------------------------------------------------------- events
  function onClick(e) {
    var b = e.target.closest && e.target.closest('[data-a]');
    if (!b) return;
    var a = b.getAttribute('data-a'), v = b.getAttribute('data-v');
    S.focusKey = b.getAttribute('data-k');
    if (a === 'filter') { S.filter = v; }
    else if (a === 'cal') { S.calOpen = !S.calOpen; }
    else if (a === 'prev') { S.monthOffset = Math.max(0, S.monthOffset - 1); }
    else if (a === 'next') { S.monthOffset = Math.min(11, S.monthOffset + 1); }
    else if (a === 'day') { S.date = new Date(+v); S.flexible = false; S.calOpen = false; S.focusKey = 'cal'; }
    else if (a === 'quick') {
      if (v === 'flex') { S.flexible = true; }
      else {
        S.date = new Date(+v); S.flexible = false;
        var t = today0();
        S.monthOffset = (S.date.getFullYear() - t.getFullYear()) * 12 + S.date.getMonth() - t.getMonth();
      }
      S.calOpen = false; S.focusKey = 'cal';
    }
    else if (a === 'send') { send(); return; }
    else if (a === 'again') { S.sent = false; S.picked = null; S.message = ''; S.focusKey = null; if (S.sheetOpen) { closeSheet(); return; } }
    else if (a === 'open') { S.sheetOpen = true; S.focusKey = 'people'; document.documentElement.style.overflow = 'hidden'; }
    else if (a === 'close') { closeSheet(); return; }
    render();
  }
  function onChange(e) {
    var t = e.target;
    if (t.name === 'nwp-price') {
      S.picked = t.value; S.sent = false; S.error = '';
      var it = pickedItem();
      if (it) {
        if (!S.date && !S.flexible) S.date = kindOf(it) === 'start' ? nextMonday() : addDays(today0(), 1);
        track('price_card_picked', { space: data.space, price: it.full, slug: SLUG });
      }
      S.focusKey = 'r-' + t.value;
      render();
      return;
    }
    var f = t.getAttribute && t.getAttribute('data-f');
    if (f) S[f] = t.value;
  }
  function onInput(e) {
    var f = e.target.getAttribute && e.target.getAttribute('data-f');
    if (f) S[f] = e.target.value;
  }
  function closeSheet() {
    S.sheetOpen = false;
    document.documentElement.style.overflow = '';
    render();
    var bt = document.querySelector('#nwp-bar button');
    if (bt) bt.focus();
  }

  // ------------------------------------------------------------ sending
  function send() {
    var it = pickedItem();
    if (!it || S.sending) return;
    S.name = S.name.trim(); S.email = S.email.trim();
    if (!S.name) { S.error = 'Please add your name.'; S.focusKey = 'name'; render(); return; }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(S.email)) { S.error = 'Please check your email address.'; S.focusKey = 'email'; render(); return; }
    var form = document.getElementById('wf-form-Research-Form');
    var box = form && form.closest('.w-form');
    if (!form) { S.error = 'Sorry, this could not be sent from here. Please email spaces@nomadwise.io.'; render(); return; }
    var kind = kindOf(it);
    var when = S.flexible ? 'Flexible on dates' : (S.date ? fmtDate(S.date, true) : 'Not given');
    var lines = [
      'Asking about: ' + it.full + ' (' + it.priceText + ')',
      'People: ' + S.people,
      (kind === 'start' ? 'Starting: ' : 'Day: ') + when
    ];
    if (kind === 'hour') lines.push('Time: from ' + S.time + ', ' + S.length);
    if (S.message.trim()) lines.push('', S.message.trim());
    lines.push('', '(Sent from the price list on the page.)');
    function set(name, val) {
      var el = form.querySelector('[name="' + name + '"]');
      if (!el) return;
      if (el.type === 'checkbox') el.checked = !!val; else el.value = val;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    set('Text-area', lines.join('\n'));
    set('Name-Of-Customer-2', S.name);
    set('email-of-customer-2', S.email);
    set('ticked-terms-2', true);
    // The form's own checks (its email field is stricter than ours).
    if (form.checkValidity && !form.checkValidity()) {
      var bad = form.querySelector(':invalid');
      var nm = bad && bad.getAttribute('name');
      S.error = nm === 'email-of-customer-2' ? 'Please check your email address.'
        : (nm === 'Name-Of-Customer-2' ? 'Please check your name.' : 'Sorry, this could not be sent. Please email spaces@nomadwise.io.');
      S.focusKey = nm === 'email-of-customer-2' ? 'email' : (nm === 'Name-Of-Customer-2' ? 'name' : null);
      render();
      return;
    }
    var done = box && box.querySelector('.w-form-done');
    var fail = box && box.querySelector('.w-form-fail');
    // A thank-you still showing from the site's own pop-up is not ours.
    try { if (done) done.style.display = 'none'; if (fail) fail.style.display = 'none'; form.style.display = ''; } catch (e) {}
    S.sending = true; S.error = ''; S.focusKey = null; render();
    var started = Date.now(), gaveUp = false;
    function shown(el) { return el && getComputedStyle(el).display !== 'none'; }
    try {
      // Webflow's own handler sends it (its AJAX post); never a plain
      // browser submit, which would put the details in the address.
      var btn = form.querySelector('[type="submit"]');
      if (form.requestSubmit) form.requestSubmit(btn || undefined);
      else if (window.jQuery) window.jQuery(form).trigger('submit');
      else if (btn) btn.click();
    } catch (e) {
      S.sending = false; S.error = 'Sorry, that did not send. Please try again.'; render(); return;
    }
    (function wait() {
      if (shown(done)) {
        S.sending = false; S.sent = true; S.error = ''; S.focusKey = 'again'; S.sentAbout = it.full.charAt(0).toLowerCase() + it.full.slice(1) +
          (S.flexible ? ', with flexible dates' : (S.date ? (kind === 'start' ? ', starting ' : ', on ') + fmtDate(S.date) : ''));
        track('price_enquiry_sent', { space: data.space, price: it.full, slug: SLUG });
        // the pop-up form is ready again for the next one
        setTimeout(function () {
          try {
            done.style.display = 'none'; form.style.display = ''; form.reset();
            form.querySelectorAll('.w--redirected-checked').forEach(function (x) { x.classList.remove('w--redirected-checked'); });
          } catch (e) {}
        }, 1500);
        render();
        return;
      }
      if (shown(fail)) {
        S.sending = false;
        S.error = 'Sorry, that did not send. Please try again, or email spaces@nomadwise.io.';
        try { fail.style.display = 'none'; form.style.display = ''; } catch (e) {}
        render();
        return;
      }
      // Slow: say so, but keep watching (and keep Send off) for a minute,
      // so a late success still counts and nothing is sent twice.
      if (!gaveUp && Date.now() - started > 20000) {
        gaveUp = true;
        S.error = 'This is taking a while. Please wait a moment.';
        render();
      }
      if (Date.now() - started > 60000) {
        S.sending = false;
        S.error = 'Sorry, that did not send. Please try again, or email spaces@nomadwise.io.';
        render();
        return;
      }
      setTimeout(wait, 300);
    })();
  }

  // ------------------------------------------------------------- start
  function mount() {
    var desc = document.querySelector('.left-column .modal-more-div') ||
      document.querySelector('.modal-more-div');
    var host = desc && desc.parentElement;
    if (!host) return false;
    addStyles();
    root = document.createElement('section');
    root.className = 'nwp';
    root.id = 'prices';
    root.setAttribute('aria-label', 'Passes and prices');
    host.insertBefore(root, desc.nextSibling);
    var bar = document.createElement('div');
    bar.id = 'nwp-bar';
    bar.className = 'nwp-bar';
    document.body.appendChild(bar);
    sheet = document.createElement('div');
    sheet.className = 'nwp-sheet';
    sheet.setAttribute('role', 'dialog');
    sheet.setAttribute('aria-modal', 'true');
    sheet.setAttribute('aria-label', 'Your enquiry');
    sheet.innerHTML = '<div class="nwp-sh"><button type="button" class="nwp-x" data-a="close" data-k="x" aria-label="Back to prices">' + ICON_L + '</button>' +
      '<h2>Ask ' + esc(data.space) + '</h2></div><div class="nwp-sb"></div>';
    document.body.appendChild(sheet);
    [root, bar, sheet].forEach(function (el) {
      el.addEventListener('click', onClick);
      el.addEventListener('change', onChange);
      el.addEventListener('input', onInput);
    });
    document.addEventListener('keydown', function (e) {
      if (!S.sheetOpen) return;
      if (e.key === 'Escape') { closeSheet(); return; }
      // Tab stays inside the sheet while it is open
      if (e.key === 'Tab') {
        var f = [].slice.call(sheet.querySelectorAll('button:not([disabled]),select,input,textarea,a[href]'));
        if (!f.length) return;
        var first = f[0], last = f[f.length - 1];
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
        else if (!sheet.contains(document.activeElement)) { e.preventDefault(); first.focus(); }
      }
    });
    if (window.matchMedia) {
      var wide = window.matchMedia('(min-width: 992px)');
      var onWide = function () { if (wide.matches && S.sheetOpen) closeSheet(); };
      if (wide.addEventListener) wide.addEventListener('change', onWide); else if (wide.addListener) wide.addListener(onWide);
    }
    render();
    return true;
  }

  function start() {
    fetch(URL_ + '/rest/v1/rpc/page_prices', {
      method: 'POST',
      headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_slug: SLUG })
    }).then(function (r) { return r.ok ? r.json() : null; })
      .then(function (raw) {
        if (!raw || !raw.show) return;
        data = shape(raw);
        if (!data.groups.length) return;
        mount();
      })
      .catch(function () {});
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();

/* Price cards and one-price enquiries on nomadwise.io listing pages
 * (migration 243; mockup approved by Jonathan, 3 Nov 2026).
 *
 * Loaded on every nomadwise.io page from https://nomadmaps.io/prices.js
 * by a small Webflow site script; does something only on a coworking
 * listing page (/coworking/<slug>) whose prices are switched on in Nomad
 * Maps (sync_settings 'price_cards': OUR HQ first, then every page).
 *
 * Under the description: on a computer a price list (each group with a
 * small photo, its "From" price, and every price with its own Request
 * button); on a phone tabs, one group at a time with its photo. Request
 * opens a pop-up (sliding up full screen on a phone) with that price
 * already chosen: how many people, when (a calendar; for a meeting room
 * also the start time and how long), name, email, an optional note.
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
  // An area page ("Meeting rooms in Shoreditch", /workspace/<slug>):
  // each Request button opens this same pop-up on the area page itself,
  // for that space and price (Jonathan, 22 Nov 2026). Sending goes
  // through that space's own page, loaded out of sight (see areaFrame).
  var AREA = !m && /^\/workspace\/[a-z0-9-]+\/?$/i.test(location.pathname || '');
  // A space's page loaded out of sight by an area page: no price list
  // and no page count, only the form the area page sends through.
  var FRAMED = false;
  try { FRAMED = window.top !== window.self; } catch (e) { FRAMED = true; }
  if (!m && !AREA) return;
  window.__nwPrices = true;
  var SLUG = m ? m[1].toLowerCase() : '';
  var AREA_PIC = '', AREA_BTN = null;

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
    tab: 0, bad: null, picked: null, sent: false, sending: false, error: '',
    calOpen: false, monthOffset: 0, date: null, flexible: false,
    people: 'Just me', time: '10:00', length: '1 hour',
    name: '', email: '', message: '', news: false, sheetOpen: false, focusKey: null
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
  // The price as a row shows it: the usual price struck through, then
  // ours, then a small "Nomadwise discount" mark.
  function priceHtml(it) {
    if (!it.was) return esc(it.priceText);
    return '<s class="nwp-was">' + esc(it.was) + '</s>' + esc(it.priceText) +
      '<em class="nwp-deal">Nomadwise discount</em>';
  }
  function today0() { var d = new Date(); d.setHours(0, 0, 0, 0); return d; }
  function addDays(d, n) { var x = new Date(d); x.setDate(x.getDate() + n); return x; }
  function nextMonday() { var t = today0(); return addDays(t, ((8 - t.getDay()) % 7) || 7); }
  // The days of the week the space is closed (0 = Sunday), from its
  // opening hours; the date a request starts on skips them (Jonathan,
  // 22 Nov 2026). The visitor can still pick any date.
  var SHUT = [];
  function openDay(d) {
    for (var i = 0; i < 7 && SHUT.indexOf(d.getDay()) >= 0; i++) d = addDays(d, 1);
    return d;
  }
  function sameDay(a, b) { return a && b && a.getTime() === b.getTime(); }
  // A request by the hour never asks for a time that has gone
  // (Jonathan, 23 Nov 2026, after a test asked for 10:00 on a day that
  // was already 13:57). By the visitor's own clock: the page does not
  // know the space's time zone.
  var HOUR_FIRST = 7, HOUR_LAST = 20;
  function firstHourOn(d) {
    if (!d || !sameDay(d, today0())) return HOUR_FIRST;
    return Math.max(HOUR_FIRST, new Date().getHours() + 1);
  }
  function hourText(h) { return (h < 10 ? '0' : '') + h + ':00'; }
  // Moves the day and time on when they have passed; true when it did.
  function keepAhead(kind) {
    if (kind !== 'hour' || S.flexible || !S.date) return false;
    var moved = false, t = today0();
    if (S.date < t) { S.date = t; moved = true; }
    if (firstHourOn(S.date) > HOUR_LAST) {
      S.date = openDay(addDays(t, 1)); moved = true;
    }
    if (moved) S.monthOffset = (S.date.getFullYear() - t.getFullYear()) * 12 + S.date.getMonth() - t.getMonth();
    var first = firstHourOn(S.date);
    if (parseInt(S.time, 10) < first) { S.time = hourText(first); moved = true; }
    return moved;
  }
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
      // "Meeting room Tokyo" reads as "Tokyo" under Meeting rooms, but a
      // room the space calls "Meeting Room 1" or "Meeting Room LG.02"
      // keeps its name: the space has to recognise it in a request.
      if (cat === 'meeting_room' && /^meeting room\s+[a-z]{3,}/i.test(name) && !/^meeting room\s+\S*[\d.&]/i.test(name)) name = name.replace(/^meeting room\s+/i, '');
      var label = money(p.amount, p.currency, p.label);
      // Webflow's "Starting from" marks the price shown on a phone, not
      // a "from" price: "from" comes only from the price's own words.
      var from = false;
      // A label that already says "From £118" is a "from" price: keep
      // the word out of the label so it is never written twice.
      if (/^from\s+\S/i.test(label)) { from = true; label = label.replace(/^from\s+/i, ''); }
      var vat = null;
      var notes = details.filter(function (d) {
        var l = d.toLowerCase();
        if (/^(per|a|an) (hour|day|week|month|year)$|^monthly$|^daily$|^hourly$/.test(l)) return false;
        if (/^price per room, per (hour|day)$|^per (person|desk), per (month|day)$|^per desk$/.test(l) && period) return false;
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
        priceText: (from ? 'from ' : '') + label + (period && p.amount != null ? ' ' + PER[period] : ''),
        // A price the space gives Nomadwise visitors: its usual price is
        // shown struck through beside it (Jonathan, 22 Nov 2026).
        was: p.was ? String(p.was) : ''
      };
      item.askText = item.priceText + (item.was ? ', Nomadwise discount, usually ' + item.was : '');
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
        var c = /up to (\d+)/i.exec(i.note); if (c && caps.indexOf(+c[1]) < 0) caps.push(+c[1]);
      });
      var spec;
      // "4 to 12 people" only when the sizes differ ("3 to 3" never shows).
      if (caps.length > 1) spec = Math.min.apply(null, caps) + ' to ' + Math.max.apply(null, caps) + ' people';
      else spec = items.length + (items.length === 1 ? ' option' : ' options');
      if (periods.length) spec += ' · by ' + periods.map(function (x) { return BY[x]; }).join(' or ').replace(/ or the /g, ' or ');
      out.push({
        key: g[0], title: g[1], items: items, spec: spec,
        fromWord: low && (items.length > 1 || low.from) ? 'From' : '',
        // No priced option in the group: the top says "Price on request"
        // where the price would stand (it read "Ask" until 23 Nov 2026).
        price: low ? low.label : '',
        per: low && low.period ? PER_LONG[low.period] : ''
      });
    });
    return {
      space: raw.space || 'this space', groups: out, vat: vatSame && vatWords ? vatWords : '',
      checked: checkedWords(raw.checked_on),
      site: /^https?:\/\//i.test(raw.website || '') ? String(raw.website) : ''
    };
  }

  // "checked November 2026": the month the prices were last checked
  // (Jonathan, 23 Nov 2026). Only the month, and only while the check
  // is under six months old, so the page never shows a stale date.
  function checkedWords(day) {
    var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(day || ''));
    if (!m) return '';
    var d = new Date(+m[1], +m[2] - 1, +m[3]);
    var age = (Date.now() - d.getTime()) / 86400000;
    if (isNaN(age) || age < -2 || age > 183) return '';
    return 'checked ' + d.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
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
  // Jonathan, 3 Nov 2026: on a computer a price list (every price with its
  // own Request button, a small photo per group); on a phone tabs (one
  // group at a time, its photo at full width). Request opens a pop-up
  // with the form: "super slick, as if we are a fully funded series A
  // SaaS". Motion is turned off for people who ask their device for less.
  function addStyles() {
    var EASE = 'cubic-bezier(.2,.8,.2,1)';
    var css = [
      '.nwp,.nwp-sheet{--nwp-red:' + RED + ';--nwp-red-ink:#D7303A;--nwp-teal:' + TEAL + ';--nwp-ink:#2C2C2C;--nwp-muted:#5E6670;--nwp-line:rgba(0,0,0,.08);--nwp-soft:#F8F8FA}',
      '.nwp *,.nwp-sheet *{box-sizing:border-box}',
      '.nwp label,.nwp-sheet label{margin:0;font-weight:400}',
      '.nwp{margin:28px 0 36px;font-family:inherit;color:var(--nwp-ink);scroll-margin-top:84px;animation:nwp-in .35s ' + EASE + ' both}',
      '.nwp-jump{display:none}',
      '.nwp-hrs,.nwp-bar{display:none}',
      '@media (max-width: 767px){' +
        '.nwp-hrs{display:flex;align-items:center;justify-content:space-between;gap:12px;width:100%;min-height:44px;margin:0;padding:0;border:0;background:transparent;font-family:Roboto,sans-serif;text-align:left;color:#2C2C2C;cursor:pointer}' +
        '.nwp-hrs b{font-size:15px;font-weight:500;line-height:1.3}' +
        '.nwp-hrs span{flex:none;font-size:14px;font-weight:700;color:#05434F;text-decoration:underline}' +
        '.nwp-week.nwp-shut{display:none !important}' +
        '.nwp-bar.on{display:flex;align-items:center;justify-content:center;gap:8px;position:fixed;left:12px;right:88px;bottom:18px;min-height:52px;padding:6px 14px;border:0;border-radius:8px;background:#D7303A;color:#fff;font-family:Roboto,sans-serif;box-shadow:0 6px 20px rgba(20,32,50,.25);z-index:2147482990;cursor:pointer}' +
        '.nwp-bar b{font-size:15px;font-weight:700;white-space:nowrap}' +
        '.nwp-bar span{font-size:13.5px;font-weight:400;opacity:.95;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
      '}',
      '@media (max-width: 767px){.nwp-jump{display:flex;align-items:center;justify-content:center;min-height:44px;margin:4px 0 0;font-family:Roboto,sans-serif;font-size:14.5px;line-height:1.3;font-weight:700;color:#05434F;text-decoration:underline;text-align:center}}',
      '@keyframes nwp-in{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}',
      '.nwp h2.nwp-h{margin:0 0 4px;font-size:21px;font-weight:700;line-height:1.25}',
      '.nwp-sub{margin:0 0 14px;font-size:14px;line-height:1.45;color:var(--nwp-muted)}',
      '.nwp-site{color:var(--nwp-teal);font-weight:700;text-decoration:underline;white-space:nowrap}',
      // shared: the Request button
      '.nwp-enq{flex:none;min-height:34px;padding:0 14px;border-radius:8px;border:1.5px solid var(--nwp-red);background:#fff;color:var(--nwp-red-ink);font-family:inherit;font-weight:700;font-size:13.5px;line-height:1;cursor:pointer;transition:background .15s,color .15s,transform .1s}',
      '.nwp-enq:hover{background:var(--nwp-red);color:#fff}',
      '.nwp-enq:active{transform:scale(.97)}',
      '.nwp button:focus-visible,.nwp-sheet button:focus-visible,.nwp-sheet input:focus-visible,.nwp-sheet select:focus-visible,.nwp-sheet textarea:focus-visible,.nwp-sheet a:focus-visible{outline:2px solid var(--nwp-teal);outline-offset:2px}',
      // the computer: a price list
      '.nwp-box{border:1px solid var(--nwp-line);border-radius:8px;overflow:hidden;background:#fff}',
      '.nwp-grp + .nwp-grp{border-top:1px solid var(--nwp-line)}',
      '.nwp-gh{display:flex;align-items:center;gap:14px;padding:12px 16px;background:var(--nwp-soft)}',
      '.nwp-gimg{width:88px;height:66px;border-radius:8px;object-fit:cover;display:block;flex:none;background:#E6E9ED}',
      '.nwp-gt{flex:1 1 auto;min-width:0}',
      '.nwp-gt b{display:block;font-size:16px;line-height:1.3}',
      '.nwp-gt span{display:block;font-size:13px;line-height:1.35;color:var(--nwp-muted);margin-top:2px}',
      '.nwp-from{text-align:right;white-space:nowrap;line-height:1.1}',
      '.nwp-from small{display:block;font-size:10px;font-weight:700;letter-spacing:.08em;color:var(--nwp-muted);margin-bottom:2px}',
      '.nwp-from b{font-size:19px;font-weight:900}',
      '.nwp-from i{font-style:normal;font-size:13px;color:var(--nwp-muted)}',
      '.nwp-req b{font-size:15px;font-weight:700}',
      '.nwp-rows{list-style:none;margin:0;padding:0 16px}',
      '.nwp-r{display:flex;align-items:center;gap:14px;padding:9px 0;border-bottom:1px solid rgba(0,0,0,.05);transition:background .15s}',
      '.nwp-r:last-child{border-bottom:0}',
      '.nwp-rn{flex:1 1 auto;min-width:0;font-size:14.5px;line-height:1.35}',
      '.nwp-rn b{font-weight:700}',
      '.nwp-rn span{color:var(--nwp-muted);font-size:13px}',
      '.nwp-rp{font-size:14.5px;font-weight:700;white-space:nowrap}',
      '.nwp-rpw{white-space:normal;text-align:right}',
      '.nwp-tp .nwp-rpw{text-align:left}',
      '.nwp-was{font-weight:400;opacity:.6;margin-right:6px}',
      '.nwp-deal{display:inline-block;font-style:normal;font-size:12px;font-weight:500;line-height:1.3;color:#D42F3A;border:1px solid #D42F3A;border-radius:8px;padding:1px 6px;margin-left:6px;white-space:nowrap}',
      // the phone: tabs
      '.nwp-tabs{display:flex;overflow-x:auto;scrollbar-width:none;background:var(--nwp-soft);border-bottom:1px solid var(--nwp-line)}',
      '.nwp-tabs::-webkit-scrollbar{display:none}',
      '.nwp-tab{flex:0 0 auto;min-height:56px;padding:8px 14px;border:0;background:transparent;color:var(--nwp-ink);text-align:left;cursor:pointer;font-family:inherit;box-shadow:inset 0 -3px 0 transparent;transition:box-shadow .2s,background .2s}',
      '.nwp-tab[aria-selected="true"]{background:#fff;box-shadow:inset 0 -3px 0 var(--nwp-red)}',
      '.nwp-tab b{display:block;font-size:14.5px;line-height:1.3}',
      '.nwp-tab span{display:block;font-size:12.5px;color:var(--nwp-muted);line-height:1.3}',
      '.nwp-tabs-fit{overflow:hidden}',
      '.nwp-tabs-fit .nwp-tab{flex:1 1 0;min-width:0;padding:8px 6px;text-align:center}',
      '.nwp-tabs-fit .nwp-tab b{font-size:13.5px}',
      '.nwp-tabs-fit .nwp-tab span{font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
      '.nwp-tabs:not(.nwp-tabs-fit){-webkit-mask-image:linear-gradient(90deg,#000 86%,transparent);mask-image:linear-gradient(90deg,#000 86%,transparent)}',
      '.nwp-tp{animation:nwp-in .25s ' + EASE + ' both}',
      '.nwp-timg{display:block;width:100%;aspect-ratio:16/10;object-fit:cover;background:#E6E9ED}',
      '.nwp-tp .nwp-rows{padding:2px 14px 6px}',
      '.nwp-tp .nwp-r{padding:10px 0}',
      '.nwp-tp .nwp-rn{display:flex;flex-direction:column}',
      // 44px: the height a thumb needs (visitor audit, 23 Nov 2026).
      '.nwp-tp .nwp-enq{min-height:44px}',
      '.nwp-tp .nwp-r{gap:12px}',
      // The phone row (Jonathan, 21 Nov 2026): the name has the row's
      // width, its price sits under it, the button to the right of both.
      '.nwp-tp .nwp-r{display:grid;grid-template-columns:minmax(0,1fr) auto;column-gap:14px;row-gap:3px;align-items:center;padding:13px 0}',
      '.nwp-tp .nwp-rn{grid-column:1;grid-row:1;line-height:1.3}',
      '.nwp-tp .nwp-rn b{font-size:15px}',
      '.nwp-tp .nwp-rp{grid-column:1;grid-row:2;font-size:15px;font-weight:400;white-space:normal}',
      '.nwp-tp .nwp-enq{grid-column:2;grid-row:1 / span 2}',
      // the pop-up
      '.nwp-sheet{position:fixed;inset:0;z-index:2147483002;display:none;align-items:center;justify-content:center;padding:24px;font-family:Roboto,sans-serif;color:var(--nwp-ink);background:rgba(20,32,50,0);-webkit-backdrop-filter:blur(0);backdrop-filter:blur(0);transition:background .2s,backdrop-filter .2s,-webkit-backdrop-filter .2s}',
      '.nwp-sheet.open{display:flex}',
      '.nwp-sheet.in{background:rgba(20,32,50,.5);-webkit-backdrop-filter:blur(3px);backdrop-filter:blur(3px)}',
      '.nwp-dlg{position:relative;background:#fff;border-radius:8px;width:100%;max-width:480px;max-height:calc(100vh - 48px);display:flex;flex-direction:column;box-shadow:0 24px 64px rgba(20,32,50,.28),0 2px 8px rgba(20,32,50,.08);overflow:hidden;opacity:0;transform:translateY(10px) scale(.98);transition:opacity .2s ' + EASE + ',transform .24s ' + EASE + '}',
      '.nwp-sheet.in .nwp-dlg{opacity:1;transform:none}',
      '.nwp-hd{display:flex;align-items:flex-start;gap:12px;padding:14px 10px 14px 16px;border-bottom:1px solid var(--nwp-line)}',
      '.nwp-hd img{width:56px;height:56px;border-radius:8px;object-fit:cover;flex:none;background:#E6E9ED}',
      '.nwp-hd-t{flex:1 1 auto;min-width:0}',
      '.nwp-hd-t small{display:block;font-size:12px;color:var(--nwp-muted);line-height:1.3}',
      '.nwp-hd-t h2{margin:1px 0 0;font-size:17px;font-weight:700;line-height:1.25;overflow-wrap:anywhere}',
      '.nwp-chipp{display:inline-block;margin-top:7px;font-size:13px;font-weight:700;padding:4px 9px;border-radius:8px;background:#FFF1F2;color:var(--nwp-red-ink);white-space:nowrap}',
      '.nwp-x{flex:none;width:38px;height:38px;border:0;border-radius:8px;background:transparent;color:var(--nwp-ink);cursor:pointer;display:flex;align-items:center;justify-content:center;transition:background .15s}',
      '.nwp-x:hover{background:var(--nwp-soft)}',
      '.nwp-bd{flex:1 1 auto;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:16px;overscroll-behavior:contain}',
      '.nwp-fl{display:flex;flex-direction:column;gap:7px}',
      '.nwp-fl > .nwp-lt{font-size:13px;font-weight:500;color:var(--nwp-ink)}',
      '.nwp-fl > .nwp-lt i{font-style:normal;font-weight:400;color:var(--nwp-muted)}',
      '.nwp-seg{display:flex;flex-wrap:wrap;gap:6px}',
      // People: five buttons of the same width (Jonathan, 4 Nov 2026).
      '.nwp-seg-people{display:grid;grid-template-columns:repeat(5,minmax(0,1fr))}.nwp-seg-people .nwp-sg{padding:0 4px;white-space:nowrap}',
      '.nwp-sg{min-height:38px;padding:0 13px;border-radius:8px;border:1.5px solid #D5DAE0;background:#fff;color:var(--nwp-ink);font-family:inherit;font-size:14px;font-weight:500;cursor:pointer;transition:border-color .15s,background .15s,color .15s}',
      '.nwp-sg:hover{border-color:#AEB6BF}',
      '.nwp-sg[aria-checked="true"]{border-color:var(--nwp-teal);background:var(--nwp-teal);color:#fff}',
      '.nwp-in{height:42px;border:1.5px solid #D5DAE0;border-radius:8px;padding:0 12px;font-family:inherit;font-size:15px;background:#fff;color:var(--nwp-ink);width:100%;transition:border-color .15s,box-shadow .15s}',
      '.nwp-in:focus{border-color:var(--nwp-teal);box-shadow:0 0 0 3px rgba(5,67,79,.12);outline:none}',
      '.nwp-in.bad{border-color:#D93025;box-shadow:0 0 0 3px rgba(217,48,37,.10)}',
      '.nwp-ck{display:flex;align-items:flex-start;gap:10px;font-size:13.5px;line-height:1.45;color:var(--nwp-ink);cursor:pointer}',
      '.nwp-ck input{flex:none;width:18px;height:18px;margin:1px 0 0;accent-color:var(--nwp-teal);cursor:pointer}',
      'textarea.nwp-in{height:auto;min-height:64px;padding:10px 12px;resize:vertical;line-height:1.45}',
      '.nwp-hint{font-size:12.5px;color:#C5221F;min-height:0}',
      '.nwp-hint:empty{display:none}',
      '.nwp-two{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}',
      '.nwp-when{display:flex;align-items:center;gap:10px;height:42px;padding:0 12px;border-radius:8px;background:#fff;cursor:pointer;border:1.5px solid #D5DAE0;font-family:inherit;font-size:15px;color:var(--nwp-ink);width:100%;text-align:left;transition:border-color .15s}',
      '.nwp-when:hover{border-color:#AEB6BF}',
      '.nwp-when[aria-expanded="true"]{border-color:var(--nwp-teal)}',
      '.nwp-when .nwp-chev{margin-left:auto;transition:transform .2s}',
      '.nwp-when[aria-expanded="true"] .nwp-chev{transform:rotate(180deg)}',
      '.nwp-cal{border:1px solid var(--nwp-line);border-radius:8px;padding:12px;display:flex;flex-direction:column;gap:10px;animation:nwp-in .2s ' + EASE + ' both;background:#fff;box-shadow:0 6px 18px rgba(20,32,50,.06)}',
      '.nwp-quick{display:flex;gap:6px;flex-wrap:wrap}',
      '.nwp-q{min-height:32px;padding:0 11px;border-radius:8px;font-family:inherit;font-weight:500;font-size:13px;cursor:pointer;background:var(--nwp-soft);color:var(--nwp-ink);border:1.5px solid var(--nwp-soft);transition:border-color .15s}',
      '.nwp-q:hover{border-color:#D5DAE0}',
      '.nwp-q.on{background:#FFF1F2;border-color:var(--nwp-red)}',
      '.nwp-mh{display:flex;align-items:center;justify-content:space-between}',
      '.nwp-mh b{font-size:14.5px}',
      '.nwp-nav{width:34px;height:34px;border:0;border-radius:8px;background:var(--nwp-soft);color:var(--nwp-ink);cursor:pointer;display:flex;align-items:center;justify-content:center}',
      '.nwp-nav:disabled{color:#B4BAC1;cursor:default}',
      '.nwp-grid{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:3px}',
      '.nwp-wd{text-align:center;font-size:11px;font-weight:700;color:var(--nwp-muted);padding-bottom:2px}',
      '.nwp-d{height:36px;border-radius:8px;font-family:inherit;font-size:14px;cursor:pointer;background:#fff;color:var(--nwp-ink);border:1px solid transparent;padding:0;transition:background .12s,border-color .12s}',
      '.nwp-d:hover:not(:disabled){background:var(--nwp-soft)}',
      '.nwp-d.today{font-weight:700;border-color:var(--nwp-teal)}',
      '.nwp-d.on{background:var(--nwp-red);color:#fff;font-weight:700;border-color:var(--nwp-red)}',
      '.nwp-d:disabled{color:#B4BAC1;cursor:default;text-decoration:line-through;background:transparent}',
      '.nwp-d.blank{visibility:hidden}',
      '.nwp-ft{padding:12px 16px calc(14px + env(safe-area-inset-bottom));border-top:1px solid var(--nwp-line);background:#fff;display:flex;flex-direction:column;gap:8px}',
      '.nwp-err{margin:0;font-size:13px;color:#C5221F}',
      '.nwp-send{position:relative;min-height:46px;border:0;border-radius:8px;font-family:inherit;font-weight:700;font-size:16px;cursor:pointer;background:var(--nwp-red);color:#fff;width:100%;transition:filter .15s,transform .1s;display:flex;align-items:center;justify-content:center;gap:10px}',
      '.nwp-send:hover{filter:brightness(.95)}',
      '.nwp-send:active{transform:scale(.99)}',
      '.nwp-send[disabled]{cursor:default;filter:none;opacity:.85}',
      '.nwp-spin{width:18px;height:18px;border-radius:50%;border:2.5px solid rgba(255,255,255,.4);border-top-color:#fff;animation:nwp-rot .7s linear infinite}',
      '@keyframes nwp-rot{to{transform:rotate(360deg)}}',
      '.nwp-trust{margin:0;font-size:12px;color:var(--nwp-muted);text-align:left;line-height:1.45}',
      '.nwp-trust a{color:var(--nwp-teal)}',
      // sent
      '.nwp-ok{padding:28px 20px 22px;display:flex;flex-direction:column;align-items:center;text-align:center;gap:10px}',
      '.nwp-ok svg circle{stroke-dasharray:151;stroke-dashoffset:151;animation:nwp-draw .5s ' + EASE + ' forwards}',
      '.nwp-ok svg path{stroke-dasharray:36;stroke-dashoffset:36;animation:nwp-draw .35s .35s ' + EASE + ' forwards}',
      '@keyframes nwp-draw{to{stroke-dashoffset:0}}',
      '.nwp-ok h3{margin:4px 0 0;font-size:19px;font-weight:700}',
      '.nwp-ok p{margin:0;font-size:14px;color:var(--nwp-muted);line-height:1.5;max-width:340px}',
      '.nwp-sum{width:100%;margin:8px 0 4px;border:1px solid var(--nwp-line);border-radius:8px;text-align:left;font-size:14px}',
      '.nwp-sum div{display:flex;gap:12px;padding:9px 12px;border-bottom:1px solid rgba(0,0,0,.05)}',
      '.nwp-sum div:last-child{border-bottom:0}',
      '.nwp-sum span{width:70px;flex:none;color:var(--nwp-muted)}',
      '.nwp-done-btn{min-height:44px;width:100%;border:0;border-radius:8px;background:var(--nwp-teal);color:#fff;font-family:inherit;font-size:15px;font-weight:700;cursor:pointer}',
      // phone: the pop-up slides up and fills the screen
      '@media (max-width: 767px){.nwp-sheet{padding:0;align-items:flex-end}.nwp-dlg{max-width:none;max-height:none;height:100%;border-radius:0;transform:translateY(100%);opacity:1;transition:transform .3s ' + EASE + '}.nwp-sheet.in .nwp-dlg{transform:none}.nwp-in,.nwp-when{height:46px;font-size:16px}.nwp-sg{min-height:42px;font-size:15px}.nwp-d{height:40px;font-size:15px}.nwp-send{min-height:50px;font-size:17px}.nwp-q{min-height:36px;font-size:14px}.nwp-nav{width:40px;height:40px}.nwp-two{grid-template-columns:1fr}.nwp-x{width:44px;height:44px}}',
      '@media (prefers-reduced-motion: reduce){.nwp,.nwp *,.nwp-sheet,.nwp-sheet *{animation:none !important;transition:none !important}}'
    ].join('\n');
    var st = document.createElement('style');
    st.id = 'nwp-css';
    st.textContent = css;
    document.head.appendChild(st);
  }

  // ------------------------------------------------------------ the page
  var ICON_CAL = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#5E6670" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5" width="18" height="16" rx="2"></rect><path d="M3 10h18M8 3v4M16 3v4"></path></svg>';
  var ICON_CHEV = '<svg class="nwp-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#5E6670" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9l6 6 6-6"></path></svg>';
  var ICON_L = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>';
  var ICON_R = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 18l6-6-6-6"></path></svg>';
  var ICON_X = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"></path></svg>';
  var ICON_OK = '<svg width="60" height="60" viewBox="0 0 52 52" fill="none" aria-hidden="true"><circle cx="26" cy="26" r="24" stroke="#1E7A43" stroke-width="2.5"></circle><path d="M15 27l7 7 15-16" stroke="#1E7A43" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"></path></svg>';

  var PEOPLE = ['Just me', '2', '3 to 5', '6 to 10', 'More than 10'];
  var PEOPLE_LABEL = { 'Just me': 'Just me', '2': '2', '3 to 5': '3-5', '6 to 10': '6-10', 'More than 10': '10+' };
  var LENGTHS = ['1 hour', '2 hours', '3 hours', 'Half a day', 'All day'];

  function photos() {
    if (AREA) return AREA_PIC ? [AREA_PIC] : [];
    var out = [];
    document.querySelectorAll('.gallery__image').forEach(function (img) {
      var src = img.currentSrc || img.src;
      if (src && out.indexOf(src) < 0) out.push(src);
    });
    return out;
  }
  function photoFor(gi) {
    var pics = photos();
    return pics.length ? pics[AREA ? 0 : (gi + 1) % pics.length] : '';
  }
  function groupOf(id) {
    for (var i = 0; i < data.groups.length; i++) {
      for (var j = 0; j < data.groups[i].items.length; j++) {
        if (data.groups[i].items[j].id === id) return i;
      }
    }
    return 0;
  }

  function enqBtn(it) {
    return '<button type="button" class="nwp-enq" data-a="enq" data-v="' + esc(it.id) + '" data-k="e-' + esc(it.id) + '" aria-label="Request ' + esc(it.full) + '">Request</button>';
  }

  // The computer: every group, every price, a Request on each.
  function listHtml() {
    var h = '<div class="nwp-box">';
    data.groups.forEach(function (g, gi) {
      var pic = photoFor(gi);
      h += '<section class="nwp-grp" aria-label="' + esc(g.title) + '"><div class="nwp-gh">' +
        (pic ? '<img class="nwp-gimg" src="' + esc(pic) + '" alt="" loading="lazy">' : '') +
        '<div class="nwp-gt"><b>' + esc(g.title) + '</b><span>' + esc(g.spec) + '</span></div>' +
        (g.price ? '<div class="nwp-from">' + (g.fromWord ? '<small>FROM</small>' : '') + '<b>' + esc(g.price) + '</b><i>' + esc(g.per) + '</i></div>' : '<div class="nwp-from nwp-req"><b>Price on request</b></div>') + '</div>' +
        '<ul class="nwp-rows">';
      g.items.forEach(function (it) {
        h += '<li class="nwp-r"><span class="nwp-rn"><b>' + esc(it.name) + '</b>' + (it.note ? ' <span>· ' + esc(it.note) + '</span>' : '') + '</span>' +
          '<span class="nwp-rp' + (it.was ? ' nwp-rpw' : '') + '">' + priceHtml(it) + '</span>' + enqBtn(it) + '</li>';
      });
      h += '</ul></section>';
    });
    return h + '</div>';
  }

  // The phone: one group at a time.
  function tabsHtml() {
    var gi = Math.min(S.tab, data.groups.length - 1);
    var g = data.groups[gi];
    var h = '<div class="nwp-box">';
    if (data.groups.length > 1) {
      // Three or fewer share the width; more than that scroll sideways.
      var fit = data.groups.length <= 3;
      h += '<div class="nwp-tabs' + (fit ? ' nwp-tabs-fit' : '') + '" role="tablist" aria-label="Kinds of space">';
      data.groups.forEach(function (x, i) {
        var on = i === gi;
        h += '<button type="button" class="nwp-tab" role="tab" id="nwp-tab-' + i + '" aria-controls="nwp-tp" aria-selected="' + on + '" tabindex="' + (on ? 0 : -1) + '" data-a="tab" data-v="' + i + '" data-k="t' + i + '">' +
          '<b>' + esc(fit && x.key === 'private_office' ? 'Offices' : x.title) + '</b><span>' + (x.price ? (x.fromWord ? 'from ' : '') + esc(x.price) + esc(x.per.replace('/month', '/mo').replace('/hour', '/hr')) : 'Price on request') + '</span></button>';
      });
      h += '</div>';
    }
    var pic = photoFor(gi);
    h += '<div class="nwp-tp" id="nwp-tp" role="tabpanel" aria-labelledby="nwp-tab-' + gi + '" data-gi="' + gi + '">' +
      (pic ? '<img class="nwp-timg" src="' + esc(pic) + '" alt="">' : '') + '<ul class="nwp-rows">';
    g.items.forEach(function (it) {
      h += '<li class="nwp-r"><span class="nwp-rn"><b>' + esc(it.name) + '</b>' + (it.note ? '<span>' + esc(it.note) + '</span>' : '') + '</span>' +
        '<span class="nwp-rp' + (it.was ? ' nwp-rpw' : '') + '">' + priceHtml(it) + '</span>' + enqBtn(it) + '</li>';
    });
    return h + '</ul></div></div>';
  }

  function calendarHtml(kind) {
    var t = today0();
    var first = new Date(t.getFullYear(), t.getMonth() + S.monthOffset, 1);
    var title = first.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
    var lead = (first.getDay() + 6) % 7;
    var inMonth = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
    var cells = Math.ceil((lead + inMonth) / 7) * 7;
    // Just the calendar: people are used to picking a date (Jonathan, 3 Nov 2026).
    var h = '<div class="nwp-cal">';
    h += '<div class="nwp-mh"><button type="button" class="nwp-nav" data-a="prev" data-k="prev" aria-label="Previous month"' + (S.monthOffset <= 0 ? ' disabled' : '') + '>' + ICON_L + '</button>' +
      '<b aria-live="polite">' + esc(title) + '</b>' +
      '<button type="button" class="nwp-nav" data-a="next" data-k="next" aria-label="Next month"' + (S.monthOffset >= 11 ? ' disabled' : '') + '>' + ICON_R + '</button></div>' +
      '<div class="nwp-grid" role="group" aria-label="' + esc(title) + '">';
    ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'].forEach(function (w) { h += '<span class="nwp-wd" aria-hidden="true">' + w + '</span>'; });
    for (var i = 0; i < cells; i++) {
      var n = i - lead + 1;
      if (n < 1 || n > inMonth) { h += '<span class="nwp-d blank" aria-hidden="true"></span>'; continue; }
      var d = new Date(first.getFullYear(), first.getMonth(), n);
      var isT = sameDay(d, t), on = !S.flexible && sameDay(d, S.date);
      var past = d < t || (kind === 'hour' && isT && firstHourOn(d) > HOUR_LAST);
      h += '<button type="button" class="nwp-d' + (isT ? ' today' : '') + (on ? ' on' : '') + '" data-a="day" data-v="' + d.getTime() + '" data-k="d' + d.getTime() + '"' +
        (past ? ' disabled' : '') + ' aria-pressed="' + on + '" aria-label="' + esc(fmtDate(d, true) + (isT ? ', today' : '')) + '">' + n + '</button>';
    }
    return h + '</div></div>';
  }

  function segHtml(field, options, labels, value, name) {
    var h = '<div class="nwp-seg nwp-seg-' + field + '" role="radiogroup" aria-label="' + esc(name) + '">';
    options.forEach(function (o, i) {
      var on = value === o;
      var tab = on || (i === 0 && options.indexOf(value) < 0);
      h += '<button type="button" class="nwp-sg" role="radio" aria-checked="' + on + '" tabindex="' + (tab ? 0 : -1) + '" data-a="seg" data-f="' + field + '" data-v="' + esc(o) + '" data-k="' + field + i + '">' + esc(labels ? labels[o] : o) + '</button>';
    });
    return h + '</div>';
  }

  // The pop-up's inside: the price, the form, Send; or "Sent".
  function modalHtml() {
    var it = pickedItem();
    if (!it) return '';
    var gi = groupOf(it.id);
    var pic = photoFor(gi);
    var head = '<div class="nwp-hd">' + (pic ? '<img src="' + esc(pic) + '" alt="">' : '') +
      '<div class="nwp-hd-t"><small>Send a request to ' + esc(data.space) + '</small><h2 id="nwp-dlg-h">' + esc(it.full) + '</h2>' +
      '<span class="nwp-chipp">' + esc(it.priceText) + (it.was ? ' · Nomadwise discount' : '') + '</span></div>' +
      '<button type="button" class="nwp-x" data-a="close" data-k="x" aria-label="Close">' + ICON_X + '</button></div>';
    if (S.sent) {
      var rows = [['What', it.full + ' (' + it.askText + ')'], ['People', S.people], ['When', S.sentWhen]];
      if (S.sentTime) rows.push(['Time', S.sentTime]);
      var sum = '<div class="nwp-sum">' + rows.map(function (r) { return '<div><span>' + esc(r[0]) + '</span><b>' + esc(r[1]) + '</b></div>'; }).join('') + '</div>';
      return head + '<div class="nwp-bd"><div class="nwp-ok" role="status">' + ICON_OK +
        '<h3>Request sent</h3><p>' + esc(data.space) + ' will reply to you by email at <b>' + esc(S.email) + '</b>.</p>' + sum +
        '<button type="button" class="nwp-done-btn" data-a="close" data-k="done">Done</button></div></div>';
    }
    var kind = kindOf(it);
    keepAhead(kind);
    var whenLabel = kind === 'start' ? 'When would you like to start?' : 'Which day?';
    var whenText = S.flexible ? "I'm flexible on dates" : (S.date ? fmtDate(S.date, true) : 'Pick a date');
    var h = head + '<div class="nwp-bd">';
    h += '<div class="nwp-fl"><span class="nwp-lt" id="nwp-ppl">How many people?</span>' + segHtml('people', PEOPLE, PEOPLE_LABEL, S.people, 'How many people') + '</div>';
    h += '<div class="nwp-fl"><span class="nwp-lt" id="nwp-when-l">' + whenLabel + '</span>' +
      '<button type="button" class="nwp-when" data-a="cal" data-k="cal" aria-labelledby="nwp-when-l" aria-expanded="' + S.calOpen + '">' + ICON_CAL +
      '<span>' + esc(whenText) + '</span>' + ICON_CHEV + '</button>' + (S.calOpen ? calendarHtml(kind) : '') + '</div>';
    if (kind === 'hour') {
      h += '<div class="nwp-fl"><label class="nwp-lt" for="nwp-time">Starting at</label><select class="nwp-in" id="nwp-time" data-f="time" data-k="time">';
      var hr0 = S.flexible ? HOUR_FIRST : firstHourOn(S.date);
      for (var hr = hr0; hr <= HOUR_LAST; hr++) {
        var tt = hourText(hr);
        h += '<option' + (S.time === tt ? ' selected' : '') + '>' + tt + '</option>';
      }
      h += '</select>' + (hr0 > HOUR_FIRST ? '<span style="font-size:12.5px;color:#5D5D5D">Earlier times today have already passed.</span>' : '') +
        '</div><div class="nwp-fl"><span class="nwp-lt">For how long?</span>' + segHtml('length', LENGTHS, null, S.length, 'For how long') + '</div>';
    }
    h += '' +
      '<div class="nwp-fl"><label class="nwp-lt" for="nwp-name">Your name</label><input class="nwp-in' + (S.bad === 'name' ? ' bad' : '') + '" id="nwp-name" type="text" autocomplete="name" maxlength="120" data-f="name" data-k="name" value="' + esc(S.name) + '"' + (S.bad === 'name' ? ' aria-invalid="true"' : '') + '></div>' +
      '<div class="nwp-fl"><label class="nwp-lt" for="nwp-email">Your email</label><input class="nwp-in' + (S.bad === 'email' ? ' bad' : '') + '" id="nwp-email" type="email" inputmode="email" autocomplete="email" maxlength="200" data-f="email" data-k="email" value="' + esc(S.email) + '" aria-describedby="nwp-email-hint"' + (S.bad === 'email' ? ' aria-invalid="true"' : '') + '>' +
      '<span class="nwp-hint" id="nwp-email-hint">' + (S.bad === 'email' ? esc(S.error) : '') + '</span></div>';
    h += '<div class="nwp-fl"><label class="nwp-lt" for="nwp-msg">Anything to add? <i>(optional)</i></label>' +
      '<textarea class="nwp-in" id="nwp-msg" rows="2" maxlength="1500" data-f="message" data-k="message">' + esc(S.message) + '</textarea></div>';
    // Newsletter for nomads (Jonathan, 6 Nov 2026): never ticked for them.
    h += '<label class="nwp-ck"><input type="checkbox" data-f="news" data-k="news"' + (S.news ? ' checked' : '') + '>' +
      '<span>Send me the Nomadwise newsletter now and then. Unsubscribe any time.</span></label>';
    h += '</div><div class="nwp-ft">' +
      (S.error && S.bad !== 'email' ? '<p class="nwp-err" role="alert">' + esc(S.error) + '</p>' : '') +
      '<button type="button" class="nwp-send" data-a="send" data-k="send"' + (S.sending ? ' disabled aria-busy="true"' : '') + '>' +
      (S.sending ? '<span class="nwp-spin" aria-hidden="true"></span>Sending' : 'Send request') + '</button>' +
      '<p class="nwp-trust">Free, with no obligation. ' + esc(data.space) + ' replies by email. By sending you agree to our <a href="/legal-information" target="_blank" rel="noopener">terms</a>.</p></div>';
    return h;
  }

  function render() {
    if (!root || !data) return;
    var active = document.activeElement;
    var key = S.focusKey || (active && active.getAttribute && active.getAttribute('data-k'));
    var phone = root.clientWidth < 560;
    S.phone = phone;
    root.innerHTML =
      '<h2 class="nwp-h">Passes and prices at ' + esc(data.space) + '</h2>' +
      '<p class="nwp-sub">' + (data.vat ? 'All prices ' + esc(data.vat.replace(/^prices?\s+/i, '')) + ', set by ' + esc(data.space) : 'Prices set by ' + esc(data.space)) +
      (data.checked ? ', ' + esc(data.checked) : '') + '. ' +
      'Sending a request is free and there\'s no obligation.' +
      // A Premium page links to the space's own website; a free page
      // does not, so the Request button stays the way to ask.
      (data.site ? ' <a class="nwp-site" href="' + esc(data.site) + '" target="_blank" rel="noopener">Visit website</a>' : '') + '</p>' +
      (phone ? tabsHtml() : listHtml());
    if (sheet) sheet.querySelector('.nwp-dlg').innerHTML = S.sheetOpen ? modalHtml() : '';
    if (key) {
      var scope = S.sheetOpen && sheet ? sheet : root;
      var el = scope.querySelector('[data-k="' + key + '"]');
      if (el && el.focus) { try { el.focus({ preventScroll: true }); } catch (e) { el.focus(); } }
    }
    S.focusKey = null;
  }

  // ------------------------------------------------------- the pop-up
  var REDUCED = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  function openSheet(id, fromKey) {
    S.picked = id; S.sent = false; S.error = ''; S.bad = null; S.calOpen = false; S.returnKey = fromKey;
    var it = pickedItem();
    if (!it) return;
    var k = kindOf(it);
    if (S.kindFor !== k) {
      S.date = openDay(k === 'start' ? nextMonday() : addDays(today0(), 1));
      S.flexible = false; S.kindFor = k;
      // A meeting room starts with no number picked, so the space is
      // never told "just me" for a boardroom by mistake.
      if (k === 'hour') S.people = '';
      else if (!S.people) S.people = 'Just me';
      var t = today0();
      S.monthOffset = (S.date.getFullYear() - t.getFullYear()) * 12 + S.date.getMonth() - t.getMonth();
    }
    S.sheetOpen = true;
    S.focusKey = 'people' + Math.max(0, PEOPLE.indexOf(S.people));
    document.documentElement.style.overflow = 'hidden';
    sheet.classList.add('open');
    render();
    // next frame: fade and rise in
    requestAnimationFrame(function () { requestAnimationFrame(function () { sheet.classList.add('in'); }); });
    track('price_enquiry_opened', { space: data.space, price: it.full, slug: SLUG });
    // Counted once per visit and page: the early sign that prices are
    // being acted on (Prices overview).
    hit('request');
  }
  function closeSheet() {
    if (!S.sheetOpen) return;
    S.sheetOpen = false;
    sheet.classList.remove('in');
    document.documentElement.style.overflow = '';
    var back = S.returnKey;
    var finish = function () {
      sheet.classList.remove('open');
      if (S.sent) { S.sent = false; S.message = ''; }
      sheet.querySelector('.nwp-dlg').innerHTML = '';
      var bt = AREA ? AREA_BTN : (back && root.querySelector('[data-k="' + back + '"]'));
      if (bt) { try { bt.focus({ preventScroll: true }); } catch (e) { bt.focus(); } }
    };
    if (REDUCED) finish(); else setTimeout(finish, S.phone ? 300 : 200);
  }

  // ------------------------------------------------------------- events
  function onClick(e) {
    var b = e.target.closest && e.target.closest('[data-a]');
    if (!b) return;
    var a = b.getAttribute('data-a'), v = b.getAttribute('data-v');
    S.focusKey = b.getAttribute('data-k');
    if (a === 'enq') { openSheet(v, b.getAttribute('data-k')); return; }
    if (a === 'close') { closeSheet(); return; }
    if (a === 'send') { send(); return; }
    if (a === 'tab') { S.tab = +v; }
    else if (a === 'seg') {
      S[b.getAttribute('data-f')] = v;
      if (S.bad === 'people' && b.getAttribute('data-f') === 'people') { S.bad = null; S.error = ''; }
    }
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
    render();
  }
  function onChange(e) {
    var f = e.target.getAttribute && e.target.getAttribute('data-f');
    if (f && e.target.tagName !== 'BUTTON') S[f] = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
  }
  function onInput(e) {
    var t = e.target, f = t.getAttribute && t.getAttribute('data-f');
    if (!f || t.tagName === 'BUTTON') return;
    if (t.type === 'checkbox') { S[f] = t.checked; return; }
    S[f] = t.value;
    // Fixing a flagged field clears the flag as you type.
    if (S.bad === f && (f !== 'email' || EMAIL_OK(t.value))) {
      S.bad = null; S.error = '';
      t.classList.remove('bad'); t.removeAttribute('aria-invalid');
      var hint = sheet.querySelector('#nwp-email-hint'); if (hint && f === 'email') hint.textContent = '';
    }
  }
  function EMAIL_OK(v) { return /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(String(v || '').trim()); }
  // Leaving the email box with a typo: say so there and then.
  function onFocusOut(e) {
    var t = e.target;
    if (!t.getAttribute || t.getAttribute('data-f') !== 'email') return;
    var v = t.value.trim();
    if (v && !EMAIL_OK(v)) {
      S.bad = 'email'; S.error = "That email doesn't look quite right.";
      t.classList.add('bad'); t.setAttribute('aria-invalid', 'true');
      var hint = sheet.querySelector('#nwp-email-hint'); if (hint) hint.textContent = S.error;
    }
  }
  // Arrow keys move along the tabs and the one-tap choices.
  function onKey(e) {
    var t = e.target;
    if (!t.getAttribute) return;
    var role = t.getAttribute('role');
    if ((role !== 'tab' && role !== 'radio') || ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].indexOf(e.key) < 0) return;
    var group = t.parentElement ? [].slice.call(t.parentElement.querySelectorAll('[role="' + role + '"]')) : [];
    var i = group.indexOf(t);
    if (i < 0) return;
    e.preventDefault();
    var n = e.key === 'Home' ? 0 : e.key === 'End' ? group.length - 1
      : (i + (e.key === 'ArrowLeft' || e.key === 'ArrowUp' ? -1 : 1) + group.length) % group.length;
    group[n].click();
  }

  // ------------------------------------------------------------ sending
  function send() {
    var it = pickedItem();
    if (!it || S.sending) return;
    S.name = S.name.trim(); S.email = S.email.trim();
    if (!S.people) { S.error = 'Please choose how many people.'; S.bad = 'people'; S.focusKey = 'people0'; render(); return; }
    if (!S.name) { S.error = 'Please add your name.'; S.bad = 'name'; S.focusKey = 'name'; render(); return; }
    if (!EMAIL_OK(S.email)) { S.error = "That email doesn't look quite right."; S.bad = 'email'; S.focusKey = 'email'; render(); return; }
    S.bad = null;
    if (keepAhead(kindOf(it))) {
      S.error = 'That time has already passed, so we moved it on. Please check the day and time, then send again.';
      S.focusKey = 'time'; render(); return;
    }
    if (AREA && !frameForm()) {
      // The space's page is still loading out of sight: wait for it.
      if (!S.waitFrame) S.waitFrame = Date.now();
      if (Date.now() - S.waitFrame < 20000) {
        if (!S.frameWaitShown) { S.frameWaitShown = true; S.error = ''; render(); }
        setTimeout(send, 300);
        return;
      }
      S.waitFrame = 0; S.frameWaitShown = false;
      S.error = 'Sorry, this could not be sent from here. Please try again, or email spaces@nomadwise.io.';
      render();
      return;
    }
    S.waitFrame = 0; S.frameWaitShown = false;
    var form = AREA ? frameForm() : document.getElementById('wf-form-Research-Form');
    var W = (form && form.ownerDocument && form.ownerDocument.defaultView) || window;
    var box = form && form.closest('.w-form');
    if (!form) { S.error = 'Sorry, this could not be sent from here. Please email spaces@nomadwise.io.'; render(); return; }
    var kind = kindOf(it);
    var when = S.flexible ? 'Flexible on dates' : (S.date ? fmtDate(S.date, true) : 'Not given');
    var lines = [
      'Asking about: ' + it.full + ' (' + it.askText + ')',
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
      el.dispatchEvent(new W.Event('input', { bubbles: true }));
      el.dispatchEvent(new W.Event('change', { bubbles: true }));
    }
    set('Text-area', lines.join('\n'));
    set('Name-Of-Customer-2', S.name);
    set('email-of-customer-2', S.email);
    set('ticked-terms-2', true);
    set('Agree-to-Receive-Marketing-2', S.news);
    // The form's own checks (its email field is stricter than ours).
    if (form.checkValidity && !form.checkValidity()) {
      var bad = form.querySelector(':invalid');
      var nm = bad && bad.getAttribute('name');
      S.error = nm === 'email-of-customer-2' ? 'Please check your email address.'
        : (nm === 'Name-Of-Customer-2' ? 'Please check your name.' : 'Sorry, this could not be sent. Please email spaces@nomadwise.io.');
      S.focusKey = nm === 'email-of-customer-2' ? 'email' : (nm === 'Name-Of-Customer-2' ? 'name' : null);
      S.bad = S.focusKey;
      render();
      return;
    }
    var done = box && box.querySelector('.w-form-done');
    var fail = box && box.querySelector('.w-form-fail');
    // A thank-you still showing from the site's own pop-up is not ours.
    try { if (done) done.style.display = 'none'; if (fail) fail.style.display = 'none'; form.style.display = ''; } catch (e) {}
    S.sending = true; S.error = ''; S.focusKey = null; render();
    var started = Date.now(), gaveUp = false;
    function shown(el) { return el && W.getComputedStyle(el).display !== 'none'; }
    try {
      // Webflow's own handler sends it (its AJAX post); never a plain
      // browser submit, which would put the details in the address.
      var btn = form.querySelector('[type="submit"]');
      if (form.requestSubmit) form.requestSubmit(btn || undefined);
      else if (W.jQuery) W.jQuery(form).trigger('submit');
      else if (btn) btn.click();
    } catch (e) {
      S.sending = false; S.error = 'Sorry, that did not send. Please try again.'; render(); return;
    }
    (function wait() {
      if (shown(done)) {
        S.sending = false; S.sent = true; S.error = ''; S.focusKey = 'done';
        S.sentWhen = S.flexible ? 'Flexible on dates' : (S.date ? (kind === 'start' ? 'Starting ' : '') + fmtDate(S.date, true) : 'Not given');
        S.sentTime = kind === 'hour' ? 'From ' + S.time + ', ' + S.length : '';
        track('price_enquiry_sent', { space: data.space, price: it.full, slug: SLUG, newsletter: !!S.news, from: AREA ? location.pathname : 'listing' });
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
    if (root) { render(); return true; }
    var desc = document.querySelector('.left-column .modal-more-div') ||
      document.querySelector('.modal-more-div');
    var host = desc && desc.parentElement;
    if (!host && !AREA) return false;
    addStyles();
    root = document.createElement('section');
    root.className = 'nwp';
    root.id = 'prices';
    root.setAttribute('aria-label', 'Passes and prices');
    if (AREA) { root.hidden = true; document.body.appendChild(root); }
    else host.insertBefore(root, desc.nextSibling);
    sheet = document.createElement('div');
    sheet.className = 'nwp-sheet';
    sheet.innerHTML = '<div class="nwp-dlg" role="dialog" aria-modal="true" aria-labelledby="nwp-dlg-h"></div>';
    document.body.appendChild(sheet);
    // A click on the dimmed page around the pop-up closes it.
    sheet.addEventListener('mousedown', function (e) { if (e.target === sheet) closeSheet(); });
    [root, sheet].forEach(function (el) {
      el.addEventListener('click', onClick);
      el.addEventListener('change', onChange);
      el.addEventListener('input', onInput);
      el.addEventListener('keydown', onKey);
    });
    sheet.addEventListener('focusout', onFocusOut);
    document.addEventListener('keydown', function (e) {
      if (!S.sheetOpen) return;
      if (e.key === 'Escape') { closeSheet(); return; }
      // Tab stays inside the pop-up while it is open
      if (e.key === 'Tab') {
        var f = [].slice.call(sheet.querySelectorAll('button:not([disabled]):not([tabindex="-1"]),select,input,textarea,a[href]'));
        if (!f.length) return;
        var first = f[0], last = f[f.length - 1];
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
        else if (!sheet.contains(document.activeElement)) { e.preventDefault(); first.focus(); }
      }
    });
    render();
    // Tabs on a phone, the list on a computer: switch when the column crosses over.
    var rt = null;
    window.addEventListener('resize', function () {
      clearTimeout(rt);
      rt = setTimeout(function () { if ((root.clientWidth < 560) !== S.phone) render(); }, 150);
    });
    return true;
  }

  // Any enquiry sent from this page (the price list or the site's own
  // Send an enquiry pop-up): ask for it to be filed now, so the person
  // gets their confirmation email within minutes (migration 244).
  function nudge() {
    try {
      fetch(URL_ + '/rest/v1/rpc/enquiry_nudge', {
        method: 'POST', keepalive: true,
        headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
        body: '{}'
      }).catch(function () {});
    } catch (e) {}
  }
  document.addEventListener('submit', function (ev) {
    var f = ev.target;
    if (!f || f.id !== 'wf-form-Research-Form') return;
    var box = f.parentElement, done = box && box.querySelector('.w-form-done'), t0 = Date.now();
    (function look() {
      if (done && getComputedStyle(done).display !== 'none') { setTimeout(nudge, 1500); return; }
      if (Date.now() - t0 < 60000) setTimeout(look, 500);
    })();
  }, true);

  // ------------------------------------------- temporarily closed
  // The owner marked the space temporarily closed in their Owner
  // account (CR-36, migration 250): a notice under the page title until
  // the day it opens again. Every listing page, price list or not.
  var DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  var MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'];
  function longDay(iso) {
    var p = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || ''));
    if (!p) return '';
    var d = new Date(Date.UTC(+p[1], +p[2] - 1, +p[3]));
    return DAYS[d.getUTCDay()] + ' ' + d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()] + ' ' + d.getUTCFullYear();
  }
  function showClosed(c) {
    var day = longDay(c && c.reopens_on);
    if (!day || document.querySelector('.nwp-closed')) return;
    var h1 = document.querySelector('h1');
    var box = h1 && h1.parentElement && h1.parentElement.parentElement;
    if (!box) return;
    var el = document.createElement('div');
    el.className = 'nwp-closed';
    el.setAttribute('role', 'status');
    el.setAttribute('style', 'display:flex;align-items:flex-start;gap:10px;margin:14px 0 4px;padding:12px 14px;' +
      'border-radius:8px;background:#FFF6E5;border:1px solid #F3D28B;color:#4A3200;' +
      'font-family:inherit;font-size:15px;line-height:1.45;max-width:640px;box-sizing:border-box');
    el.innerHTML =
      '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#B26B00" stroke-width="2" ' +
      'stroke-linecap="round" aria-hidden="true" style="flex:none;margin-top:1px">' +
      '<circle cx="12" cy="12" r="9"></circle><path d="M12 7v5l3 2"></path></svg>' +
      '<div><strong style="display:block;font-weight:700;color:#3A2700">Temporarily closed</strong>' +
      esc((c.space || 'This space') + ' opens again on ' + day + '.') + '</div>';
    box.appendChild(el);
  }

  // ------------------------------------------------ our own page counts
  // Views of this listing page and taps on its Directions link, for the
  // owner's Performance tab and monthly email (migration 251). Once per
  // visitor session per page, no cookies (sessionStorage only).
  function hit(kind) {
    // A team device (nomadwise.io/?team) is not a visitor: its views
    // and taps are left out of the counts (Jonathan, 22 Nov 2026).
    try { if (localStorage.getItem('nw_team')) return; } catch (e) {}
    var key = 'nw_' + kind + '_' + SLUG;
    try { if (sessionStorage.getItem(key)) return; sessionStorage.setItem(key, '1'); } catch (e) {}
    try {
      fetch(URL_ + '/rest/v1/rpc/page_hit', {
        method: 'POST', keepalive: true,
        headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_slug: SLUG, p_kind: kind })
      }).catch(function () {});
    } catch (e) {}
  }
  var MAPS = /(google\.[a-z.]+\/maps|maps\.google\.|maps\.app\.goo\.gl|goo\.gl\/maps|maps\.apple\.com)/i;
  document.addEventListener('click', function (ev) {
    var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;
    if (a && MAPS.test(a.getAttribute('href') || '')) hit('directions');
  }, true);

  // A Request button on an area page ("Meeting rooms in Shoreditch",
  // /workspace/<slug>) links here as /coworking/<slug>?request=<price id>:
  // the request pop-up opens with that price already chosen (Jonathan,
  // 22 Nov 2026). An id that is not on this page opens nothing.
  function fromLink() {
    var id = '';
    try { id = new URLSearchParams(location.search).get('request') || ''; } catch (e) { return; }
    if (!/^[0-9a-f-]{36}$/i.test(id)) return;
    S.picked = id;
    if (!pickedItem()) { S.picked = null; return; }
    S.picked = null;
    try { root.scrollIntoView({ block: 'start' }); } catch (e) {}
    openSheet(id);
    track('area_page_request_opened', { slug: SLUG, from: document.referrer || '' });
  }

  // ---------------------------------------------------- area pages
  // The space's own page, loaded out of sight, so a request sent from
  // the area page goes through that page's form exactly as one sent on
  // the page itself (same form, same listing name, same import).
  var frame = null, frameSlug = '', cache = {};
  function areaFrame(slug) {
    if (frame && frameSlug === slug) return;
    if (frame) { try { frame.remove(); } catch (e) {} }
    frameSlug = slug;
    frame = document.createElement('iframe');
    frame.setAttribute('aria-hidden', 'true');
    frame.tabIndex = -1;
    frame.title = '';
    frame.style.cssText = 'position:absolute;left:-10000px;top:0;width:400px;height:600px;border:0;opacity:0;pointer-events:none';
    frame.src = '/coworking/' + slug;
    document.body.appendChild(frame);
  }
  function frameForm() {
    try {
      var d = frame && frame.contentDocument;
      if (!d || d.readyState !== 'complete') return null;
      var w = frame.contentWindow;
      if (!w.Webflow && !w.jQuery) return null;
      return d.getElementById('wf-form-Research-Form');
    } catch (e) { return null; }
  }
  function areaOpen(slug, id, btn, href) {
    AREA_BTN = btn;
    var card = btn.closest && btn.closest('.aw-card');
    var img = card && card.querySelector('img');
    AREA_PIC = img ? (img.currentSrc || img.src) : '';
    areaFrame(slug);
    var got = cache[slug] ? Promise.resolve(cache[slug]) : fetch(URL_ + '/rest/v1/rpc/page_prices', {
      method: 'POST',
      headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_slug: slug })
    }).then(function (r) { return r.ok ? r.json() : null; });
    got.then(function (raw) {
      if (!raw || !raw.prices) throw new Error('no prices');
      cache[slug] = raw;
      SLUG = slug;
      SHUT = Array.isArray(raw.closed_days) ? raw.closed_days.map(Number) : [];
      data = shape(raw);
      S.picked = id;
      if (!pickedItem() || !mount()) throw new Error('no price');
      S.sent = false;
      openSheet(id);
    }).catch(function () { location.href = href; });
  }
  if (AREA) {
    document.addEventListener('click', function (ev) {
      var a = ev.target && ev.target.closest ? ev.target.closest('a.aw-req') : null;
      if (!a || ev.metaKey || ev.ctrlKey || ev.shiftKey) return;
      var u;
      try { u = new URL(a.href, location.href); } catch (e) { return; }
      var mm = /^\/coworking\/([a-z0-9-]+)\/?$/i.exec(u.pathname);
      var id = u.searchParams.get('request') || '';
      if (!mm || !/^[0-9a-f-]{36}$/i.test(id)) return;
      ev.preventDefault();
      areaOpen(mm[1].toLowerCase(), id, a, a.href);
    }, true);
  }

  // "Google rating" beside the stars, so a visitor knows whose rating
  // it is (visitor audit, 23 Nov 2026). Plain words, no link.
  function ratingLabel() {
    try {
      var w = document.querySelectorAll('.google-rating-wrapper');
      for (var i = 0; i < w.length; i++) {
        if (w[i].querySelector('.nwp-gr') || !/\d/.test(w[i].textContent || '')) continue;
        var sp = document.createElement('span');
        sp.className = 'nwp-gr';
        sp.textContent = 'Google rating';
        sp.style.cssText = 'font-size:13px;font-weight:400;color:#5E6670;margin-left:4px;white-space:nowrap';
        w[i].appendChild(sp);
      }
    } catch (e) {}
  }

  // On a phone the price list sits two to four screens down, below the
  // hours, map, tags and description (visitor audit, 23 Nov 2026). A
  // link under the top "Send a request" button says the prices are
  // there and jumps to them. Phones only (see .nwp-jump).
  function jumpLink() {
    try {
      if (!data || !data.groups.length || document.querySelector('.nwp-jump')) return;
      var bw = document.querySelector('.left-column .buttons-wrapper');
      if (!bw || !bw.parentElement) return;
      var g = data.groups[0];
      var from = g.price
        ? ', from ' + g.price + g.per.replace('/month', '/mo').replace('/hour', '/hr') : '';
      var a = document.createElement('a');
      a.className = 'nwp-jump';
      a.href = '#prices';
      a.textContent = 'See passes and prices' + from;
      a.addEventListener('click', function () { track('prices_jump_link', { slug: SLUG }); });
      bw.parentElement.insertBefore(a, bw.nextSibling);
    } catch (e) {}
  }

  // On a phone the full week of opening hours sits above the prices
  // and takes a third of a screen (benchmark, 23 Nov 2026). It becomes
  // one line, "Open Mon to Fri, 8:30 AM - 6:00 PM", and the week folds
  // out on a tap. The line is built only from the hours on the page and
  // never says "open now": the visitor may be in another time zone.
  function hoursLine(rows) {
    var D = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    var say = function (v) { return /24\s*hours/i.test(v) ? '24 hours' : v; };
    var open = [], vals = [];
    rows.forEach(function (r, k) {
      if (/^closed$/i.test(r)) return;
      open.push(k);
      if (vals.indexOf(r) < 0) vals.push(r);
    });
    if (!open.length) return '';
    var first = open[0], last = open[open.length - 1];
    var run = last - first + 1 === open.length;
    // Which days: every day, one unbroken run, or a count.
    var days = open.length === 7 ? 'every day'
      : run ? (last > first ? D[first] + ' to ' + D[last] : D[first])
      : open.length + ' days a week';
    // One set of hours is said; several are left to the full week.
    return 'Open ' + days + ', ' + (vals.length === 1 ? say(vals[0]) : 'hours vary');
  }
  function foldHours() {
    try {
      var grid = document.querySelector('.left-column .div-block-77 .wifi-openinghours-quickstack');
      if (!grid || document.querySelector('.nwp-hrs')) return;
      var cells = grid.querySelectorAll('.w-layout-cell');
      if (cells.length !== 14) return;
      var names = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
      var rows = [];
      for (var i = 0; i < 7; i++) {
        var day = (cells[i * 2].textContent || '').trim().toLowerCase();
        var val = (cells[i * 2 + 1].textContent || '').replace(/\s+/g, ' ').trim();
        if (day !== names[i] || !val) return;
        rows.push(val);
      }
      var line = hoursLine(rows);
      if (!line) return;
      if (!grid.id) grid.id = 'nwp-week';
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'nwp-hrs';
      b.setAttribute('aria-expanded', 'false');
      b.setAttribute('aria-controls', grid.id);
      b.innerHTML = '<b>' + esc(line) + '</b><span>See all hours</span>';
      grid.classList.add('nwp-week', 'nwp-shut');
      b.addEventListener('click', function () {
        var open = grid.classList.toggle('nwp-shut') === false;
        b.setAttribute('aria-expanded', open ? 'true' : 'false');
        b.lastChild.textContent = open ? 'Hide hours' : 'See all hours';
        if (open) track('hours_opened', { slug: SLUG });
      });
      grid.parentElement.insertBefore(b, grid);
    } catch (e) {}
  }

  // On a phone the top "Send a request" button scrolls away (benchmark,
  // 23 Nov 2026: the best pages keep the action in view). A bar at the
  // bottom of the screen takes its place until the price list, with
  // its own buttons, is on screen. It leaves room for the chat bubble.
  function requestBar() {
    try {
      if (!data || !data.groups.length || document.querySelector('.nwp-bar')) return;
      if (!window.IntersectionObserver) return;
      var top = document.querySelector('.left-column .buttons-wrapper .research-button');
      if (!top) return;
      var g = data.groups[0];
      var from = g.price && g.price !== 'Ask'
        ? 'from ' + g.price + g.per.replace('/month', '/mo').replace('/hour', '/hr') : '';
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'nwp-bar';
      b.innerHTML = '<b>Send a request</b>' + (from ? '<span>' + esc(from) + '</span>' : '');
      document.body.appendChild(b);
      var topIn = true, listIn = false;
      var upd = function () { b.classList.toggle('on', !topIn && !listIn); };
      new IntersectionObserver(function (es) { topIn = es[es.length - 1].isIntersecting; upd(); }).observe(top);
      new IntersectionObserver(function (es) { listIn = es[es.length - 1].isIntersecting; upd(); }).observe(root);
      b.addEventListener('click', function () {
        track('request_bar_tap', { slug: SLUG });
        (top.querySelector('#research-button-wrapper') || top).click();
      });
    } catch (e) {}
  }

  function start() {
    if (AREA || FRAMED) return;
    ratingLabel();
    hit('view');
    fetch(URL_ + '/rest/v1/rpc/page_prices', {
      method: 'POST',
      headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_slug: SLUG })
    }).then(function (r) { return r.ok ? r.json() : null; })
      .then(function (raw) {
        if (raw && raw.closed) showClosed(raw.closed);
        if (!raw || !raw.show) return;
        SHUT = Array.isArray(raw.closed_days) ? raw.closed_days.map(Number) : [];
        data = shape(raw);
        if (!data.groups.length) return;
        if (mount()) { jumpLink(); foldHours(); requestBar(); fromLink(); }
      })
      .catch(function () {});
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();

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
    tab: 0, more: {}, bad: null, picked: null, sent: false, sending: false, error: '',
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
  // The price in three parts ("from", the amount, "/mo"), so a design
  // can make only the amount bold. Without extra styling it reads
  // exactly as before.
  function priceParts(text) {
    var m = /^(from\s+)?([^\s\d]*\d[\d,.]*)(.*)$/i.exec(text || '');
    if (!m) return esc(text || '');
    return (m[1] ? '<span class="nwp-pre">' + esc(m[1]) + '</span>' : '') + '<span class="nwp-amt">' + esc(m[2]) + '</span>' +
      (m[3] ? '<span class="nwp-unit">' + esc(m[3]) + '</span>' : '');
  }
  function priceHtml(it) {
    if (!it.was) return priceParts(it.priceText);
    return '<s class="nwp-was">' + esc(it.was) + '</s>' + priceParts(it.priceText) +
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
    // "1 Month (Hot Desk)", "Meeting Room 1 Hour": one of a unit is that
    // unit (benchmark, 23 Nov 2026: every price shows its unit).
    var one = /(^|[^\d.,])(1|one)\s*(hour|day|week|month|year)\b(?!s)/.exec(n);
    if (one && !/\b(?!1\b)\d+\s*(hour|day|week|month|year)s?\b/.test(n.replace(one[0], ' '))) return one[3];
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
        was: p.was ? String(p.was) : '',
        // The space's own words say the price is for each person, so a
        // team total may be worked out from it (listing redesign, step 2).
        perPerson: /\bper (person|desk|member|seat)\b|\bp\.?p\.?\b|\/\s*(person|desk)/i.test(String(p.name || '') + ' | ' + details.join(' | '))
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
      // The "from" price is the lowest one that says per what, so the
      // first number a visitor sees always has its unit; a group with no
      // such price falls back to its lowest price.
      var withUnit = priced.filter(function (i) { return i.period; });
      var pool = withUnit.length ? withUnit : priced;
      var low = oneCur ? pool.slice().sort(function (a, b) { return a.amount - b.amount; })[0] : pool[0];
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
      '.nwp-mr{list-style:none;margin:0;padding:0;border-top:1px solid rgba(0,0,0,.05)}',
      '.nwp-more{display:block;width:100%;min-height:44px;margin:0;padding:0;border:0;background:transparent;font-family:inherit;font-size:14.5px;font-weight:700;color:var(--nwp-teal);text-decoration:underline;text-align:center;cursor:pointer}',
      '.nwp-addr{display:flex;flex-wrap:wrap;align-items:baseline;gap:0 8px;margin:2px 0 8px;font-family:Roboto,sans-serif;font-size:14px;line-height:1.4;color:#5E6670}',
      '.nwp-addr span{white-space:nowrap}',
      '.nwp-addr a{flex:none;color:#05434F;font-weight:700;text-decoration:underline;white-space:nowrap}',
      '.nwp-jump{display:none}',
      // Phones: the heading at 20px (24px took three lines), and the
      // facts under it flow as one wrapped line: rating, area, country,
      // kind of space, directions (Jonathan, 24 Nov 2026: 'do 1, 2 and
      // 3'; tried on Alt_ChiangMai at phone width first).
      '@media (max-width: 767px){' +
        'h1.nwp-h1{font-size:20px !important;line-height:1.3 !important}' +
        '.nwp-top{display:flex !important;flex-wrap:wrap;align-items:center;gap:4px 14px !important}' +
        '.nwp-top>.div-block-138{flex:0 0 100%}' +
        '.nwp-top>.div-block-156,.nwp-top>.div-block-header-3{display:contents !important}' +
        '.nwp-top .google-rating-wrapper{order:1}' +
        '.nwp-top .location-div{order:2}' +
        '.nwp-top .div-block-137{order:3}' +
        '.nwp-top .cafe-coworking-wrapper{order:4}' +
        '.nwp-top .wifi-wrapper{order:5}' +
        '.nwp-top>.nwp-addr{order:6;margin:0}' +
        // The star lines up with the heading and the row under it.
        '.nwp-top .google-rating-wrapper,.nwp-top .cafe-coworking-wrapper{padding-left:0 !important}' +
        '.nwbc li.nwp-bc-cur,.nwbc li:has(>span.nwbc-c){display:none !important}' +
      '}',
      '.nwp-hrs,.nwp-bar{display:none}',
      '@media (max-width: 767px){' +
        '.nwp-hrs{display:flex;align-items:center;justify-content:space-between;gap:12px;width:100%;min-height:44px;margin:0;padding:0;border:0;background:transparent;font-family:Roboto,sans-serif;text-align:left;color:#2C2C2C;cursor:pointer}' +
        '.nwp-hrs b{font-size:15px;font-weight:500;line-height:1.3}' +
        '.nwp-hrs span{flex:none;font-size:14px;font-weight:700;color:#05434F;text-decoration:underline}' +
        '.nwp-week.nwp-shut{display:none !important}' +
        '.nwp-bar.on{display:flex;align-items:center;justify-content:center;gap:8px;position:fixed;left:12px;right:88px;bottom:18px;min-height:52px;padding:6px 14px;border:0;border-radius:8px;background:' + RED + ';color:#fff;font-family:Roboto,sans-serif;box-shadow:0 6px 20px rgba(20,32,50,.25);z-index:2147482990;cursor:pointer}' +
        '.nwp-bar b{font-size:15px;font-weight:700;white-space:nowrap}' +
        '.nwp-bar span{font-size:13.5px;font-weight:400;opacity:.95;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
      '}',
      '@media (max-width: 767px){.nwp-jump{display:flex;align-items:center;justify-content:flex-start;min-height:44px;margin:4px 0 0;font-family:Roboto,sans-serif;font-size:14.5px;line-height:1.3;font-weight:700;color:#05434F;text-decoration:underline;text-align:left}}',
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
      '.nwp-dot{font-style:normal}',
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
  // A long group shows its first five lines and a "Show all" button
  // (benchmark, 23 Nov 2026). Seven or more only, so the button never
  // hides a single line.
  function shownItems(g) {
    return S.more[g.key] || g.items.length <= 6 ? g.items : g.items.slice(0, 5);
  }
  function moreBtn(g) {
    if (S.more[g.key] || g.items.length <= 6) return '';
    return '<li class="nwp-mr"><button type="button" class="nwp-more" data-a="more" data-v="' + esc(g.key) +
      '" data-k="more-' + esc(g.key) + '">Show all ' + g.items.length + '</button></li>';
  }

  function listHtml() {
    var h = '<div class="nwp-box">';
    data.groups.forEach(function (g, gi) {
      var pic = photoFor(gi);
      h += '<section class="nwp-grp" aria-label="' + esc(g.title) + '"><div class="nwp-gh">' +
        (pic ? '<img class="nwp-gimg" src="' + esc(pic) + '" alt="" loading="lazy">' : '') +
        '<div class="nwp-gt"><b>' + esc(g.title) + '</b><span>' + esc(g.spec) + '</span></div>' +
        (g.price ? '<div class="nwp-from">' + (g.fromWord ? '<small>FROM</small>' : '') + '<b>' + esc(g.price) + '</b><i>' + esc(g.per) + '</i></div>' : '<div class="nwp-from nwp-req"><b>Price on request</b></div>') + '</div>' +
        '<ul class="nwp-rows">';
      shownItems(g).forEach(function (it) {
        h += '<li class="nwp-r"><span class="nwp-rn"><b>' + esc(it.name) + '</b>' + (it.note ? ' <span><i class="nwp-dot">· </i>' + esc(it.note) + '</span>' : '') + '</span>' +
          '<span class="nwp-rp' + (it.was ? ' nwp-rpw' : '') + '">' + priceHtml(it) + '</span>' + enqBtn(it) + '</li>';
      });
      h += moreBtn(g) + '</ul></section>';
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
    shownItems(g).forEach(function (it) {
      h += '<li class="nwp-r"><span class="nwp-rn"><b>' + esc(it.name) + '</b>' + (it.note ? '<span>' + esc(it.note) + '</span>' : '') + '</span>' +
        '<span class="nwp-rp' + (it.was ? ' nwp-rpw' : '') + '">' + priceHtml(it) + '</span>' + enqBtn(it) + '</li>';
    });
    return h + moreBtn(g) + '</ul></div></div>';
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
    // The strip of tabs keeps its place when the list is redrawn, so
    // choosing "Other" does not jump the strip back to the start
    // (Jonathan, 24 Nov 2026).
    var strip = root.querySelector('.nwp-tabs');
    var stripAt = strip ? strip.scrollLeft : 0;
    root.innerHTML =
      '<h2 class="nwp-h">Passes and prices at ' + esc(data.space) + '</h2>' +
      '<p class="nwp-sub">' + (data.vat ? 'All prices ' + esc(data.vat.replace(/^prices?\s+/i, '')) + ', set by ' + esc(data.space) : 'Prices set by ' + esc(data.space)) +
      (data.checked ? ', ' + esc(data.checked) : '') + '. ' +
      'Sending a request is free and there\'s no obligation.' +
      // A Premium page links to the space's own website; a free page
      // does not, so the Request button stays the way to ask.
      (data.site ? ' <a class="nwp-site" href="' + esc(data.site) + '" target="_blank" rel="noopener">Visit website</a>' : '') + '</p>' +
      (phone ? tabsHtml() : listHtml());
    try {
      strip = root.querySelector('.nwp-tabs');
      if (strip && strip.scrollWidth > strip.clientWidth) {
        strip.scrollLeft = stripAt;
        // And the chosen tab is brought fully into view.
        var sel = strip.querySelector('.nwp-tab[aria-selected="true"]');
        if (sel) {
          var l = sel.offsetLeft - strip.offsetLeft, r = l + sel.offsetWidth;
          if (l < strip.scrollLeft) strip.scrollLeft = Math.max(0, l - 12);
          else if (r > strip.scrollLeft + strip.clientWidth) strip.scrollLeft = r - strip.clientWidth + 12;
        }
      }
    } catch (e) {}
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
    else if (a === 'more') { S.more[v] = true; track('prices_show_all', { slug: SLUG, group: v }); }
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

  // The grey tags under the photos: a tag shown twice shows once, and a
  // tag that only says "No" (or nothing) is not shown (visitor audit,
  // 23 Nov 2026: "Skype Room" twice on five of six pages; Jonathan, 24
  // Nov 2026: "remove the doubled skype room", "and the stray no tag").
  // The page's own tags are untouched; the repeats are only hidden.
  function tidyTags() {
    try {
      var boxes = document.querySelectorAll('.modal-filtertag-div');
      for (var b = 0; b < boxes.length; b++) {
        var seen = {}, tags = boxes[b].querySelectorAll('.modal-filtertag-tag');
        for (var i = 0; i < tags.length; i++) {
          var tx = tags[i].querySelector('.modal-filtertag-tagtext');
          if (!tx) continue;
          if (tags[i].classList.contains('w-condition-invisible')) continue;
          var k = String(tx.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
          if (!k || k === 'no' || k === 'none' || k === 'n/a' || seen[k]) tags[i].style.display = 'none';
          else seen[k] = 1;
        }
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
      a.textContent = from ? 'See prices' + from : 'See passes and options';
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
      // Seven rows of day and hours; the page's grid carries two spare
      // cells after Sunday.
      if (cells.length < 14) return;
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
  // bottom of the screen takes its place for the rest of the page.
  // Nomadwise red, always. It leaves room for the chat bubble.
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
      // Shown whenever the top button is off screen (Jonathan, 23 Nov
      // 2026: it only appeared near the footer, because on most pages the
      // price list comes on screen as the top button leaves).
      new IntersectionObserver(function (es) {
        if (V2.go) return;
        b.classList.toggle('on', !es[es.length - 1].isIntersecting);
      }).observe(top);
      b.addEventListener('click', function () {
        track('request_bar_tap', { slug: SLUG });
        if (V2.go) { V2.go('bar'); return; }
        (top.querySelector('#research-button-wrapper') || top).click();
      });
    } catch (e) {}
  }

  // The heading keeps its words (it carries the city and area for
  // search) and is a little smaller on phones, so it takes two lines
  // where it took three (Jonathan, 24 Nov 2026: "make it slightly
  // smaller on mobile"). Size only: see h1.nwp-h1.
  function smallHeading() {
    try {
      var h = document.querySelector('h1');
      if (!h) return;
      h.classList.add('nwp-h1');
      var box = h.closest('.div-block-136');
      if (box && box.querySelector('.div-block-header-3')) box.classList.add('nwp-top');
    } catch (e) {}
    trimCrumb(0);
  }
  // On a phone the breadcrumb ends at the area ("< Old City"): the
  // space's own name is the heading right under it. Only the plain
  // name is hidden, never the button that switches between places.
  // The breadcrumb is drawn by its own script, so this looks a few
  // times.
  function trimCrumb(n) {
    try {
      var cur = document.querySelector('.nwbc span.nwbc-c');
      var li = cur && cur.closest('li');
      if (li) { li.classList.add('nwp-bc-cur'); return; }
    } catch (e) { return; }
    if (n < 10) setTimeout(function () { trimCrumb(n + 1); }, 400);
  }

  // The street address in words under the name, with "Get directions"
  // (benchmark, 23 Nov 2026). The address is the short one from the
  // space's Google listing, as it is; directions open at its own pin.
  function addressLine(raw) {
    try {
      var addr = String(raw.address || '').replace(/\s+/g, ' ').trim();
      if (document.querySelector('.nwp-addr')) return;
      // A short, clean address is shown whole. A long one, or a map
      // code such as "9533+M38", is left out and only the link shows:
      // never cut, never an ellipsis (Jonathan, 24 Nov 2026: the long
      // one was "too long", and "I don't really like the ...").
      if (addr.length > 34 || /^[A-Z0-9]{4}\+[A-Z0-9]{2,}/i.test(addr)) addr = '';
      var lat = Number(raw.lat), lng = Number(raw.lng);
      var href = raw.lat != null && raw.lng != null && isFinite(lat) && isFinite(lng)
        ? 'https://www.google.com/maps/dir/?api=1&destination=' + lat + ',' + lng +
          (raw.place ? '&destination_place_id=' + encodeURIComponent(raw.place) : '')
        : '';
      var w = document.querySelectorAll('.google-rating-wrapper');
      for (var i = 0; i < w.length; i++) {
        var row = w[i].closest('.div-block-header-3') || w[i].parentElement;
        if (!row || !row.parentElement) continue;
        var el = document.createElement('div');
        el.className = 'nwp-addr';
        if (!addr && !href) return;
        el.innerHTML = (addr ? '<span>' + esc(addr) + '</span>' : '') + (href ? '<a href="' + esc(href) + '" target="_blank" rel="noopener">Get directions</a>' : '');
        var a = el.querySelector('a');
        if (a) a.addEventListener('click', function () { track('directions_tap', { slug: SLUG }); });
        row.parentElement.insertBefore(el, row);
      }
    } catch (e) {}
  }

  // ------------------------------------------- new page, step 1 (preview)
  // The listing page redesign Jonathan chose on 26 Nov 2026 (design
  // canvas "Coworking listing page: three directions", Combined). Built
  // behind a preview switch so the 8 Dec read of batches 1 to 3 stays
  // clean: nomadwise.io/...?preview=1 turns it on for that browser,
  // ?preview=0 turns it off. Visitors see today's page.
  // Step 1: two fact lines under the name, "How a request works", other
  // spaces nearby, and one small claim line.
  // LIVE FOR EVERYONE from 26 Nov 2026 (Jonathan: "im looking to move
  // this design to live"). The switch stays as a way back: ...?preview=0
  // shows the old page in that browser, ?preview=1 returns to the new one.
  // To take the new page off for all visitors, set PREVIEW to false here.
  var PREVIEW = true;
  try {
    var pq = new URLSearchParams(location.search).get('preview');
    if (pq === '1') localStorage.setItem('nw_preview', '1');
    if (pq === '0') localStorage.setItem('nw_preview', '0');
    PREVIEW = localStorage.getItem('nw_preview') !== '0';
  } catch (e) {}

  // No flash of the old layout (Jonathan, 26 Nov 2026: "for a split
  // second it shows the old template widths, and then moves to the new
  // one"). The page's own layout arrives first and the new one is built
  // a moment later, once the space's prices have come back. So the
  // listing is held unseen from the moment this script runs and fades in
  // when the new layout is ready. It shows anyway after 2.5 seconds, or
  // at once if anything fails, so the page can never stay blank.
  // A small script in the head of the Webflow listing template adds the
  // same nwv2-pre class before first paint; preShow() below clears both.
  var PRE = null;
  function preShow() {
    if (PRE === null) return;
    clearTimeout(PRE);
    PRE = null;
    try { document.documentElement.classList.remove('nwv2-pre'); } catch (e) {}
  }
  if (PREVIEW && SLUG && !AREA && !FRAMED) {
    try {
      var pst = document.createElement('style');
      pst.textContent = '.card_template_padding{transition:opacity .15s ease}html.nwv2-pre .card_template_padding{opacity:0;transition:none}';
      (document.head || document.documentElement).appendChild(pst);
      document.documentElement.classList.add('nwv2-pre');
      PRE = setTimeout(preShow, 2500);
    } catch (e) {}
  }

  function v2Styles() {
    if (document.getElementById('nwv2-css')) return;
    var st = document.createElement('style');
    st.id = 'nwv2-css';
    st.textContent = [
      // The old fact rows and the two claim boxes give way to the new ones.
      '.nwv2 .div-block-156,.nwv2 .nwp-addr,.nwv2 .div-block-header-3{display:none !important}',
      '.nwv2 .claim-banner,.nwv2 .claim-line-sidebar{display:none !important}',
      // The chat bubble waits 30 seconds: someone still on the page by
      // then may have a question (Jonathan, 26 Nov 2026).
      'body.nwv2:not(.nwv2-chat) #nw-chat{display:none !important}',
      // The lines must never widen the page: they take the width they
      // are given and no more (found on Masco, 26 Nov 2026: a long
      // address stretched the whole card on a phone).
      '.nwv2-facts{display:flex;flex-direction:column;gap:6px;margin:8px 0 12px;font-family:Roboto,sans-serif;font-size:14.5px;line-height:1.5;color:#444B53;flex:0 0 100%;width:100%;max-width:100%;contain:inline-size}',
      '.nwv2-ln{white-space:nowrap;overflow:hidden;width:0;min-width:100%}',
      '.nwv2-ln.wrap{white-space:normal}',
      // Each fact starts with a small icon (star, pin, clock) so the eye
      // finds the rating, the address and the hours at once, and the two
      // facts on the first line stand apart (Leonie, 26 Nov 2026: plain
      // text, "missing some sort of icon", "too much unrelated info in the
      // same style"). Links: dark, a little heavier, no underline, no arrow,
      // red on hover (Jonathan and Leonie, 26 Nov 2026: no teal, no
      // underline, no arrow).
      '.nwv2-ln a{color:#2C2C2C;font-weight:500;text-decoration:none;white-space:nowrap}',
      '.nwv2-ln a:hover{color:#FF444F}',
      '.nwv2-ln svg{width:16px;height:16px;vertical-align:-3px;margin-right:6px;color:#FF444F}',
      '.nwv2-ln svg.nwv2-star{color:#F5A623}',
      '.nwv2-ln b{font-weight:700;color:#2C2C2C}',
      '.nwv2-ln .gap{display:inline-block;width:20px}',
      '.nwv2-ln .dot{margin:0 6px}',
      '.nwv2-ln.wrap a[data-nwv2="hours"]{display:block;margin-left:22px}',
      '.nwv2-ln.wrap .dot:has(+ a[data-nwv2="hours"]){display:none}',
      // The "Where to stay" banner is off the new page for now (Jonathan,
      // 26 Nov 2026). Ubigi and SafetyWing stay.
      'body.nwv2 .listings-5th-col .w-dyn-item:has(img[src*="stay-nearby-banner"]),body.nwv2 .listings-5th-col .w-dyn-item:has(img[alt^="Where to stay"]){display:none !important}',
      '.nwv2-sec{margin:32px 0;font-family:Roboto,sans-serif;color:#2C2C2C;contain:inline-size}',
      '.nwv2-sec h2{margin:0 0 14px;font-size:20px;line-height:1.3;font-weight:700}',
      '.nwv2-steps{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px;margin:0;padding:0;list-style:none}',
      '.nwv2-steps li{display:flex;gap:10px;align-items:flex-start;font-size:15px;line-height:1.45;margin:0}',
      '.nwv2-steps b{flex:0 0 28px;height:28px;border-radius:8px;background:#FFF1F2;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:14px}',
      '.nwv2-near{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px}',
      '@media (min-width:768px) and (max-width:1199px){.nwv2-near{grid-template-columns:repeat(2,minmax(0,1fr))}}',
      // A photo with a proper 4:3 shape and the words under it, no box
      // round the card (Jonathan, 26 Nov 2026: the boxed cards with a
      // shallow photo "look too wide somehow").
      '.nwv2-card{display:block;color:#2C2C2C;text-decoration:none}',
      '.nwv2-pic{aspect-ratio:4/3;border-radius:8px;background:#E9ECEF center/cover no-repeat}',
      '.nwv2-card:hover .nwv2-pic{opacity:.92}',
      '.nwv2-card:hover b{text-decoration:underline}',
      '.nwv2-tx{padding:10px 0 0;font-size:14px;line-height:1.4}',
      '.nwv2-tx b{display:block;font-weight:700}',
      '.nwv2-tx span{display:block;color:#5E6670}',
      '.nwv2-tx b{margin-bottom:4px}',
      '.nwv2-rate i{font-style:normal;color:#2C2C2C}',
      '.nwv2-tx .nwv2-cp{margin-top:6px;color:#2C2C2C;font-weight:500}',
      '.nwv2-claim{margin:8px 0 24px;font-family:Roboto,sans-serif;font-size:13px;color:#5E6670}',
      '.nwv2-claim a{color:#5E6670;text-decoration:underline}',
      // Step 2: the "What do you need?" box. With it on the page the old
      // top button and the "See prices" link step aside.
      '.nwv2-haspick .left-column .div-block-80>.buttons-wrapper>.research-button,.nwv2-haspick .left-column .div-block-80>.buttons-wrapper>.div-block-829,.nwv2-haspick .nwp-jump{display:none !important}',
      '.nwv2-pick{margin:4px 0 24px;padding:18px;border:1px solid rgba(0,0,0,.1);border-radius:8px;background:#fff;font-family:Roboto,sans-serif;color:#2C2C2C;display:flex;flex-direction:column;gap:14px;max-width:560px;contain:inline-size;scroll-margin-top:84px}',
      '.nwv2-pick *{box-sizing:border-box}',
      '.nwv2-pick h2{margin:0;font-size:18px;line-height:1.3;font-weight:700}',
      '.nwv2-needs{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}',
      '.nwv2-needs button{min-height:48px;margin:0;padding:8px 10px;border:1px solid #C9CED4;border-radius:8px;background:#fff;font:500 14px/1.25 Roboto,sans-serif;color:#2C2C2C;cursor:pointer}',
      '.nwv2-needs button[aria-pressed="true"]{border:2px solid #FF444F;background:#FFF1F2;padding:7px 9px}',
      '.nwv2-needs button:only-child{grid-column:1/-1}',
      '.nwv2-needs button:last-child:nth-child(3){grid-column:1/-1}',
      '.nwv2-ppl{display:flex;align-items:center;justify-content:space-between;gap:12px;font-size:15px}',
      '.nwv2-ppl>div{display:flex;align-items:center;gap:12px}',
      '.nwv2-ppl button{width:44px;height:44px;margin:0;padding:0;border:1px solid #C9CED4;border-radius:8px;background:#fff;font:400 20px/1 Roboto,sans-serif;color:#2C2C2C;cursor:pointer}',
      '.nwv2-ppl button[disabled]{opacity:.4;cursor:default}',
      '.nwv2-ppl b{min-width:24px;text-align:center;font-weight:700}',
      '.nwv2-res{display:flex;flex-direction:column;gap:0;padding-top:14px;border-top:1px solid rgba(0,0,0,.08)}',
      '.nwv2-it{padding:12px 0;border-top:1px solid rgba(0,0,0,.08)}',
      '.nwv2-res>.nwv2-it:first-child{border-top:0;padding-top:0}',
      '.nwv2-it-top{display:flex;flex-wrap:wrap;align-items:baseline;justify-content:space-between;gap:2px 12px}',
      '.nwv2-it-top>b{font:700 15px/1.35 Roboto,sans-serif;color:#2C2C2C;min-width:0}',
      '.nwv2-note{display:block;margin-top:3px;font:400 13.5px/1.45 Roboto,sans-serif;color:#5E6670}',
      '.nwv2-pr{font:400 13.5px/1.35 Roboto,sans-serif;color:#5E6670;white-space:nowrap}',
      '.nwv2-pr b{font-size:15px;font-weight:700;color:#2C2C2C}',
      '.nwv2-all{padding-top:4px;font-size:14px;font-weight:500;color:#2C2C2C;text-decoration:none}',
      '.nwv2-all:hover{color:#FF444F}',
      // The request form on a computer: wider and shorter, two fields to a
      // row, the button beside the small print, so it fits a laptop screen
      // without scrolling (Jonathan, 26 Nov 2026: it was cut off on
      // Leonie's laptop). Phones keep the full-screen form.
      '@media (min-width:768px){' +
      'body.nwv2 .nwp-dlg{max-width:740px}' +
      'body.nwv2 .nwp-hd{padding:14px 14px 14px 20px}' +
      'body.nwv2 .nwp-bd{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px 16px;align-items:start;padding:16px 20px}' +
      'body.nwv2 .nwp-bd>.nwp-ok,body.nwv2 .nwp-bd>.nwp-ck,body.nwv2 .nwp-bd>.nwp-fl:has(textarea){grid-column:1/-1}' +
      'body.nwv2 .nwp-bd .nwp-seg:not(.nwp-seg-people){display:flex;flex-wrap:nowrap}' +
      'body.nwv2 .nwp-bd .nwp-seg:not(.nwp-seg-people) .nwp-sg{flex:1 1 auto;padding:0 6px;white-space:nowrap}' +
      'body.nwv2 .nwp-ft{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:8px 20px;padding:12px 20px 14px}' +
      'body.nwv2 .nwp-ft>.nwp-err{grid-column:1/-1;grid-row:1}' +
      'body.nwv2 .nwp-ft>.nwp-send{grid-column:2;grid-row:2;width:auto;min-width:230px;padding:0 24px}' +
      'body.nwv2 .nwp-ft>.nwp-trust{grid-column:1;grid-row:2}' +
      '}',
      // Options a visitor can pick: the request then names that one.
      '.nwv2-pick button.nwv2-opt{display:grid;grid-template-columns:16px minmax(0,1fr);column-gap:10px;align-items:start;width:100%;margin:0;padding:12px 0;border:0;border-top:1px solid rgba(0,0,0,.08);border-radius:0;background:none;text-align:left;font:inherit;color:inherit;cursor:pointer}',
      '.nwv2-pick .nwv2-res>button.nwv2-opt:first-child{border-top:0;padding-top:0}',
      '.nwv2-opt>span:last-child{display:block;min-width:0}',
      '.nwv2-opt .nwv2-it-top{display:flex}',
      '.nwv2-rad{box-sizing:border-box;width:16px;height:16px;margin-top:2px;border:1.5px solid #9AA1A9;border-radius:8px;background:#fff}',
      '.nwv2-opt:hover .nwv2-rad{border-color:#2C2C2C}',
      '.nwv2-opt[aria-pressed="true"] .nwv2-rad{border-color:#FF444F;background:#FF444F;box-shadow:inset 0 0 0 3px #fff}',
      '.nwv2-tot{margin:4px 0 0;padding:10px 12px;border-radius:8px;background:#F6F7F8;font-size:14px;line-height:1.45}',
      '.nwv2-none{margin:0;font-size:14px;line-height:1.45;color:#5E6670}',
      '.nwv2-alt{display:flex;justify-content:space-between;gap:12px;font-size:14.5px;color:#2C2C2C;text-decoration:none}',
      '.nwv2-alt span{text-decoration:underline;color:#05434F;font-weight:700}',
      '.nwv2-alt b{font-weight:400;white-space:nowrap}',
      '.nwv2-go{min-height:48px;margin:0;padding:10px 16px;border:0;border-radius:8px;background:#FF444F;color:#fff;font:500 16px/1.2 Roboto,sans-serif;cursor:pointer}',
      '.nwv2-go:hover{background:#E63B45}',
      '.nwv2-pick button:focus-visible,.nwv2-pick a:focus-visible{outline:2px solid #2C2C2C;outline-offset:2px}',
      '.nwv2-sure{display:flex;flex-direction:column;gap:5px;margin:0;padding:0;list-style:none;font-size:13px;line-height:1.4;color:#5E6670;text-align:left}',
      '.nwv2-sure li{display:flex;align-items:flex-start;gap:8px;margin:0;padding:0}',
      '.nwv2-sure svg{flex:0 0 14px;width:14px;height:14px;margin-top:2px}',
      '@media (max-width:767px){' +
        '.nwv2-steps{grid-template-columns:1fr;gap:12px}' +
        // The hours are in the fact line; the week below stays out of
        // the way until "See all hours" is tapped.
        '.nwv2 .map-div-mobile{background:#E9ECEF;border-radius:8px;overflow:hidden}' +
        // No request bar stuck to the bottom of a phone for now (Jonathan,
        // 26 Nov 2026): the box and the price list carry the buttons.
        'body.nwv2 .nwp-bar{display:none !important}' +
        'body:not(.nwv2-hrs-seen) .nwv2 .div-block-77:has(.nwp-week.nwp-shut){display:none}' +
        '.nwv2-sec{margin:26px 0}.nwv2-sec h2{font-size:17px}' +
        '.nwv2-near{display:flex;overflow-x:auto;gap:10px;margin-right:-20px;padding-right:20px;scroll-snap-type:x mandatory;scrollbar-width:none}' +
        '.nwv2-near::-webkit-scrollbar{display:none}' +
        // One and a half cards across, so the next one shows there is
        // more to swipe to.
        '.nwv2-card{flex:0 0 64%;scroll-snap-align:start}' +
        '.nwv2-tx{font-size:14.5px;line-height:1.45}' +
        '.nwv2-tx b{font-size:16px}' +
      '}',
      // The price list on a computer as an aligned list (design A,
      // Jonathan, 26 Nov 2026: the old one "seems a bit difficult to
      // read"): a thin heading per kind of space, the name with its
      // description on a line of its own, prices in one column with only
      // the amount bold.
      // These rules reach only the list form (it has .nwp-grp), never
      // the tabbed form shown in a narrow column.
      '.nwv2 .nwp-box:has(.nwp-grp){border:0;border-radius:0;overflow:visible;background:none}',
      // Each kind of space sits in its own thin box with its heading inside
      // at the top (Leonie, 26 Nov 2026: the black line under a heading
      // read as the bottom edge of the group above). Headings are black,
      // the item names bold grey, descriptions a lighter grey.
      '.nwv2 .nwp-grp{border:1px solid #E3E5E8;border-radius:8px;padding:16px 18px 4px}',
      '.nwv2 .nwp-grp + .nwp-grp{border-top:1px solid #E3E5E8;margin-top:16px}',
      '.nwv2 .nwp-grp .nwp-gh{background:none;padding:0 0 4px;border-bottom:0;align-items:baseline;gap:12px}',
      '.nwv2 .nwp-grp .nwp-gimg,.nwv2 .nwp-grp .nwp-gh .nwp-from{display:none}',
      '.nwv2 .nwp-grp .nwp-gt{display:flex;align-items:baseline;justify-content:space-between;gap:12px}',
      '.nwv2 .nwp-grp .nwp-gt b{font-size:14px;letter-spacing:.06em;text-transform:uppercase;color:#2C2C2C}',
      '.nwv2 .nwp-grp .nwp-gt span{margin:0;font-size:13px}',
      '.nwv2 .nwp-grp .nwp-rows{padding:0}',
      '.nwv2 .nwp-grp .nwp-r{display:grid;grid-template-columns:minmax(0,1fr) auto 96px;gap:16px;align-items:center;padding:14px 0;border-bottom:1px solid #ECEEF0}',
      '.nwv2 .nwp-grp .nwp-r:last-child{border-bottom:0}',
      '.nwv2 .nwp-grp .nwp-rn b{display:block;font-size:16px;line-height:1.35;color:#5E6670}',
      '.nwv2 .nwp-grp .nwp-rn span{display:block;margin-top:2px;font-size:14px;line-height:1.45;color:#7A828C}',
      '.nwv2 .nwp-grp .nwp-dot{display:none}',
      '.nwv2 .nwp-grp .nwp-rp{font-weight:400;font-size:14px;color:#2C2C2C;text-align:right}',
      '.nwv2 .nwp-grp .nwp-rp .nwp-pre,.nwv2 .nwp-grp .nwp-rp .nwp-unit{font-size:13px;color:#5E6670}',
      '.nwv2 .nwp-grp .nwp-rp .nwp-amt{font-weight:700;font-size:17px}',
      '.nwv2 .nwp-grp .nwp-enq{justify-self:end;min-height:40px;font-weight:500;font-size:14px}',
      // Step 3: photos, "What's here", and the two columns on a computer.
      '.nwv2-h{margin:28px 0 14px;font:700 20px/1.3 Roboto,sans-serif;color:#2C2C2C}',
      // What's here
      '.nwv2-amen{display:grid !important;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px 20px;margin:0 0 8px !important;height:auto !important;contain:inline-size}',
      '.nwv2-amen .modal-filtertag-tag{border:0;background:none;box-shadow:none;padding:0;margin:0;gap:12px;height:auto;min-width:0;align-items:center}',
      '.nwv2-amen .modal-filtertag-tag .modal-filtertag-tagtext{font:400 15px/1.35 Roboto,sans-serif !important;color:#2C2C2C;white-space:normal}',
      '.nwv2-amen .modal-filtertag-tag .nw-amen-ico{width:22px !important;height:22px !important;flex:0 0 22px;color:#2C2C2C !important;stroke-width:1.6}',
      '.nwv2-amen:not(.all) .nwv2-x{display:none !important}',
      '.nwv2-amen-row{display:flex;flex-wrap:wrap;align-items:center;gap:12px 24px;margin:16px 0 0}',
      '.nwv2-amen-row:empty{display:none}',
      '.nwv2-amen-row .nwv2-btn2{margin:0}',
      '.nwv2-amen-row .modal-filtertag-tag-empty{border:0;background:none;box-shadow:none;padding:0;margin:0;height:auto;font-size:14px;color:#5E6670}',
      '.nwv2-amen-row:not(.all) .modal-filtertag-tag-empty{display:none}',
      '@media (min-width:768px){.nwv2-amen-row.m .modal-filtertag-tag-empty{display:inline-flex}}',
      '.nwv2-btn2{display:inline-flex;align-items:center;justify-content:center;min-height:44px;margin:8px 0 0;padding:8px 18px;border:1px solid #2C2C2C;border-radius:8px;background:#fff;font:500 15px/1.2 Roboto,sans-serif;color:#2C2C2C;cursor:pointer}',
      '.nwv2-btn2:hover{background:#F6F7F8}',
      '@media (min-width:768px){.nwv2-amen-btn.nwv2-m{display:none}}',
      '.nwv2-btn2:focus-visible,.nwv2-view button:focus-visible{outline:2px solid #2C2C2C;outline-offset:2px}',
      // Photos
      '.nwv2-all-ph{position:absolute;right:12px;bottom:12px;z-index:3;min-height:40px;margin:0;padding:6px 14px;border:1px solid #2C2C2C;border-radius:8px;background:#fff;font:500 14px/1.2 Roboto,sans-serif;color:#2C2C2C;cursor:pointer}',
      '.nwv2-ph{display:none}',
      '.nwv2-view{position:fixed;inset:0;z-index:2147483000;background:#fff;overflow-y:auto;-webkit-overflow-scrolling:touch;font-family:Roboto,sans-serif}',
      '.nwv2-view-top{position:sticky;top:0;z-index:1;display:flex;align-items:center;justify-content:space-between;gap:12px;padding:10px 16px;background:#fff;border-bottom:1px solid rgba(0,0,0,.08)}',
      '.nwv2-view-top b{font-size:15px;font-weight:700;color:#2C2C2C;min-width:0;overflow-wrap:anywhere}',
      '.nwv2-view-top button{flex:none;min-height:44px;margin:0;padding:8px 16px;border:1px solid #2C2C2C;border-radius:8px;background:#fff;font:500 15px/1.2 Roboto,sans-serif;color:#2C2C2C;cursor:pointer}',
      '.nwv2-view-list{display:flex;flex-direction:column;gap:8px;max-width:900px;margin:0 auto;padding:12px 12px 40px}',
      '.nwv2-view-list img{display:block;width:100%;height:auto;border-radius:8px;background:#E9ECEF}',
      'html.nwv2-lock,html.nwv2-lock body{overflow:hidden !important}',
      '@media (max-width:767px){' +
      '.nwv2-h{margin:24px 0 12px;font-size:17px}' +
        '.nwv2-amen{grid-template-columns:minmax(0,1fr);gap:16px}' +
        '.nwv2-amen .modal-filtertag-tag{gap:16px}' +
        '.nwv2-amen .modal-filtertag-tag .modal-filtertag-tagtext{font-size:16px !important}' +
        '.nwv2-amen .modal-filtertag-tag .nw-amen-ico{width:24px !important;height:24px !important;flex-basis:24px}' +
        '.nwv2-amen:not(.all) .nwv2-x5{display:none !important}' +
        '.nwv2-amen-btn{display:flex;width:100%;min-height:48px;font-size:16px}' +
      '.nwv2-hasph .image-div-mobile .div-block-209{display:none !important}' +
        // The photo block keeps a 3:2 shape of its own, which left a gap
        // under the grid that grew on wider phones (Jonathan, 26 Nov 2026).
        '.nwv2-hasph .image-div-mobile{height:auto !important;min-height:0 !important;aspect-ratio:auto !important}' +
        // The breadcrumb sits midway between the photos and the card
        // below (Jonathan, 26 Nov 2026): 12px above its words, 13 below.
        '.nwv2-hasph .image-div-mobile+.section-8{padding:5px 0 0}' +
      '.nwv2-ph{position:relative;display:grid;grid-template-columns:minmax(0,2fr) minmax(0,1fr);grid-template-rows:1fr 1fr;gap:4px;height:238px;margin:8px 12px 0;border-radius:8px;overflow:hidden;contain:inline-size}' +
      '.nwv2-ph button.t{margin:0;padding:0;border:0;background:#E9ECEF center/cover no-repeat;cursor:pointer;min-width:0}' +
      '.nwv2-ph button.t:first-child{grid-row:1/3}' +
      '.nwv2-all-ph{right:8px;bottom:8px}' +
      '}',
      // Computer: two columns, the box on the right stays in view.
      '.nwv2-stick,.nwv2-hrs-card{display:none}',
      // Computer: once the box has scrolled away, a slim bar under the
      // menu keeps the request one click away all the way down the page.
      '.nwv2-topbar{display:none}',
      '@media (min-width:992px){' +
        '.nwv2-topbar.on{display:block;position:fixed;left:0;right:0;z-index:900;background:#fff;border-bottom:1px solid rgba(0,0,0,.1);box-shadow:0 4px 14px rgba(20,32,50,.06);font-family:Roboto,sans-serif}' +
        '.nwv2-topbar>div{display:flex;align-items:center;justify-content:space-between;gap:20px;margin:0 auto;padding:10px 3px;box-sizing:border-box}' +
        '.nwv2-topbar b.n{font-size:16px;font-weight:700;color:#2C2C2C;min-width:0;overflow-wrap:anywhere}' +
        '.nwv2-topbar .r{display:flex;align-items:center;gap:16px;flex:none}' +
        '.nwv2-topbar .p{font-size:14px;color:#5E6670;white-space:nowrap}' +
        '.nwv2-topbar .p b{font-size:16px;font-weight:700;color:#2C2C2C}' +
        '.nwv2-topbar .nwv2-go{min-height:44px;padding:8px 22px}' +
      '}',
      // From tablet width up the week of hours sits in the page and the
      // old button in the side column gives way to the box.
      '@media (min-width:768px){.nwv2-wide .nwv2-hrs-card{display:block;max-width:340px;margin:0 0 8px}.nwv2-wide .listings-5th-col.directory>.div-block-835{display:none !important}}',
      '@media (min-width:992px){' +
      // The page's own container hides overflow, which would stop the
      // box from staying in view.
      '.nwv2-wide .container-listings,.nwv2-wide .listing-wrapper{overflow:visible}' +
        // The banners keep their own width in the wider column.
        // Banners: tall ones stay 260 wide in the middle of the column; the
        // wide SafetyWing one (740 x 420, made for this column) runs its
        // full width (Jonathan, 26 Nov 2026). Ubigi is left as it is.
        '.nwv2-wide .listings-5th-col.directory>.w-dyn-list{width:100%;max-width:none;align-self:stretch}' +
        '.nwv2-wide .listings-5th-col.directory>.w-dyn-list>.w-dyn-items{display:flex;flex-direction:column;align-items:center;width:100%;max-width:none}' +
        '.nwv2-wide .listings-5th-col.directory>.w-dyn-list .w-dyn-item{width:100%;max-width:260px}' +
        '.nwv2-wide .listings-5th-col.directory>.w-dyn-list .w-dyn-item.nwv2-widead{max-width:none}' +
        '.nwv2-wide .nwv2-widead .monis-rent-banner-desktop,.nwv2-wide .nwv2-widead a{display:block;width:100%;max-width:none;height:auto}' +
        '.nwv2-wide .nwv2-widead img{display:block;width:100%;height:auto;aspect-ratio:740/420;object-fit:cover;border-radius:8px}' +
      '.nwv2-wide .listing-wrapper{flex-wrap:wrap;align-items:stretch}' +
      '.nwv2-wide .listing-wrapper>.quick-stack{flex:1 1 0;min-width:0;width:auto}' +
      '.nwv2-wide .listings-5th-col.directory{align-self:stretch;height:auto;flex:0 0 340px;width:340px;max-width:none;display:flex;flex-direction:column}' +
      '.nwv2-wide .nwv2-stick{display:block;flex:0 0 auto;align-self:stretch;width:100%;padding-bottom:16px}' +
      '.nwv2-wide .nwv2-stick .nwv2-pick{margin:0;max-width:none;box-shadow:0 6px 20px rgba(20,32,50,.08)}' +
      '.nwv2-wide .nwv2-stick .nwv2-claim{margin:12px 0 0;text-align:center}' +
      // Under the box, as on the mock-up Jonathan liked: a small map
      // with the address and directions, then the week of hours.
      '.nwv2-mapcard{width:100%;margin:0 0 16px;border:1px solid rgba(0,0,0,.1);border-radius:8px;overflow:hidden;background:#fff;font-family:Roboto,sans-serif}' +
      '.nwv2-mapcard .map-div-main{height:220px !important;min-height:0 !important;margin:0 !important}' +
      '.nwv2-mapcard .map-div-main>*,.nwv2-mapcard .map-div-main iframe{height:220px !important}' +
      '.nwv2-mapfoot{display:flex;flex-direction:column;gap:10px;padding:14px 16px 16px;font-size:14.5px;line-height:1.4;color:#2C2C2C}' +
      '.nwv2-mapfoot .nwv2-btn2{margin:0;text-decoration:none;width:100%}' +
      '.nwv2-info.nwv2-wide .nwv2-hrs-card{display:none}' +
      '.nwv2-hrs{padding:14px 16px 12px;border-top:1px solid rgba(0,0,0,.08);color:#2C2C2C}' +
      '.nwv2-hrs .h{display:block;margin:0 0 6px;font-size:15px;font-weight:700}' +
      '.nwv2-hrs .r{display:flex;justify-content:space-between;gap:12px;font-size:14px;line-height:1.9}' +
      '.nwv2-hrs .r span:last-child{color:#5E6670;text-align:right}' +
      '.nwv2-site{display:flex;justify-content:space-between;gap:12px;padding:14px 16px;border-top:1px solid rgba(0,0,0,.08);font-size:14.5px;font-weight:700;color:#2C2C2C;text-decoration:none}' +
      '.nwv2-site:hover{background:#F6F7F8}' +
      // The name sits on the page itself across the full width; the
        // photos fill the left column and the box starts level with them
        // (Jonathan, 26 Nov 2026, after an earlier mock-up he liked).
        '.nwv2-head{flex:0 0 100%;width:100%;padding:8px 3px 14px;contain:inline-size}' +
        '.nwv2-wide .listings-content-container{box-shadow:none;padding:0;border-radius:0}' +
        '.nwv2-wide .listing-wrapper{column-gap:28px}' +
        '.nwv2-wide .left-column .quick-stack-41,.nwv2-wide .left-column .div-block-208,.nwv2-wide .gallery__component{display:block}' +
        '.nwv2-wide .row-4.is-gallery{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);grid-template-rows:minmax(0,1fr);gap:8px;height:clamp(320px,min(36vw,50vh),520px);border-radius:8px;overflow:hidden}' +
        '.nwv2-wide .row-4.is-gallery>.col{height:100%;min-height:0;width:auto;max-width:none;padding:0}' +
        '.nwv2-wide .row-4.is-gallery>.col:last-child{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);grid-template-rows:minmax(0,1fr) minmax(0,1fr);gap:8px}' +
        '.nwv2-wide .gallery-popup__image-wrapper{height:100%;padding:0 !important;aspect-ratio:auto}' +
        '.nwv2-wide .gallery-popup__image-wrapper img{width:100%;height:100%;object-fit:cover;border-radius:0}' +
        '.nwv2-wide .listing-wrapper>.nwv2-nearby{flex:0 0 100%;width:100%;margin:8px 0 32px;padding:0 3px}' +
      '.nwv2-wide .listing-wrapper>.nwv2-nearby .nwv2-near{grid-template-columns:repeat(4,minmax(0,1fr))}' +
      '}',
      '@media (min-width:1200px){.nwv2-wide .listings-5th-col.directory{flex-basis:370px;width:370px}}',
      // The Nomadwise look (26 Nov 2026). Leonie: the page "looks too much
      // like airbnb", and should be spotted at once as Nomadwise. So: one
      // large photo with two stacked beside it, each with its own rounded
      // corners and a dark label, instead of the one-and-four mosaic with a
      // white button; "What's here" as soft pink tags with red icons, all
      // shown, instead of a two-column icon list with "Show all". Red is
      // the only accent, no teal.
      '.nwv2-sure svg{color:#FF444F}',
      '.nwv2-all-ph{left:12px;right:auto;border:0;background:rgba(44,44,44,.92);color:#fff}',
      '@media (max-width:767px){.nwv2-all-ph{left:8px;right:auto}}',
      '.nwv2-amen{display:flex !important;flex-wrap:wrap;gap:8px}',
      '.nwv2-amen .modal-filtertag-tag{flex:0 0 auto;width:auto;gap:8px;padding:8px 12px;border-radius:8px;background:#FFF1F2}',
      '.nwv2-amen .modal-filtertag-tag .modal-filtertag-tagtext{font:500 14px/1.3 Roboto,sans-serif !important;color:#2C2C2C;white-space:nowrap}',
      '.nwv2-amen .modal-filtertag-tag .nw-amen-ico{width:18px !important;height:18px !important;flex:0 0 18px;color:#FF444F !important;stroke-width:2}',
      '.nwv2-amen-row{margin:12px 0 0}',
      // The nearby cards stay as they were, a photo with the words under
      // it and no box (Jonathan, 26 Nov 2026: "we should keep this").
      '@media (min-width:992px){' +
        '.nwv2-wide .row-4.is-gallery{grid-template-columns:minmax(0,2fr) minmax(0,1fr);gap:10px;border-radius:0;overflow:visible}' +
        '.nwv2-wide .row-4.is-gallery>.col:last-child{grid-template-columns:minmax(0,1fr);grid-template-rows:none;grid-auto-rows:minmax(0,1fr);gap:10px}' +
        '.nwv2-wide .row-4.is-gallery>.col:last-child>*:nth-child(n+3){display:none}' +
        '.nwv2-wide .row-4.is-gallery>.col>*,.nwv2-wide .gallery-popup__image-wrapper{border-radius:8px;overflow:hidden}' +
      '}',
      // Laptops: the listing page, its breadcrumb and the menu open up
      // to 1320px so the photos have room. Larger screens already go to
      // 1440px. Listing pages only; article pages are untouched.
      '@media (min-width:1200px) and (max-width:1919px){.nwv2-wide .container_coworking,.nwv2-wide .listing-wrapper,.nwv2-wide .container-31,.nwv2-wide .navbar-2 .container-10{max-width:min(1320px,calc(100vw - 96px)) !important;width:100%}}'
    ].join('\n');
    document.head.appendChild(st);
  }

  // Line 1: rating, Get directions, street address. Line 2: the opening
  // hours line, plus "members 24/7" when the space's own prices say so.
  // Each line must fit on one line of the visitor's screen; if it does
  // not, the least useful piece is left out whole, never cut with "..."
  // (Jonathan, 26 Nov 2026: "simply putting ... won't work"). The full
  // address and the full week stay further down the page.
  function v2Facts(raw) {
    var top = document.querySelector('.div-block-136');
    if (!top || top.querySelector('.nwv2-facts')) return;
    var rw = top.querySelector('.google-rating-wrapper');
    var rt = rw ? String(rw.textContent || '').replace(/\s+/g, ' ') : '';
    var rm = /(\d(?:[.,]\d)?)\s*\/?\s*\((\d[\d,]*)\)/.exec(rt);
    var rating = rm ? '<b>' + esc(rm[1]) + '</b> (' + esc(rm[2]) + ' Google reviews)' : '';
    var addr = String(raw.address || '').replace(/\s+/g, ' ').trim();
    if (/^[A-Z0-9]{4}\+[A-Z0-9]{2,}/i.test(addr)) addr = '';
    var lat = Number(raw.lat), lng = Number(raw.lng), dir = '';
    if (raw.lat != null && raw.lng != null && isFinite(lat) && isFinite(lng)) {
      dir = 'https://www.google.com/maps/dir/?api=1&destination=' + lat + ',' + lng +
        (raw.place ? '&destination_place_id=' + encodeURIComponent(raw.place) : '');
    } else {
      var ll = top.querySelector('a.location-link');
      if (ll && MAPS.test(ll.getAttribute('href') || '')) dir = ll.getAttribute('href');
    }
    // Hours from the page's own week, as in foldHours.
    var hours = '';
    try {
      var grid = document.querySelector('.left-column .div-block-77 .wifi-openinghours-quickstack');
      var cells = grid ? grid.querySelectorAll('.w-layout-cell') : [];
      var names = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'], rows = [];
      if (cells.length >= 14) {
        for (var i = 0; i < 7; i++) {
          var dy = (cells[i * 2].textContent || '').trim().toLowerCase();
          var vl = (cells[i * 2 + 1].textContent || '').replace(/\s+/g, ' ').trim();
          if (dy !== names[i] || !vl) { rows = []; break; }
          rows.push(vl);
        }
      }
      if (rows.length === 7) hours = hoursLine(rows);
    } catch (e) {}
    var allDay = false;
    (raw.prices || []).forEach(function (p) {
      var t = (p.name || '') + ' ' + (p.details || []).join(' ');
      if (/24\s*\/\s*7|24 hour access|24h access/i.test(t)) allDay = true;
    });
    if (/24 hours/.test(hours)) allDay = false;

    var box = document.createElement('div');
    box.className = 'nwv2-facts';
    var l1 = [], l2 = [];
    var IC = {
      r: '<svg class="nwv2-star" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2.6l2.9 5.9 6.5.9-4.7 4.6 1.1 6.5-5.8-3.1-5.8 3.1 1.1-6.5L2.6 9.4l6.5-.9z"/></svg>',
      a: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/></svg>',
      h: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>'
    };
    if (rating) l1.push({ k: 'rating', g: 'r', h: rating });
    if (addr) l1.push({ k: 'addr', g: 'a', h: esc(addr) });
    if (dir) l1.push({ k: 'dir', g: 'a', h: '<a href="' + esc(dir) + '" target="_blank" rel="noopener" data-nwv2="dir">Get directions</a>' });
    if (hours) l2.push({ k: 'hours', g: 'h', h: esc(hours) });
    if (hours && allDay) l2.push({ k: 'members', g: 'h', h: 'members 24/7' });
    if (hours) l2.push({ k: 'all', g: 'h', h: '<a href="#nwp-week" data-nwv2="hours">See all hours</a>' });
    var draw = function (parts) {
      // The first fact of each kind carries the icon; a wider gap sets
      // the kinds apart, a dot joins what belongs together.
      var out = '', last = null;
      parts.forEach(function (p) {
        if (last !== null) out += p.g === last ? '<span class="dot" aria-hidden="true">·</span>' : '<span class="gap"></span>';
        out += (p.g !== last ? IC[p.g] : '') + p.h;
        last = p.g;
      });
      return out;
    };
    var ln1 = document.createElement('div'), ln2 = document.createElement('div');
    ln1.className = ln2.className = 'nwv2-ln';
    if (l1.length) box.appendChild(ln1);
    if (l2.length) box.appendChild(ln2);
    if (!box.children.length) return;
    var h1box = top.querySelector('.div-block-138');
    if (h1box && h1box.nextSibling) top.insertBefore(box, h1box.nextSibling); else top.appendChild(box);
    var fit = function () {
      [[ln1, l1, ['addr']], [ln2, l2, ['members']]].forEach(function (x) {
        var el = x[0], parts = x[1].slice(), drop = x[2].slice();
        el.classList.remove('wrap');
        el.innerHTML = draw(parts);
        while (el.scrollWidth > el.clientWidth + 1 && drop.length) {
          var k = drop.shift();
          parts = parts.filter(function (p) { return p.k !== k; });
          el.innerHTML = draw(parts);
        }
        // A narrow phone: "See all hours" shortens to "All hours" before
        // the line is allowed to break.
        if (el.scrollWidth > el.clientWidth + 1) {
          var sa = el.querySelector('a[data-nwv2="hours"]');
          if (sa) sa.textContent = 'All hours';
        }
        // Still too long with only what must stay: let it wrap rather
        // than cut anything off.
        if (el.scrollWidth > el.clientWidth + 1) {
          el.classList.add('wrap');
          // The hours link then takes a line of its own, in full.
          var sb = el.querySelector('a[data-nwv2="hours"]');
          if (sb) sb.textContent = 'See all hours';
        }
      });
    };
    fit();
    V2.fit = fit;
    V2.addr = addr;
    V2.dir = dir;
    var t = null;
    window.addEventListener('resize', function () { clearTimeout(t); t = setTimeout(fit, 150); });
    box.addEventListener('click', function (e) {
      var a = e.target.closest && e.target.closest('a[data-nwv2]');
      if (!a) return;
      var what = a.getAttribute('data-nwv2');
      if (what === 'dir') { track('directions_tap', { slug: SLUG, from: 'facts' }); return; }
      if (what === 'hours') {
        e.preventDefault();
        var b = document.querySelector('.nwp-hrs');
        var g = document.querySelector('.left-column .div-block-77 .wifi-openinghours-quickstack');
        // Once opened from here the hours stay on the page: "Hide" folds
        // them back to one line and no longer makes the block vanish
        // (Jonathan, 26 Nov 2026).
        document.body.classList.add('nwv2-hrs-seen');
        if (V2.map) V2.map();
        if (b && b.getAttribute('aria-expanded') !== 'true') b.click();
        var seen = function (el) { return el && el.getClientRects().length ? el : null; };
        var at = seen(b) || seen(g) || seen(document.getElementById('nwv2-hours')) || seen(document.querySelector('.nwv2-hrs'));
        if (at) { try { at.scrollIntoView({ behavior: 'smooth', block: 'center' }); } catch (er) { at.scrollIntoView(); } }
        track('hours_opened', { slug: SLUG, from: 'facts' });
      }
    });
  }

  function v2Steps(space) {
    if (document.querySelector('.nwv2-how')) return;
    var host = document.querySelector('.left-column .div-block-80');
    if (!host) return;
    var who = space || 'the space';
    var sec = document.createElement('section');
    sec.className = 'nwv2-sec nwv2-how';
    sec.setAttribute('aria-label', 'How a request works');
    sec.innerHTML = '<h2>How a request works</h2><ol class="nwv2-steps">' +
      '<li><b>1</b><span>Tell us what you need and when. It takes about a minute.</span></li>' +
      '<li><b>2</b><span>We pass it on to ' + esc(who) + '.</span></li>' +
      '<li><b>3</b><span>They reply to you by email. You decide, with no obligation.</span></li></ol>';
    var after = document.getElementById('prices') || host.querySelector('.modal-more-div');
    if (after && after.parentElement === host) host.insertBefore(sec, after.nextSibling);
    else host.appendChild(sec);
  }

  // The lowest price that says per what: a day pass first, then a month,
  // then an hour. Words a visitor reads, from the space's own prices.
  function nearPrice(prices) {
    var best = {};
    (prices || []).forEach(function (p) {
      var details = (p.details || []).map(function (x) { return String(x || '').trim(); }).filter(Boolean);
      var per = periodOf(p.name, details, p.category);
      if (!per || p.amount == null) return;
      var key = per === 'month' ? (p.category === 'private_office' ? 'office' : 'month') : per;
      if (!best[key] || Number(p.amount) < Number(best[key].amount)) best[key] = p;
    });
    var say = function (p) { return money(p.amount, p.currency, p.label).replace(/^from\s+/i, ''); };
    if (best.day) return 'Day pass from ' + say(best.day);
    if (best.month) return 'Desk from ' + say(best.month) + ' a month';
    if (best.office) return 'Office from ' + say(best.office) + ' a month';
    if (best.hour) return 'Meeting room from ' + say(best.hour) + ' an hour';
    return '';
  }

  var V2 = { map: null, sel: null, need: null, people: 1, go: null, near: null, place: null, fit: null, addr: '', dir: '' };
  function nearbyList() {
    if (!V2.near) {
      V2.near = fetch(URL_ + '/rest/v1/rpc/page_nearby', {
        method: 'POST',
        headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_slug: SLUG })
      }).then(function (r) { return r.ok ? r.json() : []; }).catch(function () { return []; });
    }
    return V2.near;
  }

  // ------------------------------------------- new page, step 2 (preview)
  // "What do you need?": a day pass, a desk for the month, an office, a
  // meeting room, and for how many people. Only the prices that match
  // are shown; the button says what is being asked ("Request an office
  // for 4") and opens the request with that price and team size filled
  // in. A team total is shown only when the space's own words say the
  // price is per person. Only what the space itself lists is offered.
  var NEEDS = [
    ['day', 'A day pass', 'a day pass', 'day passes'],
    ['desk', 'A desk for the month', 'a desk', 'monthly desks'],
    ['office', 'An office for my team', 'an office', 'private offices'],
    ['room', 'A meeting room', 'a meeting room', 'meeting rooms']
  ];
  function needOfKind(cat, period) {
    if (cat === 'meeting_room') return 'room';
    if (cat === 'private_office') return 'office';
    if (cat !== 'coworking') return null;
    return period === 'month' || period === 'year' ? 'desk' : 'day';
  }
  function needItems(need) {
    var out = [];
    if (!data) return out;
    data.groups.forEach(function (g) {
      g.items.forEach(function (it) { if (needOfKind(it.cat, it.period) === need) out.push(it); });
    });
    // Priced first, lowest first; "Price on request" after.
    return out.sort(function (a, b) {
      if ((a.amount == null) !== (b.amount == null)) return a.amount == null ? 1 : -1;
      return (a.amount || 0) - (b.amount || 0);
    });
  }
  var TICK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';
  function bucket(n) { return n <= 1 ? 'Just me' : n === 2 ? '2' : n <= 5 ? '3 to 5' : n <= 10 ? '6 to 10' : 'More than 10'; }

  function v2Picker() {
    if (!data || !data.groups.length || document.querySelector('.nwv2-pick')) return;
    var host = document.querySelector('.left-column .div-block-80');
    if (!host) return;
    var first = null;
    NEEDS.forEach(function (n) { if (!first && needItems(n[0]).length) first = n[0]; });
    if (!first) return;
    V2.need = first;
    var box = document.createElement('section');
    box.className = 'nwv2-pick';
    box.id = 'nwv2-pick';
    box.setAttribute('aria-label', 'What do you need?');
    host.insertBefore(box, host.firstChild);
    document.body.classList.add('nwv2-haspick');
    var have = NEEDS.filter(function (n) { return needItems(n[0]).length > 0; });
    var bar = document.querySelector('.nwp-bar');

    var state = function () {
      var def = NEEDS.filter(function (n) { return n[0] === V2.need; })[0];
      var items = needItems(V2.need);
      var many = V2.people > 1;
      var cta = 'Send a request';
      if (items.length) {
        cta = V2.need === 'desk' && many ? 'Request desks for ' + V2.people
          : 'Request ' + def[2] + (many ? ' for ' + V2.people : '');
      }
      var sel = items.filter(function (it) { return String(it.id) === String(V2.sel); })[0] || items[0] || null;
      return { def: def, items: items, many: many, cta: cta, sel: sel };
    };
    var draw = function (focusKey) {
      var st = state(), h = '<h2>What do you need?</h2><div class="nwv2-needs" role="group" aria-label="What do you need?">';
      // Only what this space itself offers: its page never points a
      // visitor to another space (Jonathan, 26 Nov 2026: an owner whose
      // page advertises other spaces would be rightly annoyed).
      have.forEach(function (n) {
        h += '<button type="button" data-need="' + n[0] + '" data-k="need-' + n[0] + '" aria-pressed="' + (n[0] === V2.need) + '">' + esc(n[1]) + '</button>';
      });
      h += '</div><div class="nwv2-ppl"><span id="nwv2-ppl-l">How many people?</span><div role="group" aria-labelledby="nwv2-ppl-l">' +
        '<button type="button" data-step="-1" data-k="less" aria-label="Fewer people"' + (V2.people <= 1 ? ' disabled' : '') + '>&minus;</button>' +
        '<b aria-live="polite">' + V2.people + '</b>' +
        '<button type="button" data-step="1" data-k="more" aria-label="More people"' + (V2.people >= 50 ? ' disabled' : '') + '>+</button></div></div>';
      h += '<div class="nwv2-res">';
      if (st.items.length) {
        st.items.slice(0, 3).forEach(function (it) {
          // Name and price share the first line (the price drops under
          // the name when both do not fit); the description gets the
          // full width below. Only the amount itself is bold (Jonathan,
          // 26 Nov 2026: the two narrow columns looked cluttered).
          var pm = /^(from\s+)?([^\s\d]*\d[\d,.]*)(.*)$/i.exec(it.priceText || '');
          var ph = pm ? esc(pm[1] || '') + '<b>' + esc(pm[2]) + '</b>' + esc(pm[3]) : esc(it.priceText || '');
          if (it.perPerson && it.amount != null) ph += ' per person';
          var body = '<span class="nwv2-it-top"><b>' + esc(it.name) + '</b><span class="nwv2-pr">' + ph + '</span></span>' +
            (it.note ? '<span class="nwv2-note">' + esc(it.note) + '</span>' : '');
          // With more than one option each row can be picked, so the
          // request names the one the visitor wants (Jonathan, 26 Nov
          // 2026). The cheapest starts picked.
          if (st.items.length > 1) {
            h += '<button type="button" class="nwv2-it nwv2-opt" data-item="' + esc(it.id) + '" data-k="it-' + esc(it.id) + '" aria-pressed="' + (it === st.sel) + '">' +
              '<span class="nwv2-rad" aria-hidden="true"></span><span>' + body + '</span></button>';
          } else {
            h += '<div class="nwv2-it">' + body.replace('<span class="nwv2-it-top">', '<div class="nwv2-it-top">').replace('</span></span>', '</span></div>') + '</div>';
          }
        });
        if (st.items.length > 3) h += '<a class="nwv2-all" href="#prices">See all ' + st.items.length + ' options</a>';
        // The total: only from a price the space gives per person (a
        // desk is for one person by its nature).
        var low = st.items[0];
        if (st.many && low.amount != null && (low.perPerson || V2.need === 'desk') && (low.period === 'month' || low.period === 'day')) {
          var tot = money(low.amount * V2.people, low.currency, '') + (/\+\s*vat/i.test(low.label) ? ' + VAT' : '');
          h += '<p class="nwv2-tot">For ' + V2.people + ' people: from ' + esc(tot) + (low.period === 'month' ? ' a month' : ' a day') +
            ', based on the price per person. ' + esc(data.space) + ' confirms the exact offer.</p>';
        }
      }
      h += '</div><button type="button" class="nwv2-go" data-k="go">' + esc(st.cta) + '</button>' +
        // Three short lines, left aligned, each with a small tick
        // (Jonathan, 26 Nov 2026: the centred paragraph looked poor).
        '<ul class="nwv2-sure"><li>' + TICK + 'Free, with no obligation</li><li>' + TICK + esc(data.space) + ' replies to you by email</li>' +
        (data.checked ? '<li>' + TICK + 'Prices from their own website, ' + esc(data.checked) + '</li>' : '') + '</ul>';
      box.innerHTML = h;
      if (bar) bar.innerHTML = '<b>' + esc(st.cta) + '</b>';
      if (focusKey) {
        var el = box.querySelector('[data-k="' + focusKey + '"]');
        if (el && !el.disabled) { try { el.focus({ preventScroll: true }); } catch (e) { el.focus(); } }
      }
    };
    V2.go = function (from) {
      var st = state();
      track('picker_request', { slug: SLUG, need: V2.need, people: V2.people, from: from || 'box', matched: st.items.length > 0 });
      if (!st.items.length) {
        var top = document.querySelector('.left-column .buttons-wrapper .research-button');
        if (top) (top.querySelector('#research-button-wrapper') || top).click();
        return;
      }
      openSheet((st.sel || st.items[0]).id, 'go');
      // The team size chosen here is carried into the request.
      S.people = bucket(V2.people);
      render();
    };
    box.addEventListener('click', function (e) {
      var t = e.target.closest ? e.target.closest('button,a') : null;
      if (!t) return;
      if (t.hasAttribute('data-need')) {
        V2.need = t.getAttribute('data-need');
        V2.sel = null;
        track('picker_need', { slug: SLUG, need: V2.need });
        draw('need-' + V2.need);
      } else if (t.hasAttribute('data-step')) {
        var up = t.getAttribute('data-step') === '1';
        V2.people = Math.max(1, Math.min(50, V2.people + (up ? 1 : -1)));
        draw(up ? (V2.people >= 50 ? 'less' : 'more') : (V2.people <= 1 ? 'more' : 'less'));
      } else if (t.hasAttribute('data-item')) {
        V2.sel = t.getAttribute('data-item');
        track('picker_item', { slug: SLUG, need: V2.need, item: V2.sel });
        draw('it-' + V2.sel);
      } else if (t.classList.contains('nwv2-go')) {
        V2.go('box');
      }
    });
    draw();
    // On a phone the bar at the bottom shows whenever the box's own
    // button is off screen, and says the same thing.
    if (bar && window.IntersectionObserver) {
      new IntersectionObserver(function (es) {
        var e = es[es.length - 1];
        var go = box.querySelector('.nwv2-go');
        bar.classList.toggle('on', !e.isIntersecting);
        if (!go) return;
      }, { threshold: 0 }).observe(box);
    }
  }

  function v2Nearby() {
    if (document.querySelector('.nwv2-nearby')) return;
    var host = document.querySelector('.left-column .div-block-80');
    if (!host) return;
    nearbyList().then(function (list) {
      if (!Array.isArray(list) || !list.length || document.querySelector('.nwv2-nearby')) return;
      var loc = document.querySelector('.location-div');
      var area = loc ? String(loc.textContent || '').split(',')[0].replace(/\s+/g, ' ').trim() : '';
      var sec = document.createElement('section');
      sec.className = 'nwv2-sec nwv2-nearby';
      sec.setAttribute('aria-label', 'Other spaces nearby');
      var h = '<h2>' + esc(area && area.length < 40 ? 'Also in ' + area : 'Also nearby') + '</h2><div class="nwv2-near">';
      list.forEach(function (s) {
        var m = Number(s.metres);
        // The distance says what it is measured from (Jonathan, 26 Nov
        // 2026: "is that in context of the listing page? unclear").
        var away = isFinite(m) ? (m < 1000 ? Math.max(50, Math.round(m / 10) * 10) + ' m' : (m / 1000).toFixed(1).replace(/\.0$/, '') + ' km') + ' from this space' : '';
        var rate = s.rating ? '<span class="nwv2-rate"><i aria-hidden="true">\u2605</i> ' + esc(String(s.rating)) + (s.reviews ? ' (' + esc(String(s.reviews)) + ')' : '') + ' on Google</span>' : '';
        var price = nearPrice(s.prices);
        h += '<a class="nwv2-card" href="/coworking/' + esc(s.slug) + '" data-slug="' + esc(s.slug) + '">' +
          '<div class="nwv2-pic" aria-hidden="true"></div><div class="nwv2-tx"><b>' + esc(s.name) + '</b>' +
          rate + (away ? '<span>' + esc(away) + '</span>' : '') + (price ? '<span class="nwv2-cp">' + esc(price) + '</span>' : '') + '</div></a>';
      });
      sec.innerHTML = h + '</div>';
      var how = host.querySelector('.nwv2-how');
      if (how) host.insertBefore(sec, how.nextSibling); else host.appendChild(sec);
      if (V2.place) V2.place();
      sec.addEventListener('click', function (e) {
        var a = e.target.closest && e.target.closest('a.nwv2-card');
        if (a) track('nearby_click', { slug: SLUG, to: a.getAttribute('data-slug') });
      });
      // Each card's photo is that page's own share picture, fetched only
      // when the section comes near the screen.
      var load = function () {
        [].slice.call(sec.querySelectorAll('a.nwv2-card')).forEach(function (a) {
          fetch('/coworking/' + a.getAttribute('data-slug')).then(function (r) { return r.ok ? r.text() : ''; }).then(function (t) {
            var mm = /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i.exec(t || '') ||
              /<meta[^>]+content="([^"]+)"[^>]+property="og:image"/i.exec(t || '');
            if (mm && /^https:\/\//i.test(mm[1])) a.querySelector('.nwv2-pic').style.backgroundImage = 'url("' + mm[1].replace(/"/g, '%22') + '")';
          }).catch(function () {});
        });
      };
      if (window.IntersectionObserver) {
        var io = new IntersectionObserver(function (es) {
          if (es.some(function (x) { return x.isIntersecting; })) { io.disconnect(); load(); }
        }, { rootMargin: '600px 0px' });
        io.observe(sec);
      } else load();
    }).catch(function () {});
  }

  function v2Claim() {
    if (document.querySelector('.nwv2-claim')) return;
    var host = document.querySelector('.left-column .div-block-80');
    var link = document.querySelector('.claim-banner a[href], .claim-line a[href], .claim-line-sidebar a[href]');
    if (!host || !link) return;
    var p = document.createElement('p');
    p.className = 'nwv2-claim';
    p.innerHTML = 'Run this space? <a href="' + esc(link.getAttribute('href')) + '">Claim it for free</a>';
    host.appendChild(p);
  }

  // ------------------------------------------- new page, step 3 (preview)
  // Photos as a grid with "Show all N photos", the tags as a "What's
  // here" list, and on a computer the "What do you need?" box fixed on
  // the right while the page scrolls.
  function v2Amen() {
    var box = document.querySelector('.left-column .modal-filtertag-div');
    if (!box || box.classList.contains('nwv2-amen')) return;
    var tags = [].slice.call(box.querySelectorAll('.modal-filtertag-tag')).filter(function (t) {
      return !t.classList.contains('w-condition-invisible') && t.style.display !== 'none';
    });
    // With no tags at all, the lone "Add a tag" box is left out too.
    if (!tags.length) { box.style.display = 'none'; return; }
    box.classList.add('nwv2-amen');
    var h = document.createElement('h2');
    h.className = 'nwv2-h';
    h.textContent = 'What’s here';
    box.parentNode.insertBefore(h, box);
    // "Add a tag" is something a visitor can do, not something the space
    // has, so it leaves the list and sits as a quiet link in a row of
    // its own under it, beside the button (Jonathan, 26 Nov 2026: "a
    // bit close and out of place").
    var row = document.createElement('div');
    row.className = 'nwv2-amen-row';
    box.parentNode.insertBefore(row, box.nextSibling);
    var add = box.querySelector('.modal-filtertag-tag-empty');
    if (add) row.appendChild(add);
    // As tags they are compact, so all of them show and there is no
    // "Show all" button (26 Nov 2026).
    box.classList.add('all');
    row.classList.add('all');
  }

  function v2Photos(space) {
    if (document.querySelector('.nwv2-all-ph')) return;
    var list = [], seen = {};
    [].slice.call(document.querySelectorAll('.gallery__component img.gallery__image, .image-div-mobile .w-slide img')).forEach(function (im) {
      var s = im.getAttribute('src') || '';
      if (!/^https:\/\//i.test(s) || seen[s]) return;
      if (im.classList.contains('w-dyn-bind-empty') || (im.closest && im.closest('.w-condition-invisible'))) return;
      seen[s] = 1;
      list.push(s);
    });
    if (list.length < 2) return;
    var name = space || 'this space';
    var view = null, last = null;
    var shut = function () {
      if (!view) return;
      view.parentNode.removeChild(view);
      view = null;
      document.documentElement.classList.remove('nwv2-lock');
      document.removeEventListener('keydown', onKey);
      if (last && last.focus) { try { last.focus({ preventScroll: true }); } catch (e) {} }
    };
    var close = function () {
      // Opening added a step to the browser's history, so the phone's
      // back button closes the photos; closing by hand takes it back.
      if (history.state && history.state.nwv2 === 'photos') history.back(); else shut();
    };
    var onKey = function (e) { if (e.key === 'Escape') close(); };
    window.addEventListener('popstate', shut);
    var open = function (at, from) {
      if (view) return;
      last = document.activeElement;
      view = document.createElement('div');
      view.className = 'nwv2-view';
      view.setAttribute('role', 'dialog');
      view.setAttribute('aria-modal', 'true');
      view.setAttribute('aria-label', 'Photos of ' + name);
      var h = '<div class="nwv2-view-top"><b>' + (space ? esc(space) + ', ' : '') + list.length + ' photos</b><button type="button">Close</button></div><div class="nwv2-view-list">';
      list.forEach(function (s, i) {
        h += '<img src="' + esc(s) + '" alt="' + esc(name) + ', photo ' + (i + 1) + '" loading="' + (i === at ? 'eager' : 'lazy') + '" width="1360" height="1020">';
      });
      view.innerHTML = h + '</div>';
      document.body.appendChild(view);
      document.documentElement.classList.add('nwv2-lock');
      var btn = view.querySelector('button');
      btn.addEventListener('click', close);
      document.addEventListener('keydown', onKey);
      try { history.pushState({ nwv2: 'photos' }, ''); } catch (e) {}
      try { btn.focus({ preventScroll: true }); } catch (e) { btn.focus(); }
      if (at > 0) { var im = view.querySelectorAll('img')[at]; if (im) im.scrollIntoView(); }
      track('photos_open', { slug: SLUG, from: from, count: list.length });
    };
    var label = 'Show all ' + list.length + ' photos';
    // Computer: the page's own grid, with the button on it.
    var grid = document.querySelector('.gallery__component');
    if (grid) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'nwv2-all-ph';
      b.textContent = label;
      b.addEventListener('click', function () { open(0, 'button'); });
      grid.appendChild(b);
      grid.addEventListener('click', function (e) {
        var a = e.target.closest && e.target.closest('a.w-lightbox');
        if (!a) return;
        e.preventDefault();
        e.stopPropagation();
        var im = a.querySelector('img'), at = im ? list.indexOf(im.getAttribute('src')) : 0;
        open(at < 0 ? 0 : at, 'grid');
      }, true);
    }
    // Phone: one large photo and two small ones instead of the slider.
    var mob = document.querySelector('.image-div-mobile');
    if (mob && list.length >= 3) {
      var g = document.createElement('div');
      g.className = 'nwv2-ph';
      var hh = '';
      for (var i = 0; i < 3; i++) {
        hh += '<button type="button" class="t" data-i="' + i + '" aria-label="' + esc(name) + ', photo ' + (i + 1) + ' of ' + list.length +
          '" style="background-image:url(&quot;' + esc(list[i]) + '&quot;)"></button>';
      }
      g.innerHTML = hh + '<button type="button" class="nwv2-all-ph" data-i="0">' + label + '</button>';
      g.addEventListener('click', function (e) {
        var t = e.target.closest && e.target.closest('button');
        if (t) open(Number(t.getAttribute('data-i')) || 0, 'phone');
      });
      mob.appendChild(g);
      document.body.classList.add('nwv2-hasph');
    }
  }

  // Computer: the box moves to the right-hand column and stays in view
  // while the page scrolls; the week of hours it replaces there moves
  // into the page, and "Also in <area>" runs the full width underneath.
  // The phone map is loaded lazily by the browser, so jumping to the hours
  // with "See all hours" landed on an empty white block where the map was
  // still to come (Jonathan, 26 Nov 2026). It now starts loading well
  // before it scrolls into view, and shows as a grey block until it has.
  function v2MapSoon() {
    var f = document.querySelector('.map-div-mobile iframe');
    if (!f || f.getAttribute('data-nwv2')) return;
    f.setAttribute('data-nwv2', '1');
    var go = function () {
      if (f.getAttribute('loading') !== 'lazy') return;
      f.setAttribute('loading', 'eager');
      var src = f.getAttribute('src');
      if (src) f.setAttribute('src', src);
    };
    V2.map = go;
    if (!window.IntersectionObserver) { go(); return; }
    var io = new IntersectionObserver(function (es) {
      if (es[es.length - 1].isIntersecting) { io.disconnect(); go(); }
    }, { rootMargin: '1200px 0px' });
    io.observe(f.parentNode);
  }

  function v2Wide() {
    var side = document.querySelector('.listings-5th-col.directory');
    var wrapper = document.querySelector('.listing-wrapper');
    var host = document.querySelector('.left-column .div-block-80');
    var pick = document.querySelector('.nwv2-pick');
    if (!side || !wrapper || !host || !pick || !window.matchMedia || document.querySelector('.nwv2-stick')) return;
    if (side.parentNode !== wrapper) return;
    var stick = document.createElement('div');
    stick.className = 'nwv2-stick';
    var inner = document.createElement('div');
    inner.className = 'nwv2-stick-in';
    stick.appendChild(inner);
    side.insertBefore(stick, side.firstChild);
    // The hours card and the two round links, into the page.
    var card = document.createElement('div');
    card.className = 'nwv2-hrs-card';
    card.id = 'nwv2-hours';
    [].slice.call(side.children).forEach(function (c) {
      if (!c.classList || !c.classList.contains('place_wrapper')) return;
      // A week with no hours in it is not shown as an empty box
      // (Jonathan, 26 Nov 2026, Living On Air Kertasari).
      var week = c.querySelector('.wifi-openinghours-quickstack-5th');
      if (week) {
        var cells = week.querySelectorAll('.w-layout-cell'), any = false;
        for (var i = 1; i < cells.length && i < 14; i += 2) {
          if (/\d|closed|open/i.test(cells[i].textContent || '')) any = true;
        }
        if (!any) { c.style.display = 'none'; return; }
      }
      card.appendChild(c);
    });
    var before = host.querySelector('section.nwp') || host.querySelector('.nwv2-how');
    if (card.children.length) { if (before) host.insertBefore(card, before); else host.appendChild(card); }
    // The map, small, with the address and directions under it.
    var map = host.querySelector('.map-div-main'), mapHome = null, mapCard = null;
    if (map && map.parentNode === host) {
      mapHome = document.createComment('map');
      host.insertBefore(mapHome, map);
      mapCard = document.createElement('div');
      mapCard.className = 'nwv2-mapcard';
      var foot = document.createElement('div');
      foot.className = 'nwv2-mapfoot';
      foot.innerHTML = (V2.addr ? '<span>' + esc(V2.addr) + '</span>' : '') +
        (V2.dir ? '<a class="nwv2-btn2" href="' + esc(V2.dir) + '" target="_blank" rel="noopener">Get directions</a>' : '');
      if (foot.children.length) mapCard.appendChild(foot);
      foot.addEventListener('click', function (e) {
        if (e.target.closest && e.target.closest('a')) track('directions_tap', { slug: SLUG, from: 'mapcard' });
      });
      // The week of hours and the space's website live in the same card
      // as the map, as plain rows, instead of a separate box and two
      // round icons (Jonathan, 26 Nov 2026: "the opening hours looks
      // misplaced, needs to be integrated better").
      var wk = card.querySelector('.wifi-openinghours-quickstack-5th');
      var wc = wk ? wk.querySelectorAll('.w-layout-cell') : [];
      if (wc.length >= 14) {
        var rows = '';
        for (var d = 0; d < 7; d++) {
          var dn = String(wc[d * 2].textContent || '').replace(/\s+/g, ' ').trim();
          var dv = String(wc[d * 2 + 1].textContent || '').replace(/\s+/g, ' ').trim();
          if (dn && dv) rows += '<div class="r"><span>' + esc(dn) + '</span><span>' + esc(dv) + '</span></div>';
        }
        if (rows) {
          var hb = document.createElement('div');
          hb.className = 'nwv2-hrs';
          hb.innerHTML = '<b class="h">Opening hours</b>' + rows;
          mapCard.appendChild(hb);
        }
      }
      var site = card.querySelector('.modal-link-circles-container-5th a[href]');
      var sh = site ? String(site.getAttribute('href') || '') : '';
      if (/^https?:\/\//i.test(sh) && !MAPS.test(sh)) {
        var host2 = '';
        try { host2 = new URL(sh).hostname.replace(/^www\./i, ''); } catch (e) {}
        if (host2) {
          var sa = document.createElement('a');
          sa.className = 'nwv2-site';
          sa.href = sh;
          sa.target = '_blank';
          sa.rel = site.getAttribute('rel') || 'noopener';
          sa.innerHTML = '<span>' + esc(host2) + '</span><span aria-hidden="true">\u2197</span>';
          sa.setAttribute('aria-label', 'Website of this space, ' + host2);
          sa.addEventListener('click', function () { track('website_tap', { slug: SLUG, from: 'infocard' }); });
          mapCard.appendChild(sa);
        }
      }
      document.body.classList.add('nwv2-info');
    }
    // The name and fact lines run the full width above the two columns
    // (Jonathan, 26 Nov 2026: "the photos might not be big enough"; the
    // main one was 324px wide on a laptop).
    var lc = document.querySelector('.left-column');
    var top = lc ? lc.querySelector('.div-block-136') : null;
    var topHome = top ? top.parentNode : null;
    var head = null;
    if (top && topHome) {
      head = document.createElement('div');
      head.className = 'nwv2-head';
    }
    // The banners stay where they are, in the side column under the
    // card (Jonathan, 26 Nov 2026: "absolutely no" to a row of banners
    // in the page).
    document.body.classList.add('nwv2-wide');
    var mq = window.matchMedia('(min-width:992px)');
    // The SafetyWing banner: the site's own square one below 992px, the
    // wide one at the full width of this column from 992px up.
    var SW_WIDE = 'https://cdn.prod.website-files.com/64b6780f84d27e4bfd91f2d6/6b082a12e4cbe2034361b684_0002-1992240321205237671.jpeg';
    var swImg = side.querySelector('.w-dyn-item a[href*="safetywing.com"] img');
    var swItem = swImg && swImg.closest ? swImg.closest('.w-dyn-item') : null;
    var swOld = swImg ? { src: swImg.getAttribute('src'), srcset: swImg.getAttribute('srcset'), sizes: swImg.getAttribute('sizes') } : null;
    var swSet = function (wide) {
      if (!swImg || !swItem) return;
      if (wide === swItem.classList.contains('nwv2-widead')) return;
      swItem.classList.toggle('nwv2-widead', wide);
      if (wide) {
        swImg.removeAttribute('srcset');
        swImg.removeAttribute('sizes');
        swImg.setAttribute('src', SW_WIDE);
      } else {
        if (swOld.srcset) swImg.setAttribute('srcset', swOld.srcset);
        if (swOld.sizes) swImg.setAttribute('sizes', swOld.sizes);
        swImg.setAttribute('src', swOld.src);
      }
    };
    var place = function () {
      var near = document.querySelector('.nwv2-nearby');
      var claim = document.querySelector('.nwv2-claim');
      swSet(mq.matches);
      if (mq.matches) {
        if (pick.parentNode !== inner) inner.insertBefore(pick, inner.firstChild);
        if (claim && claim.parentNode !== inner) inner.appendChild(claim);
        if (near && near.parentNode !== wrapper) wrapper.appendChild(near);
        if (head) {
          if (head.parentNode !== wrapper) wrapper.insertBefore(head, wrapper.firstChild);
          if (top.parentNode !== head) head.appendChild(top);
        }
        var after = stick;
        if (mapCard) {
          if (mapCard.parentNode !== side) side.insertBefore(mapCard, after.nextSibling);
          if (map.parentNode !== mapCard) mapCard.insertBefore(map, mapCard.firstChild);
          after = mapCard;
        }
      } else {
        if (mapCard && map.parentNode !== host) {
          host.insertBefore(map, mapHome);
          if (mapCard.parentNode) mapCard.parentNode.removeChild(mapCard);
        }

        if (head && top.parentNode !== topHome) {
          topHome.insertBefore(top, topHome.firstChild);
          if (head.parentNode) head.parentNode.removeChild(head);
        }
        if (pick.parentNode !== host) host.insertBefore(pick, host.firstChild);
        if (claim && claim.parentNode !== host) host.appendChild(claim);
        if (near && near.parentNode !== host) {
          var how = host.querySelector('.nwv2-how');
          if (how) host.insertBefore(near, how.nextSibling); else host.appendChild(near);
        }
      }
    };
    V2.place = function () { place(); if (V2.fit) V2.fit(); };
    V2.place();
    if (mq.addEventListener) mq.addEventListener('change', V2.place); else if (mq.addListener) mq.addListener(V2.place);
    v2TopBar(pick, wrapper);
  }

  // The request follows the visitor down the page on a computer: when
  // the box is out of view, a slim bar under the menu shows the space,
  // the price for what is picked and the same button (Jonathan, 26 Nov
  // 2026: map and hours beside the photos, and the request still
  // following down the page).
  function v2TopBar(pick, wrapper) {
    if (document.querySelector('.nwv2-topbar') || !window.IntersectionObserver) return;
    var h1 = document.querySelector('.div-block-136 h1');
    var name = data && data.space !== 'this space' ? data.space : (h1 ? String(h1.textContent || '').replace(/\s+/g, ' ').trim() : '');
    var bar = document.createElement('div');
    bar.className = 'nwv2-topbar';
    bar.innerHTML = '<div><b class="n">' + esc(name) + '</b><span class="r"><span class="p"></span><button type="button" class="nwv2-go"></button></span></div>';
    document.body.appendChild(bar);
    var btn = bar.querySelector('button'), price = bar.querySelector('.p');
    var sync = function () {
      var go = pick.querySelector('.nwv2-go'), pr = pick.querySelector('.nwv2-pr');
      btn.textContent = go ? go.textContent : 'Send a request';
      price.innerHTML = pr ? pr.innerHTML : '';
    };
    sync();
    if (window.MutationObserver) new MutationObserver(sync).observe(pick, { childList: true });
    btn.addEventListener('click', function () {
      var go = pick.querySelector('.nwv2-go');
      track('topbar_request', { slug: SLUG });
      if (go) go.click();
    });
    var nav = document.querySelector('.w-nav');
    new IntersectionObserver(function (es) {
      var e = es[es.length - 1];
      var on = !e.isIntersecting && e.boundingClientRect.top < 0;
      if (on) {
        // One pixel under the menu's edge, so no sliver of the page shows
        // between the two (Jonathan, 26 Nov 2026).
        bar.style.top = (nav ? Math.floor(nav.getBoundingClientRect().bottom) - 1 : 67) + 'px';
        bar.firstChild.style.maxWidth = Math.round(wrapper.getBoundingClientRect().width) + 'px';
      }
      bar.classList.toggle('on', on);
    }, { threshold: 0 }).observe(pick);
  }

  // A space with no prices on its page still gets the box, so every
  // listing reads the same way: one place to send a request from.
  function v2Ask(space) {
    if (document.querySelector('.nwv2-pick')) return;
    var host = document.querySelector('.left-column .div-block-80');
    var top = document.querySelector('.left-column .buttons-wrapper .research-button');
    if (!host || !top) return;
    var who = space || 'this space';
    var box = document.createElement('section');
    box.className = 'nwv2-pick';
    box.id = 'nwv2-pick';
    box.setAttribute('aria-label', 'Ask for prices');
    box.innerHTML = '<h2>Ask for prices</h2><p class="nwv2-none">We do not have prices for ' + esc(who) +
      ' yet. Send a request, say what you need, and they reply to you by email.</p>' +
      '<button type="button" class="nwv2-go">Send a request</button><ul class="nwv2-sure"><li>' + TICK + 'Free, with no obligation</li><li>' + TICK + 'They reply to you by email</li></ul>';
    host.insertBefore(box, host.firstChild);
    document.body.classList.add('nwv2-haspick');
    box.querySelector('.nwv2-go').addEventListener('click', function () {
      track('picker_request', { slug: SLUG, need: 'ask', people: 1, from: 'box', matched: false });
      (top.querySelector('#research-button-wrapper') || top).click();
    });
  }

  function v2(raw) {
    try {
      v2Styles();
      var top = document.querySelector('.div-block-136');
      if (top) top.classList.add('nwv2');
      var page = document.querySelector('.left-column');
      if (page) page.classList.add('nwv2');
      document.body.classList.add('nwv2');
      var name = data && data.space !== 'this space' ? data.space : (raw.space || '');
      v2Facts(raw);
      v2Photos(name);
      v2Picker();
      if (!document.querySelector('.nwv2-pick')) v2Ask(name);
      v2Amen();
      v2Steps(name);
      v2Nearby();
      v2Claim();
      v2MapSoon();
      v2Wide();
      setTimeout(function () { document.body.classList.add('nwv2-chat'); }, 30000);
      track('listing_v2_preview', { slug: SLUG });
    } catch (e) {}
    preShow();
  }

  function start() {
    if (AREA || FRAMED) return;
    ratingLabel();
    tidyTags();
    hit('view');
    fetch(URL_ + '/rest/v1/rpc/page_prices', {
      method: 'POST',
      headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_slug: SLUG })
    }).then(function (r) { return r.ok ? r.json() : null; })
      .then(function (raw) {
        if (raw && raw.closed) showClosed(raw.closed);
        if (raw && raw.show) {
          SHUT = Array.isArray(raw.closed_days) ? raw.closed_days.map(Number) : [];
          data = shape(raw);
          if (data.groups.length && mount()) { smallHeading(); jumpLink(); foldHours(); requestBar(); addressLine(raw); fromLink(); }
        }
        if (PREVIEW) v2(raw || {});
      })
      .catch(function () { preShow(); });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();

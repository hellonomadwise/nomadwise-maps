// The Coworking Global page on nomadwise.io (/coworking-global), 23 Nov
// 2026. Loaded from an embed at the bottom of the page's new section.
//
// The cities and countries are Webflow collection lists (Regions and
// Countries with Spaces above 0, most first; the numbers come from
// scripts/webflow_counts.py), so the page works and is read by Google
// without this file. This file adds what Webflow cannot do:
//  - the line "1,059 spaces in 94 cities" and the quick city links
//  - search across cities, countries and areas (areas from Nomad Maps:
//    webflow_locations with at least one live space, readable by anyone)
//  - Near me: the nearest city with spaces, from the browser's location
//  - continent buttons over the countries, and Show all buttons
//  - PostHog events, so the page can be judged before and after:
//    cg_view, cg_search, cg_search_pick (kind city, country or area),
//    cg_near_me, cg_city_click, cg_country_click, cg_quick_click,
//    cg_continent_filter, cg_show_more, cg_list_space_click.
// If anything here fails, the page simply shows the full lists.
(function () {
  var URL_ = '__NW_SUPABASE_URL__';
  var KEY = '__NW_SUPABASE_KEY__';
  var page = document.querySelector('[data-cg=page]');
  if (!page || page.getAttribute('data-cg-on')) return;
  page.setAttribute('data-cg-on', '1');

  function track(ev, props) {
    try { if (window.posthog && window.posthog.capture) window.posthog.capture(ev, props || {}); } catch (e) {}
  }
  function txt(el, sel) {
    var x = sel ? el.querySelector(sel) : el;
    return x ? (x.textContent || '').replace(/\s+/g, ' ').trim() : '';
  }
  function num(s) { var n = parseFloat(String(s).replace(/[^0-9.\-]/g, '')); return isNaN(n) ? null : n; }
  function fmt(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ','); }
  function norm(s) {
    s = String(s || '').toLowerCase();
    try { s = s.normalize('NFD').replace(/[̀-ͯ]/g, ''); } catch (e) {}
    return s.replace(/[^a-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim();
  }
  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function continent(v) {
    v = norm(v);
    if (!v) return '';
    if (v.indexOf('asia') >= 0) return 'Asia';
    if (v.indexOf('america') >= 0) return 'Americas';
    if (v === 'europe') return 'Europe';
    if (v === 'africa') return 'Africa';
    if (v === 'middle east') return 'Middle East';
    if (v === 'oceania') return 'Oceania';
    return '';
  }
  function flagOf(el) {
    var img = el.querySelector('img[data-cg=flag]');
    if (!img || /w-dyn-bind-empty/.test(img.className) || !img.getAttribute('src') || /placeholder/.test(img.getAttribute('src'))) return '';
    return img.getAttribute('src');
  }
  function path(a) { try { return new URL(a.href, location.href).pathname; } catch (e) { return a.getAttribute('href') || ''; } }

  // ---- each card's own address ----
  // Webflow renders the card links as /region and /country; the card
  // carries its item slug in data-slug, so set the full address here.
  [].slice.call(page.querySelectorAll('a[data-cg=city][data-slug], a[data-cg=land][data-slug]')).forEach(function (a) {
    var slug = (a.getAttribute('data-slug') || '').trim();
    if (slug) a.setAttribute('href', (a.getAttribute('data-cg') === 'city' ? '/region/' : '/country/') + slug);
  });

  // ---- read the lists Webflow rendered ----
  var cities = [].slice.call(page.querySelectorAll('a[data-cg=city]')).map(function (a, i) {
    return {
      el: a, item: a.closest('[role=listitem]') || a, name: txt(a, '[data-cg=name]'),
      country: txt(a, '[data-cg=country]'), n: num(txt(a, '[data-cg=n]')) || 0,
      lat: num(a.getAttribute('data-lat')), lng: num(a.getAttribute('data-lng')),
      cont: continent(a.getAttribute('data-cont')), href: path(a), flag: flagOf(a), pos: i + 1
    };
  }).filter(function (c) { return c.name && /^\/(region|country)\/./.test(c.href); });
  var lands = [].slice.call(page.querySelectorAll('a[data-cg=land]')).map(function (a, i) {
    return {
      el: a, item: a.closest('[role=listitem]') || a, name: txt(a, '[data-cg=name]'),
      n: num(txt(a, '[data-cg=n]')) || 0, cont: continent(a.getAttribute('data-cont')),
      href: path(a), flag: flagOf(a), pos: i + 1
    };
  }).filter(function (c) { return c.name && /^\/(region|country)\/./.test(c.href); });
  var flagByCountry = {};
  lands.forEach(function (l) { if (l.flag) flagByCountry[l.name] = l.flag; });
  cities.forEach(function (c) { if (!c.flag && flagByCountry[c.country]) c.flag = flagByCountry[c.country]; });

  // Numbers as "1,059 spaces", and "1 space" for one.
  [].slice.call(page.querySelectorAll('[data-cg=count]')).forEach(function (box) {
    var nEl = box.querySelector('[data-cg=n]');
    var n = nEl ? num(nEl.textContent) : null;
    if (n === null) return;
    nEl.textContent = fmt(n);
    var word = nEl.nextElementSibling;
    if (word && /^spaces?$/.test(txt(word))) word.textContent = n === 1 ? 'space' : 'spaces';
  });

  var total = lands.reduce(function (s, l) { return s + l.n; }, 0);
  var kick = page.querySelector('[data-cg=kick]');
  if (kick && total && cities.length) {
    kick.textContent = fmt(total) + ' cafes and coworking spaces in ' + cities.length + ' cities';
  }
  var heading = page.querySelector('[data-cg=countries] h2');
  if (heading && lands.length) heading.textContent = 'All ' + lands.length + ' countries';

  // ---- quick links: the four biggest cities ----
  var quick = page.querySelector('[data-cg=quick]');
  if (quick) {
    cities.slice(0, 4).forEach(function (c) {
      var a = document.createElement('a');
      a.className = 'cg-chip';
      a.href = c.href;
      a.textContent = c.name;
      a.setAttribute('data-cg-quick', c.name);
      quick.appendChild(a);
    });
  }

  // ---- Show all ----
  function showMore(list, first, label, where) {
    if (list.length <= first) return null;
    list.slice(first).forEach(function (x) { x.item.classList.add('cg-cut'); });
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'cg-more';
    b.textContent = label;
    b.addEventListener('click', function () {
      list.forEach(function (x) { x.item.classList.remove('cg-cut'); });
      b.remove();
      track('cg_show_more', { list: where });
    });
    return b;
  }
  var phone = window.matchMedia && window.matchMedia('(max-width: 767px)').matches;
  var citySec = page.querySelector('[data-cg=cities]');
  var cityBtn = showMore(cities, 8, 'Show all ' + cities.length + ' cities', 'cities');
  if (cityBtn && citySec) citySec.appendChild(cityBtn);
  var landSec = page.querySelector('[data-cg=countries]');
  var landBtn = phone ? showMore(lands, 10, 'Show all ' + lands.length + ' countries', 'countries') : null;
  if (landBtn && landSec) landSec.appendChild(landBtn);

  // ---- continent buttons ----
  var pills = page.querySelector('.cg-pills');
  if (pills && lands.length) {
    var order = ['Asia', 'Europe', 'Africa', 'Middle East', 'Americas', 'Oceania'];
    var sums = {};
    lands.forEach(function (l) { if (l.cont) sums[l.cont] = (sums[l.cont] || 0) + l.n; });
    var groups = [{ label: 'All', key: '', n: total }].concat(order.filter(function (k) { return sums[k]; }).map(function (k) {
      return { label: k, key: k, n: sums[k] };
    }));
    groups.forEach(function (g) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'cg-pill';
      b.setAttribute('aria-pressed', g.key ? 'false' : 'true');
      b.innerHTML = esc(g.label) + ' <span>' + fmt(g.n) + '</span>';
      b.addEventListener('click', function () {
        [].slice.call(pills.children).forEach(function (x) { x.setAttribute('aria-pressed', x === b ? 'true' : 'false'); });
        lands.forEach(function (l) {
          l.item.classList.toggle('cg-hide', !!g.key && l.cont !== g.key);
          if (g.key) l.item.classList.remove('cg-cut');
        });
        if (landBtn && landBtn.parentNode) landBtn.style.display = g.key ? 'none' : '';
        if (!g.key && landBtn && landBtn.parentNode) lands.slice(10).forEach(function (l) { l.item.classList.add('cg-cut'); });
        track('cg_continent_filter', { continent: g.label, countries: lands.filter(function (l) { return !g.key || l.cont === g.key; }).length });
      });
      pills.appendChild(b);
    });
  }

  // ---- areas from Nomad Maps (loaded on first use of the search box) ----
  var areas = null, areasLoading = null;
  function loadAreas() {
    if (areas || areasLoading || !URL_ || URL_.indexOf('__') === 0) return areasLoading;
    var hdr = { apikey: KEY, Authorization: 'Bearer ' + KEY };
    function get(q) {
      return fetch(URL_ + '/rest/v1/' + q, { headers: hdr }).then(function (r) { return r.ok ? r.json() : []; });
    }
    function allLive(offset, acc) {
      return get('venues?select=webflow_location_id&website_status=eq.released&website_retired_at=is.null' +
        '&webflow_slug=not.is.null&webflow_location_id=not.is.null&order=id&limit=1000&offset=' + offset)
        .then(function (rows) {
          acc = acc.concat(rows || []);
          return rows && rows.length === 1000 ? allLive(offset + 1000, acc) : acc;
        });
    }
    areasLoading = Promise.all([
      get('webflow_locations?select=id,name,slug,region_id&sitemap_added_at=not.is.null&limit=2000'),
      get('webflow_regions?select=id,name&limit=2000'),
      allLive(0, [])
    ]).then(function (r) {
      var regionName = {};
      (r[1] || []).forEach(function (x) { regionName[x.id] = (x.name || '').split(',')[0].trim(); });
      var per = {};
      (r[2] || []).forEach(function (v) { per[v.webflow_location_id] = (per[v.webflow_location_id] || 0) + 1; });
      var byCity = {};
      cities.forEach(function (c) { byCity[c.name] = c; });
      areas = (r[0] || []).filter(function (l) { return per[l.id] && l.slug && l.name; }).map(function (l) {
        var city = regionName[l.region_id] || '';
        var c = byCity[city];
        return { name: l.name, city: city, n: per[l.id], href: '/locations/' + l.slug, flag: c ? c.flag : '' };
      }).filter(function (a) { return norm(a.name) !== norm(a.city); });
      return areas;
    }).catch(function () { areas = []; return areas; });
    return areasLoading;
  }

  // ---- search ----
  var form = page.querySelector('form.cg-form');
  var input = form && form.querySelector('input');
  var sug = form && form.querySelector('.cg-sug');
  var msg = page.querySelector('.cg-msg');
  var results = [], active = -1, lastQ = '';

  function score(name, q) {
    var n = norm(name);
    if (n === q) return 0;
    if (n.indexOf(q) === 0) return 1;
    if ((' ' + n).indexOf(' ' + q) >= 0) return 2;
    if (n.indexOf(q) >= 0) return 3;
    return -1;
  }
  function find(qRaw) {
    var q = norm(qRaw);
    if (!q) return [];
    var out = [];
    cities.forEach(function (c) {
      var s = score(c.name, q);
      if (s >= 0) out.push({ kind: 'city', s: s, w: c.n, name: c.name, sub: c.country, n: c.n, href: c.href, flag: c.flag });
    });
    lands.forEach(function (l) {
      var s = score(l.name, q);
      if (s >= 0) out.push({ kind: 'country', s: s, w: l.n, name: l.name, sub: 'Country', n: l.n, href: l.href, flag: l.flag });
    });
    (areas || []).forEach(function (a) {
      var s = score(a.name, q);
      if (s >= 0) out.push({ kind: 'area', s: s + 0.5, w: a.n, name: a.name, sub: a.city, n: a.n, href: a.href, flag: a.flag });
    });
    out.sort(function (a, b) { return a.s - b.s || b.w - a.w; });
    return out.slice(0, 8);
  }
  function render() {
    if (!sug) return;
    var q = input.value.trim();
    if (!q) { sug.hidden = true; sug.innerHTML = ''; input.setAttribute('aria-expanded', 'false'); return; }
    results = find(q);
    active = results.length ? 0 : -1;
    if (!results.length) {
      sug.innerHTML = '<div class="cg-none">' + (areasLoading && !areas ? 'Searching…' :
        'No spaces listed there yet. Try a city or country, like Lisbon or Thailand.') + '</div>';
    } else {
      sug.innerHTML = results.map(function (r, i) {
        return '<a class="cg-opt" role="option" id="cg-opt-' + i + '" aria-selected="' + (i === active) + '" href="' + esc(r.href) +
          '" data-i="' + i + '">' + (r.flag ? '<img src="' + esc(r.flag) + '" alt="">' : '<span class="cg-noflag"></span>') +
          '<span class="cg-ot"><b>' + esc(r.name) + '</b><em>' + esc(r.sub) + '</em></span><small>' +
          fmt(r.n) + (r.n === 1 ? ' space' : ' spaces') + '</small></a>';
      }).join('');
    }
    sug.hidden = false;
    input.setAttribute('aria-expanded', 'true');
    input.setAttribute('aria-activedescendant', active >= 0 ? 'cg-opt-' + active : '');
  }
  function move(d) {
    if (!results.length) return;
    active = (active + d + results.length) % results.length;
    [].slice.call(sug.querySelectorAll('.cg-opt')).forEach(function (o, i) { o.setAttribute('aria-selected', i === active ? 'true' : 'false'); });
    input.setAttribute('aria-activedescendant', 'cg-opt-' + active);
  }
  function go(r, how) {
    track('cg_search_pick', { query: input.value.trim().slice(0, 60), kind: r.kind, name: r.name, how: how, position: results.indexOf(r) + 1 });
    location.href = r.href;
  }
  if (form && input && sug) {
    input.setAttribute('role', 'combobox');
    input.setAttribute('aria-autocomplete', 'list');
    input.setAttribute('aria-expanded', 'false');
    input.setAttribute('aria-controls', 'cg-sug');
    sug.id = 'cg-sug';
    input.addEventListener('focus', function () {
      var p = loadAreas();
      if (p) p.then(function () { if (input.value.trim()) render(); });
    });
    input.addEventListener('input', render);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
      else if (e.key === 'Escape') { sug.hidden = true; input.setAttribute('aria-expanded', 'false'); }
    });
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var q = input.value.trim();
      if (!q) { input.focus(); return; }
      results = find(q);
      track('cg_search', { query: q.slice(0, 60), results: results.length });
      lastQ = q;
      if (results.length) go(results[active >= 0 && active < results.length ? active : 0], 'enter');
      else render();
    });
    sug.addEventListener('mousedown', function (e) { e.preventDefault(); });
    sug.addEventListener('click', function (e) {
      var o = e.target.closest('.cg-opt');
      if (!o) return;
      e.preventDefault();
      var r = results[+o.getAttribute('data-i')];
      if (r) go(r, 'click');
    });
    input.addEventListener('blur', function () {
      setTimeout(function () { sug.hidden = true; input.setAttribute('aria-expanded', 'false'); }, 150);
      var q = input.value.trim();
      if (q && q !== lastQ) { lastQ = q; track('cg_search', { query: q.slice(0, 60), results: find(q).length, left: true }); }
    });
  }

  // ---- Near me ----
  var near = page.querySelector('[data-cg=near]');
  function say(t) { if (msg) msg.textContent = t; }
  if (near) {
    if (!navigator.geolocation) near.style.display = 'none';
    near.addEventListener('click', function () {
      say('Finding the nearest city…');
      navigator.geolocation.getCurrentPosition(function (p) {
        var lat = p.coords.latitude, lng = p.coords.longitude, best = null;
        cities.forEach(function (c) {
          if (c.lat === null || c.lng === null) return;
          var r = Math.PI / 180, dLat = (c.lat - lat) * r, dLng = (c.lng - lng) * r;
          var h = Math.sin(dLat / 2) * Math.sin(dLat / 2) + Math.cos(lat * r) * Math.cos(c.lat * r) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
          var km = 12742 * Math.asin(Math.sqrt(h));
          if (!best || km < best.km) best = { c: c, km: km };
        });
        if (!best) { say('Sorry, that did not work. Search for a city instead.'); return; }
        track('cg_near_me', { result: 'found', city: best.c.name, km: Math.round(best.km) });
        say('Nearest city with spaces: ' + best.c.name + (best.km > 30 ? ', ' + fmt(Math.round(best.km)) + ' km away' : ''));
        setTimeout(function () { location.href = best.c.href; }, best.km > 30 ? 900 : 200);
      }, function (err) {
        track('cg_near_me', { result: err && err.code === 1 ? 'denied' : 'error' });
        say(err && err.code === 1 ? 'Location is turned off for this site. Search for a city instead.' :
          'We could not find your location. Search for a city instead.');
      }, { timeout: 10000, maximumAge: 600000 });
    });
  }

  // ---- clicks ----
  page.addEventListener('click', function (e) {
    var a = e.target.closest('a');
    if (!a || !page.contains(a)) return;
    var c, l;
    if (a.getAttribute('data-cg') === 'city') {
      c = cities.filter(function (x) { return x.el === a; })[0];
      if (c) track('cg_city_click', { city: c.name, country: c.country, position: c.pos, spaces: c.n });
    } else if (a.getAttribute('data-cg') === 'land') {
      l = lands.filter(function (x) { return x.el === a; })[0];
      var on = pills && pills.querySelector('[aria-pressed=true]');
      if (l) track('cg_country_click', { country: l.name, position: l.pos, spaces: l.n, continent_filter: on ? txt(on).replace(/[\d,\s]+$/, '') : 'All' });
    } else if (a.hasAttribute('data-cg-quick')) {
      track('cg_quick_click', { city: a.getAttribute('data-cg-quick') });
    } else if (a.classList.contains('cg-btn')) {
      track('cg_list_space_click', {});
    }
  });

  track('cg_view', { version: '2026-11-redesign', cities: cities.length, countries: lands.length, spaces: total });
})();

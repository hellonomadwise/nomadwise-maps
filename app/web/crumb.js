// Breadcrumb on nomadwise.io country, region, location and listing pages
// (22 Nov 2026). Loaded by the NomadwiseCrumb site script in Webflow.
//
// Before: every step was a dropdown with no visible arrow, so clicking
// "London" on the Shoreditch page opened a list of English cities instead
// of going to London, and listing pages left out the area.
// Now: every step is a plain link up to its page; only the last step (the
// page you are on) opens a switcher, with a search box when the list is
// long. Listing pages get their area (from Nomad Maps: venues ->
// webflow_locations, both readable by anyone) and end with the space's
// name. The old dropdowns stay in the page, hidden, so nothing else that
// uses them breaks; if anything here fails they simply stay visible.
// Adds BreadcrumbList data for Google.
(function () {
  var URL_ = '__NW_SUPABASE_URL__';
  var KEY = '__NW_SUPABASE_KEY__';
  var CSS = [
    '.nwbc{font:400 13px/1.4 Roboto,system-ui,sans-serif;color:#5B6470;margin:20px 0;position:relative;z-index:20}',
    '.nwbc ol{list-style:none;margin:0;padding:0;display:flex;flex-wrap:wrap;align-items:center;gap:2px}',
    '.nwbc li{display:flex;align-items:center;margin:0}',
    '.nwbc li[hidden],.nwbc-none[hidden]{display:none!important}',
    '.nwbc a.nwbc-l{display:inline-flex;align-items:center;gap:7px;color:#5B6470;text-decoration:none;padding:6px 8px;border-radius:8px;min-height:32px;box-sizing:border-box}',
    '.nwbc a.nwbc-l:hover{background:#F2F3F5;color:#1F2328}',
    '.nwbc .nwbc-s{color:#A3AAB3;width:14px;height:14px;flex:none}',
    '.nwbc .nwbc-b{display:none;width:14px;height:14px;margin-right:-3px}',
    '.nwbc img.nwbc-f{width:20px;height:15px;border-radius:2px;object-fit:cover;box-shadow:0 0 0 .5px #D5D9DE;display:block;flex:none}',
    '.nwbc .nwbc-c{display:inline-flex;align-items:center;gap:7px;color:#1F2328;font:500 13px/1.4 Roboto,system-ui,sans-serif;padding:5px 10px;border-radius:8px;margin-left:4px;min-height:32px;box-sizing:border-box}',
    '.nwbc button.nwbc-c{border:1px solid #E3E5E8;background:#fff;cursor:pointer}',
    '.nwbc button.nwbc-c:hover,.nwbc button.nwbc-c[aria-expanded=true]{border-color:#C9CED4;background:#F7F8F9}',
    '.nwbc .nwbc-car{width:14px;height:14px;color:#5B6470;transition:transform .15s}',
    '.nwbc button[aria-expanded=true] .nwbc-car{transform:rotate(180deg)}',
    '.nwbc-m{position:absolute;top:calc(100% + 6px);left:0;width:280px;max-width:calc(100vw - 32px);background:#fff;border:1px solid #E3E5E8;border-radius:8px;box-shadow:0 8px 24px rgba(31,35,40,.12);padding:8px;box-sizing:border-box}',
    '.nwbc-m[hidden]{display:none}',
    '.nwbc-mh{font-size:12px;color:#7A828C;padding:4px 8px 8px}',
    '.nwbc-m input{width:100%;height:36px;border:1px solid #C9CED4;border-radius:8px;padding:0 10px;font:400 14px Roboto,system-ui,sans-serif;margin:0 0 6px;box-sizing:border-box;color:#1F2328;background:#fff}',
    '.nwbc-m input:focus{outline:none;border-color:#5B6470;box-shadow:0 0 0 3px #EEF0F2}',
    '.nwbc-m ul{list-style:none;margin:0;padding:0;max-height:300px;overflow:auto}',
    '.nwbc-m li{display:block}',
    '.nwbc-m li a{display:flex;align-items:center;gap:8px;width:100%;box-sizing:border-box;padding:8px;border-radius:8px;color:#3A424C;text-decoration:none;font-size:14px}',
    '.nwbc-m li a:hover,.nwbc-m li a:focus{background:#F2F3F5;color:#1F2328;outline:none}',
    '.nwbc-m li a[aria-current]{font-weight:500;color:#1F2328}',
    '.nwbc-none{padding:8px;font-size:13px;color:#7A828C}',
    'html.nwbc-on .product-pagination-wrap,html.nwbc-on .product-pagination-wrap-listings,html.nwbc-on [data-aw=crumb]{display:none!important}',
    '[data-aw] .nwbc{margin:0 0 12px}',
    '@media (max-width:767px){',
    ' .nwbc{margin:4px 0}',
    ' .nwbc li.nwbc-far{display:none}',
    ' .nwbc li.nwbc-par .nwbc-s,.nwbc li.nwbc-par img.nwbc-f{display:none}',
    ' .nwbc li.nwbc-par .nwbc-b{display:block}',
    ' .nwbc .nwbc-c{min-height:40px;padding:8px 12px}',
    ' .nwbc a.nwbc-l{min-height:40px}',
    '}'
  ].join('\n');

  function svg(cls, d) {
    return '<svg class="' + cls + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="' + d + '"/></svg>';
  }
  var CHEV = svg('nwbc-s', 'M9 6l6 6l-6 6');
  var BACK = svg('nwbc-b', 'M15 6l-6 6l6 6');
  var CARET = svg('nwbc-car', 'M6 9l6 6l6 -6');
  function clean(t) { return (t || '').replace(/\s+/g, ' ').trim(); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function kind(h) { var m = (h || '').match(/^\/(country|region|locations)\//); return m ? m[1] : ''; }
  function good(src) { return !!src && src.indexOf('placeholder') < 0; }
  function track(ev, props) { try { if (window.posthog) window.posthog.capture(ev, props); } catch (e) {} }

  function run() {
    if (document.querySelector('.nwbc')) return;
    var path = location.pathname.replace(/\/$/, '');
    var listing = /^\/coworking\//.test(path);
    var area = /^\/workspace\//.test(path);
    var wrap = area ? document.querySelector('[data-aw=crumb]')
      : document.querySelector('.product-pagination-wrap,.product-pagination-wrap-listings');
    if (!wrap) return;
    var steps = [];

    // Area pages (/workspace/, made by scripts/webflow_area_pages.py): the
    // breadcrumb is links and the page's own name, "England / London /
    // Shoreditch / Office space". No switcher: the tabs on the page switch.
    if (area) {
      [].slice.call(wrap.querySelectorAll('a[href]')).forEach(function (a) {
        var h = a.getAttribute('href').replace(/^https?:\/\/[^/]+/, '').replace(/\/$/, '');
        if (kind(h)) steps.push({ name: clean(a.textContent), href: h, opts: [], kind: kind(h) });
      });
      var label = clean(wrap.textContent).split('/').pop().trim();
      var fi = wrap.querySelector('img');
      if (steps.length && label) {
        steps[0].flag = fi ? fi.getAttribute('src') : '';
        steps.push({ name: label, href: path, opts: [], kind: 'area', current: true });
      } else return;
    }

    // The steps, from the old dropdowns: each toggle's name, and its list
    // of links (the names sit beside each link, in .checkbox_label).
    if (!area) [].slice.call(wrap.children).forEach(function (dd) {
      if (!dd.classList.contains('w-dropdown') || getComputedStyle(dd).display === 'none') return;
      var tog = dd.querySelector('.w-dropdown-toggle'), list = dd.querySelector('.w-dropdown-list');
      if (!tog || !list) return;
      // The visible label; a hidden "Heading" placeholder sits beside it.
      var pt = [].filter.call(tog.querySelectorAll('[class*=pagination-text]'), function (x) {
        return getComputedStyle(x).display !== 'none' && clean(x.textContent);
      })[0];
      var name = clean(pt ? pt.textContent : tog.textContent);
      if (!name) return;
      var seen = {}, opts = [];
      [].slice.call(list.querySelectorAll('a[href]')).forEach(function (a) {
        var box = a.parentElement, lb = box.querySelector('.checkbox_label');
        var h = a.getAttribute('href').replace(/^https?:\/\/[^/]+/, '').replace(/\/$/, '');
        var t = clean(lb ? lb.textContent : a.textContent);
        if (!t || !kind(h) || seen[h]) return;
        seen[h] = 1;
        var im = box.querySelector('img');
        opts.push({ name: t.split(',')[0].trim(), full: t, href: h, flag: im ? im.getAttribute('src') : '' });
      });
      var me = null;
      opts.forEach(function (o) { if (o.href === path) me = o; });
      if (!me) opts.forEach(function (o) { if (!me && o.name.toLowerCase() === name.toLowerCase()) me = o; });
      if (!me) return; // a filter, not a step ("All Cities / Areas Selected")
      steps.push({ name: name, href: me.href, flag: me.flag, opts: opts, kind: kind(me.href) });
    });
    if (!steps.length) return;

    if (area) {
      // the steps are complete
    } else if (listing) {
      var h1 = document.querySelector('h1'), t = h1 ? clean(h1.textContent) : '';
      var k = t.lastIndexOf(' in ' + steps[steps.length - 1].name);
      var cur = k > 0 ? t.slice(0, k) : t;
      if (!cur) return;
      steps.push({ name: cur, href: path, opts: [], kind: 'space', current: true });
    } else if (steps[steps.length - 1].href === path) {
      steps[steps.length - 1].current = true;
    } else return;

    var flag = steps[0].flag;
    if (!good(flag)) {
      var pf = document.querySelector('img.icon-country-image-coworking,img[alt^="Flag of"]:not([src*="placeholder"])');
      flag = pf ? pf.getAttribute('src') : '';
    }

    var st = document.createElement('style');
    st.textContent = CSS;
    document.head.appendChild(st);
    var nav = document.createElement('nav');
    nav.className = 'nwbc';
    nav.setAttribute('aria-label', 'Breadcrumb');
    wrap.parentNode.insertBefore(nav, wrap);

    function render() {
      var n = steps.length, ci = n - 1, par = ci - 1, html = '<ol>';
      steps.forEach(function (s, i) {
        var cls = i < par ? 'nwbc-far' : i === par ? 'nwbc-par' : '';
        var sep = i ? CHEV : '';
        var fl = i === 0 && good(flag) ? '<img class="nwbc-f" src="' + esc(flag) + '" alt="" width="20" height="15">' : '';
        var inner;
        if (s.current && s.opts.length > 1) {
          var lab = s.kind === 'country' ? 'Other countries'
            : s.kind === 'region' ? 'Other places in ' + steps[0].name
            : 'Other areas in ' + (steps[i - 1] ? steps[i - 1].name : '');
          inner = '<button type="button" class="nwbc-c" aria-expanded="false" aria-haspopup="true" aria-current="page">' + fl + esc(s.name) + CARET + '</button>' +
            '<div class="nwbc-m" hidden><div class="nwbc-mh">' + esc(lab) + '</div>' +
            (s.opts.length > 12 ? '<input type="search" placeholder="Search ' + s.opts.length + (s.kind === 'country' ? ' countries' : ' places') + '" aria-label="Search">' : '') +
            '<ul>' + s.opts.map(function (o) {
              return '<li><a href="' + esc(o.href) + '"' + (o.href === path ? ' aria-current="page"' : '') + '>' +
                (s.kind === 'country' && good(o.flag) ? '<img class="nwbc-f" src="' + esc(o.flag) + '" alt="" width="20" height="15">' : '') +
                esc(o.name) + '</a></li>';
            }).join('') + '</ul><div class="nwbc-none" hidden>No matches</div></div>';
        } else if (s.current) {
          inner = '<span class="nwbc-c" aria-current="page">' + fl + esc(s.name) + '</span>';
        } else {
          inner = '<a class="nwbc-l" href="' + esc(s.href) + '">' + BACK + fl + esc(s.name) + '</a>';
        }
        html += '<li' + (cls ? ' class="' + cls + '"' : '') + '>' + sep + inner + '</li>';
      });
      nav.innerHTML = html + '</ol>';
      wire();
      schema();
    }

    function wire() {
      var btn = nav.querySelector('button.nwbc-c'), menu = nav.querySelector('.nwbc-m');
      if (!btn || !menu) return;
      function open(v) {
        btn.setAttribute('aria-expanded', v ? 'true' : 'false');
        menu.hidden = !v;
        if (!v) return;
        menu.style.left = Math.max(0, Math.min(btn.offsetLeft, nav.clientWidth - menu.offsetWidth)) + 'px';
        var q = menu.querySelector('input');
        (q || menu.querySelector('a')).focus();
        track('breadcrumb_switcher_open', { page: path });
      }
      btn.addEventListener('click', function (e) { e.stopPropagation(); open(menu.hidden); });
      var q = menu.querySelector('input'), none = menu.querySelector('.nwbc-none');
      if (q) q.addEventListener('input', function () {
        var v = q.value.toLowerCase().trim(), shown = 0;
        [].forEach.call(menu.querySelectorAll('li'), function (x) {
          var ok = !v || x.textContent.toLowerCase().indexOf(v) > -1;
          x.hidden = !ok;
          if (ok) shown++;
        });
        none.hidden = shown > 0;
      });
      nav._open = open;
    }
    document.addEventListener('click', function (e) {
      var menu = nav.querySelector('.nwbc-m');
      if (menu && !menu.hidden && !menu.contains(e.target) && nav._open) nav._open(false);
    });
    document.addEventListener('keydown', function (e) {
      var menu = nav.querySelector('.nwbc-m');
      if (e.key === 'Escape' && menu && !menu.hidden && nav._open) { nav._open(false); nav.querySelector('button.nwbc-c').focus(); }
    });
    nav.addEventListener('click', function (e) {
      var a = e.target.closest('a');
      if (a) track('breadcrumb_click', { to: a.getAttribute('href'), from: path, switcher: !!a.closest('.nwbc-m') });
    });

    function schema() {
      var old = document.querySelector('script[data-nwbc]');
      if (old) old.parentNode.removeChild(old);
      var items = steps.map(function (s, i) {
        return { '@type': 'ListItem', position: i + 1, name: s.name, item: location.origin + s.href };
      });
      if (items.length < 2) return;
      var ld = document.createElement('script');
      ld.type = 'application/ld+json';
      ld.setAttribute('data-nwbc', '1');
      ld.textContent = JSON.stringify({ '@context': 'https://schema.org', '@type': 'BreadcrumbList', itemListElement: items });
      document.head.appendChild(ld);
    }

    render();
    document.documentElement.classList.add('nwbc-on');

    // Listing pages: add the area (Shoreditch) between the city and the
    // space, when Nomad Maps knows it and its page is in the sitemap.
    if (listing && URL_.indexOf('__') !== 0) {
      var slug = path.split('/').pop();
      var hdr = { apikey: KEY, Authorization: 'Bearer ' + KEY };
      fetch(URL_ + '/rest/v1/venues?select=webflow_location_id&webflow_slug=eq.' + encodeURIComponent(slug) + '&limit=1', { headers: hdr })
        .then(function (r) { return r.ok ? r.json() : []; })
        .then(function (v) {
          var id = v && v[0] && v[0].webflow_location_id;
          if (!id) return [];
          return fetch(URL_ + '/rest/v1/webflow_locations?select=name,slug&sitemap_added_at=not.is.null&id=eq.' + encodeURIComponent(id) + '&limit=1', { headers: hdr })
            .then(function (r) { return r.ok ? r.json() : []; });
        })
        .then(function (l) {
          var loc = l && l[0];
          if (!loc || !loc.slug || !loc.name) return;
          var href = '/locations/' + loc.slug;
          if (steps.some(function (s) { return s.href === href; })) return;
          steps.splice(steps.length - 1, 0, { name: loc.name, href: href, opts: [], kind: 'locations' });
          render();
        })
        .catch(function () {});
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run);
  else run();
})();

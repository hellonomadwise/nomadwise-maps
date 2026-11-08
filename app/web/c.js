// Short claim links (migration 287): nomadmaps.io/c/<space>-<4 letters>.
// GitHub Pages answers an unknown address with 404.html, which loads
// this. It asks the database where the link goes and opens the claim
// form just as the long link did: ?claim=<slug>&from=email&email=<address>.
(function () {
  var URL_ = '__NW_SUPABASE_URL__';
  var KEY = '__NW_SUPABASE_KEY__';
  var m = location.pathname.match(/^\/c\/([a-z0-9-]+)\/?$/i);
  if (!m) return;
  var code = m[1].toLowerCase();
  // If the database cannot be asked, the space's own name is still in
  // the link: open the claim form on it.
  var slug = code.replace(/-[a-z0-9]{4}$/, '');
  function go(s, from, email) {
    location.replace('/?claim=' + encodeURIComponent(s) + '&from=' + encodeURIComponent(from || 'email') +
      (email ? '&email=' + encodeURIComponent(email) : ''));
  }
  if (URL_.indexOf('__') === 0) { go(slug); return; }
  var done = false;
  setTimeout(function () { if (!done) { done = true; go(slug); } }, 4000);
  fetch(URL_ + '/rest/v1/rpc/claim_link_open', {
    method: 'POST',
    headers: { 'apikey': KEY, 'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_code: code })
  }).then(function (r) { return r.ok ? r.json() : null; })
    .then(function (d) {
      if (done) return; done = true;
      if (d && d.slug) go(d.slug, d.from, d.email); else go(slug);
    })
    .catch(function () { if (!done) { done = true; go(slug); } });
})();

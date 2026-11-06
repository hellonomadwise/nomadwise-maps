// "Stop monthly updates" from the monthly email (migration 251/253).
// A button, not an automatic switch-off on opening, so a mail program
// that checks links does not turn the email off by itself.
(function () {
  var URL_ = '__NW_SUPABASE_URL__';
  var KEY = '__NW_SUPABASE_KEY__';
  var q = new URLSearchParams(location.search);
  var t = q.get('t') || '';
  // k=tips: the owner tips (migration 275); otherwise the monthly update
  var k = q.get('k') === 'tips' ? 'tips' : 'monthly';
  var WHAT = k === 'tips' ? 'these tips' : 'the monthly update';
  var go = document.getElementById('go');
  var msg = document.getElementById('msg');
  var card = document.getElementById('card');
  function say(text) { msg.hidden = false; msg.textContent = text; }
  if (k === 'tips') {
    card.querySelector('h1').textContent = 'Stop these tips?';
    card.querySelector('p').textContent = 'You will no longer get the occasional tip about your page. Requests from people, updates about your page and the monthly update still reach you.';
    go.textContent = 'Stop these tips';
  }
  if (!t) {
    go.disabled = true;
    say('This link is not complete. You can turn ' + WHAT + ' off in Settings in your Owner account.');
    return;
  }
  go.addEventListener('click', function () {
    go.disabled = true;
    fetch(URL_ + '/rest/v1/rpc/owner_email_pref_off', {
      method: 'POST',
      headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_token: t, p_key: k })
    }).then(function (r) { return r.json(); }).then(function (d) {
      if (d && d.ok) {
        card.innerHTML = '<h1>Done</h1><p>You will not get ' + WHAT + ' any more.</p>' +
          '<p>Changed your mind? Turn it back on in Settings in your <a href="https://nomadmaps.io/owner">Owner account</a>.</p>';
      } else {
        go.disabled = false;
        say('That did not work. You can turn ' + WHAT + ' off in Settings in your Owner account.');
      }
    }).catch(function () {
      go.disabled = false;
      say('That did not work. Please try again in a moment.');
    });
  });
})();

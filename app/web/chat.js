/* Nomadwise chat box (migration 190).
 *
 * Loaded on every nomadwise.io page from https://nomadmaps.io/chat.js.
 * A round button bottom right; tapping it opens the chat. The visitor's
 * chat key lives in their browser (localStorage), so a chat carries on
 * across pages and visits. Answers come from Nomadwise's assistant, or
 * from Jonathan once he takes a chat over in Nomad Maps (Chats,
 * Website).
 *
 * Light on the database: nothing is asked until the visitor writes;
 * then the box looks for an answer every 2 seconds while one is on its
 * way, every 10 seconds while the box is open, and stops when it is
 * closed, the tab is hidden, or nothing has happened for 15 minutes.
 *
 * The build fills in the two values below (scripts/export_map.py).
 */
(function () {
  'use strict';
  var URL_ = '__NW_SUPABASE_URL__';
  var KEY = '__NW_SUPABASE_KEY__';
  if (URL_.indexOf('__') === 0 || KEY.indexOf('__') === 0) return;
  if (window.__nwChat) return;
  window.__nwChat = true;

  var RED = '#FF444F', INK = '#142032', BG = '#F7F7F7';
  var STORE = 'nw-chat';
  var state = load();
  var open = false, busy = false, typing = false, mode = 'bot';
  var pollTimer = null, waitingSince = 0, lastActivity = Date.now();
  var shown = {};

  function load() {
    try {
      var s = JSON.parse(localStorage.getItem(STORE) || '{}');
      if (s && s.token) return s;
    } catch (e) {}
    return { token: null, after: 0, msgs: [] };
  }
  function save() {
    try {
      localStorage.setItem(STORE, JSON.stringify({
        token: state.token, after: state.after,
        msgs: state.msgs.slice(-60), at: Date.now()
      }));
    } catch (e) {}
  }
  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
      var r = Math.random() * 16 | 0;
      return (c === 'x' ? r : (r & 3 | 8)).toString(16);
    });
  }
  function rpc(name, args) {
    return fetch(URL_.replace(/\/$/, '') + '/rest/v1/rpc/' + name, {
      method: 'POST',
      headers: {
        'apikey': KEY, 'Authorization': 'Bearer ' + KEY,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(args)
    }).then(function (r) {
      return r.json().then(function (j) {
        if (!r.ok) throw new Error((j && j.message) || 'Something went wrong.');
        return j;
      });
    });
  }

  // ------------------------------------------------------------ view
  var host = document.createElement('div');
  host.id = 'nw-chat';
  var root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;
  root.innerHTML =
    '<style>' +
    ':host{all:initial}' +
    '*{box-sizing:border-box;font-family:Roboto,system-ui,-apple-system,"Segoe UI",sans-serif}' +
    '.btn{position:fixed;right:18px;bottom:18px;width:58px;height:58px;border-radius:50%;background:' + RED + ';border:0;cursor:pointer;box-shadow:0 6px 20px rgba(20,32,50,.25);z-index:2147483000;display:flex;align-items:center;justify-content:center}' +
    '.btn svg{width:28px;height:28px;fill:#fff}' +
    '.dot{position:absolute;top:4px;right:4px;width:12px;height:12px;border-radius:50%;background:' + INK + ';border:2px solid #fff;display:none}' +
    '.panel{position:fixed;right:18px;bottom:88px;width:370px;max-width:calc(100vw - 24px);height:560px;max-height:calc(100vh - 110px);background:#fff;border-radius:16px;box-shadow:0 12px 40px rgba(20,32,50,.25);z-index:2147483001;display:none;flex-direction:column;overflow:hidden;color:' + INK + '}' +
    '.panel.on{display:flex}' +
    '.head{background:' + INK + ';color:#fff;padding:14px 16px;display:flex;align-items:center;gap:10px}' +
    '.head b{font-size:16px;display:block}.head span{font-size:12px;opacity:.8}' +
    '.x{margin-left:auto;background:none;border:0;color:#fff;font-size:24px;cursor:pointer;line-height:1;padding:0 4px}' +
    '.list{flex:1;overflow-y:auto;padding:14px;background:' + BG + '}' +
    '.m{max-width:85%;margin:0 0 10px;padding:9px 12px;border-radius:14px;font-size:14px;line-height:1.45;white-space:pre-wrap;word-wrap:break-word}' +
    '.them{background:#fff;border:1px solid rgba(20,32,50,.08);border-bottom-left-radius:4px}' +
    '.me{background:' + INK + ';color:#fff;margin-left:auto;border-bottom-right-radius:4px}' +
    '.who{font-size:11px;font-weight:700;color:#5C6773;margin:0 0 3px}' +
    '.m a{color:' + RED + ';font-weight:600}' +
    '.me a{color:#fff;text-decoration:underline}' +
    '.chips{display:flex;flex-wrap:wrap;gap:6px;margin:4px 0 10px}' +
    '.chip{background:#fff;border:1px solid ' + RED + ';color:' + RED + ';border-radius:16px;padding:6px 12px;font-size:13px;font-weight:600;cursor:pointer}' +
    '.typing{font-size:12px;color:#5C6773;margin:0 0 10px;display:none}' +
    '.err{font-size:12.5px;color:' + RED + ';padding:6px 14px 0;display:none}' +
    '.foot{border-top:1px solid rgba(20,32,50,.08);padding:10px;display:flex;gap:8px;align-items:flex-end;background:#fff}' +
    'textarea{flex:1;resize:none;border:1px solid rgba(20,32,50,.18);border-radius:10px;padding:9px 10px;font-size:14px;line-height:1.4;max-height:110px;min-height:40px;color:' + INK + ';outline:none}' +
    'textarea:focus{border-color:' + INK + '}' +
    '.send{background:' + RED + ';color:#fff;border:0;border-radius:10px;padding:0 14px;height:40px;font-weight:700;font-size:14px;cursor:pointer}' +
    '.send:disabled{opacity:.5;cursor:default}' +
    '.note{font-size:11px;color:#5C6773;padding:0 12px 9px;background:#fff;line-height:1.35}' +
    '@media (max-width:520px){.panel{right:0;left:0;bottom:0;width:100%;max-width:100%;height:85vh;max-height:85vh;border-radius:16px 16px 0 0}.btn{right:14px;bottom:14px}}' +
    '</style>' +
    '<button class="btn" aria-label="Chat with Nomadwise"><svg viewBox="0 0 24 24"><path d="M4 4h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H8l-4 4V6a2 2 0 0 1 2-2z"/></svg><i class="dot"></i></button>' +
    '<div class="panel" role="dialog" aria-label="Chat with Nomadwise">' +
    '<div class="head"><div><b>Nomadwise</b><span>Ask us about places to work, or your listing</span></div><button class="x" aria-label="Close">&times;</button></div>' +
    '<div class="list"></div>' +
    '<div class="err"></div>' +
    '<div class="foot"><textarea rows="1" maxlength="800" placeholder="Write a message"></textarea><button class="send">Send</button></div>' +
    '<div class="note">Our assistant answers first; Jonathan from the team reads every chat and can join in. Chats are kept so we can help you.</div>' +
    '</div>';
  var $ = function (s) { return root.querySelector(s); };
  var btn = $('.btn'), dot = $('.dot'), panel = $('.panel'), list = $('.list');
  var input = $('textarea'), sendBtn = $('.send'), err = $('.err');

  function esc(t) {
    return String(t || '').replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }
  function linkify(t) {
    return esc(t).replace(/https?:\/\/[^\s<]+[^\s<.,;:!?)\]]/g, function (u) {
      return '<a href="' + u + '" target="_blank" rel="noopener">' + u + '</a>';
    });
  }
  function bubble(role, author, body) {
    var d = document.createElement('div');
    d.className = 'm ' + (role === 'visitor' ? 'me' : 'them');
    d.innerHTML = (role === 'team' && author ? '<div class="who">' + esc(author) + '</div>' : '') + linkify(body);
    return d;
  }
  var typingEl = document.createElement('div');
  typingEl.className = 'typing';
  typingEl.textContent = 'Writing...';

  function render() {
    list.innerHTML = '';
    list.appendChild(bubble('bot', null,
      'Hi! I am Nomadwise\'s assistant. Looking for a good place to work, or do you run a cafe or coworking space?'));
    if (!state.msgs.length) {
      var chips = document.createElement('div');
      chips.className = 'chips';
      [['I run a cafe or coworking space', 'I run a cafe or coworking space.'],
       ['I am looking for a place to work', 'I am looking for a place to work.']].forEach(function (c) {
        var b = document.createElement('button');
        b.className = 'chip';
        b.textContent = c[0];
        b.onclick = function () { send(c[1]); };
        chips.appendChild(b);
      });
      list.appendChild(chips);
    }
    state.msgs.forEach(function (m) { list.appendChild(bubble(m.role, m.author, m.body)); });
    typingEl.style.display = typing ? 'block' : 'none';
    list.appendChild(typingEl);
    list.scrollTop = list.scrollHeight;
  }

  function take(view) {
    if (!view) return false;
    mode = view.mode || mode;
    typing = !!view.typing;
    if (typing && !waitingSince) waitingSince = Date.now();
    var fresh = false;
    (view.messages || []).forEach(function (m) {
      if (shown[m.id]) return;
      shown[m.id] = true;
      if (m.id > state.after) state.after = m.id;
      state.msgs.push({ id: m.id, role: m.role, author: m.author, body: m.body });
      if (m.role !== 'visitor') fresh = true;
    });
    if (fresh) {
      lastActivity = Date.now();
      if (!open) dot.style.display = 'block';
    }
    save();
    render();
    return fresh;
  }

  // ------------------------------------------------------------ talk
  function send(text) {
    text = String(text || '').trim();
    if (!text || busy) return;
    busy = true;
    sendBtn.disabled = true;
    err.style.display = 'none';
    if (!state.token) state.token = uuid();
    var temp = { id: -Date.now(), role: 'visitor', body: text };
    state.msgs.push(temp);
    typing = true;
    render();
    rpc('site_chat_send', {
      p_token: state.token, p_body: text,
      p_page: location.href.slice(0, 500), p_title: document.title.slice(0, 200),
      p_after: state.after
    }).then(function (view) {
      state.msgs = state.msgs.filter(function (m) { return m !== temp; });
      input.value = '';
      input.style.height = '';
      lastActivity = Date.now();
      waitingSince = Date.now();
      take(view);
      schedule();
    }).catch(function (e) {
      state.msgs = state.msgs.filter(function (m) { return m !== temp; });
      typing = false;
      render();
      input.value = text;
      err.textContent = e.message || 'That did not send. Please try again.';
      err.style.display = 'block';
    }).then(function () {
      busy = false;
      sendBtn.disabled = false;
    });
  }

  function poll() {
    pollTimer = null;
    if (!state.token || document.hidden) return schedule();
    rpc('site_chat_poll', { p_token: state.token, p_after: state.after })
      .then(function (view) { take(view); })
      .catch(function () {})
      .then(schedule);
  }

  // How soon to look again, if at all.
  function schedule() {
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = null;
    if (!state.token) return;
    var idle = Date.now() - lastActivity;
    var delay = null;
    if (typing && Date.now() - waitingSince < 90000) delay = 2000;
    else if (open && idle < 15 * 60000) delay = 10000;
    else if (mode === 'team' && idle < 15 * 60000) delay = 30000;
    if (delay !== null) pollTimer = setTimeout(poll, delay);
  }

  function toggle(on) {
    open = on;
    panel.classList.toggle('on', on);
    if (on) {
      dot.style.display = 'none';
      lastActivity = Date.now();
      render();
      setTimeout(function () { try { input.focus(); } catch (e) {} }, 50);
      if (state.token) poll();
    } else {
      schedule();
    }
  }

  btn.onclick = function () { toggle(!open); };
  $('.x').onclick = function () { toggle(false); };
  sendBtn.onclick = function () { send(input.value); };
  input.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      send(input.value);
    }
  });
  input.addEventListener('input', function () {
    input.style.height = 'auto';
    input.style.height = Math.min(110, input.scrollHeight) + 'px';
  });
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && open && state.token) poll();
  });

  state.msgs.forEach(function (m) { if (m.id > 0) shown[m.id] = true; });
  function mount() {
    document.body.appendChild(host);
    // A chat from the last day: one quiet look for anything new.
    var s = null;
    try { s = JSON.parse(localStorage.getItem(STORE) || '{}'); } catch (e) {}
    if (state.token && s && s.at && Date.now() - s.at < 86400000) poll();
  }
  if (document.body) mount();
  else document.addEventListener('DOMContentLoaded', mount);
})();

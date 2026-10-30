/* D.A.M VPN for LG — интерфейс. Работает с фоновой частью на ТВ по HTTP (127.0.0.1:8098, только для самого ТВ).
   Пробный режим (?demo или фоновая часть недоступна) — для просмотра на компьютере. */
(function () {
  "use strict";

  var BACKEND = "http://127.0.0.1:8098/api/";
  var RELAY = "https://damstudio.tech/tv/";
  var $ = function (id) { return document.getElementById(id); };

  // ---------- связь с фоновой частью ----------
  // Пробный режим — только в обычном браузере (на ТВ есть PalmServiceBridge) или по ?demo
  var onTV = typeof PalmServiceBridge !== "undefined";
  var demo = /demo/.test(location.search) || !onTV;
  var bridges = [];
  function luna(uri, params) {
    return new Promise(function (ok) {
      var b = new PalmServiceBridge(); bridges.push(b);
      b.onservicecallback = function (m) { try { ok(JSON.parse(m)); } catch (e) { ok({}); } };
      b.call(uri, JSON.stringify(params));
    });
  }
  // Фоновая часть не отвечает — просим Homebrew Channel запустить её с правами root
  function startBackend() {
    return luna("luna://org.webosbrew.hbchannel.service/exec",
      { command: "sh /media/developer/apps/usr/palm/applications/com.damstudio.vpn/service/run.sh" })
      .then(function () { return new Promise(function (r) { setTimeout(r, 2500); }); });
  }
  var started = false;
  var demoState = {
    connected: false, serverId: "s1", speed: null, ping: null,
    subscription: { name: "Quattro", count: 529 },
    servers: [
      { id: "s1", label: "🇸🇪 Швеция", kind: "gRPC", ping: 42 }, { id: "s2", label: "🇫🇮 Финляндия", kind: "REALITY", ping: 38 },
      { id: "s3", label: "🇳🇱 Нидерланды", kind: "REALITY", ping: 55 }, { id: "s4", label: "🇩🇪 Германия", kind: "REALITY", ping: 61 },
      { id: "s5", label: "🇱🇻 Латвия", kind: "REALITY", ping: 47 }, { id: "s6", label: "🇪🇪 Эстония", kind: "REALITY", ping: 44 },
      { id: "s7", label: "🇵🇱 Польша", kind: "gRPC", ping: 52 }, { id: "s8", label: "🇳🇴 Норвегия", kind: "gRPC", ping: 49 }
    ],
    settings: { autostart: true, autoServer: false, update: "раз в день", dns: true, ipv6: true, lan: true }
  };
  function api(method, path, body) {
    if (demo) return demoApi(method, path, body);
    return fetch(BACKEND + path, { method: method, headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined })
      .then(function (r) { return r.json().then(function (j) { if (!r.ok) throw new Error(j.error || "HTTP " + r.status); return j; }); });
  }
  function demoApi(method, path, body) {
    var s = demoState;
    return new Promise(function (ok) {
      setTimeout(function () {
        if (path === "status") ok({ connected: s.connected, serverId: s.serverId, speed: s.connected ? 161 : null, ping: s.connected ? 42 : null, subscription: s.subscription });
        else if (path === "servers") ok(s.servers);
        else if (path === "connect") { s.connected = true; if (body && body.id) s.serverId = body.id; ok({ ok: true }); }
        else if (path === "disconnect") { s.connected = false; ok({ ok: true }); }
        else if (path === "settings") { if (method === "POST") s.settings = body; ok(s.settings); }
        else if (path === "subscription") ok(s.subscription);
        else ok({});
      }, path === "connect" ? 900 : 150);
    });
  }

  // ---------- состояние и отрисовка ----------
  var st = { status: null, servers: [], settings: {} };
  function refresh() {
    return Promise.all([api("GET", "status"), api("GET", "servers")]).then(function (r) {
      st.status = r[0]; st.servers = r[1]; renderMain();
    }).catch(function () {
      if (!started) { started = true; return startBackend().then(refresh); }
      $("state").textContent = "Нет связи";
      $("sub").textContent = "Фоновая часть не запустилась. На Mac: ./tvctl install-app";
    });
  }
  function serverById(id) { for (var i = 0; i < st.servers.length; i++) if (st.servers[i].id === id) return st.servers[i]; return null; }
  function renderMain() {
    var s = st.status || {}, cur = serverById(s.serverId), main = $("main");
    main.classList.toggle("off", !s.connected);
    $("state").textContent = s.connected ? "Подключено" : (st.servers.length ? "Отключено" : "Нет подписки");
    $("sub").textContent = cur ? (s.connected ? cur.label : "Сервер: " + cur.label) : "Добавьте подписку — кнопка «+ Подписка»";
    $("power").textContent = s.connected ? "Отключить" : (st.servers.length ? "Подключить" : "Добавить подписку");
    $("speed").textContent = s.speed ? s.speed + " Мбит/с" : "—";
    $("ping").textContent = s.ping ? s.ping + " мс" : "—";
    $("subname").textContent = s.subscription ? s.subscription.name : "нет";
    $("count").textContent = st.servers.length;
    var list = $("servers"), keep = focused && focused.dataset.id;
    list.innerHTML = "";
    if (!st.servers.length) list.innerHTML = '<div class="empty">Серверов пока нет. Добавьте подписку с телефона.</div>';
    st.servers.forEach(function (sv) {
      var b = document.createElement("button");
      b.className = "it" + (sv.id === s.serverId ? " cur" : "");
      b.setAttribute("data-focus", ""); b.dataset.id = sv.id;
      b.innerHTML = "<span></span><small></small>";
      b.firstChild.textContent = sv.label;
      b.lastChild.textContent = (sv.ping ? sv.ping + " мс · " : "") + sv.kind;
      b.onclick = function () { choose(sv.id); };
      list.appendChild(b);
      if (keep === sv.id) focus(b);
    });
  }
  function choose(id) {
    var s = st.status || {};
    if (s.connected && s.serverId === id) return;
    busy(true);
    api("POST", "connect", { id: id }).then(refresh).catch(fail).then(function () { busy(false); });
  }
  function busy(on) { $("power").classList.toggle("busy", on); $("power").disabled = on; }
  function fail(e) { $("sub").textContent = "Не получилось: " + (e && e.message || e); }

  $("power").onclick = function () {
    var s = st.status || {};
    if (!st.servers.length) return show("add");
    busy(true);
    api("POST", s.connected ? "disconnect" : "connect", s.connected ? null : { id: s.serverId })
      .then(refresh).catch(fail).then(function () { busy(false); });
  };
  $("toAdd").onclick = function () { show("add"); };
  $("toSettings").onclick = function () { show("settings"); };
  $("addBack").onclick = $("setBack").onclick = function () { show("main"); };

  // ---------- подписка с телефона: QR → страница на damstudio.tech → шифр → ТВ ----------
  var poll = null;
  function b64u(bytes) { var t = ""; for (var i = 0; i < bytes.length; i++) t += String.fromCharCode(bytes[i]); return btoa(t).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); }
  function unb64u(t) { t = t.replace(/-/g, "+").replace(/_/g, "/"); while (t.length % 4) t += "="; var s = atob(t), a = new Uint8Array(s.length); for (var i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return a; }
  function addStatus(text, cls) { var w = $("addStatus"); w.className = "wait" + (cls ? " " + cls : ""); w.innerHTML = "<i></i>"; w.appendChild(document.createTextNode(text)); }
  function startAdd() {
    var sid = b64u(crypto.getRandomValues(new Uint8Array(16))), keyRaw = crypto.getRandomValues(new Uint8Array(32));
    var url = RELAY + "#s=" + sid + "&k=" + b64u(keyRaw);
    var qr = qrcode(0, "M"); qr.addData(url); qr.make();
    $("qr").innerHTML = qr.createSvgTag({ cellSize: 4, margin: 0 });
    $("addTitle").textContent = "Добавьте свою подписку";
    addStatus("Ждём телефон…");
    var started = Date.now();
    stopAdd();
    poll = setInterval(function () {
      if (Date.now() - started > 600000) { stopAdd(); addStatus("QR-код устарел — откройте экран заново", "err"); return; }
      fetch(RELAY + "api.php?s=" + sid, { cache: "no-store" }).then(function (r) { return r.json(); }).then(function (j) {
        if (!j || !j.ct) return;
        stopAdd();
        addStatus("Получили, расшифровываем…");
        return crypto.subtle.importKey("raw", keyRaw, "AES-GCM", false, ["decrypt"])
          .then(function (k) { return crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64u(j.iv) }, k, unb64u(j.ct)); })
          .then(function (pt) { addStatus("Загружаем серверы…"); return api("POST", "subscription", { text: new TextDecoder().decode(pt) }); })
          .then(function (sub) {
            $("addTitle").textContent = "Подписка добавлена";
            addStatus((sub && sub.name ? sub.name + " · " : "") + (sub && sub.count ? sub.count + " серверов" : "готово"), "ok");
            return refresh().then(function () { setTimeout(function () { show("main"); }, 2500); });
          });
      }).catch(function (e) { if (!poll) addStatus("Не получилось: " + (e && e.message || e), "err"); });
    }, 2000);
  }
  function stopAdd() { if (poll) { clearInterval(poll); poll = null; } }

  // ---------- настройки ----------
  var OPTS = [
    ["autostart", "Включать VPN вместе с ТВ", "подключаться к последнему серверу"],
    ["autoServer", "Выбирать сервер сам", "самый быстрый по пингу"],
    ["update", "Обновлять подписку", "новые и убранные серверы", ["раз в день", "раз в неделю", "вручную"]],
    ["dns", "Адреса сайтов через VPN", "обход блокировок DNS"],
    ["ipv6", "Закрыть IPv6", "чтобы ничего не шло мимо VPN"],
    ["lan", "Локальная сеть мимо VPN", "трансляции с телефона, принтеры"]
  ];
  function renderSettings() {
    var box = $("opts"); box.innerHTML = "";
    OPTS.forEach(function (o) {
      var b = document.createElement("button"), v = st.settings[o[0]];
      b.className = "opt"; b.setAttribute("data-focus", "");
      b.innerHTML = "<div></div>" + (o[3] ? '<div class="val"></div>' : '<div class="sw' + (v ? " on" : "") + '"></div>');
      b.firstChild.textContent = o[1];
      var small = document.createElement("small"); small.textContent = o[2]; b.firstChild.appendChild(small);
      if (o[3]) b.lastChild.textContent = v;
      b.onclick = function () {
        st.settings[o[0]] = o[3] ? o[3][(o[3].indexOf(v) + 1) % o[3].length] : !v;
        api("POST", "settings", st.settings).then(function (s) { st.settings = s; renderSettings(); focus(box.children[OPTS.indexOf(o)]); });
      };
      box.appendChild(b);
    });
    var about = document.createElement("div");
    about.className = "opt"; about.innerHTML = "<div>О программе<small>D.A.M VPN for LG · github.com/beatsformygotti-jpg/dam-vpn-for-lg</small></div><div class=\"val\">v0.1</div>";
    box.appendChild(about);
  }

  // ---------- экраны и пульт ----------
  var current = "main", focused = null;
  function show(name) {
    ["main", "add", "settings"].forEach(function (n) { $(n).hidden = n !== name; });
    if (current === "add" && name !== "add") stopAdd();
    current = name;
    if (name === "add") startAdd();
    if (name === "settings") api("GET", "settings").then(function (s) { st.settings = s; renderSettings(); focus(first()); });
    focus(name === "main" ? $("power") : first());
  }
  function first() { return $(current).querySelector("[data-focus]"); }
  function focus(el) {
    if (!el) return;
    if (focused) focused.classList.remove("focus");
    focused = el; el.classList.add("focus"); el.focus({ preventScroll: true });
    if (el.scrollIntoView && el.classList.contains("it")) el.scrollIntoView({ block: "nearest" });
  }
  // Пространственная навигация: ближайший элемент в нужную сторону
  function move(dx, dy) {
    if (!focused) return focus(first());
    var a = focused.getBoundingClientRect(), ax = a.left + a.width / 2, ay = a.top + a.height / 2, best = null, bestD = 1e9;
    $(current).querySelectorAll("[data-focus]").forEach(function (el) {
      if (el === focused) return;
      var b = el.getBoundingClientRect(); if (!b.width) return;
      var bx = b.left + b.width / 2, by = b.top + b.height / 2, px = (bx - ax) * dx, py = (by - ay) * dy;
      if ((dx && px <= 0) || (dy && py <= 0)) return;
      var d = (dx ? Math.abs(bx - ax) + Math.abs(by - ay) * 3 : Math.abs(by - ay) + Math.abs(bx - ax) * 3);
      if (d < bestD) { bestD = d; best = el; }
    });
    if (best) focus(best);
  }
  document.addEventListener("keydown", function (e) {
    var k = e.keyCode;
    if (k === 37) move(-1, 0); else if (k === 39) move(1, 0); else if (k === 38) move(0, -1); else if (k === 40) move(0, 1);
    else if (k === 13) { if (focused && !focused.disabled) focused.click(); }
    else if (k === 461 || k === 27 || k === 8) { if (current !== "main") show("main"); else if (window.webOS && webOS.platformBack) webOS.platformBack(); else return; }
    else return;
    e.preventDefault();
  });
  document.addEventListener("mouseover", function (e) { var t = e.target.closest && e.target.closest("[data-focus]"); if (t) focus(t); });
  document.addEventListener("visibilitychange", function () { if (!document.hidden) refresh(); });

  refresh().then(function () { focus($("power")); });
  setInterval(function () { if (current === "main") api("GET", "status").then(function (s) { st.status = s; renderMain(); }).catch(function () {}); }, 5000);
})();

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

// Vesting mini-app (RFP-017). Wallet first: the home screen shows your accounts and balances, where
// your LGO are (wallet -> locked in a vesting account -> recipient), what is coming to you and when it
// unlocks, and what you created. "Vest tokens" is always in the header; creating is a 4-step stepper
// whose action bar is pinned below the scrolling page, so it is never cut off. One primary action per screen, a review
// sheet before anything is signed, explicit pending / success / error states, plain words with a
// one-line "?" explanation for every term, technical detail behind "Show details" and Settings.
// All chain work happens in vesting_module (the `vesting` CLI + LEZ wallet); keys never reach
// this view. Wording and screen map: docs/UX_REDESIGN.md.
Item {
    id: root
    width: 960
    height: 760

    readonly property string appVersion: "0.3.0"      // keep in sync with metadata.json (render.sh checks)
    readonly property string appBuilt: "2026-11-21"
    // LEZ native token: LGO-scale, 10^9 native units per LGO (LEZ testnet_initial_state).
    readonly property string tokenName: "LGO"
    readonly property int decimals: 9

    // ---- data from the module ---------------------------------------------------------------
    property var cfg: ({})
    property bool cfgLoaded: false
    property var pubAccounts: []
    property var privAccounts: []
    property var schedules: []
    property var network: null            // {url, kind: local | testnet | other} (CLI ≥ 0.2)
    property var scan: null               // {next, tip, found, done}: on-chain search for vestings
    property real clockSkew: 0            // chain clock - local clock (from `list`)
    property bool loaded: false           // first refresh finished
    property string loadError: ""
    property bool refreshing: false
    property int privIndex: 0             // private account used for private claims
    property int acctIndex: -1            // selected public account (-1 = pick the richest)

    readonly property bool needsSetup: cfgLoaded && !cfg.program
    readonly property bool ready: loaded && !loadError && !needsSetup
    readonly property var incoming: schedules.filter(function (s) { return isMine(s.beneficiary) })
    readonly property var outgoing: schedules.filter(function (s) { return isMine(s.creator) })
    readonly property var acct: pubAccounts.length ? pubAccounts[acctIdx()] : null
    readonly property string netKind: network && network.kind ? network.kind : (cfg.dev_mode === "true" ? "local" : "")
    readonly property bool testNet: netKind === "local" || netKind === "testnet"

    // ---- navigation -------------------------------------------------------------------------
    property string page: "home"          // home | create | bulk | detail
    property string backPage: "home"
    property string detailKey: ""
    property string detailRole: "recipient"
    readonly property var ds: findSchedule(detailKey)
    property bool welcomeHidden: false
    property bool codeEntryOpen: false
    property int createStep: 1            // 1 Who · 2 How much · 3 Schedule · 4 Review
    property string toMode: "mine"        // mine | other  ("Sending to": my other account / someone else)
    property bool showEmptyAccounts: false
    property bool showEmptyFrom: false
    property bool showAllTo: false
    property string renameId: ""          // account being renamed (rename sheet)

    // ---- names and one-time notes, kept on this computer (QtQuick.LocalStorage if present) --
    property var names: ({})              // account id -> name the person gave it
    property bool introSeen: false        // "where did these test LGO come from" card dismissed
    property var db: null
    function dbOpen() {
        if (typeof renderHarness !== "undefined") return      // offscreen render: no persistence
        try {
            var o = Qt.createQmlObject('import QtQuick 2.15; import QtQuick.LocalStorage 2.15; QtObject { function open() { return LocalStorage.openDatabaseSync("rfp017_vesting_ui", "1.0", "Vesting mini-app preferences", 100000) } }', root, "prefs")
            db = o.open()
            db.transaction(function (tx) { tx.executeSql("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)") })
            db.readTransaction(function (tx) {
                var r = tx.executeSql("SELECT k, v FROM kv")
                var n = {}
                for (var i = 0; i < r.rows.length; i++) {
                    var row = r.rows.item(i)
                    if (row.k === "introSeen") introSeen = row.v === "1"
                    else if (row.k.indexOf("name:") === 0) n[row.k.substr(5)] = row.v
                }
                names = n
            })
        } catch (e) { db = null; console.log("vesting prefs: not stored (" + e + ")") }
    }
    function kvSet(k, v) {
        if (!db) return
        try { db.transaction(function (tx) { if (v === "") tx.executeSql("DELETE FROM kv WHERE k = ?", [k]); else tx.executeSql("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", [k, v]) }) } catch (e) {}
    }
    function setName(id, name) {
        var n = {}; for (var k in names) n[k] = names[k]
        name = String(name || "").trim().substr(0, 32)
        if (name === "") delete n[id]; else n[id] = name
        names = n
        kvSet("name:" + id, name)
    }
    function dismissIntro() { introSeen = true; kvSet("introSeen", "1") }

    // ---- operation (pending / success / error) ------------------------------------------
    property var op: null
    property int opStep: 0
    property bool opRunning: false
    property var opDone: null             // {title, body, code, codes, details, after}
    property var opError: null            // humanError(...)
    property real opStarted: 0
    property real tick: Date.now()

    // ---- sheets -----------------------------------------------------------------------------
    property string sheetMode: ""         // claim | confirm | bulkReview | op | settings | receive | addTokens | help | testLgo | rename
    property var claimTarget: null
    property bool claimPrivate: false
    property var quote: null
    property string quoteError: ""
    property bool quoting: false
    property int quoteSeq: 0
    property var confirmSpec: null
    property string copiedNote: ""

    QtObject {
        id: theme
        readonly property color bg: "#FFFFFF"
        readonly property color surface: "#F8F8FA"
        readonly property color surface2: "#EFEFF3"
        readonly property color border: "#E6E6EB"
        readonly property color text: "#131316"
        readonly property color text2: "#6A6A73"
        readonly property color text3: "#A0A0A8"
        readonly property color accent: "#6E56CF"
        readonly property color accentHover: "#5D45BE"
        readonly property color accentSoft: "#EEEBFC"
        readonly property color accentMid: "#C4B8F3"
        readonly property color good: "#1F9D55"
        readonly property color goodSoft: "#E4F5EA"
        readonly property color bad: "#D23F3F"
        readonly property color badSoft: "#FCEBEB"
        readonly property color warn: "#9A6B00"
        readonly property color warnSoft: "#FFF5DB"
        readonly property string mono: "monospace"
    }

    // Draft of the "Create a vesting" form (kept here so it survives navigation). Amounts are
    // what the person typed, in LGO; toBase() turns them into native units.
    QtObject {
        id: form
        property string to: ""
        property string amount: ""
        property string preset: "1y3m"        // 1y3m | 4y1y | 6m | milestones | custom
        property string lastsN: "12"
        property string lastsUnit: "months"
        property string cliffN: "3"
        property string cliffUnit: "months"
        property string startText: ""         // "" = now, else YYYY-MM-DD
        property var milestones: ["", ""]
        property bool cancelable: true
        property bool transferable: false
        property bool moreOpen: false
    }
    QtObject {
        id: bulk
        property string lines: ""
        property bool json: false
        property string jsonText: ""
    }
    property alias formState: form      // for tests/render/Harness.qml
    property alias bulkState: bulk

    // ---- bridge -----------------------------------------------------------------------------
    function unwrap(payload) {
        var p = payload
        for (var n = 0; n < 3 && typeof p === "string"; n++) { try { p = JSON.parse(p) } catch (e) { return { ok: false, error: "bad reply: " + p } } }
        if (p && typeof p === "object" && ("result" in p || "error" in p) && !("ok" in p)) {
            if (!("result" in p)) return { ok: false, error: String(p.error) }
            return unwrap(p.result)
        }
        if (p && typeof p === "object" && !("ok" in p)) return { ok: false, error: String(p.message || p.error || JSON.stringify(p)) }
        return (p && typeof p === "object") ? p : { ok: false, error: "empty reply" }
    }
    function call(method, args, done) {
        var finish = function (payload) {
            console.log("vesting " + method + " -> " + String(payload).substr(0, 300))
            var r = unwrap(payload)
            if (r.ok && r.pending && r.job) { var js = jobs; js[r.job] = done; jobs = js; pollTimer.start(); return }
            done(r)
        }
        if (typeof logos === "undefined" || !logos) { finish({ ok: false, error: "bridge: Logos bridge not available" }); return }
        if (logos.callModuleAsync) logos.callModuleAsync("vesting_module", method, args, finish, 20000)
        else finish(logos.callModule("vesting_module", method, args))
    }
    // Long module calls come back as jobs; poll each one on its own (several can run at once,
    // e.g. a forced refresh while an earlier one is still going).
    property var jobs: ({})               // job id -> callback
    property var jobsPolling: ({})        // job id -> true while a jobResult call is in flight
    Timer {
        id: pollTimer
        interval: 2000; repeat: true
        onTriggered: {
            var ids = Object.keys(jobs)
            if (ids.length === 0) { stop(); return }
            ids.forEach(function (job) {
                if (jobsPolling[job]) return
                jobsPolling[job] = true
                var got = function (payload) {
                    delete jobsPolling[job]
                    console.log("vesting jobResult -> " + String(payload).substr(0, 300))
                    var r = unwrap(payload)
                    if (r.ok && r.pending) return
                    var d = jobs[job]
                    var js = jobs; delete js[job]; jobs = js
                    if (d) d(r)
                }
                if (logos.callModuleAsync) logos.callModuleAsync("vesting_module", "jobResult", [job], got, 20000)
                else got(logos.callModule("vesting_module", "jobResult", [job]))
            })
        }
    }
    Timer { interval: 1000; running: true; repeat: true; onTriggered: root.tick = Date.now() }   // countdowns
    // Refresh every 20 s (also retries after a connection error); every 3 s while the first search for vestings is still going.
    Timer { interval: scan && !scan.done ? 3000 : 20000; running: (ready || (loaded && !needsSetup && loadError !== "")) && !opRunning; repeat: true; onTriggered: refresh() }

    // force: start over even if a load is in flight (after Save or Try again); stale replies are dropped.
    property int loadSeq: 0
    function refresh(force) {
        if (!force && (pollTimer.running || refreshing)) return
        var my = ++loadSeq
        refreshing = true
        call("getConfig", [], function (r) { if (my === loadSeq && r.ok) { cfg = r; cfgLoaded = true } })
        call("accounts", [], function (r) {
            if (my !== loadSeq) return
            if (!r.ok) { refreshing = false; loaded = true; loadError = r.error; return }
            pubAccounts = r["public"] || []
            privAccounts = r["private"] || []
            if (r.network) network = r.network
            call("listSchedules", [], function (l) {
                if (my !== loadSeq) return
                refreshing = false
                loaded = true
                if (!l.ok) { loadError = l.error; return }
                loadError = ""
                schedules = l.schedules || []
                scan = l.scan || null
                if (l.now) clockSkew = Number(l.now) - Date.now()
            })
        })
    }
    Component.onCompleted: { dbOpen(); refresh() }

    // ---- numbers (amounts are u128 strings in native units) --------------------------------
    function norm(a) { a = String(a === undefined || a === null ? "0" : a).replace(/^0+(?=\d)/, ""); return /^\d+$/.test(a) ? a : "0" }
    function cmp(a, b) { a = norm(a); b = norm(b); if (a.length !== b.length) return a.length < b.length ? -1 : 1; return a < b ? -1 : (a > b ? 1 : 0) }
    function add(a, b) {
        a = norm(a); b = norm(b)
        var r = "", c = 0, i = a.length - 1, j = b.length - 1
        while (i >= 0 || j >= 0 || c) { var s = (i >= 0 ? +a[i] : 0) + (j >= 0 ? +b[j] : 0) + c; r = (s % 10) + r; c = s >= 10 ? 1 : 0; i--; j-- }
        return norm(r)
    }
    function sub(a, b) {   // max(a - b, 0)
        a = norm(a); b = norm(b)
        if (cmp(a, b) <= 0) return "0"
        var r = "", br = 0, i = a.length - 1, j = b.length - 1
        while (i >= 0) { var d = +a[i] - (j >= 0 ? +b[j] : 0) - br; br = d < 0 ? 1 : 0; r = (d + (br ? 10 : 0)) + r; i--; j-- }
        return norm(r)
    }
    function isZero(a) { return norm(a) === "0" }
    function isWhole(a) { return /^\d+$/.test(String(a)) }
    function fmt(a) {
        var s = String(a === undefined || a === null ? "" : a)
        if (!/^\d+$/.test(s)) return s
        return norm(s).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    }
    function frac(a, b) { var t = Number(norm(b)); return t > 0 ? Math.min(1, Number(norm(a)) / t) : 0 }
    function sumOf(list, key) { var t = "0"; for (var i = 0; i < list.length; i++) t = add(t, list[i][key]); return t }
    // a / n for a small whole n (native-unit strings), rounded down.
    function divBy(a, n) {
        a = norm(a); var r = "", rem = 0
        for (var i = 0; i < a.length; i++) { var cur = rem * 10 + Number(a[i]); r += Math.floor(cur / n); rem = cur % n }
        return norm(r)
    }
    // Local LEZ test network (testnet_initial_state): two demo accounts get 10,000 and 20,000 LGO at start.
    function totalGenesis() { return "30000000000000" }
    function genesisCount() { return 2 }
    function uniq(list, key) { var seen = {}, out = []; for (var i = 0; i < list.length; i++) { var k = list[i][key]; if (!seen[k]) { seen[k] = true; out.push(k) } } return out }
    function namesOf(ids) {
        var t = ids.slice(0, 2).map(function (id) { return isMine(id) ? acctLabel(id) : shortId(id) }).join(", ")
        return ids.length > 2 ? t + " +" + (ids.length - 2) : t
    }
    function recipientsText(list) { return namesOf(uniq(list, "beneficiary")) }
    function sendersText(list) { return namesOf(uniq(list, "creator")) }
    function incomingAccountsText() { return namesOf(uniq(incoming, "beneficiary")) }

    // ---- LGO <-> native units -------------------------------------------------------------
    // What a person types ("1500", "12.5", "0,25", "1 000") -> native units, or "" if it isn't an amount.
    function toBase(t) {
        var s = String(t === undefined || t === null ? "" : t).replace(/[\s_'\u00a0]/g, "")
        if (s === "") return ""
        var commas = (s.match(/,/g) || []).length
        if (s.indexOf(".") >= 0) s = s.replace(/,/g, "")             // 1,234.5
        else if (commas === 1) s = s.replace(",", ".")               // 0,25 (comma decimal)
        else if (commas > 1) s = s.replace(/,/g, "")                 // 1,234,567
        var m = s.match(/^(\d*)(?:\.(\d*))?$/)
        if (!m || (m[1] === "" && !m[2])) return ""
        var f = m[2] || ""
        if (f.length > decimals) return ""
        while (f.length < decimals) f += "0"
        return norm((m[1] || "0") + f)
    }
    function validAmount(t) { var b = toBase(t); return b !== "" && !isZero(b) }
    // native units -> "12,345.6789" (exact, trailing zeros dropped)
    function units(a) {
        a = norm(a)
        while (a.length <= decimals) a = "0" + a
        var f = a.slice(a.length - decimals).replace(/0+$/, "")
        return fmt(a.slice(0, a.length - decimals)) + (f ? "." + f : "")
    }
    function tok(a) { return units(a) + " " + tokenName }
    // Rounded, for estimates and rates: 2 decimals from 1 LGO up, 4 significant digits below.
    function tokShort(x) {
        var v = Number(x) / Math.pow(10, decimals)
        if (!(v > 0)) return "0 " + tokenName
        var s = v >= 1 ? v.toFixed(2) : v.toPrecision(4)
        if (s.indexOf("e") >= 0) s = v.toFixed(decimals)
        s = s.indexOf(".") >= 0 ? s.replace(/0+$/, "").replace(/\.$/, "") : s
        var p = s.split(".")
        return fmt(p[0]) + (p[1] ? "." + p[1] : "") + " " + tokenName
    }

    // ---- text helpers -----------------------------------------------------------------------
    function nowMs() { return tick + clockSkew }
    function shortId(id) { id = String(id || ""); return id.length > 12 ? id.substr(0, 4) + "…" + id.substr(id.length - 4) : id }
    function isMine(id) { for (var i = 0; i < pubAccounts.length; i++) if (pubAccounts[i].id === id) return true; return false }
    function acctPos(id) { for (var i = 0; i < pubAccounts.length; i++) if (pubAccounts[i].id === id) return i; return -1 }
    // "Account 2", or the name the person gave it; an address that isn't ours stays a short address.
    function acctLabel(id) {
        if (names[id]) return names[id]
        var i = acctPos(id)
        return i >= 0 ? "Account " + (i + 1) : shortId(id)
    }
    function accountName(id) { return isMine(id) ? acctLabel(id) + " (" + shortId(id) + ")" : shortId(id) }
    // Who an address is, in words: "your Account 2" or "7wHg…3YQo".
    function whoIs(id) { return isMine(id) ? "your " + acctLabel(id) : shortId(id) }
    function acctById(id) { var i = acctPos(id); return i >= 0 ? pubAccounts[i] : null }
    readonly property var fundedAccounts: pubAccounts.filter(function (a) { return !isZero(a.balance) })
    readonly property int emptyCount: pubAccounts.length - fundedAccounts.length
    function validAccount(a) { return /^[A-Za-z0-9]{32,48}$/.test(String(a).trim()) }
    function keyOf(s) { return s ? s.creator + ":" + s.id : "" }
    function codeFor(s) { return s ? "vesting:" + s.creator + ":" + s.id : "" }
    function parseCode(t) {
        var m = String(t).trim().match(/^(?:vesting:)?\s*([A-Za-z0-9]{32,48})\s*[:\/\s]\s*([0-9a-fA-F]{64})$/)
        return m ? { creator: m[1], id: m[2].toLowerCase() } : null
    }
    function findSchedule(key) { for (var i = 0; i < schedules.length; i++) if (keyOf(schedules[i]) === key) return schedules[i]; return null }
    function fmtDate(ms) { return Qt.formatDateTime(new Date(Number(ms)), "MMM d, yyyy") }
    function fmtDateTime(ms) { return Qt.formatDateTime(new Date(Number(ms)), "MMM d, yyyy, HH:mm") }
    function whenFull(ms) { return Qt.formatDateTime(new Date(Number(ms)), "ddd, MMM d, yyyy 'at' HH:mm") }
    function rel(ms) {
        var d = Number(ms) - nowMs()
        var past = d < 0; d = Math.abs(d)
        var m = Math.round(d / 60000), h = Math.round(d / 3600000), days = Math.round(d / 86400000)
        var t = m < 1 ? "less than a minute" : m < 60 ? m + (m === 1 ? " minute" : " minutes")
              : h < 48 ? h + (h === 1 ? " hour" : " hours") : days + " days"
        return past ? t + " ago" : "in " + t
    }
    // Live countdown to `ms`: "2 days 03:14:05", "00:04:59".
    function countdown(ms) {
        var d = Math.max(0, Math.floor((Number(ms) - nowMs()) / 1000))
        var days = Math.floor(d / 86400), h = Math.floor(d % 86400 / 3600), m = Math.floor(d % 3600 / 60), s = d % 60
        var p = function (x) { return (x < 10 ? "0" : "") + x }
        return (days > 0 ? days + (days === 1 ? " day " : " days ") : "") + p(h) + ":" + p(m) + ":" + p(s)
    }
    function span(ms) {
        var days = ms / 86400000
        if (days >= 350) { var y = Math.round(days / 365.25); if (Math.abs(days - y * 365.25) < 20) return y + (y === 1 ? " year" : " years") }
        if (days >= 27) { var mo = Math.round(days / 30.44); return mo + (mo === 1 ? " month" : " months") }
        if (days >= 1.5) return Math.round(days) + " days"
        var h = ms / 3600000
        if (h >= 1.5) return Math.round(h) + " hours"
        var m = Math.max(1, Math.round(ms / 60000))
        return m + (m === 1 ? " minute" : " minutes")
    }
    function shapeText(s) {
        if (!s || !s.kind) return ""
        if (s.kind.linear) {
            var l = s.kind.linear
            return span(l.end - l.start) + ", " + (l.cliff > l.start ? span(l.cliff - l.start) + " wait (cliff)" : "no waiting period")
        }
        var n = s.kind.milestones ? s.kind.milestones.length : 0
        return n + (n === 1 ? " milestone" : " milestones")
    }
    function milestoneDone(s, i) { return Math.floor(Number(s.kind.done_mask || 0) / Math.pow(2, i)) % 2 === 1 }
    // What unlocks next for one vesting, in a form every screen can show the same way.
    //   kind: time (a moment, with a countdown) | flowing (unlocking every second) | milestone | done | stopped
    function nextOf(s) {
        if (!s || !s.kind) return { kind: "done" }
        if (s.cancelled) return { kind: "stopped", at: s.cancelled.at }
        var now = nowMs()
        if (s.kind.linear) {
            var l = s.kind.linear, len = Math.max(1, l.end - l.start)
            if (now < l.start) return { kind: "time", at: l.start, end: l.end, perDay: Number(norm(s.total)) * 86400000 / len, start: true }
            if (now < l.cliff) return { kind: "time", at: l.cliff, end: l.end, amount: Number(norm(s.total)) * (l.cliff - l.start) / len }
            if (now < l.end) return { kind: "flowing", end: l.end, perDay: Number(norm(s.total)) * 86400000 / len }
            return { kind: "done" }
        }
        var n = s.next_unlock
        if (n && n.kind === "milestone") return { kind: "milestone", index: n.index, amount: s.kind.milestones[n.index] }
        return { kind: "done" }
    }
    // One plain sentence for nextOf(); asCreator words it for the sender.
    function nextLine(s, asCreator) {
        var n = nextOf(s)
        if (n.kind === "stopped") return (asCreator ? "You stopped it on " : "The sender stopped it on ") + fmtDate(n.at) + ". Nothing more will unlock."
        if (n.kind === "time") {
            if (n.start) return "Starts " + whenFull(n.at) + ", then unlocks every second until " + fmtDate(n.end) + "."
            return "First unlock: about " + tokShort(n.amount) + " on " + whenFull(n.at) + "."
        }
        if (n.kind === "flowing") return "Unlocking every second (about " + tokShort(n.perDay) + " a day) until " + whenFull(n.end) + "."
        if (n.kind === "milestone") return "Next: " + tok(n.amount) + " when " + (asCreator ? "you confirm" : "the sender confirms") + " milestone " + (n.index + 1) + "."
        return "Everything has unlocked."
    }
    // The earliest "next unlock" across vestings (for the summary on Home).
    function nextAcross(list) {
        var best = null
        for (var i = 0; i < list.length; i++) {
            var n = nextOf(list[i])
            var rank = n.kind === "flowing" ? 0 : n.kind === "time" ? 1 : n.kind === "milestone" ? 2 : 9
            if (rank === 9) continue
            if (!best || rank < best.rank || (rank === 1 && best.rank === 1 && n.at < best.n.at)) best = { rank: rank, n: n, s: list[i] }
        }
        return best
    }
    function statusOf(s) {
        if (!s) return { text: "", tone: "" }
        if (s.cancelled) return { text: "Stopped", tone: "bad" }
        if (cmp(s.vested, s.total) >= 0) return { text: "Fully unlocked", tone: "good" }
        return { text: "Active", tone: "accent" }
    }
    function copyText(t, note) { clip.text = t; clip.selectAll(); clip.copy(); copiedNote = note || "Copied"; copiedTimer.restart() }
    TextEdit { id: clip; visible: false }
    Timer { id: copiedTimer; interval: 2000; onTriggered: copiedNote = "" }

    // ---- accounts ---------------------------------------------------------------------------
    function acctIdx() {
        if (acctIndex >= 0 && acctIndex < pubAccounts.length) return acctIndex
        // Default: the account with the most LGO (the one you'd pay from). "Coming to you" covers all accounts.
        var best = 0
        for (var i = 1; i < pubAccounts.length; i++) if (cmp(pubAccounts[i].balance, pubAccounts[best].balance) > 0) best = i
        return best
    }
    function fromAccount() { return acct }
    function networkName() {
        return netKind === "local" ? "Test network on this computer" : netKind === "testnet" ? "Logos testnet" : "LEZ network"
    }

    // ---- glossary: one line for every term the app uses -------------------------------------
    readonly property var terms: ({
        vesting: "Tokens locked for someone that unlock bit by bit on a schedule, like a salary or a team grant.",
        unlock: "The moment tokens become the recipient's to take.",
        claim: "Move tokens that have unlocked out of the vesting into your account. Waiting costs nothing; they stay safe in the vesting.",
        cliff: "A waiting period at the start. Nothing unlocks before it ends; then the share for that period unlocks at once.",
        milestones: "The tokens come in parts. Each part unlocks only when the sender confirms that milestone (for example, \"design done\").",
        stop: "The sender ends the vesting. What has already unlocked stays with the recipient; the locked rest goes back to the sender.",
        permanent: "The sender gave up the right to stop it, so the recipient is guaranteed every token on schedule.",
        account: "Your public LEZ account. Share its address so people can send you LGO or create a vesting for you. The keys stay in your wallet; this app never sees them.",
        lgo: "The Logos network's token. Amounts here are in whole LGO (1 LGO = 1,000,000,000 native units).",
        fee: "A small amount of LGO paid to the network to process an action.",
        privateBalance: "LGO in your private account. Others can't see how much you have or where it goes.",
        receivePrivately: "Claim into your private balance so nobody can trace where the tokens went. Slower: it builds a proof on this computer (about 40 minutes).",
        testNet: "A practice network. Its LGO are free test tokens and have no value.",
        code: "A reference to one vesting. You rarely need it: vestings for your address show up in the app by themselves.",
        transferable: "The recipient may hand the rest of the vesting to another account.",
        escrow: "When you vest, your LGO move out of your account into a separate vesting account made just for this vesting. Nobody holds a key to it: only the vesting program can move the LGO, and only by its rules: unlocked parts to the recipient when they claim, the locked rest back to you if you stop it.",
        publicPrivate: "Vesting uses public accounts, so amounts and addresses are visible on the network. Your private balance is only used to receive a claim privately.",
        testLgo: "Your local test network created free test LGO for 2 demo accounts when it started: 10,000 and 20,000, so 30,000 LGO in total. They have no value and never leave this computer. On the real network you bring your own LGO from your Logos wallet."
    })

    // ---- errors in plain words (docs/UX_REDESIGN.md §5) ------------------------------------
    function humanError(raw) {
        var s = String(raw || "Unknown error")
        var m = s.match(/V0\d\d/)
        var code = m ? m[0] : ""
        var T = {
            V001: ["Amount is zero", "Enter an amount above 0."],
            V002: ["Dates don't fit", "The waiting period must end before the vesting ends, and the end must be after the start."],
            V003: ["Milestones don't add up", "Use 1 to 64 milestones, each above 0, adding up to the amount."],
            V004: ["Not signed", "The wallet didn't sign. Unlock the wallet and try again."],
            V005: ["Something went wrong", "An internal check failed. Open Show details and share the text."],
            V006: ["Something went wrong", "An internal check failed. Open Show details and share the text."],
            V007: ["Already exists", "A vesting with this id already exists. Try again; a new id will be picked."],
            V008: ["Vesting not found", "There is no vesting for this code. Check it with the sender."],
            V009: ["Not yours", "Only the recipient of this vesting can do this."],
            V010: ["Not yours", "Only the sender of this vesting can do this."],
            V012: ["Can't be stopped", "This vesting was made permanent."],
            V013: ["Already stopped", "This vesting was stopped earlier."],
            V014: ["No such milestone", "This vesting has no milestone with that number."],
            V015: ["Already confirmed", "This milestone was confirmed earlier."],
            V016: ["Not a milestone vesting", "This vesting unlocks over time, not by milestones."],
            V017: ["Can't be given away", "The sender didn't allow giving this vesting to another account."],
            V018: ["Something went wrong", "A number was too large. Open Show details and share the text."],
            V019: ["No recipients", "Add at least one person."],
            V020: ["Not enough LGO for the network cost", "Add LGO to the paying account and try again."],
            V021: ["The network didn't accept it", "It wasn't included within 2 minutes. Wait a moment and try again."],
            V022: ["Busy", "Another action is still running. Wait for it to finish, then try again."],
            V023: ["Not a private account", "Pick one of this wallet's private accounts in Settings → Advanced."],
            V024: ["Too many people", "Up to 360 people per transaction. Split the list."]
        }
        var title = "", msg = ""
        if (code === "V011") {
            title = "Nothing to claim yet"
            var t = s.match(/next unlock at (\d+)/), mi = s.match(/milestone #(\d+)/)
            if (t) msg = "Next unlock: " + whenFull(Number(t[1])) + " (" + rel(Number(t[1])) + ")."
            else if (mi) msg = "Next unlock: when the sender confirms milestone " + (Number(mi[1]) + 1) + "."
            else msg = "Everything unlocked so far has been claimed, and nothing more will unlock."
        } else if (code && T[code]) {
            title = T[code][0]; msg = T[code][1]
            if (code === "V020") {
                var b = s.match(/balance (\d+) is below the estimated fee (\d+)/)
                var priv = /Private\//.test(s)
                msg = (priv ? "Your private balance" : "Your account") + " can't cover the network cost."
                    + (b ? " It needs about " + tok(b[2]) + "; it has " + tok(b[1]) + "." : "")
                    + (priv ? " Move some LGO into your private account first, then try again." : " Add LGO to it (Home → Add LGO), then try again.")
            }
        } else if (/bridge|not available|bad reply|empty reply/i.test(s)) {
            title = "Can't reach the vesting module"; msg = "Make sure the Vesting module is installed and running, then try again."
        } else if (/PROGRAM required/i.test(s)) {
            title = "Not set up yet"; msg = "Add the vesting program address in Settings → Advanced."
        } else if (/open wallet|LEE_WALLET|wallet home|storage/i.test(s)) {
            title = "Can't open the wallet"; msg = "Check the wallet folder in Settings → Advanced, and that the wallet is unlocked."
        } else if (/sequencer|connection refused|connect|dns|unreachable/i.test(s)) {
            title = "Can't reach the network"; msg = "The LEZ node isn't answering. Check that it is running, then try again."
        } else if (/timed? ?out/i.test(s)) {
            title = "Took too long"; msg = "The network didn't answer in time. Try again."
        } else if (/invalid (creator|account|id)|must be/i.test(s)) {
            title = "Check what you entered"; msg = s.replace(/^.*?: /, "")
        } else {
            title = "Something went wrong"; msg = "Try again. If it keeps happening, open Show details and share the text."
        }
        return { code: code, title: title, message: msg, raw: s }
    }

    // ---- operations -------------------------------------------------------------------------
    function runOp(spec) {
        op = spec; op.results = []
        opStep = 0; opDone = null; opError = null
        opRunning = true; opStarted = Date.now(); tick = Date.now()
        sheetMode = "op"
        nextStep()
    }
    function nextStep() {
        var st = op.steps[opStep]
        call(st.method, st.args, function (r) {
            if (!r.ok) {
                opRunning = false
                var e = humanError(r.error)
                if (op.stepError) e = op.stepError(opStep, e) || e
                opError = e
                refresh()
                return
            }
            op.results.push(r)
            if (opStep + 1 < op.steps.length) { opStep = opStep + 1; nextStep(); return }
            opRunning = false
            opDone = op.success(op.results)
            refresh()
        })
    }
    function retryOp() { opError = null; opRunning = true; opStarted = Date.now(); tick = Date.now(); nextStep() }
    function elapsed() { var s = Math.max(0, Math.floor((tick - opStarted) / 1000)); var m = Math.floor(s / 60); s = s % 60; return m + ":" + (s < 10 ? "0" : "") + s }
    function closeSheet() {
        if (sheetMode === "op" && !opRunning) { op = null; opDone = null; opError = null }
        sheetMode = ""
    }

    // claim
    function privId() { return privAccounts.length ? privAccounts[Math.min(privIndex, privAccounts.length - 1)].id : "" }
    function openClaim(s) { claimTarget = s; claimPrivate = false; sheetMode = "claim"; requote() }
    function requote() {
        var s = claimTarget
        quote = null; quoteError = ""
        quoteSeq = quoteSeq + 1
        var seq = quoteSeq
        if (claimPrivate && !privId()) { quoting = false; quoteError = "noPrivate"; return }
        quoting = true
        call("quoteClaim", [s.beneficiary, s.creator, s.id, claimPrivate ? privId() : ""], function (r) {
            if (seq !== quoteSeq) return
            quoting = false
            if (r.ok) quote = r; else quoteError = r.error
        })
    }
    function claimBlocker() {
        if (quoting) return "Getting the cost…"
        if (quoteError === "noPrivate") return "No private account in this wallet"
        if (quoteError) {
            var c = humanError(quoteError).code
            if (c === "V020") return "Not enough LGO for the network cost"
            if (c === "V011") return "Nothing to claim yet"
            return ""
        }
        return quote ? "" : "Getting the cost…"
    }
    function confirmClaim() {
        if (quoteError) { requote(); return }
        var s = claimTarget, amt = quote.amount, priv = claimPrivate ? privId() : ""
        var steps = [{ label: "Claiming", method: "claim", args: [s.beneficiary, s.creator, s.id, priv] }]
        if (priv) steps.push({ label: "Moving to your private balance", method: "receivePending", args: [] })
        runOp({
            title: "Claiming " + tok(amt) + "…",
            long: !!priv,
            steps: steps,
            stepError: function (i, e) {
                if (i === 1) return { code: e.code, raw: e.raw, title: "Claimed, but not moved yet",
                                      message: "Your claim went through. Moving it into your private balance didn't finish: " + e.message + " Press Try again to finish." }
                return null
            },
            success: function (rs) {
                var got = rs[0].amount || amt
                if (!priv) return { title: "Claimed!", body: tok(got) + " are now in your account " + shortId(s.beneficiary) + ".", details: "Included in block " + rs[0].block + "." }
                var n = rs[1] && rs[1].received ? rs[1].received.length : 0
                if (n > 0) return { title: "Claimed!", body: tok(got) + " are now in your private balance.", details: "Claim in block " + rs[0].block + "; received " + n + " private payment(s)." }
                return { title: "Claimed!", body: "Your LGO are on their way to your private balance. If they don't show up, press “Check for private payments” on Home in a minute.", details: "Claim in block " + rs[0].block + "." }
            }
        })
    }

    // create
    function presetSpec(p) {
        if (p === "1y3m") return { lasts: 12, lu: "months", cliff: 3, cu: "months" }
        if (p === "4y1y") return { lasts: 48, lu: "months", cliff: 12, cu: "months" }
        if (p === "6m") return { lasts: 6, lu: "months", cliff: 0, cu: "months" }
        return { lasts: Number(form.lastsN), lu: form.lastsUnit, cliff: Number(form.cliffN || 0), cu: form.cliffUnit }
    }
    function addSpan(ms, n, unit) {
        if (unit === "days") return ms + n * 86400000
        var d = new Date(ms)
        d.setMonth(d.getMonth() + (unit === "years" ? 12 * n : n))
        return d.getTime()
    }
    function planTimes(preset) {
        var spec = presetSpec(preset)
        if (!(spec.lasts > 0) || Math.floor(spec.lasts) !== spec.lasts) return { ok: false, err: "Enter how long it lasts" }
        if (!(spec.cliff >= 0) || Math.floor(spec.cliff) !== spec.cliff) return { ok: false, err: "Enter the waiting period (0 for none)" }
        var start = nowMs(), future = false
        if (preset === "custom" && form.startText.trim() !== "") {
            var m = form.startText.trim().match(/^(\d{4})-(\d{2})-(\d{2})$/)
            if (!m) return { ok: false, err: "Start date: use YYYY-MM-DD" }
            start = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])).getTime()
            if (isNaN(start)) return { ok: false, err: "Start date: use YYYY-MM-DD" }
            future = start > nowMs()
        }
        var end = addSpan(start, spec.lasts, spec.lu), cliff = addSpan(start, spec.cliff, spec.cu)
        if (cliff > end) return { ok: false, err: "The waiting period must be shorter than the whole vesting" }
        return { ok: true, start: Math.round(start), cliff: Math.round(cliff), end: Math.round(end), future: future }
    }
    function milestoneSum() { var t = "0"; for (var i = 0; i < form.milestones.length; i++) t = add(t, toBase(form.milestones[i]) || "0"); return t }
    // What stops each step of "Vest tokens" (the button shows it, Uniswap-style); "" = ok.
    function stepBlocker(n) {
        if (!ready) return "Not connected"
        if (pubAccounts.length === 0) return "No account in this wallet"
        if (n === 1) {
            if (form.to.trim() === "") return toMode === "mine" ? "Pick the account that receives it" : "Paste the recipient's address"
            if (!validAccount(form.to)) return "Check the recipient's address"
            if (form.to.trim() === acct.id) return "Pick a different account to receive"
            return ""
        }
        if (n === 2) {
            if (!validAmount(form.amount)) return "Enter an amount"
            if (cmp(toBase(form.amount), acct.balance) > 0) return "Not enough LGO in " + acctLabel(acct.id)
            return ""
        }
        if (n === 3) return scheduleBlocker()
        return createBlocker()
    }
    function createBlocker() { return stepBlocker(1) || stepBlocker(2) || stepBlocker(3) }
    function toCheck() {   // live check under the address field
        var t = form.to.trim()
        if (t === "") return { tone: "plain", text: "" }
        if (!validAccount(t)) return { tone: "bad", text: "That isn't a LEZ address. It is 32 to 48 letters and digits, like the one under Receive." }
        if (acct && t === acct.id) return { tone: "bad", text: "That's the account you're paying from. Pick another one." }
        if (isMine(t)) return { tone: "good", text: "✓ That's your " + acctLabel(t) + "." }
        return { tone: "good", text: "✓ Valid address. Double-check it with the recipient: LGO vested to a wrong address only come back if you stop the vesting." }
    }
    function flickItem() { return flick }   // for tests/render/Harness.qml
    // "Sending to → My other account": every account but the payer; funded ones first, then up to 2 empty
    // ones unless "Show more" (the chosen one always stays visible).
    function toAll() {
        var o = pubAccounts.filter(function (a) { return !acct || a.id !== acct.id })
        return o.filter(function (a) { return !isZero(a.balance) }).concat(o.filter(function (a) { return isZero(a.balance) }))
    }
    function toChoices() {
        var all = toAll()
        if (showAllTo) return all
        var funded = all.filter(function (a) { return !isZero(a.balance) }).length
        return all.filter(function (a, i) { return i < Math.max(3, funded + 2) || a.id === form.to.trim() })
    }
    function toChoicesHidden() { return toAll().length - toChoices().length }
    function goStep(n) { createStep = Math.max(1, Math.min(4, n)); flick.contentY = 0 }
    function startCreate() { if (page !== "create") createStep = 1; page = "create"; flick.contentY = 0 }
    function scheduleBlocker() {
        if (form.preset === "milestones") {
            if (form.milestones.length < 1 || form.milestones.length > 64) return "Use 1 to 64 milestones"
            for (var i = 0; i < form.milestones.length; i++) if (!validAmount(form.milestones[i])) return "Enter every milestone amount"
            if (cmp(milestoneSum(), toBase(form.amount)) !== 0) return "Milestones must add up to the amount"
            return ""
        }
        var p = planTimes(form.preset)
        return p.ok ? "" : p.err
    }
    function previewSentence(who, amount) {
        var base = toBase(amount)
        var amt = base !== "" && !isZero(base) ? tok(base) : "the LGO"
        if (form.preset === "milestones") {
            var n = form.milestones.length
            return who + " gets " + amt + " in " + n + (n === 1 ? " part" : " parts") + ". Each part unlocks when you confirm that milestone."
        }
        var p = planTimes(form.preset)
        if (!p.ok) return ""
        var head = (p.future ? "Starting " + fmtDate(p.start) + ", " + who.charAt(0).toLowerCase() + who.slice(1) : who) + " gets " + amt + " over " + span(p.end - p.start) + ". "
        if (p.cliff <= p.start) return head + "They unlock a little every second, starting now, until " + fmtDate(p.end) + "."
        var part = base !== "" && !isZero(base) ? "about " + tokShort(Number(base) * (p.cliff - p.start) / (p.end - p.start)) : "a share"
        return head + "Nothing unlocks for the first " + span(p.cliff - p.start) + ". On " + fmtDate(p.cliff) + " " + part + " unlock at once, then the rest a little every second until " + fmtDate(p.end) + "."
    }
    function createValues() {
        if (form.preset === "milestones") return { kind: "milestones", values: form.milestones.map(function (x) { return toBase(x) }).join(",") }
        var p = planTimes(form.preset)
        return { kind: "linear", values: [p.start, p.cliff, p.end].join(",") }
    }
    function resetForm() { form.to = ""; form.amount = ""; form.milestones = ["", ""]; createStep = 1 }
    function confirmCreate() {
        var a = acct, v = createValues(), to = form.to.trim(), amt = toBase(form.amount)
        var when = previewSentence(isMine(to) ? acctLabel(to) : shortId(to), form.amount)
        runOp({
            title: "Vesting " + tok(amt) + "…",
            steps: [{ label: "Locking your LGO in a vesting account", method: "create", args: [a.id, to, amt, v.kind, v.values, form.cancelable, form.transferable] }],
            success: function (rs) {
                resetForm()
                return { title: "Vesting created", body: tok(amt) + " left " + acctLabel(a.id) + " and are now locked in their own vesting account. They unlock for " + whoIs(to) + " on the schedule.",
                         code: "vesting:" + a.id + ":" + rs[0].id, details: "Included in block " + rs[0].block + ".", after: "home",
                         created: { creator: a.id, id: rs[0].id, beneficiary: to, amount: amt, schedule: rs[0].schedule || "", when: when, fromLeft: sub(a.balance, amt) } }
            }
        })
    }
    // One click to the recipient's side of a vesting when the recipient is one of my accounts.
    function viewAsRecipient(creator, id, beneficiary) {
        var i = acctPos(beneficiary)
        if (i >= 0) acctIndex = i
        if (sheetMode !== "") closeSheet()
        detailKey = creator + ":" + id; detailRole = "recipient"; backPage = "home"; page = "detail"
        refresh(true)
    }

    // bulk: one person per line, "address, amount in LGO"
    function parseBulk() {
        var entries = []
        if (bulk.json) {
            try {
                var a = JSON.parse(bulk.jsonText)
                if (!Array.isArray(a) || a.length === 0) return { ok: false, err: "Paste a JSON list of vestings" }
                if (a.length > 360) return { ok: false, err: "Up to 360 people per transaction" }
                return { ok: true, raw: JSON.stringify(a), count: a.length, total: sumOf(a.map(function (e) { return { t: String(e.total) } }), "t"), entries: a }
            } catch (e) { return { ok: false, err: "That isn't valid JSON" } }
        }
        var lines = bulk.lines.split(/\r?\n/)
        var p = planTimes(bulkPreset())
        if (!p.ok) return { ok: false, err: p.err }
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i].trim()
            if (l === "" || l.charAt(0) === "#") continue
            // "address, amount" / "address;amount" / "address amount"; the amount may be "1 500" or "12,5".
            var m = l.match(/^([A-Za-z0-9]{32,48})\s*[,;\t ]\s*(.+)$/)
            if (!m) return { ok: false, err: "Line " + (i + 1) + ": write address, amount" }
            var parts = [m[1], m[2].trim()]
            if (!validAccount(parts[0])) return { ok: false, err: "Line " + (i + 1) + ": check the address" }
            if (!validAmount(parts[1])) return { ok: false, err: "Line " + (i + 1) + ": the amount must be above 0" }
            entries.push({ beneficiary: parts[0], total: toBase(parts[1]), linear: [p.start, p.cliff, p.end], cancelable: form.cancelable, transferable: form.transferable })
        }
        if (entries.length === 0) return { ok: false, err: "Add one person per line" }
        if (entries.length > 360) return { ok: false, err: "Up to 360 people per transaction. Split the list." }
        return { ok: true, raw: JSON.stringify(entries), count: entries.length, total: sumOf(entries, "total"), entries: entries }
    }
    function bulkPreset() { return form.preset === "milestones" ? "1y3m" : form.preset }
    function bulkSentence() {
        var p = planTimes(bulkPreset())
        if (!p.ok) return ""
        if (p.cliff <= p.start) return "Each person's LGO unlock a little every second over " + span(p.end - p.start) + ", until " + fmtDate(p.end) + "."
        return "Each person's LGO unlock over " + span(p.end - p.start) + ": nothing for the first " + span(p.cliff - p.start) + ", then a little every second until " + fmtDate(p.end) + "."
    }
    function bulkBlocker(b) {
        if (!ready) return "Not connected"
        if (pubAccounts.length === 0) return "No account in this wallet"
        if (!b.ok) return b.err
        if (cmp(b.total, acct.balance) > 0) return "Not enough LGO in this account"
        return ""
    }
    function confirmBulk() {
        var b = parseBulk(), a = acct
        runOp({
            title: "Creating " + b.count + " vestings…",
            steps: [{ label: "Creating", method: "createBatch", args: [a.id, b.raw] }],
            success: function (rs) {
                var rows = rs[0].schedules || []
                bulk.lines = ""; bulk.jsonText = ""
                return { title: rows.length + " vestings created", body: "Everyone sees their vesting in their Vesting app by themselves. If someone uses another app, they may need their code (below).",
                         codes: rows.map(function (x) { return x.beneficiary + "  vesting:" + a.id + ":" + x.id }).join("\n"),
                         details: "Included in block " + rs[0].block + ".", after: "home" }
            }
        })
    }

    // sender / recipient actions (confirm first)
    function askStop(s) {
        confirmSpec = { title: "Stop this vesting?", danger: true, button: "Stop vesting",
            body: tok(sub(s.vested, s.claimed)) + " that already unlocked stay with the recipient to claim. " + tok(sub(s.total, s.vested)) + " still locked come back to your account. This can't be undone.",
            run: function () { runOp({ title: "Stopping vesting…", steps: [{ label: "Stopping", method: "cancel", args: [s.creator, s.id] }],
                success: function (rs) { return { title: "Vesting stopped", body: "What already unlocked stays with the recipient; the rest came back to your account.", details: "Included in block " + rs[0].block + "." } } }) } }
        sheetMode = "confirm"
    }
    function askPermanent(s) {
        confirmSpec = { title: "Make it permanent?", danger: false, button: "Make permanent",
            body: "After this you can never stop this vesting; the recipient is guaranteed every LGO on schedule. This can't be undone.",
            run: function () { runOp({ title: "Making it permanent…", steps: [{ label: "Saving", method: "makeIrrevocable", args: [s.creator, s.id] }],
                success: function (rs) { return { title: "Vesting is now permanent", body: "It can no longer be stopped.", details: "Included in block " + rs[0].block + "." } } }) } }
        sheetMode = "confirm"
    }
    function askMilestone(s, i) {
        var amt = s.kind.milestones[i]
        confirmSpec = { title: "Confirm milestone " + (i + 1) + "?", danger: false, button: "Confirm milestone " + (i + 1),
            body: tok(amt) + " unlock for " + shortId(s.beneficiary) + " right away. This can't be undone.",
            run: function () { runOp({ title: "Confirming milestone " + (i + 1) + "…", steps: [{ label: "Confirming", method: "signalMilestone", args: [s.creator, s.id, i] }],
                success: function (rs) { return { title: "Milestone " + (i + 1) + " confirmed", body: tok(amt) + " are now unlocked for the recipient.", details: "Included in block " + rs[0].block + "." } } }) } }
        sheetMode = "confirm"
    }
    function askGive(s, to) {
        confirmSpec = { title: "Give this vesting away?", danger: true, button: "Give to " + shortId(to),
            body: "The account " + shortId(to) + " becomes the recipient and can claim everything still to come. You will no longer be able to claim it. This can't be undone.",
            run: function () { runOp({ title: "Giving the vesting away…", steps: [{ label: "Transferring", method: "transferBeneficiary", args: [s.beneficiary, s.creator, s.id, to] }],
                success: function (rs) { return { title: "Vesting given to " + shortId(to), body: "The new recipient sees it in their Vesting app and can claim it.", details: "Included in block " + rs[0].block + ".", after: "home" } } }) } }
        sheetMode = "confirm"
    }
    function receiveNow() {
        runOp({ title: "Checking for private payments…", steps: [{ label: "Receiving", method: "receivePending", args: [] }],
            success: function (rs) {
                var n = rs[0].received ? rs[0].received.length : 0
                return n > 0 ? { title: "Received " + n + (n === 1 ? " payment" : " payments"), body: "They are now in your private balance." }
                             : { title: "Nothing new", body: "No private payments are waiting." }
            } })
    }
    function openDetail(s, role) { detailKey = keyOf(s); detailRole = role; backPage = page === "detail" ? backPage : page; page = "detail" }
    function addCode(text, done) {
        var c = parseCode(text)
        if (!c) { done("That doesn't look like a vesting code. It starts with “vesting:”."); return }
        call("track", [c.creator, c.id], function (r) {
            if (!r.ok) { done(/V008/.test(r.error) ? "No vesting found for this code. Check it with the sender." : humanError(r.error).message); return }
            done("")
            refresh()
        })
    }

    // =========================================================================================
    // Building blocks
    // =========================================================================================
    component Card: Rectangle {
        id: card
        default property alias content: cardCol.data
        property int pad: 20
        property alias spacing: cardCol.spacing
        Layout.fillWidth: true
        implicitHeight: cardCol.implicitHeight + 2 * pad
        radius: 20
        color: theme.surface
        border.color: theme.border
        border.width: 1
        ColumnLayout {
            id: cardCol
            x: card.pad; y: card.pad
            width: card.width - 2 * card.pad
            spacing: 12
        }
    }
    component Label2: Text {
        color: theme.text
        font.pixelSize: 14
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
    component Caption: Text {
        color: theme.text2
        font.pixelSize: 13
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
    component FieldLabel: Text {
        color: theme.text2
        font.pixelSize: 13
        font.weight: Font.DemiBold
    }
    component Big: Text {
        color: theme.text
        font.pixelSize: 34
        font.weight: Font.DemiBold
        Layout.fillWidth: true
        elide: Text.ElideRight
    }
    component SheetTitle: Text { color: theme.text; font.pixelSize: 18; font.weight: Font.Bold; Layout.fillWidth: true; Layout.rightMargin: 24; wrapMode: Text.Wrap }
    component PrimaryButton: Rectangle {
        id: pb
        property string text: ""
        property bool busy: false
        property bool danger: false
        property bool soft: false
        signal clicked()
        Layout.fillWidth: true
        implicitHeight: 52
        implicitWidth: pbRow.implicitWidth + 40
        radius: 16
        color: !enabled ? theme.surface2 : soft ? (pbMouse.containsMouse ? "#E4E4EA" : theme.surface2) : danger ? (pbMouse.containsMouse ? "#BB3434" : theme.bad) : (pbMouse.containsMouse ? theme.accentHover : theme.accent)
        Row {
            id: pbRow
            anchors.centerIn: parent
            spacing: 8
            Spinner { visible: pb.busy; size: 18; color: pb.enabled && !pb.soft ? "white" : theme.text2; anchors.verticalCenter: parent.verticalCenter }
            Text { text: pb.text; color: pb.enabled && !pb.soft ? "white" : pb.soft ? theme.text : theme.text2; font.pixelSize: 16; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea { id: pbMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pb.clicked() }
    }
    component SoftButton: Rectangle {
        id: sb
        property string text: ""
        property bool danger: false
        property bool small: false
        signal clicked()
        implicitHeight: small ? 34 : 44
        implicitWidth: sbLabel.implicitWidth + (small ? 24 : 32)
        radius: small ? 12 : 14
        opacity: enabled ? 1 : 0.45
        color: danger ? (sbMouse.containsMouse ? "#F8DCDC" : theme.badSoft) : (sbMouse.containsMouse ? "#E4E4EA" : theme.surface2)
        Text { id: sbLabel; anchors.centerIn: parent; text: sb.text; color: sb.danger ? theme.bad : theme.text; font.pixelSize: sb.small ? 13 : 15; font.weight: Font.DemiBold }
        MouseArea { id: sbMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sb.clicked() }
    }
    component LinkText: Text {
        id: lt
        signal clicked()
        color: theme.accent
        font.pixelSize: 14
        font.weight: Font.DemiBold
        opacity: enabled ? 1 : 0.45
        MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: lt.clicked() }
    }
    component Field: TextField {
        id: tf
        Layout.fillWidth: true
        implicitHeight: 48
        font.pixelSize: 15
        color: theme.text
        placeholderTextColor: theme.text3
        leftPadding: 14; rightPadding: 14
        selectByMouse: true
        background: Rectangle { radius: 14; color: theme.bg; border.width: tf.activeFocus ? 2 : 1; border.color: tf.activeFocus ? theme.accent : theme.border }
    }
    component Chip: Rectangle {
        id: chip
        property string text: ""
        property bool selected: false
        signal clicked()
        implicitHeight: 36
        implicitWidth: chipLabel.implicitWidth + 28
        radius: 18
        color: selected ? theme.accentSoft : (chipMouse.containsMouse ? theme.surface2 : theme.bg)
        border.width: 1
        border.color: selected ? theme.accent : theme.border
        Text { id: chipLabel; anchors.centerIn: parent; text: chip.text; font.pixelSize: 14; font.weight: chip.selected ? Font.DemiBold : Font.Normal; color: chip.selected ? theme.accent : theme.text }
        MouseArea { id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chip.clicked() }
    }
    component Pill: Rectangle {
        id: pill
        property string text: ""
        property string tone: "accent"
        visible: text !== ""
        implicitHeight: 24
        implicitWidth: pillLabel.implicitWidth + 18
        radius: 12
        color: tone === "good" ? theme.goodSoft : tone === "bad" ? theme.badSoft : tone === "warn" ? theme.warnSoft : tone === "plain" ? theme.surface2 : theme.accentSoft
        Text { id: pillLabel; anchors.centerIn: parent; text: pill.text; font.pixelSize: 12; font.weight: Font.DemiBold
               color: pill.tone === "good" ? theme.good : pill.tone === "bad" ? theme.bad : pill.tone === "warn" ? theme.warn : pill.tone === "plain" ? theme.text2 : theme.accent }
    }
    component Toggle: Item {
        id: tg
        property bool checked: false
        property string text: ""
        property string hint: ""
        signal toggled()
        Layout.fillWidth: true
        implicitHeight: Math.max(tgCol.implicitHeight, 28)
        opacity: enabled ? 1 : 0.5
        ColumnLayout {
            id: tgCol
            anchors.left: parent.left; anchors.right: knobTrack.left; anchors.rightMargin: 16
            spacing: 2
            Text { text: tg.text; color: theme.text; font.pixelSize: 15; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.Wrap }
            Text { visible: tg.hint !== ""; text: tg.hint; color: theme.text2; font.pixelSize: 13; Layout.fillWidth: true; wrapMode: Text.Wrap }
        }
        Rectangle {
            id: knobTrack
            anchors.right: parent.right; anchors.top: parent.top
            width: 44; height: 26; radius: 13
            color: tg.checked ? theme.accent : "#D4D4DA"
            Rectangle { width: 20; height: 20; radius: 10; color: "white"; y: 3; x: tg.checked ? 21 : 3; Behavior on x { NumberAnimation { duration: 120 } } }
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { tg.checked = !tg.checked; tg.toggled() } }
    }
    component Progress: Rectangle {
        id: prog
        property real unlocked: 0
        property real claimed: 0
        Layout.fillWidth: true
        implicitHeight: 10
        radius: 5
        color: theme.surface2
        Rectangle { height: parent.height; radius: 5; width: Math.max(prog.unlocked > 0 ? 6 : 0, parent.width * Math.min(1, prog.unlocked)); color: theme.accentMid }
        Rectangle { height: parent.height; radius: 5; width: Math.max(prog.claimed > 0 ? 6 : 0, parent.width * Math.min(1, prog.claimed)); color: theme.accent }
    }
    component InfoRow: RowLayout {
        id: ir
        property string label: ""
        property string value: ""
        property color valueColor: theme.text
        property bool monoValue: false
        Layout.fillWidth: true
        spacing: 12
        Text { text: ir.label; color: theme.text2; font.pixelSize: 14; Layout.alignment: Qt.AlignTop }
        Text { text: ir.value; color: ir.valueColor; font.pixelSize: ir.monoValue ? 12 : 14; font.family: ir.monoValue ? theme.mono : Qt.application.font.family
               horizontalAlignment: Text.AlignRight; wrapMode: ir.monoValue ? Text.WrapAnywhere : Text.Wrap; Layout.fillWidth: true }
    }
    component Notice: Rectangle {
        id: nt
        property string title: ""
        property string text: ""
        property string tone: "plain"     // plain | warn | bad | good | accent
        Layout.fillWidth: true
        implicitHeight: ntCol.implicitHeight + 24
        radius: 14
        color: tone === "warn" ? theme.warnSoft : tone === "bad" ? theme.badSoft : tone === "good" ? theme.goodSoft : tone === "accent" ? theme.accentSoft : theme.surface2
        ColumnLayout {
            id: ntCol
            x: 14; y: 12; width: nt.width - 28
            spacing: 4
            Text { visible: nt.title !== ""; text: nt.title; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.Wrap
                   color: nt.tone === "warn" ? theme.warn : nt.tone === "bad" ? theme.bad : nt.tone === "good" ? theme.good : theme.text }
            Text { visible: nt.text !== ""; text: nt.text; font.pixelSize: 13; color: theme.text; Layout.fillWidth: true; wrapMode: Text.Wrap; lineHeight: 1.15 }
        }
    }
    component Expander: ColumnLayout {
        id: ex
        property string title: "Show details"
        property bool open: false
        default property alias content: exBody.data
        Layout.fillWidth: true
        spacing: 10
        Text {
            text: (ex.open ? "▾  " : "▸  ") + ex.title
            color: theme.text2; font.pixelSize: 13; font.weight: Font.DemiBold
            MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: ex.open = !ex.open }
        }
        ColumnLayout { id: exBody; visible: ex.open; Layout.fillWidth: true; spacing: 10 }
    }
    component Divider: Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: theme.border }
    component Spinner: Item {
        id: sp
        property int size: 22
        property color color: theme.accent
        implicitWidth: size; implicitHeight: size
        Canvas {
            anchors.fill: parent
            onPaint: {
                var c = getContext("2d"); c.reset()
                var lw = Math.max(2, sp.size / 9)
                c.lineWidth = lw; c.lineCap = "round"; c.strokeStyle = sp.color
                c.beginPath(); c.arc(width / 2, height / 2, width / 2 - lw, 0, Math.PI * 1.5); c.stroke()
            }
        }
        RotationAnimator on rotation { from: 0; to: 360; duration: 900; loops: Animation.Infinite; running: sp.visible }
    }
    component StatusIcon: Rectangle {
        id: si
        property string kind: "good"      // good | bad
        implicitWidth: 56; implicitHeight: 56; radius: 28
        color: kind === "good" ? theme.goodSoft : theme.badSoft
        Text { anchors.centerIn: parent; text: si.kind === "good" ? "✓" : "!"; font.pixelSize: 28; font.weight: Font.Bold; color: si.kind === "good" ? theme.good : theme.bad }
    }
    component Stat: ColumnLayout {
        id: stat
        property string label: ""
        property string value: ""
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        spacing: 2
        Text { text: stat.label; color: theme.text2; font.pixelSize: 12 }
        Text { text: stat.value; color: theme.text; font.pixelSize: 17; font.weight: Font.DemiBold; wrapMode: Text.Wrap; Layout.fillWidth: true }
    }
    // Unlock chart: linear-with-cliff curve or milestone steps, with a "now" marker.
    component UnlockChart: ColumnLayout {
        id: uc
        property string kind: "linear"
        property real start: 0
        property real cliff: 0
        property real end: 1
        property var amounts: []
        property var done: []
        property real now: 0
        Layout.fillWidth: true
        spacing: 6
        onKindChanged: cv.requestPaint()
        onStartChanged: cv.requestPaint()
        onCliffChanged: cv.requestPaint()
        onEndChanged: cv.requestPaint()
        onAmountsChanged: cv.requestPaint()
        onDoneChanged: cv.requestPaint()
        onNowChanged: cv.requestPaint()
        Canvas {
            id: cv
            Layout.fillWidth: true
            implicitHeight: 120
            onWidthChanged: requestPaint()
            onPaint: {
                var c = getContext("2d"); c.reset()
                var w = width, h = height, top = 6, bot = h - 1
                var X = function (f) { return 1 + f * (w - 2) }, Y = function (f) { return bot - f * (bot - top) }
                c.strokeStyle = theme.border; c.lineWidth = 1
                for (var g = 0; g <= 2; g++) { var gy = Math.round(Y(g / 2)) + 0.5; c.beginPath(); c.moveTo(0, gy); c.lineTo(w, gy); c.stroke() }
                var i
                if (uc.kind === "milestones") {
                    var n = uc.amounts.length, tot = 0
                    for (i = 0; i < n; i++) tot += Number(uc.amounts[i]) || 0
                    if (n === 0 || tot <= 0) return
                    var bw = (w - 2) / n, cum = 0
                    for (i = 0; i < n; i++) {
                        cum += Number(uc.amounts[i]) || 0
                        var bh = Math.max(2, (cum / tot) * (bot - top))
                        c.fillStyle = uc.done[i] ? theme.accent : theme.accentSoft
                        c.fillRect(X(i / n) + 4, bot - bh, bw - 8, bh)
                        c.strokeStyle = theme.accent; c.lineWidth = 1.5
                        c.strokeRect(X(i / n) + 4.5, bot - bh + 0.5, bw - 9, bh - 1)
                    }
                    return
                }
                var sp = uc.end - uc.start
                if (!(sp > 0)) return
                var cf = Math.max(0, Math.min(1, (uc.cliff - uc.start) / sp))
                c.beginPath(); c.moveTo(X(0), Y(0)); c.lineTo(X(cf), Y(0)); c.lineTo(X(cf), Y(cf)); c.lineTo(X(1), Y(1)); c.lineTo(X(1), Y(0)); c.closePath()
                c.fillStyle = theme.accentSoft; c.fill()
                c.beginPath(); c.moveTo(X(0), Y(0)); c.lineTo(X(cf), Y(0)); c.lineTo(X(cf), Y(cf)); c.lineTo(X(1), Y(1))
                c.strokeStyle = theme.accent; c.lineWidth = 2.5; c.lineJoin = "round"; c.stroke()
                var nf = (uc.now - uc.start) / sp
                if (uc.now > 0 && nf > 0 && nf < 1) {
                    var vy = nf < cf ? 0 : nf
                    c.strokeStyle = theme.text2; c.lineWidth = 1
                    c.beginPath(); c.moveTo(Math.round(X(nf)) + 0.5, top); c.lineTo(Math.round(X(nf)) + 0.5, bot); c.stroke()
                    c.fillStyle = theme.text; c.beginPath(); c.arc(X(nf), Y(vy), 4.5, 0, 2 * Math.PI); c.fill()
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            visible: uc.kind === "linear" && uc.end > uc.start + 1
            Caption { text: "Starts\n" + fmtDate(uc.start); Layout.fillWidth: false; font.pixelSize: 12 }
            Item { Layout.fillWidth: true }
            Caption { visible: uc.cliff > uc.start; text: "Waiting ends\n" + fmtDate(uc.cliff); horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: false; font.pixelSize: 12 }
            Item { Layout.fillWidth: true }
            Caption { text: "Fully unlocked\n" + fmtDate(uc.end); horizontalAlignment: Text.AlignRight; Layout.fillWidth: false; font.pixelSize: 12 }
        }
        RowLayout {
            Layout.fillWidth: true
            visible: uc.kind === "milestones"
            spacing: 0
            Repeater {
                model: uc.kind === "milestones" ? uc.amounts.length : 0
                Caption { text: "Milestone " + (index + 1) + (uc.done[index] ? " ✓" : ""); horizontalAlignment: Text.AlignHCenter; font.pixelSize: 12; Layout.fillWidth: true; Layout.preferredWidth: 1 }
            }
        }
    }
    // "?" next to a term: hover (or click to pin) for its one-line explanation.
    component Hint: Item {
        id: hn
        property string tip: ""
        property bool pinned: false
        implicitWidth: 18; implicitHeight: 18
        Layout.alignment: Qt.AlignVCenter
        Rectangle {
            anchors.fill: parent; radius: 9
            color: hnMouse.containsMouse || hn.pinned ? theme.accentSoft : theme.surface2
            border.width: 1; border.color: hnMouse.containsMouse || hn.pinned ? theme.accentMid : theme.border
            Text { anchors.centerIn: parent; text: "?"; font.pixelSize: 11; font.weight: Font.Bold; color: hnMouse.containsMouse || hn.pinned ? theme.accent : theme.text2 }
        }
        MouseArea { id: hnMouse; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hn.pinned = !hn.pinned }
        TextMetrics { id: hnMetrics; font.pixelSize: 13; text: hn.tip }
        ToolTip {
            visible: (hnMouse.containsMouse || hn.pinned) && hn.tip !== ""
            delay: 100
            margins: 8
            padding: 10
            width: Math.min(300, hnMetrics.advanceWidth + 2 * padding + 4)
            contentItem: Text { text: hn.tip; wrapMode: Text.Wrap; color: "white"; font.pixelSize: 13; lineHeight: 1.15 }
            background: Rectangle { radius: 10; color: "#2A2A30" }
        }
    }
    component CopyButton: Rectangle {
        id: cb
        property string value: ""
        property string note: "Copied"
        property string label: "Copy"
        implicitHeight: 34
        implicitWidth: cbLabel.implicitWidth + 24
        radius: 12
        color: cbMouse.containsMouse ? "#E4E4EA" : theme.surface2
        Text { id: cbLabel; anchors.centerIn: parent; text: copiedNote === cb.note ? "Copied ✓" : cb.label; color: copiedNote === cb.note ? theme.good : theme.text; font.pixelSize: 13; font.weight: Font.DemiBold }
        MouseArea { id: cbMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: copyText(cb.value, cb.note) }
    }
    component SectionHeader: ColumnLayout {
        id: sh
        property string title: ""
        property string tip: ""
        property string sub: ""
        Layout.fillWidth: true
        Layout.topMargin: 10
        spacing: 2
        RowLayout {
            spacing: 8
            Text { text: sh.title; font.pixelSize: 19; font.weight: Font.Bold; color: theme.text }
            Hint { tip: sh.tip; visible: sh.tip !== "" }
        }
        Caption { visible: sh.sub !== ""; text: sh.sub }
    }
    component TermRow: ColumnLayout {
        id: trm
        property string term: ""
        property string text: ""
        Layout.fillWidth: true
        spacing: 1
        Text { text: trm.term; color: theme.text; font.pixelSize: 14; font.weight: Font.DemiBold }
        Caption { text: trm.text }
    }
    component StepRow: RowLayout {
        id: stp
        property int n: 1
        property string text: ""
        Layout.fillWidth: true
        spacing: 12
        Rectangle {
            implicitWidth: 26; implicitHeight: 26; radius: 13; color: theme.accentSoft
            Layout.alignment: Qt.AlignTop
            Text { anchors.centerIn: parent; text: String(stp.n); color: theme.accent; font.pixelSize: 13; font.weight: Font.Bold }
        }
        Label2 { text: stp.text; lineHeight: 1.15; Layout.alignment: Qt.AlignVCenter }
    }
    // Loading / setup / connection error, shared by the pages.
    component StateCards: ColumnLayout {
        Layout.fillWidth: true
        spacing: 16
        visible: !ready
        Card {
            visible: !loaded
            RowLayout { spacing: 12; Spinner {} Label2 { text: "Opening your wallet…" } }
        }
        Card {
            visible: loaded && needsSetup
            Label2 { text: "Finish setup"; font.pixelSize: 18; font.weight: Font.DemiBold }
            Caption { text: "Tell the app which vesting program to use: open Settings and add the program address under Advanced." }
            PrimaryButton { text: "Open settings"; onClicked: sheetMode = "settings" }
        }
        Card {
            visible: loaded && !needsSetup && loadError !== ""
            Label2 { text: humanError(loadError).title; font.pixelSize: 18; font.weight: Font.DemiBold }
            Caption { text: humanError(loadError).message }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                PrimaryButton { text: "Try again"; busy: refreshing; onClicked: { loaded = false; refresh(true) } }
                SoftButton { text: "Settings"; implicitHeight: 52; onClicked: sheetMode = "settings" }
            }
            Expander { Caption { text: loadError; font.family: theme.mono; font.pixelSize: 11; wrapMode: Text.WrapAnywhere } }
        }
    }

    // ---- money flow: wallet -> vesting account (held by the program) -> recipient -------------
    // node: {title, name, addr, amount, sub, tone: plain | lock | good, tip}
    component FlowNode: Rectangle {
        id: fn
        property var node: ({})
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        implicitHeight: fnCol.implicitHeight + 24
        radius: 14
        color: fn.node.tone === "lock" ? theme.accentSoft : fn.node.tone === "good" ? theme.goodSoft : theme.bg
        border.width: 1
        border.color: fn.node.tone === "lock" ? theme.accentMid : fn.node.tone === "good" ? "#BFE5CC" : theme.border
        ColumnLayout {
            id: fnCol
            x: 12; y: 12; width: fn.width - 24
            spacing: 3
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Text { text: fn.node.title || ""; color: fn.node.tone === "lock" ? theme.accent : fn.node.tone === "good" ? theme.good : theme.text2; font.pixelSize: 11; font.weight: Font.Bold; font.capitalization: Font.AllUppercase; Layout.fillWidth: true; wrapMode: Text.Wrap }
                Hint { visible: !!fn.node.tip; tip: fn.node.tip || "" }
            }
            Text { text: fn.node.name || ""; color: theme.text; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.Wrap }
            Text { visible: !!fn.node.addr; text: fn.node.addr || ""; font.family: theme.mono; font.pixelSize: 11; color: theme.text2; Layout.fillWidth: true; elide: Text.ElideMiddle }
            Text { visible: !!fn.node.amount; text: fn.node.amount || ""; color: theme.text; font.pixelSize: 17; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.Wrap; Layout.topMargin: 2 }
            Text { visible: !!fn.node.sub; text: fn.node.sub || ""; color: theme.text2; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.Wrap; lineHeight: 1.1 }
        }
    }
    component FlowArrow: Item {
        id: fa
        property string label: ""
        property bool vertical: false
        implicitWidth: vertical ? 200 : Math.max(52, faLab.implicitWidth + 10)
        implicitHeight: vertical ? 28 : 44
        Layout.alignment: vertical ? Qt.AlignLeft : Qt.AlignVCenter
        Layout.leftMargin: vertical ? 22 : 0
        Text { id: faArrow; x: fa.vertical ? 0 : (fa.width - width) / 2; y: fa.vertical ? (fa.height - height) / 2 : 2
               text: fa.vertical ? "↓" : "→"; font.pixelSize: 20; font.weight: Font.Bold; color: theme.accent }
        Text { id: faLab; text: fa.label; font.pixelSize: 11; color: theme.text2
               x: fa.vertical ? faArrow.width + 10 : (fa.width - width) / 2; y: fa.vertical ? (fa.height - height) / 2 : faArrow.height + 2 }
    }
    component MoneyFlow: GridLayout {
        id: mf
        property var a: ({})
        property var b: ({})
        property var c: ({})
        property string ab: ""
        property string bc: ""
        property bool wide: root.width >= 720
        Layout.fillWidth: true
        columns: wide ? 5 : 1
        columnSpacing: 0
        rowSpacing: 2
        FlowNode { node: mf.a }
        FlowArrow { label: mf.ab; vertical: !mf.wide }
        FlowNode { node: mf.b }
        FlowArrow { label: mf.bc; vertical: !mf.wide }
        FlowNode { node: mf.c }
    }

    // ---- an account as a row: name, short address, balance (pickers and the wallet list) ------
    component AccountRow: Rectangle {
        id: ar
        property var account: null
        property bool selected: false
        property string note: ""
        readonly property string acctId: account ? account.id : ""
        signal picked()
        Layout.fillWidth: true
        implicitHeight: 58
        radius: 14
        color: selected ? theme.accentSoft : (arMouse.containsMouse ? theme.surface : theme.bg)
        border.width: selected ? 2 : 1
        border.color: selected ? theme.accent : theme.border
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12; anchors.rightMargin: 14
            spacing: 12
            Rectangle {
                implicitWidth: 34; implicitHeight: 34; radius: 17
                color: ["#E9E3FF", "#DDF3E6", "#FFE9D6", "#DCEBFF", "#FCE1EC", "#E6F0D8", "#F1E4FF", "#DFF4F4"][Math.max(0, acctPos(ar.acctId)) % 8]
                Text { anchors.centerIn: parent; text: String(acctPos(ar.acctId) + 1); font.pixelSize: 14; font.weight: Font.Bold; color: theme.text }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text { text: acctLabel(ar.acctId) + (ar.note ? "  ·  " + ar.note : ""); color: theme.text; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                Text { text: shortId(ar.acctId); color: theme.text2; font.pixelSize: 12; font.family: theme.mono }
            }
            Text { text: ar.account ? tok(ar.account.balance) : ""; color: ar.account && isZero(ar.account.balance) ? theme.text3 : theme.text; font.pixelSize: 14; font.weight: Font.DemiBold }
            Rectangle {
                implicitWidth: 20; implicitHeight: 20; radius: 10
                color: "transparent"; border.width: 2; border.color: ar.selected ? theme.accent : theme.text3
                Rectangle { anchors.centerIn: parent; width: 10; height: 10; radius: 5; color: theme.accent; visible: ar.selected }
            }
        }
        MouseArea { id: arMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ar.picked() }
    }

    // ---- "Vest tokens" stepper header ---------------------------------------------------------
    component Stepper: RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Repeater {
            model: ["Who", "How much", "Schedule", "Review"]
            RowLayout {
                spacing: 6
                Layout.fillWidth: index < 3
                Rectangle {
                    objectName: "stepDot"
                    implicitWidth: 28; implicitHeight: 28; radius: 14
                    color: index + 1 < createStep ? theme.good : index + 1 === createStep ? theme.accent : theme.surface2
                    Text { anchors.centerIn: parent; text: index + 1 < createStep ? "✓" : String(index + 1); color: index + 1 <= createStep ? "white" : theme.text2; font.pixelSize: 13; font.weight: Font.Bold }
                    MouseArea { anchors.fill: parent; enabled: index + 1 < createStep; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: goStep(index + 1) }
                }
                Text { visible: root.width >= 600 || index + 1 === createStep; text: modelData; font.pixelSize: 13; font.weight: index + 1 === createStep ? Font.Bold : Font.Normal; color: index + 1 === createStep ? theme.text : theme.text2 }
                Rectangle { visible: index < 3; Layout.fillWidth: true; implicitHeight: 2; Layout.minimumWidth: 8; color: index + 1 < createStep ? theme.good : theme.border }
            }
        }
    }

    // =========================================================================================
    // Layout
    // =========================================================================================
    Rectangle { anchors.fill: parent; color: theme.bg }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- header: the primary action is always here ----------------------------------------
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 64
            color: theme.bg
            Divider { anchors.bottom: parent.bottom; width: parent.width }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: root.width < 560 ? 12 : 20; anchors.rightMargin: root.width < 560 ? 8 : 20
                spacing: root.width < 560 ? 8 : 14
                Text {
                    objectName: "homeLink"
                    text: "Vesting"; font.pixelSize: 20; font.weight: Font.Bold; color: theme.text
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: page = "home" }
                }
                Rectangle {   // which network, always visible
                    visible: ready && netKind !== "" && root.width >= 760
                    implicitHeight: 26; implicitWidth: netLabel.implicitWidth + 22; radius: 13
                    color: testNet ? theme.warnSoft : theme.goodSoft
                    Text { id: netLabel; anchors.centerIn: parent; text: testNet ? (netKind === "local" ? "Test network · free test LGO" : "Logos testnet · test LGO") : networkName()
                           font.pixelSize: 12; font.weight: Font.DemiBold; color: testNet ? theme.warn : theme.good }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sheetMode = "testLgo" }
                }
                Item { Layout.fillWidth: true }
                Rectangle {   // running operation, when its sheet is closed
                    visible: opRunning && sheetMode !== "op"
                    implicitHeight: 34; implicitWidth: bgRow.implicitWidth + 24; radius: 17; color: theme.accentSoft
                    Row { id: bgRow; anchors.centerIn: parent; spacing: 8
                          Spinner { size: 14; anchors.verticalCenter: parent.verticalCenter }
                          Text { text: (root.width < 900 ? "" : (op ? op.steps[opStep].label : "") + "… ") + elapsed(); color: theme.accent; font.pixelSize: 13; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter } }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sheetMode = "op" }
                }
                Text { visible: copiedNote !== "" && sheetMode === "" && root.width >= 760; text: copiedNote; color: theme.good; font.pixelSize: 13; font.weight: Font.DemiBold }
                LinkText { objectName: "helpLink"; text: root.width < 640 ? "?" : "How it works"; font.pixelSize: 14; onClicked: sheetMode = "help" }
                PrimaryButton { objectName: "newVesting"; text: root.width < 640 ? "Vest" : "+  Vest tokens"; Layout.fillWidth: false; implicitHeight: 40; onClicked: startCreate() }
                Rectangle {
                    objectName: "settingsButton"
                    implicitWidth: 40; implicitHeight: 40; radius: 20
                    color: gearMouse.containsMouse ? theme.surface2 : "transparent"
                    Text { anchors.centerIn: parent; text: "⚙"; font.pixelSize: 22; color: theme.text2 }
                    MouseArea { id: gearMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sheetMode = "settings" }
                }
            }
        }

        // ---- pages (scroll; the scroll bar is always shown when there is more below) -------------
        Flickable {
            id: flick
            objectName: "pageFlick"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: pageCol.implicitHeight + 48
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: flick.contentHeight > flick.height + 1 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }

            ColumnLayout {
                id: pageCol
                width: Math.min(700, flick.width - 40)
                x: (flick.width - width) / 2
                y: 20
                spacing: 16

                // ================= Home =================
                ColumnLayout {
                    visible: page === "home"
                    Layout.fillWidth: true
                    spacing: 16
                    StateCards {}

                    Card {   // the test LGO, explained once (always reachable from the wallet card)
                        objectName: "introCard"
                        visible: ready && netKind === "local" && !introSeen
                        color: theme.warnSoft
                        border.color: "#F2E2B3"
                        spacing: 10
                        RowLayout { spacing: 10; Pill { text: "TEST NETWORK"; tone: "warn" } Label2 { text: "Where did these LGO come from?"; font.pixelSize: 16; font.weight: Font.Bold } }
                        Label2 { text: "These " + units(totalGenesis()) + " LGO are free test tokens your local test network created for " + genesisCount() + " demo accounts when it started. On the real network you bring your own LGO from your Logos wallet."; lineHeight: 1.2 }
                        Caption { visible: cmp(sumOf(pubAccounts, "balance"), totalGenesis()) !== 0; text: "Your wallet has " + tok(sumOf(pubAccounts, "balance")) + " now: the rest is locked in vesting accounts or was paid as network costs." }
                        Caption { text: "They have no value and never leave this computer, so try anything: vest them to your other account and claim them back." }
                        RowLayout { spacing: 16
                            SoftButton { objectName: "introOk"; text: "Got it"; onClicked: dismissIntro() }
                            LinkText { text: "How do I get real LGO?"; onClicked: sheetMode = "addTokens" } }
                    }
                    Rectangle {   // testnet (not local): one line
                        visible: ready && netKind === "testnet"
                        Layout.fillWidth: true
                        implicitHeight: tnRow.implicitHeight + 20
                        radius: 14
                        color: theme.warnSoft
                        RowLayout { id: tnRow; x: 14; y: 10; width: parent.width - 28; spacing: 10
                            Pill { text: "TEST"; tone: "warn" }
                            Label2 { text: "You're on the Logos testnet. Its LGO are test tokens with no value."; font.pixelSize: 13; color: theme.warn }
                            Hint { tip: terms.testNet } }
                    }

                    Card {   // the wallet: accounts with balances, the one in use, receive / add / vest
                        objectName: "walletCard"
                        visible: ready && !!acct
                        spacing: 10
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text { text: "Your wallet"; font.pixelSize: 17; font.weight: Font.Bold; color: theme.text }
                            Hint { tip: terms.account }
                            Item { Layout.fillWidth: true }
                            LinkText { objectName: "testLgoLink"; visible: testNet && !(netKind === "local" && !introSeen); text: netKind === "local" ? "Where did these LGO come from?" : "About test LGO"; font.pixelSize: 13; onClicked: sheetMode = "testLgo" }
                        }
                        Caption { text: tok(sumOf(pubAccounts, "balance")) + " in " + fundedAccounts.length + (fundedAccounts.length === 1 ? " account" : " accounts") + (emptyCount > 0 ? " (and " + emptyCount + " empty)" : "") + ". Pick the one you're using."; Layout.topMargin: -6 }
                        Repeater {
                            model: pubAccounts.filter(function (a) { return showEmptyAccounts || !isZero(a.balance) || (acct && a.id === acct.id) })
                            AccountRow { objectName: "acctRow"; account: modelData; selected: !!acct && acct.id === modelData.id; note: selected ? "in use" : ""; onPicked: acctIndex = acctPos(modelData.id) }
                        }
                        LinkText { visible: emptyCount > 0; text: showEmptyAccounts ? "Hide empty accounts" : "Show " + emptyCount + " empty " + (emptyCount === 1 ? "account" : "accounts"); font.pixelSize: 13; onClicked: showEmptyAccounts = !showEmptyAccounts }
                        Divider { Layout.topMargin: 2 }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            FieldLabel { text: acct ? acctLabel(acct.id) : "" }
                            LinkText { objectName: "renameLink"; text: "Rename"; font.pixelSize: 12; onClicked: { renameId = acct.id; sheetMode = "rename" } }
                            Item { Layout.fillWidth: true }
                            CopyButton { objectName: "copyAddress"; value: acct ? acct.id : ""; note: "Address copied"; label: "Copy address" }
                        }
                        Text { text: acct ? acct.id : ""; font.family: theme.mono; font.pixelSize: 12; color: theme.text2; elide: Text.ElideMiddle; Layout.fillWidth: true; Layout.topMargin: -4 }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Big { objectName: "balanceText"; text: acct ? tok(acct.balance) : ""; Layout.fillWidth: false; font.pixelSize: 30 }
                            Hint { tip: terms.lgo }
                            Item { Layout.fillWidth: true }
                        }
                        Caption { text: (netKind === "local" ? "Free test LGO" : netKind === "testnet" ? "Test LGO" : "LGO") + " in " + (acct ? acctLabel(acct.id) : "") + ", free to spend or to vest."; Layout.topMargin: -8 }
                        Notice {
                            visible: !!acct && isZero(acct.balance)
                            tone: "warn"
                            text: "This account has no LGO yet. Pick a funded account above, or add LGO to this one (Add LGO)."
                        }
                        RowLayout {
                            visible: privAccounts.length > 0
                            Layout.fillWidth: true
                            spacing: 8
                            Caption { text: "Private balance: " + tok(sumOf(privAccounts, "balance")); Layout.fillWidth: false }
                            Hint { tip: terms.privateBalance }
                            Item { Layout.fillWidth: true }
                            LinkText { objectName: "receiveLink"; text: "Check for private payments"; font.pixelSize: 13; enabled: !opRunning; onClicked: receiveNow() }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 10
                            PrimaryButton { objectName: "homeVest"; text: "Vest tokens"; Layout.preferredWidth: 2; enabled: !!acct && !isZero(acct.balance); onClicked: startCreate() }
                            SoftButton { objectName: "receiveButton"; text: "Receive"; Layout.fillWidth: true; Layout.preferredWidth: 1; implicitHeight: 52; onClicked: sheetMode = "receive" }
                            SoftButton { objectName: "addTokensButton"; text: "Add LGO"; Layout.fillWidth: true; Layout.preferredWidth: 1; implicitHeight: 52; onClicked: sheetMode = "addTokens" }
                        }
                    }

                    Card {   // where your LGO are: the money flow
                        objectName: "flowCard"
                        visible: ready && (outgoing.length > 0 || incoming.length > 0)
                        spacing: 12
                        RowLayout { spacing: 8; Text { text: "Where your LGO are"; font.pixelSize: 17; font.weight: Font.Bold; color: theme.text } Hint { tip: terms.escrow } }
                        Caption { text: "Vested LGO don't sit in anyone's wallet. Each vesting has its own vesting account, held by the vesting program, and the recipient claims from it as parts unlock."; Layout.topMargin: -6 }
                        Caption { visible: outgoing.length > 0; text: "Vestings you created"; font.weight: Font.DemiBold; color: theme.text }
                        MoneyFlow {
                            visible: outgoing.length > 0
                            a: ({ title: "Your wallet", name: fundedAccounts.length + (fundedAccounts.length === 1 ? " account" : " accounts"), amount: tok(sumOf(pubAccounts, "balance")), sub: "free to use" })
                            ab: "you vested " + tokShort(sumOf(outgoing, "total"))
                            b: ({ title: "Locked in vestings", name: outgoing.length + (outgoing.length === 1 ? " vesting account" : " vesting accounts") + ", held by the vesting program", amount: tok(sumOf(outgoing, "escrow")),
                                  sub: tok(sumOf(outgoing, "locked")) + " still locked · " + tok(sumOf(outgoing, "claimable")) + " unlocked, not claimed yet", tone: "lock", tip: terms.escrow })
                            bc: "they claim"
                            c: ({ title: "Recipients", name: recipientsText(outgoing), amount: tok(sumOf(outgoing, "claimed")), sub: "claimed so far", tone: "good" })
                        }
                        Caption { visible: incoming.length > 0; text: "Vestings for you"; font.weight: Font.DemiBold; color: theme.text; Layout.topMargin: 4 }
                        MoneyFlow {
                            visible: incoming.length > 0
                            a: ({ title: "From", name: sendersText(incoming), sub: "vested " + tok(sumOf(incoming, "total")) + " for you" })
                            ab: "locked"
                            b: ({ title: "Locked for you", name: incoming.length + (incoming.length === 1 ? " vesting account" : " vesting accounts") + ", held by the vesting program", amount: tok(sumOf(incoming, "escrow")),
                                  sub: tok(sumOf(incoming, "claimable")) + " ready to claim · " + tok(sumOf(incoming, "locked")) + " still locked", tone: "lock", tip: terms.escrow })
                            bc: "you claim"
                            c: ({ title: "Your wallet", name: incomingAccountsText(), amount: tok(sumOf(incoming, "claimed")), sub: "claimed so far", tone: "good" })
                        }
                    }

                    // ---- coming to you ----
                    SectionHeader {
                        visible: ready
                        title: "Coming to you"
                        tip: terms.vesting
                        sub: "Vestings for any of your accounts. They appear here by themselves."
                    }
                    Card {   // summary: ready now, locked, next unlock
                        id: sumCard
                        objectName: "incomingSummary"
                        visible: ready && incoming.length > 0
                        property var nx: nextAcross(incoming)
                        spacing: 12
                        RowLayout {
                            Layout.fillWidth: true
                            Stat { label: "Ready to claim now"; value: tok(sumOf(incoming, "claimable")) }
                            Stat { label: "Still locked"; value: tok(sumOf(incoming, "locked")) }
                            Stat { label: "Claimed so far"; value: tok(sumOf(incoming, "claimed")) }
                        }
                        Divider {}
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Caption { text: "Next unlock"; font.weight: Font.DemiBold }
                                Label2 { text: sumCard.nx ? nextLine(sumCard.nx.s, false) : "Everything has unlocked." }
                            }
                            Rectangle {
                                visible: !!sumCard.nx && sumCard.nx.n.kind === "time"
                                implicitHeight: 44; implicitWidth: cdText.implicitWidth + 28; radius: 12; color: theme.accentSoft
                                Text { id: cdText; anchors.centerIn: parent; text: sumCard.nx && sumCard.nx.n.kind === "time" ? "in " + countdown(sumCard.nx.n.at) : ""
                                       font.pixelSize: 16; font.weight: Font.DemiBold; color: theme.accent; font.family: theme.mono }
                            }
                        }
                    }
                    Repeater {
                        model: ready ? incoming : []
                        Card {
                            id: inCard
                            property var s: modelData
                            property var nx: nextOf(modelData)
                            spacing: 10
                            RowLayout {
                                Layout.fillWidth: true
                                Caption { text: (isMine(inCard.s.creator) ? "From your " + acctLabel(inCard.s.creator) : "From " + shortId(inCard.s.creator)) + "  →  vesting account " + shortId(inCard.s.schedule) + "  →  your " + acctLabel(inCard.s.beneficiary); Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                                Pill { text: inCard.s.cancelled ? "Stopped" : ""; tone: "bad" }
                                Pill { text: !inCard.s.cancelable && !inCard.s.cancelled ? "Permanent" : ""; tone: "plain" }
                            }
                            RowLayout {
                                spacing: 8
                                Big { text: tok(inCard.s.claimable); font.pixelSize: 28; Layout.fillWidth: false }
                                Hint { tip: terms.claim }
                            }
                            Caption { text: "ready to claim into your " + acctLabel(inCard.s.beneficiary); Layout.topMargin: -8 }
                            Progress { unlocked: frac(inCard.s.vested, inCard.s.total); claimed: frac(inCard.s.claimed, inCard.s.total); Layout.topMargin: 4 }
                            Caption { text: units(inCard.s.vested) + " of " + tok(inCard.s.total) + " unlocked · " + units(inCard.s.claimed) + " claimed · " + units(inCard.s.locked) + " still locked" }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Label2 { text: nextLine(inCard.s, false) }
                                Pill { text: inCard.nx.kind === "time" ? "in " + countdown(inCard.nx.at) : ""; tone: "accent" }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                PrimaryButton {
                                    objectName: "cardClaim"
                                    text: isZero(inCard.s.claimable) ? "Nothing to claim yet" : "Claim " + tok(inCard.s.claimable)
                                    enabled: !isZero(inCard.s.claimable) && !opRunning
                                    onClicked: openClaim(inCard.s)
                                }
                                SoftButton { objectName: "cardDetails"; text: "Details"; implicitHeight: 52; onClicked: openDetail(inCard.s, "recipient") }
                            }
                        }
                    }
                    Card {   // nothing coming yet
                        objectName: "incomingEmpty"
                        visible: ready && incoming.length === 0
                        Label2 { text: "Nothing coming to you yet"; font.pixelSize: 17; font.weight: Font.DemiBold }
                        Caption { text: "When someone vests LGO for one of your addresses, it shows up here by itself. No code needed. Give them the address of " + (acct ? acctLabel(acct.id) : "your account") + ":" }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text { text: acct ? acct.id : ""; font.family: theme.mono; font.pixelSize: 12; color: theme.text; elide: Text.ElideMiddle; Layout.fillWidth: true }
                            CopyButton { value: acct ? acct.id : ""; note: "Address copied" }
                        }
                        Caption { visible: pubAccounts.length > 1; text: "Trying it out? Vest some LGO to your other account: press Vest tokens and pick “My other account”."; font.pixelSize: 12 }
                    }
                    RowLayout {   // search progress + manual code entry (fallback)
                        visible: ready
                        Layout.fillWidth: true
                        Layout.leftMargin: 4; Layout.rightMargin: 4
                        spacing: 8
                        Spinner { visible: !!scan && !scan.done; size: 14 }
                        Caption {
                            Layout.fillWidth: true
                            font.pixelSize: 12
                            text: scan && !scan.done ? "Looking for vestings sent to you… checked " + fmt(String(scan.next - 1)) + " of " + fmt(String(scan.tip)) + " blocks"
                                  : "Checked the whole network for vestings to your addresses."
                        }
                        LinkText { objectName: "codeLink"; text: codeEntryOpen ? "Hide" : "Have a vesting code?"; font.pixelSize: 12; onClicked: codeEntryOpen = !codeEntryOpen }
                    }
                    Card {
                        visible: ready && codeEntryOpen
                        Caption { text: "Only needed if the sender used another app and sent you a code. " + terms.code }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Field { id: codeField; objectName: "codeField"; placeholderText: "Paste the vesting code (vesting:…)"; onTextChanged: addCard.err = "" }
                            SoftButton {
                                text: addCard.adding ? "Adding…" : "Add"
                                implicitHeight: 48
                                enabled: codeField.text.trim() !== "" && !addCard.adding
                                onClicked: { addCard.adding = true; addCode(codeField.text, function (err) { addCard.adding = false; addCard.err = err; if (!err) { codeField.text = ""; codeEntryOpen = false } }) }
                            }
                        }
                        QtObject { id: addCard; property bool adding: false; property string err: "" }
                        Caption { visible: addCard.err !== ""; text: addCard.err; color: theme.bad }
                    }

                    // ---- created by you ----
                    SectionHeader {
                        visible: ready
                        title: "Created by you"
                        tip: terms.escrow
                        sub: "Vestings you made. Their LGO are in their own vesting accounts until the recipient claims them."
                    }
                    Card {
                        visible: ready && outgoing.length === 0
                        Label2 { text: "You haven't vested any LGO yet"; font.pixelSize: 17; font.weight: Font.DemiBold }
                        Caption { text: "Lock LGO for someone, like a salary or a team grant. They move into a vesting account that only the vesting program controls, and unlock bit by bit for the recipient." }
                        PrimaryButton { text: "Vest tokens"; onClicked: startCreate() }
                    }
                    Repeater {
                        model: ready ? outgoing : []
                        Card {
                            id: outCard
                            property var s: modelData
                            spacing: 10
                            color: outMouse.containsMouse ? "#F2F2F6" : theme.surface
                            RowLayout {
                                Layout.fillWidth: true
                                Caption { text: "Your " + acctLabel(outCard.s.creator) + "  →  vesting account " + shortId(outCard.s.schedule) + "  →  " + (isMine(outCard.s.beneficiary) ? "your " + acctLabel(outCard.s.beneficiary) : shortId(outCard.s.beneficiary)); Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                                Pill { text: statusOf(outCard.s).text; tone: statusOf(outCard.s).tone }
                                Pill { text: !outCard.s.cancelable && !outCard.s.cancelled ? "Permanent" : ""; tone: "plain" }
                            }
                            Label2 { text: tok(outCard.s.total); font.pixelSize: 22; font.weight: Font.DemiBold }
                            Caption { text: shapeText(outCard.s) + " · " + tok(outCard.s.escrow) + " still in the vesting account"; Layout.topMargin: -6 }
                            Progress { unlocked: frac(outCard.s.vested, outCard.s.total); claimed: frac(outCard.s.claimed, outCard.s.total) }
                            Caption { text: units(outCard.s.vested) + " unlocked · " + units(outCard.s.claimed) + " claimed by the recipient" }
                            RowLayout {
                                Layout.fillWidth: true
                                Label2 { text: nextLine(outCard.s, true); font.pixelSize: 13 }
                                Text { text: "Manage ›"; color: theme.accent; font.pixelSize: 14; font.weight: Font.DemiBold }
                            }
                            MouseArea { id: outMouse; objectName: "sentCard"; parent: outCard; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: openDetail(outCard.s, "creator") }
                        }
                    }
                }

                // ================= Vesting detail =================
                ColumnLayout {
                    id: detailPage
                    visible: page === "detail"
                    Layout.fillWidth: true
                    spacing: 16
                    property var nx: nextOf(ds)
                    property bool both: !!ds && isMine(ds.creator) && isMine(ds.beneficiary)
                    LinkText { objectName: "backLink"; text: "‹  Back"; onClicked: page = backPage }
                    Card {
                        visible: !ds
                        RowLayout { spacing: 12; Spinner { visible: refreshing } Label2 { text: refreshing ? "Loading the vesting…" : "This vesting isn't in your list anymore." } }
                    }
                    RowLayout {   // both ends are mine: switch sides in one click
                        visible: detailPage.both
                        Layout.fillWidth: true
                        spacing: 8
                        Caption { text: "View as"; Layout.fillWidth: false }
                        Chip { objectName: "roleSender"; text: "Sender · " + (ds ? acctLabel(ds.creator) : ""); selected: detailRole === "creator"; onClicked: detailRole = "creator" }
                        Chip { objectName: "roleRecipient"; text: "Recipient · " + (ds ? acctLabel(ds.beneficiary) : ""); selected: detailRole === "recipient"; onClicked: { detailRole = "recipient"; acctIndex = acctPos(ds.beneficiary) } }
                        Item { Layout.fillWidth: true }
                    }
                    Card {
                        visible: !!ds
                        spacing: 12
                        RowLayout {
                            Layout.fillWidth: true
                            Caption { text: ds ? (detailRole === "creator" ? "You vested for " + whoIs(ds.beneficiary) : (isMine(ds.creator) ? "From your " + acctLabel(ds.creator) : "From " + shortId(ds.creator)) + " for your " + acctLabel(ds.beneficiary)) : ""; Layout.fillWidth: true }
                            Pill { text: statusOf(ds).text; tone: statusOf(ds).tone }
                            Pill { text: ds && !ds.cancelable && !ds.cancelled ? "Permanent" : ""; tone: "plain" }
                        }
                        RowLayout {
                            spacing: 8
                            Big { text: ds ? tok(detailRole === "creator" ? ds.total : ds.claimable) : ""; Layout.fillWidth: false }
                            Hint { tip: detailRole === "creator" ? terms.vesting : terms.claim }
                        }
                        Caption { text: detailRole === "creator" ? "vested · " + shapeText(ds) : "ready to claim now into your " + (ds ? acctLabel(ds.beneficiary) : ""); Layout.topMargin: -8 }
                        PrimaryButton {
                            objectName: "detailClaim"
                            visible: detailRole === "recipient"
                            text: ds && isZero(ds.claimable) ? "Nothing to claim yet" : ds ? "Claim " + tok(ds.claimable) : ""
                            enabled: !!ds && !isZero(ds.claimable) && !opRunning
                            onClicked: openClaim(ds)
                        }
                        MoneyFlow {
                            objectName: "detailFlow"
                            a: ({ title: detailRole === "creator" ? "From you" : "From", name: ds ? (isMine(ds.creator) ? acctLabel(ds.creator) : "The sender") : "", addr: ds ? shortId(ds.creator) : "", amount: ds ? tok(ds.total) : "", sub: "paid in when it was created" })
                            ab: "locked"
                            b: ({ title: "Vesting account", name: "Held by the vesting program", addr: ds ? shortId(ds.schedule) : "", amount: ds ? tok(ds.escrow) : "", sub: ds ? tok(ds.locked) + " still locked · " + tok(ds.claimable) + " unlocked, ready to claim" : "", tone: "lock", tip: terms.escrow })
                            bc: "claims"
                            c: ({ title: "To", name: ds ? (isMine(ds.beneficiary) ? acctLabel(ds.beneficiary) : "The recipient") : "", addr: ds ? shortId(ds.beneficiary) : "", amount: ds ? tok(ds.claimed) : "", sub: "claimed so far", tone: "good" })
                        }
                        Rectangle {   // next unlock, with the exact time and a live countdown
                            objectName: "nextUnlockBox"
                            Layout.fillWidth: true
                            radius: 14
                            color: theme.accentSoft
                            implicitHeight: nuCol.implicitHeight + 24
                            ColumnLayout {
                                id: nuCol
                                x: 14; y: 12; width: parent.width - 28
                                spacing: 4
                                Text { text: "Next unlock"; color: theme.accent; font.pixelSize: 12; font.weight: Font.DemiBold }
                                Label2 { text: ds ? nextLine(ds, detailRole === "creator") : "" }
                                Text {
                                    visible: detailPage.nx.kind === "time"
                                    text: detailPage.nx.kind === "time" ? "in " + countdown(detailPage.nx.at) : ""
                                    color: theme.accent; font.pixelSize: 24; font.weight: Font.DemiBold; font.family: theme.mono
                                }
                                Caption { visible: detailPage.nx.kind === "time" || detailPage.nx.kind === "flowing"; text: "Times are in this computer's time zone."; font.pixelSize: 12 }
                            }
                        }
                        UnlockChart {
                            Layout.topMargin: 6
                            kind: ds && ds.kind.milestones ? "milestones" : "linear"
                            start: ds && ds.kind.linear ? ds.kind.linear.start : 0
                            cliff: ds && ds.kind.linear ? ds.kind.linear.cliff : 0
                            end: ds && ds.kind.linear ? ds.kind.linear.end : 1
                            amounts: ds && ds.kind.milestones ? ds.kind.milestones : []
                            done: ds && ds.kind.milestones ? ds.kind.milestones.map(function (x, i) { return milestoneDone(ds, i) }) : []
                            now: Math.floor(nowMs() / 60000) * 60000
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Stat { label: "Unlocked so far"; value: ds ? tok(ds.vested) : "" }
                            Stat { label: detailRole === "creator" ? "Claimed by recipient" : "Claimed"; value: ds ? tok(ds.claimed) : "" }
                            Stat { label: "Still locked"; value: ds ? tok(ds.locked) : "" }
                        }
                        Notice {   // creator view of a vesting to my own account: the other side is one click away
                            visible: !!ds && detailRole === "creator" && isMine(ds.beneficiary)
                            tone: "accent"
                            text: "The recipient is your own " + (ds ? acctLabel(ds.beneficiary) : "") + ". Switch to “Recipient” above to see what they see and claim."
                        }
                        RowLayout {
                            visible: !!ds && !!ds.kind.milestones && detailRole === "creator"
                            spacing: 8
                            FieldLabel { text: "Milestones" }
                            Hint { tip: terms.milestones }
                        }
                        Repeater {   // milestones: the sender confirms them
                            model: ds && ds.kind.milestones && detailRole === "creator" ? ds.kind.milestones.length : 0
                            RowLayout {
                                id: msRow
                                Layout.fillWidth: true
                                property bool isDone: milestoneDone(ds, index)
                                Label2 { text: "Milestone " + (index + 1) + " · " + tok(ds.kind.milestones[index]); Layout.fillWidth: true }
                                Pill { visible: msRow.isDone; text: "Unlocked"; tone: "good" }
                                SoftButton { objectName: "msConfirm"; visible: !msRow.isDone; small: true; text: "Confirm"; enabled: !opRunning && !ds.cancelled; onClicked: askMilestone(ds, index) }
                            }
                        }
                    }
                    Card {   // sender: manage
                        visible: !!ds && detailRole === "creator"
                        RowLayout { spacing: 8; FieldLabel { text: "Manage" } Hint { tip: terms.stop + " " + terms.permanent } }
                        Caption {
                            text: !ds ? "" : ds.cancelled ? "This vesting was stopped on " + fmtDate(ds.cancelled.at) + ". Nothing more will unlock."
                                  : !ds.cancelable ? "This vesting is permanent: it can't be stopped."
                                  : "You can stop this vesting at any time: what already unlocked stays in the vesting account for the recipient, the locked rest comes back to you. Or make it permanent to guarantee the recipient every LGO."
                        }
                        RowLayout {
                            visible: !!ds && ds.cancelable && !ds.cancelled
                            spacing: 10
                            SoftButton { objectName: "stopVesting"; text: "Stop vesting"; danger: true; enabled: !opRunning; onClicked: askStop(ds) }
                            SoftButton { objectName: "makePermanent"; text: "Make permanent"; enabled: !opRunning; onClicked: askPermanent(ds) }
                        }
                        Caption { text: "The recipient sees this vesting in their Vesting app by themselves."; font.pixelSize: 12 }
                    }
                    Card {   // recipient: give away
                        visible: !!ds && detailRole === "recipient" && ds.transferable && !ds.cancelled
                        RowLayout { spacing: 8; FieldLabel { text: "Give to another account" } Hint { tip: terms.transferable } }
                        Caption { text: "The new recipient gets everything still to claim. The LGO stay in the same vesting account; only who may claim changes. You can't undo this." }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Field { id: giveField; objectName: "giveField"; placeholderText: "New recipient's address" }
                            SoftButton { objectName: "giveButton"; text: "Give"; implicitHeight: 48; enabled: validAccount(giveField.text) && !opRunning; onClicked: askGive(ds, giveField.text.trim()) }
                        }
                    }
                    Card {
                        visible: !!ds
                        Expander {
                            InfoRow { label: "Starts"; visible: !!ds && !!ds.kind.linear; value: ds && ds.kind.linear ? whenFull(ds.kind.linear.start) : "" }
                            InfoRow { label: "First unlock (end of waiting period)"; visible: !!ds && !!ds.kind.linear && ds.kind.linear.cliff > ds.kind.linear.start; value: ds && ds.kind.linear ? whenFull(ds.kind.linear.cliff) : "" }
                            InfoRow { label: "Fully unlocked"; visible: !!ds && !!ds.kind.linear; value: ds && ds.kind.linear ? whenFull(ds.kind.linear.end) : "" }
                            InfoRow { label: "In the vesting account now"; value: ds ? tok(ds.escrow) : "" }
                            InfoRow { label: "Sender can stop it"; value: ds ? (ds.cancelable ? "Yes" : "No, it's permanent") : "" }
                            InfoRow { label: "Recipient can give it away"; value: ds ? (ds.transferable ? "Yes" : "No") : "" }
                            InfoRow { label: "Sender"; value: ds ? ds.creator : ""; monoValue: true }
                            InfoRow { label: "Recipient"; value: ds ? ds.beneficiary : ""; monoValue: true }
                            InfoRow { label: "Vesting account (program-owned)"; value: ds ? ds.schedule : ""; monoValue: true }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Text { text: "Vesting code"; color: theme.text2; font.pixelSize: 14 }
                                Hint { tip: terms.code }
                                Text { text: codeFor(ds); font.family: theme.mono; font.pixelSize: 12; color: theme.text; elide: Text.ElideMiddle; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight }
                                CopyButton { value: codeFor(ds); note: "Code copied" }
                            }
                        }
                    }
                }

                // ================= Vest tokens (stepper) =================
                ColumnLayout {
                    id: createPage
                    visible: page === "create"
                    Layout.fillWidth: true
                    spacing: 14
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "Vest tokens"; font.pixelSize: 24; font.weight: Font.Bold; color: theme.text; Layout.fillWidth: true }
                        LinkText { objectName: "bulkLink"; text: "Send to many people"; font.pixelSize: 13; onClicked: page = "bulk" }
                    }
                    Caption { text: "Lock LGO in a vesting account for someone. They unlock bit by bit on your schedule, and the person claims them as they unlock."; Layout.topMargin: -8 }
                    StateCards {}
                    Stepper { visible: ready }

                    // ---- 1 Who ----
                    Card {
                        objectName: "stepWho"
                        visible: ready && createStep === 1
                        spacing: 10
                        RowLayout { spacing: 8; Text { text: "Paying from"; font.pixelSize: 16; font.weight: Font.Bold; color: theme.text } Hint { tip: "The account the LGO leave. Its balance must cover the amount." } }
                        Repeater {
                            model: pubAccounts.filter(function (a) { return showEmptyFrom || !isZero(a.balance) || (acct && a.id === acct.id) })
                            AccountRow { objectName: "fromRow"; account: modelData; selected: !!acct && acct.id === modelData.id; onPicked: { acctIndex = acctPos(modelData.id); if (form.to.trim() === modelData.id) form.to = "" } }
                        }
                        LinkText { visible: emptyCount > 0; text: showEmptyFrom ? "Hide empty accounts" : "Show " + emptyCount + " empty " + (emptyCount === 1 ? "account" : "accounts"); font.pixelSize: 13; onClicked: showEmptyFrom = !showEmptyFrom }
                        Divider { Layout.topMargin: 4 }
                        RowLayout { spacing: 8; Layout.topMargin: 4; Text { text: "Sending to"; font.pixelSize: 16; font.weight: Font.Bold; color: theme.text } Hint { tip: "Who receives the LGO as they unlock. They claim them from the vesting account into their own." } }
                        RowLayout {
                            spacing: 8
                            Chip { objectName: "toModeMine"; visible: pubAccounts.length > 1; text: "My other account"; selected: toMode === "mine"; onClicked: { toMode = "mine"; if (!isMine(form.to.trim())) form.to = "" } }
                            Chip { objectName: "toModeOther"; text: "Someone else"; selected: toMode === "other" || pubAccounts.length < 2; onClicked: { toMode = "other"; if (isMine(form.to.trim())) form.to = "" } }
                        }
                        ColumnLayout {
                            visible: toMode === "mine" && pubAccounts.length > 1
                            Layout.fillWidth: true
                            spacing: 8
                            Repeater {   // funded accounts first; empty ones (also fine to receive) behind "Show"
                                model: toChoices()
                                AccountRow { objectName: "toMineRow"; account: modelData; selected: form.to.trim() === modelData.id; onPicked: form.to = modelData.id }
                            }
                            LinkText { visible: toChoicesHidden() > 0 || showAllTo; text: showAllTo ? "Show fewer" : "Show " + toChoicesHidden() + " more (empty) " + (toChoicesHidden() === 1 ? "account" : "accounts"); font.pixelSize: 13; onClicked: showAllTo = !showAllTo }
                            Caption { text: "Handy for trying it out: you'll see both sides, the sender's and the recipient's."; font.pixelSize: 12 }
                        }
                        ColumnLayout {
                            visible: toMode === "other" || pubAccounts.length < 2
                            Layout.fillWidth: true
                            spacing: 6
                            Field { objectName: "toField"; placeholderText: "Paste the recipient's LEZ address"; text: form.to; onTextChanged: form.to = text; font.family: form.to === "" ? Qt.application.font.family : theme.mono; font.pixelSize: form.to === "" ? 15 : 13 }
                            Caption { objectName: "toCheck"; visible: toCheck().text !== ""; text: toCheck().text; color: toCheck().tone === "bad" ? theme.bad : theme.good }
                            Caption { text: "They can copy it from Receive in their Vesting app."; font.pixelSize: 12; visible: form.to === "" }
                        }
                        Caption { text: terms.publicPrivate; font.pixelSize: 12; Layout.topMargin: 4 }
                    }

                    // ---- 2 How much ----
                    Card {
                        objectName: "stepAmount"
                        visible: ready && createStep === 2
                        spacing: 10
                        RowLayout { spacing: 8; Text { text: "How much to vest"; font.pixelSize: 16; font.weight: Font.Bold; color: theme.text } Hint { tip: terms.lgo } }
                        Field {
                            objectName: "amountField"
                            placeholderText: "0"; text: form.amount; onTextChanged: form.amount = text
                            font.pixelSize: 26; implicitHeight: 64
                            validator: RegularExpressionValidator { regularExpression: /[0-9 .,]*/ }
                            rightPadding: 70
                            Text { anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter; text: tokenName; color: theme.text2; font.pixelSize: 16; font.weight: Font.DemiBold }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Caption {
                                Layout.fillWidth: true
                                text: form.amount.trim() !== "" && !validAmount(form.amount) ? "Use a number like 1500 or 12.5 (up to 9 decimals)."
                                      : acct ? "Available in " + acctLabel(acct.id) + ": " + tok(acct.balance) : ""
                                color: form.amount.trim() !== "" && !validAmount(form.amount) ? theme.bad : theme.text2
                            }
                            Repeater {
                                model: [{ t: "25%", f: 4 }, { t: "50%", f: 2 }]
                                Chip { visible: !!acct && !isZero(acct.balance); text: modelData.t; onClicked: form.amount = units(divBy(acct.balance, modelData.f)).replace(/,/g, "") }
                            }
                            Chip { objectName: "useAll"; visible: !!acct && !isZero(acct.balance); text: "Max"; onClicked: form.amount = units(acct.balance).replace(/,/g, "") }
                        }
                        Notice {
                            visible: validAmount(form.amount) && !!acct && cmp(toBase(form.amount), acct.balance) <= 0
                            text: tok(toBase(form.amount) || "0") + " will leave " + acctLabel(acct ? acct.id : "") + " and go into a new vesting account for " + (validAccount(form.to) ? whoIs(form.to.trim()) : "the recipient") + ". " + acctLabel(acct ? acct.id : "") + " keeps " + tok(sub(acct ? acct.balance : "0", toBase(form.amount) || "0")) + "."
                        }
                    }

                    // ---- 3 Schedule ----
                    Card {
                        objectName: "stepSchedule"
                        visible: ready && createStep === 3
                        spacing: 12
                        RowLayout { spacing: 8; Text { text: "How it unlocks"; font.pixelSize: 16; font.weight: Font.Bold; color: theme.text } Hint { tip: terms.cliff } }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 8
                            Repeater {
                                model: [{ k: "1y3m", t: "1 year · first unlock after 3 months" }, { k: "4y1y", t: "4 years · first unlock after 1 year" }, { k: "6m", t: "6 months · starts now" },
                                        { k: "milestones", t: "When I confirm milestones" }, { k: "custom", t: "Custom" }]
                                Chip { objectName: "preset_" + modelData.k; text: modelData.t; selected: form.preset === modelData.k; onClicked: form.preset = modelData.k }
                            }
                        }
                        GridLayout {   // custom
                            visible: form.preset === "custom"
                            Layout.fillWidth: true
                            columns: 2; columnSpacing: 10; rowSpacing: 10
                            FieldLabel { text: "Lasts"; Layout.columnSpan: 2 }
                            Field { text: form.lastsN; onTextChanged: form.lastsN = text; Layout.preferredWidth: 90; Layout.fillWidth: false; validator: RegularExpressionValidator { regularExpression: /[0-9]*/ } }
                            Row { spacing: 6; Repeater { model: ["days", "months", "years"]; Chip { text: modelData; selected: form.lastsUnit === modelData; onClicked: form.lastsUnit = modelData } } }
                            FieldLabel { text: "Waiting period: nothing unlocks before it ends (0 = none)"; Layout.columnSpan: 2 }
                            Field { text: form.cliffN; onTextChanged: form.cliffN = text; Layout.preferredWidth: 90; Layout.fillWidth: false; validator: RegularExpressionValidator { regularExpression: /[0-9]*/ } }
                            Row { spacing: 6; Repeater { model: ["days", "months", "years"]; Chip { text: modelData; selected: form.cliffUnit === modelData; onClicked: form.cliffUnit = modelData } } }
                            FieldLabel { text: "Starts"; Layout.columnSpan: 2 }
                            Field { text: form.startText; onTextChanged: form.startText = text; placeholderText: "Now, or a date like 2027-01-31"; Layout.columnSpan: 2 }
                        }
                        ColumnLayout {   // milestones
                            visible: form.preset === "milestones"
                            Layout.fillWidth: true
                            spacing: 8
                            Caption { text: terms.milestones }
                            Repeater {
                                model: form.preset === "milestones" ? form.milestones.length : 0
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    Text { text: "Milestone " + (index + 1); color: theme.text2; font.pixelSize: 14; Layout.preferredWidth: 96 }
                                    Field {
                                        objectName: "msField"
                                        text: form.milestones[index]
                                        placeholderText: "Amount in " + tokenName
                                        validator: RegularExpressionValidator { regularExpression: /[0-9 .,]*/ }
                                        onTextChanged: { if (form.milestones[index] !== undefined && form.milestones[index] !== text) { var m = form.milestones.slice(); m[index] = text; form.milestones = m } }
                                    }
                                    LinkText { visible: form.milestones.length > 1; text: "Remove"; color: theme.text2; font.pixelSize: 13
                                               onClicked: { var m = form.milestones.slice(); m.splice(index, 1); form.milestones = m } }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                LinkText { visible: form.milestones.length < 64; text: "+ Add milestone"; onClicked: { var m = form.milestones.slice(); m.push(""); form.milestones = m } }
                                Item { Layout.fillWidth: true }
                                Caption {
                                    Layout.fillWidth: false
                                    text: "Milestones add up to " + tok(milestoneSum()) + (validAmount(form.amount) ? " of " + tok(toBase(form.amount)) : "")
                                    color: validAmount(form.amount) && cmp(milestoneSum(), toBase(form.amount)) !== 0 ? theme.bad : theme.text2
                                }
                            }
                        }
                        Rectangle {   // the schedule in one sentence and a chart
                            Layout.fillWidth: true
                            radius: 16
                            color: theme.bg
                            border.color: theme.border
                            implicitHeight: pvCol.implicitHeight + 28
                            ColumnLayout {
                                id: pvCol
                                x: 14; y: 14; width: parent.width - 28
                                spacing: 10
                                Label2 {
                                    objectName: "previewText"
                                    text: previewSentence(validAccount(form.to) ? (isMine(form.to.trim()) ? "Your " + acctLabel(form.to.trim()) : shortId(form.to.trim())) : "The recipient", form.amount)
                                    lineHeight: 1.2
                                }
                                UnlockChart {
                                    property var plan: form.preset === "milestones" ? null : planTimes(form.preset)
                                    kind: form.preset === "milestones" ? "milestones" : "linear"
                                    start: plan && plan.ok ? plan.start : 0
                                    cliff: plan && plan.ok ? plan.cliff : 0
                                    end: plan && plan.ok ? plan.end : 1
                                    amounts: form.preset === "milestones" ? form.milestones.map(function (x) { var b = toBase(x); return b ? Number(b) : 0 }) : []
                                    done: []
                                }
                            }
                        }
                        Expander {
                            title: "More options"
                            open: form.moreOpen
                            onOpenChanged: form.moreOpen = open
                            Toggle { text: "I can stop this vesting"; hint: terms.stop + " Turn off to make it permanent."; checked: form.cancelable; onToggled: form.cancelable = checked }
                            Toggle { objectName: "transferableToggle"; text: "Recipient can give it to another account"; hint: terms.transferable; checked: form.transferable; onToggled: form.transferable = checked }
                        }
                    }

                    // ---- 4 Review ----
                    Card {
                        id: reviewCard
                        objectName: "stepReview"
                        visible: ready && createStep === 4
                        spacing: 12
                        property string to: form.to.trim()
                        Caption { text: "You're vesting" }
                        Big { text: tok(toBase(form.amount) || "0"); font.pixelSize: 32; Layout.topMargin: -8 }
                        Caption { text: "for " + (validAccount(reviewCard.to) ? whoIs(reviewCard.to) : "?") + ", unlocking over time"; Layout.topMargin: -8 }
                        MoneyFlow {
                            objectName: "reviewFlow"
                            a: ({ title: "From", name: acct ? acctLabel(acct.id) : "", addr: acct ? shortId(acct.id) : "", amount: "−" + tok(toBase(form.amount) || "0"), sub: acct ? "keeps " + tok(sub(acct.balance, toBase(form.amount) || "0")) : "" })
                            ab: "locks"
                            b: ({ title: "New vesting account", name: "Held by the vesting program", amount: tok(toBase(form.amount) || "0"), sub: "made for this vesting; nobody has its key", tone: "lock", tip: terms.escrow })
                            bc: "claims as it unlocks"
                            c: ({ title: "To", name: isMine(form.to.trim()) ? acctLabel(form.to.trim()) : "The recipient", addr: shortId(form.to.trim()), amount: "0 " + tokenName + " now", sub: form.preset === "milestones" ? "parts unlock as you confirm milestones" : "unlocks on the schedule", tone: "good" })
                        }
                        Label2 { text: previewSentence(isMine(reviewCard.to) ? "Your " + acctLabel(reviewCard.to) : shortId(reviewCard.to), form.amount); lineHeight: 1.2 }
                        UnlockChart {
                            property var plan: form.preset === "milestones" ? null : planTimes(form.preset)
                            kind: form.preset === "milestones" ? "milestones" : "linear"
                            start: plan && plan.ok ? plan.start : 0
                            cliff: plan && plan.ok ? plan.cliff : 0
                            end: plan && plan.ok ? plan.end : 1
                            amounts: form.preset === "milestones" ? form.milestones.map(function (x) { var b = toBase(x); return b ? Number(b) : 0 }) : []
                            done: []
                        }
                        InfoRow { label: "To"; value: reviewCard.to; monoValue: true }
                        InfoRow { label: "You can stop it"; value: form.cancelable ? "Yes" : "No, it's permanent" }
                        InfoRow { label: "Recipient can give it away"; value: form.transferable ? "Yes" : "No" }
                        Notice { text: "When you press Vest, your wallet signs one transaction: the LGO leave " + (acct ? acctLabel(acct.id) : "your account") + " and go into the new vesting account. The recipient sees it in their Vesting app by themselves. A small network cost is paid from your account." }
                    }
                }

                // ================= Bulk =================
                ColumnLayout {
                    id: bulkPage
                    visible: page === "bulk"
                    Layout.fillWidth: true
                    spacing: 16
                    property var parsed: page === "bulk" ? parseBulk() : ({ ok: false, err: "" })
                    LinkText { text: "‹  Vest to one person"; onClicked: page = "create" }
                    Text { text: "Send to many people"; font.pixelSize: 24; font.weight: Font.Bold; color: theme.text }
                    StateCards {}
                    Card {
                        visible: ready
                        spacing: 14
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            FieldLabel { text: "Paying from" }
                            Caption { text: acct ? acctLabel(acct.id) + " (" + shortId(acct.id) + ") · " + tok(acct.balance) : ""; Layout.fillWidth: true }
                            LinkText { text: "Change"; font.pixelSize: 13; onClicked: { page = "create"; goStep(1) } }
                        }
                        Divider {}
                        Caption { text: bulk.json ? "Paste the JSON list (the CLI's create-batch format, see README). Amounts there are native units: 1 LGO = 1,000,000,000." : "One person per line: address, then the amount in LGO. Everyone gets the schedule you pick below. Up to 360 people at once." }
                        ScrollView {
                            Layout.fillWidth: true
                            implicitHeight: 140
                            TextArea {
                                id: bulkArea
                                objectName: "bulkArea"
                                text: bulk.json ? bulk.jsonText : bulk.lines
                                onTextChanged: { if (bulk.json) bulk.jsonText = text; else bulk.lines = text }
                                placeholderText: bulk.json ? '[{"beneficiary":"…","total":"1000000000","linear":[start_ms,cliff_ms,end_ms]}]' : "address, 1500\naddress, 250.5"
                                font.family: theme.mono; font.pixelSize: 13
                                color: theme.text
                                placeholderTextColor: theme.text3
                                wrapMode: TextEdit.WrapAnywhere
                                selectByMouse: true
                                background: Rectangle { radius: 14; color: theme.bg; border.width: bulkArea.activeFocus ? 2 : 1; border.color: bulkArea.activeFocus ? theme.accent : theme.border }
                            }
                        }
                        Caption {
                            visible: bulkPage.parsed.ok
                            text: bulkPage.parsed.ok ? bulkPage.parsed.count + (bulkPage.parsed.count === 1 ? " person · " : " people · ") + tok(bulkPage.parsed.total) + " in total" + (acct ? " (you have " + tok(acct.balance) + ")" : "") : ""
                        }
                        FieldLabel { visible: !bulk.json; text: "How it unlocks, for everyone"; Layout.topMargin: 4 }
                        Flow {
                            visible: !bulk.json
                            Layout.fillWidth: true
                            spacing: 8
                            Repeater {
                                model: [{ k: "1y3m", t: "1 year · first unlock after 3 months" }, { k: "4y1y", t: "4 years · first unlock after 1 year" }, { k: "6m", t: "6 months · starts now" }, { k: "custom", t: "Custom" }]
                                Chip { visible: modelData.k !== "custom" || form.preset === "custom"; text: modelData.t; selected: bulkPreset() === modelData.k; onClicked: form.preset = modelData.k }
                            }
                        }
                        Caption { visible: !bulk.json; text: bulkSentence() }
                        Expander {
                            title: "More options"
                            Toggle { text: "I can stop these vestings"; hint: terms.stop; checked: form.cancelable; onToggled: form.cancelable = checked }
                            Toggle { text: "Recipients can give them to another account"; checked: form.transferable; onToggled: form.transferable = checked }
                            Toggle { text: "Paste JSON instead"; hint: "For scripts: the same list format as the CLI's create-batch."; checked: bulk.json; onToggled: bulk.json = checked }
                        }
                        Caption { text: "Each person gets their own vesting account, held by the vesting program. All are created in one transaction."; font.pixelSize: 12 }
                    }
                }
            }
        }

        // ---- action bar: pinned under the page, never scrolled away or cut off -----------------
        Rectangle {
            objectName: "actionBar"
            visible: (page === "create" || page === "bulk") && ready
            Layout.fillWidth: true
            implicitHeight: 76
            color: theme.bg
            Divider { anchors.top: parent.top; width: parent.width }
            RowLayout {
                width: Math.min(700, parent.width - 40)
                x: (parent.width - width) / 2
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12
                SoftButton { objectName: "stepBack"; visible: page === "create"; text: createStep > 1 ? "‹  Back" : "Cancel"; implicitHeight: 52; onClicked: { if (createStep > 1) goStep(createStep - 1); else page = "home" } }
                Caption { visible: page === "create" && root.width >= 640; text: "Step " + createStep + " of 4"; Layout.fillWidth: false }
                Item { Layout.fillWidth: true }
                PrimaryButton {
                    objectName: "stepNext"
                    visible: page === "create" && createStep < 4
                    Layout.fillWidth: false
                    Layout.preferredWidth: Math.min(360, root.width * 0.55)
                    text: stepBlocker(createStep) || "Continue"
                    enabled: stepBlocker(createStep) === ""
                    onClicked: goStep(createStep + 1)
                }
                PrimaryButton {
                    objectName: "createConfirm"
                    visible: page === "create" && createStep === 4
                    Layout.fillWidth: false
                    Layout.preferredWidth: Math.min(360, root.width * 0.55)
                    text: createBlocker() || ("Vest " + tok(toBase(form.amount) || "0"))
                    enabled: createBlocker() === "" && !opRunning
                    busy: opRunning
                    onClicked: confirmCreate()
                }
                PrimaryButton {
                    objectName: "bulkReview"
                    visible: page === "bulk"
                    Layout.fillWidth: false
                    Layout.preferredWidth: Math.min(360, root.width * 0.55)
                    text: bulkBlocker(bulkPage.parsed) || "Review"
                    enabled: bulkBlocker(bulkPage.parsed) === "" && !opRunning
                    onClicked: sheetMode = "bulkReview"
                }
            }
        }
    }

    // =========================================================================================
    // Sheets: review / confirm / pending / success / error / settings / receive / add LGO / help
    // =========================================================================================
    Rectangle {
        id: overlay
        anchors.fill: parent
        visible: sheetMode !== ""
        color: "#73000000"
        z: 100
        MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: closeSheet() }
        Rectangle {
            id: sheet
            width: Math.min(sheetMode === "op" && opDone && opDone.created ? 640 : sheetMode === "help" || sheetMode === "addTokens" || sheetMode === "testLgo" ? 540 : 480, root.width - 32)
            height: Math.min(sheetFlick.contentHeight + 48, root.height - 48)
            anchors.centerIn: parent
            radius: 24
            color: theme.bg
            border.color: theme.border
            MouseArea { anchors.fill: parent }    // keep clicks inside the sheet
            Flickable {
                id: sheetFlick
                objectName: "sheetFlick"
                anchors.fill: parent
                anchors.margins: 24
                clip: true
                contentWidth: width
                contentHeight: sheetLoader.item ? sheetLoader.item.implicitHeight : 0
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: sheetFlick.contentHeight > sheetFlick.height + 1 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }
                Loader {
                    id: sheetLoader
                    width: sheetFlick.width - (sheetFlick.contentHeight > sheetFlick.height + 1 ? 14 : 0)
                    sourceComponent: sheetMode === "claim" ? claimSheet : sheetMode === "confirm" ? confirmSheet
                                   : sheetMode === "bulkReview" ? bulkSheet
                                   : sheetMode === "op" ? opSheet : sheetMode === "settings" ? settingsSheet
                                   : sheetMode === "receive" ? receiveSheet : sheetMode === "addTokens" ? addTokensSheet
                                   : sheetMode === "help" ? helpSheet : sheetMode === "testLgo" ? testLgoSheet
                                   : sheetMode === "rename" ? renameSheet : null
                }
            }
            Text {
                visible: sheetMode !== "op" || !opRunning
                anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 20
                objectName: "sheetClose"
                text: "✕"; font.pixelSize: 18; color: theme.text2
                MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: closeSheet() }
            }
        }
    }

    Component {
        id: claimSheet
        ColumnLayout {
            id: cs
            spacing: 14
            property var s: claimTarget
            property var err: quoteError && quoteError !== "noPrivate" ? humanError(quoteError) : null
            SheetTitle { text: "Review claim" }
            Caption { text: "You're claiming"; Layout.topMargin: 4 }
            Big { text: tok(quote ? quote.amount : (cs.s ? cs.s.claimable : "0")); font.pixelSize: 32 }
            Caption { text: cs.s ? "From the vesting " + shortId(cs.s.creator) + " made for you. It moves into your account." : ""; Layout.topMargin: -8 }
            Divider {}
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Toggle {
                    objectName: "privateToggle"
                    text: "Receive privately"
                    hint: privAccounts.length === 0
                          ? "No private account in this wallet. Create one in your LEZ wallet to claim privately."
                          : claimPrivate ? "" : "Hides where the LGO go. Takes about 40 minutes and about 10 GB of free memory on this computer."
                    enabled: privAccounts.length > 0 && !opRunning
                    checked: claimPrivate
                    onToggled: { claimPrivate = checked; requote() }
                }
                Hint { tip: terms.receivePrivately; Layout.alignment: Qt.AlignTop }
            }
            Divider {}
            InfoRow { label: "To"; value: claimPrivate ? "Your private balance" : (cs.s ? "Your account " + shortId(cs.s.beneficiary) : "") }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Text { text: "Network cost"; color: theme.text2; font.pixelSize: 14 }
                Hint { tip: terms.fee }
                Text { text: quoting ? "…" : quote && quote.fee_estimate ? "about " + tok(quote.fee_estimate) : "—"; color: theme.text; font.pixelSize: 14; horizontalAlignment: Text.AlignRight; Layout.fillWidth: true }
            }
            InfoRow { label: "Paid from"; value: quoting ? "…" : quote ? (claimPrivate ? "Your private balance" : "Your account") + " (has " + tok(quote.fee_payer_balance) + ")" : "—" }
            Notice {
                visible: !!quote && !!quote.fee_estimate && cmp(quote.fee_estimate, quote.amount) >= 0
                tone: "warn"
                text: "The network cost is higher than what you'd claim. Consider waiting until more unlocks."
            }
            Notice {
                objectName: "privacyDisclosure"
                visible: claimPrivate && !!quote && !!quote.visible
                tone: "accent"
                title: "What others can see"
                text: quote && quote.visible
                      ? "Visible to everyone: the amount (" + tok(quote.visible.amount) + "), your vesting account (" + shortId(quote.visible.beneficiary) + ") and this vesting (" + shortId(quote.visible.schedule) + ").\n"
                        + "Not traceable: " + (quote.hidden || []).join(", and ") + "."
                      : ""
            }
            Notice {
                visible: claimPrivate && !!quote
                tone: "warn"
                text: "A private claim builds a zero-knowledge proof on this computer (about 40 minutes, about 10 GB of free memory), then a second step moves the LGO into your private balance. You can close this window while it runs."
            }
            Notice {
                visible: !claimPrivate && !!quote
                text: "Public claim: the amount and your account are visible to everyone, like any normal transfer."
            }
            Notice { visible: !!cs.err; tone: cs.err && cs.err.code === "V011" ? "plain" : "bad"; title: cs.err ? cs.err.title : ""; text: cs.err ? cs.err.message : "" }
            Expander {
                InfoRow { label: "Fee payer"; value: quote ? quote.fee_payer : ""; monoValue: true }
                InfoRow { visible: !!quote && !!quote.destination; label: "Destination"; value: quote && quote.destination ? quote.destination : ""; monoValue: true }
                InfoRow { visible: claimPrivate; label: "Private account"; value: privId(); monoValue: true }
                InfoRow { visible: !!quote && !!quote.visible; label: "One-time alias"; value: quote && quote.visible ? quote.visible.one_time_alias : ""; monoValue: true }
                InfoRow { label: "Vesting account"; value: quote ? quote.schedule : (cs.s ? cs.s.schedule : ""); monoValue: true }
                Caption { visible: !!cs.err; text: cs.err ? cs.err.raw : ""; font.family: theme.mono; font.pixelSize: 11; wrapMode: Text.WrapAnywhere }
            }
            PrimaryButton {
                objectName: "claimConfirm"
                property string block: claimBlocker()
                text: block !== "" ? block : cs.err ? "Try again" : claimPrivate ? "Claim privately" : "Claim"
                busy: quoting
                enabled: block === "" && !opRunning
                onClicked: confirmClaim()
            }
        }
    }

    Component {
        id: confirmSheet
        ColumnLayout {
            spacing: 16
            SheetTitle { text: confirmSpec ? confirmSpec.title : "" }
            Label2 { text: confirmSpec ? confirmSpec.body : ""; lineHeight: 1.2 }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                SoftButton { text: "Cancel"; implicitHeight: 52; Layout.fillWidth: true; Layout.preferredWidth: 1; onClicked: closeSheet() }
                PrimaryButton { objectName: "confirmAction"; text: confirmSpec ? confirmSpec.button : ""; danger: !!confirmSpec && confirmSpec.danger; Layout.preferredWidth: 2; enabled: !opRunning; onClicked: confirmSpec.run() }
            }
        }
    }

    Component {
        id: bulkSheet
        ColumnLayout {
            id: bs
            spacing: 14
            property var b: parseBulk()
            SheetTitle { text: "Review vestings" }
            Caption { text: "You're creating"; Layout.topMargin: 4 }
            Big { text: (bs.b.ok ? bs.b.count : 0) + " vestings"; font.pixelSize: 32 }
            Caption { text: bs.b.ok ? tok(bs.b.total) + " in total" : ""; Layout.topMargin: -8 }
            Divider {}
            Label2 { visible: !bulk.json; text: bulkSentence(); lineHeight: 1.2 }
            Repeater {
                model: bs.b.ok ? bs.b.entries.slice(0, 5) : []
                InfoRow { label: shortId(modelData.beneficiary); value: tok(String(modelData.total)) }
            }
            Caption { visible: bs.b.ok && bs.b.count > 5; text: "and " + (bs.b.count - 5) + " more" }
            InfoRow { label: "Paid from"; value: acct ? "Your account " + shortId(acct.id) : "" }
            Notice { text: "All vestings are created in one transaction. Everyone sees theirs in their app by themselves. A small network cost is paid from your account." }
            PrimaryButton { objectName: "bulkConfirm"; text: "Create " + (bs.b.ok ? bs.b.count : 0) + " vestings"; enabled: bs.b.ok && !opRunning; onClicked: confirmBulk() }
        }
    }

    Component {
        id: opSheet
        ColumnLayout {
            spacing: 14
            ColumnLayout {   // pending
                visible: opRunning
                Layout.fillWidth: true
                spacing: 14
                Spinner { size: 44; Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 8 }
                SheetTitle { text: op ? op.title : ""; horizontalAlignment: Text.AlignHCenter; Layout.rightMargin: 0 }
                Repeater {
                    model: op && op.steps.length > 1 ? op.steps : []
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Rectangle {
                            implicitWidth: 24; implicitHeight: 24; radius: 12
                            color: index < opStep ? theme.good : index === opStep ? theme.accent : theme.surface2
                            Text { anchors.centerIn: parent; text: index < opStep ? "✓" : String(index + 1); color: index <= opStep ? "white" : theme.text2; font.pixelSize: 12; font.weight: Font.Bold }
                        }
                        Label2 { text: "Step " + (index + 1) + " of " + op.steps.length + " · " + modelData.label; color: index === opStep ? theme.text : theme.text2; font.weight: index === opStep ? Font.DemiBold : Font.Normal }
                    }
                }
                Caption {
                    horizontalAlignment: Text.AlignHCenter
                    text: (op && op.long
                           ? "Building a zero-knowledge proof and waiting for the network. A private claim takes about 40 minutes."
                           : "Signing with your wallet and waiting for the network to include it. This can take a few minutes.")
                          + " You can close this window; it keeps going."
                }
                Text { text: "Elapsed " + elapsed(); color: theme.text2; font.pixelSize: 13; Layout.alignment: Qt.AlignHCenter }
                SoftButton { text: "Close"; Layout.fillWidth: true; implicitHeight: 48; onClicked: sheetMode = "" }
            }
            ColumnLayout {   // success
                visible: !opRunning && !!opDone
                Layout.fillWidth: true
                spacing: 14
                StatusIcon { kind: "good"; Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 8 }
                SheetTitle { text: opDone ? opDone.title : ""; horizontalAlignment: Text.AlignHCenter; Layout.rightMargin: 0; font.pixelSize: 22 }
                Label2 { text: opDone ? opDone.body : ""; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.2 }
                ColumnLayout {   // after "Vest": where the LGO are now, and what the recipient sees
                    visible: !!opDone && !!opDone.created
                    Layout.fillWidth: true
                    spacing: 10
                    property var cr: opDone && opDone.created ? opDone.created : null
                    Text { text: "Where your LGO are now"; font.pixelSize: 15; font.weight: Font.Bold; color: theme.text }
                    MoneyFlow {
                        objectName: "createdFlow"
                        wide: sheet.width >= 600
                        a: ({ title: "From", name: parent.cr ? acctLabel(parent.cr.creator) : "", addr: parent.cr ? shortId(parent.cr.creator) : "", amount: parent.cr ? "−" + tok(parent.cr.amount) : "", sub: parent.cr ? "keeps " + tok(parent.cr.fromLeft) : "" })
                        ab: "locked"
                        b: ({ title: "Vesting account", name: "Held by the vesting program", addr: parent.cr && parent.cr.schedule ? shortId(parent.cr.schedule) : "", amount: parent.cr ? tok(parent.cr.amount) : "", tone: "lock", tip: terms.escrow })
                        bc: "claims"
                        c: ({ title: "To", name: parent.cr ? (isMine(parent.cr.beneficiary) ? acctLabel(parent.cr.beneficiary) : "The recipient") : "", addr: parent.cr ? shortId(parent.cr.beneficiary) : "", amount: "0 " + tokenName + " yet", sub: "claims as it unlocks", tone: "good" })
                    }
                    Text { text: "What " + (parent.cr ? whoIs(parent.cr.beneficiary).replace(/^your /, "") : "the recipient") + " sees"; font.pixelSize: 15; font.weight: Font.Bold; color: theme.text; Layout.topMargin: 4 }
                    Label2 { text: (parent.cr ? parent.cr.when + " " : "") + "It shows up by itself on Home under “Coming to you”, with a Claim button once something has unlocked."; lineHeight: 1.2; font.pixelSize: 13 }
                    PrimaryButton {
                        objectName: "viewAsRecipient"
                        visible: !!parent.cr && isMine(parent.cr.beneficiary)
                        text: parent.cr ? "See what " + acctLabel(parent.cr.beneficiary) + " sees  ›" : ""
                        onClicked: { var c = parent.cr; viewAsRecipient(c.creator, c.id, c.beneficiary) }
                    }
                }
                PrimaryButton { objectName: "opDone"; soft: !!opDone && !!opDone.created && isMine(opDone.created.beneficiary); text: "Done"; onClicked: { var after = opDone && opDone.after; closeSheet(); if (after) page = after } }
                Expander {
                    visible: !!opDone && !!(opDone.code || opDone.codes)
                    title: opDone && opDone.codes ? "Vesting codes (only for other apps)" : "Vesting code (only for other apps)"
                    Caption { text: terms.code }
                    Rectangle {
                        Layout.fillWidth: true
                        radius: 14; color: theme.surface2
                        implicitHeight: codeText.implicitHeight + 24
                        Text { id: codeText; x: 12; y: 12; width: parent.width - 24; text: opDone ? (opDone.code || opDone.codes || "") : ""; font.family: theme.mono; font.pixelSize: 12; color: theme.text; wrapMode: Text.WrapAnywhere; maximumLineCount: 8; elide: Text.ElideRight }
                    }
                    CopyButton { value: opDone ? (opDone.code || opDone.codes || "") : ""; note: "Code copied"; label: opDone && opDone.codes ? "Copy all codes" : "Copy code" }
                }
                Expander { visible: !!opDone && !!opDone.details; Caption { text: opDone && opDone.details ? opDone.details : "" } }
            }
            ColumnLayout {   // error
                visible: !opRunning && !!opError
                Layout.fillWidth: true
                spacing: 14
                StatusIcon { kind: "bad"; Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 8 }
                SheetTitle { text: opError ? opError.title : ""; horizontalAlignment: Text.AlignHCenter; Layout.rightMargin: 0; font.pixelSize: 22 }
                Label2 { text: opError ? opError.message : ""; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.2 }
                Expander { Caption { text: opError ? opError.raw : ""; font.family: theme.mono; font.pixelSize: 11; wrapMode: Text.WrapAnywhere } }
                PrimaryButton { text: "Try again"; onClicked: retryOp() }
                SoftButton { text: "Close"; Layout.fillWidth: true; implicitHeight: 48; onClicked: closeSheet() }
            }
        }
    }

    Component {
        id: receiveSheet
        ColumnLayout {
            spacing: 14
            SheetTitle { text: "Receive LGO or a vesting" }
            Caption { text: "Share this address with anyone who sends you LGO or creates a vesting for you. Vestings to it show up on Home by themselves." }
            Rectangle {
                Layout.fillWidth: true
                radius: 14; color: theme.surface2
                implicitHeight: addrText.implicitHeight + 28
                Text { id: addrText; objectName: "receiveAddress"; x: 14; y: 14; width: parent.width - 28; text: acct ? acct.id : ""; font.family: theme.mono; font.pixelSize: 15; color: theme.text; wrapMode: Text.WrapAnywhere }
            }
            CopyButton { Layout.fillWidth: true; implicitHeight: 44; value: acct ? acct.id : ""; note: "Address copied"; label: "Copy address" }
            Notice { text: "This is a public address: sharing it is safe. Never share your wallet's keys or recovery phrase." }
            Caption { visible: pubAccounts.length > 1; text: "This wallet has " + pubAccounts.length + " accounts; this is your " + accountName(acct ? acct.id : "") + ". Pick another one on Home." }
        }
    }

    Component {
        id: addTokensSheet
        ColumnLayout {
            spacing: 14
            SheetTitle { text: "Add LGO to this account" }
            Notice {
                visible: netKind === "local"
                tone: "warn"
                title: "You're on a test network on this computer"
                text: "When this test network was set up, the test accounts in this wallet were given free test LGO (10,000 and 20,000). That's where your balance comes from. They have no value and never leave this computer."
            }
            Notice {
                visible: netKind === "testnet"
                tone: "warn"
                title: "You're on the Logos testnet"
                text: "LGO here are test tokens with no value. There is no faucet: you bring test LGO over from the Logos Blockchain (below), for example ones earned by running a node."
            }
            Label2 { text: netKind === "local" ? "To give test LGO to another address" : "Move LGO from your Logos wallet"; font.weight: Font.DemiBold; visible: true }
            ColumnLayout {
                visible: netKind !== "local"
                Layout.fillWidth: true
                spacing: 10
                StepRow { n: 1; text: "In Basecamp, open the Logos Blockchain app → Wallet → Channel Deposit (called “LEZ Bridge” in the Unofficial Windows build)." }
                StepRow { n: 2; text: "Pick the LGO to move and the LEZ channel. In Metadata, paste this account's address:" }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 38
                    spacing: 10
                    Text { text: acct ? acct.id : ""; font.family: theme.mono; font.pixelSize: 12; color: theme.text; elide: Text.ElideMiddle; Layout.fillWidth: true }
                    CopyButton { value: acct ? acct.id : ""; note: "Address copied" }
                }
                StepRow { n: 3; text: "Confirm. The LGO arrive here once the deposit is final on the Logos Blockchain (about an hour on the testnet). Refresh happens by itself." }
                Caption { text: "A deposit can only go to a public account like this one. Or ask someone who already has LGO on LEZ to send them to your address." }
            }
            ColumnLayout {
                visible: netKind === "local"
                Layout.fillWidth: true
                spacing: 8
                Caption { text: "Easiest: create a vesting for that address right here. Or send test LGO with the LEZ wallet in a terminal (inside WSL on Windows):" }
                Rectangle {
                    Layout.fillWidth: true
                    radius: 12; color: theme.surface2
                    implicitHeight: cmdText.implicitHeight + 20
                    Text { id: cmdText; x: 10; y: 10; width: parent.width - 20; wrapMode: Text.WrapAnywhere; font.family: theme.mono; font.pixelSize: 12; color: theme.text
                           text: "wallet auth-transfer send --from Public/" + (acct ? acct.id : "<yours>") + " --to Public/<their address> --amount <native units>" }
                }
                Caption { text: "The wallet counts in native units: 1 LGO = 1,000,000,000." }
            }
            Expander {
                title: "On the real network"
                visible: netKind === "local"
                Caption { text: "Real LGO come from your Logos wallet: in Basecamp's Logos Blockchain app, use Wallet → Channel Deposit with this account's address in Metadata. They arrive once the deposit is final on the Logos Blockchain." }
            }
        }
    }

    Component {
        id: helpSheet
        ColumnLayout {
            spacing: 14
            SheetTitle { text: "How vesting works" }
            StepRow { n: 1; text: "The sender vests LGO for your address and picks a schedule. The LGO leave their account at once and go into a vesting account made for this vesting. Nobody has its key: only the vesting program can move them." }
            StepRow { n: 2; text: "The LGO unlock bit by bit on that schedule. Home shows how much is ready and when the next unlock is." }
            StepRow { n: 3; text: "You claim what has unlocked whenever you like. It moves from the vesting account into yours. Waiting costs nothing. If the sender stops the vesting, what already unlocked stays yours to claim and only the locked rest goes back." }
            Divider {}
            Text { text: "Words used here"; font.pixelSize: 16; font.weight: Font.Bold; color: theme.text }
            TermRow { term: "Vesting"; text: terms.vesting }
            TermRow { term: "Vesting account"; text: terms.escrow }
            TermRow { term: "Public / private account"; text: terms.publicPrivate }
            TermRow { term: "Unlock"; text: terms.unlock }
            TermRow { term: "Claim"; text: terms.claim }
            TermRow { term: "Waiting period (cliff)"; text: terms.cliff }
            TermRow { term: "Milestones"; text: terms.milestones }
            TermRow { term: "Stop"; text: terms.stop }
            TermRow { term: "Permanent"; text: terms.permanent }
            TermRow { term: "Give away"; text: terms.transferable }
            TermRow { term: "Account / address"; text: terms.account }
            TermRow { term: "LGO"; text: terms.lgo }
            TermRow { term: "Network cost"; text: terms.fee }
            TermRow { term: "Private balance"; text: terms.privateBalance }
            TermRow { term: "Receive privately"; text: terms.receivePrivately }
            TermRow { term: "Test network"; text: terms.testNet }
            TermRow { term: "Vesting code"; text: terms.code }
        }
    }

    Component {
        id: testLgoSheet
        ColumnLayout {
            spacing: 14
            SheetTitle { text: netKind === "local" ? "Where did these LGO come from?" : "About test LGO" }
            Notice {
                tone: "warn"
                title: netKind === "local" ? "Free test tokens" : "Test tokens"
                text: netKind === "local"
                      ? "These 30,000 LGO are free test tokens your local test network created for 2 demo accounts when it started (10,000 and 20,000). On the real network you bring your own LGO from your Logos wallet."
                      : "You're on the Logos testnet. Its LGO are test tokens with no value. There is no faucet: you bring them from the Logos Blockchain with Channel Deposit (see Add LGO)."
            }
            Label2 { visible: netKind === "local"; text: "Why do I see " + pubAccounts.length + " accounts?"; font.weight: Font.DemiBold }
            Caption { visible: netKind === "local"; text: "Your wallet can hold many accounts. " + fundedAccounts.length + " of them have LGO" + (emptyCount > 0 ? "; the other " + emptyCount + " are empty extra accounts (Home hides them under “Show empty accounts”)." : ".") + " Give them names with Rename on Home." }
            Label2 { visible: netKind === "local"; text: "What to try"; font.weight: Font.DemiBold }
            StepRow { visible: netKind === "local"; n: 1; text: "Press Vest tokens, pay from one account and pick “My other account” as the recipient." }
            StepRow { visible: netKind === "local"; n: 2; text: "Watch the LGO move into a vesting account on Home (Where your LGO are)." }
            StepRow { visible: netKind === "local"; n: 3; text: "Switch to the other account and claim what has unlocked." }
            SoftButton { text: "How do I get real LGO?"; Layout.fillWidth: true; onClicked: sheetMode = "addTokens" }
        }
    }

    Component {
        id: renameSheet
        ColumnLayout {
            spacing: 14
            SheetTitle { text: "Rename " + acctLabel(renameId) }
            Caption { text: "Only for you: the name is kept on this computer and never goes on the network. The address stays " + shortId(renameId) + "." }
            Field { id: renF; objectName: "renameField"; text: names[renameId] || ""; placeholderText: "Account " + (acctPos(renameId) + 1); maximumLength: 32; Component.onCompleted: forceActiveFocus() }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                SoftButton { text: "Reset"; implicitHeight: 52; onClicked: { setName(renameId, ""); closeSheet() } }
                PrimaryButton { objectName: "renameSave"; text: "Save"; onClicked: { setName(renameId, renF.text); closeSheet() } }
            }
        }
    }

    Component {
        id: settingsSheet
        ColumnLayout {
            id: st
            spacing: 14
            property string saved: ""
            property bool saving: false
            property int backend: cfg.backend === "wsl" ? 1 : 0
            property bool dev: cfg.dev_mode === "true"
            SheetTitle { text: "Settings" }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Rectangle { implicitWidth: 10; implicitHeight: 10; radius: 5; color: ready ? theme.good : needsSetup ? theme.warn : loaded ? theme.bad : theme.text3 }
                Label2 {
                    text: !loaded ? "Connecting…"
                          : needsSetup ? "Not set up: add the vesting program address under Advanced."
                          : loadError ? humanError(loadError).title + ". " + humanError(loadError).message
                          : "Connected to " + networkName() + " · " + pubAccounts.length + (pubAccounts.length === 1 ? " account" : " accounts") + ", " + privAccounts.length + " private"
                }
            }
            Caption { text: "Your keys stay in your LEZ wallet. This app never sees them." }
            Expander {
                title: "Advanced"
                open: needsSetup || loadError !== ""
                FieldLabel { text: "Vesting program address" }
                Field { id: progF; objectName: "programField"; text: cfg.program || ""; placeholderText: "Program account id" }
                FieldLabel { text: "Wallet folder" }
                Field { id: walletF; objectName: "walletField"; text: cfg.wallet_home || ""; placeholderText: "LEE_WALLET_HOME_DIR" }
                FieldLabel { text: st.backend === 1 ? "vesting CLI path (inside WSL)" : "vesting CLI path" }
                Field { id: cliF; objectName: "cliField"; text: cfg.cli || ""; placeholderText: "Bundled CLI" }
                FieldLabel { text: "Run on" }
                Row { spacing: 8
                      Chip { objectName: "backendNative"; text: "This computer"; selected: st.backend === 0; onClicked: st.backend = 0 }
                      Chip { text: "WSL (Windows)"; selected: st.backend === 1; onClicked: st.backend = 1 } }
                FieldLabel { visible: st.backend === 1; text: "WSL distribution" }
                Field { id: distroF; visible: st.backend === 1; text: cfg.wsl_distro || ""; placeholderText: "Default distribution" }
                Toggle { objectName: "devToggle"; text: "Fast test proofs"; hint: "Local test network only. Real networks need real proofs."; checked: st.dev; onToggled: st.dev = checked }
                FieldLabel { visible: privAccounts.length > 1; text: "Private account for private claims" }
                Flow {
                    visible: privAccounts.length > 1
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater { model: privAccounts; Chip { text: shortId(modelData.id) + " · " + tok(modelData.balance); selected: privIndex === index; onClicked: privIndex = index } }
                }
                Caption { text: "Windows: the prover runs in WSL. Pick “WSL (Windows)” and install the vesting CLI there. Private claims need about 10 GB of memory for WSL." }
            }
            Caption { visible: st.saved !== ""; text: st.saved; color: st.saved === "Saved" ? theme.good : theme.bad }
            PrimaryButton {
                objectName: "saveSettings"
                text: "Save"
                busy: st.saving
                enabled: !st.saving
                onClicked: {
                    st.saving = true
                    call("setConfig", [JSON.stringify({ program: progF.text.trim(), wallet_home: walletF.text.trim(), cli: cliF.text.trim(),
                                                        backend: st.backend === 1 ? "wsl" : "native", wsl_distro: distroF.text.trim(), dev_mode: st.dev ? "true" : "false" })],
                         function (r) {
                             st.saving = false
                             if (!r.ok) { st.saved = humanError(r.error).message; return }
                             cfg = r; cfgLoaded = true; st.saved = "Saved"
                             loaded = false; loadError = ""; refresh(true)
                         })
                }
            }
            Divider {}
            FieldLabel { text: "About" }
            Caption { objectName: "aboutVersion"; text: "Vesting " + appVersion + " (" + appBuilt + ") · RFP-017 prototype for LEZ 0.4"; font.pixelSize: 12 }
            Caption { visible: !!network && !!network.url; text: network && network.url ? "Network: " + networkName() + " (" + network.url + ")" : ""; font.pixelSize: 12 }
        }
    }
}

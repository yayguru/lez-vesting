import QtQuick 2.15
import QtQuick.Window 2.15

// Offscreen render check for the vesting mini-app: loads ../../Main.qml with a mock `logos`
// bridge, drives it through every screen and state, and saves one PNG per state.
// Run via render.sh (fails on any QML warning).
Window {
    id: win
    visible: true
    width: 960
    height: 820
    color: "white"

    property string outDir: Qt.application.arguments.length > 0 ? Qt.application.arguments[Qt.application.arguments.length - 1] : "/tmp"
    property var mock: ({})
    property int stepIndex: -1

    readonly property string me: "7Hq3F9aKpX2vLmN8sT4cR6wYbJ1dE5gU3zQ9xV2kc21b"
    readonly property string sender: "3F9aB7kLmQ2wErT5yU8iHpA4sD6fG1hJ3kL9zX7cc4e1"
    readonly property string priv: "9Ab3PrivK2mN4bV6cX8zL1kJ3hG5fD7sA9qW2eR4t6Yq"
    readonly property string bob: "7Bc1Wq3Er5Ty7Ui9Hp2As4Df6Gh8Jk1Lz3Xc5Vb9e0a"
    readonly property string me2: "4Rt8Yu2Io4Pa6Sd8Fg1Hj3Kl5Zx7Cv9Bn2Mq4Wr6Ey8T"
    readonly property string e3: "2koDq8Wm4Ns6Pt8Rv1Xz3Bc5Df7Gh9Jk2Lm4Np6YS2y"
    readonly property string e4: "2oGoT5Ry7Ui9Op1As3Df5Gh7Jk9Lz2Xc4Vb6NmhRMP"
    readonly property string e5: "5GPoZ1Xc3Vb5Nm7Qw9Er2Ty4Ui6Op8As1Df3Gh5jsz3"
    readonly property string ann: "5KdA2fG4hJ6kL8zX1cV3bN5mQ7wE9rT2yU4iH6pS8dFa"
    readonly property real now: Date.now()
    readonly property real day: 86400000

    function hex(c) { var s = ""; for (var i = 0; i < 64; i++) s += c; return s }
    function sched(o) {
        var base = { schedule: "Sch" + o.id.substr(0, 40), escrow: "0", cancelable: true, transferable: false, cancelled: null, next_unlock: { kind: "never" } }
        for (var k in o) base[k] = o[k]
        return base
    }
    // Native units: 1 LGO = 10^9. lgo("1500") -> "1500000000000".
    function lgo(x) { return x === "0" ? "0" : x + "000000000" }
    function mkData() {
        var A = sched({ id: hex("a"), creator: sender, beneficiary: me, kind: { linear: { start: now - 120 * day, cliff: now - 30 * day, end: now + 245 * day } },
                        total: lgo("1000"), vested: lgo("328"), locked: lgo("672"), claimed: lgo("25"), claimable: lgo("303"), escrow: lgo("975"), transferable: true,
                        next_unlock: { kind: "time", at: now + 60000 } })
        var B = sched({ id: hex("b"), creator: sender, beneficiary: me, kind: { milestones: [lgo("200"), lgo("300"), lgo("500")], done_mask: 1 },
                        total: lgo("1000"), vested: lgo("200"), locked: lgo("800"), claimed: lgo("200"), claimable: "0", escrow: lgo("800"),
                        next_unlock: { kind: "milestone", index: 1 } })
        var C = sched({ id: hex("c"), creator: me, beneficiary: bob, kind: { linear: { start: now - 200 * day, cliff: now + 165 * day, end: now + 1261 * day } },
                        total: lgo("4800"), vested: "0", locked: lgo("4800"), claimed: "0", claimable: "0", escrow: lgo("4800"),
                        next_unlock: { kind: "time", at: now + 165 * day } })
        var D = sched({ id: hex("d"), creator: me, beneficiary: ann, kind: { milestones: [lgo("100"), lgo("150"), lgo("250")], done_mask: 1 },
                        total: lgo("500"), vested: lgo("100"), locked: lgo("400"), claimed: lgo("40"), claimable: lgo("60"), escrow: lgo("460"), next_unlock: { kind: "milestone", index: 1 } })
        var E = sched({ id: hex("e"), creator: me, beneficiary: bob, kind: { linear: { start: now - 90 * day, cliff: now - 90 * day, end: now + 90 * day } },
                        total: lgo("200"), vested: lgo("50"), locked: "0", claimed: lgo("50"), claimable: "0", escrow: "0", cancelled: { at: now - 45 * day, vested: lgo("50") } })
        var F = sched({ id: hex("9"), creator: me, beneficiary: me2, schedule: "VestAcc9mQ2wErT5yU8iHpA4sD6fG1hJ3kL9zX7cK2", kind: { linear: { start: now - 92 * day, cliff: now - 1 * day, end: now + 273 * day } },
                        total: lgo("1000"), vested: lgo("250"), locked: lgo("750"), claimed: "0", claimable: lgo("250"), escrow: lgo("1000"),
                        next_unlock: { kind: "time", at: now + 60000 } })
        return { A: A, B: B, C: C, D: D, E: E, F: F }
    }
    function baseMock() {
        var d = mkData()
        return {
            config: { ok: true, program: "VestProg1111111111111111111111111111111111", wallet_home: "/home/user/.lee-wallet", cli: "", backend: "native", wsl_distro: "", dev_mode: "true" },
            accounts: { ok: true, "public": [{ id: me, balance: lgo("8950") }, { id: me2, balance: lgo("20000") }, { id: e3, balance: "0" }, { id: e4, balance: "0" }, { id: e5, balance: "0" }], "private": [{ id: priv, balance: "9100000" }],
                        network: { url: "http://127.0.0.1:3040", kind: "local" } },
            list: { ok: true, schedules: [d.A, d.B, d.C, d.D, d.E, d.F], now: now, scan: { next: 4200, tip: 4200, found: 0, done: true } },
            hang: {}, replies: {}
        }
    }
    function quoteFor(args) {
        if (args[3] === "") return { ok: true, amount: lgo("303"), schedule: "Sch" + hex("a").substr(0, 40), fee_payer: "Public/" + me, fee_payer_balance: lgo("8950"), destination: me, fee_estimate: "308000" }
        return { ok: true, amount: lgo("303"), schedule: "Sch" + hex("a").substr(0, 40), fee_payer: "Private/" + priv, fee_payer_balance: "9100000",
                 visible: { amount: lgo("303"), beneficiary: me, schedule: "Sch" + hex("a").substr(0, 40), one_time_alias: "Alias7mQ2wErT5yU8iHpA4sD6fG1hJ3kL9zX7cLp" },
                 hidden: ["which private account the alias belongs to", "later movements of the funds"], fee_estimate: "5370000" }
    }
    function respond(method, args) {
        if (mock.hang[method]) return null
        if (mock.replies[method]) return typeof mock.replies[method] === "function" ? mock.replies[method](args) : mock.replies[method]
        if (method === "getConfig") return mock.config
        if (method === "accounts") return mock.accounts
        if (method === "listSchedules") return mock.list
        if (method === "quoteClaim") return quoteFor(args)
        if (method === "jobResult") return { ok: true, pending: true }
        return { ok: true, pending: true, job: "1" }
    }
    QtObject {
        id: logos
        function callModuleAsync(mod, method, args, cb, timeout) {
            var r = win.respond(method, args)
            if (r === null) return
            var t = Qt.createQmlObject('import QtQuick 2.15; Timer { interval: 30; repeat: false }', win)
            t.triggered.connect(function () { cb(JSON.stringify(r)); t.destroy() })
            t.start()
        }
    }

    QtObject { id: renderHarness }   // Main.qml: don't persist names / notes while rendering
    Loader { id: loader; anchors.fill: parent }
    readonly property var app: loader.item

    // Each step: name, optional mock tweak, optional size, action on the app.
    // Each step: name, optional mock tweak, optional size, action on the app.
    // Sizes: "laptop" = the Basecamp app area on the owner's laptop (1366x768 screen, 96 DPI, maximized): 1260x655.
    function empty(m) { m.list = { ok: true, schedules: [], now: now, scan: { next: 4200, tip: 4200, found: 0, done: true } }; m.accounts["public"] = [{ id: me, balance: lgo("10000") }, { id: me2, balance: lgo("20000") }, { id: e3, balance: "0" }, { id: e4, balance: "0" }, { id: e5, balance: "0" }] }
    function testnet(m) { m.accounts.network = { url: "https://testnet.lez.logos.co", kind: "testnet" }; m.config.dev_mode = "false"; m.accounts["public"] = [{ id: me, balance: "0" }]; m.list = { ok: true, schedules: [], now: now, scan: { next: 9, tip: 9, found: 0, done: true } } }
    function vestForm(a, to, amt, step) { a.acctIndex = 0; a.page = "create"; a.toMode = to === me2 ? "mine" : "other"; a.formState.to = to; a.formState.amount = amt; a.formState.preset = "1y3m"; a.createStep = step }
    property var steps: [
        { name: "01-loading", mock: function (m) { m.hang = { accounts: true, getConfig: true } } },
        { name: "02-setup-needed", mock: function (m) { m.config = { ok: true, program: "", wallet_home: "", cli: "", backend: "native", dev_mode: "false" }; m.list = { ok: false, error: "--program / VESTING_PROGRAM required" } } },
        { name: "03-wallet-error", mock: function (m) { m.accounts = { ok: false, error: "open wallet (LEE_WALLET_HOME_DIR): No such file or directory (os error 2)" } } },
        { name: "04-first-run", h: 1500, mock: empty },
        { name: "05-first-run-laptop", w: 1260, h: 655, mock: empty },
        { name: "06-home", h: 3000 },
        { name: "07-home-laptop", w: 1260, h: 655 },
        { name: "08-home-laptop-scrolled", w: 1260, h: 655, act: function (a) { a.dismissIntro() }, then: function (a) { a.flickItem().contentY = 560 } },
        { name: "09-home-1024x700", w: 1024, h: 700, act: function (a) { a.dismissIntro() } },
        { name: "10-home-1280x720", w: 1280, h: 720, act: function (a) { a.dismissIntro() } },
        { name: "11-home-empty-accounts-shown", h: 1300, act: function (a) { a.dismissIntro(); a.showEmptyAccounts = true } },
        { name: "12-home-searching", h: 1200, mock: function (m) { m.list.scan = { next: 1200, tip: 4200, found: 0, done: false } }, act: function (a) { a.dismissIntro() } },
        { name: "13-test-lgo", w: 1260, h: 655, act: function (a) { a.sheetMode = "testLgo" } },
        { name: "14-rename", act: function (a) { a.renameId = a.acct.id; a.sheetMode = "rename" } },
        { name: "15-renamed-home", h: 1100, act: function (a) { a.dismissIntro(); a.setName(me, "Team treasury"); a.setName(me2, "My savings") } },
        { name: "16-receive", act: function (a) { a.sheetMode = "receive" } },
        { name: "17-add-tokens-local", h: 900, act: function (a) { a.sheetMode = "addTokens" } },
        { name: "18-add-tokens-testnet", h: 960, mock: testnet, act: function (a) { a.sheetMode = "addTokens" } },
        { name: "19-home-testnet-empty", h: 1250, mock: testnet },
        { name: "20-help", h: 1500, act: function (a) { a.sheetMode = "help" } },
        { name: "21-claim-review", act: function (a) { a.openClaim(a.incoming[0]) } },
        { name: "22-claim-review-private", h: 1060, act: function (a) { a.openClaim(a.incoming[0]); a.claimPrivate = true; a.requote() } },
        { name: "23-claim-pending-private", act: function (a) { a.openClaim(a.incoming[0]); a.claimPrivate = true; a.requote() }, then: function (a) { a.confirmClaim() } },
        { name: "24-claim-success", mock: function (m) { m.replies.claim = { ok: true, amount: lgo("303"), block: 4182, schedule: "x" } },
          act: function (a) { a.openClaim(a.incoming[0]) }, then: function (a) { a.confirmClaim() } },
        { name: "25-claim-error", mock: function (m) { m.replies.claim = { ok: false, error: "V021 transaction 9f2c was not included within 2 minutes; it was probably refused at settlement. Refresh and retry." } },
          act: function (a) { a.openClaim(a.incoming[0]) }, then: function (a) { a.confirmClaim() } },
        { name: "26-claim-not-enough-for-fee", mock: function (m) { m.replies.quoteClaim = { ok: false, error: "V020 Public/" + me + " balance 120000 is below the estimated fee 308000; fund it first" } },
          act: function (a) { a.openClaim(a.incoming[0]) } },
        { name: "27-detail-recipient", h: 1500, act: function (a) { a.openDetail(a.incoming[0], "recipient") } },
        { name: "28-detail-recipient-milestones", h: 1300, act: function (a) { a.openDetail(a.incoming[1], "recipient") } },
        { name: "29-detail-creator-milestones", h: 1500, act: function (a) { a.openDetail(a.outgoing[1], "creator") } },
        { name: "30-detail-creator-linear", h: 1450, act: function (a) { a.openDetail(a.outgoing[0], "creator") } },
        { name: "31-detail-own-as-sender", h: 1450, act: function (a) { a.openDetail(a.outgoing[3], "creator") } },
        { name: "32-detail-own-as-recipient-laptop", w: 1260, h: 655, act: function (a) { a.openDetail(a.outgoing[3], "creator") }, then: function (a) { a.detailRole = "recipient" } },
        { name: "33-confirm-stop", act: function (a) { a.openDetail(a.outgoing[0], "creator"); a.askStop(a.outgoing[0]) } },
        { name: "34-vest-1-who-laptop", w: 1260, h: 655, act: function (a) { a.page = "create"; a.createStep = 1 } },
        { name: "35-vest-1-who-mine", h: 1000, act: function (a) { vestForm(a, me2, "", 1) } },
        { name: "36-vest-1-who-other-ok", w: 1260, h: 655, act: function (a) { vestForm(a, bob, "", 1) }, then: function (a) { a.flickItem().contentY = 200 } },
        { name: "37-vest-1-who-other-bad", w: 1024, h: 700, act: function (a) { vestForm(a, "7Bc1Wq3Er5Ty7", "", 1) }, then: function (a) { a.flickItem().contentY = 200 } },
        { name: "38-vest-2-amount-laptop", w: 1260, h: 655, act: function (a) { vestForm(a, me2, "1000", 2) } },
        { name: "39-vest-2-amount-too-much", w: 1280, h: 720, act: function (a) { vestForm(a, me2, "9000", 2) } },
        { name: "40-vest-3-schedule-laptop", w: 1260, h: 655, act: function (a) { vestForm(a, me2, "1000", 3) } },
        { name: "41-vest-3-milestones", h: 1100, act: function (a) { vestForm(a, bob, "1000", 3); a.formState.preset = "milestones"; a.formState.milestones = ["250", "250", "500"] } },
        { name: "42-vest-3-custom", h: 1200, act: function (a) { vestForm(a, bob, "600.5", 3); a.formState.preset = "custom"; a.formState.lastsN = "2"; a.formState.lastsUnit = "years"; a.formState.cliffN = "6"; a.formState.startText = "2027-01-01"; a.formState.moreOpen = true } },
        { name: "43-vest-4-review-laptop", w: 1260, h: 655, act: function (a) { vestForm(a, me2, "1000", 4) } },
        { name: "44-vest-4-review-full", h: 1300, act: function (a) { vestForm(a, me2, "1000", 4) } },
        { name: "45-vest-4-review-1024x700", w: 1024, h: 700, act: function (a) { vestForm(a, bob, "1000", 4) } },
        { name: "46-vest-pending", w: 1260, h: 655, act: function (a) { vestForm(a, me2, "1000", 4) }, then: function (a) { a.confirmCreate() } },
        { name: "47-vested-own-account-laptop", w: 1260, h: 655, mock: function (m) { m.replies.create = { ok: true, id: hex("f"), block: 4190, schedule: "VestAccFq2wErT5yU8iHpA4sD6fG1hJ3kL9zX7cQ1" } },
          act: function (a) { vestForm(a, me2, "1000", 4) }, then: function (a) { a.confirmCreate() } },
        { name: "48-vested-someone-else", h: 900, mock: function (m) { m.replies.create = { ok: true, id: hex("f"), block: 4190, schedule: "VestAccFq2wErT5yU8iHpA4sD6fG1hJ3kL9zX7cQ1" } },
          act: function (a) { vestForm(a, bob, "1000", 4) }, then: function (a) { a.confirmCreate() } },
        { name: "49-bulk-laptop", w: 1260, h: 655, act: function (a) { a.page = "bulk"; a.bulkState.lines = bob + ", 1000\n" + ann + ",2500.5\n" + sender + " 1500" } },
        { name: "50-bulk-review", act: function (a) { a.page = "bulk"; a.bulkState.lines = bob + ", 1000\n" + ann + ",2500.5\n" + sender + " 1500"; a.sheetMode = "bulkReview" } },
        { name: "51-settings-about", h: 900, act: function (a) { a.sheetMode = "settings" } },
        { name: "52-settings-setup", h: 1050, mock: function (m) { m.config = { ok: true, program: "", wallet_home: "", cli: "", backend: "wsl", dev_mode: "false" }; m.list = { ok: false, error: "--program / VESTING_PROGRAM required" } },
          act: function (a) { a.sheetMode = "settings" } },
        { name: "53-code-entry", h: 3000, act: function (a) { a.codeEntryOpen = true } },
        { name: "54-narrow-home", w: 440, h: 3600 },
        { name: "55-narrow-vest-review", w: 440, h: 800, act: function (a) { vestForm(a, me2, "1000", 4) } },
        { name: "56-narrow-first-run", w: 440, h: 1700, mock: empty }
    ]

    Timer { id: stepTimer; interval: 50; onTriggered: win.runStep() }
    Timer { id: actTimer; interval: 400; property var fn: null; onTriggered: { if (fn) fn(app); fn = null; thenTimer.start() } }
    Timer { id: thenTimer; interval: 400; onTriggered: { var s = steps[stepIndex]; if (s.then) s.then(app); grabTimer.start() } }
    Timer { id: grabTimer; interval: 700; onTriggered: win.grab() }

    function runStep() {
        stepIndex++
        if (stepIndex >= steps.length) { console.log("RENDER DONE " + steps.length); Qt.quit(); return }
        var s = steps[stepIndex]
        mock = baseMock()
        if (s.mock) s.mock(mock)
        win.width = s.w || 960
        win.height = s.h || 820
        loader.source = ""
        loader.source = Qt.resolvedUrl("../../Main.qml")
        actTimer.fn = s.act || null
        actTimer.start()
    }
    function grab() {
        var s = steps[stepIndex]
        if (!loader.item) { console.log("RENDER FAILED " + s.name + " (Main.qml did not load)"); Qt.quit(); return }
        loader.item.grabToImage(function (r) {
            var f = outDir + "/" + s.name + ".png"
            console.log("RENDER " + (r.saveToFile(f) ? "saved " : "FAILED ") + f)
            stepTimer.start()
        })
    }
    Component.onCompleted: stepTimer.start()
}

// Unit tests for package/contents/ui/logic.js. Run: node tests/logic.test.js
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { execFileSync } = require("child_process");

const src = fs.readFileSync(path.join(__dirname, "../package/contents/ui/logic.js"), "utf8")
    .replace(/^\.pragma library\s*$/m, "");
const L = {};
vm.runInNewContext(src + "\nObject.assign(out, {shellQuote, normalizeForward, parseStore, serializeStore, forwardTitle, unitName, forwardCommand, startScript, stopScript, pollScript, parsePoll, deriveStatus, errorKind, decodeBase64Utf8, readStoreScript, writeStoreScript, sshConfigScript, parseSshHosts, dependencyScript, richEscape, localPortsScript, splitAddress, addressScope, parseSsLine, processLabel, projectName, parseDockerPorts, parseLocalPorts, formatAddress, browseHost, killScript, normalizeBindAddress, canonicalIPv6, bindKey, listenAddressesOverlap, bindAddressesOverlap, forwardsConflict, isLoopbackBind, localAddress, browseAddress, LISTEN_SHELL});", { out: L, Date });

let n = 0;
function test(name, fn) {
    fn();
    n += 1;
    console.log("ok", n, "-", name);
}

const bash = (script, env) => execFileSync("bash", ["-c", script], { encoding: "utf8", env: Object.assign({}, process.env, env || {}) });

test("shellQuote survives bash for nasty strings", () => {
    for (const s of ["plain", "it's", "a b\tc", "$(touch /tmp/pwned)", "`id`", "'; rm -rf / #", "çğış → ✓", "new\nline", ""]) {
        assert.strictEqual(bash("printf %s " + L.shellQuote(s)), s);
    }
});

test("normalizeForward applies the original's rules", () => {
    let made = 0;
    const mk = () => "gen" + (++made);
    assert.strictEqual(L.normalizeForward(null, mk), null);
    assert.strictEqual(L.normalizeForward({ localPort: 0, sshTarget: "h" }, mk), null);
    assert.strictEqual(L.normalizeForward({ localPort: "abc", sshTarget: "h" }, mk), null);
    assert.strictEqual(L.normalizeForward({ localPort: 3000, sshTarget: "  " }, mk), null);
    const f = L.normalizeForward({ id: " a b|c ", localPort: "3000", sshTarget: " foundry ", remotePort: -1, autostart: "true", label: " Web ", extraOptions: " -J x " }, mk);
    assert.deepStrictEqual(JSON.parse(JSON.stringify(f)), { id: "a_b_c", label: "Web", bindAddress: "", localPort: 3000, sshTarget: "foundry", remoteHost: "localhost", remotePort: 3000, autostart: false, extraOptions: "-J x" });
    const g = L.normalizeForward({ localPort: 8080, sshTarget: "h", remoteHost: "db", remotePort: 5432, autostart: true }, mk);
    assert.strictEqual(g.id, "gen1");
    assert.strictEqual(g.remoteHost, "db");
    assert.strictEqual(g.remotePort, 5432);
    assert.strictEqual(g.autostart, true);
});

test("parseStore: empty, broken, derived and duplicate ids", () => {
    assert.strictEqual(L.parseStore("").ok, true);
    assert.strictEqual(L.parseStore("").forwards.length, 0);
    const broken = L.parseStore("{ nope");
    assert.strictEqual(broken.ok, false);
    assert.strictEqual(broken.forwards.length, 0);
    const text = JSON.stringify({ version: 1, forwards: [
        { localPort: 1, sshTarget: "a" }, { id: "x", localPort: 2, sshTarget: "b" }, { id: "x", localPort: 3, sshTarget: "c" },
        { id: "a.b", localPort: 4, sshTarget: "d" }, { id: "a_b", localPort: 5, sshTarget: "e" }] });
    const r = L.parseStore(text);
    assert.strictEqual(r.ok, true);
    const ids = Array.from(r.forwards.map(f => f.id));
    // no id: derived from content, identical on every load
    assert.ok(/^h[0-9a-z]+$/.test(ids[0]), ids[0]);
    assert.strictEqual(L.parseStore(text).forwards[0].id, ids[0]);
    // same id, and ids that map to the same unit name, get a stable suffix
    assert.deepStrictEqual(ids.slice(1), ["x", "x-2", "a.b", "a_b-2"]);
    assert.strictEqual(new Set(ids.map(L.unitName)).size, ids.length);
    assert.ok(L.serializeStore([]).endsWith("\n"));
    assert.strictEqual(JSON.parse(L.serializeStore([])).version, 1);
});

test("parseStore refuses shapes it cannot keep", () => {
    for (const t of ['[{"localPort":1,"sshTarget":"a"}]', '{"forwards":{"a":1}}', '"text"', "42"]) {
        const r = L.parseStore(t);
        assert.strictEqual(r.ok, false, t);
    }
});

test("invalid entries, unknown fields and top-level keys survive a save", () => {
    const text = JSON.stringify({ version: 1, note: "mine", forwards: [
        { localPort: 8080, sshTarget: "web", comment: "kept" },
        { id: "db", localport: 5432, sshTarget: "db", comment: "prod" },
        { id: "t", localPort: 22, sshTarget: "-oProxyCommand=x" },
        { id: "z", localPort: 9, sshTarget: "z", tags: ["a"] }] });
    const r = L.parseStore(text);
    assert.strictEqual(r.ok, true);
    assert.deepStrictEqual(Array.from(r.forwards.map(f => f.sshTarget)), ["web", "z"]);
    assert.strictEqual(r.invalid.length, 2);
    // round trip without changes keeps every byte of meaning
    const back = JSON.parse(L.serializeStore(r.forwards, r.extras, r.invalid, r.top));
    assert.strictEqual(back.note, "mine");
    assert.deepStrictEqual(back.forwards[1], { id: "db", localport: 5432, sshTarget: "db", comment: "prod" });
    assert.deepStrictEqual(back.forwards[2], { id: "t", localPort: 22, sshTarget: "-oProxyCommand=x" });
    assert.strictEqual(back.forwards[0].comment, "kept");
    assert.deepStrictEqual(back.forwards[3].tags, ["a"]);
    // after deleting the first valid entry and adding one, the invalid ones are still there
    const fw = r.forwards.slice(1).concat([{ id: "n", label: "", localPort: 1, sshTarget: "n", remoteHost: "localhost", remotePort: 1, autostart: false, extraOptions: "" }]);
    const after = JSON.parse(L.serializeStore(fw, r.extras, r.invalid, r.top)).forwards;
    assert.strictEqual(after.length, 4);
    assert.ok(after.some(e => e.localport === 5432) && after.some(e => e.sshTarget === "-oProxyCommand=x"));
});

test("richEscape shows markup literally", () => {
    const e = L.richEscape("web: <b>x</b> & <img src='http://127.0.0.1:1/p.png'>\n\"q\"");
    assert.ok(e.startsWith("<p>") && e.endsWith("</p>"));
    const inner = e.slice(3, -4);
    assert.ok(!/[<>]/.test(inner.replace(/<br\/>/g, "")), inner);
    assert.ok(inner.includes("&lt;img src=&#39;http://127.0.0.1:1/p.png&#39;&gt;"));
});

test("forwardCommand matches the original flag for flag", () => {
    const f = { localPort: 3000, sshTarget: "foundry", remoteHost: "", remotePort: 3001, extraOptions: " -J  bastion -p 22 " };
    assert.deepStrictEqual(Array.from(L.forwardCommand(f, false)), ["ssh", "-N", "-T", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=10", "-L", "3000:localhost:3001",
        "-J", "bastion", "-p", "22", "--", "foundry"]);
    const t = Array.from(L.forwardCommand(f, true));
    assert.deepStrictEqual(t.slice(15, 17), ["-o", "StrictHostKeyChecking=accept-new"]);
});

test("unit names are safe", () => {
    assert.strictEqual(L.unitName("f1.x"), "porthole-f1_x");
    assert.strictEqual(L.normalizeForward({ localPort: 1, sshTarget: "-oProxyCommand=x" }, () => "i"), null);
});

test("generated scripts parse with bash -n", () => {
    const f = { id: "a'b", localPort: 3000, sshTarget: "h'ost", remoteHost: "localhost", remotePort: 3000, extraOptions: "" };
    const b = Object.assign({}, f, { bindAddress: "::1" });
    for (const s of [L.startScript(f, ["porthole-other"], true, "desc 'quoted'"), L.stopScript("a'b"), L.pollScript([f]), L.pollScript([]),
        L.startScript(b, [], false, "d"), L.pollScript([f, b]),
        L.readStoreScript(), L.writeStoreScript("{\"a\": \"it's\"}\n"), L.sshConfigScript(), L.dependencyScript()]) {
        execFileSync("bash", ["-n", "-c", s]);
    }
});

test("startScript picks the first live agent socket", () => {
    const f = { id: "t1", localPort: 3999, sshTarget: "h", remoteHost: "localhost", remotePort: 1, extraOptions: "" };
    // Swap systemd-run for printf and systemctl/ss/gpgconf for fakes to see the final argv.
    const s = L.startScript(f, [], false, "d").replace("exec systemd-run", "exec printf '[%s]'");
    const fakeBin = fs.mkdtempSync("/tmp/pf-fake-");
    const sock = name => {
        const p = path.join(fakeBin, name);
        execFileSync("python3", ["-c", "import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1])", p]);
        return p;
    };
    const fake = (name, body) => fs.writeFileSync(path.join(fakeBin, name), "#!/bin/sh\n" + body + "\nexit 0\n", { mode: 0o755 });
    fake("systemctl", "");
    fake("ss", "");
    fake("gpgconf", "");
    const env = { PATH: fakeBin + ":/usr/bin", XDG_RUNTIME_DIR: fakeBin, SSH_AUTH_SOCK: "" };
    let out = bash(s, env);
    assert.ok(!out.includes("SSH_AUTH_SOCK"), out);
    assert.ok(out.includes("[--unit=porthole-t1][--description=d][--][ssh][-N]"), out);
    // gpg-agent's ssh socket is the last resort
    const gpg = sock("gpg-ssh");
    fake("gpgconf", "echo " + gpg);
    assert.ok(bash(s, env).includes("[--setenv=SSH_AUTH_SOCK=" + gpg + "]"));
    // GNOME Keyring beats gpg-agent
    fs.mkdirSync(path.join(fakeBin, "gcr"));
    const gcr = sock("gcr/ssh");
    assert.ok(bash(s, env).includes("[--setenv=SSH_AUTH_SOCK=" + gcr + "]"));
    // ssh-agent.socket beats GNOME Keyring
    const agent = sock("ssh-agent.socket");
    assert.ok(bash(s, env).includes("[--setenv=SSH_AUTH_SOCK=" + agent + "]"));
    // the socket plasmashell passed down beats those
    const inherited = sock("inherited");
    assert.ok(bash(s, Object.assign({}, env, { SSH_AUTH_SOCK: inherited })).includes("[--setenv=SSH_AUTH_SOCK=" + inherited + "]"));
    // the user manager's own value wins, but only when it is a live socket
    fake("systemctl", '[ "$2" = show-environment ] && echo SSH_AUTH_SOCK=/nonexistent/agent');
    assert.ok(bash(s, Object.assign({}, env, { SSH_AUTH_SOCK: inherited })).includes("[--setenv=SSH_AUTH_SOCK=" + inherited + "]"));
    const manager = sock("manager");
    fake("systemctl", '[ "$2" = show-environment ] && echo SSH_AUTH_SOCK=' + manager);
    assert.ok(bash(s, Object.assign({}, env, { SSH_AUTH_SOCK: inherited })).includes("[--setenv=SSH_AUTH_SOCK=" + manager + "]"));
    fs.rmSync(fakeBin, { recursive: true });
});

test("startScript stops each bounced unit in its own systemctl call", () => {
    const f = { id: "t2", localPort: 3998, sshTarget: "h", remoteHost: "localhost", remotePort: 1, extraOptions: "" };
    const fakeBin = fs.mkdtempSync("/tmp/pf-fake-");
    const log = path.join(fakeBin, "calls");
    // a systemctl that, like systemd 262, refuses the call when a unit is unknown
    fs.writeFileSync(path.join(fakeBin, "systemctl"), "#!/bin/sh\necho \"$*\" >> " + log + "\nexit 0\n", { mode: 0o755 });
    fs.writeFileSync(path.join(fakeBin, "ss"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    const s = L.startScript(f, ["porthole-a", "porthole-b"], false, "d").replace("exec systemd-run", "exec true");
    bash(s, { PATH: fakeBin + ":/usr/bin", XDG_RUNTIME_DIR: fakeBin });
    const calls = fs.readFileSync(log, "utf8").trim().split("\n").filter(l => !l.includes("show-environment"));
    assert.deepStrictEqual(calls, [
        "--user stop porthole-t2", "--user reset-failed porthole-t2",
        "--user stop porthole-a", "--user reset-failed porthole-a",
        "--user stop porthole-b", "--user reset-failed porthole-b"]);
    fs.rmSync(fakeBin, { recursive: true });
});

test("parsePoll + deriveStatus follow the original table", () => {
    const b64 = Buffer.from("ssh: connect to host x port 22: Connection refused — ç").toString("base64");
    const p = L.parsePoll("a active yes - - - i1\nb active no - - https://login.tailscale.com/a/xyz i2\nc active no - - - -\nd failed no " + b64 + " new - i4\ne inactive no - - - -\nf activating no - - - -\ng active shared - - - i7\nh failed no = = - i8\n@cfg 1.2.3\n");
    assert.strictEqual(p.cfg, "1.2.3");
    assert.deepStrictEqual(Array.from(p.rows.map(L.deriveStatus)), ["active", "auth", "connecting", "error", "inactive", "connecting", "active", "error"]);
    assert.strictEqual(p.rows[3].msg, "ssh: connect to host x port 22: Connection refused — ç");
    assert.strictEqual(p.rows[3].hostKey, "new");
    assert.strictEqual(p.rows[3].invocation, "i4");
    assert.strictEqual(p.rows[1].url, "https://login.tailscale.com/a/xyz");
    assert.strictEqual(p.rows[6].listen, "shared");
    assert.strictEqual(p.rows[7].cached, true);
    assert.strictEqual(p.rows[7].msg, "");
});

test("pollScript: own listener, shared port, cached journal", () => {
    // Fake systemctl/ss/journalctl: unit u-a is ssh pid 100 on 4001, unit u-b
    // shares 4002 with pid 200, u-c is failed (journal counted).
    const fakeBin = fs.mkdtempSync("/tmp/pf-fake-");
    const jlog = path.join(fakeBin, "journal-calls");
    const fake = (name, body) => fs.writeFileSync(path.join(fakeBin, name), "#!/bin/bash\n" + body + "\n", { mode: 0o755 });
    fake("ss", 'cat <<"EOF"\nLISTEN 0 128 127.0.0.1:4001 0.0.0.0:* users:(("ssh",pid=100,fd=4))\nLISTEN 0 128 [::1]:4002 [::]:* users:(("ssh",pid=101,fd=4))\nLISTEN 0 5 127.0.0.1:4002 0.0.0.0:* users:(("python3",pid=200,fd=3))\nLISTEN 0 5 127.0.0.1:4003 0.0.0.0:* users:(("python3",pid=300,fd=3))\nEOF');
    fake("systemctl", 'u="${@: -1}"\ncase "$*" in\n*is-active*porthole-c) echo failed;;\n*is-active*) echo active;;\n*InvocationID*) echo "inv-$u";;\n*MainPID*porthole-a) echo 100;;\n*MainPID*porthole-b) echo 101;;\n*MainPID*) echo 0;;\nesac');
    fake("journalctl", 'echo call >> ' + jlog + '\necho "ssh: connect to host x port 22: Connection refused"');
    fake("stat", "echo 1.2.3");
    const env = { PATH: fakeBin + ":/usr/bin" };
    const fw = [{ id: "a", localPort: 4001 }, { id: "b", localPort: 4002 }, { id: "c", localPort: 4004 }, { id: "d", localPort: 4003 }];
    let p = L.parsePoll(bash(L.pollScript(fw, {}), env));
    assert.deepStrictEqual(Array.from(p.rows.map(r => r.listen)), ["yes", "shared", "no", "no"]);
    // d: a foreign program on its port does not make it active
    assert.strictEqual(L.deriveStatus(p.rows[3]), "connecting");
    assert.strictEqual(p.rows[2].msg, "ssh: connect to host x port 22: Connection refused");
    assert.strictEqual(p.rows[2].invocation, "inv-porthole-c");
    const calls = () => fs.readFileSync(jlog, "utf8").trim().split("\n").length;
    const before = calls();
    p = L.parsePoll(bash(L.pollScript([fw[2]], { c: "inv-porthole-c" }), env));
    assert.strictEqual(p.rows[0].cached, true);
    assert.strictEqual(calls(), before, "journal read again for a cached invocation");
    fs.rmSync(fakeBin, { recursive: true });
});

test("errorKind", () => {
    assert.strictEqual(L.errorKind("changed", "x"), "hostkey-changed");
    assert.strictEqual(L.errorKind("new", "x"), "hostkey-new");
    assert.strictEqual(L.errorKind("", "alice@127.0.0.1: Permission denied (publickey)."), "publickey");
    assert.strictEqual(L.errorKind("", "bind: Address already in use"), "raw");
    assert.strictEqual(L.errorKind("", ""), "generic");
});

test("decodeBase64Utf8 matches Buffer for multibyte text", () => {
    for (const s of ["", "a", "ab", "abc", "Türkçe ğüşiöç", "emoji 🚀 ok", "日本語"]) {
        assert.strictEqual(L.decodeBase64Utf8(Buffer.from(s).toString("base64")), s);
    }
});

test("parseSshHosts skips patterns and dedupes", () => {
    assert.deepStrictEqual(Array.from(L.parseSshHosts("Host ok <b>x</b> a&b\n")), ["ok"]);
    const hosts = L.parseSshHosts("Host foundry staging\n  HostName 1.2.3.4\nHost *\nHost *.corp !bad web?\nhost=bastion # comment\nMatch host x\n  Host  \"quoted\"\nHost foundry\n");
    assert.deepStrictEqual(Array.from(hosts), ["foundry", "staging", "bastion", "quoted"]);
});

test("sshConfigScript follows one level of Include", () => {
    const home = fs.mkdtempSync("/tmp/pf-home-");
    fs.mkdirSync(path.join(home, ".ssh/conf.d"), { recursive: true });
    fs.writeFileSync(path.join(home, ".ssh/config"), "Include conf.d/*.conf\nInclude ~/.ssh/extra\nHost main\n");
    fs.writeFileSync(path.join(home, ".ssh/conf.d/a.conf"), "Host inc-a\n");
    fs.writeFileSync(path.join(home, ".ssh/extra"), "Host inc-extra\n");
    const out = bash(L.sshConfigScript(), { HOME: home });
    assert.deepStrictEqual(Array.from(L.parseSshHosts(out)).sort(), ["inc-a", "inc-extra", "main"]);
    assert.strictEqual(bash(L.sshConfigScript(), { HOME: "/nonexistent" }), "");
    fs.rmSync(home, { recursive: true });
});

test("store read/write scripts round-trip atomically", () => {
    const cfgHome = fs.mkdtempSync("/tmp/pf-cfg-");
    const env = { XDG_CONFIG_HOME: cfgHome };
    let code = 0;
    try { bash(L.readStoreScript(), env); } catch (e) { code = e.status; }
    assert.strictEqual(code, 3);
    const content = L.serializeStore([{ id: "x", label: "it's \"q\" ✓", localPort: 1, sshTarget: "h", remoteHost: "localhost", remotePort: 1, autostart: false, extraOptions: "" }]);
    const sig = bash(L.writeStoreScript(content), env).trim();
    assert.ok(/^\d+\.\d+\.\d+$/.test(sig), sig);
    assert.strictEqual(bash(L.readStoreScript(), env), content);
    assert.deepStrictEqual(fs.readdirSync(path.join(cfgHome, "porthole")), ["forwards.json"]);
    // a new file gets the umask's mode, not mktemp's 0600
    assert.strictEqual(fs.statSync(path.join(cfgHome, "porthole/forwards.json")).mode & 0o777, 0o644 & ~process.umask());
    fs.rmSync(cfgHome, { recursive: true });
});

test("writing follows a symlinked store and keeps its mode", () => {
    const cfgHome = fs.mkdtempSync("/tmp/pf-cfg-");
    const dotfiles = fs.mkdtempSync("/tmp/pf-dot-");
    const real = path.join(dotfiles, "forwards.json");
    fs.writeFileSync(real, "{}\n", { mode: 0o640 });
    fs.chmodSync(real, 0o640);
    fs.mkdirSync(path.join(cfgHome, "porthole"));
    fs.symlinkSync(real, path.join(cfgHome, "porthole/forwards.json"));
    bash(L.writeStoreScript("{\"version\": 1}\n"), { XDG_CONFIG_HOME: cfgHome });
    assert.ok(fs.lstatSync(path.join(cfgHome, "porthole/forwards.json")).isSymbolicLink());
    assert.strictEqual(fs.readFileSync(real, "utf8"), "{\"version\": 1}\n");
    assert.strictEqual(fs.statSync(real).mode & 0o777, 0o640);
    assert.deepStrictEqual(fs.readdirSync(dotfiles), ["forwards.json"]);
    fs.rmSync(cfgHome, { recursive: true });
    fs.rmSync(dotfiles, { recursive: true });
});

test("dependencyScript reports missing tools", () => {
    const empty = fs.mkdtempSync("/tmp/pf-path-");
    fs.symlinkSync("/usr/bin/bash", path.join(empty, "bash"));
    const out = execFileSync(path.join(empty, "bash"), ["-c", L.dependencyScript()], { encoding: "utf8", env: { PATH: empty } }).trim();
    assert.strictEqual(out, "ssh systemd-run systemctl journalctl ss");
    assert.strictEqual(bash(L.dependencyScript()).trim(), "");
    fs.rmSync(empty, { recursive: true });
});


test("ss lines: IPv4, IPv6, wildcard, scope suffixes, no/many users", () => {
    const a = L.parseSsLine('LISTEN 0 511 127.0.0.1:5180 0.0.0.0:* users:(("node-MainThread",pid=3453156,fd=22))');
    assert.deepStrictEqual(JSON.parse(JSON.stringify(a)), { host: "127.0.0.1", port: 5180, scope: "loopback", procs: [{ name: "node-MainThread", pid: 3453156 }] });
    const b = L.parseSsLine("LISTEN 0 4096 [::1]:631 [::]:*");
    assert.strictEqual(b.host, "::1"); assert.strictEqual(b.port, 631); assert.strictEqual(b.scope, "loopback"); assert.strictEqual(b.procs.length, 0);
    const c = L.parseSsLine('LISTEN 0 511 *:3000 *:* users:(("next-server (v1",pid=3455250,fd=22))');
    assert.strictEqual(c.host, "*"); assert.strictEqual(c.scope, "all"); assert.strictEqual(c.procs[0].name, "next-server (v1");
    const d = L.parseSsLine("LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*");
    assert.strictEqual(d.host, "127.0.0.53"); assert.strictEqual(d.port, 53); assert.strictEqual(d.scope, "loopback");
    // the interface comes after the bracket, as ss prints it
    const e = L.parseSsLine("LISTEN 0 128 [fe80::1]%wlan0:22 [::]:*");
    assert.strictEqual(e.host, "fe80::1"); assert.strictEqual(e.port, 22); assert.strictEqual(e.scope, "lan");
    const e2 = L.parseSsLine("LISTEN 0 128 [::1]%lo:3000 [::]:*");
    assert.strictEqual(e2.host, "::1"); assert.strictEqual(e2.scope, "loopback");
    const f = L.parseSsLine('LISTEN 0 128 0.0.0.0:8000 0.0.0.0:* users:(("gunicorn",pid=10,fd=5),("gunicorn",pid=11,fd=5),("gunicorn",pid=12,fd=5))');
    assert.deepStrictEqual(Array.from(f.procs.map(x => x.pid)), [10, 11, 12]); assert.strictEqual(f.scope, "all");
    assert.strictEqual(L.parseSsLine("LISTEN 0 4096 [::]:5355 [::]:*").scope, "all");
    assert.strictEqual(L.parseSsLine("LISTEN 0 4096 100.64.0.7:42643 0.0.0.0:*").scope, "lan");
    assert.strictEqual(L.parseSsLine("garbage"), null);
    assert.strictEqual(L.formatAddress("::1", 631), "[::1]:631");
    assert.strictEqual(L.formatAddress("127.0.0.1", 5180), "127.0.0.1:5180");
});

test("process names", () => {
    const n = (args, comm) => L.processLabel(args, comm).name;
    assert.strictEqual(n(["node", "/home/u/Projects/x/node_modules/.bin/vite", "--port", "5180"], "node-MainThread"), "Vite");
    assert.strictEqual(n(["node", "/w/node_modules/vite/bin/vite.js"], "node"), "Vite");
    assert.strictEqual(n(["node", "/home/u/Projects/p/node_modules/.bin/../vite/bin/vite.js", "--port", "5180"], "node-MainThread"), "Vite");
    assert.strictEqual(n(["node", "/w/node_modules/.pnpm/vite@5.4.0/node_modules/vite/bin/vite.js"], "node"), "Vite");
    assert.strictEqual(n(["node", "/w/node_modules/next/dist/bin/next", "dev"], "node"), "Next.js");
    assert.strictEqual(n(["node", "/w/inviteserver.js"], "node"), "Node inviteserver.js");
    assert.strictEqual(n(["next-server (v15.1.0)"], "next-server (v1"), "Next.js");
    assert.strictEqual(n(["node", "/w/node_modules/.bin/next", "dev"], "node"), "Next.js");
    assert.strictEqual(n(["python3", "-m", "http.server", "8000", "--bind", "127.0.0.1"], "python3"), "Python http.server");
    assert.strictEqual(n(["/usr/bin/python3.12", "-m", "uvicorn", "app:app"], "python3.12"), "Uvicorn");
    assert.strictEqual(n(["/venv/bin/uvicorn", "app:app"], "uvicorn"), "Uvicorn");
    assert.strictEqual(n(["python", "manage.py", "runserver"], "python"), "Django");
    assert.strictEqual(n(["python3", "-m", "flask", "run"], "python3"), "Flask");
    assert.strictEqual(n(["/usr/bin/docker-proxy", "-proto", "tcp"], "docker-proxy"), "Docker");
    assert.strictEqual(n(["/usr/lib/postgresql/bin/postgres", "-D", "/x"], "postgres"), "PostgreSQL");
    assert.strictEqual(n(["redis-server", "*:6379"], "redis-server"), "Redis");
    assert.strictEqual(n(["node", "--inspect", "server.js"], "node"), "Node server.js");
    assert.strictEqual(n(["node", "/w/node_modules/.bin/astro", "dev"], "node"), "Node astro");
    assert.strictEqual(n(["bun", "run", "dev.ts"], "bun"), "Bun dev.ts");
    assert.strictEqual(n(["php", "-S", "localhost:8080"], "php"), "PHP server");
    const k = L.processLabel(["/usr/bin/kdeconnectd"], "kdeconnectd");
    assert.strictEqual(k.name, "kdeconnectd"); assert.strictEqual(k.dev, false);
    assert.strictEqual(n([], "cupsd"), "cupsd");
});

test("project names", () => {
    // the git repository wins
    assert.strictEqual(L.projectName("/home/u/work/acme/shop/web", "/home/u", "/home/u/work/acme/shop"), "shop");
    assert.strictEqual(L.projectName("/srv/api/src", "/home/u", "/srv/api"), "api");
    // a dotfiles repository in $HOME is not a project
    assert.strictEqual(L.projectName("/home/u", "/home/u", "/home/u"), "");
    assert.strictEqual(L.projectName("/home/u/notes", "/home/u", "/home/u"), "notes");
    // no repository: the folder under a projects folder, any common name
    assert.strictEqual(L.projectName("/home/u/Projects/blog/web", "/home/u"), "blog");
    assert.strictEqual(L.projectName("/home/u/code/blog", "/home/u"), "blog");
    assert.strictEqual(L.projectName("/home/u/Projeler/blog/web", "/home/u"), "blog");
    assert.strictEqual(L.projectName("/home/u/src/blog/a/b", "/home/u"), "blog");
    assert.strictEqual(L.projectName("/home/u/Projects", "/home/u"), "Projects");
    assert.strictEqual(L.projectName("/home/u/Downloads/site", "/home/u"), "site");
    assert.strictEqual(L.projectName("/srv/www/site/", "/home/u"), "site");
    assert.strictEqual(L.projectName("/home/u", "/home/u"), "");
    assert.strictEqual(L.projectName("/", "/home/u"), "");
    assert.strictEqual(L.projectName("", "/home/u"), "");
});

test("docker ps ports", () => {
    const m = L.parseDockerPorts("pg-main\t0.0.0.0:18123->8123/tcp, [::]:18123->8123/tcp, 9000/tcp\nweb\t127.0.0.1:8080-8081->80-81/tcp\nnoports\t\nudp\t0.0.0.0:53->53/udp");
    assert.strictEqual(m[18123], "pg-main");
    assert.strictEqual(m[8080], "web"); assert.strictEqual(m[8081], "web");
    assert.strictEqual(m[9000], undefined); assert.strictEqual(m[53], undefined);
});

test("parseLocalPorts: grouping, tunnels left out, docker, system", () => {
    const b = s => Buffer.from(s).toString("base64");
    const text = [
        "@home " + b("/home/u"),
        '@l LISTEN 0 511 127.0.0.1:5180 0.0.0.0:* users:(("node-MainThread",pid=100,fd=22))',
        '@l LISTEN 0 511 [::1]:5180 [::]:* users:(("node-MainThread",pid=100,fd=23))',
        '@l LISTEN 0 511 *:3000 *:* users:(("next-server (v1",pid=200,fd=22))',
        '@l LISTEN 0 128 127.0.0.1:18765 0.0.0.0:* users:(("ssh",pid=300,fd=4))',
        '@l LISTEN 0 4096 0.0.0.0:18123 0.0.0.0:*',
        '@l LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*',
        '@l LISTEN 0 50 *:1716 *:* users:(("kdeconnectd",pid=400,fd=18))',
        '@l LISTEN 0 5 0.0.0.0:8000 0.0.0.0:* users:(("gunicorn",pid=501,fd=5),("gunicorn",pid=500,fd=5))',
        "@p 100 no 1 111 " + b("node\n/home/u/Projects/notes/node_modules/.bin/vite\n") + " " + b("/home/u/Projects/notes"),
        "@p 200 no 1 222 " + b("next-server (v15)\n") + " " + b("/home/u/Projects/shop/app"),
        "@p 300 yes 1 333 " + b("ssh\n-N\n") + " " + b("/"),
        "@p 400 no 1 444 " + b("/usr/bin/kdeconnectd\n") + " " + b("/home/u"),
        "@p 500 no 1 555 " + b("/venv/bin/gunicorn\napp:app\n") + " " + b("/srv/api"),
        "@p 501 no 500 556 " + b("/venv/bin/gunicorn\napp:app\n") + " " + b("/srv/api"),
        "@docker " + b("pg-main\t0.0.0.0:18123->8123/tcp"),
    ].join("\n");
    const r = L.parseLocalPorts(text);
    const e = Array.from(r.entries.map(x => [x.port, x.name, x.project, x.scope, x.kind, x.pid]));
    assert.deepStrictEqual(JSON.parse(JSON.stringify(e)), [
        [3000, "Next.js", "shop", "all", "user", 200],
        [5180, "Vite", "notes", "loopback", "user", 100],
        [8000, "Gunicorn", "api", "all", "user", 500],
        [18123, "Docker", "pg-main", "all", "docker", 0]]);
    assert.deepStrictEqual(Array.from(r.entries[1].hosts), ["127.0.0.1", "::1"]);
    assert.strictEqual(r.entries[1].start, "111");
    assert.ok(!r.entries.some(x => x.port === 18765) && !r.system.some(x => x.port === 18765), "tunnel listed");
    assert.deepStrictEqual(JSON.parse(JSON.stringify(r.system.map(x => [x.port, x.kind, x.name]))), [[53, "system", ""], [1716, "own-system", "kdeconnectd"]]);
    // without docker the container port is a system service
    const nod = L.parseLocalPorts(text.split("\n").filter(l => !l.startsWith("@docker")).join("\n"));
    assert.ok(nod.system.some(x => x.port === 18123 && x.kind === "system"));
    // a Docker socket this user cannot write to: unnamed ports get a hint, nothing else changes
    const denied = L.parseLocalPorts(text.split("\n").filter(l => !l.startsWith("@docker")).join("\n") + "\n@dockerdenied");
    assert.strictEqual(denied.dockerDenied, true);
    assert.strictEqual(nod.dockerDenied, false);
    assert.strictEqual(r.dockerDenied, false);
    const noPidless = L.parseLocalPorts(["@home " + b("/home/u"), '@l LISTEN 0 50 *:1716 *:* users:(("kdeconnectd",pid=400,fd=18))', "@p 400 no 1 444 " + b("/usr/bin/kdeconnectd\n") + " " + b("/home/u"), "@dockerdenied"].join("\n"));
    assert.strictEqual(noPidless.dockerDenied, false, "hint shown with no unnamed port to explain");
    assert.strictEqual(L.browseHost(r.entries[0]), "localhost");
    assert.strictEqual(L.browseHost({ scope: "lan", hosts: ["192.168.1.5"] }), "192.168.1.5");
});

test("localPortsScript runs and sees a real listener with its cwd", () => {
    const dir = fs.mkdtempSync("/tmp/pf-lp-");
    const child = require("child_process").spawn("python3", ["-m", "http.server", "18899", "--bind", "127.0.0.1"], { cwd: dir, stdio: "ignore" });
    try {
        let r = null;
        for (let i = 0; i < 50; i++) {
            execFileSync("sleep", ["0.1"]);
            r = L.parseLocalPorts(bash(L.localPortsScript()));
            if (r.entries.some(x => x.port === 18899)) break;
        }
        const e = r.entries.filter(x => x.port === 18899)[0];
        assert.ok(e, "listener not found");
        assert.strictEqual(e.name, "Python http.server");
        assert.strictEqual(e.project, path.basename(dir));
        assert.strictEqual(e.pid, child.pid);
        assert.strictEqual(e.scope, "loopback");
    } finally {
        child.kill("SIGKILL");
        fs.rmSync(dir, { recursive: true });
    }
});

test("localPortsScript names the project after the git repository above the cwd", () => {
    const repo = fs.mkdtempSync("/tmp/pf-repo-");
    fs.mkdirSync(path.join(repo, ".git"));
    fs.mkdirSync(path.join(repo, "apps", "web"), { recursive: true });
    const child = require("child_process").spawn("python3", ["-m", "http.server", "18898", "--bind", "127.0.0.1"], { cwd: path.join(repo, "apps", "web"), stdio: "ignore" });
    try {
        let r = null;
        for (let i = 0; i < 50; i++) {
            execFileSync("sleep", ["0.1"]);
            r = L.parseLocalPorts(bash(L.localPortsScript()));
            if (r.entries.some(x => x.port === 18898)) break;
        }
        const e = r.entries.filter(x => x.port === 18898)[0];
        assert.ok(e, "listener not found");
        assert.strictEqual(e.project, path.basename(repo));
    } finally {
        child.kill("SIGKILL");
        fs.rmSync(repo, { recursive: true });
    }
});

test("localPortsScript reports a Docker socket the user cannot write to", () => {
    const sock = "/var/run/docker.sock";
    if (!fs.existsSync(sock) || !require("child_process").spawnSync("sh", ["-c", "command -v docker"]).stdout.length)
        return; // no Docker here: nothing to report
    let writable = true;
    try { fs.accessSync(sock, fs.constants.W_OK); } catch (e) { writable = false; }
    assert.strictEqual(/^@dockerdenied$/m.test(bash(L.localPortsScript())), !writable);
});

test("killScript: TERM, refuses a reused pid, reports a survivor", () => {
    const { spawn } = require("child_process");
    const stat = pid => fs.readFileSync("/proc/" + pid + "/stat", "utf8").replace(/^.*\) /, "").split(" ")[19];
    const a = spawn("sleep", ["60"], { stdio: "ignore", detached: true });
    const startA = stat(a.pid);
    assert.strictEqual(bash(L.killScript(a.pid, "1", false)).trim(), "gone"); // wrong start time: untouched
    assert.ok(fs.existsSync("/proc/" + a.pid));
    a.unref();
    assert.strictEqual(bash(L.killScript(a.pid, startA, false)).trim(), "gone");
    const b = spawn("bash", ["-c", "trap '' TERM; sleep 60 & wait; sleep 60"], { stdio: "ignore", detached: true });
    execFileSync("sleep", ["0.3"]);
    const startB = stat(b.pid);
    assert.strictEqual(bash(L.killScript(b.pid, startB, false)).trim(), "alive");
    assert.strictEqual(bash(L.killScript(b.pid, startB, true)).trim(), "gone");
    try { process.kill(-b.pid, "SIGKILL"); } catch (e) { /* already gone */ }
});


// --- bind address --------------------------------------------------------------

test("bind address: accepted and refused shapes", () => {
    const ok = {
        "": "", "   ": "", " 127.0.1.1 ": "127.0.1.1", "0.0.0.0": "0.0.0.0", "255.255.255.255": "255.255.255.255",
        "localhost": "localhost", "LocalHost": "localhost", "*": "*", "::": "::", "::1": "::1", "[::1]": "::1",
        "[ ::1 ]": "::1", "FE80::1": "fe80::1", "2001:db8::42": "2001:db8::42", "::ffff:127.0.0.1": "::ffff:127.0.0.1",
        "0:0:0:0:0:0:0:1": "0:0:0:0:0:0:0:1"
    };
    for (const k in ok)
        assert.strictEqual(L.normalizeBindAddress(k), ok[k], k);
    assert.strictEqual(L.normalizeBindAddress(undefined), "");
    assert.strictEqual(L.normalizeBindAddress(null), "");
    for (const bad of ["256.1.1.1", "01.2.3.4", "1.2.3", "1.2.3.4.5", "host.lan", "example.com", "[]", "[127.0.0.1]",
            "[localhost]", "fe80::1%eth0", "1::2::3", ":::", "1:2:3:4:5:6:7:8:9", "127.0.0.1:3000", "**", "-oProxyCommand=x", "a b", 5, true])
        assert.strictEqual(L.normalizeBindAddress(bad), null, String(bad));
});

test("bind address: IPv6 compared in the form ss prints", () => {
    const cases = { "0:0:0:0:0:0:0:1": "::1", "::": "::", "FE80:0:0:0:0:0:0:1": "fe80::1", "1:0:0:2:0:0:0:3": "1:0:0:2::3",
        "1:0:0:0:2:0:0:3": "1::2:0:0:3", "1:0:2:3:4:5:6:7": "1:0:2:3:4:5:6:7", "2001:db8::": "2001:db8::",
        "::ffff:7f00:1": "::ffff:127.0.0.1", "1:2:3:4:5:6:1.2.3.4": "1:2:3:4:5:6:102:304" };
    for (const k in cases)
        assert.strictEqual(L.canonicalIPv6(k), cases[k], k);
    assert.strictEqual(L.bindKey("[0:0::1]"), "::1");
    assert.strictEqual(L.bindKey("localhost"), "");
    assert.strictEqual(L.bindKey(""), "");
    assert.strictEqual(L.bindKey("127.0.1.1"), "127.0.1.1");
});

test("bind address: store round trip, old files and their ids unchanged", () => {
    // a file written before bind addresses: read as is, ids derived exactly as
    // 0.1.0 derived them (running units keep their names)
    const old = JSON.stringify({ version: 1, forwards: [{ localPort: 8080, sshTarget: "web" },
        { label: "DB", localPort: 5432, sshTarget: "db", remoteHost: "10.0.0.5", remotePort: 5432 }] });
    const r = L.parseStore(old);
    assert.deepStrictEqual(Array.from(r.forwards.map(f => f.id)), ["hksph4d", "hkrc0np"]);
    assert.deepStrictEqual(Array.from(r.forwards.map(f => f.bindAddress)), ["", ""]);
    assert.strictEqual(r.invalid.length, 0);
    // saved the way every known field is saved, then read back the same
    const text = L.serializeStore(r.forwards, r.extras, r.invalid, r.top);
    assert.strictEqual(JSON.parse(text).forwards[0].bindAddress, "");
    assert.deepStrictEqual(JSON.parse(JSON.stringify(L.parseStore(text).forwards)), JSON.parse(JSON.stringify(r.forwards)));
    // set addresses: normalised on load, written back, identical on the next load
    const withBind = JSON.stringify({ version: 1, forwards: [
        { id: "a", bindAddress: " 127.0.1.1 ", localPort: 3000, sshTarget: "a" },
        { id: "b", bindAddress: "[::1]", localPort: 3000, sshTarget: "b" },
        { id: "c", bindAddress: "box.lan", localPort: 3000, sshTarget: "c", comment: "kept" },
        { localPort: 8080, sshTarget: "web", bindAddress: "127.0.1.2" }] });
    const w = L.parseStore(withBind);
    assert.deepStrictEqual(Array.from(w.forwards.map(f => f.bindAddress)), ["127.0.1.1", "::1", "127.0.1.2"]);
    // a bind address changes the derived id (two entries otherwise alike)
    assert.notStrictEqual(w.forwards[2].id, "hksph4d");
    // an address that is not one: refused like any unreadable entry, kept verbatim
    assert.strictEqual(w.invalid.length, 1);
    const back = JSON.parse(L.serializeStore(w.forwards, w.extras, w.invalid, w.top));
    assert.deepStrictEqual(back.forwards[2], { id: "c", bindAddress: "box.lan", localPort: 3000, sshTarget: "c", comment: "kept" });
    assert.strictEqual(back.forwards[0].bindAddress, "127.0.1.1");
    assert.strictEqual(back.forwards[1].bindAddress, "::1");
    const again = L.parseStore(JSON.stringify(back));
    assert.deepStrictEqual(JSON.parse(JSON.stringify(again.forwards)), JSON.parse(JSON.stringify(w.forwards)));
});

test("bind address: the -L spec; without one, byte for byte the old spec", () => {
    const f = { localPort: 3000, sshTarget: "foundry", remoteHost: "", remotePort: 3001, extraOptions: "" };
    const spec = b => { const c = Array.from(L.forwardCommand(Object.assign({}, f, b === undefined ? {} : { bindAddress: b }), false)); return c[c.indexOf("-L") + 1]; };
    // regression: no field, empty, blank
    for (const b of [undefined, "", "   ", null])
        assert.strictEqual(spec(b), "3000:localhost:3001", String(b));
    assert.deepStrictEqual(Array.from(L.forwardCommand(Object.assign({}, f, { bindAddress: "" }), false)), Array.from(L.forwardCommand(f, false)));
    assert.strictEqual(spec("127.0.1.1"), "127.0.1.1:3000:localhost:3001");
    assert.strictEqual(spec("localhost"), "localhost:3000:localhost:3001");
    assert.strictEqual(spec("0.0.0.0"), "0.0.0.0:3000:localhost:3001");
    assert.strictEqual(spec("*"), "*:3000:localhost:3001");
    assert.strictEqual(spec("::1"), "[::1]:3000:localhost:3001");
    assert.strictEqual(spec("[fe80::1]"), "[fe80::1]:3000:localhost:3001");
    assert.strictEqual(spec("::"), "[::]:3000:localhost:3001");
    // through startScript and bash: "*" stays one literal argument
    const fakeBin = fs.mkdtempSync("/tmp/pf-fake-");
    for (const name of ["systemctl", "ss", "gpgconf"])
        fs.writeFileSync(path.join(fakeBin, name), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    const run = b => bash(L.startScript(Object.assign({ id: "t" }, f, { bindAddress: b }), [], false, "d").replace("exec systemd-run", "exec printf '[%s]'"),
        { PATH: fakeBin + ":/usr/bin", XDG_RUNTIME_DIR: fakeBin, SSH_AUTH_SOCK: "" });
    assert.ok(run("*").includes("[-L][*:3000:localhost:3001][--][foundry]"));
    assert.ok(run("::1").includes("[-L][[::1]:3000:localhost:3001]"));
    assert.ok(run("").includes("[-L][3000:localhost:3001]"));
    fs.rmSync(fakeBin, { recursive: true });
});

test("bind address: conflict matrix", () => {
    const yes = [["", ""], ["", "localhost"], ["", "127.0.0.1"], ["", "::1"], ["", "[0:0::1]"], ["localhost", "127.0.0.1"],
        ["127.0.1.1", "127.0.1.1"], ["0.0.0.0", "127.0.1.1"], ["0.0.0.0", ""], ["0.0.0.0", "192.168.1.5"], ["0.0.0.0", "0.0.0.0"],
        ["*", "::1"], ["*", "127.0.1.1"], ["*", ""], ["::", "::1"], ["::", ""], ["::", "fe80::1"], ["::", "::"], ["*", "::"],
        ["*", "0.0.0.0"], ["fe80::1", "FE80:0:0:0:0:0:0:1"]];
    const no = [["127.0.1.1", "127.0.1.2"], ["", "127.0.1.1"], ["localhost", "127.0.1.2"], ["", "192.168.1.5"],
        ["0.0.0.0", "::1"], ["0.0.0.0", "fe80::1"], ["127.0.0.1", "::1"], ["::1", "fe80::1"], ["192.168.1.5", "10.0.0.1"],
        // ssh's IPv6 listeners are IPv6 only: [::]:P and 127.0.1.1:P bind side by side
        ["::", "127.0.1.1"], ["::", "0.0.0.0"], ["::", "192.168.1.5"]];
    for (const [a, b] of yes) {
        assert.strictEqual(L.bindAddressesOverlap(a, b), true, a + " / " + b);
        assert.strictEqual(L.bindAddressesOverlap(b, a), true, b + " / " + a);
    }
    for (const [a, b] of no) {
        assert.strictEqual(L.bindAddressesOverlap(a, b), false, a + " / " + b);
        assert.strictEqual(L.bindAddressesOverlap(b, a), false, b + " / " + a);
    }
    // forwards: the port has to match too; missing fields are the default
    const fw = (port, bind) => ({ localPort: port, bindAddress: bind });
    assert.strictEqual(L.forwardsConflict(fw(3000, "127.0.1.1"), fw(3000, "127.0.1.2")), false);
    assert.strictEqual(L.forwardsConflict(fw(3000, "127.0.1.1"), fw(3001, "127.0.1.1")), false);
    assert.strictEqual(L.forwardsConflict(fw(3000, "127.0.1.1"), fw(3000, "127.0.1.1")), true);
    assert.strictEqual(L.forwardsConflict({ localPort: 3000 }, { localPort: 3000 }), true);
    assert.strictEqual(L.forwardsConflict({ localPort: 3000 }, fw(3000, "0.0.0.0")), true);
});

test("bind address: the shell's overlap check agrees with the JS one", () => {
    // every listener shape ss prints against every bind key
    const hosts = ["127.0.0.1", "::1", "127.0.1.1", "127.0.1.2", "0.0.0.0", "*", "::", "192.168.1.5", "fe80::1"];
    const binds = ["", "127.0.0.1", "::1", "127.0.1.1", "0.0.0.0", "*", "::", "192.168.1.5", "fe80::1"];
    let script = L.LISTEN_SHELL;
    for (const h of hosts)
        for (const b of binds)
            script += "ov " + L.shellQuote(h) + " " + L.shellQuote(b) + " && echo 1 || echo 0; ";
    const shell = bash(script).trim().split("\n");
    let i = 0;
    for (const h of hosts)
        for (const b of binds) {
            const js = b === "" ? L.listenAddressesOverlap(h, "127.0.0.1") || L.listenAddressesOverlap(h, "::1") : L.listenAddressesOverlap(h, b);
            assert.strictEqual(shell[i++], js ? "1" : "0", h + " vs " + JSON.stringify(b));
        }
    // fixed answers too, so the two sides cannot share a mistake:
    // [ss host, bind key, overlap]
    const known = [["*", "127.0.1.1", 1], ["*", "::1", 1], ["::", "127.0.1.1", 0], ["::", "", 1], ["::", "::1", 1],
        ["::", "0.0.0.0", 0], ["127.0.1.1", "::", 0], ["::1", "::", 1], ["0.0.0.0", "::1", 0], ["0.0.0.0", "127.0.1.1", 1],
        ["0.0.0.0", "", 1], ["127.0.1.1", "", 0], ["::1", "", 1], ["127.0.1.2", "127.0.1.1", 0], ["192.168.1.5", "*", 1]];
    for (const [h, b, want] of known) {
        assert.strictEqual(bash(L.LISTEN_SHELL + "ov " + L.shellQuote(h) + " " + L.shellQuote(b) + " && echo 1 || echo 0").trim(), String(want), "shell " + h + " vs " + JSON.stringify(b));
        const js = b === "" ? L.listenAddressesOverlap(h, "127.0.0.1") || L.listenAddressesOverlap(h, "::1") : L.listenAddressesOverlap(h, b);
        assert.strictEqual(js ? 1 : 0, want, "js " + h + " vs " + JSON.stringify(b));
    }
    // and lhost reads every ss address column shape
    const cols = { "127.0.0.1:5180": "127.0.0.1", "[::1]:631": "::1", "*:3000": "*", "[::]:22": "::", "127.0.0.53%lo:53": "127.0.0.53",
        "[fe80::1]%wlan0:22": "fe80::1", "[::1]%lo:3000": "::1", "[fe80::a1af:3e26:e805:e4f6]%enp48s0:546": "fe80::a1af:3e26:e805:e4f6" };
    for (const c in cols)
        assert.strictEqual(bash(L.LISTEN_SHELL + "lhost " + L.shellQuote(c)), cols[c], c);
});

test("bind address: status per address, never mixed between tunnels on one port", () => {
    // pids: 1xx are the tunnels' ssh, 9xx other programs
    const fakeBin = fs.mkdtempSync("/tmp/pf-fake-");
    const fake = (name, body) => fs.writeFileSync(path.join(fakeBin, name), "#!/bin/bash\n" + body + "\n", { mode: 0o755 });
    const ss = [
        // 5001: two tunnels on two loopback addresses, a stranger on a third
        'LISTEN 0 128 127.0.1.1:5001 0.0.0.0:* users:(("ssh",pid=100,fd=4))',
        'LISTEN 0 128 127.0.1.2:5001 0.0.0.0:* users:(("ssh",pid=101,fd=4))',
        'LISTEN 0 5 127.0.1.3:5001 0.0.0.0:* users:(("python3",pid=900,fd=3))',
        // 5002: a stranger on 127.0.1.1 too (SO_REUSEPORT): only that tunnel warns
        'LISTEN 0 128 127.0.1.1:5002 0.0.0.0:* users:(("ssh",pid=102,fd=4))',
        'LISTEN 0 5 127.0.1.1:5002 0.0.0.0:* users:(("python3",pid=901,fd=3))',
        'LISTEN 0 128 127.0.1.2:5002 0.0.0.0:* users:(("ssh",pid=103,fd=4))',
        // 5003: a stranger on every IPv4 address
        'LISTEN 0 5 0.0.0.0:5003 0.0.0.0:* users:(("python3",pid=902,fd=3))',
        'LISTEN 0 128 127.0.1.5:5003 0.0.0.0:* users:(("ssh",pid=104,fd=4))',
        'LISTEN 0 128 [::1]:5003 [::]:* users:(("ssh",pid=105,fd=4))',
        // 5005: the default address, a stranger on 127.0.1.1 does not count
        'LISTEN 0 128 127.0.0.1:5005 0.0.0.0:* users:(("ssh",pid=106,fd=4))',
        'LISTEN 0 128 [::1]:5005 [::]:* users:(("ssh",pid=106,fd=5))',
        'LISTEN 0 5 127.0.1.1:5005 0.0.0.0:* users:(("python3",pid=903,fd=3))',
        // 5006: the default address, 127.0.0.1 taken: shared, as before
        'LISTEN 0 128 [::1]:5006 [::]:* users:(("ssh",pid=107,fd=4))',
        'LISTEN 0 5 127.0.0.1:5006 0.0.0.0:* users:(("python3",pid=904,fd=3))',
        // 5008: an IPv6 bind written long-hand, ss prints it short
        'LISTEN 0 128 [::1]:5008 [::]:* users:(("ssh",pid=108,fd=4))',
        'LISTEN 0 5 [::1]:5008 [::]:* users:(("python3",pid=905,fd=3))',
        // 5009: a stranger on [::] (IPv6 only) does not reach 127.0.1.1
        'LISTEN 0 511 [::]:5009 [::]:* users:(("nginx",pid=907,fd=6))',
        'LISTEN 0 128 127.0.1.1:5009 0.0.0.0:* users:(("ssh",pid=109,fd=4))',
        // 5010: a dual-stack stranger (*) reaches every address
        'LISTEN 0 511 *:5010 *:* users:(("node",pid=908,fd=6))',
        'LISTEN 0 128 127.0.1.1:5010 0.0.0.0:* users:(("ssh",pid=110,fd=4))',
        // 50010 must not be read as port 5001
        'LISTEN 0 5 127.0.1.1:50010 0.0.0.0:* users:(("python3",pid=906,fd=3))',
    ];
    fake("ss", "cat <<\"EOF\"\n" + ss.join("\n") + "\nEOF");
    const pids = { a: 100, b: 101, c: 102, d: 103, e: 104, f: 105, g: 106, h: 107, k: 108, l: 109, m: 110, x: 0 };
    let sc = 'u="${@: -1}"\ncase "$*" in\n*is-active*) echo active;;\n*InvocationID*) echo "inv-$u";;\n';
    for (const id in pids)
        sc += "*MainPID*porthole-" + id + ") echo " + pids[id] + ";;\n";
    fake("systemctl", sc + "esac");
    fake("journalctl", "true");
    fake("stat", "echo 1.2.3");
    const fw = [
        { id: "a", localPort: 5001, bindAddress: "127.0.1.1" }, { id: "b", localPort: 5001, bindAddress: "127.0.1.2" },
        { id: "c", localPort: 5002, bindAddress: "127.0.1.1" }, { id: "d", localPort: 5002, bindAddress: "127.0.1.2" },
        { id: "e", localPort: 5003, bindAddress: "127.0.1.5" }, { id: "f", localPort: 5003, bindAddress: "::1" },
        { id: "g", localPort: 5005 }, { id: "h", localPort: 5006, bindAddress: "" },
        { id: "k", localPort: 5008, bindAddress: "0:0:0:0:0:0:0:1" },
        { id: "l", localPort: 5009, bindAddress: "127.0.1.1" }, { id: "m", localPort: 5010, bindAddress: "127.0.1.1" },
        // nothing of its own listening; strangers elsewhere on the port do not make it active
        { id: "x", localPort: 5001, bindAddress: "127.0.1.9" }];
    const p = L.parsePoll(bash(L.pollScript(fw, {}), { PATH: fakeBin + ":/usr/bin" }));
    const got = {};
    p.rows.forEach(r => { got[r.id] = r.listen; });
    assert.deepStrictEqual(got, { a: "yes", b: "yes", c: "shared", d: "yes", e: "shared", f: "yes", g: "yes", h: "shared", k: "shared", l: "yes", m: "shared", x: "no" });
    assert.strictEqual(L.deriveStatus(p.rows[11]), "connecting");
    fs.rmSync(fakeBin, { recursive: true });
});

test("bind address: start waits only for listeners on its own address", () => {
    // a listener that never goes away on 127.0.1.1:4100
    const fakeBin = fs.mkdtempSync("/tmp/pf-fake-");
    fs.writeFileSync(path.join(fakeBin, "ss"), "#!/bin/sh\necho 'LISTEN 0 128 127.0.1.1:4100 0.0.0.0:*'\n", { mode: 0o755 });
    for (const name of ["systemctl", "gpgconf"])
        fs.writeFileSync(path.join(fakeBin, name), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    const took = b => {
        const s = L.startScript({ id: "w", localPort: 4100, bindAddress: b, sshTarget: "h", remoteHost: "", remotePort: 1, extraOptions: "" }, [], false, "d")
            .replace("exec systemd-run", "exec true");
        const t0 = Date.now();
        bash(s, { PATH: fakeBin + ":/usr/bin", XDG_RUNTIME_DIR: fakeBin });
        return Date.now() - t0;
    };
    assert.ok(took("127.0.1.2") < 1500, "waited for a listener on another address");
    assert.ok(took("") < 1500, "the default address waited for 127.0.1.1");
    assert.ok(took("0.0.0.0") >= 3500, "did not wait for a listener on its own address");
    fs.rmSync(fakeBin, { recursive: true });
});

test("bind address: shown, copied and opened", () => {
    const f = b => ({ localPort: 3000, bindAddress: b });
    const rows = [
        [undefined, "localhost:3000", "localhost:3000"], ["", "localhost:3000", "localhost:3000"],
        ["localhost", "localhost:3000", "localhost:3000"], ["127.0.1.1", "127.0.1.1:3000", "127.0.1.1:3000"],
        ["::1", "[::1]:3000", "[::1]:3000"], ["192.168.1.5", "192.168.1.5:3000", "192.168.1.5:3000"],
        ["0.0.0.0", "0.0.0.0:3000", "localhost:3000"], ["*", "*:3000", "localhost:3000"], ["::", "[::]:3000", "localhost:3000"],
        ["0:0:0:0:0:0:0:0", "[0:0:0:0:0:0:0:0]:3000", "localhost:3000"]];
    for (const [b, shown, browse] of rows) {
        assert.strictEqual(L.localAddress(f(b)), shown, String(b));
        assert.strictEqual(L.browseAddress(f(b)), browse, String(b));
    }
    for (const b of ["", "localhost", "127.0.0.1", "127.0.1.1", "127.255.255.254", "::1", "::ffff:127.0.0.1"])
        assert.strictEqual(L.isLoopbackBind(b), true, b);
    for (const b of ["0.0.0.0", "*", "::", "192.168.1.5", "10.0.0.1", "fe80::1", "128.0.0.1"])
        assert.strictEqual(L.isLoopbackBind(b), false, b);
});

test("local ports: tunnels on several addresses of one port stay out, a server on another address shows", () => {
    const b = s => Buffer.from(s).toString("base64");
    const r = L.parseLocalPorts([
        "@home " + b("/home/u"),
        '@l LISTEN 0 128 127.0.1.1:3000 0.0.0.0:* users:(("ssh",pid=300,fd=4))',
        '@l LISTEN 0 128 127.0.1.2:3000 0.0.0.0:* users:(("ssh",pid=301,fd=4))',
        '@l LISTEN 0 5 127.0.1.3:3000 0.0.0.0:* users:(("python3",pid=302,fd=3))',
        "@p 300 yes 1 1 " + b("ssh\n-N\n") + " " + b("/"),
        "@p 301 yes 1 2 " + b("ssh\n-N\n") + " " + b("/"),
        "@p 302 no 1 3 " + b("python3\n-m\nhttp.server\n") + " " + b("/home/u/Projects/site"),
    ].join("\n"));
    assert.strictEqual(r.entries.length, 1);
    assert.deepStrictEqual(Array.from(r.entries[0].hosts), ["127.0.1.3"]);
    assert.strictEqual(r.entries[0].pid, 302);
    // localhost does not reach 127.0.1.3: the browser goes to the address itself
    assert.strictEqual(L.browseHost(r.entries[0]), "127.0.1.3");
    assert.strictEqual(L.browseHost({ scope: "loopback", hosts: ["127.0.0.1", "::1"] }), "localhost");
    assert.strictEqual(L.browseHost({ scope: "loopback", hosts: ["::1"] }), "localhost");
    assert.strictEqual(L.browseHost({ scope: "loopback", hosts: ["fd00::1"] }), "[fd00::1]");
    assert.strictEqual(L.browseHost({ scope: "all", hosts: ["0.0.0.0"] }), "localhost");
});

console.log(`all ${n} tests passed`);

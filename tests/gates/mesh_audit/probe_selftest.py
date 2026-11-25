"""Red/green proof of tests/ga_tests/firewall/mesh_probe.sh and of FW-60/FW-61 in test.sh, live files."""
import http.server, os, re, socket, subprocess, sys, tempfile, threading
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
PROBE, SUITE = ROOT + "/tests/ga_tests/firewall/mesh_probe.sh", ROOT + "/tests/ga_tests/firewall/test.sh"
TOKEN = "probe-selftest-token"
W = tempfile.mkdtemp(); open(W + "/tok", "w").write(TOKEN + "\n")
ran = bad = 0
def check(n, c, why=""):
    global ran, bad
    ran += 1; bad += not c; print(("  ok    " if c else "  FAIL  ") + n + ("" if c else f" -- {why}"))
def web(fn):
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(s, *a): pass
        def do_GET(s): s.send_response(fn(s.path, s.headers)); s.send_header("Content-Length", "0"); s.end_headers()
    h = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=h.serve_forever, daemon=True).start(); return h.server_port
def ssh(banner):
    l = socket.socket(); l.bind(("127.0.0.1", 0)); l.listen(9)
    def go():
        while True: c, _ = l.accept(); c.send(banner); c.close()
    threading.Thread(target=go, daemon=True).start(); return l.getsockname()[1]
def closed():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p
def fm(dev=200, ctl=404):
    return web(lambda p, h: 401 if h.get("Authorization") != "Bearer " + TOKEN else dev if "/KIB-TEST/" in p else ctl)
def run(sshp, gm, ha, fmp, dev="KIB-TEST", tok=W + "/tok"):
    e = {**os.environ, "GA_P_SSH": str(sshp), "GA_P_GM": str(gm), "GA_P_HA": ha, "GA_FM_URL": f"http://127.0.0.1:{fmp}", "GA_FM_TOKEN_FILE": tok}
    r = subprocess.run(["sh", PROBE, "127.0.0.1"] + ([dev] if dev else []), env=e, capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr
S, G, H, X = ssh(b"SSH-2.0-x\r\n"), web(lambda p, h: 200 if p == "/livez" else 404), web(lambda p, h: 200 if p == "/auth/providers" else 404), closed()
for name, args, rc, red in (
    ("known-good", (S, G, f"{X} {H}", fm()), 0, None),
    ("ssh port closed", (X, G, str(H), fm()), 1, "FW-41a"),
    ("port open, not ssh", (ssh(b"HTTP"), G, str(H), fm()), 1, "FW-41a"),
    ("ga_manager port closed", (S, X, str(H), fm()), 1, "FW-41b"),
    ("ga_manager port open, app 503", (S, web(lambda p, h: 503), str(H), fm()), 1, "FW-41b"),
    ("no HA port answers", (S, G, f"{X} {X}", fm()), 1, "FW-41c"),
    ("HA port open, app 502", (S, G, str(web(lambda p, h: 502)), fm()), 1, "FW-41c"),
    ("fleet manager cannot reach the device", (S, G, str(H), fm(dev=502)), 1, "FW-43"),
    ("fleet manager answers 200 to anything", (S, G, str(H), fm(ctl=200)), 1, "FW-43"),
    ("no device id given", (S, G, str(H), fm(), ""), 2, None),
    ("no token file", (S, G, str(H), fm(), "KIB-TEST", W + "/none"), 2, None)):
    c, o = run(*args); fails = re.findall(r"FAIL  (FW-\w+)", o)
    check(f"probe: {name} -> rc {rc}", c == rc and fails == ([red] if red else []) and TOKEN not in o, (c, fails, o[-200:]))

# FW-60/61: the block is cut out of the live suite and run against recorded tables
t = open(SUITE).read(); m = re.search(r'^MA_TABLE=.*?^run_test "FW-61".*?$', t, re.S | re.M); assert m
GOOD = '''table inet ga_mesh_audit {
	set by_port {
		type inet_proto . inet_service
	}
	chain count_in {
		type filter hook prerouting priority mangle; policy accept;
		iifname "wt0" ct state new counter name "new_total"
	}
	chain count_routed {
		type filter hook forward priority filter - 10; policy accept;
		iifname "wt0" ct state new ct status ! dnat counter name "routed_total"
	}
}'''
def dev(table):
    os.makedirs(W + "/b", exist_ok=True); open(W + "/tbl", "w").write(table)
    open(W + "/b/nft", "w").write(f"#!/bin/sh\n[ -s {W}/tbl ] && cat {W}/tbl\n"); os.chmod(W + "/b/nft", 0o755)
    h = 'run_test() { if eval "$3" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fi; }\n'
    r = subprocess.run(["sh", "-c", h + m.group(0)], env={"PATH": W + "/b:" + os.environ["PATH"]}, capture_output=True, text=True)
    return dict(reversed(l.split()) for l in r.stdout.splitlines())
for name, tab, w60, w61 in (
    ("known-good", GOOD, "PASS", "PASS"), ("no table", "", "FAIL", "FAIL"),
    ("a drop rule", GOOD.replace('counter name "new_total"', 'counter name "new_total" drop'), "PASS", "FAIL"),
    ("a reject rule", GOOD.replace('counter name "routed_total"', "reject"), "PASS", "FAIL"),
    ("policy drop", GOOD.replace("mangle; policy accept", "mangle; policy drop"), "PASS", "FAIL"),
    ("an accept verdict", GOOD.replace('counter name "new_total"', "accept"), "PASS", "FAIL"),
    ("set missing", GOOD.replace("by_port", "other"), "FAIL", "PASS")):
    r = dev(tab); check(f"FW-60/61: {name} -> {w60}/{w61}", (r.get("FW-60"), r.get("FW-61")) == (w60, w61), r)
print(f"{ran} checks, {bad} failed"); sys.exit(1 if bad or ran < 18 else 0)

"""Real traffic through the LIVE ga-mesh-audit and the LIVE ga-firewall-gate.

Three namespaces: peer --wt0-- device --eth0-- lan. The same flows are run with and
without the audit table; every one must work in both, and the counts must be exact.
Mutants: a copy of the script that drops something must fail the BEHAVIOUR check, a
copy that miscounts must fail the COUNT check - the named check, not just any.
"""
import json, os, re, subprocess, sys, tempfile, time
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OV = ROOT + "/buildroot-external/rootfs-overlay"
AUDIT, GATE = OV + "/usr/libexec/ga-mesh-audit", OV + "/usr/libexec/ga-firewall-gate"
W = tempfile.mkdtemp(prefix="mesh-audit-")
TCP, UDP, N = [22222, 80, 8123, 8099, 8324, 1883], [5353], 3   # 8099 is redirected to 9099
ran = bad = 0

def sh(cmd, ns=None, ok=True, inp=None):
    c = (["ip", "netns", "exec", ns] if ns else []) + (cmd if isinstance(cmd, list) else ["sh", "-c", cmd])
    r = subprocess.run(c, capture_output=True, text=True, input=inp, timeout=60)
    if ok and r.returncode: raise SystemExit(f"FAIL setup: {cmd}: {r.stderr}")
    return r

def check(name, cond, why=""):
    global ran, bad
    ran += 1; bad += not cond
    print(("  ok    " if cond else "  FAIL  ") + name + ("" if cond else f" -- {why}"))

SERVER = r'''
import socket,selectors,sys
s=selectors.DefaultSelector()
for p in map(int,sys.argv[1].split(",")):
    l=socket.socket(); l.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); l.bind(("0.0.0.0",p)); l.listen(64); s.register(l,1,("l",p))
for p in map(int,filter(None,sys.argv[2].split(","))):
    u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.bind(("0.0.0.0",p)); s.register(u,1,("u",p))
print("up",flush=True)
while True:
    for k,_ in s.select():
        t,p=k.data
        if t=="l": c,_=k.fileobj.accept(); s.register(c,1,("c",p))
        elif t=="u": d,a=k.fileobj.recvfrom(99); k.fileobj.sendto(d,a)
        else:
            d=k.fileobj.recv(99)
            if d: k.fileobj.send(d)
            else: s.unregister(k.fileobj); k.fileobj.close()
'''
CLIENT = r'''
import socket,sys,json
out={}
for _ in range(int(sys.argv[1])):
    for spec in sys.argv[2:]:
        t,h,p=spec.split(":")
        s=socket.socket(socket.AF_INET,socket.SOCK_STREAM if t=="tcp" else socket.SOCK_DGRAM); s.settimeout(1.0)
        try:
            s.connect((h,int(p))); s.send(b"x"); r=s.recv(9)==b"x"
        except OSError: r=False
        s.close(); out[spec]=out.get(spec,True) and r
print(json.dumps(out))
'''
HOLD = r'''
import socket,sys
s=socket.create_connection((sys.argv[1],int(sys.argv[2])),3); s.settimeout(3); print("up",flush=True)
for l in sys.stdin:
    try: s.send(b"y"); ok=s.recv(9)==b"y"
    except OSError: ok=False
    print("alive" if ok else "dead",flush=True)
'''
def setup():
    sh("mount --make-rprivate / 2>/dev/null; mount -t tmpfs tmpfs /run")
    for n in ("dev", "peer", "lan"): sh(f"ip netns add {n}"); sh("ip link set lo up", n)
    sh("ip link add wt0 netns dev type veth peer name p0 netns peer")
    sh("ip link add eth0 netns dev type veth peer name l0 netns lan")
    sh("ip addr add 10.1.0.1/24 dev wt0; ip link set wt0 up; ip addr add 10.2.0.1/24 dev eth0; ip link set eth0 up; echo 1 > /proc/sys/net/ipv4/ip_forward", "dev")
    sh("ip addr add 10.1.0.2/24 dev p0; ip link set p0 up; ip route add default via 10.1.0.1", "peer")
    sh("ip addr add 10.2.0.2/24 dev l0; ip link set l0 up; ip route add default via 10.2.0.1", "lan")
    sh(["nft", "-f", "-"], "dev", inp="table ip nat {\n chain pre { type nat hook prerouting priority dstnat; tcp dport 8099 redirect to :9099; }\n}\n")
    P = []
    for ns, t, u in (("dev", ",".join(map(str, [p for p in TCP if p != 8099] + [9099])), "5353"), ("lan", "7000", "")):
        p = subprocess.Popen(["ip", "netns", "exec", ns, sys.executable, "-I", "-c", SERVER, t, u], stdout=subprocess.PIPE, text=True)
        assert p.stdout.readline().strip() == "up"; P.append(p)
    # the live firewall gate, paths redirected on a copy; the rewrite is asserted
    s = open(GATE).read()
    for a, b in ((r"^SHARE_DIR=.*$", f"SHARE_DIR={W}/none"), (r"^OFF_MARKER=.*$", f"OFF_MARKER={W}/off")):
        s, k = re.subn(a, b, s, flags=re.M); assert k == 1, a
    open(W + "/gate", "w").write(s)
    sh(f"GA_BOARD_CONF={W}/none sh {W}/gate", "dev")
    sh("nft list table inet ga_firewall", "dev")
    return P

SPECS = [f"tcp:10.1.0.1:{p}" for p in TCP] + [f"udp:10.1.0.1:{p}" for p in UDP] + ["tcp:10.2.0.2:7000"]
def flows(n=N):
    r = json.loads(sh([sys.executable, "-I", "-c", CLIENT, str(n)] + SPECS, "peer").stdout)
    r["ping"] = sh("ping -c1 -W1 10.1.0.1 >/dev/null", "peer", ok=False).returncode == 0
    return r
def counts():
    r = sh("nft -j list table inet ga_mesh_audit", "dev", ok=False)
    if r.returncode: return None
    c = {}
    for o in json.loads(r.stdout)["nftables"]:
        if "counter" in o: c[o["counter"]["name"]] = o["counter"]["packets"]
        if "set" in o:
            for e in o["set"].get("elem", []):
                e = e["elem"]; c["%s/%s" % tuple(e["val"]["concat"])] = e["counter"]["packets"]
    return c
WANT = {**{f"tcp/{p}": N for p in TCP}, "udp/5353": N, "tcp/7000": N, "routed_total": N,
        "new_total": N * len(SPECS) + 1}                                          # + 1 ping
def case(script):
    """-> (flows that failed, counts wrong, connection held across start died)"""
    sh(f"sh {AUDIT} stop", "dev")
    h = subprocess.Popen(["ip", "netns", "exec", "peer", sys.executable, "-I", "-c", HOLD, "10.1.0.1", "1883"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    assert h.stdout.readline().strip() == "up"
    rc = sh(f"sh {script} start", "dev", ok=False).returncode
    dead = [k for k, v in flows().items() if not v]
    c = counts()
    h.stdin.write("\n"); h.stdin.flush(); held = h.stdout.readline().strip() == "alive"; h.kill(); h.wait()
    fw = sh("nft list table inet ga_firewall", "dev", ok=False).returncode == 0
    sh(f"sh {AUDIT} stop", "dev")
    wrong = {} if c == WANT else {k: ((c or {}).get(k), WANT.get(k)) for k in set(c or {}) | set(WANT) if (c or {}).get(k) != WANT.get(k)}
    return dict(rc=rc, dead=dead, wrong=wrong, table=c is not None, held=held, fw=fw)

procs = setup()
try:
    base = flows(1)
    check("baseline without the audit table: every flow works", all(base.values()), base)
    r = case(AUDIT)
    check("with the audit table: every flow still works (tcp, udp, redirected, routed, ping)", not r["dead"], r["dead"])
    check("a connection opened before the start survives it", r["held"])
    check("counts are exact per port, redirected port under its original number", r["table"] and not r["wrong"], r["wrong"])
    check("the firewall table is untouched", r["fw"])
    # more ports than the set holds: counting stops growing, traffic does not stop
    sh(f"sh {AUDIT} start", "dev")
    many = [f"tcp:10.1.0.1:{p}" for p in range(20000, 20700)]
    sh([sys.executable, "-I", "-c", CLIENT, "1"] + many, "peer")
    full = len([k for k in counts() if k.startswith("tcp/")])
    check("set full after a 700-port scan: bounded at 512", full == 512, full)
    d = [k for k, v in flows(1).items() if not v]
    check("set full: every flow still works", not d, d)
    sh(f"sh {AUDIT} stop", "dev")
    check("stop removes the table", counts() is None)
    check("stop twice and start twice are harmless", sh(f"sh {AUDIT} stop && sh {AUDIT} start && sh {AUDIT} start", "dev", ok=False).returncode == 0 and counts() is not None)
    sh(f"sh {AUDIT} stop", "dev")

    src = open(AUDIT).read()
    body = re.sub(r"policy accept;|ct status & dnat == 0", "",   # the policy and a match, not verdicts
                   re.search(r"^rules\(\) \{(.*?)^\}", src, re.S | re.M).group(1))
    words = r"\b(drop|reject|queue|accept|jump|goto|return|dnat|snat|redirect|masquerade|notrack|set\s+\S+\s+set)\b"
    check("static: no verdict statement in the rules", not re.search(words, body), re.findall(words, body))
    check("static: the word check can go red", bool(re.search(words, body + "\n tcp dport 1 drop")))

    L1 = '    iifname "$IFACE" ct state new counter name new_total\n'
    ADD = re.search(r"^.*add @by_port.*\n", src, re.M).group(0)
    MUT = [  # name, old, new, which check must go red
        ("drop one tcp port", L1, L1 + '    iifname "$IFACE" tcp dport 8324 drop\n', "dead"),
        ("drop one udp port", L1, L1 + '    iifname "$IFACE" udp dport 5353 drop\n', "dead"),
        ("drop a redirected port", L1, L1 + '    iifname "$IFACE" tcp dport 8099 drop\n', "dead"),
        ("drop ping", L1, L1 + '    iifname "$IFACE" meta l4proto icmp drop\n', "dead"),
        ("drop everything new that is not ssh", L1, L1 + '    iifname "$IFACE" ct state new tcp dport != 22222 drop\n', "dead"),
        ("policy drop, prerouting", "hook prerouting priority -150; policy accept", "hook prerouting priority -150; policy drop", "dead"),
        ("policy drop, forward", "hook forward priority -10; policy accept", "hook forward priority -10; policy drop", "dead"),
        ("drop only routed traffic", "counter name routed_total", "counter name routed_total drop", "dead"),
        ("drop established packets", L1, L1 + '    iifname "$IFACE" ct state established drop\n', "held"),
        ("nothing counted per port", ADD, "", "wrong"),
        ("counted after the redirect", "priority -150", "priority -50", "wrong"),
        ("every packet counted, not every flow", ADD, ADD.replace("ct state new ", ""), "wrong"),
        ("other interface counted", "IFACE=wt0", "IFACE=eth0", "wrong"),
    ]
    for name, a, b, key in MUT:
        assert src.count(a) == 1, (name, src.count(a))
        open(W + "/mut", "w").write(src.replace(a, b))
        m = case(W + "/mut")
        red = not m["held"] if key == "held" else bool(m[key])
        extra = key == "wrong" and m["dead"]         # a counting mutant must not be caught by lost traffic
        check(f"MUST-FLAG {name} (red on {key})", m["table"] and red and not extra, m)
    open(W + "/mut", "w").write(src.replace("type filter hook prerouting", "type nonsense hook prerouting"))
    m = case(W + "/mut")
    check("rules the kernel or nft rejects: exit 0, no table, firewall and every flow intact",
          m["rc"] == 0 and not m["table"] and m["fw"] and not m["dead"] and m["held"], m)

    unit = OV + "/etc/systemd/system/ga-mesh-audit.service"
    want = OV + "/etc/systemd/system/multi-user.target.wants/ga-mesh-audit.service"
    check("unit enabled and runs the script", os.path.realpath(want) == os.path.realpath(unit) and "ExecStart=/usr/libexec/ga-mesh-audit start\n" in open(unit).read() and os.access(AUDIT, os.X_OK))
    fwunit = open(OV + "/etc/systemd/system/ga-firewall.service").read()
    check("the firewall unit does not depend on it", "mesh-audit" not in fwunit and "mesh-audit" not in open(GATE).read())
finally:
    for p in procs: p.kill()
print(f"{ran} checks, {bad} failed")
sys.exit(1 if bad or ran < 25 else 0)

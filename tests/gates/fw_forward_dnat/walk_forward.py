"""Walk a printed `nft list` forward chain for ONE new LAN connection that Docker has DNAT'd.
usage: walk_forward.py CHAINFILE IFACE ORIG_DPORT POST_DNAT_DPORT -> prints accept|drop
Recognised conditions only; a rule with any other condition (ct state established, oifname, ...) does not
match a NEW inbound connection and is skipped. Policy accept when nothing matches (as the kernel)."""
import re, sys, fnmatch
chain, iface, orig, post = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
def ports(txt):
    return {int(x) for x in re.findall(r'\d+', txt)}
verdict = 'accept'  # chain policy
for line in open(chain):
    l = line.strip()
    if not l or l.startswith(('chain ', 'type ', '}')):
        continue
    l = re.sub(r'counter packets \d+ bytes \d+', '', l)
    m = re.search(r'\b(accept|drop)\s*$', l)
    if not m:
        continue
    v, cond = m.group(1), l[:m.start()]
    ok = True
    mi = re.search(r'iifname (\{[^}]*\}|"[^"]*")', cond)
    if mi:
        names = re.findall(r'"([^"]*)"', mi.group(1))
        ok &= any(fnmatch.fnmatch(iface, n) for n in names)
        cond = cond.replace(mi.group(0), '')
    if re.search(r'oifname|ct state|iif ', cond):
        ok = False
    if 'ct status dnat' in cond:
        cond = cond.replace('ct status dnat', '')
    mo = re.search(r'ct original proto-dst (\{[^}]*\}|\d+)', cond)
    if mo:
        ok &= orig in ports(mo.group(1)); cond = cond.replace(mo.group(0), '')
    md = re.search(r'tcp dport (\{[^}]*\}|\d+)', cond)
    if md:
        ok &= post in ports(md.group(1)); cond = cond.replace(md.group(0), '')
    cond = cond.replace('meta l4proto tcp', '')
    if cond.strip():       # anything we do not model -> not a match for this packet class
        ok = False
    if ok:
        print(v); sys.exit(0)
print(verdict)

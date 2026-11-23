"""Fake Quectel BG96 AT port on a pty (test helper for lte_rat).
usage: python3 fake_bg96.py <cmdlog> <pathfile> [silent]
Writes the slave path to <pathfile>, logs every received command line to <cmdlog>,
answers queries like a BG96 (values below are made up, NOT the stock values)."""
import os, select, sys, time
cmdlog, pathfile = sys.argv[1], sys.argv[2]
silent = len(sys.argv) > 3
m, s = os.openpty()
open(pathfile, "w").write(os.ttyname(s))
REPLY = {
    'AT+QCFG="nwscanmode"': '+QCFG: "nwscanmode",0',
    'AT+QCFG="nwscanseq"': '+QCFG: "nwscanseq",020301',
    'AT+QCFG="iotopmode"': '+QCFG: "iotopmode",2',
    'AT+QCFG="band"': '+QCFG: "band",0xf,0x400a0e189f,0xa0e189f',
    'AT+QGMR': 'BG96MAR02A07M1G_01.200.01.200',
}
buf = b""; end = time.time() + 120
with open(cmdlog, "a") as log:
    while time.time() < end:
        r, _, _ = select.select([m], [], [], 0.5)
        if not r:
            continue
        buf += os.read(m, 1024)
        while b"\r" in buf:
            line, buf = buf.split(b"\r", 1)
            cmd = line.decode(errors="replace").strip()
            if not cmd:
                continue
            log.write(cmd + "\n"); log.flush()
            if silent:
                continue
            body = REPLY.get(cmd, "")
            os.write(m, ((body + "\r\n") if body else "").encode() + b"\r\nOK\r\n")

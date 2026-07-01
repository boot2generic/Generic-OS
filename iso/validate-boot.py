#!/usr/bin/env python3
"""Boot a Generic-OS ISO in QEMU and validate the *running* live desktop.

Screenshots the desktop (QMP screendump) and runs in-guest checks via the
qemu-guest-agent (conky/plasmashell running, theme applied, dotfiles present in
the live user's home, key apps installed) — proving things are actually wired
up at runtime, not just present on disk.

Outputs (per ISO, into --out): <name>.png screenshots + <name>.report.txt.
Needs: qemu-system-x86_64, KVM (falls back to slow TCG), and the ISO built with
qemu-guest-agent + live autologin. stdlib only.
"""
import argparse, base64, json, os, shutil, socket, subprocess, sys, tempfile, time

def log(m): print(m, flush=True)

class JsonSock:
    """Line-delimited JSON over a unix socket (QMP and QGA both speak this)."""
    def __init__(self, path): self.path, self.s, self.buf = path, None, b""
    def connect(self, timeout, recv_timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            try:
                s = socket.socket(socket.AF_UNIX); s.connect(self.path)
                s.settimeout(recv_timeout); self.s = s; return True
            except OSError:
                time.sleep(0.5)
        return False
    def _readline(self):
        while b"\n" not in self.buf:
            d = self.s.recv(65536)
            if not d: raise EOFError("socket closed")
            self.buf += d
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)
    def send(self, execute, arguments=None):
        o = {"execute": execute}
        if arguments: o["arguments"] = arguments
        self.s.sendall((json.dumps(o) + "\n").encode())
    def cmd(self, execute, arguments=None):
        self.send(execute, arguments)
        while True:                       # skip async events, return the reply
            m = self._readline()
            if "return" in m or "error" in m: return m

def qga_run(qga, cmd, timeout=120):
    """Run `sh -c cmd` in the guest; return (exitcode, stdout, stderr)."""
    r = qga.cmd("guest-exec", {"path": "/bin/sh", "arg": ["-c", cmd], "capture-output": True})
    if "error" in r: return (None, "", r["error"].get("desc", "guest-exec error"))
    pid = r["return"]["pid"]; end = time.time() + timeout
    while time.time() < end:
        st = qga.cmd("guest-exec-status", {"pid": pid}).get("return", {})
        if st.get("exited"):
            dec = lambda k: base64.b64decode(st.get(k, "")).decode("utf-8", "replace")
            return (st.get("exitcode", 0), dec("out-data"), dec("err-data"))
        time.sleep(0.5)
    return (None, "", "(timeout)")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("iso")
    ap.add_argument("--out", default="out/boot-validate")
    ap.add_argument("--boot-timeout", type=int, default=300, help="s to wait for guest agent")
    ap.add_argument("--desktop-timeout", type=int, default=240, help="s to wait for plasmashell")
    ap.add_argument("--mem", default="4096"); ap.add_argument("--cpus", default="4")
    ap.add_argument("--keep", action="store_true", help="leave the VM running")
    a = ap.parse_args()

    name = os.path.splitext(os.path.basename(a.iso))[0]
    parts = name.split("-"); edition = parts[1] if len(parts) > 1 else "?"; variant = parts[2] if len(parts) > 2 else "?"
    os.makedirs(a.out, exist_ok=True)
    report_path = os.path.join(a.out, f"{name}.report.txt")
    rep = open(report_path, "w"); PASS = FAIL = WARN = 0
    def emit(tag, msg):
        nonlocal PASS, FAIL, WARN
        PASS += tag == "PASS"; FAIL += tag == "FAIL"; WARN += tag == "WARN"
        line = f"  [{tag}] {msg}"; log(line); rep.write(line + "\n"); rep.flush()
    rep.write(f"Boot validation: {name} (edition={edition} variant={variant})  {time.ctime()}\n\n")
    log(f"\n== boot-validating {name} (edition={edition} variant={variant}) ==")

    tmp = tempfile.mkdtemp(prefix="genos-boot-"); qmp_s = f"{tmp}/qmp"; qga_s = f"{tmp}/qga"
    accel = "kvm" if os.path.exists("/dev/kvm") else "tcg"

    # The ISO's boot menu has `timeout 0` (waits forever for a keypress), so we
    # boot the kernel+initrd DIRECTLY (extracted from the ISO) — deterministic,
    # no menu. The ISO is still attached as a cdrom so live-boot finds the
    # squashfs medium; console=ttyS0 mirrors kernel logs to the serial file.
    log("  extracting kernel + initrd from ISO…")
    if subprocess.run(["xorriso", "-osirrox", "on", "-indev", a.iso,
                       "-extract", "/live/vmlinuz", f"{tmp}/vmlinuz",
                       "-extract", "/live/initrd.img", f"{tmp}/initrd.img"],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        emit("FAIL", "could not extract /live/vmlinuz + /live/initrd.img (need xorriso; valid ISO?)"); return
    qemu = [
        "qemu-system-x86_64", "-machine", f"accel={accel}", "-m", a.mem, "-smp", a.cpus,
        "-kernel", f"{tmp}/vmlinuz", "-initrd", f"{tmp}/initrd.img",
        "-append", "boot=live components quiet console=ttyS0",
        "-cdrom", a.iso, "-vga", "virtio", "-display", "none",
        "-qmp", f"unix:{qmp_s},server=on,wait=off",
        "-chardev", f"socket,path={qga_s},server=on,wait=off,id=qga0",
        "-device", "virtio-serial", "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0",
        "-serial", f"file:{a.out}/{name}.serial.log",
    ]
    if accel == "tcg": emit("WARN", "no /dev/kvm — using slow TCG emulation")
    log(f"  launching QEMU ({accel})…")
    vm = subprocess.Popen(qemu, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    ok = False
    try:
        qmp = JsonSock(qmp_s)
        if not qmp.connect(30): emit("FAIL", "QMP socket never came up (QEMU failed to start)"); return
        qmp._readline(); qmp.cmd("qmp_capabilities")            # greeting, then negotiate

        # Wait for the guest agent = the guest booted far enough to talk back.
        qga = JsonSock(qga_s); qga.connect(10, recv_timeout=8)   # short: poll must stay responsive
        log(f"  waiting up to {a.boot_timeout}s for the guest agent…")
        end = time.time() + a.boot_timeout; up = False
        while time.time() < end:
            try:
                if "return" in qga.cmd("guest-ping"): up = True; break
            except (OSError, EOFError): qga = JsonSock(qga_s); qga.connect(5, recv_timeout=8)
            time.sleep(3)
        if not up:
            emit("FAIL", "guest agent never responded — VM didn't boot or agent absent (rebuild with qemu-guest-agent)")
            qmp.cmd("screendump", {"filename": os.path.abspath(f"{a.out}/{name}.boot.png"), "format": "png"})
            return
        emit("PASS", "guest booted (agent responding)")
        qga.s.settimeout(45)   # roomier now that the agent is live (guest-exec replies)

        # Wait for the Plasma desktop (autologin), then let it settle + conky autostart.
        log(f"  waiting up to {a.desktop_timeout}s for the Plasma desktop…")
        end = time.time() + a.desktop_timeout; desk = False
        while time.time() < end:
            rc, out, _ = qga_run(qga, "pgrep -x plasmashell || pgrep -x plasmashell.bin")
            if out.strip(): desk = True; break
            time.sleep(4)
        if desk: emit("PASS", "Plasma desktop is running (plasmashell)")
        else:    emit("WARN", "plasmashell not detected (autologin/session issue?) — still capturing what's on screen")
        time.sleep(20)   # let the panel/conky/theme settle before the screenshot

        # --- screenshots ---
        shot = os.path.abspath(f"{a.out}/{name}.png")
        r = qmp.cmd("screendump", {"filename": shot, "format": "png"})
        if "error" in r:                                   # older QEMU: PPM only
            shot = shot[:-4] + ".ppm"; qmp.cmd("screendump", {"filename": shot})
        emit("PASS" if os.path.exists(shot) and os.path.getsize(shot) else "FAIL", f"screenshot saved: {shot}")

        # --- in-guest checks ---
        home = (qga_run(qga, "getent passwd user | cut -d: -f6")[1].strip()
                or qga_run(qga, "ls -d /home/* 2>/dev/null | head -1")[1].strip() or "/home/user")
        def has_proc(p): return bool(qga_run(qga, f"pgrep -x {p}")[1].strip())
        def check(cond, okmsg, badmsg, warn=False):
            emit("PASS" if cond else ("WARN" if warn else "FAIL"), okmsg if cond else badmsg)

        rep.write(f"\n-- live user home: {home} --\n")
        check(has_proc("conky"), "conky is running (system monitor overlay wired)",
              "conky NOT running (autostart/apply-theme?)")
        check(bool(qga_run(qga, f"test -s {home}/.zshrc && echo y")[1].strip()),
              "dotfiles deployed: ~/.zshrc in live user home",
              "~/.zshrc missing from live user home (skel not applied)")
        check(bool(qga_run(qga, f"test -f {home}/.config/kdeglobals && echo y")[1].strip()),
              "Plasma theme config in home (~/.config/kdeglobals)",
              "~/.config/kdeglobals missing")
        cs = qga_run(qga, f"grep -i colorscheme {home}/.config/kdeglobals 2>/dev/null")[1].strip()
        check("cyberpunk" in cs.lower(), f"cyberpunk color scheme applied ({cs or 'n/a'})",
              f"cyberpunk color scheme not found in kdeglobals ({cs or 'n/a'})", warn=True)
        check(bool(qga_run(qga, f"ls {home}/.config/autostart/conky.desktop 2>/dev/null")[1].strip()),
              "autostart entry present: conky.desktop",
              "autostart/conky.desktop missing in home")

        # apps per edition (which/pgrep) — best-effort where the build is best-effort
        def app(bin_, required=True):
            ok_ = bool(qga_run(qga, f"command -v {bin_}")[1].strip())
            emit("PASS" if ok_ else ("FAIL" if required else "WARN"),
                 f"app available: {bin_}" if ok_ else f"app missing: {bin_}")
        for b in ("plasmashell", "konsole", "alacritty", "nvim", "tmux", "zsh", "calamares"): app(b)
        if edition in ("security", "everything"):
            app("nmap"); app("wireshark")
        if edition == "security": app("msfconsole", required=False)
        if edition in ("gaming", "everything"):
            app("steam", required=False); app("mangohud")
        if variant == "nvidia": app("nvidia-smi", required=False)

        # capture a few raw facts for the report
        for label, cmd in (("uptime", "uptime"), ("system state", "systemctl is-system-running"),
                           ("sessions", "loginctl list-sessions --no-legend 2>/dev/null"),
                           ("autostart dir", f"ls -1 {home}/.config/autostart 2>/dev/null")):
            rep.write(f"\n-- {label} --\n{qga_run(qga, cmd)[1]}\n")

        ok = FAIL == 0
        # graceful shutdown
        if not a.keep:
            qga_run(qga, "systemctl poweroff 2>/dev/null || poweroff -f", timeout=5)
            try: qmp.cmd("quit")
            except Exception: pass
    finally:
        if not a.keep:
            try: vm.wait(timeout=30)
            except Exception: vm.kill()
        rep.write(f"\nsummary: {PASS} passed, {WARN} warnings, {FAIL} failed\n"); rep.close()
        shutil.rmtree(tmp, ignore_errors=True)
        log(f"  report: {report_path}")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()

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
    """Run `sh -c cmd` in the guest; return (exitcode, stdout, stderr).

    Never raises: the guest agent can drop mid-check (desktop settle, reboot),
    which used to crash the whole run. On any agent error we return a null
    result so the individual check just fails/warns instead.
    """
    try:
        r = qga.cmd("guest-exec", {"path": "/bin/sh", "arg": ["-c", cmd], "capture-output": True})
    except (OSError, EOFError, AttributeError) as e:
        return (None, "", f"(agent unavailable: {e})")
    if "error" in r: return (None, "", r["error"].get("desc", "guest-exec error"))
    pid = r["return"]["pid"]; end = time.time() + timeout
    while time.time() < end:
        try:
            st = qga.cmd("guest-exec-status", {"pid": pid}).get("return", {})
        except (OSError, EOFError, AttributeError) as e:
            return (None, "", f"(agent dropped: {e})")
        if st.get("exited"):
            dec = lambda k: base64.b64decode(st.get(k, "")).decode("utf-8", "replace")
            # No exitcode key => the process was killed by a signal; report a
            # non-zero code so a signal-kill isn't mistaken for success.
            return (st.get("exitcode", 1), dec("out-data"), dec("err-data"))
        time.sleep(0.5)
    return (None, "", "(timeout)")

def main():
    """Returns the process exit code (0 = all checks passed)."""
    ap = argparse.ArgumentParser()
    ap.add_argument("iso")
    ap.add_argument("--out", default="out/boot-validate")
    ap.add_argument("--boot-timeout", type=int, default=300, help="s to wait for guest agent")
    ap.add_argument("--desktop-timeout", type=int, default=240, help="s to wait for plasmashell")
    ap.add_argument("--mem", default="4096"); ap.add_argument("--cpus", default="4")
    ap.add_argument("--keep", action="store_true", help="leave the VM running")
    ap.add_argument("--firmware", choices=["bios", "uefi"],
                    help="boot through real firmware + bootloader (isolinux/grub-efi, "
                         "relies on the 5s menu auto-boot) instead of direct kernel boot; "
                         "uefi needs OVMF. Serial log stays empty (no console= on cmdline).")
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

    # Two boot modes:
    #   default — boot the kernel+initrd extracted from the ISO directly:
    #     deterministic and lets us add console=ttyS0 for the serial log.
    #   --firmware bios|uefi — boot the ISO through real firmware + bootloader
    #     (exercises isolinux / grub-efi and the 5s menu auto-boot), closest
    #     to real hardware.
    def bail(msg):                      # FAIL before the VM/try-finally exists
        emit("FAIL", msg)
        rep.write(f"\nsummary: {PASS} passed, {WARN} warnings, {FAIL} failed\n"); rep.close()
        shutil.rmtree(tmp, ignore_errors=True); return 1
    if a.firmware:
        boot_args = ["-boot", "d"]
        if a.firmware == "uefi":
            ovmf = "/usr/share/OVMF/OVMF_CODE.fd"
            if not os.path.exists(ovmf):
                return bail(f"--firmware uefi needs OVMF ({ovmf}) — apt install ovmf")
            boot_args += ["-bios", ovmf]
        log(f"  firmware boot ({a.firmware}) — relying on the boot menu's 5s auto-boot…")
    else:
        log("  extracting kernel + initrd from ISO…")
        try:
            extracted = subprocess.run(["xorriso", "-osirrox", "on", "-indev", a.iso,
                                        "-extract", "/live/vmlinuz", f"{tmp}/vmlinuz",
                                        "-extract", "/live/initrd.img", f"{tmp}/initrd.img"],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        except FileNotFoundError:
            extracted = False
        if not extracted:
            return bail("could not extract /live/vmlinuz + /live/initrd.img (need xorriso; valid ISO?)")
        boot_args = ["-kernel", f"{tmp}/vmlinuz", "-initrd", f"{tmp}/initrd.img",
                     "-append", "boot=live components quiet console=ttyS0"]
    qemu = [
        "qemu-system-x86_64", "-machine", f"accel={accel}", "-m", a.mem, "-smp", a.cpus,
        *boot_args,
        "-cdrom", a.iso, "-vga", "virtio", "-display", "none",
        "-qmp", f"unix:{qmp_s},server=on,wait=off",
        "-chardev", f"socket,path={qga_s},server=on,wait=off,id=qga0",
        "-device", "virtio-serial", "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0",
        "-serial", f"file:{a.out}/{name}.serial.log",
    ]
    if accel == "tcg": emit("WARN", "no /dev/kvm — using slow TCG emulation")
    log(f"  launching QEMU ({accel})…")
    # stderr to a file, not a pipe: nothing ever drains a pipe, so a chatty
    # QEMU would fill it and deadlock — and the file doubles as diagnostics
    # when QEMU dies before QMP comes up.
    qemu_log = os.path.join(a.out, f"{name}.qemu.log")
    qemu_err = open(qemu_log, "w")
    vm = subprocess.Popen(qemu, stdout=subprocess.DEVNULL, stderr=qemu_err)

    ok = False
    try:
        qmp = JsonSock(qmp_s)
        if not qmp.connect(30):
            emit("FAIL", f"QMP socket never came up (QEMU failed to start — see {qemu_log})"); return 1
        qmp._readline(); qmp.cmd("qmp_capabilities")            # greeting, then negotiate

        # Wait for the guest agent = the guest booted far enough to talk back.
        qga = JsonSock(qga_s); qga.connect(10, recv_timeout=8)   # short: poll must stay responsive
        log(f"  waiting up to {a.boot_timeout}s for the guest agent…")
        end = time.time() + a.boot_timeout; up = False
        while time.time() < end:
            try:
                if "return" in qga.cmd("guest-ping"): up = True; break
            except (OSError, EOFError, AttributeError): qga = JsonSock(qga_s); qga.connect(5, recv_timeout=8)
            time.sleep(3)
        if not up:
            emit("FAIL", "guest agent never responded — VM didn't boot or agent absent (rebuild with qemu-guest-agent)")
            try: qmp.cmd("screendump", {"filename": os.path.abspath(f"{a.out}/{name}.boot.png"), "format": "png"})
            except Exception: pass          # QMP may be dead too; the FAIL above is the result
            return 1
        emit("PASS", "guest booted (agent responding)")
        qga.s.settimeout(45)   # roomier now that the agent is live (guest-exec replies)

        # Wait for the Plasma desktop (autologin), then let it settle + conky autostart.
        log(f"  waiting up to {a.desktop_timeout}s for the Plasma desktop…")
        end = time.time() + a.desktop_timeout; desk = False
        while time.time() < end:
            rc, out, _ = qga_run(qga, "pgrep -x plasmashell")
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
        check(not has_proc("plasma-welcome"), "Welcome Center suppressed (kded module disabled)",
              "plasma-welcome is running — kded6rc suppression not effective")
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
        check(bool(qga_run(qga, "command -v conky")[1].strip()),
              "conky binary installed", "conky binary NOT installed (add conky-all)")
        check(bool(qga_run(qga, f"test -s {home}/.config/wallpaper/wallpaper.png && echo y")[1].strip()),
              "wallpaper image present (~/.config/wallpaper/wallpaper.png)",
              "wallpaper.png missing/empty in home (generator/download failed)")

        # apps per edition. Use a full PATH so /usr/games binaries (e.g. steam)
        # aren't false-negatives against the guest agent's minimal PATH.
        FULLPATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games"
        def app(bin_, required=True):
            ok_ = bool(qga_run(qga, f"PATH={FULLPATH} command -v {bin_}")[1].strip())
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
        try: qemu_err.close()
        except Exception: pass
        rep.write(f"\nsummary: {PASS} passed, {WARN} warnings, {FAIL} failed\n"); rep.close()
        if a.keep: log(f"  --keep: VM left running (QMP {qmp_s}, QGA {qga_s})")
        else:      shutil.rmtree(tmp, ignore_errors=True)
        log(f"  report: {report_path}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())

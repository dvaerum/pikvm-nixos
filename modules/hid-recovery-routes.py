    def do_POST(self):
        if self.path.rstrip("/") != "/hid-recovery":
            return self.reply(404, False, "not found")
        if not self._authorized():
            return self.reply(401, False, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return self.reply(400, False, "invalid JSON body")
        action = payload.get("action", "")
        if action not in ACTIONS:
            return self.reply(400, False, "unknown action")
        unit = "pikvm-hid-recover@%s.service" % action
        result = subprocess.run(["systemctl", "start", unit])
        if result.returncode == 0:
            return self.reply(200, True, "%s triggered" % action)
        return self.reply(502, False, "%s failed (rc=%d)" % (action, result.returncode))

    def do_GET(self):
        path = self.path.rstrip("/")
        if path == "/hid-recovery/udc-state":
            return self._udc_state()
        if path == "/hid-recovery/latch-status":
            return self._latch_status()
        return self.reply(404, False, "not found")

    def _udc_state(self):
        # Read-only GROUND-TRUTH UDC state for the MCP health_check: the kvmd
        # HID online flags can lie, but /sys/class/udc/<udc>/state is
        # authoritative. Pure read of a world-readable (0444) sysfs node — no
        # root, no polkit, no systemctl (never touches the privileged units).
        if not self._authorized():
            return self.reply(401, False, "unauthorized")
        try:
            udcs = sorted(os.listdir(UDC_ROOT))
        except FileNotFoundError:
            udcs = []
        if not udcs:
            # No gadget bound (UDC unregistered) — endpoint is healthy, but
            # HID is down; the null/"absent" pair is that ground-truth signal.
            return self._send_json(200, {"udc": None, "state": "absent", "online": False})
        udc = udcs[0]
        try:
            with open(os.path.join(UDC_ROOT, udc, "state")) as fh:
                state = fh.read().strip()
        except OSError as exc:
            return self.reply(500, False, "cannot read UDC state: %s" % type(exc).__name__)
        # `online` is a derived ground-truth HID-live signal for the MCP
        # health_check (state == "configured"); the raw `state` string rides
        # along for diagnostics ("not attached" vs "addressed" vs …).
        return self._send_json(200, {"udc": udc, "state": state, "online": state == "configured"})

    def _latch_status(self):
        # Serve the HID-latch monitor's latest classification verbatim (it
        # writes LATCH_STATUS_PATH atomically each sample). Pure file read — no
        # root/polkit/systemctl. Absent file = the monitor is disabled or has
        # not written its first sample yet; that is `available:false`, NOT an
        # error. `lastSampleAt` in the payload is the monitor's on-box dead-man
        # (a stale value ⇒ the monitor hung; a missing file ⇒ it is not up).
        if not self._authorized():
            return self.reply(401, False, "unauthorized")
        try:
            with open(LATCH_STATUS_PATH) as fh:
                status = json.loads(fh.read())
        except FileNotFoundError:
            return self._send_json(200, {"ok": True, "available": False,
                                         "message": "hid-latch monitor status not available"})
        except (OSError, ValueError) as exc:
            return self.reply(500, False, "cannot read latch status: %s" % type(exc).__name__)
        status.setdefault("available", True)
        return self._send_json(200, status)

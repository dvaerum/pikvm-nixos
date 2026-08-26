    def do_GET(self):
        if self.path.rstrip("/") != "/hidmode":
            return self.reply(404, False, "not found")
        if not self._authorized():
            return self.reply(401, False, "unauthorized")
        requested = requested_mode()
        observed = observed_mode()
        # `mode` is the ASSEMBLED gadget (the ground truth the MCP follows),
        # NOT the config: null while mid-reassembly/unrecognised so the MCP
        # fail-closes on its settling gate instead of driving the wrong mode.
        # `requested` (the boot-authoritative yaml = next-boot mode) + `settled`
        # ride along: requested != observed after settling = the box runs one
        # mode now but is primed to boot into the other (a drift signal nothing
        # detected before — see #53/#44).
        return self._send_json(200, {
            "ok": True,
            "mode": observed,
            "requested": requested,
            "observed": observed,
            "settled": observed is not None,
        })

    def do_POST(self):
        if self.path.rstrip("/") != "/hidmode":
            return self.reply(404, False, "not found")
        if not self._authorized():
            return self.reply(401, False, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return self.reply(400, False, "invalid JSON body")
        mode = payload.get("mode", "")
        if mode not in MODES:
            return self.reply(400, False, "unknown mode (want desktop|ipad)")
        # Skip the switch only if the ASSEMBLED gadget is already this mode —
        # comparing against observed (not the requested config) so a
        # config/gadget drift (a prior failed switch) still triggers a
        # corrective reassembly instead of being no-op'd away.
        if mode == observed_mode():
            return self._send_json(200, {"ok": True, "mode": mode, "message": "already in %s (gadget confirms)" % mode})
        unit = "pikvm-hidmode@%s.service" % mode
        # --no-block: non-locking. The switch proceeds async (the gadget
        # re-assembles, USB re-enumerates, kvmd restarts). The client polls
        # GET /hidmode for the new mode rather than us holding the request.
        result = subprocess.run(["systemctl", "start", "--no-block", unit])
        if result.returncode == 0:
            return self._send_json(200, {
                "ok": True, "mode": mode,
                "message": "mode switching to %s; USB re-enumerates and the active session drops (~5s)" % mode,
            })
        return self.reply(502, False, "switch to %s failed (rc=%d)" % (mode, result.returncode))

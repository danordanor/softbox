#!/usr/bin/env python3
"""lightd: a small local bridge for the Elgato Key Light Air MK.2.

The MK.2 no longer speaks the old open HTTP API. It only accepts a mutually
authenticated TLS WebSocket that carries JSON-RPC messages. This service keeps
ONE connection open to the light (the firmware dislikes many connections in a
row) and exposes a simple local API plus a control panel:

  http://127.0.0.1:9124            control panel
  GET  /api/state                  current state, moments, recent activity
  POST /api/set     {on, brightness, kelvin}
  POST /api/action  {type: set|flash|pulse, ...}
  POST /api/event/<id>             run a moment (used by hooks and Shortcuts)
  POST /api/config  {daylight, events: {id: {enabled}}}

Every POST needs the header "X-Lightd: 1" so other web pages can't poke it.
Only the Python standard library is used.
"""
import base64
import collections
import copy
import json
import os
import socket
import ssl
import struct
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser(os.environ.get("LIGHTD_HOME", "~/.softbox"))
HERE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(HOME, "config.json")
HTTP_PORT = int(os.environ.get("LIGHTD_PORT", "9124"))
# the panel normally opens only inside the menu-bar app; LIGHTD_WEB=1 also serves it to browsers
WEB = os.environ.get("LIGHTD_WEB", "") == "1"

DEFAULT_CFG = {
    "hosts": [],          # empty: found on the network with Bonjour (or set your light's address)
    "port": 9123,
    "daylight": False,
    "events": {
        "claude-waiting": {
            "kind": "signal", "enabled": True, "label": "Claude needs you",
            "effect": "breath",
        },
        "claude-done": {
            "kind": "signal", "enabled": False, "label": "Claude finished",   # every reply: too often to be on by default
            "effect": "breath",
        },
        "focus": {
            "kind": "scene", "enabled": True, "label": "Focus",
            "action": {"type": "set", "on": 1, "kelvin": 6200, "brightness": 78},
        },
        "meeting": {
            "kind": "scene", "enabled": True, "label": "Meeting",
            "action": {"type": "set", "on": 1, "kelvin": 4300, "brightness": 28},
        },
        "evening": {
            "kind": "scene", "enabled": True, "label": "Evening",
            "action": {"type": "set", "on": 1, "kelvin": 3100, "brightness": 12},
        },
        "off": {
            "kind": "scene", "enabled": True, "label": "Off",
            "action": {"type": "set", "on": 0},
        },
    },
}

# The effect: one gentle flicker. The light rises 10% (of what the power allows) and
# settles back, three times in two seconds. Brightness only, never the warmth.
EFFECTS = {
    "breath": {"label": "Breath", "desc": "Three soft flickers, 10% up and back",
               "action": {"type": "flicker", "beats": 3, "glide": 0.9, "delta": 10}},
}
EFFECT_ORDER = ["breath"]


def effect_action(eid):
    return copy.deepcopy(EFFECTS.get(eid, EFFECTS["breath"])["action"])


# Kelvin targets through the day for the daylight rhythm (hour, kelvin).
DAYLIGHT = [(0, 2900), (6, 3800), (9, 5600), (13, 5600), (17, 4600), (20, 3400), (23, 2900), (24, 2900)]


def log(*a):
    print(datetime.now().strftime("%H:%M:%S"), *a, flush=True)


def k2m(k):
    """Kelvin to the light's mired-like unit (143 = 7000K, 344 = 2900K)."""
    return max(143, min(344, round(1_000_000 / max(1, int(k)))))


def m2k(m):
    return round(1_000_000 / m) if m else 0


# ---------------------------------------------------------------- config
def load_cfg():
    # Effect behaviour (actions, labels, hints) is defined by the app, so we
    # always take it from DEFAULT_CFG. Only the user's own choices are read
    # back from disk: which automations are on, the daylight toggle, and the
    # light's address. This way shipped changes to an effect take hold even
    # for someone who installed an earlier version.
    cfg = copy.deepcopy(DEFAULT_CFG)
    try:
        with open(CFG_PATH) as f:
            saved = json.load(f)
        for k in ("hosts", "port", "daylight"):
            if k in saved:
                cfg[k] = saved[k]
        for eid, ev in (saved.get("events") or {}).items():
            if eid in cfg["events"] and isinstance(ev, dict):
                if "enabled" in ev:
                    cfg["events"][eid]["enabled"] = bool(ev["enabled"])
                if ev.get("effect") in EFFECTS and "effect" in cfg["events"][eid]:
                    cfg["events"][eid]["effect"] = ev["effect"]
                _apply_scene(cfg["events"][eid], (ev.get("action") or {}))
    except FileNotFoundError:
        pass
    except Exception as e:  # a broken file should never stop the service
        log("config ignored:", e)
    return cfg


def _apply_scene(target, act):
    """Copy a moved preset's warmth/brightness onto a scene (only lit scenes move)."""
    if target.get("kind") != "scene" or target.get("action", {}).get("on") != 1:
        return
    k, b = act.get("kelvin"), act.get("brightness")
    if isinstance(k, int) and isinstance(b, int):
        target["action"]["kelvin"] = max(2900, min(7000, k))
        target["action"]["brightness"] = max(1, min(100, b))


def save_cfg(cfg):
    os.makedirs(HOME, exist_ok=True)
    tmp = CFG_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, CFG_PATH)


# ---------------------------------------------------------------- light
class LightError(Exception):
    pass


class RpcError(LightError):
    """The light answered, but refused the request. The connection is fine."""


class Light:
    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.RLock()
        self.effect_lock = threading.Lock()
        self.s = None
        self.buf = b""
        self.i = 0
        self.last_send = 0.0
        self.connected = False
        self.last_ok = 0.0
        self.last_manual = 0.0
        self.host = None
        self.state = {"on": 0, "brightness": 20, "temperature": 344}
        self.activity = collections.deque(maxlen=12)
        self.info = {}
        self.hw_fade = False
        self.info_at = 0.0

    # -- connection ------------------------------------------------------
    def _ctx(self):
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        c.check_hostname = False
        c.verify_mode = ssl.CERT_NONE
        c.load_cert_chain(os.path.join(HOME, "client-chain.crt"), os.path.join(HOME, "client.key"))
        return c

    def _hosts(self):
        """Saved addresses first; if none (or none answer), look for the light with Bonjour."""
        if self.cfg.get("hosts"):
            return list(self.cfg["hosts"])
        found = discover_lights()
        if found:
            log("found the light at " + ", ".join(found))
            self.cfg["hosts"] = found
        return found

    def _open(self):
        last = None
        hosts = self._hosts()
        if not hosts:
            raise LightError("no light found on the network yet")
        for host in hosts:
            try:
                raw = socket.create_connection((host, self.cfg["port"]), timeout=4)
                s = self._ctx().wrap_socket(raw)
                key = base64.b64encode(os.urandom(16)).decode()
                s.sendall((
                    f"GET / HTTP/1.1\r\nHost: {host}:{self.cfg['port']}\r\n"
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                    f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
                ).encode())
                r = b""
                while b"\r\n\r\n" not in r:
                    x = s.recv(1024)
                    if not x:
                        break
                    r += x
                head, _, rest = r.partition(b"\r\n\r\n")
                if b" 101" not in head.split(b"\r\n")[0]:
                    s.close()
                    raise LightError("handshake refused by " + host)
                self.s, self.buf, self.host = s, rest, host
                if not self.connected:
                    log("connected to", host)
                self.connected = True
                return
            except (OSError, LightError) as e:
                last = e
        raise LightError(f"light unreachable ({last})")

    def _close(self):
        if self.s:
            try:
                self.s.close()
            except OSError:
                pass
        self.s, self.buf = None, b""
        if self.connected:
            log("disconnected")
        self.connected = False

    # -- websocket framing ----------------------------------------------
    def _send_frame(self, op, data):
        mask = os.urandom(4)
        n = len(data)
        head = bytearray([0x80 | op])
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head.append(0x80 | 126)
            head += struct.pack(">H", n)
        else:
            head.append(0x80 | 127)
            head += struct.pack(">Q", n)
        self.s.sendall(bytes(head) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _parse(self):
        b = self.buf
        if len(b) < 2:
            return None
        op, masked, n, i = b[0] & 0x0F, b[1] & 0x80, b[1] & 0x7F, 2
        if n == 126:
            if len(b) < 4:
                return None
            n, i = struct.unpack(">H", b[2:4])[0], 4
        elif n == 127:
            if len(b) < 10:
                return None
            n, i = struct.unpack(">Q", b[2:10])[0], 10
        mask = b""
        if masked:
            if len(b) < i + 4:
                return None
            mask, i = b[i:i + 4], i + 4
        if len(b) < i + n:
            return None
        payload = b[i:i + n]
        if mask:
            payload = bytes(x ^ mask[j % 4] for j, x in enumerate(payload))
        self.buf = b[i + n:]
        return op, payload

    def _next_frame(self, deadline):
        while True:
            f = self._parse()
            if f:
                return f
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            self.s.settimeout(remaining)
            try:
                x = self.s.recv(4096)
            except socket.timeout:
                return None
            if not x:
                raise LightError("connection closed by light")
            self.buf += x

    def _handle(self, frame):
        op, payload = frame
        if op == 0x9:  # ping
            self._send_frame(0xA, payload)
            return None
        if op == 0x8:
            raise LightError("light closed the channel")
        if op != 0x1:
            return None
        try:
            j = json.loads(payload.decode("utf-8", "replace"))
        except ValueError:
            return None
        if j.get("method") == "notification.elgato.accessory-info" and isinstance(j.get("params"), dict):
            self.info["accessory"] = j["params"]
        if j.get("method") == "notification.elgato.lights":
            try:
                self.state.update(j["params"]["lights"][0])
            except (KeyError, IndexError, TypeError):
                pass
        return j

    # -- rpc ------------------------------------------------------------
    def call(self, method, params=None, timeout=3.0):
        with self.lock:
            for attempt in (0, 1):
                try:
                    if not self.s:
                        self._open()
                    gap = time.time() - self.last_send
                    if gap < 0.045:
                        time.sleep(0.045 - gap)
                    self.i += 1
                    rid = str(self.i)  # must be a string: a numeric id reboots the light
                    msg = {"jsonrpc": "2.0", "id": rid, "method": method}
                    if params is not None:
                        msg["params"] = params
                    self._send_frame(0x1, json.dumps(msg).encode())
                    self.last_send = time.time()
                    deadline = time.time() + timeout
                    while True:
                        f = self._next_frame(deadline)
                        if f is None:
                            raise LightError("no reply to " + method)
                        j = self._handle(f)
                        if j and str(j.get("id")) == rid:
                            self.last_ok = time.time()
                            res = j.get("result")
                            if isinstance(res, dict) and res.get("lights"):
                                self.state.update(res["lights"][0])
                            if "error" in j:
                                raise RpcError(str(j["error"]))
                            return j
                except RpcError:
                    raise                      # don't drop a healthy connection over one refusal
                except (OSError, LightError) as e:
                    self._close()
                    if attempt:
                        raise LightError(str(e))
                    time.sleep(0.4)

    def refresh(self):
        self.call("get.elgato.lights", {})
        return self.state

    def power(self):
        acc = self.info.get("accessory") or {}
        p = acc.get("power-info") or {}
        pdo = (p.get("source") or {}).get("pdo") or {}
        mv, ma = pdo.get("voltage"), pdo.get("current")
        return {
            "maxBrightness": int(p.get("maximumBrightness") or 100),
            "maxLumen": p.get("maximumLumen"),
            "watts": round(mv * ma / 1e6, 1) if mv and ma else None,
        }

    def cap(self):
        return max(1, min(100, self.power()["maxBrightness"]))

    def fetch_info(self):
        """Ask the light about itself: model, firmware, power and brightness limits."""
        out = {}
        for key, method in (("accessory", "get.elgato.accessory-info"), ("settings", "get.elgato.lights.settings")):
            try:
                out[key] = (self.call(method, {}) or {}).get("result")
            except LightError as e:
                out[key] = {"error": str(e)}
        first = not self.info
        self.info, self.info_at = out, time.time()
        if first:
            log("info " + json.dumps(out))
            self.soften()
        return out

    # The light fades by itself between values; out of the box it does it in 0.1s, which
    # reads as jumps. Ask for slower, softer transitions (kept in the light, so the phone
    # gets them too). If the light accepts, effects send fewer steps and let it glide.
    SOFT = {"switchOnDurationMs": 900, "switchOffDurationMs": 900, "colorChangeDurationMs": 400}

    def soften(self):
        st = self.info.get("settings")
        if not isinstance(st, dict) or "error" in st:
            return
        if all(st.get(k) == v for k, v in self.SOFT.items()):
            self.hw_fade = True
            return
        new = dict(st)
        new.update(self.SOFT)
        try:
            self.call("put.elgato.lights.settings", new)
            got = (self.call("get.elgato.lights.settings", {}) or {}).get("result") or {}
            self.hw_fade = got.get("colorChangeDurationMs") == self.SOFT["colorChangeDurationMs"]
            if self.hw_fade:
                self.info["settings"] = got
            log("soft transitions on" if self.hw_fade else "light kept its transitions: " + json.dumps(got))
        except LightError as e:
            log("couldn't set soft transitions: %s" % e)

    def put(self, light):
        self.call("put.elgato.lights", {"numberOfLights": 1, "lights": [light]})
        self.state.update(light)

    # -- high level -----------------------------------------------------
    def set(self, on=None, brightness=None, kelvin=None, temperature=None):
        light = {}
        if on is not None:
            light["on"] = 1 if on else 0
        if brightness is not None:
            light["brightness"] = max(1, min(100, int(brightness)))
        if kelvin is not None:
            light["temperature"] = k2m(kelvin)
        elif temperature is not None:
            light["temperature"] = max(143, min(344, int(temperature)))
        if light:
            self.put(light)

    def note(self, text):
        self.activity.appendleft({"t": time.time(), "text": text})
        log(text)

    def run_action(self, action, label=None):
        kind = action.get("type", "set")
        if kind == "set":
            self.set(action.get("on"), action.get("brightness"), action.get("kelvin"))
        elif kind in self.EFFECTS:
            if not self.effect_lock.acquire(blocking=False):
                return False  # an effect is already playing, skip instead of stacking
            try:
                self.EFFECTS[kind](self, action)
            finally:
                self.effect_lock.release()
        else:
            raise LightError("unknown action " + kind)
        if label:
            self.note(label)
        return True

    def _snapshot(self):
        try:
            self.refresh()
        except LightError:
            pass
        st = dict(self.state)
        return int(st.get("on", 1)), int(st.get("brightness", 20)), int(st.get("temperature", 344))

    def _contrast(self, temp, kelvin):
        alt = k2m(kelvin)
        if abs(alt - temp) < 40:  # already that color: go the other way so it's visible
            alt = k2m(2900) if temp < 250 else k2m(7000)
        return alt

    # ---- effects: smooth, perceptual curves that start and end where the light was ----
    @staticmethod
    def _perceptual(a, b, f, g=2.2):
        pa, pb = (a / 100) ** (1 / g), (b / 100) ** (1 / g)
        return max(1, min(100, round(((pa + (pb - pa) * f) ** g) * 100)))

    def _sweep(self, a, b, seconds, curve):
        # with soft transitions the light glides between points, so a point every 0.4s is
        # smoother than many tiny jumps; without them, fall back to 20 steps a second
        step = 0.4 if self.hw_fade else 0.05
        n, last = max(2, round(seconds / step)), None
        for i in range(1, n + 1):
            v = self._perceptual(a, b, curve(i / n))
            if v != last:
                self.put({"brightness": v}); last = v
            time.sleep(step)

    @staticmethod
    def _there(t):
        import math
        return (1 - math.cos(t * math.pi)) / 2

    @staticmethod
    def _there_back(t):
        import math
        return (1 - math.cos(t * 2 * math.pi)) / 2

    def _prep(self):
        """Snapshot the light; if it's off, fade it gently on so the effect is visible."""
        on, bri, temp = self._snapshot()
        bri = min(bri, self.cap())
        if not on:
            bri = max(1, round(self.cap() * 0.4))   # from off: a soft 40%, not full power
            self.put({"on": 1, "brightness": 1})
            self._sweep(1, bri, 0.6, self._there)
        return on, bri, temp

    def _finish(self, on, bri):
        self.put({"brightness": bri})
        if not on:
            self._sweep(bri, 1, 0.6, self._there)
            self.put({"on": 0})

    def _set_fade(self, ms):
        """Change only how long the light takes to glide between values."""
        st = self.info.get("settings")
        if not isinstance(st, dict) or "error" in st:
            return False
        new = dict(st)
        new["colorChangeDurationMs"] = int(ms)
        try:
            self.call("put.elgato.lights.settings", new)
            st["colorChangeDurationMs"] = int(ms)
            return True
        except LightError as e:
            log("couldn't change the fade: %s" % e)
            return False

    def _flicker(self, a):                       # brightness only, warmth pinned where it is
        on, b0, temp = self._prep()
        cap = self.cap()
        d = max(1, round(cap * float(a.get("delta", 10)) / 100))
        hi = b0 + d if b0 + d <= cap else max(1, b0 - d)      # only at the very top does it dip instead
        beats = max(1, min(6, int(a.get("beats", 3))))
        glide = float(a.get("glide", 0.9))                     # seconds for each rise and each settle
        # The light glides by itself. Give it one value per half-beat and a long enough fade,
        # and never send the next value before the glide has finished: no interruptions, no jumps.
        if self.hw_fade and self._set_fade(glide * 1000):
            try:
                for _ in range(beats):
                    self.put({"brightness": hi, "temperature": temp}); time.sleep(glide + 0.06)
                    self.put({"brightness": b0, "temperature": temp}); time.sleep(glide + 0.06)
            finally:
                self._set_fade(self.SOFT["colorChangeDurationMs"])
        else:                                    # no fades in the light: draw the curve ourselves
            for _ in range(beats):
                n = max(2, round(2 * glide / 0.05))
                for i in range(1, n + 1):
                    v = self._perceptual(b0, hi, self._there_back(i / n))
                    self.put({"brightness": v, "temperature": temp}); time.sleep(0.05)
        self._finish(on, b0)

    # action "type" -> the method that plays it
    EFFECTS = {
        "flicker": _flicker,
    }


# ---------------------------------------------------------------- loops
def daylight_target(now=None):
    now = now or datetime.now()
    h = now.hour + now.minute / 60
    for (h0, k0), (h1, k1) in zip(DAYLIGHT, DAYLIGHT[1:]):
        if h0 <= h <= h1:
            return round(k0 + (k1 - k0) * (h - h0) / (h1 - h0))
    return 4000


def keepalive(light):
    while True:
        try:
            light.refresh()
            if time.time() - light.info_at > 300:
                light.fetch_info()
            time.sleep(8)
        except LightError:
            time.sleep(15)
        except Exception as e:  # never let the loop die
            log("keepalive:", e)
            time.sleep(15)


def daylight_loop(light):
    while True:
        time.sleep(60)
        try:
            cfg = light.cfg
            if not cfg.get("daylight") or not light.connected or not light.state.get("on"):
                continue
            if time.time() - light.last_manual < 20 * 60 or light.effect_lock.locked():
                continue
            target = daylight_target()
            if abs(m2k(light.state.get("temperature", 344)) - target) > 120:
                light.set(kelvin=target)
        except Exception as e:
            log("daylight:", e)


# ---------------------------------------------------------------- http
def make_handler(light):
    class H(BaseHTTPRequestHandler):
        server_version = "lightd"

        def log_message(self, *a):
            pass

        def _json(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            if not n:
                return {}
            try:
                return json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return {}

        def _file(self, name, ctype):
            try:
                with open(os.path.join(HERE, name), "rb") as f:
                    body = f.read()
            except OSError:
                return self._json({"error": "not found"}, 404)
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            # the page changes with every update, so always fetch it fresh; icons can be cached
            self.send_header("Cache-Control", "no-cache" if name.endswith(".html") else "max-age=86400")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?")[0]
            STATIC = {
                "/manifest.webmanifest": "application/manifest+json",
                "/icon-180.png": "image/png", "/icon-192.png": "image/png", "/icon-512.png": "image/png",
            }
            if path in ("/", "/index.html"):
                # the panel lives in the menu-bar app only, not in a browser
                if not WEB and "SoftboxApp" not in (self.headers.get("User-Agent") or ""):
                    body = ("<!doctype html><meta charset=utf-8><title>Softbox</title>"
                            "<body style='background:#0e0f12;color:#888;font:14px -apple-system,sans-serif;"
                            "display:grid;place-items:center;height:90vh'>Softbox lives in your menu bar.</body>").encode()
                    self.send_response(404)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self._file("ui.html", "text/html; charset=utf-8")
            elif path in STATIC:
                self._file(path.lstrip("/"), STATIC[path])
            elif path == "/api/state":
                st = light.state
                def ev_out(k, v):
                    o = {"id": k, "kind": v.get("kind"), "enabled": v.get("enabled", True),
                         "label": v.get("label")}
                    if v.get("kind") == "signal":
                        eid = v.get("effect", "breath")
                        o["effect"] = eid
                        o["hint"] = EFFECTS.get(eid, {}).get("desc", "")
                    else:
                        o["action"] = v.get("action")
                    return o
                self._json({
                    "connected": light.connected and time.time() - light.last_ok < 40,
                    "on": int(st.get("on", 0)),
                    "brightness": int(st.get("brightness", 0)),
                    "kelvin": m2k(st.get("temperature", 344)),
                    "daylight": bool(light.cfg.get("daylight")),
                    "daylightTarget": daylight_target(),
                    "events": [ev_out(k, v) for k, v in light.cfg["events"].items()],
                    "effects": [dict(id=e, label=EFFECTS[e]["label"], desc=EFFECTS[e]["desc"])
                                for e in EFFECT_ORDER],
                    "activity": list(light.activity),
                    "info": light.info,
                    "power": light.power(),
                })
            else:
                self._json({"error": "not found"}, 404)

        def do_POST(self):
            if self.headers.get("X-Lightd") != "1":
                return self._json({"error": "missing X-Lightd header"}, 403)
            path, _, query = self.path.partition("?")
            body = self._body()
            try:
                if path == "/api/set":
                    light.last_manual = time.time()
                    light.set(body.get("on"), body.get("brightness"), body.get("kelvin"))
                    return self._json({"ok": True})
                if path == "/api/action":
                    # run an effect straight from the app: {"effect":"blink"} or a raw {"type":...}
                    act = effect_action(body["effect"]) if body.get("effect") in EFFECTS else body
                    light.last_manual = time.time()
                    threading.Thread(target=self._safe, args=(act, None), daemon=True).start()
                    return self._json({"ok": True})
                if path.startswith("/api/event/"):
                    eid = path.rsplit("/", 1)[1]
                    ev = light.cfg["events"].get(eid)
                    if not ev:
                        return self._json({"error": "unknown event " + eid}, 404)
                    if not ev.get("enabled", True) and "force=1" not in query:
                        return self._json({"ok": True, "skipped": "disabled"})
                    if ev.get("kind") == "scene":
                        light.last_manual = time.time()
                        act = dict(ev["action"])
                        if "brightness" in act:      # presets live on the 0-100 scale of what the power allows
                            act["brightness"] = max(1, round(act["brightness"] * light.cap() / 100))
                    else:
                        act = effect_action(ev.get("effect", "breath"))
                        log("signal: " + ev.get("label", eid))   # so it's clear what made the light breathe
                    threading.Thread(target=self._safe, args=(act, ev.get("label", eid)), daemon=True).start()
                    return self._json({"ok": True})
                if path == "/api/config":
                    if "daylight" in body:
                        light.cfg["daylight"] = bool(body["daylight"])
                        light.note("Daylight rhythm " + ("on" if light.cfg["daylight"] else "off"))
                    for eid, patch in (body.get("events") or {}).items():
                        tgt = light.cfg["events"].get(eid)
                        if not tgt:
                            continue
                        if "enabled" in patch:
                            tgt["enabled"] = bool(patch["enabled"])
                        if patch.get("effect") in EFFECTS and "effect" in tgt:
                            tgt["effect"] = patch["effect"]
                        _apply_scene(tgt, patch.get("action") or {})
                    if body.get("resetScenes"):
                        for eid, ev in DEFAULT_CFG["events"].items():
                            if ev.get("kind") == "scene":
                                light.cfg["events"][eid]["action"] = copy.deepcopy(ev["action"])
                    save_cfg(light.cfg)
                    return self._json({"ok": True})
                return self._json({"error": "not found"}, 404)
            except LightError as e:
                return self._json({"error": str(e)}, 502)

        @staticmethod
        def _safe(action, label):
            try:
                light.run_action(action, label)
            except Exception as e:
                log("action failed:", e)

    return H


def main():
    cfg = load_cfg()
    if not os.path.exists(CFG_PATH):
        save_cfg(cfg)
    light = Light(cfg)
    threading.Thread(target=keepalive, args=(light,), daemon=True).start()
    threading.Thread(target=daylight_loop, args=(light,), daemon=True).start()
    # bind to all interfaces so a phone on the same Wi-Fi can reach the panel;
    # the X-Lightd header guard still blocks stray web pages. Set LIGHTD_BIND=
    # 127.0.0.1 to keep it to this Mac only.
    host = os.environ.get("LIGHTD_BIND", "0.0.0.0")
    srv = ThreadingHTTPServer((host, HTTP_PORT), make_handler(light))
    adv = advertise() if host != "127.0.0.1" else None
    import signal
    def stop(*_):
        if adv:
            adv.terminate()
        os._exit(0)
    # self-update: when lightd.py is replaced on disk, exit cleanly and let
    # launchd (KeepAlive) start the new version a few seconds later
    threading.Thread(target=watch_self, args=(stop,), daemon=True).start()
    threading.Thread(target=watch_app, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log(f"lightd ready on http://{host}:{HTTP_PORT}")
    srv.serve_forever()


def watch_app():
    """Rebuild the menu-bar app when its source in ~/.softbox/app changes, then restart it.
    So an app update arrives the same way a service update does: drop the files, done."""
    import hashlib, subprocess
    src = os.path.join(HOME, "app")
    stamp = os.path.join(src, ".built")
    apps = os.path.expanduser("~/Applications")
    while True:
        try:
            main = os.path.join(src, "main.swift")
            if os.path.exists(main) and os.path.exists(os.path.join(src, "build-app.sh")):
                with open(main, "rb") as f:
                    h = hashlib.sha256(f.read()).hexdigest()
                done = open(stamp).read().strip() if os.path.exists(stamp) else ""
                if h != done:
                    time.sleep(2)                     # let the copy finish
                    log("app source changed, rebuilding the menu-bar app")
                    r = subprocess.run(["bash", os.path.join(src, "build-app.sh"), apps],
                                       capture_output=True, text=True, timeout=600)
                    with open(stamp, "w") as f:
                        f.write(h)                    # don't loop on a failing build
                    if r.returncode == 0:
                        subprocess.run(["launchctl", "kickstart", "-k",
                                        "gui/%d/dev.softbox.app" % os.getuid()],
                                       capture_output=True, timeout=30)
                        log("menu-bar app rebuilt and restarted")
                    else:
                        log("app build failed: " + (r.stderr or r.stdout)[-400:])
        except Exception as e:                        # never let this take the service down
            log("app watcher: %s" % e)
        time.sleep(10)


def watch_self(stop):
    me = os.path.abspath(__file__)
    try:
        seen = os.stat(me).st_mtime
    except OSError:
        return
    while True:
        time.sleep(3)
        try:
            now = os.stat(me).st_mtime
        except OSError:
            continue
        if now != seen:
            time.sleep(1)            # let the write finish
            log("new version on disk, restarting")
            stop()


def discover_lights(seconds=4):
    """Find Key Light Air MK.2 lights on the LAN with Bonjour (_elg._tcp) and return their
    .local host names. Uses macOS's dns-sd; returns [] anywhere else."""
    import shutil
    import subprocess
    if not shutil.which("dns-sd"):
        return []

    def run(args):
        try:
            return subprocess.run(args, capture_output=True, text=True, timeout=seconds).stdout
        except subprocess.TimeoutExpired as e:           # dns-sd streams forever; take what it said
            out = e.stdout or b""
            return out.decode(errors="replace") if isinstance(out, bytes) else out

    names = []
    for line in run(["dns-sd", "-B", "_elg._tcp", "local"]).splitlines():
        parts = line.split(None, 6)
        if len(parts) == 7 and parts[1] == "Add":
            name = parts[6].strip()
            if name not in names:
                names.append(name)
    hosts = []
    for name in names:
        for line in run(["dns-sd", "-L", name, "_elg._tcp", "local"]).splitlines():
            if "can be reached at" in line:
                h = line.split("can be reached at", 1)[1].strip().split(":")[0].rstrip(".")
                if h and h not in hosts:
                    hosts.append(h)
                break
    return hosts


def advertise():
    """Announce the bridge on the LAN (Bonjour) so the phone app can find it."""
    import shutil
    import subprocess
    if not shutil.which("dns-sd"):
        return None
    try:
        return subprocess.Popen(
            ["dns-sd", "-R", "Softbox Bridge", "_softbox._tcp", "local", str(HTTP_PORT)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return None


if __name__ == "__main__":
    main()

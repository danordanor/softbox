#!/usr/bin/env python3
"""A stand-in for the MK.2 light: a TLS WebSocket server that speaks the same
JSON-RPC the real firmware does, so we can test lightd without hardware.

It mirrors the quirks we learned:
  - requires TLS (self-signed here; lightd does not verify)
  - sends a notification.elgato.lights right after connect
  - replies to get/put.elgato.lights, echoing a STRING id
  - a numeric id would be rejected by the real light; we just log it
"""
import base64, hashlib, json, os, socket, ssl, struct, threading, sys

HOST, PORT = "127.0.0.1", 9123
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
state = {"on": 1, "brightness": 20, "temperature": 344}
CERT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock.pem")


def mkcert():
    if os.path.exists(CERT):
        return
    os.system(
        f'openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 '
        f'-nodes -keyout {CERT} -out {CERT} -days 3650 -subj "/CN=mock" 2>/dev/null'
    )


def send_text(c, text):
    data = text.encode()
    head = bytearray([0x81])
    n = len(data)
    if n < 126:
        head.append(n)
    else:
        head.append(126); head += struct.pack(">H", n)
    c.sendall(bytes(head) + data)


def read_frame(c):
    b = c.recv(2)
    if len(b) < 2:
        return None
    op = b[0] & 0x0F
    masked = b[1] & 0x80
    n = b[1] & 0x7F
    if n == 126:
        n = struct.unpack(">H", c.recv(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", c.recv(8))[0]
    mask = c.recv(4) if masked else b""
    payload = b""
    while len(payload) < n:
        payload += c.recv(n - len(payload))
    if mask:
        payload = bytes(x ^ mask[i % 4] for i, x in enumerate(payload))
    return op, payload


def handle(c):
    req = b""
    while b"\r\n\r\n" not in req:
        x = c.recv(1024)
        if not x:
            return
        req += x
    key = ""
    for line in req.decode(errors="replace").split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()
    accept = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
    ).decode()
    c.sendall((
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
    ).encode())
    # push current state like the real light
    send_text(c, json.dumps({"jsonrpc": "2.0", "method": "notification.elgato.lights",
                             "params": {"numberOfLights": 1, "lights": [state]}}))
    while True:
        f = read_frame(c)
        if not f:
            return
        op, payload = f
        if op == 0x8:
            return
        if op == 0x9:
            c.sendall(bytes([0x8A, 0]))
            continue
        if op != 0x1:
            continue
        try:
            j = json.loads(payload)
        except ValueError:
            send_text(c, '{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"},"id":"unknown"}')
            continue
        rid = j.get("id")
        if not isinstance(rid, str):
            print("  mock: REJECT non-string id", repr(rid), "(real light would reboot)")
            continue
        m = j.get("method", "")
        if m == "get.elgato.lights":
            send_text(c, json.dumps({"jsonrpc": "2.0", "id": rid,
                "result": {"numberOfLights": 1, "lights": [state]}}))
        elif m == "put.elgato.lights":
            state.update(j["params"]["lights"][0])
            send_text(c, json.dumps({"jsonrpc": "2.0", "id": rid,
                "result": {"numberOfLights": 1, "lights": [state]}}))
            print("  mock: state ->", state)
        elif m == "get.elgato.accessory-info":
            send_text(c, json.dumps({"jsonrpc": "2.0", "id": rid,
                "result": {"productName": "Elgato Key Light Air MK.2", "serialNumber": "MOCK", "power-info": {"operationMode": 1, "maximumBrightness": 20, "maximumLumen": 180, "source": {"usbStatus": 0, "type": 3, "pdo": {"voltage": 5000, "current": 900}}}}}))
        else:
            send_text(c, json.dumps({"jsonrpc": "2.0", "id": rid,
                "error": {"code": -32601, "message": "Method not found"}}))


def main():
    mkcert()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT)
    ctx.verify_mode = ssl.CERT_NONE
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(5)
    print(f"mock light on {HOST}:{PORT}", flush=True)
    while True:
        raw, _ = srv.accept()
        try:
            c = ctx.wrap_socket(raw, server_side=True)
        except ssl.SSLError as e:
            print("  mock: tls error", e); continue
        threading.Thread(target=lambda: _run(c), daemon=True).start()


def _run(c):
    try:
        handle(c)
    except (OSError, ssl.SSLError):
        pass
    finally:
        try: c.close()
        except OSError: pass


if __name__ == "__main__":
    main()

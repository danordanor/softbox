# The Key Light Air MK.2 protocol

What the light speaks, worked out from Elgato Control Center and the light itself (firmware 1.1.8). Use it to build your own client.

## Finding the light

The light advertises **`_elg._tcp`** over Bonjour. Its host name looks like `elgato-key-light-air-mk-2-xxxx.local`.

```sh
dns-sd -B _elg._tcp local
dns-sd -L "<instance name>" _elg._tcp local
```

## Connecting

- **`wss://<light>:9123/`**: a WebSocket over TLS.
- **Mutual TLS.** The light only accepts clients that show a certificate signed by Elgato's intermediate CA. Elgato Control Center ships that intermediate certificate *and its key* in its bundle:

  ```
  /Applications/Elgato Control Center.app/Contents/Resources/pki_Key_Light_Air_Mk2/
    intermediate.crt.pem
    intermediate.key.pem
  ```

  Mint a client certificate from it (EC P-256, `extendedKeyUsage=clientAuth,serverAuth`), and present it **with the intermediate in the chain**. Without the chain the handshake fails. See `mac/install.sh` for the exact `openssl` steps.
- The light's own certificate doesn't match its host name, so don't verify it by name.
- **Keep one connection** and reuse it. Many quick reconnects make the firmware unhappy.
- Space requests about **45 ms** apart.

## JSON-RPC 2.0

Every message is a JSON-RPC 2.0 text frame.

> **IDs must be strings.** A numeric `id` makes the light reboot.

```json
{"jsonrpc":"2.0","id":"1","method":"get.elgato.lights","params":{}}
```

### Methods

| Method | Params | Result |
|---|---|---|
| `get.elgato.lights` | `{}` | `{"numberOfLights":1,"lights":[{"on":1,"brightness":20,"temperature":344}]}` |
| `put.elgato.lights` | `{"numberOfLights":1,"lights":[{...any of on, brightness, temperature}]}` | the new state |
| `get.elgato.accessory-info` | `{}` | model, firmware, serial, Wi-Fi and **power-info** |
| `get.elgato.lights.settings` | `{}` | power-on behaviour and **transition durations** |
| `put.elgato.lights.settings` | the full settings object, changed | the new settings |

- `on`: `0` or `1`
- `brightness`: `1` to `100`. The light clamps it to `power-info.maximumBrightness`.
- `temperature`: in **mireds**, `143` (≈7000 K, cool) to `344` (≈2900 K, warm). `kelvin = 1,000,000 / mired`.

### Power

```json
"power-info": {
  "operationMode": 1,
  "maximumBrightness": 20,
  "maximumLumen": 180,
  "source": { "type": 3, "pdo": { "voltage": 5000, "current": 900 } }
}
```

On a 5 V / 0.9 A port (4.5 W) the light allows **20%**. A USB-C PD supply of about 30 W unlocks 100%. Softbox shows brightness as 0 to 100 *of this cap*.

### Transitions

```json
"switchOnDurationMs": 100, "switchOffDurationMs": 300, "colorChangeDurationMs": 100
```

The light fades between values by itself over these durations. The defaults are short enough to read as jumps. Softbox sets **900 / 900 / 400 ms** once (they're stored in the light), then steps effects one brightness value at a time and lets the light glide between them.

### Notifications

The light pushes changes without being asked:

- `notification.elgato.lights`: the light state changed (from any client or the hardware button)
- `notification.elgato.accessory-info`: for example, the power source changed

Treat them like the result of a `get`.

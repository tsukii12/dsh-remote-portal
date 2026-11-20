# Public access and relay deployment

[简体中文](DEPLOY-SERVER.zh-CN.md) · [Documentation](README.md#english)

A YuRemote relay runs on **your server**, not a hosted service supplied by the project. Start with a working [local portal](GETTING-STARTED.md). Do not expose dsh's own Web port, and do not send portal passwords, cookies, pairing links or relay tokens over untrusted HTTP.

## Install the project relay

On a Linux server with systemd, point a DNS name such as `relay.example.com` at the server. Download and inspect the installer, then run it:

```sh
curl -fsSLO https://raw.githubusercontent.com/tsukii12/dsh-YuRemote/master/tools/deploy-relay.sh
sudo bash deploy-relay.sh
```

Choose **HTTPS** for visitors. The installer can obtain a Let's Encrypt certificate with HTTP validation (requires inbound TCP 80) or DNS validation, use your PEM certificate and key, or create a self-signed certificate. Self-signed certs are not automatically trusted by browsers or apps. The installer registers the `yuremote-relay` service and the `yuremote` command; it can install Node if needed. A rerun updates the relay while keeping saved settings. Use `--reconfigure` to change certificate, proxy or public listener settings.

Open the chosen visitor port (normally TCP **443** for HTTPS) and the agent port (normally TCP **9443**) on the server. The dsh host only needs outbound access to the agent port, not inbound port forwarding. The two connections are independent: HTTPS on the visitor port does not turn a plaintext agent port into TLS.

## Connect the dsh host

1. On the server, use `yuremote` to see the **endpoint** and use `yuremote token` to retrieve the token privately.
2. In dsh, open **Remote access → Public access**, paste the endpoint (for example `tls://relay.example.com:9443`) and token, then connect. Use `tcp://relay.example.com:9443` only for an intentionally plaintext agent port on a trusted link. A bare address attempts TLS; it does not fall back to TCP.
3. When connected, open the HTTPS **visitor** URL, e.g. `https://relay.example.com/__t/EXAMPLE_ID/`, and sign in to the portal. Keep the whole path when adding the host in the app. The URL is an address, not a login credential.

| Command | Purpose |
| --- | --- |
| `yuremote` / `yuremote url` | Status and visitor URL |
| `yuremote log -f` | Follow service logs |
| `yuremote restart` | Restart the relay service |
| `yuremote token add` / `yuremote tokens` / `yuremote urls` | Add another host and list tunnels and URLs |
| `yuremote token remove <id>` | Remove a host's relay token |
| `yuremote uninstall` | Remove the installed relay |

Each host uses a different token and tunnel path. If a token leaks, remove it, create a replacement, and reconnect the host. If the agent cannot connect, check DNS, the agent port, the token and the configured TLS mode. Prefer a valid certificate; for your own CA use `tunnel.caFile` in host configuration instead of disabling verification.

## Run the relay behind a reverse proxy

For a manual installation, use Node.js 20+, a private token file (mode `0600`, one token per line), and your own service manager. For example, with a certificate available to the relay for the agent and a separate HTTPS proxy for visitors:

```sh
node tools/relay.mjs --token-file /path/to/tokens \
  --agent-port 9443 --http-port 127.0.0.1:8080 \
  --tls-cert /path/to/fullchain.pem --tls-key /path/to/key.pem \
  --public-url https://relay.example.com
```

Forward HTTPS requests to `127.0.0.1:8080`, preserving the full visitor path and forwarding WebSocket upgrades. Do not buffer streaming responses. Keep port 8080 private; publish the HTTPS proxy and the agent port, and use `tls://relay.example.com:9443` in YuRemote.

## Bring your own tunnel

You can use an existing private overlay or reverse tunnel instead of the project relay. With a tunnel client on the dsh host, set **Bind address** to `127.0.0.1` and point the tunnel at the gateway (`http://127.0.0.1:3081` by default). For direct access over a private overlay, bind the gateway to an address on that overlay instead. Forward streaming HTTP and WebSockets and leave portal authentication enabled. For public exposure use trusted HTTPS, not a raw forward of dsh Web.

# rsc-relay

Lets clients that can only make HTTPS requests play RuneScape Classic.
Apple Watch apps are the reason: watchOS blocks raw TCP connections for
normal apps ([TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)),
even when sideloaded. The relay holds the game's TCP connection and passes
the bytes over HTTPS.

```
Apple Watch --HTTPS--> https://192.168.4.20:8443 (the relay's own port, pinned key) --+
            --HTTPS--> <machine>.<tailnet>.ts.net (Tailscale Funnel, optional) ---------+--> rsc-relay --TCP--> game.openrsc.com:43596
```

It's a single Go program with no dependencies, and runs on macOS, Linux,
Windows, WSL and in a container.

The relay has its own key (made on first start), and serves HTTPS with it on
port 8443. The apps don't trust it by name or certificate authority: they
pin the key. So every address that reaches the relay, whether the home
network, a public IP, Tailscale or WireGuard, is equally safe, and
`/v1/info` lists them all. The apps try them at once and use the first that
answers, which also gets the watch past an iPhone whose Tailscale DNS gives
it an address it can't reach.

## Run it

```
cd relay
go build -o rsc-relay .     # needs Go 1.22 or later
./rsc-relay
```

On first run it creates its key (`identity.pem`) and an access token
(`token`), which clients need, in its data directory:

| System | Data directory |
|---|---|
| macOS | `~/Library/Application Support/rsc-relay/` |
| Linux, WSL | `~/.config/rsc-relay/` |
| Windows | `%AppData%\rsc-relay\` |
| Container | `/data` |

Never delete `identity.pem`: apps that pinned its key won't trust a new one
on the relay's own port until they learn it again through the relay URL.

Options (each can also be set in the environment as `RSC_RELAY_<FLAG>`,
e.g. `RSC_RELAY_TLS_LISTEN`, for containers):

| Flag | Default | |
|---|---|---|
| `-data` | see above | Key, token and paired devices |
| `-listen` | `127.0.0.1:8737` | Plain HTTP for Tailscale Funnel or another TLS proxy on this machine; empty to turn off |
| `-tls-listen` | `:8443` | HTTPS with the relay's own key, on every interface; empty to turn off |
| `-advertise` | | Extra addresses apps may use, comma-separated: a public IP, a WireGuard address, a Funnel URL |
| `-local-addresses` | `true` | Offer this machine's own addresses; `false` in a bridged container |
| `-shared-token` | `true` | Accept the shared token; `false` once every device is paired, so only paired devices get in |
| `-token-file` | `<data>/token` | Where the shared token is kept |
| `-allow` | Preservation, Uranium, 2001Scape and Neat F2P | Comma-separated `host:port` game servers clients may reach |
| `-idle` | `60s` | Close sessions whose client stopped polling, such as a watch that went to sleep |

Commands:

```
rsc-relay info                      # the key and the addresses apps are offered
rsc-relay devices list              # paired devices
rsc-relay devices add "Apple Watch" # pair one: prints its own token, once
rsc-relay devices remove <id>       # unpair one; takes effect within seconds
```

Paired devices each have their own token, so one can be removed without
changing the others. The shared token keeps working alongside them until
you turn it off with `-shared-token=false` (`RSC_RELAY_SHARED_TOKEN=false`).
After that, a device still using it is told to pair, and the token file is
left alone in case you turn it back on.

### In a container

```
docker build -t rsc-relay relay/
docker run -d --name rsc-relay --restart unless-stopped \
    --network host -v rsc-relay:/data rsc-relay
docker exec rsc-relay rsc-relay info
```

Podman takes the same commands. `--network host` lets the relay offer the
machine's real addresses. With a bridged network, publish the port and name
them yourself:
`-p 8443:8443 -e RSC_RELAY_LOCAL_ADDRESSES=false -e RSC_RELAY_ADVERTISE=192.168.4.20`.

On WSL2, use mirrored networking (Windows 11), or the home network can't
reach the relay.

To build for another machine from this one, e.g. a Linux server:

```
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o rsc-relay-linux .
```

## Reach it from your devices

**At home:** nothing to set up. The apps learn the relay's home-network
address from `/v1/info` once they've reached it through the relay URL.
Allow port 8443 in the machine's firewall, e.g.
`sudo ufw allow from 192.168.1.0/24 to any port 8443 proto tcp`, and give
the machine a fixed address in the router (on an eero: Settings, Network
settings, Reservations & port forwarding).

**From anywhere, without a VPN:** forward TCP 8443 on the router to the
machine and add the public address with `-advertise`.

### With Tailscale

**From anywhere, including a watch on LTE (Funnel):** a watch can't join a
tailnet, so Funnel publishes the relay at a public HTTPS address with a
valid certificate:

```
tailscale funnel --bg 8737
```

The first time, Tailscale asks you to turn on HTTPS certificates and Funnel
for your tailnet in the admin console and prints the link. Then
`tailscale funnel status` shows the address, like
`https://<machine>.<tailnet>.ts.net/`.

**Only from your own devices (Serve):** iPhones, iPads and computers running
Tailscale can use the tailnet without anything being public:

```
tailscale serve --bg 8737
```

Turn either off with `tailscale funnel --https=443 off` or
`tailscale serve --https=443 off`.

Keep the machine awake while you play. On a MacBook, plug it in and run
`caffeinate -s ./rsc-relay`, or turn on "Prevent automatic sleeping when the
display is off" in Battery settings.

## When something doesn't connect

The relay logs every session and every request it turns away, with which app
sent it and what to do about it:

```
watch 0.2.0: POST /v1/sessions refused (401 Unauthorized): wrong access token. Copy the token from this relay's token file into the app's Relay settings
watch 0.2.0: session 3f9a1c… opened to game.openrsc.com:43596
watch 0.2.0: session 3f9a1c… closed by client after 4m12s (sent 3.1 KB, received 88.0 KB)
iPhone 0.2.0: session 7be210… closed after going idle after 1m05s (sent 41 B, received 0 B); the game server never replied
```

If the app shows a connection problem and **nothing** appears here, the
request never reached the relay: check that the relay's machine is awake,
port 8443 is open, and (for Funnel) Tailscale is on and
`tailscale funnel status` lists the relay.

The watch isn't on your tailnet. When it's online through an iPhone that
uses Tailscale DNS, the Funnel name gives it the relay's Tailscale address
(`100.x`), which it can't reach. It uses the relay's own port instead,
once it knows it: open RSC on the iPhone first, which fetches the relay's
key and addresses and sends them to the watch. If the watch still only has
the Funnel URL, it says "iPhone's Tailscale DNS is on".

The apps also check each link themselves when a login can't connect, and
show which one failed:

| Link | If it fails |
|---|---|
| Internet | The phone or watch is offline |
| Reach the relay | Wrong relay URL, relay machine asleep, Tailscale or Funnel off, or (watch) the iPhone's Tailscale DNS |
| rsc-relay running | Funnel is up but the relay isn't (Funnel answers `502`) |
| Access token | The app's token doesn't match the token file |
| World allowed | The world isn't in `-allow` |
| Game server | The relay can't reach the game server |

On the watch, the report also says when the settings last came from the
iPhone; open RSC on the iPhone to send them again.

## Security

A Funnel address, and the relay's own port once it's forwarded, is
reachable by anyone who knows it, so:

- Every request except `/v1/health` needs a token. After 20 wrong tokens
  in 10 minutes, an address is refused until it stops.
- On the relay's own port, the apps only talk to the relay whose key they
  pinned, so nobody can stand in for it. Treat it like a
  password and keep it out of git, like your Funnel address.
- Only the game servers in the allow list can be reached, so the relay
  can't be used as a general proxy.
- The relay never logs game data or tokens, only sessions opening and
  closing and requests it refused.
- The game client RSA-encrypts the password before sending it, so the relay
  never sees it in plain text.

Everyone using one relay appears to the game server as one address, so
mind servers' limits on accounts per address if you share it.

## API

All requests except `/v1/health` need `Authorization: Bearer <token>`.
Clients name themselves in `X-RSC-Client` (such as `watch 0.2.0`) for the
log, and every response carries `X-RSC-Relay: <version>`, which tells a
reply from the relay apart from Tailscale Funnel answering for it.

| Request | |
|---|---|
| `POST /v1/sessions` with `{"host": "...", "port": 43596}` | Connects to the game server. Returns `{"id": "..."}` |
| `POST /v1/sessions/{id}/send?at=N` | Sends the body; `N` is the stream offset of its first byte |
| `GET /v1/sessions/{id}/recv?from=N&wait=ms` | Returns bytes from offset `N`, waiting up to `wait` (at most 20 s) for some to arrive. Asking for `N` acknowledges everything before it |
| `DELETE /v1/sessions/{id}` | Closes the session |
| `GET /v1/health` | Returns `ok` |
| `GET /v1/info` | The key and addresses: `{"version", "name", "pin": "sha256/<base64>", "endpoints": [{"url", "kind"}]}`. `kind` is `lan`, `tailscale`, `ipv6` or `advertised` |
| `GET /v1/check?host=...&port=N` | Whether the relay can reach that game server: `{"version", "sessions", "servers": [{"address", "allowed", "reachable", "ms", "error"}]}`. Without `host`, checks every allowed server |

The offsets make every request safe to retry on a flaky connection: a
repeated send is skipped, and a recv whose response was lost can be fetched
again. `409` means an offset didn't match the stream, `410` that the game
server closed the connection, `404` an unknown or expired session.

The pin is the SHA-256 of the key's SubjectPublicKeyInfo, as
`curl --pinnedpubkey` takes it:

```
curl --pinnedpubkey "sha256//<base64>" -k https://192.168.4.20:8443/v1/health
```

Run the tests with `go test -race ./...`.

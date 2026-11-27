# Deploying the server

How to run the sharecmd server on a Linux VPS, so players (such as a
browser game's) can connect to it over the internet. Replace the
placeholders as you go:

| Placeholder | What it is |
| --- | --- |
| `<server-ip>` | your server's public IP address |
| `<user>` | the account you log in to the server with |
| `example.com` | your domain name, if you serve the game over HTTPS |

The server is one self-contained binary with no files or database. It runs
one match at a time (see [Server options](README.md#server-options)).

## 1. Build a Linux binary

`main.go` is generated (see [Build it](README.md#build-it)), so run
`build.sh` first, with orc checked out next to this repo. Then build a
static binary, so the server doesn't need Go installed:

```sh
./build.sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o sharecmd .
scp sharecmd <user>@<server-ip>:/tmp/
```

Match `GOARCH` to the server's CPU: run `uname -m` on it. `x86_64` is
`amd64`, and `aarch64` is `arm64`.

## 2. Install it

Put it outside any folder your web server serves, so it can't be
downloaded:

```sh
sudo mkdir -p /opt/sharecmd
sudo mv /tmp/sharecmd /opt/sharecmd/
sudo chmod 755 /opt/sharecmd/sharecmd
```

## 3. Open its port

The server listens on 8080 by default. Allow it through the server's
firewall, for example with ufw:

```sh
sudo ufw status            # if it's active:
sudo ufw allow 8080/tcp
```

If your hosting provider has its own firewall in front of the server, add
an inbound rule for TCP 8080 there too.

## 4. Try it by hand

On the server:

```sh
/opt/sharecmd/sharecmd -mode server -addr :8080
```

From your own machine:

```sh
curl -X POST http://<server-ip>:8080/match
```

You should get JSON like `{"match_id":"…","player":0}`. That request takes
player 0's slot, which frees up again after the join timeout (`-join-timeout`,
30 seconds by default). Stop the server with Ctrl-C.

## 5. Keep it running with systemd

Create `/etc/systemd/system/sharecmd.service`. That folder belongs to
root, so write it with `sudo` (a plain editor opens it read-only). This
writes the whole file in one paste:

```sh
sudo tee /etc/systemd/system/sharecmd.service > /dev/null << 'EOF'
[Unit]
Description=sharecmd lockstep server
After=network.target

[Service]
ExecStart=/opt/sharecmd/sharecmd -mode server -addr :8080
Restart=always
DynamicUser=yes

[Install]
WantedBy=multi-user.target
EOF
```

Or open it in an editor as root, such as
`sudo nano /etc/systemd/system/sharecmd.service`, and paste the lines
between the `EOF`s.

`DynamicUser=yes` runs it as a throwaway unprivileged user, which is fine
since it needs no files. Then start it, now and on every boot:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now sharecmd
systemctl status sharecmd
sudo journalctl -u sharecmd -f      # its log, live
```

`journalctl -f` follows the log and doesn't finish on its own: press
Ctrl-C to stop watching (the server keeps running). Without `sudo` it shows
"No entries", unless your account is in the `systemd-journal` (or `adm`)
group.

To update it later, copy the new binary over the old one and run
`sudo systemctl restart sharecmd`.

## 6. Check it comes back after a reboot

Once the service runs, restart the server once to make sure it starts on
its own.

Before the reboot, check it's enabled, and that the copy running is the
service's, not one started by hand in a terminal (which a reboot ends
anyway):

```sh
systemctl is-enabled sharecmd       # enabled
systemctl is-active sharecmd        # active
pgrep -a sharecmd                   # one process: /opt/sharecmd/sharecmd ...
systemctl show -p MainPID sharecmd  # the same number pgrep printed
```

If `MainPID` is different (or 0), a hand-started copy is holding the port:
stop it (`kill <its number>`), then `sudo systemctl restart sharecmd`.

Stop watching any `journalctl -f` with Ctrl-C, then restart:

```sh
sudo reboot
```

Your session drops. Give the server a minute, log back in, and check:

```sh
uptime                              # "up 0 min" or so: it did restart
systemctl status sharecmd           # active (running), since just after the boot
sudo journalctl -u sharecmd -b      # this boot's log
```

The log should end with `lockstep server listening on :8080`. (`-b` limits
it to the current boot.) Then check from your own machine, the way players
reach it:

```sh
curl -s -X POST http://<server-ip>:8080/match
```

That takes a player slot for the join timeout (30 seconds), so wait before
playing. Or skip it and play: open the game in two browser windows side by
side (not two tabs: a background tab is paused) and start a match.

## Browser clients: HTTP or HTTPS

A browser game is a page served by your web server (such as Apache), which
then talks to sharecmd: `POST /match` over HTTP, then a websocket at `/ws`.
`POST /match` replies with `Access-Control-Allow-Origin: *`, so a page
served from another port or host may call it.

The server itself only speaks plain HTTP and websockets (no TLS), so what
works depends on how the page is served:

- **Page over `http://`**: the page can reach `http://<server-ip>:8080`
  and `ws://<server-ip>:8080` directly, and nothing more is needed. The
  traffic isn't encrypted.
- **Page over `https://`**: browsers block a secure page from plain `http://`
  and `ws://` connections (mixed content), so the page needs
  `https://` and `wss://`. Put a reverse proxy with TLS in front of
  sharecmd, as below.

Watch for a redirect: a site set up with Let's Encrypt's certbot usually
redirects its domain from `http://` to `https://`, so a page you open by
domain name may be on HTTPS even if you typed `http://`. Check with
`curl -sI http://example.com/your-game/`.

### HTTPS with Apache in front

Apache can serve HTTPS on port 8080, with the certificate your site already
has, and pass everything to sharecmd on a local port. A client that uses
port 8080 on the page's own host then works unchanged.

1. Run sharecmd on a local port only: change the systemd unit's
   `ExecStart` to `-addr 127.0.0.1:9080` (edit it with `sudo`, as in step
   5), then
   `sudo systemctl daemon-reload && sudo systemctl restart sharecmd`.
2. Enable Apache's modules:
   `sudo a2enmod ssl proxy proxy_http proxy_wstunnel`.
3. Add a site, such as `/etc/apache2/sites-available/sharecmd.conf`, with
   the certificate paths from your HTTPS site's config:

   ```apache
   Listen 8080
   <VirtualHost *:8080>
       ServerName example.com
       SSLEngine on
       SSLCertificateFile    /etc/letsencrypt/live/example.com/fullchain.pem
       SSLCertificateKeyFile /etc/letsencrypt/live/example.com/privkey.pem
       ProxyPass        / http://127.0.0.1:9080/ upgrade=websocket
       ProxyPassReverse / http://127.0.0.1:9080/
   </VirtualHost>
   ```

4. Turn it on:
   `sudo a2ensite sharecmd && sudo apache2ctl configtest && sudo systemctl reload apache2`.

Open the game by its domain name (so the certificate matches), not by IP.
`upgrade=websocket` needs Apache 2.4.47 or later (`apache2 -v`).

## Troubleshooting

- The browser's developer console shows a request that failed, and why
  (refused, blocked as mixed content, or a CORS error).
- `sudo journalctl -u sharecmd -f` shows whether requests reach the server. No
  log line at all usually means a firewall is blocking the port.
- `curl -X POST http://<server-ip>:8080/match` from outside tests the port
  without a browser.
- `503` from `/match` means a match is already in progress: the server runs
  one at a time.

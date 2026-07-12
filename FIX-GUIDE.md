# Fix Guide: Hide Response Headers from ISP Scanners

This guide is for servers **already installed** with autoscript v0.2.0-beta.
It makes the domain show minimal information when scanned — no HTTP status
line, no `Server` header, no `Upgrade: websocket` response.

**What this fixes:**

| Path | Before | After |
|------|--------|-------|
| `/` | `HTTP/1.1 101 Switching Protocols` + headers | TCP close (no response) |
| `/vmess` | `HTTP/1.1 101 Switching Protocols` + headers | TCP close (no response) |
| `/vless` | `HTTP/1.1 400 Bad Request` + `Server: nginx` | TCP close (no response) |
| `/trojan` | `HTTP/1.1 400 Bad Request` + `Server: nginx` | TCP close (no response) |

**How**: Nginx checks for `Upgrade: websocket` header — all real clients
(SSH injector, VMESS, VLESS, Trojan, v2ray/Xray) send it. Scanners don't.
Non-WebSocket requests get HTTP 444 — instant TCP close, zero bytes sent.

---

## Step 1: Add `return 444` Guards

Edit `/etc/nginx/risqinf.conf`. Add the guard line as the **first line**
inside each WebSocket location block:

### `/vless`
```nginx
    location /vless {
        if ($http_upgrade != "websocket") { return 444; }
        proxy_pass http://vless_ws;
```

### `/vmess`
```nginx
    location /vmess {
        if ($http_upgrade != "websocket") { return 444; }
        proxy_pass http://vmess_ws;
```
> If `/vmess` block doesn't exist yet, add it (identical structure to `/vless`).

### `/trojan`
```nginx
    location /trojan {
        if ($http_upgrade != "websocket") { return 444; }
        proxy_pass http://trojan_ws;
```

### `/ssh`
```nginx
    location /ssh {
        if ($http_upgrade != "websocket") { return 444; }
        proxy_pass http://ssh_ws;
```

### `/` (root — **before** the `rewrite` line)
```nginx
    location / {
        if ($http_upgrade != "websocket") { return 444; }
        rewrite ^.*$ / break;
```

> **Important for `/`**: the guard MUST be before `rewrite`. Nginx processes
> `return` before `rewrite`, so the guard fires first.

---

## Step 2: Test and Reload

```bash
nginx -t && systemctl reload nginx
```

---

## Step 3: Verify

```bash
# Scanner probe — should timeout / "Empty reply from server"
curl -sk --max-time 5 https://your-domain.com/
curl -sk --max-time 5 https://your-domain.com/vmess
curl -sk --max-time 5 https://your-domain.com/vless
curl -sk --max-time 5 https://your-domain.com/trojan
```

All real clients (SSH WebSocket injector, VMESS, VLESS, Trojan) should
connect normally after this change.

---

## How 444 Works

444 is a special Nginx status code: it closes the TCP connection
immediately without sending any HTTP response — no status line, no
headers, no body. The scanner sees only a connection reset or timeout.

Since real WebSocket clients (SSH injector, VMESS, VLESS, Trojan, v2ray/Xray)
**always** include `Upgrade: websocket` in their initial request, they pass
through normally. Only scanners/browsers/curl without the WebSocket header
get the silent disconnect.

---

## Rollback

Remove the added `if ($http_upgrade != "websocket") { return 444; }` lines
from each location block, then:

```bash
nginx -t && systemctl reload nginx
```

---

## Note

- This fix is included by default in **autoscript v0.2.1-beta+**.
- No extra packages or repos needed — `return 444` is built into Nginx.
- The `server_tokens off;` in `/etc/nginx/nginx.conf` already hides the
  Nginx version number from the `Server` header.
- The `/ssh` path is the safest payload path for SSH injector clients.
  If an injector configured with root path `/` gives a 400 error, switch
  it to the `/ssh` path.

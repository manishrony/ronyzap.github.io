# Securing the dashboard with Cloudflare (Tunnel + Access)

Goal: reach the Zappa1 dashboard at **https://dash.ronyzap.com**, gated so that
**only your email** can log in — with no port-forwarding, automatic HTTPS, and
**$0** cost. `www.ronyzap.com` stays on GitHub Pages as a public landing page.

**Cost:** Cloudflare DNS, Tunnel, and Zero Trust Access (free ≤ 50 users) are all
free. You do **not** transfer the domain — it stays registered at Hostinger; you
only repoint its **nameservers** to Cloudflare (free, reversible).

**What's already prepared in this repo**
- `index.html` (repo root) — the public landing page for www.ronyzap.com. Goes
  live when merged to `main` (GitHub Pages builds from `main`).
- `gpu-monitor/cloudflare/config.yml` — the tunnel config to drop on Zappa1.

You run the steps below (they need your Hostinger/Cloudflare logins and a shell
on Zappa1, which I can't access from here). ~15 minutes.

---

## Step 1 — Create Cloudflare account + add the domain

1. Sign up (free) at https://dash.cloudflare.com/sign-up.
2. **Add a site** → enter `ronyzap.com` → choose the **Free** plan.
3. Cloudflare scans your existing DNS records and imports them. **Verify** these
   exist (add any that are missing — values below assume GitHub Pages):
   - Type `CNAME`, name `www`, target `manishrony.github.io`, Proxy status **DNS
     only** (grey cloud). *(GitHub manages the Pages cert, so keep this grey.)*
   - Type `A`, name `ronyzap.com` (apex) → `185.199.108.153`, `185.199.109.153`,
     `185.199.110.153`, `185.199.111.153` (four A records), **DNS only**. *(Only
     if you want the bare apex to work too; www is what your CNAME file uses.)*
4. Cloudflare shows you **two nameservers** (e.g. `xxx.ns.cloudflare.com`). Copy
   them — you need them in Step 2.

## Step 2 — Point Hostinger's nameservers at Cloudflare

1. Log into Hostinger → **Domains** → `ronyzap.com` → **DNS / Nameservers**.
2. Choose **Use custom nameservers** and paste the two Cloudflare nameservers.
   (This does **not** move your registration or billing — the domain stays yours
   at Hostinger. It only delegates DNS to Cloudflare.)
3. Save. Back in Cloudflare, it can take anywhere from minutes to a few hours to
   flip to **Active**. You'll get an email. Continue to Step 3 meanwhile — the
   tunnel doesn't depend on the flip finishing.

## Step 3 — Install the tunnel on Zappa1

On **Zappa1** (the hub), as root:

```bash
# 1. Install cloudflared (Debian/Ubuntu amd64)
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb

# 2. Authenticate — opens a browser link; pick the ronyzap.com zone.
#    (On a headless rig, copy the printed URL to any browser and approve.)
sudo cloudflared tunnel login

# 3. Create the tunnel (name it "zappa"). Note the UUID it prints; it also
#    writes /root/.cloudflared/<UUID>.json (the tunnel's credentials).
sudo cloudflared tunnel create zappa

# 4. Route the hostname to this tunnel (creates the proxied dash.* DNS record
#    in Cloudflare automatically):
sudo cloudflared tunnel route dns zappa dash.ronyzap.com
```

Now install the config from this repo and start the service:

```bash
# From your repo clone on Zappa1 (branch: claude/gpu-rig-power-management-yo6oxs)
sudo mkdir -p /etc/cloudflared
sudo cp gpu-monitor/cloudflare/config.yml /etc/cloudflared/config.yml

# Put the real UUID into the config (replaces the two <TUNNEL-UUID> placeholders)
UUID=$(sudo cloudflared tunnel list | awk '/zappa/{print $1; exit}')
sudo sed -i "s|<TUNNEL-UUID>|$UUID|g" /etc/cloudflared/config.yml

# Run cloudflared as a boot service
sudo cloudflared service install
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared --no-pager
```

Sanity check: `sudo cloudflared tunnel info zappa` should show a healthy
connection. At this point https://dash.ronyzap.com reaches the dashboard — but
it's **not gated yet**. Do Step 4 before sharing the URL.

## Step 4 — Gate it with Cloudflare Access (email allowlist)

1. In the Cloudflare dashboard, open **Zero Trust** (left sidebar). First time
   only: pick a team name (any) and the **Free** plan.
2. **Access → Applications → Add an application → Self-hosted.**
   - **Application name:** `Zappa dashboard`
   - **Session duration:** e.g. `1 month`
   - **Public hostname:** subdomain `dash`, domain `ronyzap.com`.
   - Continue.
3. **Add a policy:**
   - **Policy name:** `Only me`
   - **Action:** Allow
   - **Include → Emails →** your email address (add more addresses to approve
     others later).
   - Save.
4. Finish. Identity method **One-time PIN** is on by default: visiting the URL
   emails you a 6-digit code, and only allowlisted emails are accepted. Done —
   the dashboard is now private.

**Optional — "Sign in with Google" instead of email PIN** (still free):
Zero Trust → **Settings → Authentication → Login methods → Add → Google**. You
create a free Google Cloud OAuth client (Cloudflare shows the exact redirect URL
to paste). Once added, the Access login page offers a Google button. The `Only
me` email policy still applies, so only your Google email gets in.

## Step 5 — Publish the landing page

`index.html` at the repo root is the public www.ronyzap.com page (links through
to the gated dashboard). It publishes when `main` updates, since GitHub Pages
builds from `main`. Merge this branch (or cherry-pick `index.html`) to `main`,
then confirm https://www.ronyzap.com shows the page and the **Operations
dashboard** button lands on the Cloudflare Access login.

---

## How this is secured

- **No open ports.** `cloudflared` makes an outbound connection to Cloudflare;
  your router exposes nothing. 8080 stays LAN-only.
- **Access sits in front of the tunnel.** Every request to dash.ronyzap.com must
  pass the email allowlist before it ever reaches Zappa1.
- **HTTPS is automatic** (Cloudflare terminates TLS at the edge).
- The landing page on www.ronyzap.com is static and exposes **no** rig data.

## Troubleshooting

- **dash.ronyzap.com won't resolve:** the ronyzap.com zone must be **Active** in
  Cloudflare (Step 2 nameserver flip finished). Check the Overview page.
- **502/error page after login:** the dashboard isn't listening. On Zappa1:
  `systemctl status gpu-dashboard` and `curl -s localhost:8080 | head`.
- **`cloudflared` down:** `journalctl -u cloudflared -e --no-pager`.
- **Locked out / add another person:** Zero Trust → Access → Applications →
  Zappa dashboard → Policies → add the email.
- **Undo everything:** stop/uninstall cloudflared on Zappa1, delete the tunnel
  and Access app in Cloudflare, and set Hostinger nameservers back to Hostinger's
  defaults. Registration was never affected.

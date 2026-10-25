# mail_server - the mail server

VM 130 `mail`: the mail server of `deverenozcan.com` on Ubuntu Server 26.04,
at `10.10.20.10` in the DMZ. Postfix takes and sends mail, Dovecot keeps the
mailboxes and serves them over IMAP, rspamd filters spam. The mailboxes are
the Active Directory users ([../samba_ad](../samba_ad/README.md)): people sign
in with their address and their AD password.

| Path | What it is |
|---|---|
| `site.yml` | the playbook: serial console, packages, the data volume, then each service |
| `host_vars/mail.yml` | every setting: the domain, the directory, the data volume, which secrets come from `.env` |
| `inventory.yml` | how the controller reaches it: `ubuntu@10.10.20.10` over SSH |
| `roles/` | `serial_console`, `mail_base`, `data_volume`, `rspamd`, `cloudflared`, `webmail`, `certificate`, `dovecot`, `postfix`, `mail_receiver` |
| `terraform/` | VM 130 and VM 9130, which holds its data disk |
| `cloudflare/` | the way in on Cloudflare: tunnel, Access, the Email Worker (`worker/`), Email Routing; its own Terraform state |
| `.env` | the secrets (git-ignored; `.env.example` shows the format) |
| `ansible.cfg`, `requirements.yml` | Ansible settings and the collections the roles need |

**Status (2026-10-25):** the server, the Cloudflare side and webmail run,
and every address of the domain comes to the server: Email Routing's
catch-all hands it all to the Worker ([Switching mail over](#switching-mail-over)).
Sending to the internet is not set up ([Sending](#sending)). The one mailbox is
`admin@deverenozcan.com` (the AD account `eren.ozcan`), which also gets
`postmaster@` and `abuse@`; `eren.ozcan@deverenozcan.com` is not a mailbox
here - Cloudflare forwards it to its owner's own mailbox.

## How mail gets in

The home connection is behind the ISP's carrier-grade NAT: the router's own
WAN address is `10.227.57.212`, the internet sees `176.88.142.161` - a port
forwarded on the router never reaches it. So nothing here listens to the
internet. Mail comes in through Cloudflare, which already holds the domain's
MX records:

```
sender ─▶ MX: Cloudflare Email Routing
            └─ catch-all ─▶ Email Worker
                  POSTs each message, raw, with the shared secret,
                  to the tunnel's hostname (Cloudflare Access in front)
                     │
               Cloudflare Tunnel ── cloudflared on this server dials out
                     ▼
VM 130: receiver 127.0.0.1:8025 ─▶ Postfix 127.0.0.1:25 ─▶ rspamd
                                         └─ LMTP ─▶ Dovecot ─▶ /var/vmail
                                    mailboxes ◀── LDAPS ── dc1 (AD)
```

- **The receiver** (`roles/mail_receiver`, a short Python program) answers
  with what Postfix said: `200` queued, `422` refused for good (an unknown
  address, spam), `503` refused for now. The Worker turns a `422` into a
  rejection, so the sender gets a bounce; `files/receiver.py` has the whole
  protocol.
- **Nothing leaves the server unasked.** cloudflared dials out to Cloudflare
  (the DMZ may reach the internet, firewall rule DMZ 40); the receiver and
  Postfix's port 25 listen on 127.0.0.1 only.
- **The Worker** (`cloudflare/worker/mail-inbound.js`) delivers on `200
  queued`, rejects on `422`, and on anything else - the server down, busy,
  unreachable, Access in the way - forwards the message to a fallback
  address, so nothing is lost. `mail-inbound.test.mjs` tests those
  decisions without Cloudflare (`node mail-inbound.test.mjs`).
- **Only the Worker gets to the receiver.** Cloudflare Access stops every
  other request for `mx-in.deverenozcan.com` at the edge (a service token,
  which never expires); the receiver checks its own shared secret behind
  that.

## Setting up the way in

All of it is `cloudflare/`, a Terraform configuration of its own, so the VM's
state and the Proxmox password stay out of it. Nothing there changes where
mail goes until you say so: the tunnel, Access and the Worker come first,
then one test address, then everything.

### The API token

Cloudflare dashboard → My Profile → API Tokens → Create Token → Custom token.
Account resources: your account; zone resources: `deverenozcan.com`.

| Scope | Permission | For |
|---|---|---|
| Account | Cloudflare Tunnel: Edit | the tunnel and its routes |
| Account | Access: Apps and Policies: Edit | the Access application and policy |
| Account | Access: Service Tokens: Edit | the Worker's service token |
| Account | Workers Scripts: Edit | the Worker |
| Account | Email Routing Addresses: Read | checking the fallback address is verified |
| Zone | Zone: Read | finding the zone and the account |
| Zone | DNS: Edit | the `mx-in` record |
| Zone | Email Routing Rules: Edit | the test rule and the catch-all |

Put it, with the fallback address, into `cloudflare/secret.tfvars`
(git-ignored; start from `secret.tfvars.example`). The fallback address has
to be a verified destination in Email Routing - the one today's rules forward
to will do.

If the account has never used Zero Trust, the dashboard asks once for a team
name and a plan (Free, up to 50 users) before Access and tunnels can be
created.

### The tunnel, Access and the Worker

From `cloudflare/`:

```bash
terraform init
```

```bash
terraform plan -var-file=secret.tfvars
```

```bash
terraform apply -var-file=secret.tfvars
```

Then hand cloudflared its token and start it, from this directory:

```bash
sed -i "s|^MAIL_CLOUDFLARED_TOKEN=.*|MAIL_CLOUDFLARED_TOKEN=$(terraform -chdir=cloudflare output -raw tunnel_token)|" .env
```

```bash
ansible-playbook site.yml --tags receiver,cloudflared
```

`systemctl status cloudflared-tunnel` on the server shows it connected.

### One address first

With a mailbox in place ([Using it](#using-it)), send one address of the
domain to the server while every other address keeps going where it went:

```bash
terraform -chdir=cloudflare apply -var-file=secret.tfvars -var test_address=jane.doe@deverenozcan.com
```

Write to it from an outside mailbox (Gmail): it lands in the mailbox. The
Worker's log (dashboard → Workers → mail-inbound → Logs) shows every
message that went to the fallback address instead, and why.

### Switching mail over

Done on 2026-10-25. `route_all_mail` is true by default since then, so every
run keeps the catch-all on the Worker; `-var route_all_mail=false` removes it.

An address with a rule of its own keeps that rule and never reaches the
server. `forward_to_fallback` (`cloudflare/variables.tf`) lists the ones
forwarded straight to the fallback address: `eren.ozcan@`, the owner's
address from before the server, adopted by `cloudflare/imports.tf`. Mail
written to it from inside - from webmail - is refused: on the server it is
not a mailbox, and the server cannot send anything out yet.

**Going back**, if the server cannot take the domain's mail: in the
dashboard set the catch-all to "Send to an email" with the fallback address.
Mail the server cannot take meanwhile already goes to the fallback address
by itself (the Worker).

## Webmail

`https://mail.deverenozcan.com` is Roundcube, in Turkish, from anywhere -
the same tunnel carries it (`cloudflare/main.tf`). People sign in with the
part of their address before the @ and their AD password, and can change the
password themselves (Settings → Password).

```
anywhere ─▶ https://mail.deverenozcan.com ─ Cloudflare (its certificate) ─ tunnel ─▶ nginx 127.0.0.1:8080
LAN      ─▶ https://mail.deverenozcan.com ─ the firewall answers 10.10.20.10 ─────▶ nginx :443 (Let's Encrypt)
                                     nginx ─▶ php-fpm ─▶ Roundcube ─▶ Dovecot :993, Postfix :587
```

- **The sign-in faces the internet**, as on any webmail - not behind Cloudflare
  Access. Roundcube allows 3 failed tries a minute, and AD locks an account
  for 15 minutes after 10 wrong passwords (`../samba_ad`, password policy).
- **The server's certificate** is Let's Encrypt's, for `mail.deverenozcan.com`:
  what IMAP, submission and webmail from the LAN present (`roles/certificate`).
  Let's Encrypt checks the name over HTTP, which public DNS sends through the
  tunnel to nginx - so no DNS token lives on the server, and `certbot.timer`
  renews it the same way, reloading Postfix, Dovecot and nginx.
- **Roundcube's database** - settings, address books - is an SQLite file on
  the data disk.

## How it is put together

- **The VM.** Ubuntu's 26.04 cloud image, 2 vCPU, 3 GB, a 20 GB OS disk;
  cloud-init sets `10.10.20.10/24` via `10.10.20.1`, the name
  `mail.deverenozcan.com` and the controller's SSH key. Everything else is
  `site.yml`.
- **The data disk.** 40 GB on the host's `vmdata`, owned by VM 9130
  (`data-130`), which is never started. `/var/vmail` (the mailboxes),
  `/var/lib/rspamd` and `/var/lib/redis` (what the spam filter has learnt)
  are bound onto it, so a rebuilt VM gets them back. The mailboxes belong to
  `vmail`, uid 5000, fixed so the numbers on the disk stay right; the
  packages' own users get whatever IDs are free, so the roles hand their
  directories back to them on every run.
- **Mailboxes from Active Directory.** An address is a mailbox when an
  enabled AD user in the group `Mail Users` has it as `mail`. Postfix and
  Dovecot look it up as `svc-mail` over LDAPS (`ldaps://dc1.ad.deverenozcan.com`;
  `/etc/hosts` has the name, the DMZ's resolver does not know the AD domain)
  and trust only the CA Samba made for the DC (`mail_ad_ca_cert`). That
  connection is the one way from the DMZ into the LAN (firewall rule DMZ 25).
  Dovecot checks a password by binding as the user.
- **Postfix** (`roles/postfix`): port 25 on 127.0.0.1 takes mail for the
  domain from the receiver and refuses unknown addresses there and then.
  Port 587 is for people: TLS, signed in, and only as their own address.
  `postmaster@` and `abuse@` go to `mail_admin_address`.
- **Dovecot 2.4** (`roles/dovecot`): IMAP over TLS on 993 only, LMTP for
  Postfix. One configuration file, written whole. **2.4 renamed most
  settings**; guides written for 2.3 do not apply - `doveconf -n` shows what
  Dovecot made of it.
- **rspamd** (`roles/rspamd`): scores every message. Above 6 it is marked
  `X-Spam: Yes` and a sieve script files it into Junk; above 15 it is
  refused. No greylisting: the Worker cannot try again later. The checks of
  the connecting client (SPF, HELO) do not apply - every message reaches
  Postfix from 127.0.0.1, which rspamd recognises by itself; Cloudflare
  checked SPF when it took the message.
- **TLS**: Let's Encrypt's certificate for `mail.deverenozcan.com`
  ([Webmail](#webmail)); Ubuntu's self-signed one only until it exists. Mail
  from the internet does not need it: TLS ends at Cloudflare, and the tunnel
  carries it from there.

## Sending

Not set up. Mail to an address outside the domain is refused when it is
submitted, with "Sending mail outside deverenozcan.com is not set up yet".
The home connection cannot send it itself (outgoing port 25 is blocked, and
there is no reverse DNS); the plan is Cloudflare's Email Sending (Workers
Paid) as Postfix's relay, with SPF, DKIM and DMARC records for the domain.

## Running it

From this directory, on the controller, with the repo's venv active:

```bash
ansible-playbook site.yml --check --diff
```

```bash
ansible-playbook site.yml
```

`--tags console|base|data|rspamd|cloudflared|webmail|certificate|dovecot|postfix|receiver`
runs one part. Terraform, from `terraform/`:

```bash
terraform plan -var-file=secret.tfvars
```

`terraform test` checks the planned VM against a mock provider, without the
host.

### Secrets

In `.env` here (git-ignored; start from `.env.example`):

| Key | What it is |
|---|---|
| `MAIL_LDAP_PASSWORD` | the password of `svc-mail`. The same value is `SAMBA_SVC_MAIL_PASSWORD` in `../samba_ad/.env`, which creates the account |
| `MAIL_RECEIVER_SECRET` | shared with the Email Worker; the receiver refuses mail without it |
| `MAIL_ROUNDCUBE_DES_KEY` | Roundcube's key for what it keeps encrypted in sessions, 24 characters (`openssl rand -hex 12`) |
| `MAIL_CLOUDFLARED_TOKEN` | the tunnel's token (`terraform -chdir=cloudflare output -raw tunnel_token`); empty until the tunnel exists, and cloudflared stays off until then |

And in `cloudflare/secret.tfvars`: the Cloudflare API token and the fallback
address. The Worker's copy of the receiver's secret is read from `.env` here.

## Building it from nothing

Before this: the firewall carries rule DMZ 25 and the `mail` host override
(`../firewall`), and the domain controller has `svc-mail` and `Mail Users`
(`../samba_ad`, tag `accounts`). The Ubuntu 26.04 cloud image is on the host
(`../samba_ad/README.md`, "The disk image").

1. **Secrets.** Both passwords and the receiver's secret:

   ```bash
   PW="Aa1-$(openssl rand -hex 20)"
   printf 'MAIL_LDAP_PASSWORD=%s\nMAIL_RECEIVER_SECRET=%s\nMAIL_CLOUDFLARED_TOKEN=\n' "$PW" "$(openssl rand -hex 32)" > .env
   printf 'SAMBA_SVC_MAIL_PASSWORD=%s\n' "$PW" >> ../samba_ad/.env
   ```

2. **The VM**, from `terraform/`:

   ```bash
   terraform init
   ```

   ```bash
   terraform apply -var-file=secret.tfvars
   ```

   **Never start `data-130`:** it only holds the disk.

3. **The configuration**, once `ssh ubuntu@10.10.20.10 true` works:

   ```bash
   ansible-playbook site.yml --check --diff
   ```

   On a fresh VM the dry run stops after the packages with a note. Then:

   ```bash
   ansible-playbook site.yml
   ```

## Using it

**A mailbox for someone** - the admin's (`mail_admin_address`) first - on
the DC (`ssh ubuntu@10.10.10.10`):

```bash
sudo samba-tool user create jane.doe --mail-address=jane.doe@deverenozcan.com
sudo samba-tool group addmembers "Mail Users" jane.doe
```

An existing user gets an address with `sudo samba-tool user edit jane.doe`
(the `mail:` line). The mailbox appears with the first message.

**Changing someone's address** changes their sign-in too (it is `mail`), and
the mailbox follows the address: move the directory, or they start empty -
on the mail server, `sudo mv /var/vmail/deverenozcan.com/OLD /var/vmail/deverenozcan.com/NEW`.
Roundcube keeps settings per address, so they start from its defaults.

**Webmail**: `https://mail.deverenozcan.com`, from anywhere.

**Mail clients**, from the LAN: IMAP `mail.deverenozcan.com:993` (TLS),
SMTP `mail.deverenozcan.com:587` (STARTTLS), user name the full address. The
firewall answers that name with `10.10.20.10` inside. From the home network
and from outside, IMAP and SMTP are not reachable yet - webmail is; clients
would need Cloudflare Zero Trust (WARP).

## Checking it

On the server:

```bash
sudo doveconf -n | head                           # Dovecot read the file
sudo postmap -q jane.doe@deverenozcan.com proxy:ldap:/etc/postfix/ldap-users.cf
sudo doveadm user jane.doe@deverenozcan.com       # the mailbox's home
systemctl is-active postfix dovecot rspamd redis-server mail-receiver
```

A message through the receiver, as the Worker will send it - on the server,
since the receiver listens on 127.0.0.1 only (`SECRET` is
`MAIL_RECEIVER_SECRET` from `.env`):

```bash
curl -H "X-Receiver-Secret: $SECRET" -H "X-Envelope-From: someone%40example.org" \
     -H "X-Envelope-To: jane.doe%40deverenozcan.com" --data-binary @message.eml \
     http://127.0.0.1:8025/inbound                # 200 queued
```

## Good to know

- **Webmail was checked** (2026-10-25) through Cloudflare with a temporary
  AD user and its own password policy (both deleted afterwards): sign-in,
  the inbox, a password change accepted ("Kaydedildi") and the new password
  taken by Dovecot, one refused by the domain's history, one by Roundcube's
  minimum length; Let's Encrypt's certificate on 993, 587 and 443, and
  `certbot renew --dry-run`.
- **How this was checked** (2026-10-23), before it ran anywhere: the rendered
  configuration in an `ubuntu:26.04` container with the same packages -
  `postfix check`, `doveconf -n`, `rspamadm configtest`, `sievec` - and the
  whole chain: receiver → Postfix → rspamd → LMTP → Dovecot → Junk by
  sieve; 403 without the secret, 422 for an unknown address and for spam,
  503 with Postfix down; submission on 587 only signed in and only as one's
  own address; LDAPS to the real DC with the right CA (the bind failed, as
  it must, before `svc-mail` existed). On the built server, with a
  temporary AD user (deleted afterwards): the mailbox lookup, sign-in with
  the AD password and a wrong one, delivery through the receiver, IMAPS,
  587, the refusal of outside addresses; then a reboot.
- **Dovecot's LDAP connection trusts the CA in `/etc/ldap/ldap.conf`.** It
  goes through libldap, which ignores Dovecot's own `ssl_client_ca_file`;
  with only that set, Dovecot "Can't connect" to the DC while Postfix can.
  `mail_base` writes the AD CA there.
- **The certificate is chosen for every run.** `site.yml` picks Let's
  Encrypt's in its pre_tasks, so `--tags postfix` and the like keep it - a run
  of one role once put Postfix back on the self-signed one for a few minutes
  (2026-10-25).
- **Changing a password in webmail is a change, not a reset.** Roundcube's
  `ldap_samba_ad` driver replaces `unicodePwd`, which AD allows only an
  administrator ("Insufficient access" for users). `roles/webmail` ships its
  own driver (`files/ldap_samba_ad_change.php`) that removes the old value
  and adds the new one as the user - AD's change - so the domain's policy
  applies: a password set by an administrator can be changed the next day
  (minimum age 1 day), not to one of the last 24, and Samba still accepts the
  previous one for 60 minutes afterwards (`old password allowed period`).
- **Roundcube on PHP 8.5.** Ubuntu 26.04's Roundcube 1.6.11 declares
  `array_first()`, which PHP 8.5 now has itself: every page failed with
  "Cannot redeclare function". `roles/webmail` applies Roundcube's own fix
  (its 1.6 branch declares the function only when PHP lacks it) to the
  packaged file, and does nothing once Ubuntu ships it. PHP 8.5 also logs
  "Using null as an array offset is deprecated" from Roundcube's database
  layer into `/var/log/roundcube/errors.log`: noise, not a fault, until the
  package catches up.
- **Turkish text and rspamd.** `R_MIXED_CHARSET` weighs 5.0 by default and
  scored "Teşekkürler, Şükrü Işık" 3.75 on its own; it is lowered to 1.0
  (`files/local.d/groups.conf`).
- **The DC's certificate expires on 2028-09-21.** Samba generated it with
  the domain. When it is renewed, put the new CA into `mail_ad_ca_cert`.
- **Strings that land on the server are not cosmetic.** Every file names its
  role; editing a role's text rewrites the file and restarts the service.

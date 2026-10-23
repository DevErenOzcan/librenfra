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
| `roles/` | `serial_console`, `mail_base`, `data_volume`, `rspamd`, `dovecot`, `postfix`, `mail_receiver`, `cloudflared` |
| `terraform/` | VM 130 and VM 9130, which holds its data disk |
| `.env` | the secrets (git-ignored; `.env.example` shows the format) |
| `ansible.cfg`, `requirements.yml` | Ansible settings and the collections the roles need |

**Status: built on 2026-10-23, waiting for the Cloudflare side.** The server
runs and delivers mail inside the domain; mail from the internet arrives once
the Worker and the tunnel exist ([How mail gets in](#how-mail-gets-in)), and
sending to the internet is not set up ([Sending](#sending)). No mailbox
exists yet - not even `mail_admin_address`'s, so mail to `postmaster@`
bounces until it does.

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
- **The Cloudflare side - the Worker, the tunnel, Access, the routing rule -
  is not written yet.** Until then, Cloudflare Email Routing forwards the
  domain's mail as it does today.

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
- **TLS**: Ubuntu's self-signed certificate for now, so mail clients warn
  once. A real certificate for `mail.deverenozcan.com` comes with the
  Cloudflare side (Let's Encrypt, DNS-01).

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

`--tags console|base|data|rspamd|dovecot|postfix|receiver|cloudflared` runs
one part. Terraform, from `terraform/`:

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
| `MAIL_CLOUDFLARED_TOKEN` | the tunnel's token; empty until the tunnel exists, and cloudflared stays off until then |

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

**Mail clients**, from the LAN: IMAP `mail.deverenozcan.com:993` (TLS),
SMTP `mail.deverenozcan.com:587` (STARTTLS), user name the full address. The
firewall answers that name with `10.10.20.10` inside. From the home network
and from outside the firewall lets nothing in yet; that comes with Cloudflare
Zero Trust.

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
- **Turkish text and rspamd.** `R_MIXED_CHARSET` weighs 5.0 by default and
  scored "Teşekkürler, Şükrü Işık" 3.75 on its own; it is lowered to 1.0
  (`files/local.d/groups.conf`).
- **The DC's certificate expires on 2028-09-21.** Samba generated it with
  the domain. When it is renewed, put the new CA into `mail_ad_ca_cert`.
- **Strings that land on the server are not cosmetic.** Every file names its
  role; editing a role's text rewrites the file and restarts the service.

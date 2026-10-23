# librenfra

The infrastructure of a small organisation, as code: the machines that run on
the Proxmox host `pve1` (`192.168.1.200`) besides the desktop. The host itself
and the desktop that manages everything live in the **ProxmoxHomeLab**
repository.

| Directory | Machine | Managed with |
|---|---|---|
| [`firewall/`](firewall/README.md) | VM 100 `opnsense-fw`: OPNsense, WAN `192.168.1.201`, gateway of LAN, DMZ and LAB | Terraform (the VM), Ansible over the OPNsense API (the policy) |
| [`samba_ad/`](samba_ad/README.md) | VM 120 `dc1`: Samba AD domain controller for `ad.deverenozcan.com`, `10.10.10.10`, and VM 9120 that holds its data | Terraform and Ansible |
| [`mail_server/`](mail_server/README.md) | VM 130 `mail`: Postfix, Dovecot and rspamd for `deverenozcan.com`, `10.10.20.10` in the DMZ, mailboxes from AD, mail in through Cloudflare (not set up yet); VM 9130 holds its data | Terraform and Ansible |

**Each directory stands on its own.** It has its own `ansible.cfg`,
inventory, settings, roles, Terraform and secrets, and every command for that
machine runs from inside it. Nothing is shared between them.

```
firewall/                  cd firewall && ansible-playbook site.yml --check --diff
  site.yml                   the playbook
  host_vars/firewall.yml     every setting for the machine
  inventory.yml              how to reach it
  roles/                     one role per concern
  terraform/                 the VM: cd terraform && terraform plan -var-file=secret.tfvars
  README.md                  what it does, how to build it from nothing

samba_ad/                  cd samba_ad && ansible-playbook site.yml --check --diff
  site.yml, host_vars/dc1.yml, inventory.yml, roles/, terraform/, README.md
```

## The network

```
internet ── home router 192.168.1.1
                 │  home network 192.168.1.0/24
                 ├── pve1, the Proxmox host     192.168.1.200
                 ├── ubuntu-desktop (VM 102)    192.168.1.202   the controller
                 └── opnsense-fw (VM 100)       192.168.1.201   firewall/
                           │
         ┌─────────────────┼─────────────────┐
   vmbr1 LAN           vmbr2 DMZ          vmbr3 LAB
   10.10.10.0/24       10.10.20.0/24      10.10.30.0/24
   trusted             faces the          experiments,
   dc1 .10             internet           quarantine
                       mail .10
```

The segments are bridges inside the host; the firewall is their only way out.
The LAN is trusted and reachable from home; DMZ and LAB reach the internet
and nothing else - except the mail server's LDAPS lookups on the DC. The
rules are in [firewall/README.md](firewall/README.md).

The home connection is behind the ISP's carrier-grade NAT, so nothing here
can be reached from the internet directly, and no port forward would change
that. What has to come in does through Cloudflare, which holds the domain:
mail through Email Routing and a tunnel ([mail_server/README.md](mail_server/README.md)).

VM IDs: the firewall is 100, the desktop 102; servers get their own (the DC
120, the mail server 130), and a server's data disk is held by VM 9000 + its
ID.

## The controller

Everything runs from the `ubuntu-desktop` VM, on the home network next to the
host, with the route `10.10.0.0/16 via 192.168.1.201` into the segments
(ProxmoxHomeLab sets both up). The checkouts live in its `/home`, on a
persistent data disk, so the Terraform state and the secrets survive a
rebuilt desktop.

```
ubuntu-desktop (192.168.1.202)
  terraform ──────── HTTPS ────▶ pve1:8006 (Proxmox API)        */terraform/
  ansible-playbook ─ HTTPS ────▶ opnsense-fw:443 (OPNsense API) firewall/
                   ─ SSH ──────▶ dc1 (10.10.10.10)              samba_ad/
                   ─ SSH ──────▶ mail (10.10.20.10)             mail_server/
```

### Setting up the controller

Once, from the repo root. Ansible is not installed system-wide: the repo has
its own environment in `.venv`.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Activate it (`. .venv/bin/activate`) before running anything. Each directory
lists the collections its roles need:

```bash
ansible-galaxy collection install -r firewall/requirements.yml -r samba_ad/requirements.yml -r mail_server/requirements.yml
```

Terraform comes with the desktop's packages. The controller's SSH key,
`~/.ssh/id_ed25519`, is the one cloud-init puts on the servers.

### Secrets

All stay on the controller and are git-ignored; each directory's README says
how to make them, and an `.example` file next to each shows the format.

| File | Holds |
|---|---|
| `*/terraform/secret.tfvars` | the host's root password, for the Proxmox API |
| `*/terraform/terraform.tfstate` | what Terraform manages - not secret, but only here |
| `firewall/.env` | the OPNsense API key |
| `samba_ad/.env` | the domain's Administrator password, and the passwords of the service accounts it creates |
| `mail_server/.env` | `svc-mail`'s password (the same as in `samba_ad/.env`), the receiver's shared secret, the tunnel token |

Keep a copy of all of them, and of `~/.ssh/id_ed25519`, off the laptop: the
desktop's data disk is persistent, not backed up.

## Order, from nothing

1. ProxmoxHomeLab: the host (with `vmbr1`-`vmbr3` and the `vmdata` storage),
   then the desktop as the controller.
2. [firewall/README.md](firewall/README.md): the firewall.
3. [samba_ad/README.md](samba_ad/README.md): the domain controller.
4. [mail_server/README.md](mail_server/README.md): the mail server.

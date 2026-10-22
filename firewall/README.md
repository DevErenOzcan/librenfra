# firewall - the OPNsense firewall

VM 100 `opnsense-fw`: OPNsense 26.7, the router and firewall every internal
segment goes through. Its WAN leg is on the home network at `192.168.1.201`;
LAN, DMZ and LAB are bridges that exist only inside the Proxmox host.

| Path | What it is |
|---|---|
| `site.yml` | the playbook: the firewall's policy over its REST API, run on the controller |
| `host_vars/firewall.yml` | every setting: aliases, filter rules, DNS, DHCP, and the baseline that is only checked |
| `inventory.yml` | the API address; nothing connects over SSH |
| `roles/opnsense_config/` | how the settings are written and checked |
| `terraform/` | VM 100 itself, with its four NICs in a fixed order |
| `.env` | the API key (git-ignored; `.env.example` shows the format) |
| `ansible.cfg`, `requirements.yml` | Ansible settings and the collection the role needs |

## How it is put together

The host has one wired NIC, so the firewall is a **router on a stick**: WAN
sits on the home network next to the host, and each segment is a port-less
bridge (`vmbr1`-`vmbr3`, created by ProxmoxHomeLab's `host/`). The host itself
stays outside the firewall on purpose: if the firewall dies, the Proxmox UI at
`https://192.168.1.200:8006` - and with it the firewall's console - is still
there.

```
internet ── home router 192.168.1.1
                 │  home network 192.168.1.0/24, not behind the firewall
                 ├── Proxmox host           192.168.1.200
                 ├── ubuntu-desktop         192.168.1.202   the controller
                 └── OPNsense WAN           192.168.1.201   vmbr0, vtnet0
                           │
         ┌─────────────────┼─────────────────┐
       vmbr1             vmbr2             vmbr3
   LAN 10.10.10.1    DMZ 10.10.20.1    LAB 10.10.30.1
   trusted           faces the         experiments,
                     internet          quarantine
```

All three segments sit in `10.10.0.0/16`, so a machine on the home network
reaches them with one route: `10.10.0.0/16 via 192.168.1.201`. The home router
cannot hold it, so it lives on the machines that need it - the controller's
network profile has it.

### The VM

`terraform/main.tf` mirrors VM 100 as it runs, and adopts it with an import
block. What matters:

| Proxmox | OPNsense | Bridge | Interface | Address |
|---|---|---|---|---|
| net0 | `vtnet0` | `vmbr0` | WAN (`wan`) | `192.168.1.201/24`, gateway `192.168.1.1` |
| net1 | `vtnet1` | `vmbr1` | LAN (`lan`) | `10.10.10.1/24` |
| net2 | `vtnet2` | `vmbr2` | DMZ (`opt1`) | `10.10.20.1/24` |
| net3 | `vtnet3` | `vmbr3` | LAB (`opt2`) | `10.10.30.1/24` |

**The NIC order is the interface assignment.** Appending a NIC is safe;
reordering the `network_device` blocks rewires a running firewall. The
firewall starts first (startup order 1) and holds every other guest back 45
seconds, so nothing boots without a gateway.

### The policy

Asymmetric on purpose:

- **LAN is trusted.** It reaches everything - the home network (NATed as
  `192.168.1.201`), the firewall, DMZ, LAB, the internet - and the home
  network reaches it.
- **DMZ and LAB reach the internet and nothing else.** Nothing there can open
  a connection into the LAN, the home network or the other segment.
- **From home, only the LAN is reachable**, plus SSH from the controller into
  the DMZ. LAB machines are reached through a LAN machine.

| Interface | seq | Action | Source | Destination | Port |
|---|---|---|---|---|---|
| WAN | 10 | pass | `HOME_LAN` | this firewall | TCP 443 (web UI) |
| WAN | 11 | pass | `HOME_LAN` | 10.10.10.0/24 | any |
| WAN | 12 | pass | `HOME_LAN` | this firewall | TCP 22 |
| WAN | 13 | pass | `MGMT_WORKSTATION` | 10.10.20.0/24 | TCP 22 |
| LAN | 50 | pass | 10.10.10.0/24 | any | any, not logged |
| DMZ, LAB | 10 | pass | the segment | its gateway | TCP/UDP 53 |
| DMZ, LAB | 20 | **block** | the segment | `HOME_LAN` | any |
| DMZ, LAB | 30 | **block** | the segment | `LAB_NETS` | any |
| DMZ, LAB | 40 | pass | the segment | any | any |

`HOME_LAN` is `192.168.1.0/24`, `LAB_NETS` is `10.10.0.0/16` (the gateways
included, so sequence 30 also drops ping to them), and `MGMT_WORKSTATION` is
the controller, `192.168.1.202`. Whatever no rule passes falls to OPNsense's
default block. Two guests on the same DMZ or LAB never reach the firewall -
their frames stay in the bridge - so the host drops them instead
(ProxmoxHomeLab, `host/`, guest isolation).

Outbound NAT is on Automatic: traffic to the internet and the home network
leaves as `192.168.1.201`. No port forwards anywhere.

### DNS and DHCP

The segments cannot ask the home router, so **Unbound** on the firewall
answers them on port 53 and forwards everything to `192.168.1.1`.
**Dnsmasq** does DHCP only - its DNS port is moved to 53053 - on the two
segments with a pool: LAN `10.10.10.100-245` and LAB `10.10.30.100-199`. The
DMZ has none; its guests are cloud images with addresses cloud-init sets. So
does every server on the LAN (the domain controller is `10.10.10.10`), so
there are no DHCP reservations.

### What the API cannot write

Assigning NICs, interface addresses, the WAN gateway, the hostname and sshd
are console and GUI settings ([Building it from nothing](#building-it-from-nothing)).
`host_vars/firewall.yml` declares them as `opnsense_baseline_*`, and every run
reads them back and stops before writing anything if one differs.

## Running it

From this directory, on the controller, with the repo's venv active.

**Take a configuration backup first.** OPNsense 26.7 has no API rollback, so
a run that goes wrong is undone by restoring the backup: System →
Configuration → Backups → Download configuration. Keep the file off the
firewall; it holds password hashes.

```bash
ansible-playbook site.yml --check --diff
```

```bash
ansible-playbook site.yml
```

The dry run is a real difference report: the baseline checks are reads, and
the modules compare without writing. A converged firewall reports
`changed=0`.

**Descriptions are match keys.** A rule or a DHCP reservation is found on the
firewall by its description, character for character. Change one and the
next run adds a second object beside the first; to rename, change it and put
the old text into `opnsense_unused_rules` or
`opnsense_unused_dhcp_reservations`, which remove it after the new one is
written. Rules made in the GUI are left alone - and the ones written here are
evaluated ahead of them.

Terraform, from `terraform/`:

```bash
terraform plan -var-file=secret.tfvars
```

`secret.tfvars` holds the host's root password; start from
`secret.tfvars.example`. A plan against the running firewall shows no
changes.

### The API key

`site.yml` reads it from `.env` here. To make one: GUI → System → Access →
Users → `root` → edit → API keys → **+**. The browser downloads a file with a
`key` and a `secret`; copy both into `.env` as in `.env.example`, then delete
the download.

## Building it from nothing

Before this: the host is converged (ProxmoxHomeLab, `host/`), so `vmbr1`-
`vmbr3` exist.

### 1. The installer

The VM boots the installer from `local:iso/opnsense-26.7-dvd-amd64.iso`
(`installer_iso` in `terraform/variables.tf`). Check with
`pvesm list local --content iso` on the host. If it is not there: Datacenter
→ proxmox → local → ISO Images → Download from URL, with

| Field | Value |
|---|---|
| URL | `https://mirrors.dotsrc.org/opnsense/releases/26.7/OPNsense-26.7-dvd-amd64.iso.bz2` |
| File name | `opnsense-26.7-dvd-amd64.iso` |
| Decompression | `bzip2` |
| Checksum | SHA-256 `95cafedda6d5b22ce832e249dc2309110fbee19f813ad78cf28bb3d387186bfb` |

The checksum is the compressed file's, from `OPNsense-26.7-checksums-amd64.sha256`
on the same mirror: Proxmox checks the download before it decompresses it.

### 2. Create the VM with its WAN unplugged

> **WAN has to start unplugged.** A fresh OPNsense comes up as LAN
> `192.168.1.1/24` with a DHCP server. On `vmbr0` it answers for the home
> router's address and hands out its own leases, and the whole house loses
> the internet - it happened here on 2026-09-09.

In `terraform/`, delete `imports.tf` (there is no VM 100 to adopt), then:

```bash
terraform init
```

```bash
terraform apply -var-file=secret.tfvars -var wan_connected=false
```

### 3. Install

Open the VM's console in the Proxmox UI. In the live system, log in as
`installer`, password `opnsense`, run the guided install to the disk (the
defaults are fine), set the root password and reboot. The disk is first in
the boot order, so the VM now boots the installed system.

### 4. Assign and address the interfaces

At the console menu, **1) Assign interfaces**: no LAGGs, no VLANs, then WAN
`vtnet0`, LAN `vtnet1`, Optional 1 `vtnet2`, Optional 2 `vtnet3`.

Then **2) Set interface IP address** for each, with the addresses in the
table under [The VM](#the-vm). For WAN: no DHCP, `192.168.1.201`, bit count
`24`, upstream gateway `192.168.1.1` (the console calls it `WAN_GW`), use it
as the name server too, no DHCP6, keep HTTPS. Say no to a DHCP server on every
interface: the playbook sets up Dnsmasq.

### 5. Plug the WAN in

WAN is `192.168.1.201` now, not `192.168.1.1`:

```bash
terraform apply -var-file=secret.tfvars
```

### 6. The web UI, the first time

The anti-lockout rule exists on the LAN only, and WAN blocks everything
inbound, so nothing can reach the UI yet. At the console, **8) Shell**, and
turn the packet filter off until the next reboot:

```
pfctl -d
```

Browse to `https://192.168.1.201` from the home network, log in as `root`,
skip the wizard, and set what the API cannot:

| Where | Setting | Value |
|---|---|---|
| System → Settings → General | Hostname / Domain | `OPNsense` / `internal` |
| System → Settings → General | Time zone | `Etc/UTC` |
| System → Settings → General | DNS servers | `192.168.1.1` |
| System → Settings → General | Allow DNS server list to be overridden by DHCP/PPP on WAN | on |
| System → Settings → Administration | Secure Shell: enabled, root login, password login | on |
| Interfaces → WAN | Block private networks | **off** |
| Interfaces → WAN | Block bogon networks | on |

*Block private networks* must stay off: WAN **is** a private network here,
and the checkbox drops it ahead of every WAN pass rule - it locked every home
client out on 2026-09-17.

### 7. Apply the configuration

Create [the API key](#the-api-key), then from this directory:

```bash
ansible-playbook site.yml --check --diff
```

```bash
ansible-playbook site.yml
```

Then turn the packet filter back on: `pfctl -e` at the console, or reboot the
VM. WAN sequence 10 keeps the UI reachable from home from now on. A second
dry run reports `changed=0`.

### 8. Check it

From the controller:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.1.201    # 200
ping -c1 10.10.10.1                                                 # the LAN gateway
```

From a guest on the DMZ or the LAB, both of these must **fail**:

```bash
ping -c2 -W2 192.168.1.1; ping -c2 -W2 10.10.10.1
```

If one answers, sequence 20 or 30 on that interface is missing.

## When the firewall is down

The guests lose their network - by design. What stays:

- the Proxmox UI, `https://192.168.1.200:8006`, and through it the firewall's
  console: **8) Shell**, `pfctl -d`, fix, `pfctl -e`;
- SSH to the host. `ip addr add 10.10.10.2/24 dev vmbr1` there puts the host
  on the LAN for a while, so the firewall's UI and SSH answer on `10.10.10.1`
  even when WAN is locked; `ip addr del` it afterwards.

A configuration backup is restored from the console (**13) Restore a
backup**) or in the GUI.

## Good to know

- **Unreachable after a reboot, although the address is right?** Proxmox may
  have WAN unplugged: `qm config 100 | grep ^net0` shows `link_down=1`. That
  is what `-var wan_connected=false` does; apply without it.
- **"malformed chunk footer"** from the playbook: OPNsense 26.7.0 corrupted
  large API responses. Keep the firewall on 26.7.1 or later (it runs
  26.7.3).
- **The installer CD is not compared.** The provider reads the CD only from a
  slot it already has in its state, so an adopted VM never shows one;
  `terraform/main.tf` ignores it after creation.
- **More traffic insight**, none of it on: Reporting → NetFlow (Insight),
  Zenarmor (`os-sunnyvalley`), Services → Intrusion Detection (Suricata,
  IDS-only first). Raise the VM's memory to 8 GB in `terraform/main.tf`
  before turning all three on.

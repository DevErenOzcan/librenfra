# samba_ad - the Active Directory domain controller

VM 120 `dc1`: a Samba Active Directory domain controller on Ubuntu Server
26.04, at `10.10.10.10` on the LAN, for the domain `ad.deverenozcan.com`
(NetBIOS `AD`). It holds the organisation's user and group accounts, signs
members in with Kerberos, answers DNS for the domain and serves signed time.
Windows machines join it as they would a Windows DC; Linux machines with
`realmd`/`sssd`.

| Path | What it is |
|---|---|
| `site.yml` | the playbook: serial console, the data volume, then the domain controller |
| `host_vars/dc1.yml` | every setting: the domain, the DC's name and address, DNS forwarder, who gets time, the data volume |
| `inventory.yml` | how the controller reaches it: `ubuntu@10.10.10.10` over SSH |
| `roles/` | `serial_console`, `data_volume`, `samba_ad_dc` |
| `terraform/` | VM 120 and VM 9120, which holds its data disk |
| `.env` | the Administrator password, for the run that creates the domain (git-ignored; `.env.example` shows the format) |
| `ansible.cfg`, `requirements.yml` | Ansible settings and the collections the roles need |

**Status: written and checked, not built yet.** VM 120 and VM 9120 do not
exist; [Building it from nothing](#building-it-from-nothing) creates them.

## How it is put together

- **Why Samba.** It runs in well under 1 GB of RAM, needs no licence, and is
  a cloud image like every other server here. What it cannot do: Entra ID
  (Azure AD) Connect, which needs Windows Server; and functional levels above
  2008 R2 are newer in Samba than the rest, so the domain is created at 2008
  R2.
- **The VM.** Ubuntu's 26.04 cloud image, 2 vCPU, 2 GB, a 20 GB OS disk. cloud-init
  sets the static address `10.10.10.10/24` via `10.10.10.1` (outside the
  LAN's DHCP pool), the hostname `dc1` and the controller's SSH key for the
  `ubuntu` user, which has no password. Its display is the serial console;
  `serial_console` logs it in by itself.
- **The data disk.** The domain lives on a 10 GB disk on the host's `vmdata`
  storage, owned by VM 9120 (`data-120`) - which is never started - and
  attached to VM 120 as `scsi1`. Proxmox frees only a VM's own disks when it
  is destroyed, so VM 120 can be rebuilt and the disk stays. `/var/lib/samba`
  is bound onto it: the directory database, SYSVOL, the domain's keys. This
  matters more than for any other machine: **a DC rebuilt without it is a new
  domain**, with a new SID, and every joined machine falls out of it.
- **Name resolution.** Samba's own DNS answers for `ad.deverenozcan.com` and
  forwards everything else to Unbound on the firewall (`10.10.10.1`). The DC
  resolves through itself, so `systemd-resolved` is off - Samba needs port 53.
- **Time.** Kerberos fails beyond five minutes of clock skew, so members take
  their time from the DC: chrony serves `10.10.10.0/24` and signs through
  Samba's `ntp_signd` socket, which Windows members require.

## Running it

From this directory, on the controller, with the repo's venv active:

```bash
ansible-playbook site.yml --check --diff
```

```bash
ansible-playbook site.yml
```

`--tags console|data|samba` runs one part. A run on an existing DC needs no
password and reports nothing to change.

Terraform, from `terraform/`:

```bash
terraform plan -var-file=secret.tfvars
```

`secret.tfvars` holds the host's root password; start from
`secret.tfvars.example`. `terraform test` checks the planned VM against a mock
provider, without the host.

## Building it from nothing

Before this: the firewall runs and is configured ([../firewall](../firewall/README.md)).
The DC is on the LAN, which the controller reaches through WAN rule 11.

### 1. Decide the domain name

`samba_ad_dns_domain` in `host_vars/dc1.yml`. **It cannot be changed
afterwards** - renaming a Samba domain means building a new one. Use a
subdomain of a domain you own (here `ad.deverenozcan.com`), never `.local`,
and keep it out of public DNS. The realm is the same in capitals, and
`samba_ad_workgroup` is the short NetBIOS name Windows shows (`AD`).

### 2. The Administrator password

The domain is created with an `Administrator` account, whose password comes
from `.env` here - read only by the run that creates the domain. Samba wants
upper case, lower case and a digit; this gives all three:

```bash
printf 'SAMBA_ADMIN_PASSWORD=Aa1-%s\n' "$(openssl rand -hex 16)" >> .env
```

Keep a copy somewhere safe: it is the domain's first administrator.

### 3. The disk image

The OS disk is imported from `local:import/ubuntu-26.04-server-cloudimg-amd64.qcow2`
on the host (`os_image` in `terraform/variables.tf`). Check with
`pvesm list local --content import`. If it is not there: Datacenter → proxmox
→ local → Import → Download from URL, with
`https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-amd64.img`,
the SHA-256 from `SHA256SUMS` in the same directory, and the file name above
(`.qcow2`: the image is qcow2, and the import content type only accepts that
extension). The image only matters when the VM is created.

### 4. Create the VM

From `terraform/`:

```bash
terraform init
```

```bash
terraform apply -var-file=secret.tfvars
```

It creates the holder `data-120` with its 10 GB disk, then VM 120. **Never
start `data-120`:** it only holds the disk, and Proxmox's protection flag
keeps it from being removed by accident.

Give cloud-init a minute, then from the controller:

```bash
ssh ubuntu@10.10.10.10 true
```

### 5. Apply the configuration

```bash
ansible-playbook site.yml --check --diff
```

On a fresh VM the dry run stops after the packages with a note: nothing it
would check exists yet. Then:

```bash
ansible-playbook site.yml
```

It

1. turns on autologin on the serial console;
2. formats the blank data disk as ext4 `samba-data`, mounts it at `/mnt/data`
   and binds `/mnt/data/samba` over `/var/lib/samba`;
3. puts the DC's FQDN on its LAN address in `/etc/hosts` - and in the
   template cloud-init rewrites it from at every boot;
4. installs `samba-ad-dc`, the Kerberos tools and chrony;
5. **provisions the domain** - only when the data disk holds none - with
   Samba's internal DNS, RFC 2307 attributes and `10.10.10.1` as forwarder;
6. writes `smb.conf` (the settings provisioning wrote, kept by Ansible) and
   `/etc/krb5.conf`;
7. points the DC's resolver at itself and starts `samba-ad-dc`;
8. lets chrony serve signed time to `10.10.10.0/24`;
9. checks that the domain's LDAP SRV record points at `dc1`.

### 6. Check it

On the DC (`ssh ubuntu@10.10.10.10`):

```bash
host -t SRV _ldap._tcp.ad.deverenozcan.com          # dc1.ad.deverenozcan.com
host -t A dc1.ad.deverenozcan.com                   # 10.10.10.10
host -t A ubuntu.com                                # forwarded to the firewall
kinit administrator && klist                        # a ticket for AD.DEVERENOZCAN.COM
smbclient -L localhost -N                           # sysvol and netlogon
sudo samba-tool domain level show                   # 2008 R2
sudo chronyc clients                                # once members ask for time
```

## Using it

**Members use the DC as their DNS server.** A machine finds the domain through
its SRV records, which only the DC serves: point the member's DNS at
`10.10.10.10` before joining. The firewall's resolver does not know the
domain.

**Users and groups** with `samba-tool` on the DC, or with RSAT ("Active
Directory Users and Computers") from a Windows member:

```bash
sudo samba-tool user create jane.doe
sudo samba-tool group addmembers "Domain Admins" jane.doe
sudo samba-tool user list
```

**Group Policy** is edited with RSAT's Group Policy Management from a Windows
member; Samba keeps it in SYSVOL.

## Rebuilding the VM

When the OS is beyond repair, replace VM 120 - the domain stays on its data
disk. From `terraform/`:

```bash
terraform apply -var-file=secret.tfvars -replace=proxmox_virtual_environment_vm.dc
```

Then `ssh-keygen -R 10.10.10.10` and [step 5](#5-apply-the-configuration):
the playbook binds the disk's `/var/lib/samba` back, finds the domain there
and does not provision. The DC comes back with the same domain, accounts and
machine trusts.

**Back up the domain.** The data disk is persistent, not backed up: it lives
on one NVMe. Now and then, and before anything risky:

```bash
sudo mkdir -p /mnt/data/backups
sudo samba-tool domain backup offline --targetdir=/mnt/data/backups
```

Copy the tarball off the host. It holds the domain's secrets - treat it like
a password.

## Good to know

- **The hostname is the VM's name.** cloud-init sets it from `name` in
  `terraform/main.tf`; `samba_ad_hostname` must be the same, and the role
  stops if they differ. At most 15 characters: it is also the NetBIOS name.
- **Strings that land on the DC are not cosmetic.** `smb.conf` and the other
  files carry a "Managed by Ansible" line; editing a role's text rewrites the
  file and restarts what reads it.
- **`ansible_managed` exists only inside templates.** The files written with
  `copy` name the role in plain text instead.
- **Facts are only under `ansible_facts`** (`inject_facts_as_vars` is off):
  write `ansible_facts['hostname']`, not `ansible_hostname`.

# SMOKE TEST ONLY. Prove the loop end-to-end (Terraform -> garrett -> Ansible),
# then `terraform destroy -target` this and move on to the real Icinga2 host.
# VMID 390 is a scratch/smoke-test ID, deliberately outside the 200s (core
# appliance) and 300s (real LXC) ranges so it can never collide with a real host.
#
# NOTE: we do NOT use proxmox_virtual_environment_download_file here. That
# resource fetches the raw static URL directly, and Proxmox's template CDN
# rejected that with a 401 - the actual current URL/filename is only reliably
# known via `pveam`, not a hardcoded link. So the template is downloaded once,
# manually, via `pveam download local <file>` on garrett, and Terraform just
# references the file already sitting on disk. If this template ever needs
# updating, re-run pveam download on garrett and bump the filename below.

resource "proxmox_virtual_environment_container" "smoke_test" {
  vm_id       = 390
  node_name   = var.garrett_node_name
  unprivileged = true # avoids the root@pam-only restriction on feature flags (nesting, etc.)
                       # for privileged containers - also just better isolation by default.

  initialization {
    hostname = "tf-smoke-test"

    user_account {
      keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIBVEd/VW5X/fCP+eZ7b9623mexDR3zzn44G/EOmqK6P aba@dority"]
    }

    ip_config {
      ipv4 {
        address = "10.79.20.199/24" # scratch IP on the VLAN 20 servers segment
        gateway = "10.79.20.1"      # adjust to your actual OPNsense gateway for VLAN 20
      }
    }
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0" # adjust to garrett's actual bridge name if different
    vlan_id = 20
  }

  # Modern systemd (v247+, this template ships 257) tries to register the
  # login session with systemd-logind over D-Bus at SSH login time. Without
  # nesting enabled, that call hangs until a ~25s D-Bus timeout before
  # falling back - the exact cause of the slow SSH logins we saw. This is
  # the fix Proxmox's own "Systemd 257 detected" warning was pointing at.
  features {
    nesting = true
  }

  operating_system {
    # References the template already downloaded to garrett's local storage
    # via: pveam download local debian-13-standard_13.6-1_amd64.tar.zst
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
  }

  disk {
    datastore_id = "local-lvm" # adjust to garrett's actual storage name
    size         = 4
  }

  started = true
}

output "smoke_test_ip" {
  value = "10.79.20.199"
}

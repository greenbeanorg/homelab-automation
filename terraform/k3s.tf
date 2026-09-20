# k3s needs to run containers of its own (containerd) inside this container,
# which is why keyctl is added alongside nesting this time - confirmed
# against current guidance, not assumed from the icinga2/postgres hosts.
# Known rough edge: some unprivileged-container + storage-driver combos have
# trouble with specific image layers. If that bites us here, the honest
# fallback is unprivileged = false for this one host specifically - same
# trade-off already made for the farnum Plex LXC, for a different reason.

resource "proxmox_virtual_environment_container" "k3s1" {
  vm_id        = 304
  node_name    = var.garrett_node_name
  unprivileged = true

  initialization {
    hostname = "k3s1"

    user_account {
      keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIBVEd/VW5X/fCP+eZ7b9623mexDR3zzn44G/EOmqK6P aba@dority"]
    }

    ip_config {
      ipv4 {
        address = "10.79.20.60/24" # confirmed free against the current DNS list
        gateway = "10.79.20.1"
      }
    }
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = 20
  }

  features {
    nesting = true
    # keyctl deliberately left off: changing it requires root@pam, which our
    # scoped token can't do. Trying without it first - several k3s-on-LXC
    # setups work fine with nesting alone, since k3s uses containerd, not
    # full Docker. If k3s hits a real keyctl-shaped failure, that's the
    # signal to do a one-time manual `pct set 304 -features nesting=1,
    # keyctl=1` as root@pam directly on garrett, rather than fighting
    # Terraform for something it structurally can't grant.
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096 # k3s + the app pod(s) want real headroom, not the 1-2GB the other hosts got
  }

  disk {
    datastore_id = "local-lvm"
    size         = 20 # container images add up fast
  }

  started = true
}

output "k3s1_ip" {
  value = "10.79.20.60"
}

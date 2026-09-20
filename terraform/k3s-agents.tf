# Two k3s agent (worker) nodes joining k3s1's control plane. Same
# unprivileged + nesting baseline as every other host tonight - agents run
# containerd too, so the same /dev/kmsg fix applies.
#
# HONEST CAVEAT: these are still LXCs on the same physical garrett host as
# k3s1. This proves real multi-node k8s scheduling/operations knowledge,
# but is NOT real fault tolerance - if garrett itself goes down, every
# "node" goes down with it. Worth saying plainly if asked in an interview.

resource "proxmox_virtual_environment_container" "k3s2" {
  vm_id        = 305
  node_name    = var.garrett_node_name
  unprivileged = true

  initialization {
    hostname = "k3s2"
    user_account {
      keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIBVEd/VW5X/fCP+eZ7b9623mexDR3zzn44G/EOmqK6P aba@dority"]
    }
    ip_config {
      ipv4 {
        address = "10.79.20.61/24"
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
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = "local-lvm"
    size         = 12
  }

  started = true
}

resource "proxmox_virtual_environment_container" "k3s3" {
  vm_id        = 306
  node_name    = var.garrett_node_name
  unprivileged = true

  initialization {
    hostname = "k3s3"
    user_account {
      keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIBVEd/VW5X/fCP+eZ7b9623mexDR3zzn44G/EOmqK6P aba@dority"]
    }
    ip_config {
      ipv4 {
        address = "10.79.20.62/24"
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
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = "local-lvm"
    size         = 12
  }

  started = true
}

output "k3s2_ip" {
  value = "10.79.20.61"
}

output "k3s3_ip" {
  value = "10.79.20.62"
}

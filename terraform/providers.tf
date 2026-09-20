# Scoped ONLY to garrett. Do not add swearengen or wu endpoints here —
# the whole point of this repo is that it physically cannot touch prod.

provider "proxmox" {
  endpoint  = var.garrett_api_endpoint
  api_token = var.garrett_api_token

  # garrett is running a self-signed cert like the rest of the lab.
  # Set to false once/if a real CA cert is in place.
  insecure = true

  ssh {
    agent    = true
    username = "root" # only used for operations the API token can't do (e.g. template uploads)
  }
}

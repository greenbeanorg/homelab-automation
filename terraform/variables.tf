variable "garrett_api_endpoint" {
  description = "garrett's Proxmox API endpoint, e.g. https://10.79.10.25:8006/api2/json"
  type        = string
  default     = "https://10.79.10.25:8006/api2/json"
}

variable "garrett_api_token" {
  description = "Proxmox API token in the form 'user@pam!tokenid=secret', scoped to garrett only"
  type        = string
  sensitive   = true
}

variable "garrett_node_name" {
  description = "The Proxmox node name for garrett as it appears in the cluster/host UI"
  type        = string
  default     = "garrett"
}

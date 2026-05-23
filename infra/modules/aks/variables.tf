variable "name_suffix" {
  description = "Naming suffix (e.g., 'globalretail-dev-weu')."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group where the cluster lives. AKS will create a SEPARATE node-resource-group for VMSS, LBs, etc."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version line (e.g., '1.35'). AKS auto-picks the latest patch."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant — required by the Entra ID integration block."
  type        = string
}

# --- Identities ---------------------------------------------------------------

variable "controlplane_identity_id" {
  description = "Resource ID of the user-assigned managed identity for the AKS control plane."
  type        = string
}

variable "controlplane_identity_principal_id" {
  description = "Object (principal) ID of the control-plane UAMI — used in role assignments."
  type        = string
}

variable "kubelet_identity_id" {
  description = "Resource ID of the kubelet UAMI."
  type        = string
}

variable "kubelet_identity_client_id" {
  description = "Client ID of the kubelet UAMI."
  type        = string
}

variable "kubelet_identity_object_id" {
  description = "Object (principal) ID of the kubelet UAMI."
  type        = string
}

# --- Network ------------------------------------------------------------------

variable "aks_nodes_subnet_id" {
  description = "Subnet ID where AKS node VMs are placed. The control plane UAMI gets Network Contributor on this scope."
  type        = string
}

# --- Authorization ------------------------------------------------------------

variable "admin_group_object_ids" {
  description = "Entra ID group object IDs whose members are cluster admins (via Azure RBAC for Kubernetes)."
  type        = list(string)
  default     = []
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDR blocks allowed to reach the public API server endpoint. Entra ID auth still required on top."
  type        = list(string)
  default     = []
}

# --- Node pools ---------------------------------------------------------------

variable "system_node_count" {
  description = "Number of nodes in the system pool."
  type        = number
}

variable "system_node_size" {
  description = "VM SKU for the system pool."
  type        = string
}

variable "user_node_size" {
  description = "VM SKU for the user pool."
  type        = string
}

variable "user_node_min_count" {
  description = "Minimum nodes in the autoscaling user pool."
  type        = number
}

variable "user_node_max_count" {
  description = "Maximum nodes in the autoscaling user pool."
  type        = number
}

# --- Observability ------------------------------------------------------------

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace receiving AKS diagnostic logs."
  type        = string
}

variable "tags" {
  description = "Tags applied to the cluster and node pool."
  type        = map(string)
  default     = {}
}
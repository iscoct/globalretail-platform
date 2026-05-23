# ==============================================================================
# Network module
# ==============================================================================
# Creates the platform VNet and three subnets:
#   - snet-aks-nodes:          AKS node VMs land here
#   - snet-private-endpoints:  Reserved for PEs to ACR / KV / Storage (Iteration 2)
#   - snet-apiserver:          Reserved for future API Server VNet Integration
#
# NSGs are deliberately NOT created here. AKS attaches its own NSG to the
# nodes subnet at cluster create time, and private-endpoint subnets bypass
# NSGs by default. Adding empty NSGs preemptively just adds noise.

# --- VNet ---------------------------------------------------------------------
# Address space chosen to leave room for future peering (on-prem hub, multi-
# region expansion) without overlap. The /16 gives us 65k addresses; we use
# a tiny fraction.
resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.address_space
  tags                = var.tags
}

# --- AKS nodes subnet ---------------------------------------------------------
# Where AKS node VMs get their IPs. Sized /22 (1024 addresses) — way more than
# the few nodes we'll run today, but autoscaling and additional node pools
# can grow into it.
#
# KEY POINT FOR THE INSTRUCTOR: With Azure CNI Overlay (our choice), PODS do
# NOT consume IPs from this subnet — they live in an overlay network (default
# 10.244.0.0/16, configured at AKS create time). Only NODES use VNet IPs.
# This is the reason we picked Overlay over traditional Azure CNI: no IP
# exhaustion at scale, simpler IP planning.
#
# In traditional Azure CNI, every pod gets a VNet IP, so /22 (1024) would
# limit us to ~30 nodes × 30 pods-per-node ≈ 900 pods total. With Overlay,
# /22 is just the node ceiling — easily 100+ nodes.
resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.0.0.0/22"]
}

# --- Private endpoints subnet -------------------------------------------------
# Carved out now for use in Iteration 2 (PE to ACR, KV, Storage). Two reasons
# to define it in Iteration 1 even though nothing connects to it yet:
#
#   1. SUBNET PLANNING IS IRREVERSIBLE-ISH: shrinking a subnet that's in use
#      requires emptying it first. Defining the layout upfront avoids
#      reshuffling later.
#   2. PE-SPECIFIC FLAG: private_endpoint_network_policies = "Disabled" is
#      required for private endpoints to work — when ENABLED, the subnet's
#      NSGs and route tables get applied to PE traffic, which usually breaks
#      the connection. (This is also why PE subnets are usually dedicated.)
resource "azurerm_subnet" "private_endpoints" {
  name                              = "snet-private-endpoints"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = ["10.0.4.0/24"]
  private_endpoint_network_policies = "Disabled"
}

# --- API Server subnet (reserved, not used in Iteration 1) --------------------
# Reserved for if/when we switch from "public cluster + authorized IPs" to
# "API Server VNet Integration" (the modern alternative to private cluster).
# /28 is the minimum size AKS accepts for this purpose.
#
# Not delegated yet because delegation links the subnet to a specific Azure
# service — and if we never end up using API Server VNet Integration, that
# delegation is dead weight. When we switch, we add the delegation block.
resource "azurerm_subnet" "apiserver" {
  name                 = "snet-apiserver"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.0.5.0/28"]
}
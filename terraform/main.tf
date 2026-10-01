# All OCI infrastructure is intentionally in this file. Software is installed by Ansible.
terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    oci    = { source = "oracle/oci", version = "~> 7.0" }
    random = { source = "hashicorp/random", version = "~> 3.7" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
  }
}
provider "oci" {
  region              = var.region
  config_file_profile = var.oci_profile
  tenancy_ocid        = var.tenancy_ocid
  user_ocid           = var.user_ocid
  fingerprint         = var.fingerprint
  private_key_path    = local.oci_private_key_file
}
provider "oci" {
  alias               = "home"
  region              = var.tenancy_home_region
  config_file_profile = var.oci_profile
  tenancy_ocid        = var.tenancy_ocid
  user_ocid           = var.user_ocid
  fingerprint         = var.fingerprint
  private_key_path    = local.oci_private_key_file
}
variable "mode" {
  description = "Dev (default) and Prod use identical HA infrastructure; mode labels and separates local deployment identity."
  type        = string
  default     = "Dev"
  validation {
    condition     = contains(["dev", "prod"], lower(var.mode))
    error_message = "mode must be Dev or Prod (case insensitive)."
  }
}
variable "oci_config_file" {
  description = "OCI CLI profile file used by Ansible, relative to terraform/ or absolute."
  type        = string
  default     = "../identity/oci/config"
}
variable "user_ocid" { type = string }
variable "fingerprint" { type = string }
variable "oci_private_key_file" {
  description = "OCI API signing key for Terraform, relative to terraform/ or absolute."
  type        = string
  default     = "../identity/oci/api_key.pem"
}
variable "ssh_public_key_file" {
  description = "Public SSH key file, relative to terraform/ or absolute; ignored when ssh_public_key is supplied."
  type        = string
  default     = "../identity/ssh/id_ed25519.pub"
}
variable "ssh_private_key_file" {
  description = "Ansible controller SSH private key, relative to terraform/ or absolute. Terraform does not read its contents."
  type        = string
  default     = "../identity/ssh/id_ed25519"
}
variable "tenancy_home_region" { type = string }
variable "region" { type = string }
variable "tenancy_ocid" { type = string }
variable "compartment_ocid" { type = string }
variable "oci_profile" {
  type    = string
  default = "DEFAULT"
}
variable "name" {
  type    = string
  default = "gitlab"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.name))
    error_message = "Use 3-20 lowercase letters, digits or hyphens, starting with a letter."
  }
}
variable "domain" {
  description = "Optional base DNS domain. Leave empty to use the reserved public IPv4 address."
  type        = string
  default     = ""
  validation {
    condition     = var.domain == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$", var.domain))
    error_message = "Use a bare DNS domain without a scheme, path, port or trailing dot, or leave empty."
  }
}
variable "ssh_public_key" {
  type    = string
  default = null
}
variable "admin_cidrs" {
  description = "Optional private routed CIDRs of administrators. Bastion access is configured separately."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Supply restricted administrator CIDRs; 0.0.0.0/0 is forbidden."
  }
}
variable "bastion_ssh_cidrs" {
  description = "Public source CIDRs allowed to SSH to the bastion. Empty disables SSH ingress until configured."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.bastion_ssh_cidrs : can(cidrhost(c, 0))])
    error_message = "Supply valid IPv4 or IPv6 CIDRs for bastion SSH."
  }
}
variable "client_cidrs" {
  type    = set(string)
  default = ["0.0.0.0/0"]
}
variable "vcn_cidr" {
  type    = string
  default = "10.60.0.0/16"
  validation {
    condition     = can(cidrsubnet(var.vcn_cidr, 8, 255)) && endswith(var.vcn_cidr, "/16")
    error_message = "Use an unused IPv4 /16; it must not overlap VPN, pods (10.244/16), or services (10.96/16)."
  }
}
variable "kubernetes_version" {
  description = "An OKE-supported version, including v prefix, matching the worker image."
  type        = string
}
variable "oke_image_ocid" {
  description = "Region-specific x86_64 OKE Oracle Linux image for kubernetes_version."
  type        = string
}
variable "ubuntu_image_ocid" {
  description = "Region-specific Canonical Ubuntu 24.04 x86_64 platform image."
  type        = string
}
variable "compute_shape" {
  type    = string
  default = "VM.Standard.E5.Flex"
}
variable "runner_count" {
  description = "Dedicated OKE CI/load-generator nodes, separate from GitLab application pools."
  type        = number
  default     = 0
  validation {
    condition     = var.runner_count >= 0 && var.runner_count <= 6 && floor(var.runner_count) == var.runner_count
    error_message = "runner_count must be an integer from 0 to 6."
  }
}
variable "postgres_shape" {
  type    = string
  default = "PostgreSQL.VM.Standard.E5.Flex"
}
variable "postgres_version" {
  type    = string
  default = "17"
  validation {
    condition     = startswith(var.postgres_version, "17")
    error_message = "The pinned GitLab 19 release requires PostgreSQL 17."
  }
}
variable "object_storage_user_ocid" {
  description = "Dedicated existing OCI IAM user for S3 Customer Secret Key; no other privileges required."
  type        = string
}
variable "dns_zone_ocid" {
  description = "Optional existing public OCI DNS zone; otherwise create the documented records yourself."
  type        = string
  default     = null
}
variable "gitaly_volume_gb" {
  type    = number
  default = null
  validation {
    condition     = var.gitaly_volume_gb == null ? true : var.gitaly_volume_gb >= 100 && floor(var.gitaly_volume_gb) == var.gitaly_volume_gb
    error_message = "Repository volumes must be at least 100 GiB."
  }
}
variable "require_three_ads" {
  description = "Defaults to true in both modes. False permits only fault-domain resilience."
  type        = bool
  default     = null
}
data "oci_identity_availability_domains" "region" { compartment_id = var.tenancy_ocid }
data "oci_objectstorage_namespace" "this" { compartment_id = var.compartment_ocid }
data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}
locals {
  replica_count        = 3
  regional_storage     = coalesce(var.require_three_ads, true)
  repository_gb        = coalesce(var.gitaly_volume_gb, 1024)
  ip_access            = var.domain == ""
  gitlab_host          = local.ip_access ? oci_core_public_ip.ingress.ip_address : "gitlab.${var.domain}"
  public_ports         = local.ip_access ? [22, 80, 443, 5050, 8150] : [22, 80, 443]
  oci_private_key_file = abspath(startswith(var.oci_private_key_file, "/") ? var.oci_private_key_file : "${path.module}/${var.oci_private_key_file}")
  oci_config_file      = abspath(startswith(var.oci_config_file, "/") ? var.oci_config_file : "${path.module}/${var.oci_config_file}")
  ssh_public_key       = var.ssh_public_key != null ? var.ssh_public_key : file(startswith(var.ssh_public_key_file, "/") ? var.ssh_public_key_file : "${path.module}/${var.ssh_public_key_file}")
  ads                  = sort(data.oci_identity_availability_domains.region.availability_domains[*].name)
  tags                 = { application = "gitlab", managed_by = "terraform", mode = lower(var.mode) }
  subnets = {
    public   = { cidr = cidrsubnet(var.vcn_cidr, 8, 0), private = false }
    api      = { cidr = cidrsubnet(var.vcn_cidr, 8, 1), private = true }
    workers  = { cidr = cidrsubnet(var.vcn_cidr, 6, 1), private = true }
    storage  = { cidr = cidrsubnet(var.vcn_cidr, 8, 8), private = true }
    database = { cidr = cidrsubnet(var.vcn_cidr, 8, 9), private = true }
    cache    = { cidr = cidrsubnet(var.vcn_cidr, 8, 10), private = true }
  }
  pools = {
    # Three web pods per surviving node: 12.3 requested vCPU and 36 GiB Rails memory.
    web     = { ocpus = 8, memory = 48 }
    sidekiq = { ocpus = 2, memory = 16 }
    support = { ocpus = 2, memory = 16 }
    runner  = { ocpus = 4, memory = 16 }
  }
  hosts = merge(
    { for i in range(local.replica_count) : "gitaly-${i + 1}" => { role = "gitaly", index = i, ocpus = 4, memory = 32 } },
    { for i in range(local.replica_count) : "praefect-${i + 1}" => { role = "praefect", index = i, ocpus = 1, memory = 4 } }
  )
  buckets = toset(["artifacts", "lfs", "uploads", "packages", "external-diffs", "terraform-state", "dependency-proxy", "ci-secure-files", "registry", "backups", "tmp-backups"])
}
resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = var.name
  dns_label      = "gitlab"
  freeform_tags  = local.tags
  lifecycle {
    precondition {
      condition     = !local.regional_storage || length(local.ads) >= 3
      error_message = "This HA deployment requires a three-AD region. Disable require_three_ads only if accepting fault-domain-only HA."
    }
  }
}
resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-internet"
}
resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-nat"
}
resource "oci_core_service_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  services { service_id = data.oci_core_services.all.services[0].id }
}
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}
resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_nat_gateway.this.id
  }
  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }
}
# Explicit empty list prevents default VCN SSH ingress; NSGs define access below.
resource "oci_core_security_list" "empty" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-nsg-only"
}
resource "oci_core_subnet" "this" {
  for_each                   = local.subnets
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = each.value.cidr
  display_name               = "${var.name}-${each.key}"
  dns_label                  = each.key
  prohibit_public_ip_on_vnic = each.value.private
  route_table_id             = each.value.private ? oci_core_route_table.private.id : oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}
resource "oci_core_network_security_group" "this" {
  for_each       = toset(["public", "bastion", "api", "workers", "gitaly", "praefect", "internal_lb", "database", "cache"])
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-${each.key}"
}
# FLANNEL_OVERLAY: traffic leaving pods uses the worker's private IP.
locals {
  tcp_rules = merge(
    {
      internal_callback = { dst = "public", cidr = "${oci_core_nat_gateway.this.nat_ip}/32", min = 443, max = 443 }
      api_workers       = { dst = "api", src = "workers", min = 6443, max = 6443 }
      api_bastion       = { dst = "api", src = "bastion", min = 6443, max = 6443 }
      api_control       = { dst = "api", src = "workers", min = 12250, max = 12250 }
      control_plane     = { dst = "workers", src = "api", min = 1, max = 65535 }
      nodeports         = { dst = "workers", src = "public", min = 30000, max = 32767 }
      lb_health         = { dst = "workers", src = "public", min = 10256, max = 10256 }
      worker_peers      = { dst = "workers", src = "workers", min = 1, max = 65535 }
      git_client        = { dst = "internal_lb", src = "workers", min = 3305, max = 3305 }
      # Gitaly resolves remote repositories through Praefect during commits.
      git_remote       = { dst = "internal_lb", src = "gitaly", min = 3305, max = 3305 }
      git_check        = { dst = "internal_lb", src = "praefect", min = 3305, max = 3305 }
      praefect_lb      = { dst = "praefect", src = "internal_lb", min = 3305, max = 3305 }
      gitaly_rpc       = { dst = "gitaly", src = "praefect", min = 8076, max = 8076 }
      replication      = { dst = "gitaly", src = "gitaly", min = 8076, max = 8076 }
      postgres_app     = { dst = "database", src = "workers", min = 5432, max = 5432 }
      postgres_pf      = { dst = "database", src = "praefect", min = 5432, max = 5432 }
      redis_app        = { dst = "cache", src = "workers", min = 6379, max = 6379 }
      metrics_git      = { dst = "gitaly", src = "workers", min = 9236, max = 9236 }
      metrics_pf       = { dst = "praefect", src = "workers", min = 9652, max = 9652 }
      node_git         = { dst = "gitaly", src = "workers", min = 9100, max = 9100 }
      node_pf          = { dst = "praefect", src = "workers", min = 9100, max = 9100 }
      bastion_gitaly   = { dst = "gitaly", src = "bastion", min = 22, max = 22 }
      bastion_praefect = { dst = "praefect", src = "bastion", min = 22, max = 22 }
    },
    { for c in var.bastion_ssh_cidrs : "bastion-ssh-${c}" => { dst = "bastion", cidr = c, min = 22, max = 22 } },
    { for r in setproduct(var.admin_cidrs, ["gitaly", "praefect"]) : "ssh-${r[1]}-${r[0]}" => { dst = r[1], cidr = r[0], min = 22, max = 22 } },
    { for c in var.admin_cidrs : "admin-api-${c}" => { dst = "api", cidr = c, min = 6443, max = 6443 } },
    { for r in setproduct(var.client_cidrs, local.public_ports) : "client-${r[0]}-${r[1]}" => { dst = "public", cidr = r[0], min = r[1], max = r[1] } }
  )
}
resource "oci_core_network_security_group_security_rule" "tcp" {
  for_each                  = local.tcp_rules
  network_security_group_id = oci_core_network_security_group.this[each.value.dst].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = try(each.value.src, null) != null ? "NETWORK_SECURITY_GROUP" : "CIDR_BLOCK"
  source                    = try(each.value.src, null) != null ? oci_core_network_security_group.this[each.value.src].id : each.value.cidr
  tcp_options {
    destination_port_range {
      min = each.value.min
      max = each.value.max
    }
  }
}
resource "oci_core_network_security_group_security_rule" "flannel" {
  network_security_group_id = oci_core_network_security_group.this["workers"].id
  direction                 = "INGRESS"
  protocol                  = "17"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.this["workers"].id
  udp_options {
    destination_port_range {
      min = 14789
      max = 14789
    }
  }
}
resource "oci_core_network_security_group_security_rule" "egress" {
  for_each                  = oci_core_network_security_group.this
  network_security_group_id = each.value.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}
resource "oci_core_network_security_group_security_rule" "pmtu" {
  for_each                  = oci_core_network_security_group.this
  network_security_group_id = each.value.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  icmp_options {
    type = 3
    code = 4
  }
}
resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_ocid
  name               = var.name
  kubernetes_version = var.kubernetes_version
  vcn_id             = oci_core_vcn.this.id
  type               = "ENHANCED_CLUSTER"
  freeform_tags      = local.tags
  cluster_pod_network_options { cni_type = "FLANNEL_OVERLAY" }
  endpoint_config {
    is_public_ip_enabled = false
    subnet_id            = oci_core_subnet.this["api"].id
    nsg_ids              = [oci_core_network_security_group.this["api"].id]
  }
  options {
    service_lb_subnet_ids = [oci_core_subnet.this["public"].id]
    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
  }
}
resource "oci_containerengine_node_pool" "this" {
  for_each           = { for k, v in local.pools : k => v if k != "runner" || var.runner_count > 0 }
  compartment_id     = var.compartment_ocid
  cluster_id         = oci_containerengine_cluster.this.id
  name               = "${var.name}-${each.key}"
  kubernetes_version = var.kubernetes_version
  node_shape         = var.compute_shape
  ssh_public_key     = local.ssh_public_key
  freeform_tags      = local.tags
  node_shape_config {
    ocpus         = each.value.ocpus
    memory_in_gbs = each.value.memory
  }
  node_source_details {
    image_id                = var.oke_image_ocid
    source_type             = "IMAGE"
    boot_volume_size_in_gbs = 100
  }
  initial_node_labels {
    key   = "gitlab-pool"
    value = each.key
  }
  node_config_details {
    size                                = each.key == "runner" ? var.runner_count : local.replica_count
    nsg_ids                             = [oci_core_network_security_group.this["workers"].id]
    is_pv_encryption_in_transit_enabled = true
    node_pool_pod_network_option_details { cni_type = "FLANNEL_OVERLAY" }
    dynamic "placement_configs" {
      for_each = range(local.replica_count)
      content {
        availability_domain = local.ads[placement_configs.value % length(local.ads)]
        subnet_id           = oci_core_subnet.this["workers"].id
        fault_domains       = ["FAULT-DOMAIN-${placement_configs.value + 1}"]
      }
    }
  }
  node_eviction_node_pool_settings {
    eviction_grace_duration              = "PT1H"
    is_force_delete_after_grace_duration = false
  }
  depends_on = [oci_core_network_security_group_security_rule.tcp, oci_core_network_security_group_security_rule.egress]
}
resource "oci_core_public_ip" "ingress" {
  compartment_id = var.compartment_ocid
  lifetime       = "RESERVED"
  display_name   = "${var.name}-ingress"
  lifecycle {
    ignore_changes = [private_ip_id]
  }
}
resource "oci_identity_policy" "oke" {
  provider       = oci.home
  compartment_id = var.compartment_ocid
  name           = "${var.name}-oke-lb"
  description    = "Allow only this OKE cluster to provision service load balancers."
  statements = [for grant in ["manage load-balancers", "use virtual-network-family", "manage floating-ips", "read public-ips"] :
    "Allow any-user to ${grant} in compartment id ${var.compartment_ocid} where all {request.principal.type = 'cluster', request.principal.id = '${oci_containerengine_cluster.this.id}'}"
  ]
}
resource "oci_core_instance" "backend" {
  for_each                            = local.hosts
  compartment_id                      = var.compartment_ocid
  availability_domain                 = local.ads[each.value.index % length(local.ads)]
  fault_domain                        = "FAULT-DOMAIN-${each.value.index + 1}"
  display_name                        = "${var.name}-${each.key}"
  shape                               = var.compute_shape
  freeform_tags                       = local.tags
  is_pv_encryption_in_transit_enabled = true
  shape_config {
    ocpus         = each.value.ocpus
    memory_in_gbs = each.value.memory
  }
  create_vnic_details {
    subnet_id        = oci_core_subnet.this["storage"].id
    assign_public_ip = false
    hostname_label   = each.key
    nsg_ids          = [oci_core_network_security_group.this[each.value.role].id]
  }
  source_details {
    source_type             = "image"
    source_id               = var.ubuntu_image_ocid
    boot_volume_size_in_gbs = 100
  }
  metadata = { ssh_authorized_keys = local.ssh_public_key }
  launch_options {
    network_type                        = "PARAVIRTUALIZED"
    is_consistent_volume_naming_enabled = true
  }
}
resource "oci_core_instance" "bastion" {
  count                               = lower(var.mode) == "dev" ? 1 : 0
  compartment_id                      = var.compartment_ocid
  availability_domain                 = local.ads[0]
  display_name                        = "${var.name}-bastion"
  shape                               = var.compute_shape
  freeform_tags                       = local.tags
  is_pv_encryption_in_transit_enabled = true
  shape_config {
    ocpus         = 1
    memory_in_gbs = 4
  }
  create_vnic_details {
    subnet_id        = oci_core_subnet.this["public"].id
    assign_public_ip = true
    hostname_label   = "bastion"
    nsg_ids          = [oci_core_network_security_group.this["bastion"].id]
  }
  source_details {
    source_type             = "image"
    source_id               = var.ubuntu_image_ocid
    boot_volume_size_in_gbs = 50
  }
  metadata = { ssh_authorized_keys = local.ssh_public_key }
  launch_options {
    network_type                        = "PARAVIRTUALIZED"
    is_consistent_volume_naming_enabled = true
  }
}
resource "oci_core_volume" "gitaly" {
  for_each            = { for k, v in local.hosts : k => v if v.role == "gitaly" }
  compartment_id      = var.compartment_ocid
  availability_domain = local.ads[each.value.index % length(local.ads)]
  display_name        = "${var.name}-${each.key}-repositories"
  size_in_gbs         = local.repository_gb
  vpus_per_gb         = 20
  freeform_tags       = local.tags
  lifecycle { prevent_destroy = true }
}
resource "oci_core_volume_attachment" "gitaly" {
  for_each                            = oci_core_volume.gitaly
  attachment_type                     = "paravirtualized"
  instance_id                         = oci_core_instance.backend[each.key].id
  volume_id                           = each.value.id
  device                              = "/dev/oracleoci/oraclevdb"
  is_pv_encryption_in_transit_enabled = true
}
data "oci_core_volume_backup_policies" "builtin" {}
resource "oci_core_volume_backup_policy_assignment" "gitaly" {
  for_each  = oci_core_volume.gitaly
  asset_id  = each.value.id
  policy_id = one([for p in data.oci_core_volume_backup_policies.builtin.volume_backup_policies : p.id if p.display_name == "gold"])
}
resource "oci_load_balancer_load_balancer" "praefect" {
  compartment_id             = var.compartment_ocid
  display_name               = "${var.name}-praefect"
  shape                      = "flexible"
  is_private                 = true
  subnet_ids                 = [oci_core_subnet.this["storage"].id]
  network_security_group_ids = [oci_core_network_security_group.this["internal_lb"].id]
  shape_details {
    minimum_bandwidth_in_mbps = 100
    maximum_bandwidth_in_mbps = 1000
  }
}
resource "oci_load_balancer_backend_set" "praefect" {
  load_balancer_id = oci_load_balancer_load_balancer.praefect.id
  name             = "praefect"
  policy           = "LEAST_CONNECTIONS"
  health_checker {
    protocol = "TCP"
    port     = 3305
  }
}
resource "oci_load_balancer_backend" "praefect" {
  for_each         = { for k, v in local.hosts : k => v if v.role == "praefect" }
  load_balancer_id = oci_load_balancer_load_balancer.praefect.id
  backendset_name  = oci_load_balancer_backend_set.praefect.name
  ip_address       = oci_core_instance.backend[each.key].private_ip
  port             = 3305
}
resource "oci_load_balancer_listener" "praefect" {
  load_balancer_id         = oci_load_balancer_load_balancer.praefect.id
  name                     = "gitaly-tls"
  default_backend_set_name = oci_load_balancer_backend_set.praefect.name
  protocol                 = "TCP"
  port                     = 3305
  connection_configuration { idle_timeout_in_seconds = 3600 }
}
resource "random_password" "secret" {
  for_each = toset(["main_admin", "praefect_admin", "gitlab_db", "praefect_db", "gitaly", "praefect", "shell", "root"])
  length   = 40
  special  = false
}
resource "oci_psql_configuration" "this" {
  for_each       = toset(["main", "praefect"])
  compartment_id = var.compartment_ocid
  display_name   = "${var.name}-${each.key}"
  db_version     = var.postgres_version
  shape          = trimprefix(var.postgres_shape, "PostgreSQL.")
  is_flexible    = true
  db_configuration_overrides {
    items {
      config_key             = "oci.admin_enabled_extensions"
      overriden_config_value = "amcheck,pg_stat_statements"
    }
    items {
      config_key             = "max_connections"
      overriden_config_value = each.key == "main" ? "600" : "200"
    }
  }
}
# Separate HA database systems: Praefect must not share GitLab's database instance.
resource "oci_psql_db_system" "this" {
  for_each                    = toset(["main", "praefect"])
  compartment_id              = var.compartment_ocid
  display_name                = "${var.name}-${each.key}"
  db_version                  = var.postgres_version
  shape                       = var.postgres_shape
  instance_count              = local.replica_count
  instance_ocpu_count         = 2
  instance_memory_size_in_gbs = 32
  config_id                   = oci_psql_configuration.this[each.key].id
  network_details {
    subnet_id = oci_core_subnet.this["database"].id
    nsg_ids   = [oci_core_network_security_group.this["database"].id]
  }
  storage_details {
    is_regionally_durable = local.regional_storage
    availability_domain   = local.regional_storage ? null : local.ads[0]
    system_type           = "OCI_OPTIMIZED_STORAGE"
    iops                  = 75000
  }
  credentials {
    username = "gitlab_admin"
    password_details {
      password_type = "PLAIN_TEXT"
      password      = random_password.secret["${each.key}_admin"].result
    }
  }
  management_policy {
    maintenance_window_start = each.key == "main" ? "SUN 04:00" : "SUN 06:00"
    backup_policy {
      kind           = "DAILY"
      backup_start   = "02:00"
      retention_days = 30
    }
  }
  freeform_tags = local.tags
  lifecycle { prevent_destroy = true }
}
data "oci_psql_db_system_connection_detail" "this" {
  for_each     = oci_psql_db_system.this
  db_system_id = each.value.id
}
resource "oci_redis_oci_cache_config_set" "this" {
  compartment_id   = var.compartment_ocid
  display_name     = "${var.name}-noeviction"
  software_version = "REDIS_7_0"
  configuration_details {
    items {
      config_key   = "maxmemory-policy"
      config_value = "noeviction"
    }
  }
}
resource "oci_redis_redis_cluster" "this" {
  compartment_id          = var.compartment_ocid
  display_name            = var.name
  cluster_mode            = "NONSHARDED"
  node_count              = local.replica_count
  node_memory_in_gbs      = 8
  software_version        = "REDIS_7_0"
  subnet_id               = oci_core_subnet.this["cache"].id
  nsg_ids                 = [oci_core_network_security_group.this["cache"].id]
  oci_cache_config_set_id = oci_redis_oci_cache_config_set.this.id
  freeform_tags           = local.tags
  lifecycle { prevent_destroy = true }
}
resource "oci_objectstorage_bucket" "this" {
  for_each       = local.buckets
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${var.name}-${each.key}"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"
  freeform_tags  = local.tags
  lifecycle { prevent_destroy = true }
}
resource "oci_identity_group" "objects" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.name}-object-storage"
  description    = "Dedicated GitLab S3 access"
}
resource "oci_identity_user_group_membership" "objects" {
  provider = oci.home
  user_id  = var.object_storage_user_ocid
  group_id = oci_identity_group.objects.id
}
resource "oci_identity_policy" "objects" {
  provider       = oci.home
  compartment_id = var.compartment_ocid
  name           = "${var.name}-objects"
  description    = "Restrict GitLab's S3 user to the deployment buckets."
  statements = flatten([for b in oci_objectstorage_bucket.this : [
    "Allow group id ${oci_identity_group.objects.id} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${b.name}'",
    "Allow group id ${oci_identity_group.objects.id} to read buckets in compartment id ${var.compartment_ocid} where target.bucket.name = '${b.name}'"
  ]])
}
resource "oci_identity_customer_secret_key" "objects" {
  provider     = oci.home
  user_id      = var.object_storage_user_ocid
  display_name = "${var.name}-s3"
}
resource "oci_dns_rrset" "public" {
  for_each        = var.dns_zone_ocid == null || local.ip_access ? toset([]) : toset(["gitlab", "registry", "kas"])
  zone_name_or_id = var.dns_zone_ocid
  domain          = "${each.key}.${var.domain}"
  rtype           = "A"
  items {
    domain = "${each.key}.${var.domain}"
    rtype  = "A"
    rdata  = oci_core_public_ip.ingress.ip_address
    ttl    = 300
  }
}
# Protect state and this inventory: both contain passwords and the S3 key.
resource "local_sensitive_file" "inventory" {
  filename             = "${path.module}/../identity/${lower(var.mode)}/inventory.yml"
  file_permission      = "0600"
  directory_permission = "0700"
  content = yamlencode({
    all = {
      vars = {
        ansible_user                 = "ubuntu"
        ansible_ssh_private_key_file = abspath(startswith(var.ssh_private_key_file, "/") ? var.ssh_private_key_file : "${path.module}/${var.ssh_private_key_file}")
        ansible_python_interpreter   = "/usr/bin/python3"
        oci_region                   = var.region
        oci_profile                  = var.oci_profile
        oci_config_file              = local.oci_config_file
        deployment_mode              = title(lower(var.mode))
        gitlab_host                  = local.gitlab_host
        ip_access                    = local.ip_access
        cluster_id                   = oci_containerengine_cluster.this.id
        gitlab_domain                = var.domain
        public_ip                    = oci_core_public_ip.ingress.ip_address
        public_subnet_id             = oci_core_subnet.this["public"].id
        public_nsg_id                = oci_core_network_security_group.this["public"].id
        client_cidrs                 = setunion(var.client_cidrs, ["${oci_core_nat_gateway.this.nat_ip}/32"])
        workers_cidr                 = local.subnets.workers.cidr
        storage_cidr                 = local.subnets.storage.cidr
        admin_cidrs                  = var.admin_cidrs
        praefect_address             = oci_load_balancer_load_balancer.praefect.ip_address_details[0].ip_address
        redis_host                   = oci_redis_redis_cluster.this.primary_fqdn
        postgres = { for k, v in data.oci_psql_db_system_connection_detail.this : k => {
          host = v.primary_db_endpoint[0].fqdn
          ca   = v.ca_certificate
        } }
        secrets = { for k, v in random_password.secret : k => v.result }
        object_storage = {
          endpoint   = "https://${data.oci_objectstorage_namespace.this.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
          host       = "${data.oci_objectstorage_namespace.this.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
          access_key = oci_identity_customer_secret_key.objects.id
          secret_key = oci_identity_customer_secret_key.objects.key
          buckets    = { for k, v in oci_objectstorage_bucket.this : k => v.name }
        }
      }
      children = {
        controller = { hosts = { localhost = { ansible_connection = "local", ansible_python_interpreter = "{{ ansible_playbook_python }}" } } }
        gitaly     = { hosts = { for k, v in local.hosts : k => { ansible_host = oci_core_instance.backend[k].private_ip } if v.role == "gitaly" } }
        praefect   = { hosts = { for k, v in local.hosts : k => { ansible_host = oci_core_instance.backend[k].private_ip } if v.role == "praefect" } }
      }
    }
  })
  depends_on = [oci_core_volume_attachment.gitaly, oci_containerengine_node_pool.this, oci_identity_policy.objects, oci_identity_policy.oke]
}
output "ansible_inventory" { value = local_sensitive_file.inventory.filename }
output "public_ip" { value = oci_core_public_ip.ingress.ip_address }
output "bastion_public_ip" { value = try(oci_core_instance.bastion[0].public_ip, null) }
output "mode" { value = title(lower(var.mode)) }
output "gitlab_url" { value = "https://${local.gitlab_host}" }
output "registry_url" { value = local.ip_access ? "https://${local.gitlab_host}:5050" : "https://registry.${var.domain}" }
output "kas_url" { value = local.ip_access ? "wss://${local.gitlab_host}:8150" : "wss://kas.${var.domain}" }
output "cluster_id" { value = oci_containerengine_cluster.this.id }
output "vcn_id" { value = oci_core_vcn.this.id }
output "private_route_table_id" { value = oci_core_route_table.private.id }

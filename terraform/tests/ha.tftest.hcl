# Offline plan tests. No real OCI provider calls and no resources are created.
mock_provider "oci" {
  mock_data "oci_identity_availability_domains" {
    defaults = {
      availability_domains = [{ name = "test:AD-1" }, { name = "test:AD-2" }, { name = "test:AD-3" }]
    }
  }
  mock_data "oci_core_services" {
    defaults = { services = [{ id = "ocid1.service.test", cidr_block = "all-iad-services-in-oracle-services-network" }] }
  }
  mock_data "oci_core_volume_backup_policies" {
    defaults = { volume_backup_policies = [{ id = "ocid1.volumebackuppolicy.test", display_name = "gold" }] }
  }
}
mock_provider "oci" { alias = "home" }
mock_provider "random" {}
mock_provider "local" {}
variables {
  region                   = "us-ashburn-1"
  tenancy_home_region      = "us-ashburn-1"
  tenancy_ocid             = "ocid1.tenancy.test"
  user_ocid                = "ocid1.user.test"
  fingerprint              = "00:11:22:33"
  compartment_ocid         = "ocid1.compartment.test"
  ssh_public_key           = "ssh-ed25519 FAKE-TEST-KEY"
  admin_cidrs              = ["10.70.0.0/24"]
  kubernetes_version       = "v1.34.2"
  oke_image_ocid           = "ocid1.image.test-oke"
  ubuntu_image_ocid        = "ocid1.image.test-ubuntu"
  object_storage_user_ocid = "ocid1.user.test"
}
run "ha_invariants" {
  command = plan
  variables {
    mode          = "Prod"
    domain        = "example.test"
    dns_zone_ocid = "ocid1.dns-zone.test"
  }
  assert {
    condition     = length(oci_core_instance.backend) == 6 && length(oci_core_volume.gitaly) == 3
    error_message = "Repository HA requires three separate Gitaly and three Praefect nodes."
  }
  assert {
    condition     = alltrue([for i in oci_core_instance.backend : tobool(i.create_vnic_details[0].assign_public_ip) == false])
    error_message = "Backend hosts must remain private."
  }
  assert {
    condition     = length(distinct([for k, i in oci_core_instance.backend : i.availability_domain if startswith(k, "gitaly")])) == 3
    error_message = "Gitaly replicas must span three availability domains."
  }
  assert {
    condition     = length(oci_psql_db_system.this) == 2 && alltrue([for db in oci_psql_db_system.this : db.instance_count == 3 && db.storage_details[0].is_regionally_durable])
    error_message = "GitLab and Praefect need separate, regionally durable HA database systems."
  }
  assert {
    condition     = oci_redis_redis_cluster.this.cluster_mode == "NONSHARDED" && oci_redis_redis_cluster.this.node_count == 3
    error_message = "Redis must have replicas and must not use Redis Cluster sharding."
  }
  assert {
    condition     = alltrue([for p in oci_containerengine_node_pool.this : p.node_config_details[0].size == 3]) && oci_containerengine_node_pool.this["web"].node_shape_config[0].ocpus >= 8 && oci_containerengine_node_pool.this["web"].node_shape_config[0].memory_in_gbs >= 48
    error_message = "Node pools need failure headroom, including room for three web pods on each surviving web node."
  }
  assert {
    condition     = oci_containerengine_addon.metrics_server.addon_name == "KubernetesMetricsServer" && oci_containerengine_addon.cert_manager.addon_name == "CertManager" && oci_containerengine_addon.metrics_server.remove_addon_resources_on_delete && oci_containerengine_addon.cert_manager.remove_addon_resources_on_delete
    error_message = "Fresh clusters need managed resource metrics and their certificate dependency, both removed during teardown."
  }
  assert {
    condition     = alltrue([for b in oci_objectstorage_bucket.this : b.access_type == "NoPublicAccess" && b.versioning == "Enabled"])
    error_message = "Object storage must be private and versioned."
  }
  assert {
    condition     = oci_containerengine_cluster.this.endpoint_config[0].is_public_ip_enabled == false
    error_message = "The Kubernetes API must be private."
  }
  assert {
    condition     = length(oci_dns_rrset.public) == 3 && !local.ip_access && !contains(local.public_ports, 5050)
    error_message = "DNS access must create the three configured names and use the shared HTTPS port."
  }
}
run "reject_single_ad_for_regional_ha" {
  command = plan
  variables { mode = "Prod" }
  override_data {
    target = data.oci_identity_availability_domains.region
    values = { availability_domains = [{ name = "test:AD-1" }] }
  }
  expect_failures = [oci_core_vcn.this]
}

run "dev_is_default_with_full_ha_and_no_dns" {
  command = plan
  variables { bastion_ssh_cidrs = ["0.0.0.0/0"] }
  assert {
    condition     = var.mode == "Dev" && length(oci_core_instance.backend) == 6 && length(oci_core_volume.gitaly) == 3
    error_message = "Dev must retain all three Gitaly and Praefect nodes."
  }
  assert {
    condition     = alltrue([for p in oci_containerengine_node_pool.this : p.node_config_details[0].size == 3]) && alltrue([for db in oci_psql_db_system.this : db.instance_count == 3 && db.storage_details[0].is_regionally_durable])
    error_message = "Dev must retain three-node pools and regional HA databases."
  }
  assert {
    condition     = oci_redis_redis_cluster.this.node_count == 3 && tonumber(oci_core_volume.gitaly["gitaly-1"].size_in_gbs) == 1024
    error_message = "Dev must retain the HA cache and full repository capacity."
  }
  assert {
    condition     = local.ip_access && length(oci_dns_rrset.public) == 0 && contains(local.public_ports, 5050) && contains(local.public_ports, 8150)
    error_message = "IP access must work without DNS, with separate Registry and KAS ports."
  }
  assert {
    condition     = endswith(local_sensitive_file.inventory.filename, "/identity/dev/inventory.yml")
    error_message = "Generated credentials must be under identity/."
  }
  assert {
    condition     = length(oci_core_instance.bastion) == 1 && oci_core_instance.bastion[0].create_vnic_details[0].assign_public_ip
    error_message = "Dev needs a public bastion for private administration."
  }
  assert {
    condition     = local.tcp_rules["bastion-ssh-0.0.0.0/0"].dst == "bastion" && local.tcp_rules["api_bastion"].src == "bastion" && local.tcp_rules["bastion_gitaly"].min == 22
    error_message = "Dev must apply the selected public bastion SSH source."
  }
  assert {
    condition     = oci_containerengine_node_pool.this["web"].node_shape_config[0].ocpus == 8 && oci_containerengine_node_pool.this["web"].node_shape_config[0].memory_in_gbs == 48
    error_message = "Dev and Prod must have identical web-node sizing."
  }
  assert {
    condition     = alltrue([for db in oci_psql_db_system.this : db.instance_ocpu_count == 2 && db.instance_memory_size_in_gbs == 32]) && oci_redis_redis_cluster.this.node_memory_in_gbs == 8
    error_message = "Dev must retain the production database and cache capacity."
  }
}
run "dev_rejects_single_ad_too" {
  command = plan
  override_data {
    target = data.oci_identity_availability_domains.region
    values = { availability_domains = [{ name = "test:AD-1" }] }
  }
  expect_failures = [oci_core_vcn.this]
}
run "prod_also_supports_ip_access" {
  command = plan
  variables { mode = "pRoD" }
  assert {
    condition     = lower(var.mode) == "prod" && local.ip_access && oci_redis_redis_cluster.this.node_count == 3 && length(oci_core_instance.bastion) == 0
    error_message = "IP access must be independent of the HA profile and mode matching must ignore case."
  }
}
run "reject_invalid_mode" {
  command = plan
  variables { mode = "Preview" }
  expect_failures = [var.mode]
}

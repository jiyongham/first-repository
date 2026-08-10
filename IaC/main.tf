terraform {
  required_providers {
    nutanix = {
      source  = "nutanix/nutanix"
      version = "2.0.0"
    }
  }
}

provider "nutanix" {
  endpoint = "pc.nutanix.local"
  username = "admin"
  password = var.pc_password
  insecure = true
}

########################
# Data Sources
########################
data "nutanix_subnets" "all" {}

data "nutanix_cluster" "cluster" {
  for_each = local.all_cluster_names
  name     = each.value
}

data "nutanix_image" "img" {
  for_each   = var.vms
  image_name = each.value.template_name
}

data "nutanix_storage_containers_v2" "normal" {
  page   = 0
  limit  = 100
  filter = "endswith(name, '-Normal')"
}

data "nutanix_storage_containers_v2" "dbms" {
  page   = 0
  limit  = 100
  filter = "endswith(name, '-DBMS')"
}

########################
# Locals
########################
locals {
  # VM + VG 클러스터 통합
  all_cluster_names = toset(concat(
    [for vm in var.vms : vm.cluster_name],
    [for vg in var.volume_groups : vg.cluster_name]
  ))

  # Storage Container 통합
  all_storage_containers = concat(
    try(data.nutanix_storage_containers_v2.normal.storage_containers, []),
    try(data.nutanix_storage_containers_v2.dbms.storage_containers, []),
  )

  # 클러스터별 PE UUID 자동 추출
  cluster_pe_uuid_map = {
    for cluster_name in local.all_cluster_names :
    cluster_name => coalesce(
      try(
        one(distinct([
          for sc in local.all_storage_containers :
          sc.cluster_ext_id
          if sc.cluster_name == cluster_name
        ])),
        null
      ),
      data.nutanix_cluster.cluster[cluster_name].metadata["uuid"]
    )
  }

  # Subnet UUID 매핑
  subnet_uuid_map = {
    for vm_name, vm in var.vms :
    vm_name => try(
      one([
        for s in data.nutanix_subnets.all.entities :
        s.metadata["uuid"]
        if s.vlan_id == vm.vlan_id
        && s.cluster_reference.name == vm.cluster_name
      ]),
      null
    )
  }

  # VM Storage Container 매핑
  storage_container_map = {
    for vm_name, vm in var.vms :
    vm_name => {
      normal = try(
        one([
          for sc in local.all_storage_containers :
          sc.ext_id
          if endswith(sc.name, "-Normal")
          && sc.cluster_name == vm.cluster_name
        ]),
        null
      )
      db = try(
        one([
          for sc in local.all_storage_containers :
          sc.ext_id
          if endswith(sc.name, "-DBMS")
          && sc.cluster_name == vm.cluster_name
        ]),
        null
      )
    }
  }

  # VG Storage Container 매핑
  vg_storage_container_map = {
    for vg_name, vg in var.volume_groups :
    vg_name => {
      normal = try(
        one([
          for sc in local.all_storage_containers :
          sc.ext_id
          if endswith(sc.name, "-Normal")
          && sc.cluster_name == vg.cluster_name
        ]),
        null
      )
      db = try(
        one([
          for sc in local.all_storage_containers :
          sc.ext_id
          if endswith(sc.name, "-DBMS")
          && sc.cluster_name == vg.cluster_name
        ]),
        null
      )
    }
  }

  # VG 디스크 flat 변환
  vg_disk_list = {
    for pair in flatten([
      for vg_name, vg in var.volume_groups : [
        for idx, disk in vg.disks : {
          vg_name = vg_name
          idx     = idx
          disk    = disk
        }
      ]
    ]) :
    "${pair.vg_name}:${pair.idx}" => pair
  }

  # VM-VG 연결 flat 변환
  vm_vg_attachments = {
    for pair in flatten([
      for vm_name, vm in var.vms : [
        for vg_name in vm.volume_groups : {
          vm_name = vm_name
          vg_name = vg_name
        }
      ]
    ]) :
    "${pair.vm_name}:${pair.vg_name}" => pair
  }
}

########################
# VM
########################
resource "nutanix_virtual_machine_v2" "vm" {
  for_each = var.vms

  name                 = each.key
  num_sockets          = each.value.num_sockets
  num_cores_per_socket = each.value.num_vcpus_per_socket
  memory_size_bytes    = each.value.memory_size_gib * 1024 * 1024 * 1024

  cluster {
    ext_id = local.cluster_pe_uuid_map[each.value.cluster_name]
  }

  lifecycle {
    ignore_changes = [
      disks
    ]
  }

  # OS Disk
  disks {
    backing_info {
      vm_disk {
        disk_size_bytes = each.value.os_disk_size_gib * 1024 * 1024 * 1024
        data_source {
          reference {
            image_reference {
              image_ext_id = data.nutanix_image.img[each.key].metadata["uuid"]
            }
          }
        }
      }
    }
    disk_address {
      bus_type = "SCSI"
      index    = 0
    }
  }

  # Data Disks
  dynamic "disks" {
    for_each = each.value.disks

    content {
      backing_info {
        vm_disk {
          disk_size_bytes = disks.value.size_gib * 1024 * 1024 * 1024
          storage_container {
            ext_id = local.storage_container_map[each.key][disks.value.type]
          }
        }
      }
      disk_address {
        bus_type = "SCSI"
        index    = disks.key + 1
      }
    }
  }

  # NIC
  nics {
    network_info {
      nic_type = "NORMAL_NIC"
      subnet {
        ext_id = local.subnet_uuid_map[each.key]
      }
    }
  }
}

resource "null_resource" "migrate_os_disk" {
  for_each = var.vms

  depends_on = [nutanix_virtual_machine_v2.vm]

  triggers = {
    vm_id = nutanix_virtual_machine_v2.vm[each.key].id
  }

  provisioner "local-exec" {
    command = <<EOT
powershell -Command "
  add-type @'
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
      public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; }
    }
'@
  [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
  [System.Net.ServiceProtocolType]::Tls12

  $$cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('admin:${var.pc_password}'))
  $$vm_id = '${nutanix_virtual_machine_v2.vm[each.key].id}'
  $$container_id = '${local.storage_container_map[each.key]["normal"]}'

  # VM 디스크 목록 조회
  $$disks = Invoke-RestMethod -Uri \"https://pc.nutanix.local:9440/api/vmm/v4.0.a1/ahv/config/vms/$$vm_id/disks\" -Headers @{Authorization = \"Basic $$cred\"}

  # OS 디스크 ext_id 추출
  $$os_disk_id = $$disks.data[0].extId

  # 디스크 마이그레이션
  $$body = @{
    migrationPlan = @(
      @{
        diskExtId = $$os_disk_id
        targetContainerExtId = $$container_id
      }
    )
  } | ConvertTo-Json -Depth 5

  Invoke-RestMethod -Uri \"https://pc.nutanix.local:9440/api/vmm/v4.0.a1/ahv/config/vms/$$vm_id/`$$actions/migrate-disks\" -Method POST -Headers @{Authorization = \"Basic $$cred\"; 'Content-Type' = 'application/json'} -Body $$body
"
EOT
  }
}

########################
# Volume Group 생성
########################
resource "nutanix_volume_group_v2" "vg" {
  for_each          = var.volume_groups
  name              = each.key
  should_load_balance_vm_attachments = true
  cluster_reference = local.cluster_pe_uuid_map[each.value.cluster_name]
}

########################
# VG 디스크 추가
########################
resource "nutanix_volume_group_disk_v2" "vg_disk" {
  for_each = local.vg_disk_list

  volume_group_ext_id = nutanix_volume_group_v2.vg[each.value.vg_name].id
  disk_size_bytes     = each.value.disk.size_gib * 1024 * 1024 * 1024

  disk_data_source_reference {
    ext_id = (
      each.value.disk.type == "db"
      ? local.vg_storage_container_map[each.value.vg_name].db
      : local.vg_storage_container_map[each.value.vg_name].normal
    )
    entity_type = "STORAGE_CONTAINER"
  }
}

########################
# VG ↔ VM 연결
########################
resource "nutanix_volume_group_vm_v2" "vg_attach" {
  for_each = local.vm_vg_attachments

  volume_group_ext_id = nutanix_volume_group_v2.vg[each.value.vg_name].id
  vm_ext_id           = nutanix_virtual_machine_v2.vm[each.value.vm_name].id
}

main.tf

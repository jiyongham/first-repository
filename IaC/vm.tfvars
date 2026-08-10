volume_groups = {
    scsic-iepdevx-db = {
        cluster_name = "SSG-K-SDNCommE"
        disks = [{
            size_gib = 900
            type = "db"
        }]
    }

    dr-scsic-iepdevx-db = {
        cluster_name = "SSG-DR-SDNCommA"
        disks = [{
            size_gib = 900
            type = "db"
        }]
    }
}

vms = {
 scsic-iepdevx-db = {
    cluster_name = "SSG-K-SDNCommE"
    vlan_id = 2131
    template_name = "{T}_temp-rhel9.7-SSE"
    num_sockets = 8
    num_vcpus_per_socket = 1
    memory_size_gib = 4
    volume_groups = ["scsic-iepdevx-db"]
 }

 dr-scsic-iepdevx-db = {
    cluster_name = "SSG-DR-SDNCommA"
    vlan_id = 2131
    template_name = "{T}_temp-rhel9.7-SSE"
    num_sockets = 8
    num_vcpus_per_socket = 1
    memory_size_gib = 4
    volume_groups = ["dr-scsic-iepdevx-db"]
 }
}


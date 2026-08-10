all_data = []

def get_nutanix_data_multi_pe_v2():
    """
    여러 PE 클러스터 v2 API를 통해 VG 및 VM 정보를 수집하는 함수
    """
    pe_user = input("Enter Nutanix username: ")
    pe_password = getpass("Enter Nutanix password: ")
        
    if not pe_user or not pe_password:
        print("Error: 계정정보 오류")
        return

    requests.packages.urllib3.disable_warnings()

    # 프리즘 엘리먼트 순회
    for pe_ip, cluster_name in PE_CLUSTERS.items():
        base_url = f"https://{pe_ip}:9440/api/nutanix/v2.0"
        auth = (pe_user, pe_password)

        print(f"Processing Prism Element: {cluster_name} ({pe_ip})")

        try:
            # 모든 VG 목록 가져오기
            vg_url = f"{base_url}/volume_groups"
            vg_response = requests.get(vg_url, auth=auth, verify=False)
            vg_response.raise_for_status()
            vg_list = vg_response.json()
            
            # 모든 VM 목록 가져오기
            vm_url = f"{base_url}/vms"
            vm_response = requests.get(vm_url, auth=auth, verify=False)
            vm_response.raise_for_status()
            vm_list = vm_response.json()

            vm_info = {}
            ip = "N/A"
            for vm in vm_list.get('entities', []):
                                   
                    vm_info[vm['uuid']] = {
                        'name': vm.get('name', 'N/A'),
                        'state': vm.get('power_state', 'N/A'),
                    }

                    # nics = vm.get("status", {}).get("resources", {}).get("nic_list", [])
                    #     if nics:
                    #         ips = nics[0].get("ip_endpoint_list", "N/A")
                    #         for ip in ips:
                    #             ip_address = ip.get("ip")
                #     'ip': ', '.join([
                #         ip for nic in vm.get('vm_nics', [])
                #             for ip in nic.get('ip_addresses', [])
                #         or 'N/A'
                #     ])
                # }

            for vg in vg_list.get('entities', []):
                vg_name = vg['name']
                vm_uuids = [a.get('vm_uuid') for a in vg.get('attachment_list', []) if a.get('vm_uuid')]
                
                if not vm_uuids:
                    all_data.append({'Cluster Name': cluster_name, 'Volume Group Name': vg_name, 'VM Name': 'N/A', 'VM IP': 'N/A', 'VM State': 'N/A'})
                    continue
                
                for vm_uuid in vm_uuids:
                    vm_details = vm_info.get(vm_uuid)
                    if vm_details:
                        all_data.append({'Cluster Name': cluster_name, 'Volume Group Name': vg_name, 'VM Name': vm_details['name'], 'VM IP': vm_details['ip'], 'VM UUID': vm_uuid, 'VM State': vm_details['state']})
                    else:
                        all_data.append({'Cluster Name': cluster_name, 'Volume Group Name': vg_name, 'VM Name': f'VM not found (UUID: {vm_uuid})', 'VM IP': 'N/A', 'VM UUID': vm_uuid, 'VM State': 'N/A'})
        except requests.exceptions.RequestException as e:
            print(f"Error processing {cluster_name} ({pe_ip}): {e}")


def create_excel_report():
    if not all_data:
        print("No data collected. Exiting.")
        return
    df = pd.DataFrame(all_data)
    output_filename = 'vg_vm_connection.xlsx'
    try:
        df.to_excel(output_filename, index=False)
        print(f"Successfully created Excel file: {output_filename}")
    except Exception as e:
        print(f"Failed to create Excel file: {e}")

if __name__ == "__main__":
    get_nutanix_data_multi_pe_v2()
    create_excel_report()

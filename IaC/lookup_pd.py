# API 접속을 위한 자격 증명 입력
username = input("Enter Nutanix username: ")
password = getpass("Enter Nutanix password: ")

# API 요청 헤더 생성
# Base64로 인코딩된 인증 정보를 헤더에 포함합니다.
auth_string = base64.b64encode(f"{username}:{password}".encode()).decode()
headers = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "Authorization": f"Basic {auth_string}"
}

# CSV 파일 설정
output_filename = "nutanix_protection_domains.csv"
fieldnames = [
    "Cluster_Name",
    "Active",
    "Protection_Domain_Name",
    "Entities",
    "Schedule",
    "Remote_Site_Names"
]

def get_protection_domains(cluster_ip):
    """지정된 클러스터에서 데이터 보호 도메인 목록을 가져옵니다."""
    url = f"https://{cluster_ip}:9440/PrismGateway/services/rest/v2.0/protection_domains/"
    try:
        response = requests.get(url, headers=headers, verify=False, timeout=30)
        response.raise_for_status()  # HTTP 오류 발생 시 예외 처리
        return response.json().get('entities', [])
    except requests.exceptions.RequestException as e:
        print(f"Error connecting to {cluster_ip}: {e}", file=sys.stderr)
        return []

def main():
    """메인 함수: 여러 클러스터에서 데이터 보호 정보를 수집하고 CSV 파일로 저장합니다."""
    
    all_pd_info = []

    for cluster_ip, cluster_name in cluster_mapping.items():
        print(f"Collecting data protection info from cluster: {cluster_name} ({cluster_ip})...")
        
        protection_domains = get_protection_domains(cluster_ip)
        
        if not protection_domains:
            print(f"No protection domains found or failed to connect to {cluster_ip}.")
            continue
            
        for pd in protection_domains:
            pd_name = pd.get("name")
            pd_remote_site = pd.get("remote_site_names")
            pd_active = pd.get("active")

            # 보호 도메인에 포함된 엔티티(VM/VG 등) 목록
            entities = [vms.get("vm_name") for vms in pd.get("vms", [])]
            
            # 복제 정보 처리
            is_scheduled = "N/A"
            remote_site_name = "N/A"

            if pd.get("cron_schedules"):
                for schedule in pd["cron_schedules"]:
                    is_scheduled = schedule.get("type")
            
            all_pd_info.append({
                "Cluster_Name": cluster_name,
                "Active": pd_active,
                "Protection_Domain_Name": pd_name,
                "Entities": ", ".join(entities),
                "Schedule": is_scheduled,
                "Remote_Site_Names" : pd_remote_site
            })
    
    if all_pd_info:
        # CSV 파일에 데이터 쓰기
        with open(output_filename, 'w', newline='', encoding='cp949') as csvfile:
            writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(all_pd_info)
        print(f"Successfully collected data and saved to {output_filename}")
    else:
        print("No data collected.")

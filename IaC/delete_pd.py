def list_protection_domains(host, auth, verify=False):
    url = f"https://{host}:9440/PrismGateway/services/rest/v2.0/protection_domains"
    resp = requests.get(url, auth=auth, verify=verify)
    resp.raise_for_status()
    data = resp.json()
    pds = data.get("entities") if isinstance(data, dict) else data
    results = []
    for item in pds or []:
        name = item.get("name") if isinstance(item, dict) else str(item)
        if name:
            results.append({"name": name, "entity": item})
    return results

def get_pd_details(host, name, auth, verify=False):
    url = f"https://{host}:9440/PrismGateway/services/rest/v2.0/protection_domains/{quote(name, safe='')}"
    resp = requests.get(url, auth=auth, verify=verify)
    resp.raise_for_status()
    return resp.json()

def matches_cron_schedule(entity, skip_types=None):
    schedules = (entity or {}).get("cron_schedules") or []
    if not schedules:
        return False
    if not skip_types:
        return True
    types = {str(s.get("type")).upper() for s in schedules if s.get("type") is not None}
    skip_set = {t.upper() for t in (skip_types or [])}
    return bool(types & skip_set)

def should_skip(name, entity_or_detail, exclude_keywords, skip_types=None):
    lower_name = name.lower()
    for kw in exclude_keywords:
        if kw.lower() in lower_name:
            return True
    if matches_cron_schedule(entity_or_detail, skip_types=skip_types):
        return True
    return False

# 방법 A) PD 상세 JSON에서 후보 키들로 DR 스냅샷 ID를 추출(버그 수정 및 키 확장)
def extract_dr_snapshot_ids(pd_detail):
    """
    PD 상세에서 DR 스냅샷 ID 목록 추출.
    확실하지 않음: 키 이름은 배포/버전에 따라 다를 수 있습니다.
    확인한 후보:
      - 목록 키: 'dr_snapshots', 'remote_snapshots', 'replication_snapshots', 'snapshots'
      - ID 키: 'snapshot_id', 'id', 'uuid', 'remote_snapshot_id'
    """
    ids = []
    list_keys = ("dr_snapshots", "remote_snapshots", "replication_snapshots", "snapshots")
    id_keys = ("snapshot_id", "id", "uuid", "remote_snapshot_id")
    for lk in list_keys:
        snaps = pd_detail.get(lk) or []
        if isinstance(snaps, list):
            for s in snaps:
                for ik in id_keys:
                    sid = s.get(ik)
                    if sid is not None:
                        ids.append(str(sid))
                        break
    # 중복 제거 후 반환
    return list(dict.fromkeys(ids))

# 방법 B) 전용 엔드포인트로 DR 스냅샷 목록을 조회(권장: 환경에 맞게 endpoint_path 확인 필요)
def list_dr_snapshots(host, pd_name, auth, verify=False, endpoint_path=None):
    """
    DR 스냅샷 목록 전용 엔드포인트로 조회.
    확실하지 않음: 기본값으로 '/protection_domains/{name}/dr_snapshots'를 시도.
    환경에 따라 다른 경로일 수 있으니 endpoint_path로 지정 가능.
    """
    candidates = []
    if endpoint_path:
        candidates = [endpoint_path]
    else:
        # 후보 경로들(확실하지 않음): 실제 환경/문서에 맞게 조정 필요
        candidates = [
            f"/PrismGateway/services/rest/v2.0/protection_domains/{quote(pd_name, safe='')}/dr_snapshots",
            f"/PrismGateway/services/rest/v2.0/protection_domains/{quote(pd_name, safe='')}/snapshots",
        ]

    for path in candidates:
        url = f"https://{host}:9440{path}"
        try:
            resp = requests.get(url, auth=auth, verify=verify)
            if resp.status_code == 404:
                continue
            resp.raise_for_status()
            data = resp.json()
            # 응답 형태를 유연하게 처리
            if isinstance(data, list):
                items = data
            elif isinstance(data, dict):
                items = data.get("entities") or data.get("dr_snapshots") or data.get("snapshots") or []
            else:
                items = []

            # ID 키 후보로 ID 추출
            id_keys = ("snapshot_id", "id", "uuid", "remote_snapshot_id")
            ids = []
            for s in items:
                for ik in id_keys:
                    sid = s.get(ik)
                    if sid is not None:
                        ids.append(str(sid))
                        break
            return list(dict.fromkeys(ids))  # 중복 제거 후 반환
        except requests.HTTPError:
            # 다른 후보 경로 시도
            continue
        except Exception:
            # 예외 시 다음 후보로
            continue

    # 모든 후보 실패 시 빈 리스트 반환
    return []

def delete_dr_snapshot(host, pd_name, snapshot_id, auth, verify=False):
    """
    DR 스냅샷 단건 삭제.
    엔드포인트 확실하지 않음: 환경에 맞는 경로 확인 필요.
    기본 가정: DELETE /protection_domains/{pd_name}/dr_snapshots/{snapshot_id}
    """
    url = f"https://{host}:9440/PrismGateway/services/rest/v2.0/protection_domains/{quote(pd_name, safe='')}/dr_snapshots/{quote(str(snapshot_id), safe='')}"
    resp = requests.delete(url, auth=auth, verify=verify)
    if resp.status_code in (200, 202, 204):
        return True
    try:
        resp.raise_for_status()
    except Exception as e:
        print(f"Failed to delete snapshot '{snapshot_id}' in PD '{pd_name}': {e}")
        return False
    return False

def delete_dr_snapshots(host, pd_name, pd_detail, auth, verify=False, dry_run=True, endpoint_path=None):
    """
    DR 스냅샷 삭제 흐름:
    1) 전용 엔드포인트로 목록 조회 시도(list_dr_snapshots).
    2) 실패/빈 결과면 PD 상세에서 추출(extract_dr_snapshot_ids)로 보조.
    """
    ids = list_dr_snapshots(host, pd_name, auth, verify=verify, endpoint_path=endpoint_path)
    if not ids:
        ids = extract_dr_snapshot_ids(pd_detail)

    attempted, deleted, failed = [], [], []
    for sid in ids:
        attempted.append(sid)
        if dry_run:
            print(f"Dry-run: would delete snapshot '{sid}' in PD '{pd_name}'")
            # dry-run에서는 실제 삭제하지 않음
        else:
            ok = delete_dr_snapshot(host, pd_name, sid, auth, verify=verify)
            if ok:
                deleted.append(sid)
                print(f"Deleted snapshot '{sid}' in PD '{pd_name}'")
            else:
                failed.append(sid)
    return {"attempted": attempted, "deleted": deleted, "failed": failed}

def delete_protection_domain(host, name, auth, verify=False):
    url = f"https://{host}:9440/PrismGateway/services/rest/v2.0/protection_domains/{quote(name, safe='')}"
    resp = requests.delete(url, auth=auth, verify=verify)
    if resp.status_code in (200, 202, 204):
        return True
    try:
        resp.raise_for_status()
    except Exception as e:
        print(f"Failed to delete PD '{name}': {e}")
        return False
    return False

def cleanup_pds(host, username, password, exclude_keywords, skip_types=None, dry_run=True, verify=False, dr_snapshots_endpoint=None):
    if not verify:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    auth = HTTPBasicAuth(username, password)
    items = list_protection_domains(host, auth, verify=verify)

    deleted = []
    skipped = []
    snapshot_summary = {}

    for item in items:
        name = item["name"]
        entity = item.get("entity") or {}
        try:
            # 목록 엔티티 기준으로 스케줄 제외 판단
            if should_skip(name, entity, exclude_keywords, skip_types=skip_types):
                skipped.append(name)
                print(f"Skip: {name}")
                continue

            # 상세 조회 후 DR 스냅샷 처리(전용 엔드포인트 우선)
            detail = get_pd_details(host, name, auth, verify=verify)
            snap_res = delete_dr_snapshots(
                host, name, detail, auth, verify=verify, dry_run=dry_run,
                endpoint_path=dr_snapshots_endpoint
            )
            snapshot_summary[name] = snap_res

            # DR 스냅샷 삭제 실패가 있으면 PD 삭제는 건너뜀(안전)
            if snap_res["failed"]:
                print(f"Skip PD delete due to failed snapshot deletions in '{name}': {snap_res['failed']}")
                skipped.append(name)
                continue

            # PD 삭제
            if dry_run:
                print(f"Dry-run: would delete PD '{name}'")
            else:
                if delete_protection_domain(host, name, auth, verify=verify):
                    deleted.append(name)
                    print(f"Deleted PD: {name}")
        except requests.HTTPError as e:
            print(f"Error on '{name}': {e}")
        except Exception as e:
            print(f"Unexpected error on '{name}': {e}")

    return {"deleted": deleted, "skipped": skipped, "dry_run": dry_run, "snapshots": snapshot_summary}

if __name__ == "__main__":
    host = input("Enter Nutanix Prism Element: ")
    username = input("Enter Nutanix username: ")
    password = getpass.getpass(prompt="Prism Password: ")

    exclude_keywords = ["delete","remove"]
    skip_types = None  # 예: ["SNAPSHOT", "REPLICATION"]

    # 환경에서 사용하는 정확한 DR 스냅샷 목록 엔드포인트가 있다면 지정(예: "/PrismGateway/services/rest/v2.0/protection_domains/{name}/dr_snapshots")
    dr_snapshots_endpoint = None

    # 1) 먼저 dry-run으로 확인
    # result = cleanup_pds(
    #     host, username, password, exclude_keywords,
    #     skip_types=skip_types, dry_run=True, verify=False,
    #     dr_snapshots_endpoint=dr_snapshots_endpoint
    # )
    # print(result)

    # 2) 실제 삭제 수행하려면 주석 해제
    result = cleanup_pds(host, username, password, exclude_keywords, skip_types=skip_types, dry_run=False, verify=False)


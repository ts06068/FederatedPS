# YUHS CDM 공개 코호트와 선택 preset 실행

Windows/ODBC 환경에 FederatedPS `dev` 커밋
`2cb2ec905f51680b01e692230927e9efccc7a9c0`의 공개 비교 18개를 포함함.
포함 범위는 dev 등록 목록 전체임. dev에서 유지하는 PS 벤치마크용
`studySpecific` JSON을 사용하며 원 논문의 치료 효과는 추정하지 않음.

| 실행 순서 | 목록 | 시나리오 | 조합 수 |
|---|---|---|---:|
| 1 | 논문 기반 공개 비교 | studySpecific | 14 |
| 2 | Phenotype Library 기반 공개 비교 | studySpecific | 4 |
| 3 | opioid, ppi, statin | studySpecific | 3 |

공개 비교의 ID, 논문 DOI, Phenotype Library ID, 적용 시 변경 내용은
[`inst/studies/registry.json`](../inst/studies/registry.json)에 기록함.
해당 문헌은 비교의 근거이며 Windows 분석의 사이트 정책과 PS 적합은
기존 FederatedPS 방식임. UTI 비교 세 개는 dev에서 일부 MedDRA
제외 seed 부재로 중단된 기록이 있음. YUHS에서 해당 seed를 확인하며
누락 시 오류를 기록하고 다음 비교를 실행함. YUHS 실제 적격 환자 수와
모델 완료 여부는 실행 후 확인할 수 있음.

## 실행

기존 Windows ODBC 번들에 CDM 업데이트 v0.0.14를 적용하고
HIWARE에 로그인한 뒤 실행함.

```powershell
Set-Location C:\FP
.\RUN.ps1 -PlanOnly | Format-Table
.\RUN.ps1
```

CDM 비교만 먼저 확인하려면 두 번째 명령에 `-Family Cdm`을 추가함.
하나의 비교를 실행하려면 기존 `05_RUN_YUHS.ps1`의 `-Study`와
`-Scenario studySpecific`을 지정함. 배치는 ODBC 접속을 한 번 확인하고
비교를 순차 실행함. 기본 환자 수 상한은 없으며, CDM 비교의 기관 동시
실행 수는 1, preset은 3임. CDM 비교는 기관별 세션에서 동일한 코호트
조건을 적용하므로 `-CdmExtractionWorkers 3`을 쓰면 DB 부하가 늘 수 있음.

결과는 `FederatedPS\work\all-studies\<study>\<scenario>\<RunId>`에
저장함. 각 조합 상태와 경로는 상위 폴더의 `batch-status.csv`에 기록함.
`batch-timing.csv`는 조합별 경과 시간, 전처리·모델 단계 시간(FitSeconds),
SMD 시간(SmdSeconds), 기관 동시 실행 수(Workers)를 초 단위로 기록함.
완료한 결과 재사용 시 FitSeconds는 비워 둠.
같은 설정으로 재실행하면 성공한 모델 결과를 재사용함. 실패한 조합이
있어도 뒤의 조합을 실행한 후 배치가 오류를 반환함.

기본 실행은 각 성공 폴더에 `smd_summary.csv`와
`smd_covariates.csv`를 생성함. 각 기관에서 local-only와 pooled의 PS로
별도로 1:1 매칭함. caliper는 logit(PS) 표준편차의 0.2배이며 SMD 분모는
매칭 전 분산으로 고정함. PS 결과와 정확한 기관별 캐시를 사용함. PS 적합만 하려면 `-SkipSmd` 사용.

## SQL Server 연결

CirceR 1.3.3으로 미리 생성한 SQL을 기존 SqlRender 경로에서 렌더링함.
등록된 두 군의 정의와 index date를 유지함. 양 군이 같은 날짜에 시작하는
경우를 제외한 후 첫 적격 index를 선택함. Windows YUHS에서는 해당
환자·날짜·군의 약제 노출이 해당 기관 방문과 연결되고 다른 양의
CARE_SITE_ID 방문이 없는 환자만 남김. 공변량은 기관에 연결된 기록 중
index 이전 날짜로 제한함. 코호트와 코드 집합은 세션 임시 테이블에
생성함. dev의 SynPUF 가상 기관 landmark는 YUHS에 적용하지 않음.

개별 실행기는 기존 preset의 정의와 실행 인자를 유지함. 데이터 캐시는 추출 코드와
코호트 정의를 식별하므로 업데이트 후의 첫 실행에서 예전 캐시를 다시
만들 수 있음.


## 시간 계획

첨부된 ppi/default 실측은 199,212명, 총 38분 01초였음. 기관 3개를
병렬로 준비하는 구간은 16분 44초, 이후 모델 단계는 21분 17초였음.
같은 처리량으로 단순 환산하면 21개를 모두 기관 병렬로 돌릴 때
약 13시간 18분, CDM 18개를 기관별 순차로 처리하는 기본값에서는
약 17시간 32분임. SMD와 재시도는 이 환산값에 포함되지 않음.
6시간에 21개를 끝내려면 SMD까지 포함해 조합당 평균 17분 9초 이내가
필요함. YUHS의 실제 studySpecific 적격 환자 수와 코호트 쿼리 시간은
아직 측정되지 않았음.

실제 속도 확인용으로 아래처럼 CDM과 preset을 일부 먼저 실행할 수 있음.
같은 작업 폴더와 환자 수 설정으로 전체 실행하면 성공한 적합을 재사용함.

```powershell
.\RUN.ps1 -Study ohdsi_htn_acei_arb,ppi -CdmExtractionWorkers 3
.\RUN.ps1 -CdmExtractionWorkers 3
```

세 기관의 SQL을 동시에 수행하면 DB 병목이 생길 수 있음. 초기 실측에서
접속 대기나 DB 쿼리 시간이 늘면 `-CdmExtractionWorkers 1`로 실행함.
환자 수 상한을 건 시험 실행은 표본이 달라져 전체 코호트 실행과 별개임.

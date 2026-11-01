param([ValidatePattern('^[A-Za-z0-9_-]+\.json$')][string]$OutputName='embedding-qualification.json')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aux_device_common.ps1')
Connect-AuxDevice
$resultRoot=Join-Path $script:AuxRoot 'private/note20-auxiliary/step2'
$testApk=Join-Path $script:AuxRoot 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'
Invoke-AuxAdb @('install','--no-streaming','-r','-t',$testApk) | Out-Null
$inputs=@(
  @('private/retrieval-stage/oil-filter-int8.mrag','cache/maintenance-import-probe.mrag'),
  @('private/retrieval-stage/parity-probes.json','files/rag-probes.json'),
  @('private/retrieval-stage/pc-rankings.json','files/rag-pc-rankings.json')
)
foreach($item in $inputs){
  $source=Join-Path $script:AuxRoot $item[0]
  $remote='/data/local/tmp/aux-reference-input'
  Invoke-AuxAdb @('push',$source,$remote)|Out-Null
  try {
    Invoke-AuxAdb @('shell','run-as',$script:AuxPackage,'mkdir','-p','files','cache')|Out-Null
    Invoke-AuxAdb @('shell','run-as',$script:AuxPackage,'cp',$remote,$item[1])|Out-Null
  } finally {Invoke-AuxAdb @('shell','rm','-f',$remote)|Out-Null}
}
Invoke-AuxAdb @('shell','am','force-stop',$script:AuxPackage)|Out-Null
$instrument=@(Invoke-AuxAdb @('shell','am','instrument','-w','-e','entry','ragDeviceProbe','-e','threads','2','-e','auxiliaryPhone','true',"$script:AuxPackage.test/$script:AuxPackage.RagInstrumentation"))
$raw=(Invoke-AuxAdb @('shell','run-as',$script:AuxPackage,'cat','files/rag-probe-result.json')) -join "`n"
$data=$raw|ConvertFrom-Json -AsHashtable
if($data.privacyFilterAppliedBeforeWriting -ne $true){throw '시험 결과의 저장 전 개인정보 필터를 확인하지 못했습니다.'}
$data['testApkSha256']=(Get-FileHash -LiteralPath $testApk -Algorithm SHA256).Hash.ToLowerInvariant()
$data['threadCondition']=2
$data['purpose']='physical_auxiliary_embedding_parity_qualification_not_latency_distribution'
Save-AuxReport (Join-Path $resultRoot $OutputName) $data
[ordered]@{
  status=$data.status
  tokenCases=$data.tokenizerParityCases
  rankingCases=$data.rankingCases.Count
  orderedEvidenceRanksEqual=$data.orderedEvidenceRanksEqual
  minCosine=($data.parityCases|ForEach-Object {$_.cosine}|Measure-Object -Minimum).Minimum
  unloadConfirmed=$data.unloadConfirmed
  workerRecovery=$data.workerRecovery
  rawQuestionsOrImagesLogged=$false
  nativeFailures=$data.nativeFailures
}|ConvertTo-Json

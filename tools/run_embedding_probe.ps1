param(
  [Parameter(Mandatory=$true)][string]$Serial,
  [string]$Adb = "$env:LOCALAPPDATA/Android/sdk/platform-tools/adb.exe",
  [string]$FixtureDirectory = '',
  [string]$OutputDirectory = '',
  [ValidateSet('ragDeviceProbe','optionalModelDeviceProbe','visionDeviceProbe','flowDeviceProbe','systemPilotDeviceProbe','ragUtilityDeviceProbe')][string]$Entry = 'ragDeviceProbe',
  [ValidateRange(1,4)][int]$Threads = 2,
  [ValidateRange(0,5000)][int]$UserWaitMs = 1000,
  [string]$LlmModel = '',
  [string]$VisionModel = '',
  [string]$VisionDog = '',
  [string]$VisionEmpty = '',
  [string]$SystemPilot = '',
  [string]$SystemProbes = '',
  [string]$UtilityQuestions = ''
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$privateRoot = [IO.Path]::GetFullPath((Join-Path $workspace 'private'))
if (!$FixtureDirectory) { $FixtureDirectory = Join-Path $privateRoot 'retrieval-stage' }
if (!$OutputDirectory) { $OutputDirectory = Join-Path $privateRoot ('retrieval-stage/device-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
foreach ($path in @($FixtureDirectory, $OutputDirectory)) {
  if (![IO.Path]::GetFullPath($path).StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw '시험 입력과 결과는 이 작업공간의 private 내부에 있어야 합니다.'
  }
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
function AdbChecked([string[]]$Arguments) {
  $lines = @(& $Adb -s $Serial @Arguments 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE -ne 0) { throw ('선택한 기기의 ADB 실행 실패: ' + ($lines -join "`n")) }
  $lines
}
if ((AdbChecked @('get-state') | Out-String).Trim() -ne 'device') { throw '선택한 기기가 연결되지 않았습니다.' }
& (Join-Path $PSScriptRoot 'collect_tablet_baseline.ps1') -Adb $Adb -Serial $Serial -OutputDirectory (Join-Path $OutputDirectory 'baseline')
$apk = Join-Path $workspace 'build/app/outputs/apk/debug/app-debug.apk'
$testApk = Join-Path $workspace 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'
$metadata = [ordered]@{ capturedAt=(Get-Date).ToString('o'); entry=$Entry;
  apkSha256=(Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant();
  testApkSha256=(Get-FileHash -LiteralPath $testApk -Algorithm SHA256).Hash.ToLowerInvariant();
  fixtureSha256=(Get-FileHash -LiteralPath (Join-Path $FixtureDirectory 'oil-filter-int8.mrag') -Algorithm SHA256).Hash.ToLowerInvariant() }
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'run-metadata.json') -Encoding utf8
AdbChecked @('install','--no-streaming','-r','-t',$apk) | Set-Content (Join-Path $OutputDirectory 'install-app.log')
AdbChecked @('install','--no-streaming','-r','-t',$testApk) | Set-Content (Join-Path $OutputDirectory 'install-test.log')
$package = 'com.superkid.military.military_maintenance'
$inputs = @(
  @('oil-filter-int8.mrag','cache/maintenance-import-probe.mrag'),
  @('parity-probes.json','files/rag-probes.json'),
  @('pc-rankings.json','files/rag-pc-rankings.json')
)
foreach ($inputFile in $inputs) {
  $source = Join-Path $FixtureDirectory $inputFile[0]
  $remote = '/data/local/tmp/maintenance-' + $inputFile[0]
  AdbChecked @('push',$source,$remote) | Out-Null
  AdbChecked @('shell','run-as',$package,'mkdir','-p','files','cache') | Out-Null
  AdbChecked @('shell','run-as',$package,'cp',$remote,$inputFile[1]) | Out-Null
}
if ($Entry -in @('optionalModelDeviceProbe','flowDeviceProbe','ragUtilityDeviceProbe')) {
  if (!$LlmModel) { throw '선택 LLM 시험은 사전 반입한 공개 .gguf 경로가 필요합니다.' }
  AdbChecked @('push',$LlmModel,'/data/local/tmp/maintenance-llm.gguf') | Out-Null
  AdbChecked @('shell','run-as',$package,'cp','/data/local/tmp/maintenance-llm.gguf','cache/maintenance-import-llm.gguf') | Out-Null
}
if ($Entry -in @('visionDeviceProbe','flowDeviceProbe')) {
  foreach ($item in @(@($VisionModel,'maintenance-import-vision.onnx'),@($VisionDog,'vision-public-dog.png'),@($VisionEmpty,'vision-public-empty.png'))) {
    if (!$item[0]) { throw 'Vision 모델과 두 공개 검증 이미지 경로가 필요합니다.' }
    $remote = '/data/local/tmp/' + $item[1]
    AdbChecked @('push',$item[0],$remote) | Out-Null
    AdbChecked @('shell','run-as',$package,'cp',$remote,('cache/' + $item[1])) | Out-Null
  }
}
if ($SystemPilot) {
  AdbChecked @('push',$SystemPilot,'/data/local/tmp/maintenance-system.msystem') | Out-Null
  AdbChecked @('shell','run-as',$package,'cp','/data/local/tmp/maintenance-system.msystem','cache/maintenance-import-system.msystem') | Out-Null
}
if ($SystemProbes) {
  AdbChecked @('push',$SystemProbes,'/data/local/tmp/maintenance-system-probes.json') | Out-Null
  AdbChecked @('shell','run-as',$package,'cp','/data/local/tmp/maintenance-system-probes.json','files/system-probes.json') | Out-Null
}
if ($Entry -eq 'ragUtilityDeviceProbe') {
  if (!$UtilityQuestions -or ![IO.Path]::GetFullPath($UtilityQuestions).StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw '평가 질문은 private 내부 경로가 필요합니다.' }
  $metadata['questionsSha256'] = (Get-FileHash -LiteralPath $UtilityQuestions -Algorithm SHA256).Hash.ToLowerInvariant()
  $metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'run-metadata.json') -Encoding utf8
  AdbChecked @('push',$UtilityQuestions,'/data/local/tmp/maintenance-utility-questions.json') | Out-Null
  AdbChecked @('shell','run-as',$package,'cp','/data/local/tmp/maintenance-utility-questions.json','files/rag-utility-questions.json') | Out-Null
}
AdbChecked @('shell','am','instrument','-w','-e','entry',$Entry,'-e','threads',"$Threads",'-e','userWaitMs',"$UserWaitMs","$package.test/$package.RagInstrumentation") | Set-Content (Join-Path $OutputDirectory 'instrumentation.log')
$raw = AdbChecked @('shell','run-as',$package,'cat','files/rag-probe-result.json')
$raw | Set-Content -LiteralPath (Join-Path $OutputDirectory 'emulator-or-device-result.json') -Encoding utf8
$report = ($raw -join "`n") | ConvertFrom-Json
if ($report.status -ne 'passed') { throw "실측 시험이 통과하지 않았습니다: $($report.status). private 결과 파일을 확인하세요." }
Write-Output '선택한 모델 경로의 계측 검사가 통과했습니다. PC/에뮬레이터/실기기 구분과 시험 범위는 결과 파일에서 확인하세요.'

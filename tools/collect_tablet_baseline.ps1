param(
  [string]$Adb = "$env:LOCALAPPDATA/Android/sdk/platform-tools/adb.exe",
  [string]$Serial = '',
  [string]$OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$privateRoot = [IO.Path]::GetFullPath((Join-Path $workspace 'private'))
if (!$OutputDirectory) {
  $OutputDirectory = Join-Path $privateRoot ('tablet-test/device-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$target = [IO.Path]::GetFullPath($OutputDirectory)
if (!$target.StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Device output must remain inside this workspace private directory.'
}
$deviceLines = @(& $Adb devices)
if ($LASTEXITCODE -ne 0) { throw 'ADB device discovery failed.' }
$connected = @($deviceLines | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
if (!$Serial) {
  if ($connected.Count -ne 1) { throw 'Connect exactly one authorized USB device, or specify -Serial. No measurements collected.' }
  $Serial = $connected[0]
}
if ($connected -notcontains $Serial) { throw 'Selected device is not authorized and connected.' }
New-Item -ItemType Directory -Path $target -Force | Out-Null
$checks = [ordered]@{
  qemu = @('getprop','ro.kernel.qemu')
  model = @('getprop','ro.product.model')
  device = @('getprop','ro.product.device')
  android = @('getprop','ro.build.version.release')
  api = @('getprop','ro.build.version.sdk')
  abi = @('getprop','ro.product.cpu.abilist')
  build = @('getprop','ro.build.fingerprint')
  memory = @('cat','/proc/meminfo')
  storage = @('df','/data')
  display = @('wm','size')
  density = @('wm','density')
  airplane = @('settings','get','global','airplane_mode_on')
  wifi = @('settings','get','global','wifi_on')
  bluetooth = @('settings','get','global','bluetooth_on')
  battery = @('dumpsys','battery')
  thermal = @('dumpsys','thermalservice')
  application = @('dumpsys','package','com.superkid.military.military_maintenance')
  app_memory = @('dumpsys','meminfo','com.superkid.military.military_maintenance')
}
$results = [ordered]@{ capturedAt = (Get-Date).ToString('o'); platform = 'unknown-android'; deviceSerial = $Serial; checks = [ordered]@{} }
foreach ($entry in $checks.GetEnumerator()) {
  $arguments = @('-s', $Serial, 'shell') + $entry.Value
  $value = @(& $Adb @arguments 2>&1 | ForEach-Object { "$_" })
  $results.checks[$entry.Key] = @{ exitCode = $LASTEXITCODE; output = $value }
}
$qemu = ($results.checks.qemu.output -join '').Trim()
if ($results.checks.qemu.exitCode -eq 0) {
  $results.platform = if ($qemu -eq '1') { 'android-emulator' } elseif ($qemu -eq '' -or $qemu -eq '0') { 'physical-android' } else { 'unknown-android' }
}
$results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $target 'baseline.json') -Encoding utf8
Write-Output 'Baseline saved locally under private. Check per-command exit codes; runtime latency was not measured.'

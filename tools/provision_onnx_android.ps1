$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root '.tools/android-libs'
$file = Join-Path $directory 'onnxruntime-android-1.23.2.aar'
$expected = '82048d1f462218adae4ba76477089ab0ba76093d84f733540066db1a8ba6b827'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
if (!(Test-Path -LiteralPath $file)) {
  Invoke-WebRequest -Uri 'https://repo.maven.apache.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.23.2/onnxruntime-android-1.23.2.aar' -OutFile $file
}
if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
  throw 'ONNX Android runtime hash mismatch. Do not build with this file.'
}
Write-Output 'ONNX Android 1.23.2 provisioned and SHA-256 verified. The app never downloads this runtime.'

param([switch]$Offline)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
function FetchPublic([string]$Url, [string]$Path, [string]$Sha) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  if (!(Test-Path -LiteralPath $Path)) {
    if ($Offline) { throw '사전 반입 파일이 없습니다. 온라인 PC에서 공개 파일만 먼저 준비하세요.' }
    Invoke-WebRequest -Uri $Url -OutFile $Path -TimeoutSec 180
  }
  if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Sha) { throw '공개 의존성 SHA-256 불일치' }
}
$revision = '0ec4027a2a0183de87c007069adddc06e665f7de'
$zip = Join-Path $workspace '.tools/llama-src/source.zip'
FetchPublic "https://github.com/ggml-org/llama.cpp/archive/$revision.zip" $zip '96fc2e7f64478cf73b4eccb5e6e716f44579829b04c41e7aa267cec4fc2a4c54'
if (!(Test-Path -LiteralPath (Join-Path $workspace ".tools/llama-src/llama.cpp-$revision/include/llama.h"))) {
  Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $workspace '.tools/llama-src')
}
FetchPublic 'https://huggingface.co/ggml-org/Qwen3-0.6B-GGUF/resolve/13ac06624948e4d8589cb4b6f90100837342fcb8/Qwen3-0.6B-Q4_0.gguf' (Join-Path $workspace 'models/local/qwen3-0.6b/model.gguf') 'da2572f16c06133561ce56accaa822216f2391ef4d37fba427801cd6736417d4'
Write-Output '고정 리비전의 공개 소스·모델 해시 확인 완료. 앱은 외부 다운로드를 하지 않습니다.'

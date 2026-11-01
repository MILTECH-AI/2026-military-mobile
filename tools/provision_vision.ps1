param([switch]$Offline)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
$folder=Join-Path $workspace 'models/local/ssd-mobilenet'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$path=Join-Path $folder 'model.onnx'
if(!(Test-Path -LiteralPath $path)) {
  if($Offline){throw '공개 Vision 모델을 온라인 PC에서 먼저 사전 반입하세요.'}
  Invoke-WebRequest -Uri 'https://media.githubusercontent.com/media/onnx/models/c5cae0f1942c8d7727372c7b1f6b485aa39e4421/validated/vision/object_detection_segmentation/ssd-mobilenetv1/model/ssd_mobilenet_v1_12-int8.onnx' -OutFile $path -TimeoutSec 180
}
if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne '2b79e6a7fb1ec6a33f332b9b10d82d9de4b7b49dcd26b5946921bb356895c954'){throw '공개 Vision 모델 해시 불일치'}
Write-Output 'SSD MobileNet INT8 공개 모델 해시 확인 완료. 실제 부품 정확도를 검증한 결과가 아닙니다.'

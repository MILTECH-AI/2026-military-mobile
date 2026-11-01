param([string[]]$Abis = @('x86_64','arm64-v8a'), [string]$Sdk = "$env:LOCALAPPDATA/Android/sdk")
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$revision = '0ec4027a2a0183de87c007069adddc06e665f7de'
$source = Join-Path $workspace ".tools/llama-src/llama.cpp-$revision"
$cmake = Join-Path $sdk 'cmake/3.22.1/bin/cmake.exe'
$ninja = Join-Path $sdk 'cmake/3.22.1/bin/ninja.exe'
$ndk = Join-Path $sdk 'ndk/28.2.13676358'
if (!(Test-Path -LiteralPath (Join-Path $source 'include/llama.h'))) { throw '고정 리비전의 공개 llama.cpp 소스를 먼저 반입하세요.' }
foreach ($abi in $Abis) {
  if ($abi -notin @('x86_64','arm64-v8a')) { throw '선택 LLM은 검증 대상 64비트 ABI만 빌드합니다.' }
  $build = Join-Path $workspace ".tools/llama-build-$abi"
  & $cmake -S (Join-Path $workspace 'android/app/src/main/cpp') -B $build -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" "-DCMAKE_TOOLCHAIN_FILE=$ndk/build/cmake/android.toolchain.cmake" "-DLLAMA_SOURCE_DIR=$source" "-DANDROID_ABI=$abi" '-DANDROID_PLATFORM=android-28' '-DANDROID_STL=c++_static' '-DCMAKE_BUILD_TYPE=Release'
  if ($LASTEXITCODE -ne 0) { throw 'llama.cpp Android 구성 실패' }
  & $cmake --build $build --target maintenance_llama --parallel 2
  if ($LASTEXITCODE -ne 0) { throw 'llama.cpp Android 빌드 실패' }
  $target = Join-Path $workspace "android/app/src/main/jniLibs/$abi"
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  Copy-Item -LiteralPath (Join-Path $build 'libmaintenance_llama.so') -Destination $target
  & (Join-Path $ndk 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe') --strip-unneeded (Join-Path $target 'libmaintenance_llama.so')
  if ($LASTEXITCODE -ne 0) { throw '선택 LLM 라이브러리 심볼 정리 실패' }
}

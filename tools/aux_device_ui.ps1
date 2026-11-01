. (Join-Path $PSScriptRoot 'aux_device_common.ps1')
function Get-AuxUiNodes {
  $raw=(Invoke-AuxAdb @('exec-out','uiautomator','dump','/proc/self/fd/1')) -join "`n"
  $match=[regex]::Match($raw,'<hierarchy[\s\S]*</hierarchy>')
  if(!$match.Success){throw 'UI 계층 조회 실패. 원문은 저장하지 않습니다.'}
  $xml=[xml]$match.Value
  @($xml.SelectNodes('//node'))
}
function Click-AuxLabel([string]$Label) {
  $nodes=@(Get-AuxUiNodes)
  $matches=@($nodes | Where-Object { $_.text -eq $Label -or $_.'content-desc' -eq $Label })
  if(!$matches.Count){throw '지정한 UI 항목이 현재 화면에 없습니다. 입력 원문은 로그에 남기지 않습니다.'}
  $node=$matches[0]
  while($node -and $node.clickable -ne 'true'){$node=$node.ParentNode}
  if(!$node){throw '선택 항목의 클릭 가능한 조상을 찾지 못했습니다.'}
  $numbers=@([regex]::Matches($node.bounds,'\d+') | ForEach-Object {[int]$_.Value})
  if($numbers.Count -ne 4 -or $numbers[2] -le $numbers[0] -or $numbers[3] -le $numbers[1]){throw 'UI 항목이 화면 안에 있는지 확인하지 못했습니다.'}
  $x=[int](($numbers[0]+$numbers[2])/2);$y=[int](($numbers[1]+$numbers[3])/2)
  Invoke-AuxAdb @('shell','input','tap',"$x","$y") | Out-Null
}
function Set-AuxText([string]$Label,[string]$Value) {
  # Passing a variable prevents input values being written in host command logs.
  function Quote-AuxShell([string]$Text) {
    $q=[string][char]39
    $replacement=$q+[char]34+$q+[char]34+$q
    $q+$Text.Replace($q,$replacement)+$q
  }
  $out=@(Invoke-AuxAdb @('shell','am','instrument','-w','-e','selector',(Quote-AuxShell $Label),'-e','value',(Quote-AuxShell $Value),"$script:AuxPackage.test/$script:AuxPackage.AuxUiInstrumentation"))
  $raw=(Invoke-AuxAdb @('shell','run-as',"$script:AuxPackage.test",'cat','files/aux-ui-result.json')) -join "`n"
  $parsed=$raw|ConvertFrom-Json
  if($parsed.status -ne 'passed'){throw '한글 접근성 입력 실패. 필드 내용은 기록하지 않습니다.'}
}
function Set-AuxAsciiField([int]$Index,[string]$Value,[int]$ExpectedCount=6) {
  if($Value -notmatch '^[A-Za-z0-9_-]+$'){throw '이 경로는 가상 ASCII 시험값만 사용합니다.'}
  $fields=@(Get-AuxUiNodes | Where-Object {$_.package -eq $script:AuxPackage -and $_.class -eq 'android.widget.EditText'})
  if($fields.Count -ne $ExpectedCount -or $Index -ge $fields.Count){throw '현재 폼의 필드 수를 확인하지 못했습니다.'}
  $node=$fields[$Index]
  if([string]$node.text -eq $Value){return}
  if(![string]::IsNullOrEmpty([string]$node.text)){throw '기존 값이 있어 덮어쓰지 않고 중단합니다.'}
  $n=@([regex]::Matches($node.bounds,'\d+') | ForEach-Object {[int]$_.Value})
  if($n.Count -ne 4 -or $n[2] -le $n[0] -or $n[3] -le $n[1]){throw '입력 필드가 화면 안에 있는지 확인하지 못했습니다.'}
  $x=[int](($n[0]+$n[2])/2);$y=[int](($n[1]+$n[3])/2)
  Invoke-AuxAdb @('shell','input','tap',"$x","$y") | Out-Null
  Invoke-AuxAdb @('shell','input','text',$Value) | Out-Null
  $ime=(Invoke-AuxAdb @('shell','dumpsys','input_method')) -join "`n"
  if($ime -match 'mInputShown=true'){Invoke-AuxAdb @('shell','input','keyevent','4') | Out-Null}
  $updated=@(Get-AuxUiNodes | Where-Object {$_.package -eq $script:AuxPackage -and $_.class -eq 'android.widget.EditText'})
  if($updated.Count -ne $ExpectedCount -or [string]$updated[$Index].text -ne $Value){throw '일반 키 입력 반영을 확인하지 못했습니다.'}
}
function Open-AuxMenu {
  $nodes=@(Get-AuxUiNodes)
  $buttons=@($nodes | Where-Object {$_.package -eq $script:AuxPackage -and $_.class -eq 'android.widget.Button' -and [string]::IsNullOrEmpty([string]$_.text) -and [string]::IsNullOrEmpty([string]$_.'content-desc')})
  foreach($button in $buttons){
    $n=@([regex]::Matches($button.bounds,'\d+') | ForEach-Object {[int]$_.Value})
    if($n.Count -eq 4 -and $n[0] -lt 200 -and $n[1] -lt 300){
      $x=[int](($n[0]+$n[2])/2);$y=[int](($n[1]+$n[3])/2)
      Invoke-AuxAdb @('shell','input','tap',"$x","$y") | Out-Null
      return
    }
  }
  throw '현재 화면에서 메뉴 아이콘을 확인하지 못했습니다.'
}
function Scroll-AuxToLabel([string]$Label,[int]$MaxSwipes=8) {
  for($i=0;$i -le $MaxSwipes;$i++){
    $nodes=@(Get-AuxUiNodes)
    $found=@($nodes | Where-Object {([string]$_.text -eq $Label -or [string]$_.'content-desc' -eq $Label) -and $_.bounds -ne '[0,0][0,0]'})
    if($found.Count){return}
    if($i -eq $MaxSwipes){break}
    $scroll=@($nodes | Where-Object {$_.package -eq $script:AuxPackage -and $_.scrollable -eq 'true' -and $_.bounds -ne '[0,0][0,0]'})
    if(!$scroll.Count){throw '현재 앱의 스크롤 영역을 확인하지 못했습니다.'}
    $n=@([regex]::Matches($scroll[0].bounds,'\d+') | ForEach-Object {[int]$_.Value})
    $x=[int](($n[0]+$n[2])/2);$bottom=$n[3]-140;$top=$n[1]+140
    Invoke-AuxAdb @('shell','input','swipe',"$x","$bottom","$x","$top",'400') | Out-Null
  }
  throw '정해진 스크롤 범위에서 UI 항목을 찾지 못했습니다.'
}

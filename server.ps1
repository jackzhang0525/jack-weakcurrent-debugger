param([int]$Port = 8765)
$ErrorActionPreference = 'SilentlyContinue'
$Base = Split-Path -Parent $MyInvocation.MyCommand.Path
function Send-Json($ctx,$obj,[int]$status=200) {
  $json=ConvertTo-Json -InputObject $obj -Depth 10 -Compress
  $bytes=[Text.Encoding]::UTF8.GetBytes($json)
  $ctx.Response.StatusCode=$status; $ctx.Response.ContentType='application/json; charset=utf-8'; $ctx.Response.ContentLength64=$bytes.Length
  $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length); $ctx.Response.Close()
}
function Send-File($ctx,$path,$mime) {
  if(!(Test-Path -LiteralPath $path)){$ctx.Response.StatusCode=404;$ctx.Response.Close();return}
  $bytes=[IO.File]::ReadAllBytes($path);$ctx.Response.ContentType=$mime;$ctx.Response.ContentLength64=$bytes.Length
  $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length);$ctx.Response.Close()
}
function Is-PrivateIPv4([string]$ip) {
  $a=$null;if(![Net.IPAddress]::TryParse($ip,[ref]$a)-or $a.AddressFamily-ne[Net.Sockets.AddressFamily]::InterNetwork){return $false}
  $b=$a.GetAddressBytes()
  return ($b[0]-eq 10)-or($b[0]-eq 127)-or($b[0]-eq 169-and$b[1]-eq 254)-or($b[0]-eq 172-and$b[1]-ge 16-and$b[1]-le 31)-or($b[0]-eq 192-and$b[1]-eq 168)
}
function Resolve-Private([string]$h) {
  $a=$null;if([Net.IPAddress]::TryParse($h,[ref]$a)){if(Is-PrivateIPv4 $h){return $h};return $null}
  try{foreach($x in [Net.Dns]::GetHostAddresses($h)){if($x.AddressFamily-eq'InterNetwork'-and(Is-PrivateIPv4 $x.IPAddressToString)){return $x.IPAddressToString}}}catch{}
  return $null
}
function Get-NetInfo {
  $o=@()
  foreach($c in (Get-CimInstance Win32_NetworkAdapterConfiguration|Where-Object{$_.IPEnabled})){
    $ips=@($c.IPAddress|Where-Object{$_-match '^\d+\.\d+\.\d+\.\d+$'});$ms=@($c.IPSubnet|Where-Object{$_-match '^\d+\.\d+\.\d+\.\d+$'})
    if($ips.Count){$o += [pscustomobject]@{description=$c.Description;ip=$ips[0];mask=$(if($ms.Count){$ms[0]}else{''});gateway=$(if($c.DefaultIPGateway){$c.DefaultIPGateway[0]}else{''});dns=@($c.DNSServerSearchOrder);mac=$c.MACAddress}}
  };return ,$o
}
function Ping-One([string]$h) {
  $ip=Resolve-Private $h;if(!$ip){return @{ok=$false;error='仅允许调试本机/内网地址'}}
  $p=New-Object Net.NetworkInformation.Ping;$t=@()
  1..4|ForEach-Object{try{$r=$p.Send($ip,900);if($r.Status-eq'Success'){$t+= [int]$r.RoundtripTime}}catch{}}
  return @{ok=($t.Count-gt 0);host=$h;ip=$ip;replies=$t.Count;times=$t;avg=$(if($t.Count){[math]::Round(($t|Measure-Object -Average).Average,1)}else{$null})}
}
function Test-Port([string]$ip,[int]$port,[int]$timeout=220) {
  $c=$null;try{$c=New-Object Net.Sockets.TcpClient;$ar=$c.BeginConnect($ip,$port,$null,$null);$ok=$ar.AsyncWaitHandle.WaitOne($timeout,$false);if($ok){$c.EndConnect($ar);return $true}}catch{}finally{if($c){$c.Close()}};return $false
}
function Get-ArpMac([string]$ip) {
  try{foreach($l in (arp -a $ip 2>$null)){if($l -match ([regex]::Escape($ip)+'\s+([0-9A-Fa-f-]{17})')){return $matches[1].ToUpper()}}}catch{};return ''
}
function Get-Fingerprint([string]$ip,[int[]]$ports) {
  foreach($p in $ports){if($p-notin @(80,81,443,8000,8080,8081,8443,8899)){continue};$scheme=if($p-in @(443,8443)){'https'}else{'http'}
    try{[Net.ServicePointManager]::ServerCertificateValidationCallback={$true};$req=[Net.HttpWebRequest]::Create("$($scheme)://$($ip):$($p)/");$req.Timeout=750;$req.ReadWriteTimeout=750;$req.UserAgent='JACK-WeakCurrent-Debugger'
      $resp=$req.GetResponse();$server=$resp.Headers['Server'];$sr=New-Object IO.StreamReader($resp.GetResponseStream());$html=$sr.ReadToEnd();$sr.Close();$resp.Close()
      $title='';if($html -match '(?is)<title[^>]*>(.*?)</title>'){$title=($matches[1]-replace '\s+',' ').Trim()};$sample=($html-replace '<[^>]+>',' '-replace '\s+',' ').Trim();if($sample.Length-gt 220){$sample=$sample.Substring(0,220)}
      return @{scheme=$scheme;port=$p;server=$server;title=$title;sample=$sample}
    }catch{}
  };return $null
}
function Guess-Brand($fp,[int[]]$ports) {
  $s='';if($fp){$s=(($fp.title+' '+$fp.server+' '+$fp.sample).ToLower())}
  $rules=@(@('Hikvision / 海康威视','hikvision|海康'),@('Dahua / 大华','dahua|大华'),@('Uniview / 宇视','uniview|宇视'),@('Tiandy / 天地伟业','tiandy|天地伟业'),@('Huawei / 华为','huawei|华为'),@('H3C / 新华三','h3c|新华三'),@('Ruijie / 锐捷','ruijie|锐捷'),@('TP-Link','tp-link|tplink'),@('Ubiquiti','ubiquiti|unifi'),@('MikroTik','mikrotik|routeros'),@('Tenda / 腾达','tenda|腾达'),@('ZTE / 中兴','zte|中兴'),@('Synology / 群晖','synology|diskstation|群晖'),@('QNAP','qnap'))
  foreach($r in $rules){if($s-match $r[1]){return $r[0]}}
  if($ports-contains 37777){return '大华系 / OEM（特征推测）'};if($ports-contains 34567){return '雄迈/XMEye 系 / OEM（特征推测）'}
  if(($ports-contains 8000)-and($ports-contains 554)){return '监控设备 / 海康系或OEM（特征推测）'};if($ports-contains 554){return '摄像机/NVR/流媒体设备（RTSP）'}
  if(($ports-contains 22)-and($ports-contains 80)){return '网络设备 / Linux类管理界面（待确认）'};return '通用 / 未识别'
}
function Scan-Host([string]$ip) {
  if(!(Is-PrivateIPv4 $ip)){return @{error='仅允许扫描内网地址'}}
  try{$p=New-Object Net.NetworkInformation.Ping;[void]$p.Send($ip,150)}catch{}
  $portsToCheck=@(21,22,23,53,80,81,443,554,8000,8001,8080,8081,8443,8899,9000,34567,37777);$open=@()
  foreach($p in $portsToCheck){if(Test-Port $ip $p 160){$open += $p}}
  $fp=Get-Fingerprint $ip $open;$hn='';try{$hn=[Net.Dns]::GetHostEntry($ip).HostName}catch{}
  return @{ip=$ip;hostname=$hn;mac=(Get-ArpMac $ip);ports=$open;brand=(Guess-Brand $fp $open);http=$fp}
}
function Scan-Subnet([string]$v) {
  if($v-notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:\.\d{1,3})?(?:/24)?$'){return @{error='请输入内网 /24 网段，例如 192.168.1.0/24'}}
  $prefix="$($matches[1]).$($matches[2]).$($matches[3])";if(!(Is-PrivateIPv4 "$prefix.1")){return @{error='仅允许扫描内网网段'}}
  $online=@()
  foreach($i in 1..254){$ip="$prefix.$i";try{$p=New-Object Net.NetworkInformation.Ping;$r=$p.Send($ip,100);if($r.Status-eq'Success'){$online += $ip}}catch{}}
  try{foreach($l in (arp -a 2>$null)){if($l-match "($([regex]::Escape($prefix))\.\d{1,3})\s+[0-9A-Fa-f-]{17}"){if($online-notcontains $matches[1]){$online += $matches[1]}}}}catch{}
  $dev=@();foreach($ip in ($online|Sort-Object {[version]$_})){$dev += (Scan-Host $ip)}
  return @{subnet="$prefix.0/24";count=$dev.Count;devices=$dev}
}
function Onvif-Discover {
  $udp=$null
  try{
    $uuid=[guid]::NewGuid().ToString()
    $soap='<?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:'+ $uuid +'</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>'
    $udp=New-Object Net.Sockets.UdpClient;$udp.Client.ReceiveTimeout=300;$b=[Text.Encoding]::UTF8.GetBytes($soap);$ep=New-Object Net.IPEndPoint([Net.IPAddress]::Parse('239.255.255.250'),3702);[void]$udp.Send($b,$b.Length,$ep)
    $found=@();$until=(Get-Date).AddMilliseconds(1400)
    while((Get-Date)-lt $until){try{$remote=New-Object Net.IPEndPoint([Net.IPAddress]::Any,0);$data=$udp.Receive([ref]$remote);$txt=[Text.Encoding]::UTF8.GetString($data);$x='';if($txt-match '(?is)<[^>]*XAddrs[^>]*>(.*?)</[^>]*XAddrs>'){$x=$matches[1]};$sc='';if($txt-match '(?is)<[^>]*Scopes[^>]*>(.*?)</[^>]*Scopes>'){$sc=$matches[1]};$found += @{ip=$remote.Address.IPAddressToString;xaddrs=$x;scopes=$sc}}catch{}}
    return ,@($found|Group-Object ip|ForEach-Object{$_.Group[0]})
  }catch{return ,@()}finally{if($udp){$udp.Close()}}
}
$listener=New-Object Net.HttpListener;$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try{$listener.Start()}catch{Write-Host "无法启动本地端口 $Port，请关闭已运行的实例后重试。" -ForegroundColor Red;Read-Host '按回车退出';exit 1}
Start-Process "http://127.0.0.1:$Port/";Write-Host "JACK 弱电调试宝已启动：http://127.0.0.1:$Port/" -ForegroundColor Green;Write-Host '关闭此窗口即可停止服务。'
while($listener.IsListening){try{$ctx=$listener.GetContext();$path=$ctx.Request.Url.AbsolutePath;$q=$ctx.Request.QueryString
  switch -Regex ($path){
    '^/$'{Send-File $ctx (Join-Path $Base 'web\index.html') 'text/html; charset=utf-8'}
    '^/app.js$'{Send-File $ctx (Join-Path $Base 'web\app.js') 'application/javascript; charset=utf-8'}
    '^/style.css$'{Send-File $ctx (Join-Path $Base 'web\style.css') 'text/css; charset=utf-8'}
    '^/api/network$'{Send-Json $ctx (Get-NetInfo)}
    '^/api/ping$'{Send-Json $ctx (Ping-One $q['host'])}
    '^/api/host$'{Send-Json $ctx (Scan-Host $q['ip'])}
    '^/api/scan$'{Send-Json $ctx (Scan-Subnet $q['subnet'])}
    '^/api/onvif$'{Send-Json $ctx (Onvif-Discover)}
    default{$ctx.Response.StatusCode=404;$ctx.Response.Close()}
  }
}catch{}}

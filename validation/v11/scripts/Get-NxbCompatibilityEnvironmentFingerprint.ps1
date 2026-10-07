[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ObservationJsonPath,
    [Parameter(Mandatory=$true)][string]$PythonExecutablePath,
    [Parameter(Mandatory=$true)][string]$ValidatorPackageRoot,
    [string]$CompareObservationJsonPath,
    [string]$OutputCanonicalJsonPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 required'}
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$Schema=Join-Path $Root 'schemas\nxb-v11-environment-fingerprint.schema.json'
$Module=Join-Path $Root 'scripts\Nxb.EvidenceStore.psm1'
function Assert-File([string]$Path,[string]$Label){
 if(-not[IO.Path]::IsPathFullyQualified($Path)){throw "$Label must be absolute"}
 $full=[IO.Path]::GetFullPath($Path)
 if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw "$Label does not exist"}
 $item=Get-Item -LiteralPath $full -Force
 if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "$Label is reparse-backed"}
 return $full
}
function Hash-Bytes([byte[]]$Bytes){
 $h=[Security.Cryptography.SHA256]::Create()
 try{[BitConverter]::ToString($h.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}
 finally{$h.Dispose()}
}
function Read-Document([string]$Path){
 $bytes=[IO.File]::ReadAllBytes($Path)
 if($bytes.Length -lt 2){throw 'Invalid empty observation'}
 if($bytes.Length-ge3-and$bytes[0]-eq239-and$bytes[1]-eq187-and$bytes[2]-eq191){throw 'BOM forbidden'}
 $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
 $doc=$text|ConvertFrom-Json -Depth 100 -DateKind String
 if($doc-isnot[pscustomobject]){throw 'Observation root must be object'}
 return $doc
}
$PythonExecutablePath=Assert-File $PythonExecutablePath 'Python'
$ObservationJsonPath=Assert-File $ObservationJsonPath 'Observation'
if(-not[IO.Path]::IsPathFullyQualified($ValidatorPackageRoot)){throw 'Validator package root must be absolute'}
$ValidatorPackageRoot=[IO.Path]::GetFullPath($ValidatorPackageRoot)
if(-not(Test-Path -LiteralPath $ValidatorPackageRoot -PathType Container)){throw 'Validator package root missing'}
$vRoot=Get-Item -LiteralPath $ValidatorPackageRoot -Force
if(($vRoot.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Validator package root is reparse-backed'}
$Schema=Assert-File $Schema 'Schema'
$Module=Assert-File $Module 'Frozen canonical module'
if((Get-FileHash -LiteralPath $Schema -Algorithm SHA256).Hash.ToLowerInvariant()-cne'04698ce35e2765e042f64582a11de77b3f60bded5a0f176857e84df1f51c9144'){throw 'Schema drift'}
$ModuleSha256=(Get-FileHash -LiteralPath $Module -Algorithm SHA256).Hash.ToLowerInvariant()
$AcceptedModuleSha256=@(
 '207a3e379e411fa6761f21cf01810135572d87033779ec8f791fa0befcd17cd7',
 'baa711b12592dff95d1155953f183454f44af31e72f61b05d6388add9555d4f3'
)
if($AcceptedModuleSha256-cnotcontains$ModuleSha256){throw 'Canonical module drift'}
$pythonVerifier=@"
import hashlib,json,pathlib,sys,unicodedata
root=pathlib.Path(sys.argv[1]).resolve(strict=True)
if not root.is_dir():raise ValueError("validator package root is not a directory")
sys.path.insert(0,str(root))
from jsonschema import Draft202012Validator,FormatChecker
def reject_float(x):raise ValueError("float forbidden")
def parse_int(x):
 n=int(x)
 if not -(2**63)<=n<2**63:raise ValueError("integer overflow")
 return n
def pairs(items):
 o={}
 for k,v in items:
  if k in o:raise ValueError("duplicate JSON key: "+k)
  o[k]=v
 return o
def walk(v):
 if isinstance(v,str):
  if unicodedata.normalize("NFC",v)!=v:raise ValueError("non-NFC string")
  if any(0xD800<=ord(c)<=0xDFFF for c in v):raise ValueError("surrogate")
 elif isinstance(v,dict):
  for k,x in v.items():walk(k);walk(x)
 elif isinstance(v,list):
  for x in v:walk(x)
def load(p):
 raw=pathlib.Path(p).read_bytes()
 if raw.startswith(b"\xef\xbb\xbf"):raise ValueError("BOM forbidden")
 o=json.loads(raw.decode("utf-8","strict"),object_pairs_hook=pairs,parse_float=reject_float,parse_int=parse_int,parse_constant=lambda _:reject_float("nonfinite"))
 walk(o);return o
schema=load(sys.argv[2])
Draft202012Validator.check_schema(schema)
validator=Draft202012Validator(schema,format_checker=FormatChecker())
def verify(path):
 o=load(path)
 validator.validate(o)
 labels=o["runner"]["labels"]
 if labels!=sorted(set(labels)):raise ValueError("runner labels not sorted/unique")
 c={k:v for k,v in o.items() if k not in ("captured_utc","fingerprint_sha256")}
 payload=json.dumps(c,ensure_ascii=False,sort_keys=True,separators=(",",":"),allow_nan=False).encode("utf-8")
 digest=hashlib.sha256(payload).hexdigest()
 if digest!=o["fingerprint_sha256"]:raise ValueError("fingerprint SHA mismatch")
 return digest
first=verify(sys.argv[3])
if len(sys.argv)>4 and first!=verify(sys.argv[4]):raise ValueError("pre/post drift")
print(first)
"@
$arguments=@('-I','-c',$pythonVerifier,$ValidatorPackageRoot,$Schema,$ObservationJsonPath)
if(-not[string]::IsNullOrWhiteSpace($CompareObservationJsonPath)){
 $CompareObservationJsonPath=Assert-File $CompareObservationJsonPath 'Post-observation'
 $arguments+=$CompareObservationJsonPath
}
$previous=$ErrorActionPreference
try{
 $ErrorActionPreference='Continue'
 $lines=@(& $PythonExecutablePath @arguments 2>&1|ForEach-Object{[string]$_})
 $code=$LASTEXITCODE
}finally{$ErrorActionPreference=$previous}
if($code-ne0-or$lines.Count-ne1-or$lines[0]-cnotmatch'^[0-9a-f]{64}$'){
 throw "Python validation failed: $($lines-join' ')"
}
$pythonHash=$lines[0]
Import-Module -Name $Module -Force -ErrorAction Stop
$doc=Read-Document $ObservationJsonPath
if([string]$doc.fingerprint_sha256-cne$pythonHash){throw 'Stored digest drift'}
[void]$doc.PSObject.Properties.Remove('captured_utc')
[void]$doc.PSObject.Properties.Remove('fingerprint_sha256')
$canon=ConvertTo-NxbCanonicalJson -InputObject $doc
$pwshHash=Hash-Bytes ([Text.UTF8Encoding]::new($false).GetBytes($canon))
if($pwshHash-cne$pythonHash){throw 'Cross-runtime canonical hash drift'}
if(-not[string]::IsNullOrWhiteSpace($OutputCanonicalJsonPath)){
 if(-not[IO.Path]::IsPathFullyQualified($OutputCanonicalJsonPath)){throw 'Output must be absolute'}
 $output=[IO.Path]::GetFullPath($OutputCanonicalJsonPath)
 if(Test-Path -LiteralPath $output){throw 'Output already exists'}
 $parent=Split-Path -Parent $output
 if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw 'Output parent missing'}
 $parentInfo=Get-Item -LiteralPath $parent -Force
 if(($parentInfo.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Output parent reparse'}
 $full=Read-Document $ObservationJsonPath
 $fullJson=ConvertTo-NxbCanonicalJson -InputObject $full
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes($fullJson)
 $stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}
 finally{$stream.Dispose()}
}
[pscustomobject]@{
 authority='nxb-v11-fingerprint-reconciliation-v1'
 status='RECONCILED_CLAIM_FREE'
 fingerprint_sha256=$pythonHash
 cross_runtime_hash_match=$true
 post_observation_compared=(-not[string]::IsNullOrWhiteSpace($CompareObservationJsonPath))
 physical_compatibility_claimed=$false
}|ConvertTo-Json -Compress
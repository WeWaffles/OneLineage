# gen_stubs.ps1 — generate compile-only Java stubs + catch-all callback classes from AOSP radio AIDL.
#   gen_stubs.ps1 -Aidl <dir with android/hardware/radio/...> -Package network -Iface IRadioNetwork
# Writes stubs/android/hardware/radio/<pkg>/*.java (parcelables/unions as empty classes, the three
# interfaces with their methods) and src/gen/<Iface>Callbacks.java: Response/Indication classes that
# implement every method and forward to S26Ril.onResponse(iface, name, info, args) /
# S26Ril.onIndication(iface, name, type, args).
# Enums map to their backing primitive (AIDL Java enums are plain int/byte constants).
param([string]$Aidl, [string]$Package, [string]$Iface)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$pkgDir = Join-Path $Aidl $Package
$commonDir = $Aidl
$fq = "android.hardware.radio.$Package"

function Read-Kind([string]$fqcn) {
    # -> 'int'/'byte'/'long' for enums, 'class' for parcelables/unions/interfaces
    $parts = $fqcn.Split('.')
    $name = $parts[-1]
    $sub = $parts[3..($parts.Length - 2)] -join '\'
    $file = Join-Path (Join-Path $Aidl '..\..\..') ("android\hardware\radio\" + ($(if ($parts.Length -gt 5) { $parts[4] + '\' } else { '' })) + "$name.aidl")
    $cand = @((Join-Path $pkgDir "$name.aidl"), (Join-Path $commonDir "$name.aidl"))
    foreach ($c in $cand) {
        if (Test-Path $c) {
            $t = Get-Content -Raw $c
            if ($t -match "enum\s+$name\b") {
                if ($t -match '@Backing\(type="(\w+)"\)') { return $Matches[1] }
                return 'byte'
            }
            return 'class'
        }
    }
    return 'class'
}

$kinds = @{}
function Map-Type([string]$t) {
    $t = ($t -replace '@nullable\s*', '').Trim()
    $arr = ''
    while ($t.EndsWith('[]')) { $arr += '[]'; $t = $t.Substring(0, $t.Length - 2) }
    if ($t -in 'int', 'long', 'boolean', 'byte', 'char', 'float', 'double', 'String', 'void') { return "$t$arr" }
    if (-not $kinds.ContainsKey($t)) { $kinds[$t] = Read-Kind $t }
    $k = $kinds[$t]
    if ($k -eq 'class') { return "$t$arr" }
    return "$k$arr"
}

function Parse-Methods([string]$file) {
    $methods = @()
    foreach ($line in Get-Content $file) {
        if ($line -match '^\s*(?:oneway\s+)?(\S+)\s+(\w+)\((.*)\);') {
            $ret = Map-Type $Matches[1]; $name = $Matches[2]; $argStr = $Matches[3].Trim()
            $args = @()
            if ($argStr) {
                foreach ($a in ($argStr -split ',\s*(?=in\s|out\s|inout\s)')) {
                    $a = ($a -replace '^\s*(in|out|inout)\s+', '').Trim()
                    $i = $a.LastIndexOf(' ')
                    $args += , @((Map-Type $a.Substring(0, $i)), $a.Substring($i + 1))
                }
            }
            $methods += , @($ret, $name, $args)
        }
    }
    return $methods
}

function Rest-Names($m) { $a = @($m[2]); $r = @(); for ($i = 1; $i -lt $a.Count; $i++) { $r += $a[$i][1] }; $r -join ', ' }
function Sig($m) { ($m[2] | ForEach-Object { "$($_[0]) $($_[1])" }) -join ', ' }

$stubDir = Join-Path $here "stubs\android\hardware\radio\$Package"
New-Item -ItemType Directory -Force $stubDir | Out-Null
$req = Parse-Methods (Join-Path $pkgDir "$Iface.aidl")
$resp = Parse-Methods (Join-Path $pkgDir "${Iface}Response.aidl")
$ind = Parse-Methods (Join-Path $pkgDir "${Iface}Indication.aidl")

# request interface
$b = "package $fq;`n// generated compile-only stub (gen_stubs.ps1)`npublic interface $Iface extends android.os.IInterface {`n"
$b += "    abstract class Stub extends android.os.Binder implements $Iface {`n        public static $Iface asInterface(android.os.IBinder b) { return null; }`n    }`n"
foreach ($m in $req) { $b += "    $($m[0]) $($m[1])($(Sig $m)) throws android.os.RemoteException;`n" }
[IO.File]::WriteAllText((Join-Path $stubDir "$Iface.java"), "$b}`n")

# callback interfaces
foreach ($kind in 'Response', 'Indication') {
    $ms = if ($kind -eq 'Response') { $resp } else { $ind }
    $n = "$Iface$kind"
    $b = "package $fq;`n// generated compile-only stub (gen_stubs.ps1)`npublic interface $n extends android.os.IInterface {`n"
    $b += "    abstract class Stub extends android.os.Binder implements $n {`n        public android.os.IBinder asBinder() { return this; }`n    }`n"
    foreach ($m in $ms) { $b += "    $($m[0]) $($m[1])($(Sig $m)) throws android.os.RemoteException;`n" }
    $b += "    int getInterfaceVersion() throws android.os.RemoteException;`n    String getInterfaceHash() throws android.os.RemoteException;`n"
    [IO.File]::WriteAllText((Join-Path $stubDir "$n.java"), "$b}`n")
}

# empty classes for every referenced parcelable/union of this package (common ones exist already)
foreach ($t in $kinds.Keys) {
    if ($kinds[$t] -ne 'class' -or -not $t.StartsWith("$fq.")) { continue }
    $name = $t.Split('.')[-1]
    if ($name -like 'IRadio*') { continue }
    $f = Join-Path $stubDir "$name.java"
    if (-not (Test-Path $f)) { [IO.File]::WriteAllText($f, "package $fq;`n// generated compile-only stub`npublic class $name {}`n") }
}

# catch-all callbacks
$genDir = Join-Path $here 'src\gen'
New-Item -ItemType Directory -Force $genDir | Out-Null
$c = "// generated by gen_stubs.ps1 from AOSP $fq AIDL: every callback forwards to S26Ril`n"
$c += "import $fq.*;`n`nclass ${Iface}Callbacks {`n"
foreach ($kind in 'Response', 'Indication') {
    $ms = if ($kind -eq 'Response') { $resp } else { $ind }
    $c += "    static class $kind extends $Iface$kind.Stub {`n"
    foreach ($m in $ms) {
        $first = if ($m[2].Count -gt 0) { $m[2][0][1] } else { $null }
        $call = if ($kind -eq 'Response') {
            if ($first -eq 'info') { "S26Ril.onResponse(`"$Iface`", `"$($m[1])`", info, new Object[]{ $(Rest-Names $m) });" }
            else { "S26Ril.onAck(`"$Iface`", `"$($m[1])`");" }
        } else {
            # first arg is the RadioIndicationType, whatever the AIDL calls it (usually "type")
            "S26Ril.onIndication(`"$Iface`", `"$($m[1])`", $first, new Object[]{ $(Rest-Names $m) });"
        }
        $c += "        public $($m[0]) $($m[1])($(Sig $m)) { $call }`n"
    }
    $c += "        public int getInterfaceVersion() { return S26Ril.field($Iface$kind.class, `"VERSION`", 1); }`n"
    $c += "        public String getInterfaceHash() { return S26Ril.hash($Iface$kind.class); }`n    }`n"
}
[IO.File]::WriteAllText((Join-Path $genDir "${Iface}Callbacks.java"), "$c}`n")
"generated: $($req.Count) requests, $($resp.Count) responses, $($ind.Count) indications; types: $($kinds.Count)"

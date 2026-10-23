# build.ps1 — compile S26RilData against the compile-only stubs and dex it (stubs are not packaged:
# the device's boot classpath provides the real android.os / android.hardware.radio classes).
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$out = Join-Path $here 'build'
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$out\stubs", "$out\classes" | Out-Null

$stubs = Get-ChildItem "$here\stubs" -Recurse -Filter *.java | ForEach-Object FullName
javac --release 11 -nowarn -d "$out\stubs" $stubs
if ($LASTEXITCODE) { throw 'stub compile failed' }
$src = Get-ChildItem "$here\src" -Recurse -Filter *.java | ForEach-Object FullName
javac --release 11 -cp "$out\stubs" -d "$out\classes" $src
if ($LASTEXITCODE) { throw 'compile failed' }

$classes = Get-ChildItem "$out\classes" -Recurse -Filter *.class | ForEach-Object FullName
java -cp "$here\..\tools\r8.jar" com.android.tools.r8.D8 --min-api 34 --output $out $classes
if ($LASTEXITCODE) { throw 'd8 failed' }
Move-Item -Force "$out\classes.dex" "$out\s26_rildata.dex"
Get-Item "$out\s26_rildata.dex"

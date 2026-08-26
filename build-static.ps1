$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourceDir = Join-Path $PSScriptRoot 'cpython'
$distDir = Join-Path $PSScriptRoot 'python-3.8.20-static-win64'

function Replace-Required {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Old,
        [Parameter(Mandatory)] [string] $New
    )

    $content = [System.IO.File]::ReadAllText($Path)
    if (-not $content.Contains($Old)) {
        throw "Required text was not found in $Path`: $Old"
    }
    $content = $content.Replace($Old, $New)
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($true))
}

git clone --depth 1 --branch v3.8.20 https://github.com/python/cpython.git $sourceDir
if ($LASTEXITCODE -ne 0) { throw 'Failed to clone CPython v3.8.20.' }

$pythonCoreProject = Join-Path $sourceDir 'PCbuild\pythoncore.vcxproj'
$pythonProject = Join-Path $sourceDir 'PCbuild\python.vcxproj'

Replace-Required $pythonCoreProject `
    '<ConfigurationType>DynamicLibrary</ConfigurationType>' `
    '<ConfigurationType>StaticLibrary</ConfigurationType>'

Replace-Required $pythonCoreProject `
    '_USRDLL;Py_BUILD_CORE;Py_BUILD_CORE_BUILTIN;Py_ENABLE_SHARED;' `
    '_LIB;Py_BUILD_CORE;Py_BUILD_CORE_BUILTIN;Py_NO_ENABLE_SHARED;'

Replace-Required $pythonCoreProject `
    "    <ClCompile>`r`n      <AdditionalOptions>" `
    "    <ClCompile>`r`n      <RuntimeLibrary>MultiThreaded</RuntimeLibrary>`r`n      <AdditionalOptions>"

Replace-Required $pythonProject `
    '<PreprocessorDefinitions>Py_BUILD_CORE;_CONSOLE;%(PreprocessorDefinitions)</PreprocessorDefinitions>' `
    '<PreprocessorDefinitions>Py_BUILD_CORE;Py_NO_ENABLE_SHARED;_CONSOLE;%(PreprocessorDefinitions)</PreprocessorDefinitions>'

Replace-Required $pythonProject `
    "    <ClCompile>`r`n      <PreprocessorDefinitions>" `
    "    <ClCompile>`r`n      <RuntimeLibrary>MultiThreaded</RuntimeLibrary>`r`n      <PreprocessorDefinitions>"

Replace-Required $pythonProject `
    '      <StackReserveSize>2000000</StackReserveSize>' `
    "      <StackReserveSize>2000000</StackReserveSize>`r`n      <AdditionalDependencies>version.lib;shlwapi.lib;ws2_32.lib;%(AdditionalDependencies)</AdditionalDependencies>"

Push-Location $sourceDir
try {
    & cmd.exe /d /c 'PCbuild\get_externals.bat'
    if ($LASTEXITCODE -ne 0) { throw 'get_externals.bat failed.' }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' |
        Select-Object -First 1
    if (-not $msbuild) { throw 'MSBuild.exe was not found.' }

    & $msbuild 'PCbuild\python.vcxproj' `
        '/m' `
        '/t:Rebuild' `
        '/p:Configuration=Release' `
        '/p:Platform=x64' `
        '/p:PlatformToolset=v142' `
        '/p:IncludeExternals=true' `
        '/p:SupportSigning=false' `
        '/verbosity:minimal'
    if ($LASTEXITCODE -ne 0) { throw 'MSBuild failed.' }
}
finally {
    Pop-Location
}

$outputDir = Join-Path $sourceDir 'PCbuild\amd64'
$pythonExe = Join-Path $outputDir 'python.exe'
$pythonLib = Join-Path $outputDir 'python38.lib'

if (-not (Test-Path $pythonExe)) { throw 'python.exe was not produced.' }
if (-not (Test-Path $pythonLib)) { throw 'python38.lib was not produced.' }
if (Test-Path (Join-Path $outputDir 'python38.dll')) { throw 'Unexpected python38.dll was produced.' }

$dumpbin = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' |
    Select-Object -First 1
if (-not $dumpbin) { throw 'dumpbin.exe was not found.' }

$dependencies = (& $dumpbin /nologo /dependents $pythonExe | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'dumpbin dependency inspection failed.' }
if ($dependencies -match '(?i)python38\.dll') {
    throw 'python.exe still depends on python38.dll.'
}

$libraryMembers = (& $dumpbin /nologo /linkermember:2 $pythonLib | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'dumpbin static-library inspection failed.' }
if ($libraryMembers -notmatch 'Py_Initialize') {
    throw 'python38.lib does not contain the expected CPython symbols.'
}

New-Item -ItemType Directory -Force $distDir | Out-Null
New-Item -ItemType Directory -Force (Join-Path $distDir 'libs') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $distDir 'include') | Out-Null

Copy-Item $pythonExe $distDir
Copy-Item $pythonLib (Join-Path $distDir 'libs')
Copy-Item (Join-Path $sourceDir 'Include\*') (Join-Path $distDir 'include') -Recurse
Copy-Item (Join-Path $sourceDir 'PC\pyconfig.h') (Join-Path $distDir 'include')
Copy-Item (Join-Path $sourceDir 'Lib') $distDir -Recurse
Remove-Item (Join-Path $distDir 'Lib\test') -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $sourceDir 'LICENSE') (Join-Path $distDir 'LICENSE.txt')

$versionOutput = (& (Join-Path $distDir 'python.exe') -E -c 'import sys, json, zlib; print(sys.version); print(json.__name__); print(zlib.ZLIB_VERSION)' | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Packaged python.exe smoke test failed.' }

$commit = (git -C $sourceDir rev-parse HEAD).Trim()
$buildInfo = @"
Python version: 3.8.20
Architecture: x64
Configuration: Release
Compiler toolset: MSVC v142
Python core linkage: static
C runtime linkage: static (/MT)
CPython commit: $commit

python.exe dependencies reported by dumpbin:
$dependencies

Smoke test output:
$versionOutput
"@
[System.IO.File]::WriteAllText(
    (Join-Path $distDir 'BUILD-INFO.txt'),
    $buildInfo,
    [System.Text.UTF8Encoding]::new($false)
)

$unexpectedDynamicFiles = Get-ChildItem $distDir -Recurse -File |
    Where-Object { $_.Extension -in '.dll', '.pyd' }
if ($unexpectedDynamicFiles) {
    throw "Unexpected dynamic files in package: $($unexpectedDynamicFiles.FullName -join ', ')"
}

$archive = Join-Path $PSScriptRoot 'python-3.8.20-static-win64.zip'
Compress-Archive -Path $distDir -DestinationPath $archive -CompressionLevel Optimal -Force
Get-FileHash $archive -Algorithm SHA256 | Format-List


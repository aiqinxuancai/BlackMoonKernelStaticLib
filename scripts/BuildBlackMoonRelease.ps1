<#
Build the release layout consumed by e-packager.

The legacy BlackMoon sources are CP936 and target the x86 ABI.  The x86
archive is built by the legacy project.  The x64 archive is produced by the
source adapter and is combined with the explicitly supplied modern core
archive, which provides the ABI-compatible fallback implementation.
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = '',
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [string]$ModernCoreRoot = '',
    [string]$MetadataRoot = '',
    [string]$X86MetadataFne = '',
    [string]$X64MetadataFne = '',
    [string]$X64PrimaryLibrary = '',
    [string]$X64FallbackLibrary = '',
    [string]$X64AdapterManifest = '',
    [string]$MsBuildPath = '',
    [string]$PlatformToolset = '',
    [string]$Version = '',
    [switch]$LegacyOnly,
    [switch]$SkipModernBuild,
    [switch]$SkipX64Adapter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
} catch {
    # Windows PowerShell already exposes the system code pages.
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repositoryRoot 'artifacts\release'
}
$OutputRoot = (Resolve-Path (New-Item -ItemType Directory -Path $OutputRoot -Force)).Path
if ([String]::Equals($OutputRoot.TrimEnd('\'), $repositoryRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputRoot 不能指向源码仓库根目录，请使用 artifacts/release 等独立目录。'
}

function Resolve-FilePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description 不存在: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Test-PrereleaseVersion {
    param([Parameter(Mandatory = $true)][string]$Tag)

    # SemVer uses a hyphen before a prerelease identifier.  A few existing
    # repositories omit that separator (for example v1.0.0beta1), so keep the
    # well-known labels usable without making a stable version containing
    # unrelated text look like a preview.
    $withoutBuildMetadata = ($Tag -split '\+', 2)[0]
    return [bool](
        ($withoutBuildMetadata -match '(?i)-[0-9A-Za-z.-]+$') -or
        ($withoutBuildMetadata -match '(?i)(?:alpha|beta|preview|pre|rc|dev)[0-9A-Za-z.-]*$')
    )
}

function Find-VsWhere {
    $candidates = @(
        'C:\Program Files\Microsoft Visual Studio\Installer\vswhere.exe',
        'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command vswhere.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    return ''
}

function Find-VsInstall {
    param([string]$KnownMsBuild)
    if (-not [string]::IsNullOrWhiteSpace($KnownMsBuild)) {
        $current = (Resolve-Path -LiteralPath $KnownMsBuild).Path
        for ($index = 0; $index -lt 6; ++$index) {
            $current = Split-Path -Parent $current
            if (Test-Path -LiteralPath (Join-Path $current 'VC\Tools\MSVC') -PathType Container) {
                return $current
            }
        }
    }
    $vswhere = Find-VsWhere
    if (-not [string]::IsNullOrWhiteSpace($vswhere)) {
        $install = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null |
            ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($install.Count -eq 1 -and (Test-Path -LiteralPath $install[0] -PathType Container)) {
            return (Resolve-Path -LiteralPath $install[0]).Path
        }
    }
    return ''
}

function Resolve-MsBuild {
    param([string]$RequestedPath)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return Resolve-FilePath $RequestedPath 'MSBuild'
    }
    $command = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $command.Source).Path
    }
    $vswhere = Find-VsWhere
    if (-not [string]::IsNullOrWhiteSpace($vswhere)) {
        $install = @(& $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath 2>$null |
            ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -First 1)
        if ($install.Count -eq 1) {
            $candidate = Join-Path $install[0] 'MSBuild\Current\Bin\MSBuild.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path $candidate).Path }
        }
    }
    throw '未找到 MSBuild，请安装 Visual Studio C++ 工具或传入 -MsBuildPath。'
}

function Resolve-Toolset {
    param(
        [string]$RequestedToolset,
        [string]$VsInstall
    )
    if (-not [string]::IsNullOrWhiteSpace($RequestedToolset)) { return $RequestedToolset }
    if (-not [string]::IsNullOrWhiteSpace($VsInstall)) {
        $vcRoot = Join-Path $VsInstall 'VC\Tools\MSVC'
        $toolDirectory = Get-ChildItem -LiteralPath $vcRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($null -ne $toolDirectory) {
            $match = [regex]::Match($toolDirectory.Name, '^14\.(\d+)')
            if ($match.Success) {
                $minor = [int]$match.Groups[1].Value
                if ($minor -ge 50) { return 'v145' }
                if ($minor -ge 30) { return 'v143' }
                if ($minor -ge 20) { return 'v142' }
                if ($minor -ge 10) { return 'v141' }
            }
        }
    }
    return 'v143'
}

function Resolve-VcCompiler {
    param(
        [Parameter(Mandatory = $true)][string]$VsInstall,
        [Parameter(Mandatory = $true)][ValidateSet('x86', 'x64')][string]$Architecture
    )
    $vcRoot = Join-Path $VsInstall 'VC\Tools\MSVC'
    $toolDirectory = Get-ChildItem -LiteralPath $vcRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $toolDirectory) { throw "未找到 MSVC 工具集: $vcRoot" }
    $target = if ($Architecture -eq 'x64') { 'x64' } else { 'x86' }
    $candidate = Join-Path $toolDirectory.FullName "bin\Hostx64\$target\cl.exe"
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $candidate = Join-Path $toolDirectory.FullName "bin\Hostx86\$target\cl.exe"
    }
    return Resolve-FilePath $candidate "$Architecture cl.exe"
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [string]$WorkingDirectory = $repositoryRoot
    )
    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath $WorkingDirectory
        $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        Set-Location -LiteralPath $previousLocation
    }
    $logDirectory = Split-Path -Parent $LogPath
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    [IO.File]::WriteAllLines($LogPath, $output, [Text.UTF8Encoding]::new($true))
    if ($exitCode -ne 0) {
        throw "命令执行失败 (exit=$exitCode): $FilePath`n$($output -join "`n")"
    }
    return $output
}

function Find-FirstFile {
    param([string[]]$Candidates)
    foreach ($candidate in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return ''
}

function Build-MsBuildProject {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][ValidateSet('Win32', 'x64')][string]$Platform,
        [Parameter(Mandatory = $true)][string]$OutDirectory,
        [Parameter(Mandatory = $true)][string]$IntermediateDirectory,
        [Parameter(Mandatory = $true)][string]$Name
    )
    New-Item -ItemType Directory -Path $OutDirectory,$IntermediateDirectory -Force | Out-Null
    $out = (Resolve-Path $OutDirectory).Path.TrimEnd('\') + '\'
    $int = (Resolve-Path $IntermediateDirectory).Path.TrimEnd('\') + '\'
    $arguments = @(
        $ProjectPath,
        '/t:Rebuild',
        '/nologo',
        # The legacy compiler and the UTF-8 Windows SDK headers are not
        # reliably reentrant when many CP936 translation units are started at
        # once.  A single MSBuild node keeps the release byte-stable.
        '/m:1',
        '/v:minimal',
        "/p:Configuration=$script:configuration",
        "/p:Platform=$Platform",
        "/p:PlatformToolset=$script:toolset",
        "/p:OutDir=$out",
        "/p:IntDir=$int"
    )
    $log = Join-Path $script:workRoot "$Name-$Platform-msbuild.log"
    [void](Invoke-External -FilePath $script:msbuild -Arguments $arguments -LogPath $log -WorkingDirectory (Split-Path -Parent $ProjectPath))
}

function Find-ModernProject {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$PathHint
    )
    $hinted = Join-Path $Root $PathHint
    if (Test-Path -LiteralPath $hinted -PathType Leaf) { return (Resolve-Path $hinted).Path }
    $found = Get-ChildItem -LiteralPath $Root -Recurse -Filter $Name -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $found) { throw "现代核心工程不存在: $Name ($Root)" }
    return $found.FullName
}

function Get-MetadataFile {
    param([ValidateSet('x86', 'x64')][string]$Architecture)
    if ($Architecture -eq 'x86' -and -not [string]::IsNullOrWhiteSpace($script:X86MetadataFne)) {
        return Find-FirstFile @($script:X86MetadataFne)
    }
    if ($Architecture -eq 'x64' -and -not [string]::IsNullOrWhiteSpace($script:X64MetadataFne)) {
        return Find-FirstFile @($script:X64MetadataFne)
    }
    $modernBuild = Join-Path $script:modernBuildRoot "$Architecture\dynamic\krnln.fne"
    $candidates = @(
        $modernBuild,
        (Join-Path $script:ModernCoreRoot "lib\$Architecture\krnln.fne"),
        (Join-Path $script:MetadataRoot "lib\$Architecture\krnln.fne"),
        (Join-Path $script:MetadataRoot "$Architecture\krnln.fne")
    )
    return Find-FirstFile $candidates
}

function Get-StaticFallback {
    if (-not [string]::IsNullOrWhiteSpace($script:X64FallbackLibrary)) {
        return Find-FirstFile @($script:X64FallbackLibrary)
    }
    $candidates = @(
        (Join-Path $script:modernBuildRoot 'x64\static\krnln_static.lib'),
        (Join-Path $script:ModernCoreRoot 'static_lib\x64\krnln_static.lib'),
        (Join-Path $script:MetadataRoot 'static_lib\x64\krnln_static.lib'),
        (Join-Path $script:MetadataRoot 'x64\krnln_static.lib')
    )
    return Find-FirstFile $candidates
}

function Assert-ArtifactMachine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('x86', 'x64')][string]$Architecture
    )
    $expected = if ($Architecture -eq 'x64') { '8664' } else { '14C' }
    $headers = @(& $script:dumpbin '/headers' $Path 2>&1 | ForEach-Object { [string]$_ })
    $machineLines = @($headers | Where-Object { $_ -match '(?i)\b(?:14C|8664)\s+machine' })
    if ($machineLines.Count -eq 0 -or -not ($machineLines | Where-Object { $_ -match "(?i)\b$expected\s+machine" })) {
        throw "库位数检查失败 ($Architecture): $Path"
    }
    $wrong = if ($Architecture -eq 'x64') { '14C' } else { '8664' }
    if ($machineLines | Where-Object { $_ -match "(?i)\b$wrong\s+machine" }) {
        throw "库包含错误架构成员 ($Architecture): $Path"
    }
}

function Assert-FneExport {
    param([Parameter(Mandatory = $true)][string]$Path)
    $exports = @(& $script:dumpbin '/exports' $Path 2>&1 | ForEach-Object { [string]$_ })
    if (-not ($exports | Where-Object { $_ -match '(?i)\bGetNewInf\b' })) {
        throw "FNE 缺少 GetNewInf 导出: $Path"
    }
}

function Assert-AdapterManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $manifest = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "x64 适配清单不是有效 JSON: $Path"
    }
    if ($manifest.formatVersion -ne 1 -or $manifest.architecture -ne 'x64' -or
        $manifest.abi -ne 'ecompiler-fne-execute-v1' -or
        [string]::IsNullOrWhiteSpace($manifest.primaryArchive) -or
        [string]::IsNullOrWhiteSpace($manifest.fallbackArchive)) {
        throw "x64 适配清单字段不完整: $Path"
    }
    $base = Split-Path -Parent $Path
    foreach ($archive in @($manifest.primaryArchive, $manifest.fallbackArchive)) {
        if (-not (Test-Path -LiteralPath (Join-Path $base $archive) -PathType Leaf)) {
            throw "x64 适配清单引用的归档不存在: $archive"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($manifest.metadataFile)) {
        $metadataPath = Join-Path $base $manifest.metadataFile
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            throw "x64 适配清单引用的 FNE 不存在: $($manifest.metadataFile)"
        }
    }
}

function Copy-Required {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if ([string]::IsNullOrWhiteSpace($Source) -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "$Description 不存在，无法生成发布包。"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Prepare-LegacyUtf8Tree {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRepository,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )
    if (Test-Path -LiteralPath $DestinationRoot) {
        Remove-Item -LiteralPath $DestinationRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DestinationRoot,(Join-Path $DestinationRoot 'Project'),(Join-Path $DestinationRoot 'krnln') -Force | Out-Null
    Copy-Item -Path (Join-Path $SourceRepository 'krnln\*') -Destination (Join-Path $DestinationRoot 'krnln') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $SourceRepository 'Project\krnln_VS2019.vcxproj') `
        -Destination (Join-Path $DestinationRoot 'Project\krnln_VS2019.vcxproj') -Force
    Copy-Item -LiteralPath (Join-Path $SourceRepository 'Readme.txt') `
        -Destination (Join-Path $DestinationRoot 'Readme.txt') -Force

    $encoding936 = [Text.Encoding]::GetEncoding(936)
    $encodingUtf8 = [Text.UTF8Encoding]::new($true)
    $textExtensions = @('.cpp', '.h', '.rc', '.rc2', '.def', '.txt')
    foreach ($file in Get-ChildItem -LiteralPath $DestinationRoot -Recurse -File |
        Where-Object { $textExtensions -contains $_.Extension.ToLowerInvariant() }) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $text = $encodingUtf8.GetString($bytes, 3, $bytes.Length - 3)
        }
        else {
            $text = $encoding936.GetString($bytes)
        }
        $text = $text -replace "`r`n", "`n"
        $text = $text -replace "`r", "`n"
        $text = $text -replace "`n", "`r`n"
        [IO.File]::WriteAllText($file.FullName, $text, $encodingUtf8)
    }
    $projectPath = Join-Path $DestinationRoot 'Project\krnln_VS2019.vcxproj'
    $projectText = [IO.File]::ReadAllText($projectPath, $encodingUtf8)
    $projectText = $projectText.Replace('/source-charset:.936 /execution-charset:.936', '/source-charset:utf-8 /execution-charset:.936')
    if ($projectText -notmatch '/source-charset:utf-8') {
        throw "无法为隔离工程设置 UTF-8 源码字符集: $projectPath"
    }
    [IO.File]::WriteAllText($projectPath, $projectText, $encodingUtf8)
    return $DestinationRoot
}

function Write-Utf8Json {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($true))
}

function New-ReleaseZip {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths
    )
    $zipRoot = Join-Path $script:zipWorkRoot $Name
    if (Test-Path -LiteralPath $zipRoot) { Remove-Item -LiteralPath $zipRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $zipRoot -Force | Out-Null
    foreach ($relative in $RelativePaths) {
        $source = Join-Path $script:releaseRoot $relative
        if (-not (Test-Path -LiteralPath $source)) { throw "发布包文件缺失: $source" }
        $destination = Join-Path $zipRoot $relative
        if ((Get-Item -LiteralPath $source).PSIsContainer) {
            Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
        } else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
    }
    $zipPath = Join-Path $script:releaseRoot "$Name.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $zipRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal
    return $zipPath
}

# Keep all source and tool output deterministic regardless of the runner locale.
cmd.exe /c 'chcp 936>nul' | Out-Null
$env:VSLANG = '1033'
$env:VSCMD_SKIP_SENDTELEMETRY = '1'
$script:msbuild = Resolve-MsBuild $MsBuildPath
$script:configuration = $Configuration
$script:vsInstall = Find-VsInstall $script:msbuild
$script:toolset = Resolve-Toolset $PlatformToolset $script:vsInstall
$script:x64Compiler = ''
$script:dumpbin = ''
if (-not [string]::IsNullOrWhiteSpace($script:vsInstall)) {
    $script:x64Compiler = Resolve-VcCompiler $script:vsInstall 'x64'
    $script:dumpbin = Join-Path (Split-Path -Parent $script:x64Compiler) 'dumpbin.exe'
}
if (-not (Test-Path -LiteralPath $script:dumpbin -PathType Leaf)) {
    $dumpbinCommand = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($null -ne $dumpbinCommand) { $script:dumpbin = $dumpbinCommand.Source }
}
$script:dumpbin = Resolve-FilePath $script:dumpbin 'dumpbin.exe'
if (-not $script:x64Compiler) {
    $clCommand = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($null -ne $clCommand) { $script:x64Compiler = $clCommand.Source }
}
if ([string]::IsNullOrWhiteSpace($script:x64Compiler)) {
    throw '未找到 x64 cl.exe。'
}

if ([string]::IsNullOrWhiteSpace($ModernCoreRoot)) {
    if (-not $LegacyOnly -and (-not $SkipModernBuild -or -not $SkipX64Adapter)) {
        throw '必须通过 -ModernCoreRoot 指定匹配的现代核心源码目录。'
    }
}
if ([string]::IsNullOrWhiteSpace($MetadataRoot) -and -not [string]::IsNullOrWhiteSpace($ModernCoreRoot)) {
    $MetadataRoot = $ModernCoreRoot
}
$script:ModernCoreRoot = $ModernCoreRoot
$script:MetadataRoot = $MetadataRoot
$script:X86MetadataFne = $X86MetadataFne
$script:X64MetadataFne = $X64MetadataFne
$script:X64FallbackLibrary = $X64FallbackLibrary

$script:releaseRoot = $OutputRoot
$script:packageRoot = Join-Path $script:releaseRoot 'adapter'
$script:workRoot = Join-Path $script:releaseRoot '.build'
$script:modernBuildRoot = Join-Path $script:workRoot 'modern'
$script:zipWorkRoot = Join-Path $script:workRoot 'zip'
if (Test-Path -LiteralPath $script:packageRoot) { Remove-Item -LiteralPath $script:packageRoot -Recurse -Force }
foreach ($projectionDirectory in @((Join-Path $script:releaseRoot 'lib'), (Join-Path $script:releaseRoot 'static_lib'))) {
    if (Test-Path -LiteralPath $projectionDirectory) {
        Remove-Item -LiteralPath $projectionDirectory -Recurse -Force
    }
}
foreach ($staleManifest in @((Join-Path $script:releaseRoot 'blackmoon-package.json'))) {
    if (Test-Path -LiteralPath $staleManifest -PathType Leaf) {
        Remove-Item -LiteralPath $staleManifest -Force
    }
}
Get-ChildItem -LiteralPath $script:releaseRoot -Filter 'BlackMoonKernelStaticLib-*.zip' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force
New-Item -ItemType Directory -Path $script:packageRoot,$script:workRoot,$script:zipWorkRoot -Force | Out-Null

$legacyStageRoot = Prepare-LegacyUtf8Tree -SourceRepository $repositoryRoot `
    -DestinationRoot (Join-Path $script:workRoot 'legacy-source-utf8')
$legacyProject = Join-Path $legacyStageRoot 'Project\krnln_VS2019.vcxproj'
$legacyOut = Join-Path $script:workRoot 'legacy\x86\static'
$legacyInt = Join-Path $script:workRoot 'legacy\x86\obj'
Build-MsBuildProject -ProjectPath $legacyProject -Platform Win32 -OutDirectory $legacyOut -IntermediateDirectory $legacyInt -Name 'legacy-core'
$legacyArchive = Find-FirstFile @(
    (Join-Path $legacyOut 'krnln.lib'),
    (Join-Path $legacyOut 'krnln_static.lib')
)
if ([string]::IsNullOrWhiteSpace($legacyArchive)) { throw "未找到 Win32 核心静态库: $legacyOut" }
Copy-Required $legacyArchive (Join-Path $script:packageRoot 'static_lib\x86\krnln_static.lib') 'Win32 核心静态库'
if ($LegacyOnly) {
    Assert-ArtifactMachine (Join-Path $script:packageRoot 'static_lib\x86\krnln_static.lib') 'x86'
    Write-Output ("legacy-release-built: archive={0}" -f (Join-Path $script:packageRoot 'static_lib\x86\krnln_static.lib'))
    return
}

if (-not $SkipModernBuild) {
    if (-not (Test-Path -LiteralPath $ModernCoreRoot -PathType Container)) {
        throw "现代核心源码目录不存在: $ModernCoreRoot"
    }
    $modernDynamicProject = Find-ModernProject $ModernCoreRoot 'krnln.vcxproj' '支持库源码\krnln\krnln.vcxproj'
    foreach ($platform in @('Win32', 'x64')) {
        $architecture = if ($platform -eq 'Win32') { 'x86' } else { 'x64' }
        Build-MsBuildProject -ProjectPath $modernDynamicProject -Platform $platform `
            -OutDirectory (Join-Path $script:modernBuildRoot "$architecture\dynamic") `
            -IntermediateDirectory (Join-Path $script:modernBuildRoot "$architecture\dynamic-obj") `
            -Name 'modern-dynamic'
    }
    $modernStaticProject = Find-ModernProject $ModernCoreRoot 'krnln_static.vcxproj' '支持库源码\krnln\krnln_static\krnln_static.vcxproj'
    Build-MsBuildProject -ProjectPath $modernStaticProject -Platform x64 `
        -OutDirectory (Join-Path $script:modernBuildRoot 'x64\static') `
        -IntermediateDirectory (Join-Path $script:modernBuildRoot 'x64\static-obj') `
        -Name 'modern-static'
}

$x86Metadata = Get-MetadataFile 'x86'
$x64Metadata = Get-MetadataFile 'x64'
Copy-Required $x86Metadata (Join-Path $script:packageRoot 'lib\x86\krnln.fne') 'Win32 核心 FNE'
if (-not $SkipX64Adapter) {
    $x64Fallback = Get-StaticFallback
    if ([string]::IsNullOrWhiteSpace($x64Fallback)) { throw '未找到 x64 兼容核心静态库。' }
    $adapterScript = Resolve-FilePath (Join-Path $PSScriptRoot 'BuildBlackMoonCoreAdapter.ps1') 'x64 适配器脚本'
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -eq $pwsh) { $pwsh = Get-Command powershell.exe -ErrorAction SilentlyContinue }
    if ($null -eq $pwsh) { throw '未找到 PowerShell 执行程序。' }
    $adapterArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $adapterScript,
        '-SourceRoot', (Join-Path $legacyStageRoot 'krnln'),
        '-ModernCoreRoot', $ModernCoreRoot,
        '-FallbackLibrary', $x64Fallback,
        '-MetadataFne', $x64Metadata,
        '-OutputRoot', (Join-Path $script:packageRoot 'static_lib\x64'),
        '-WorkRoot', (Join-Path $script:workRoot 'x64-adapter'),
        '-CompilerPath', $script:x64Compiler
    )
    $adapterLog = Join-Path $script:workRoot 'x64-adapter.log'
    [void](Invoke-External -FilePath $pwsh.Source -Arguments $adapterArguments -LogPath $adapterLog -WorkingDirectory $repositoryRoot)
}
else {
    $prebuiltPrimary = Find-FirstFile @(
        $X64PrimaryLibrary,
        (Join-Path $script:MetadataRoot 'static_lib\x64\krnln_static.lib'),
        (Join-Path $script:MetadataRoot 'adapter\static_lib\x64\krnln_static.lib')
    )
    $prebuiltFallback = Find-FirstFile @(
        $X64FallbackLibrary,
        (Join-Path $script:MetadataRoot 'static_lib\x64\krnln_fallback.lib'),
        (Join-Path $script:MetadataRoot 'adapter\static_lib\x64\krnln_fallback.lib')
    )
    $prebuiltManifest = Find-FirstFile @(
        $X64AdapterManifest,
        (Join-Path $script:MetadataRoot 'static_lib\x64\krnln_adapter.json'),
        (Join-Path $script:MetadataRoot 'adapter\static_lib\x64\krnln_adapter.json')
    )
    Copy-Required $prebuiltPrimary (Join-Path $script:packageRoot 'static_lib\x64\krnln_static.lib') '预构建 x64 主归档'
    Copy-Required $prebuiltFallback (Join-Path $script:packageRoot 'static_lib\x64\krnln_fallback.lib') '预构建 x64 后备归档'
    Copy-Required $prebuiltManifest (Join-Path $script:packageRoot 'static_lib\x64\krnln_adapter.json') '预构建 x64 适配清单'
}

$x64Primary = Find-FirstFile @(
    (Join-Path $script:packageRoot 'static_lib\x64\krnln_static.lib'),
    (Join-Path $script:packageRoot 'static_lib\x64\krnln.lib')
)
if ([string]::IsNullOrWhiteSpace($x64Primary)) { throw '未找到 x64 核心适配静态库。' }
$x64MetadataInPackage = Join-Path $script:packageRoot 'lib\x64\krnln.fne'
if (-not (Test-Path -LiteralPath $x64MetadataInPackage -PathType Leaf)) {
    Copy-Required $x64Metadata (Join-Path $script:packageRoot 'lib\x64\krnln.fne') 'x64 核心 FNE'
}
# A failed/old adapter invocation may leave its private work tree under the
# package root. It is useful for local diagnostics, but never belongs in a
# release archive.
$privateBuildDirectories = @(Get-ChildItem -LiteralPath $script:packageRoot -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('.adapter-build', '.build', 'obj', 'Debug', 'Release') } |
    Sort-Object FullName -Descending)
foreach ($privateDirectory in $privateBuildDirectories) {
    Remove-Item -LiteralPath $privateDirectory.FullName -Recurse -Force
}
$unexpected = @(Get-ChildItem -LiteralPath $script:packageRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension.ToLowerInvariant() -notin @('.fne', '.lib', '.json', '.md', '.txt') })
if ($unexpected.Count -gt 0) {
    throw "发布目录包含未允许的文件: $($unexpected[0].FullName)"
}

# Also emit the conventional e-packager product-root projection.  It lets a
# user overlay the extracted package onto an e-packager directory, while the
# nested adapter tree remains suitable for --blackmoon-x64-dir.
$overlayFiles = @(
    @{ source = Join-Path $script:packageRoot 'lib\x86\krnln.fne'; destination = Join-Path $script:releaseRoot 'lib\x86\krnln.fne' },
    @{ source = Join-Path $script:packageRoot 'lib\x64\krnln.fne'; destination = Join-Path $script:releaseRoot 'lib\x64\krnln.fne' },
    @{ source = Join-Path $script:packageRoot 'lib\x86\krnln.fne'; destination = Join-Path $script:releaseRoot 'lib\krnln.fne' },
    @{ source = Join-Path $script:packageRoot 'static_lib\x86\krnln_static.lib'; destination = Join-Path $script:releaseRoot 'static_lib\x86\krnln_static.lib' },
    @{ source = Join-Path $script:packageRoot 'static_lib\x86\krnln_static.lib'; destination = Join-Path $script:releaseRoot 'static_lib\x86\krnln.lib' },
    @{ source = Join-Path $script:packageRoot 'static_lib\x64\krnln_static.lib'; destination = Join-Path $script:releaseRoot 'static_lib\x64\krnln_static.lib' },
    @{ source = Join-Path $script:packageRoot 'static_lib\x64\krnln_static.lib'; destination = Join-Path $script:releaseRoot 'static_lib\x64\krnln.lib' },
    @{ source = Join-Path $script:packageRoot 'static_lib\x64\krnln_fallback.lib'; destination = Join-Path $script:releaseRoot 'static_lib\x64\krnln_fallback.lib' },
    @{ source = Join-Path $script:packageRoot 'static_lib\x86\krnln_static.lib'; destination = Join-Path $script:releaseRoot 'static_lib\krnln_static.lib' },
    @{ source = Join-Path $script:packageRoot 'static_lib\x86\krnln_static.lib'; destination = Join-Path $script:releaseRoot 'static_lib\krnln.lib' }
)
foreach ($overlay in $overlayFiles) {
    Copy-Required $overlay.source $overlay.destination 'e-packager 产品根目录投影文件'
}
Copy-Required (Join-Path $script:packageRoot 'static_lib\x86\krnln_static.lib') `
    (Join-Path $script:packageRoot 'static_lib\x86\krnln.lib') 'Win32 BlackMoon 兼容库别名'
Copy-Required (Join-Path $script:packageRoot 'static_lib\x64\krnln_static.lib') `
    (Join-Path $script:packageRoot 'static_lib\x64\krnln.lib') 'x64 核心兼容库别名'
Copy-Required (Join-Path $script:packageRoot 'static_lib\x64\krnln_adapter.json') `
    (Join-Path $script:releaseRoot 'static_lib\x64\krnln_adapter.json') 'x64 适配清单'
Copy-Required (Join-Path $script:packageRoot 'lib\x86\krnln.fne') `
    (Join-Path $script:packageRoot 'lib\krnln.fne') 'Win32 FNE 兼容路径'

Assert-ArtifactMachine (Join-Path $script:packageRoot 'static_lib\x86\krnln_static.lib') 'x86'
Assert-ArtifactMachine $x64Primary 'x64'
Assert-ArtifactMachine (Join-Path $script:packageRoot 'lib\x86\krnln.fne') 'x86'
Assert-ArtifactMachine $x64MetadataInPackage 'x64'
Assert-FneExport (Join-Path $script:packageRoot 'lib\x86\krnln.fne')
Assert-FneExport $x64MetadataInPackage
Assert-AdapterManifest (Join-Path $script:packageRoot 'static_lib\x64\krnln_adapter.json')

$versionValue = $Version
if ([string]::IsNullOrWhiteSpace($versionValue) -and $env:GITHUB_REF_NAME) { $versionValue = $env:GITHUB_REF_NAME }
if ([string]::IsNullOrWhiteSpace($versionValue)) {
    $versionValue = @(& git -C $repositoryRoot describe --tags --always --dirty 2>$null | Select-Object -First 1)
}
if ([string]::IsNullOrWhiteSpace($versionValue)) { $versionValue = 'local' }
$safeVersion = ($versionValue -replace '[^A-Za-z0-9_.-]', '-')
$isPrerelease = Test-PrereleaseVersion $versionValue
$gitRevision = @(& git -C $repositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1)
$modernRevision = @()
if (Test-Path -LiteralPath $script:ModernCoreRoot -PathType Container) {
    $modernRevision = @(& git -C $script:ModernCoreRoot rev-parse HEAD 2>$null | Select-Object -First 1)
}
$readme = @'
# BlackMoonKernelStaticLib release layout

`adapter/lib/<arch>/krnln.fne` is the dynamic support-library metadata.
`adapter/static_lib/<arch>/krnln_static.lib` is the matching static archive.
The x64 directory also contains `krnln_fallback.lib` and `krnln_adapter.json`.

For e-packager x64 compilation pass the extracted `adapter` directory to
`--blackmoon-x64-dir`.  The legacy input is CP936 and generated adapter units
are UTF-8;
the release builder decodes the legacy CP936 sources in an isolated tree and
then compiles UTF-8 sources with a CP936 execution charset, so the runner
locale does not change the binary interface.  The zip also contains root
`lib/` and `static_lib/` projections for direct e-packager overlay.
'@
[IO.File]::WriteAllText((Join-Path $script:packageRoot 'README.md'), $readme, [Text.UTF8Encoding]::new($true))
Copy-Required (Join-Path $repositoryRoot 'LICENSE') (Join-Path $script:packageRoot 'LICENSE') 'BlackMoon 许可证'
Copy-Required (Join-Path $repositoryRoot 'LICENSE') (Join-Path $script:releaseRoot 'LICENSE') 'BlackMoon 许可证投影'
$thirdPartyNotice = @'
The x64 fallback archive and FNE metadata are built from the pinned
chungbinb/ycIDE-electron revision recorded in blackmoon-package.json.
That dependency is distributed under the MIT License; retain its copyright
notice when redistributing the generated binaries.
'@
[IO.File]::WriteAllText((Join-Path $script:packageRoot 'THIRD_PARTY_NOTICES.txt'), $thirdPartyNotice, [Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText((Join-Path $script:releaseRoot 'THIRD_PARTY_NOTICES.txt'), $thirdPartyNotice, [Text.UTF8Encoding]::new($true))
$files = @(
    'adapter/lib/x86/krnln.fne',
    'adapter/lib/krnln.fne',
    'adapter/lib/x64/krnln.fne',
    'adapter/static_lib/x86/krnln_static.lib',
    'adapter/static_lib/x86/krnln.lib',
    'adapter/static_lib/x64/krnln_static.lib',
    'adapter/static_lib/x64/krnln.lib'
)
if (Test-Path -LiteralPath (Join-Path $script:packageRoot 'static_lib\x64\krnln_fallback.lib') -PathType Leaf) {
    $files += 'adapter/static_lib/x64/krnln_fallback.lib'
}
$files += @(
    'lib/x86/krnln.fne', 'lib/x64/krnln.fne', 'lib/krnln.fne',
    'static_lib/x86/krnln_static.lib', 'static_lib/x64/krnln_static.lib',
    'static_lib/x86/krnln.lib', 'static_lib/x64/krnln_fallback.lib',
    'static_lib/x64/krnln.lib', 'static_lib/krnln_static.lib', 'static_lib/krnln.lib',
    'adapter/LICENSE', 'adapter/THIRD_PARTY_NOTICES.txt',
    'LICENSE', 'THIRD_PARTY_NOTICES.txt'
)
$manifestFiles = [ordered]@{}
foreach ($relative in $files) {
    $path = Join-Path $script:releaseRoot $relative
    $manifestFiles[$relative] = [ordered]@{
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $path).Length
    }
}
$manifest = [ordered]@{
    formatVersion = 1
    product = 'BlackMoonKernelStaticLib'
    version = $versionValue
    prerelease = $isPrerelease
    revision = if ($gitRevision.Count -gt 0) { $gitRevision[0] } else { '' }
    configuration = $script:configuration
    platformToolset = $script:toolset
    sourceEncoding = 'CP936 (normalized to UTF-8 in the isolated build tree)'
    generatedSourceEncoding = 'UTF-8'
    dependencies = [ordered]@{
        modernCoreRepository = 'chungbinb/ycIDE-electron'
        modernCoreRevision = if ($modernRevision.Count -gt 0) { $modernRevision[0] } else { '' }
    }
    architectures = [ordered]@{
        x86 = [ordered]@{ metadata = 'lib/x86/krnln.fne'; static = 'static_lib/x86/krnln_static.lib'; machine = 'I386' }
        x64 = [ordered]@{ metadata = 'lib/x64/krnln.fne'; static = 'static_lib/x64/krnln_static.lib'; fallback = 'static_lib/x64/krnln_fallback.lib'; machine = 'AMD64'; adapterManifest = 'static_lib/x64/krnln_adapter.json' }
    }
    productRootProjection = [ordered]@{ x86Metadata = 'lib/krnln.fne'; x86Static = 'static_lib/krnln_static.lib'; x64Root = '.' }
    files = $manifestFiles
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
}
Write-Utf8Json (Join-Path $script:packageRoot 'blackmoon-package.json') $manifest
Write-Utf8Json (Join-Path $script:releaseRoot 'blackmoon-package.json') $manifest

$combinedName = "BlackMoonKernelStaticLib-$safeVersion"
$x86Name = "$combinedName-x86"
$x64Name = "$combinedName-x64"
$combinedZip = New-ReleaseZip -Name $combinedName -RelativePaths @('adapter', 'lib', 'static_lib', 'LICENSE', 'THIRD_PARTY_NOTICES.txt', 'blackmoon-package.json')
$x86Zip = New-ReleaseZip -Name $x86Name -RelativePaths @('lib/krnln.fne', 'static_lib/krnln_static.lib', 'static_lib/krnln.lib', 'adapter/lib/x86', 'adapter/static_lib/x86', 'adapter/README.md', 'adapter/LICENSE', 'adapter/THIRD_PARTY_NOTICES.txt', 'adapter/blackmoon-package.json', 'LICENSE', 'THIRD_PARTY_NOTICES.txt', 'blackmoon-package.json')
$x64Zip = New-ReleaseZip -Name $x64Name -RelativePaths @('lib/x64', 'static_lib/x64', 'adapter/lib/x64', 'adapter/static_lib/x64', 'adapter/README.md', 'adapter/LICENSE', 'adapter/THIRD_PARTY_NOTICES.txt', 'adapter/blackmoon-package.json', 'LICENSE', 'THIRD_PARTY_NOTICES.txt', 'blackmoon-package.json')
Write-Output ("release-built: version={0};x86={1};x64={2};combined={3}" -f $versionValue, $x86Zip, $x64Zip, $combinedZip)

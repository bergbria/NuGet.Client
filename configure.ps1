<#
.SYNOPSIS
Configures NuGet.Client build environment. Detects and initializes
VS build toolsets. Configuration settings are stored at configure.json file.

.PARAMETER CleanCache
Cleans NuGet packages cache before build

.PARAMETER Force
Switch to force installation of required tools.

.PARAMETER CI
Indicates the build script is invoked from CI

.PARAMETER Test
Indicates the Tests need to be run. Downloads the Test cli when tests are needed to run.

.EXAMPLE
.\configure.ps1 -cc -v
Clean repo build environment configuration

.EXAMPLE
.\configure.ps1 -v
Incremental install of build tools
#>
[CmdletBinding(SupportsShouldProcess=$True)]
Param (
    [Alias('cc')]
    [switch]$CleanCache,
    [Alias('f')]
    [switch]$Force,
    [switch]$CI,
    [Alias('s15')]
    [switch]$SkipVS15,
    [Alias('s16')]
    [switch]$SkipVS16,
    [switch]$RunTest
)

. "$PSScriptRoot\build\common.ps1"

Trace-Log "Configuring NuGet.Client build environment"

$BuildErrors = @()

Invoke-BuildStep 'Configuring git repo' {
    Update-SubModules -Force:$Force
} -ev +BuildErrors

Invoke-BuildStep 'Installing NuGet.exe' {
    Install-NuGet -Force:$Force -CI:$CI
} -ev +BuildErrors

Invoke-BuildStep 'Installing .NET CLI' {
    Install-DotnetCLIToILMergePack -Force:$Force
    Install-DotnetCLI -Force:$Force
} -ev +BuildErrors

# Restoring tools required for build
Invoke-BuildStep 'Restoring solution packages' {
    Restore-SolutionPackages
} -ev +BuildErrors

Invoke-BuildStep 'Cleaning package cache' {
    Clear-PackageCache
} -skip:(-not $CleanCache) -ev +BuildErrors

$ConfigureObject = @{
    BuildTools = @{}
    Toolsets = @{}
}

Function New-BuildToolset {
    param(
        [int]$ToolsetVersion
    )
    $CommonToolsVar = "Env:VS${ToolsetVersion}0COMNTOOLS"
    if (Test-Path $CommonToolsVar) {
        $CommonToolsValue = gci $CommonToolsVar | select -expand value -ea Ignore
        Verbose-Log "Using environment variable `"$CommonToolsVar`" = `"$CommonToolsValue`""
        $ToolsetObject = @{
            VisualStudioInstallDir = [System.IO.Path]::GetFullPath((Join-Path $CommonToolsValue '..\IDE'))
        }
        Warning-Log "Here!!"
    }

    if (-not $ToolsetObject) {
        Warning-LOg "IN ToolsetObject"
        $VisualStudioRegistryKey = "HKCU:\SOFTWARE\Microsoft\VisualStudio\${ToolsetVersion}.0_Config"
        if (Test-Path $VisualStudioRegistryKey) {
            Verbose-Log "Retrieving Visual Studio installation path from registry '$VisualStudioRegistryKey'"
            $ToolsetObject = @{
                VisualStudioInstallDir = gp $VisualStudioRegistryKey | select -expand InstallDir -ea Ignore
            }
        }
    }

    if (-not $ToolsetObject -and $ToolsetVersion -gt 14) {
        Verbose-Log "are we here"

        $VisualStudioInstallRootDir = Get-LatestVisualStudioRoot #Should we really be getting this here? Look for the actual toolset version

        if ($VisualStudioInstallRootDir) {
            Verbose-Log "Using willow instance '$VisualStudioInstallRootDir' installation path"
            $ToolsetObject = @{
                VisualStudioInstallDir = [System.IO.Path]::GetFullPath((Join-Path $VisualStudioInstallRootDir Common7\IDE\))
            }
        }
    }

    if (-not $ToolsetObject) {
        Warning-Log "Toolset VS${ToolsetVersion} is not found."
    }

    # return toolset build configuration object
    $ToolsetObject
}

$ProgramFiles = ${env:ProgramFiles(x86)}

if (-not $ProgramFiles -or -not (Test-Path $ProgramFiles)) {
    $ProgramFiles = $env:ProgramFiles
}

$MSBuildDefaultRoot = Get-MSBuildRoot
$MSBuildRelativePath = 'bin\msbuild.exe'

Invoke-BuildStep 'Validating VS15 toolset installation' {
    $vs15 = New-BuildToolset 15
    if ($vs15) {
        $ConfigureObject.Toolsets.Add('vs15', $vs15)
        $script:MSBuildExe = Get-MSBuildExe 15

        # Hack VSSDK path
        $VSToolsPath = Join-Path $MSBuildDefaultRoot 'Microsoft\VisualStudio\v15.0'
        $Targets = Join-Path $VSToolsPath 'VSSDK\Microsoft.VsSDK.targets'
        if (-not (Test-Path $Targets)) {
            Warning-Log "VSSDK is not found at default location '$VSToolsPath'. Attempting to override."
            # Attempting to fix VS SDK path for VS15 willow install builds
            # as MSBUILD failes to resolve it correctly
            $VSToolsPath = Join-Path $vs15.VisualStudioInstallDir '..\..\MSBuild\Microsoft\VisualStudio\v15.0' -Resolve
            $ConfigureObject.Add('EnvVars', @{ VSToolsPath = $VSToolsPath })
        }
    }
} -skip:($SkipVS15) -ev +BuildErrors

Invoke-BuildStep 'Validating VS16 toolset installation' {
    $vs16 = New-BuildToolset 16
    if ($vs16) {
        $ConfigureObject.Toolsets.Add('vs16', $vs16)
        $script:MSBuildExe = Get-MSBuildExe 16

        # Hack VSSDK path
        $VSToolsPath = Join-Path $vs16.VisualStudioInstallDir 'Microsoft\VisualStudio\v16.0'

        $Targets = Join-Path $VSToolsPath 'VSSDK\Microsoft.VsSDK.targets'

        if (-not (Test-Path $Targets)) {
            Warning-Log "VSSDK is not found at default location '$VSToolsPath'. Attempting to override."
            # Attempting to fix VS SDK path for VS16 willow install builds
            # as MSBUILD failes to resolve it correctly
            $VSToolsPath = Join-Path $vs16.VisualStudioInstallDir '..\..\MSBuild\Microsoft\VisualStudio\v16.0' -Resolve
            $ConfigureObject.Add('EnvVars', @{ VSToolsPath = $VSToolsPath })
        }
    }
} -skip:($SkipVS16) -ev +BuildErrors

if ($MSBuildExe) {
    $MSBuildExe = [System.IO.Path]::GetFullPath($MSBuildExe)
    $MSBuildVersion = & $MSBuildExe '/version' '/nologo'
    Trace-Log "Using MSBUILD version $MSBuildVersion found at '$MSBuildExe'"
    $ConfigureObject.BuildTools.Add('MSBuildExe', $MSBuildExe)
}

New-Item $Artifacts -ItemType Directory -ea Ignore | Out-Null
$ConfigureObject | ConvertTo-Json -Compress | Set-Content $ConfigureJson

Trace-Log "Configuration data has been written to '$ConfigureJson'"

if ($BuildErrors) {
    $ErrorLines = $BuildErrors | %{ ">>> $($_.Exception.Message)" }
    Write-Error "Build's completed with $($BuildErrors.Count) error(s):`r`n$($ErrorLines -join "`r`n")" -ErrorAction Stop
}
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Analyze', 'Safe', 'Deep', 'Maximum', 'MaximumPreview')]
    [string]$Mode,

    [switch]$ElevatedChild,
    [ValidatePattern('^S-1-[0-9]+(-[0-9]+)+$')]
    [string]$ExpectedUserSid,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcherPath = $MyInvocation.MyCommand.Path

function Complete-Launcher {
    param([int]$Code)

    Write-Host ''
    Write-Host ('Launcher exit code: {0}' -f $Code)
    if (-not $NoPause -and -not $ElevatedChild) {
        try { [void](Read-Host 'Press Enter to close this window') } catch {}
    }
    exit $Code
}

function ConvertTo-CommandLineArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    # Windows native argument quoting: double backslashes before quotes and
    # before the closing quote. Start-Process does not invoke cmd.exe.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-CleanupStage {
    param([ValidateSet('All', 'User', 'System')][string]$Scope)

    $targetScript = Join-Path $scriptRoot 'Clean-CDriveCache.ps1'
    $targetArguments = @('-Scope', $Scope)
    switch ($Mode) {
        'Analyze' {
            $targetScript = Join-Path $scriptRoot 'Analyze-CDriveCache.ps1'
            $targetArguments += @('-CleanupLevel', 'Maximum')
            if ($Scope -ne 'User') { $targetArguments += '-AnalyzeComponentStore' }
        }
        'MaximumPreview' { $targetArguments += @('-DryRun', '-CleanupLevel', 'Maximum') }
        default { $targetArguments += @('-CleanupLevel', $Mode) }
    }
    if (-not (Test-Path -LiteralPath $targetScript -PathType Leaf)) {
        throw ('Required script was not found: {0}' -f $targetScript)
    }

    Write-Host ('Starting {0}: Scope={1}' -f $Mode, $Scope)
    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $targetScript @targetArguments | Out-Host
    return [int]$LASTEXITCODE
}

try {
    $powerShellPath = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
        throw ('Windows PowerShell was not found: {0}' -f $powerShellPath)
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $identity.User.Value
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedUserSid) -and $ExpectedUserSid -ne $currentSid) {
        Write-Error 'The elevated account differs from the original account. No system stage was started. Use same-account UAC consent; do not enter another administrator account.' -ErrorAction Continue
        Complete-Launcher -Code 5
    }

    if ($ElevatedChild) {
        if ([string]::IsNullOrWhiteSpace($ExpectedUserSid) -or -not $isAdmin) {
            Write-Error 'The system-stage child requires administrator rights and the original account SID.' -ErrorAction Continue
            Complete-Launcher -Code 5
        }
        Complete-Launcher -Code (Invoke-CleanupStage -Scope System)
    }

    if ($isAdmin) {
        if ($Mode -notin @('Analyze', 'MaximumPreview')) {
            Write-Error 'Start this BAT file by ordinary double-click from a non-administrator window. User caches must be cleaned before elevation. Do not select Run as administrator.' -ErrorAction Continue
            Complete-Launcher -Code 5
        }
        Complete-Launcher -Code (Invoke-CleanupStage -Scope All)
    }

    Write-Host 'Stage 1/2: current-account caches, without administrator rights.'
    $userCode = Invoke-CleanupStage -Scope User
    Write-Host ('User-stage exit code: {0}' -f $userCode)
    if ($userCode -notin @(0, 2)) {
        Write-Error 'The user stage aborted. The system stage was not started. See the report or error above.' -ErrorAction Continue
        Complete-Launcher -Code $userCode
    }

    Write-Host ''
    Write-Host 'Stage 2/2: Windows caches. Accept UAC for this SAME account.'
    Write-Host 'The system stage runs in the background; this window waits for it.'
    Write-Host 'DISM may take several minutes. Reports are written to the reports folder.'
    $launcherArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcherPath,
        '-Mode', $Mode, '-ElevatedChild', '-ExpectedUserSid', $currentSid, '-NoPause'
    )
    $argumentLine = ($launcherArguments | ForEach-Object { ConvertTo-CommandLineArgument -Value $_ }) -join ' '
    try {
        $process = Start-Process -FilePath $powerShellPath -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -WindowStyle Hidden
        $systemCode = [int]$process.ExitCode
    }
    catch {
        Write-Error ('Administrator elevation was cancelled or failed: {0}' -f $_.Exception.Message) -ErrorAction Continue
        Write-Host 'Only the user stage completed. System caches were not cleaned by this launcher.'
        Complete-Launcher -Code 1223
    }

    Write-Host ('System-stage exit code: {0}' -f $systemCode)
    Write-Host ('Reports: {0}' -f (Join-Path $scriptRoot 'reports'))
    if ($systemCode -eq 5) {
        Write-Error 'The system stage rejected elevation or an account change. Use the original account; inspect the user-stage report for work already completed.' -ErrorAction Continue
    }
    elseif ($systemCode -ne 0) {
        Write-Error 'The system stage reported errors. Read the latest reports before running cleanup again.' -ErrorAction Continue
    }
    if ($systemCode -ne 0) { Complete-Launcher -Code $systemCode }
    Complete-Launcher -Code $userCode
}
catch {
    Write-Error ('Launcher failed: {0}' -f $_.Exception.Message) -ErrorAction Continue
    Complete-Launcher -Code 1
}

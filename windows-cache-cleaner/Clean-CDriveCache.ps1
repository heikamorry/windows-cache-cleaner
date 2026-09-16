#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Safe', 'Deep', 'Maximum')]
    [string]$CleanupLevel = 'Safe',

    [ValidateSet('All', 'User', 'System')]
    [string]$Scope = 'All',
    [switch]$DryRun,
    [switch]$IncludeBrowsers,
    [switch]$IncludeWindowsUpdate,
    [switch]$IncludeApplicationCaches,
    [switch]$IncludeDeveloperCaches,
    [switch]$IncludeWindowsErrorReports,
    [switch]$IncludeCrashDumps,
    [switch]$IncludeAllUserTemp,
    [switch]$IncludeOfflineWebCaches,
    [switch]$IncludeDownloadedModels,
    [switch]$IncludePinnedDeliveryFiles,
    [switch]$IncludeRecycleBin,
    [switch]$SkipRecycleBin,
    [switch]$StopBrowserProcesses,
    [switch]$ForceCloseBrowserProcesses,
    [switch]$RunDismComponentCleanup,
    [switch]$ResetComponentBase,
    [switch]$RemovePreviousWindowsInstallation,
    [switch]$AllowRecoveryLoss,

    [ValidateSet('Keep', 'Reduced', 'Off')]
    [string]$HibernationMode = 'Keep',

    [ValidateRange(-1, 3650)]
    [int]$TempFileAgeDays = -1,

    [string]$ReportDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'CacheCleanup.Common.ps1')
. (Join-Path $scriptRoot 'CacheCleanup.Native.ps1')

if (($ResetComponentBase -or $RemovePreviousWindowsInstallation) -and -not $AllowRecoveryLoss) {
    throw 'Use -AllowRecoveryLoss with -ResetComponentBase or -RemovePreviousWindowsInstallation after reviewing the rollback impact.'
}
if ($ForceCloseBrowserProcesses -and -not $StopBrowserProcesses) {
    throw '-ForceCloseBrowserProcesses requires -StopBrowserProcesses.'
}

$script:PreviewMode = $DryRun.IsPresent -or [bool]$WhatIfPreference
$script:IsAdmin = Test-RunningAsAdministrator
$script:ExitCode = 0
$script:RunState = 'Starting'
$script:Results = New-Object System.Collections.Generic.List[object]
$script:LogWriter = $null
$script:Mutex = $null
$script:MutexAcquired = $false
$script:RunCutoffUtc = [DateTime]::UtcNow
$script:ActiveServiceStates = New-Object System.Collections.Generic.List[object]

if ([string]::IsNullOrWhiteSpace($ReportDirectory)) {
    $ReportDirectory = Join-Path $scriptRoot 'reports'
}

function Initialize-RunReports {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $Directory = ConvertTo-NormalizedFileSystemPath $Directory
    $cursor = $Directory
    while ($cursor) {
        try {
            $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ((Test-ReparsePoint $entry) -or -not $entry.PSIsContainer) { throw 'Unsafe report directory/ancestor.' }
        }
        catch [System.Management.Automation.ItemNotFoundException] {}
        $cursor = Split-Path -Parent $cursor
    }
    if (Test-Path -LiteralPath $Directory) {
        $directoryItem = Get-Item -LiteralPath $Directory -Force -ErrorAction Stop
        if (-not $directoryItem.PSIsContainer) {
            throw ('Report path is not a directory: {0}' -f $Directory)
        }
        if (Test-ReparsePoint -Item $directoryItem) {
            throw ('Refusing to write reports through a reparse point: {0}' -f $Directory)
        }
    }
    else {
        New-Item -Path $Directory -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false | Out-Null
    }

    $directoryItem = Get-Item -LiteralPath $Directory -Force -ErrorAction Stop
    if (Test-ReparsePoint -Item $directoryItem) {
        throw ('Refusing to write reports through a reparse point: {0}' -f $Directory)
    }

    $unique = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $basePath = Join-Path $directoryItem.FullName ('cleanup-' + $unique)
    $logPath = $basePath + '.log'
    $encoding = New-Object Text.UTF8Encoding($false)
    $stream = New-Object IO.FileStream($logPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $writer = New-Object IO.StreamWriter($stream, $encoding)
    $writer.AutoFlush = $true

    return [pscustomobject]@{
        BasePath = $basePath
        LogPath  = $logPath
        Writer   = $writer
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($null -eq $script:LogWriter) {
        throw 'The cleanup log is not available; refusing to continue.'
    }
    $script:LogWriter.WriteLine($line)
}

function New-CleanupResult {
    param(
        [string]$Name,
        [string]$Category,
        [string]$Status,
        [Int64]$CandidateBytes = 0,
        [Int64]$ReclaimedBytes = 0,
        [int]$ItemsRemoved = 0,
        [int]$RetainedItems = 0,
        [int]$FailedItems = 0,
        [int]$ReparsePointsSkipped = 0,
        [string]$Path = '',
        [string]$Notes = '',
        [long]$DurationMs = 0
    )

    return [pscustomobject]@{
        Name                 = $Name
        Category             = $Category
        Status               = $Status
        CandidateBytes       = $CandidateBytes
        ReclaimedBytes       = $ReclaimedBytes
        ItemsRemoved         = $ItemsRemoved
        RetainedItems        = $RetainedItems
        FailedItems          = $FailedItems
        ReparsePointsSkipped = $ReparsePointsSkipped
        Path                 = $Path
        Notes                = $Notes
        DurationMs           = $DurationMs
    }
}

function Acquire-CleanupMutex {
    if ($script:PreviewMode) { return $true }
    # Never fall back to a different namespace if access is denied.
    $script:Mutex = New-Object Threading.Mutex($false, 'Global\WindowsCacheCleaner-C')
    try { $script:MutexAcquired = $script:Mutex.WaitOne(0, $false) }
    catch [Threading.AbandonedMutexException] { $script:MutexAcquired = $true }
    return $script:MutexAcquired
}

function Stop-RequiredServices {
    param([string[]]$Names)
    $states = New-Object System.Collections.Generic.List[object]
    $allStopped = $true
    foreach ($name in @($Names | Select-Object -Unique)) {
        try {
            $service = Get-Service -Name $name -ErrorAction Stop
            if ($service.Status -notin @('Running','Stopped')) {
                throw ('Service is in a transitional/paused state: {0}' -f $service.Status)
            }
            if (@($service.DependentServices | Where-Object Status -ne 'Stopped').Count -gt 0) {
                throw 'A dependent service is active; it will not be stopped.'
            }
            $state = [pscustomobject]@{ Name=$name; WasRunning=($service.Status -eq 'Running') }
            $states.Add($state)
            # Record before the first mutation, even if a later log write throws.
            $script:ActiveServiceStates.Add($state)
            if ($state.WasRunning) {
                Stop-Service -Name $name -Confirm:$false -ErrorAction Stop
                $service.WaitForStatus('Stopped', (New-TimeSpan -Seconds 20))
                $service.Refresh()
                if ($service.Status -ne 'Stopped') { throw 'Service did not stop.' }
                Write-Log ('Stopped required service: {0}' -f $name)
            }
        }
        catch {
            $allStopped = $false
            Write-Log -Level 'WARN' -Message ('Could not stop {0}: {1}' -f $name, $_.Exception.Message)
            break
        }
    }
    return [pscustomobject]@{ AllStopped=$allStopped; States=$states.ToArray() }
}

function Restore-ServiceStates {
    param([object[]]$States)
    $restored = $true
    foreach ($state in @($States)) {
        if (-not $state.WasRunning) { continue }
        try {
            $service = Get-Service -Name $state.Name -ErrorAction Stop
            $service.Refresh()
            if ($service.Status -eq 'StopPending') {
                $service.WaitForStatus('Stopped', (New-TimeSpan -Seconds 20))
                $service.Refresh()
            }
            if ($service.Status -ne 'Running') {
                Start-Service -Name $state.Name -Confirm:$false -ErrorAction Stop
                $service.WaitForStatus('Running', (New-TimeSpan -Seconds 20))
            }
            $service.Refresh()
            if ($service.Status -ne 'Running') { throw 'Service failed to return to Running.' }
        }
        catch {
            $restored = $false
            # Restoration must continue even if disk/log writes have failed.
            [Console]::Error.WriteLine(('Restore service {0} manually: {1}' -f $state.Name, $_.Exception.Message))
        }
    }
    return $restored
}

function Remove-SafeFileSystemItem {
    param(
        [Parameter(Mandatory=$true)][System.IO.FileSystemInfo]$Item,
        [Parameter(Mandatory=$true)][pscustomobject]$Target,
        [datetime]$CutoffUtc = [DateTime]::UtcNow
    )
    $outcome = [pscustomobject]@{ Removed=0; Failed=0; ReparseSkipped=0; BytesRemoved=[Int64]0; Retained=0 }
    if ($script:PreviewMode) { return $outcome }
    $safety = Test-CacheTargetSafety -Target $Target
    if (-not $safety.IsSafe -or -not (Test-PathWithinRoot -Path $Item.FullName -Root $safety.NormalizedPath)) {
        $outcome.Failed++; return $outcome
    }
    try {
        if (Test-ReparsePoint -Item $Item) { $outcome.ReparseSkipped++; return $outcome }
        if ($Target.Mode -eq 'FilePattern' -and ($Item.PSIsContainer -or
            $Item.Name -notlike $Target.Filter -or
            (ConvertTo-NormalizedFileSystemPath (Split-Path -Parent $Item.FullName)) -ne $safety.NormalizedPath)) {
            $outcome.Retained++; return $outcome
        }
        if ($Item.PSIsContainer -and -not (Test-CacheFileAge -Item $Item -CutoffUtc $CutoffUtc -MinimumAgeDays $Target.MinimumAgeDays)) {
            $outcome.Retained++; return $outcome
        }
        $cutoff = if ($Target.MinimumAgeDays -gt 0) { $CutoffUtc.ToUniversalTime().ToFileTimeUtc() } else { [long]0 }
        $result = [CDriveCleanup.NativeDelete]::Delete($Item.FullName, $safety.NormalizedPath, $cutoff)
        if ($result.Removed) { $outcome.Removed++; $outcome.BytesRemoved=$result.Bytes }
        elseif ($result.Reason -eq 'ReparsePoint') { $outcome.ReparseSkipped++ }
        else { $outcome.Retained++ }
    }
    catch { $outcome.Failed++ }
    return $outcome
}

function Get-TargetBusyReason {
    param([pscustomobject]$Target)
    if ($Target.PSObject.Properties['UserProfileSid'] -and $Target.UserProfileSid) {
        try {
            $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID='{0}'" -f $Target.UserProfileSid) -ErrorAction Stop)
            if ($profiles.Count -ne 1 -or $profiles[0].Loaded -or $profiles[0].Special) {
                return 'The other user profile is loaded, special, or could not be identified.'
            }
        }
        catch { return 'Unable to recheck the other user profile; its TEMP will be retained.' }
    }
    if ($Target.PSObject.Properties['ProcessNames'] -and $Target.ProcessNames.Count -gt 0) {
        $active = @(Get-Process -Name $Target.ProcessNames -ErrorAction SilentlyContinue)
        if ($active.Count -gt 0) { return 'Related application/build process is running. Close it and run again.' }
    }
    return ''
}

function Get-ServicingBlockReason {
    if ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows')) -ne 'C:\') {
        return 'Windows is not on C:; online system maintenance is outside this cleanup scope.'
    }
    try {
        foreach ($key in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
            if (Test-Path -LiteralPath $key -ErrorAction Stop) { return 'Windows has a pending reboot. Restart and finish updates first.' }
        }
        if (@(Get-Process -Name @('TiWorker','TrustedInstaller','MoUsoCoreWorker','dism','setuphost','msiexec') -ErrorAction SilentlyContinue).Count -gt 0) {
            return 'Windows servicing/update/installer process is active.'
        }
    }
    catch { return 'Unable to verify Windows servicing state.' }
    return ''
}

function Get-CurrentSessionBrowserProcesses {
    $sessionId = (Get-Process -Id $PID).SessionId
    return @(Get-Process -Name @('chrome', 'msedge', 'firefox') -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId } | Sort-Object Id -Unique)
}

function Handle-BrowserProcesses {
    param([bool]$BrowserTargetsExist)

    if (-not $BrowserTargetsExist) {
        return
    }
    $processes = @(Get-CurrentSessionBrowserProcesses)
    if ($processes.Count -eq 0) {
        return
    }
    if (-not $StopBrowserProcesses) {
        Write-Log -Level 'WARN' -Message ('Current-session browser processes are running ({0}); locked cache files will be retained.' -f (($processes.ProcessName | Select-Object -Unique) -join ', '))
        return
    }
    if ($script:PreviewMode) {
        Write-Log ('Preview: would request {0} current-session browser process(es) to close.' -f $processes.Count)
        if ($ForceCloseBrowserProcesses) {
            Write-Log 'Preview: processes still running after the graceful request would be force-closed.'
        }
        return
    }
    if ($script:IsAdmin) {
        Write-Log -Level 'WARN' -Message 'Browser closure requires the non-elevated User stage; no process was closed.'
        return
    }
    if (-not $script:PSCmdlet.ShouldProcess(($processes.Id -join ', '), 'Close current-session browser processes')) {
        Write-Log -Level 'WARN' -Message 'Browser process closure was declined; locked cache files will be retained.'
        return
    }

    foreach ($process in $processes) {
        try {
            if (-not $process.HasExited -and $process.MainWindowHandle -ne 0) {
                [void]$process.CloseMainWindow()
                [void]$process.WaitForExit(5000)
            }
            if (-not $process.HasExited -and $ForceCloseBrowserProcesses) {
                Stop-Process -Id $process.Id -Force -Confirm:$false -ErrorAction Stop
            }
        }
        catch {
            Write-Log -Level 'WARN' -Message ('Could not close browser PID {0}: {1}' -f $process.Id, $_.Exception.Message)
        }
    }

    $remaining = @($processes | Where-Object {
        try { -not (Get-Process -Id $_.Id -ErrorAction Stop).HasExited } catch { $false }
    })
    if ($remaining.Count -gt 0) {
        Write-Log -Level 'WARN' -Message ('{0} browser process(es) remain; their locked files will be retained.' -f $remaining.Count)
    }
}

function Invoke-TargetCleanup {
    param([Parameter(Mandatory=$true)][pscustomobject]$Target)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $base = @{ Name=$Target.Name; Category=$Target.Category; Path=$Target.Path; Notes=$Target.Notes }
    if ($Target.RequiresAdmin -and -not $script:IsAdmin) {
        return New-CleanupResult @base -Status 'SkippedAdmin'
    }
    if (-not $Target.RequiresAdmin -and $script:IsAdmin -and -not $script:PreviewMode) {
        $base.Notes = 'Run the User stage without elevation.'
        return New-CleanupResult @base -Status 'SkippedElevation'
    }
    $busy = Get-TargetBusyReason -Target $Target
    if ($Target.ServicesToStop.Count -gt 0 -and -not $busy) {
        $busy = Get-ServicingBlockReason
    }
    $inventory = Get-CacheTargetInventory -Target $Target -CutoffUtc ($script:RunCutoffUtc.AddDays(-$Target.MinimumAgeDays))
    if (-not $inventory.SafeToClean) {
        $base.Notes=$inventory.SafetyReason
        $status = if ($inventory.AccessErrors -gt 0) { 'ScanFailed' } else { 'UnsafePath' }
        return New-CleanupResult @base -Status $status -FailedItems $inventory.AccessErrors -ReparsePointsSkipped $inventory.ReparsePointsSkipped
    }
    if (-not $inventory.MeasurementComplete -and $inventory.Files.Count -eq 0) {
        return New-CleanupResult @base -Status 'ScanFailed' -FailedItems $inventory.AccessErrors
    }
    if (-not $inventory.Exists) { return New-CleanupResult @base -Status 'NotFound' }
    if ($busy) {
        $base.Notes=$busy
        return New-CleanupResult @base -Status 'SkippedBusy' -CandidateBytes $inventory.SizeBytes
    }
    if ($inventory.Files.Count -eq 0 -and $inventory.Directories.Count -eq 0) {
        $status = if ($inventory.ReparsePointsSkipped -gt 0) { if ($script:PreviewMode) { 'PreviewPartial' } else { 'Partial' } } else { 'Empty' }
        return New-CleanupResult @base -Status $status -ReparsePointsSkipped $inventory.ReparsePointsSkipped
    }
    Write-Log ('{0}: {1} candidate bytes in {2} files.' -f $Target.Name, (Format-Bytes $inventory.SizeBytes), $inventory.Files.Count)
    if ($script:PreviewMode) {
        $status = if ($inventory.MeasurementComplete -and $inventory.ReparsePointsSkipped -eq 0) { 'Preview' } else { 'PreviewPartial' }
        return New-CleanupResult @base -Status $status -CandidateBytes $inventory.SizeBytes -ReparsePointsSkipped $inventory.ReparsePointsSkipped
    }
    if (-not $script:PSCmdlet.ShouldProcess($Target.Path, 'Delete eligible cache files and empty directories')) {
        return New-CleanupResult @base -Status 'Declined' -CandidateBytes $inventory.SizeBytes
    }
    $removed=0; $retained=0; $failed=$inventory.AccessErrors; $reparse=$inventory.ReparsePointsSkipped; $bytes=[Int64]0
    $transaction=[pscustomobject]@{AllStopped=$true;States=@()}
    $restored=$true
    try {
        $busy = Get-TargetBusyReason -Target $Target
        if (-not $busy -and $Target.ServicesToStop.Count -gt 0) { $busy=Get-ServicingBlockReason }
        if ($busy) {
            $base.Notes=$busy
            return New-CleanupResult @base -Status 'SkippedBusy' -CandidateBytes $inventory.SizeBytes
        }
        if ($Target.ServicesToStop.Count -gt 0) { $transaction=Stop-RequiredServices $Target.ServicesToStop }
        if ($transaction.AllStopped) {
            foreach ($file in $inventory.Files) {
                $outcome=Remove-SafeFileSystemItem -Item $file -Target $Target -CutoffUtc $inventory.CutoffUtc
                $removed+=$outcome.Removed; $retained+=$outcome.Retained; $failed+=$outcome.Failed; $reparse+=$outcome.ReparseSkipped; $bytes+=$outcome.BytesRemoved
            }
            foreach ($directory in @($inventory.Directories | Sort-Object { $_.FullName.Length } -Descending)) {
                $outcome=Remove-SafeFileSystemItem -Item $directory -Target $Target -CutoffUtc $inventory.CutoffUtc
                $removed+=$outcome.Removed; $retained+=$outcome.Retained; $failed+=$outcome.Failed; $reparse+=$outcome.ReparseSkipped
            }
        }
    }
    finally {
        $restored=Restore-ServiceStates -States $script:ActiveServiceStates.ToArray()
        if ($restored) { $script:ActiveServiceStates.Clear() }
    }
    $status=if (-not $restored) {'ServiceRestoreFailed'}
        elseif (-not $transaction.AllStopped) {'ServiceStopFailed'}
        elseif ($failed -gt 0 -and $removed -eq 0) {'Failed'}
        elseif ($failed -gt 0 -or $reparse -gt 0) {'Partial'}
        elseif ($removed -eq 0) {'Retained'}
        elseif ($retained -gt 0) {'CleanedWithRetained'}
        else {'Cleaned'}
    Write-Log ('{0}: {1}; deleted logical bytes={2}; failed={3}; links skipped={4}; retained={5}.' -f $Target.Name,$status,(Format-Bytes $bytes),$failed,$reparse,$retained)
    return New-CleanupResult @base -Status $status -CandidateBytes $inventory.SizeBytes -ReclaimedBytes $bytes -ItemsRemoved $removed -RetainedItems $retained -FailedItems $failed -ReparsePointsSkipped $reparse -DurationMs $timer.ElapsedMilliseconds
}

function Invoke-DeliveryOptimizationCleanup {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $path = 'DeliveryOptimization API'
    if ($Scope -eq 'User') { return $null }
    if ($null -eq (Get-Command -Name Get-DeliveryOptimizationPerfSnap -ErrorAction SilentlyContinue) -or
        $null -eq (Get-Command -Name Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'Unavailable' -Path $path -Notes 'The supported DeliveryOptimization cmdlets are unavailable.' -DurationMs $timer.ElapsedMilliseconds)
    }

    try {
        if ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows')) -ne 'C:\') {
            return New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'SkippedScope' -Path $path -Notes 'Windows is not on C:.'
        }
        foreach ($key in @(
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization',
            'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeliveryOptimization',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config')) {
            if (Test-Path -LiteralPath $key -ErrorAction Stop) {
                $config = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                if ($config.PSObject.Properties['DOModifyCacheDrive'] -and $config.DOModifyCacheDrive) {
                    return New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'SkippedScope' -Path $path -Notes 'A custom DO cache drive is configured; use Windows Storage settings to review it.'
                }
            }
        }
        $before = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop
        $candidate = [Int64]$before.CacheSizeBytes
        $pending = [int]$before.ForegroundDownloadsPending + [int]$before.BackgroundDownloadsPending + [int]$before.ForegroundDownloadCount + [int]$before.BackgroundDownloadCount
        if ($candidate -le 0) {
            $timer.Stop()
            return (New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'Empty' -Path $path -DurationMs $timer.ElapsedMilliseconds)
        }
        if ($pending -gt 0) {
            Write-Log -Level 'WARN' -Message ('Skipping Delivery Optimization cache: {0} download(s) are pending.' -f $pending)
            $timer.Stop()
            return (New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'SkippedBusy' -CandidateBytes $candidate -Path $path -Notes 'Active Delivery Optimization downloads were detected.' -DurationMs $timer.ElapsedMilliseconds)
        }
        if ($script:PreviewMode) {
            $timer.Stop()
            $notes = if ($script:IsAdmin) { 'Pinned content is retained unless explicitly included.' } else { 'Administrator rights will be required to execute; pinned content is retained by default.' }
            return (New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'Preview' -CandidateBytes $candidate -Path $path -Notes $notes -DurationMs $timer.ElapsedMilliseconds)
        }
        if (-not $script:IsAdmin) {
            $timer.Stop()
            return (New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'SkippedAdmin' -CandidateBytes $candidate -Path $path -Notes 'Administrator rights are required.' -DurationMs $timer.ElapsedMilliseconds)
        }
        if (-not $script:PSCmdlet.ShouldProcess($path, 'Delete Delivery Optimization cache through the supported Windows API')) {
            $timer.Stop()
            return (New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'Declined' -CandidateBytes $candidate -Path $path -DurationMs $timer.ElapsedMilliseconds)
        }

        $blockReason = Get-ServicingBlockReason
        if ($blockReason) {
            return New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'SkippedBusy' -Path $path -CandidateBytes $candidate -Notes $blockReason
        }
        # Recheck active transfers immediately before the API mutation.
        $current = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop
        if (($current.ForegroundDownloadsPending + $current.BackgroundDownloadsPending + $current.ForegroundDownloadCount + $current.BackgroundDownloadCount) -gt 0) {
            return New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'SkippedBusy' -Path $path -CandidateBytes $candidate
        }
        Delete-DeliveryOptimizationCache -Force -IncludePinnedFiles:$IncludePinnedDeliveryFiles -ErrorAction Stop | Out-Null
        $after = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop
        $reclaimed = [Math]::Max([Int64]0, ($candidate - [Int64]$after.CacheSizeBytes))
        $timer.Stop()
        Write-Log ('Delivery Optimization cleanup completed through the Windows API; estimated logical reduction: {0}.' -f (Format-Bytes -Bytes $reclaimed))
        return (New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'Cleaned' -CandidateBytes $candidate -ReclaimedBytes $reclaimed -Path $path -Notes 'Measured through the supported Windows API.' -DurationMs $timer.ElapsedMilliseconds)
    }
    catch {
        $timer.Stop()
        Write-Log -Level 'ERROR' -Message ('Delivery Optimization cleanup failed: {0}' -f $_.Exception.Message)
        return (New-CleanupResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'Failed' -Path $path -Notes $_.Exception.Message -DurationMs $timer.ElapsedMilliseconds)
    }
}

function Get-RecycleBinMeasurement {
    $systemDrive = Get-SystemDriveRoot
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $recycleRoot = Join-Path $systemDrive '$Recycle.Bin'
    $target = New-CacheTarget -Name 'Recycle Bin (system drive)' -Path (Join-Path $recycleRoot $sid) -AllowedRoot $recycleRoot -Category 'UserData' -Notes 'Recoverable personal data.'
    return Measure-CacheTarget -Target $target
}

function Invoke-RecycleBinCleanup {
    if ($Scope -eq 'System' -or $SkipRecycleBin -or -not $IncludeRecycleBin) {
        return $null
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $before = Get-RecycleBinMeasurement
    if (-not $before.SafeToClean -or -not $before.MeasurementComplete) {
        return New-CleanupResult -Name 'Recycle Bin (C:)' -Category 'UserData' -Status 'ScanFailed' -Notes $before.SafetyReason
    }
    $candidate = if ($before.Exists) { [Int64]$before.SizeBytes } else { [Int64]0 }
    $systemDrive = Get-SystemDriveRoot
    $driveLetter = $systemDrive.Substring(0, 1)
    if ($null -eq (Get-Command -Name Clear-RecycleBin -ErrorAction SilentlyContinue)) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Recycle Bin (system drive)' -Category 'UserData' -Status 'Unavailable' -CandidateBytes $candidate -Path ('{0} Recycle Bin' -f $systemDrive) -Notes 'Clear-RecycleBin is unavailable.' -DurationMs $timer.ElapsedMilliseconds)
    }
    if ($script:PreviewMode) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Recycle Bin (system drive)' -Category 'UserData' -Status 'Preview' -CandidateBytes $candidate -Path ('{0} Recycle Bin' -f $systemDrive) -Notes 'Explicitly selected recoverable personal files.' -DurationMs $timer.ElapsedMilliseconds)
    }
    if (-not $script:PSCmdlet.ShouldProcess(('{0} Recycle Bin' -f $systemDrive), 'Permanently clear current-user deleted files')) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Recycle Bin (system drive)' -Category 'UserData' -Status 'Declined' -CandidateBytes $candidate -Path ('{0} Recycle Bin' -f $systemDrive) -DurationMs $timer.ElapsedMilliseconds)
    }

    try {
        Clear-RecycleBin -DriveLetter $driveLetter -Force -Confirm:$false -ErrorAction Stop
        $after = Get-RecycleBinMeasurement
        if (-not $after.SafeToClean -or -not $after.MeasurementComplete) {
            return New-CleanupResult -Name 'Recycle Bin (C:)' -Category 'UserData' -Status 'ScanFailed' -CandidateBytes $candidate -Notes 'The clear request completed, but post-cleanup measurement failed; reclaimed bytes are unknown.'
        }
        $reclaimed = if ($after.Exists) { [Math]::Max([Int64]0, ($candidate - [Int64]$after.SizeBytes)) } else { $candidate }
        $timer.Stop()
        Write-Log ('Cleared only the current user Recycle Bin on {0}; estimated logical reduction: {1}.' -f $systemDrive, (Format-Bytes -Bytes $reclaimed))
        return (New-CleanupResult -Name 'Recycle Bin (system drive)' -Category 'UserData' -Status 'Cleaned' -CandidateBytes $candidate -ReclaimedBytes $reclaimed -Path ('{0} Recycle Bin' -f $systemDrive) -DurationMs $timer.ElapsedMilliseconds)
    }
    catch {
        $timer.Stop()
        Write-Log -Level 'ERROR' -Message ('Could not clear the {0} Recycle Bin: {1}' -f $systemDrive, $_.Exception.Message)
        return (New-CleanupResult -Name 'Recycle Bin (system drive)' -Category 'UserData' -Status 'Failed' -CandidateBytes $candidate -Path ('{0} Recycle Bin' -f $systemDrive) -Notes $_.Exception.Message -DurationMs $timer.ElapsedMilliseconds)
    }
}

function Invoke-DismCleanup {
    if ($Scope -eq 'User') { return $null }
    $shouldRun = $RunDismComponentCleanup -or $ResetComponentBase -or $CleanupLevel -ne 'Safe'
    if (-not $shouldRun) {
        return $null
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $name = if ($ResetComponentBase) { 'DISM Component Cleanup with ResetBase' } else { 'DISM Component Cleanup' }
    if ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows')) -ne 'C:\') {
        return New-CleanupResult -Name $name -Category 'System' -Status 'SkippedScope' -Notes 'Windows is not on C:.'
    }
    $arguments = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    if ($ResetComponentBase) {
        $arguments += '/ResetBase'
    }
    $displayPath = 'DISM ' + ($arguments -join ' ')
    if (-not $script:IsAdmin) {
        $timer.Stop()
        return (New-CleanupResult -Name $name -Category 'System' -Status 'SkippedAdmin' -Path $displayPath -Notes 'Administrator rights are required.' -DurationMs $timer.ElapsedMilliseconds)
    }

    $dismPath = Join-Path ([Environment]::SystemDirectory) 'Dism.exe'
    if (-not (Test-Path -LiteralPath $dismPath -PathType Leaf)) {
        $timer.Stop()
        return (New-CleanupResult -Name $name -Category 'System' -Status 'Unavailable' -Path $dismPath -Notes 'DISM was not found.' -DurationMs $timer.ElapsedMilliseconds)
    }
    if ($script:PreviewMode) {
        $timer.Stop()
        $notes = if ($ResetComponentBase) { 'Irreversible: existing update packages cannot be uninstalled afterward.' } else { 'Removes superseded component versions through DISM.' }
        return (New-CleanupResult -Name $name -Category 'System' -Status 'Preview' -Path $displayPath -Notes $notes -DurationMs $timer.ElapsedMilliseconds)
    }
    $blockReason = Get-ServicingBlockReason
    if ($blockReason) {
        return New-CleanupResult -Name $name -Category 'System' -Status 'SkippedBusy' -Path $displayPath -Notes $blockReason
    }
    if (-not $script:PSCmdlet.ShouldProcess('Windows Component Store', $displayPath)) {
        $timer.Stop()
        return (New-CleanupResult -Name $name -Category 'System' -Status 'Declined' -Path $displayPath -DurationMs $timer.ElapsedMilliseconds)
    }

    $freeBefore = Get-SystemDriveFreeBytes
    try {
        Write-Log ('Running: {0}' -f $displayPath)
        & $dismPath $arguments | ForEach-Object { Write-Host $_ }
        $nativeExitCode = $LASTEXITCODE
        $freeAfter = Get-SystemDriveFreeBytes
        $reclaimed = if ($null -ne $freeBefore -and $null -ne $freeAfter) { [Math]::Max([Int64]0, ([Int64]$freeAfter - [Int64]$freeBefore)) } else { [Int64]0 }
        $timer.Stop()
        if ($nativeExitCode -in @(0,3010)) {
            $status = if ($nativeExitCode -eq 3010) { 'RebootRequired' } else { 'Cleaned' }
            return (New-CleanupResult -Name $name -Category 'System' -Status $status -ReclaimedBytes $reclaimed -Path $displayPath -Notes ('DISM exit code {0}; bytes use observed C: free-space delta.' -f $nativeExitCode) -DurationMs $timer.ElapsedMilliseconds)
        }
        Write-Log -Level 'ERROR' -Message ('DISM exited with code {0}.' -f $nativeExitCode)
        return (New-CleanupResult -Name $name -Category 'System' -Status 'Failed' -ReclaimedBytes $reclaimed -Path $displayPath -Notes ('DISM exit code {0}' -f $nativeExitCode) -DurationMs $timer.ElapsedMilliseconds)
    }
    catch {
        $timer.Stop()
        Write-Log -Level 'ERROR' -Message ('DISM component cleanup failed: {0}' -f $_.Exception.Message)
        return (New-CleanupResult -Name $name -Category 'System' -Status 'Failed' -Path $displayPath -Notes $_.Exception.Message -DurationMs $timer.ElapsedMilliseconds)
    }
}

function Invoke-HibernationChange {
    if ($Scope -eq 'User' -or $HibernationMode -eq 'Keep') {
        return $null
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    if ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows')) -ne 'C:\') {
        return New-CleanupResult -Name 'Hibernation configuration' -Category 'FeatureChange' -Status 'SkippedScope'
    }
    $powerCfg = Join-Path ([Environment]::SystemDirectory) 'powercfg.exe'
    $arguments = if ($HibernationMode -eq 'Reduced') { @('/hibernate', '/type', 'reduced') } else { @('/hibernate', 'off') }
    $displayPath = 'powercfg ' + ($arguments -join ' ')
    if (-not $script:IsAdmin) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Hibernation configuration' -Category 'FeatureChange' -Status 'SkippedAdmin' -Path $displayPath -Notes 'Administrator rights are required.' -DurationMs $timer.ElapsedMilliseconds)
    }
    if (-not (Test-Path -LiteralPath $powerCfg -PathType Leaf)) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Hibernation configuration' -Category 'FeatureChange' -Status 'Unavailable' -Path $powerCfg -DurationMs $timer.ElapsedMilliseconds)
    }
    if ($script:PreviewMode) {
        $notes = if ($HibernationMode -eq 'Reduced') { 'Keeps Fast Startup but disables full hibernation.' } else { 'Disables hibernation and Fast Startup.' }
        $timer.Stop()
        return (New-CleanupResult -Name 'Hibernation configuration' -Category 'FeatureChange' -Status 'Preview' -Path $displayPath -Notes $notes -DurationMs $timer.ElapsedMilliseconds)
    }
    if (-not $script:PSCmdlet.ShouldProcess('Windows hibernation feature', $displayPath)) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Hibernation configuration' -Category 'FeatureChange' -Status 'Declined' -Path $displayPath -DurationMs $timer.ElapsedMilliseconds)
    }

    $freeBefore = Get-SystemDriveFreeBytes
    try {
        $output = @(& $powerCfg $arguments 2>&1)
        $nativeExitCode = $LASTEXITCODE
        foreach ($line in $output) {
            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                Write-Log ('powercfg: {0}' -f ([string]$line).Trim())
            }
        }
        $freeAfter = Get-SystemDriveFreeBytes
        $reclaimed = if ($null -ne $freeBefore -and $null -ne $freeAfter) { [Math]::Max([Int64]0, ([Int64]$freeAfter - [Int64]$freeBefore)) } else { [Int64]0 }
        $timer.Stop()
        if ($nativeExitCode -eq 0) {
            return (New-CleanupResult -Name 'Hibernation configuration' -Category 'FeatureChange' -Status 'Changed' -ReclaimedBytes $reclaimed -Path $displayPath -Notes ('New mode: {0}' -f $HibernationMode) -DurationMs $timer.ElapsedMilliseconds)
        }
        return (New-CleanupResult -Name 'Hibernation configuration' -Category 'FeatureChange' -Status 'Failed' -Path $displayPath -Notes ('powercfg exit code {0}' -f $nativeExitCode) -DurationMs $timer.ElapsedMilliseconds)
    }
    catch {
        $timer.Stop()
        return (New-CleanupResult -Name 'Hibernation configuration' -Category 'FeatureChange' -Status 'Failed' -Path $displayPath -Notes $_.Exception.Message -DurationMs $timer.ElapsedMilliseconds)
    }
}

function Invoke-PreviousWindowsCleanup {
    if ($Scope -eq 'User' -or -not $RemovePreviousWindowsInstallation) {
        return $null
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    if ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows')) -ne 'C:\') {
        return New-CleanupResult -Name 'Previous Windows installation cleanup' -Category 'RecoveryImpact' -Status 'SkippedScope' -Notes 'Windows is not on C:.'
    }
    $cleanMgr = Join-Path ([Environment]::SystemDirectory) 'cleanmgr.exe'
    $systemDrive = Get-SystemDriveRoot
    $driveLetter = $systemDrive.Substring(0, 1)
    $displayPath = 'cleanmgr /AUTOCLEAN /D ' + $driveLetter
    if (-not $script:IsAdmin) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Previous Windows installation cleanup' -Category 'RecoveryImpact' -Status 'SkippedAdmin' -Path $displayPath -Notes 'Administrator rights are required.' -DurationMs $timer.ElapsedMilliseconds)
    }
    if (-not (Test-Path -LiteralPath $cleanMgr -PathType Leaf)) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Previous Windows installation cleanup' -Category 'RecoveryImpact' -Status 'Unavailable' -Path $cleanMgr -DurationMs $timer.ElapsedMilliseconds)
    }
    if ($script:PreviewMode) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Previous Windows installation cleanup' -Category 'RecoveryImpact' -Status 'Preview' -Path $displayPath -Notes 'Irreversible: removes files used to return to the previous Windows version.' -DurationMs $timer.ElapsedMilliseconds)
    }
    $blockReason = Get-ServicingBlockReason
    if ($blockReason) {
        return New-CleanupResult -Name 'Previous Windows installation cleanup' -Category 'RecoveryImpact' -Status 'SkippedBusy' -Notes $blockReason
    }
    if (-not $script:PSCmdlet.ShouldProcess('Previous Windows installation files', $displayPath)) {
        $timer.Stop()
        return (New-CleanupResult -Name 'Previous Windows installation cleanup' -Category 'RecoveryImpact' -Status 'Declined' -Path $displayPath -DurationMs $timer.ElapsedMilliseconds)
    }

    $freeBefore = Get-SystemDriveFreeBytes
    try {
        $process = Start-Process -FilePath $cleanMgr -ArgumentList '/AUTOCLEAN','/D',$driveLetter -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        $nativeExitCode = $process.ExitCode
        $freeAfter = Get-SystemDriveFreeBytes
        $reclaimed = if ($null -ne $freeBefore -and $null -ne $freeAfter) { [Math]::Max([Int64]0, ([Int64]$freeAfter - [Int64]$freeBefore)) } else { [Int64]0 }
        $timer.Stop()
        if ($nativeExitCode -eq 0) {
            return (New-CleanupResult -Name 'Previous Windows installation cleanup' -Category 'RecoveryImpact' -Status 'Cleaned' -ReclaimedBytes $reclaimed -Path $displayPath -Notes 'Rollback to the prior Windows version may no longer be available.' -DurationMs $timer.ElapsedMilliseconds)
        }
        return (New-CleanupResult -Name 'Previous Windows installation cleanup' -Category 'RecoveryImpact' -Status 'Failed' -Path $displayPath -Notes ('cleanmgr exit code {0}' -f $nativeExitCode) -DurationMs $timer.ElapsedMilliseconds)
    }
    catch {
        $timer.Stop()
        return (New-CleanupResult -Name 'Previous Windows installation cleanup' -Category 'RecoveryImpact' -Status 'Failed' -Path $displayPath -Notes $_.Exception.Message -DurationMs $timer.ElapsedMilliseconds)
    }
}

try {
    $runReports = Initialize-RunReports -Directory $ReportDirectory
    $script:LogWriter = $runReports.Writer
}
catch {
    [Console]::Error.WriteLine(('Could not initialize cleanup reports. No cleanup was attempted. {0}' -f $_.Exception.Message))
    exit 10
}

$freeBytesBefore = Get-SystemDriveFreeBytes
$freeBytesAfter = $freeBytesBefore

try {
    $script:RunState = 'Running'
    Write-Log 'Windows system-drive cleanup started.'
    Write-Log ('Mode: {0}' -f ($(if ($script:PreviewMode) { 'Preview (no mutation commands will run)' } else { 'Execute' })))
    Write-Log ('Cleanup level: {0}' -f $CleanupLevel)
    Write-Log ('Scope: {0}' -f $Scope)
    Write-Log ('Administrator: {0}' -f $script:IsAdmin)
    Write-Log ('System drive: {0}' -f (Get-SystemDriveRoot))
    Write-Log ('Initial free space: {0}' -f ($(if ($null -eq $freeBytesBefore) { 'unavailable' } else { Format-Bytes -Bytes $freeBytesBefore })))
    Write-Log ('Recycle Bin explicitly included: {0}' -f ($IncludeRecycleBin.IsPresent -and -not $SkipRecycleBin.IsPresent))
    Write-Log ('Offline web/PWA caches included: {0}' -f $IncludeOfflineWebCaches.IsPresent)
    Write-Log ('Downloaded browser models included: {0}' -f ($IncludeDownloadedModels.IsPresent -or $CleanupLevel -eq 'Maximum'))
    Write-Log ('Hibernation mode request: {0}' -f $HibernationMode)

    if (-not (Acquire-CleanupMutex)) {
        throw 'Another cleanup is already executing on this system drive.'
    }
    if (-not $script:PreviewMode) { Initialize-CacheNativeCode }

    $targetParameters = @{
        CleanupLevel               = $CleanupLevel
        IncludeBrowsers            = $IncludeBrowsers
        IncludeWindowsUpdate       = $IncludeWindowsUpdate
        IncludeApplicationCaches   = $IncludeApplicationCaches
        IncludeDeveloperCaches     = $IncludeDeveloperCaches
        IncludeWindowsErrorReports = $IncludeWindowsErrorReports
        IncludeCrashDumps          = $IncludeCrashDumps
        IncludeAllUserTemp         = $IncludeAllUserTemp
        IncludeOfflineWebCaches    = $IncludeOfflineWebCaches
        IncludeDownloadedModels    = $IncludeDownloadedModels
        TempFileAgeDays            = $TempFileAgeDays
    }
    $targets = @(Get-CacheTargets @targetParameters | Where-Object {
        $Scope -eq 'All' -or ($Scope -eq 'System' -and $_.RequiresAdmin) -or ($Scope -eq 'User' -and -not $_.RequiresAdmin)
    })
    $browserTargetsExist = @($targets | Where-Object { $_.Category -in @('Browser', 'DownloadedModel') -and (Test-Path -LiteralPath $_.Path) }).Count -gt 0
    Handle-BrowserProcesses -BrowserTargetsExist $browserTargetsExist

    foreach ($target in @($targets | Sort-Object Category, Name)) {
        $targetResult = Invoke-TargetCleanup -Target $target
        $script:Results.Add($targetResult) | Out-Null
        if ($targetResult.Status -eq 'ServiceRestoreFailed') {
            throw 'A required service could not be restored. Further cleanup is stopped; inspect the report and service state.'
        }
    }

    $deliveryResult = Invoke-DeliveryOptimizationCleanup
    if ($null -ne $deliveryResult) { $script:Results.Add($deliveryResult) | Out-Null }

    $recycleResult = Invoke-RecycleBinCleanup
    if ($null -ne $recycleResult) {
        $script:Results.Add($recycleResult) | Out-Null
    }

    $dismResult = Invoke-DismCleanup
    if ($null -ne $dismResult) {
        $script:Results.Add($dismResult) | Out-Null
    }

    $previousWindowsResult = Invoke-PreviousWindowsCleanup
    if ($null -ne $previousWindowsResult) {
        $script:Results.Add($previousWindowsResult) | Out-Null
    }

    $hibernationResult = Invoke-HibernationChange
    if ($null -ne $hibernationResult) {
        $script:Results.Add($hibernationResult) | Out-Null
    }

    $freeBytesAfter = Get-SystemDriveFreeBytes
    $failureStatuses = @('UnsafePath', 'Failed', 'Partial', 'PreviewPartial', 'ServiceStopFailed', 'ServiceRestoreFailed', 'ScanFailed')
    $warningStatuses = @('SkippedAdmin', 'SkippedBusy', 'SkippedElevation', 'SkippedScope', 'Unavailable', 'Declined', 'RebootRequired', 'CleanedWithRetained', 'Retained')
    $failures = @($script:Results | Where-Object { $_.Status -in $failureStatuses })
    $warnings = @($script:Results | Where-Object { $_.Status -in $warningStatuses })
    if ($failures.Count -gt 0) {
        $script:RunState = 'CompletedWithErrors'
        $script:ExitCode = 2
    }
    elseif ($warnings.Count -gt 0) {
        $script:RunState = 'CompletedWithWarnings'
    }
    else {
        $script:RunState = 'Completed'
    }

    $candidateBytes = [Int64]0
    $logicalReclaimedBytes = [Int64]0
    foreach ($result in $script:Results) {
        $candidateBytes += [Int64]$result.CandidateBytes
        $logicalReclaimedBytes += [Int64]$result.ReclaimedBytes
    }
    $volumeDeltaBytes = if ($script:PreviewMode) { $null } elseif ($null -ne $freeBytesBefore -and $null -ne $freeBytesAfter) { [Int64]$freeBytesAfter - [Int64]$freeBytesBefore } else { $null }
    $resultsArray = $script:Results.ToArray()

    $visibleResults = @($resultsArray | Where-Object { $_.Status -notin @('NotFound', 'Empty') })
    $displayResults = @($visibleResults | Select-Object Name, Category, Status,
        @{ Name = 'Candidate'; Expression = { Format-Bytes -Bytes ([Int64]$_.CandidateBytes) } },
        @{ Name = 'Reclaimed'; Expression = { Format-Bytes -Bytes ([Int64]$_.ReclaimedBytes) } },
        ItemsRemoved, RetainedItems, FailedItems, ReparsePointsSkipped, DurationMs, Path, Notes)
    $table = $displayResults | Format-Table -Wrap -AutoSize | Out-String -Width 4096
    Write-Host $table
    $script:LogWriter.WriteLine($table)
    Write-Log ('Omitted {0} empty/not-found target(s) from the text table; JSON/CSV retain every target.' -f ($resultsArray.Count - $visibleResults.Count))

    $deltaText = if ($null -eq $volumeDeltaBytes) { 'unavailable' } else { Format-Bytes -Bytes $volumeDeltaBytes }
    Write-Log ('Run state: {0}' -f $script:RunState)
    Write-Log ('Candidate logical size: {0}' -f (Format-Bytes -Bytes $candidateBytes))
    Write-Log ('Per-action logical/volume estimates: {0}' -f (Format-Bytes -Bytes $logicalReclaimedBytes))
    Write-Log ('System-drive free-space delta: {0}' -f $deltaText)

    $summaryObject = [pscustomobject]@{
        SchemaVersion         = 3
        Timestamp             = (Get-Date).ToString('o')
        RunState              = $script:RunState
        ExitCode              = $script:ExitCode
        Preview               = $script:PreviewMode
        CleanupLevel          = $CleanupLevel
        Scope                 = $Scope
        Administrator         = $script:IsAdmin
        SystemDrive           = Get-SystemDriveRoot
        FreeBytesBefore       = $freeBytesBefore
        FreeBytesAfter        = $freeBytesAfter
        FreeSpaceDeltaBytes   = $volumeDeltaBytes
        CandidateBytes        = $candidateBytes
        EstimatedReclaimedBytes = $logicalReclaimedBytes
        Results               = $resultsArray
    }

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText(($runReports.BasePath + '.json'), ($summaryObject | ConvertTo-Json -Depth 6), $utf8NoBom)
    $resultsArray | Export-Csv -LiteralPath ($runReports.BasePath + '.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Log ('Cleanup log: {0}' -f $runReports.LogPath)
    Write-Log ('JSON report: {0}' -f ($runReports.BasePath + '.json'))
    Write-Log ('CSV report: {0}' -f ($runReports.BasePath + '.csv'))
}
catch {
    $abortMessage = $_.Exception.Message
    $script:RunState = 'Aborted'
    $script:ExitCode = 1
    try {
        Write-Log -Level 'ERROR' -Message ('Cleanup aborted: {0}' -f $_.Exception.Message)
    }
    catch {
        [Console]::Error.WriteLine(('Cleanup aborted and the log could not be updated: {0}' -f $_.Exception.Message))
    }
}
finally {
    if ($script:ActiveServiceStates.Count -gt 0) {
        if (-not (Restore-ServiceStates -States $script:ActiveServiceStates.ToArray())) {
            $script:ExitCode = 2
        }
    }
    if ($script:RunState -eq 'Aborted') {
        try {
            $aborted = [pscustomobject]@{
                SchemaVersion=3; Timestamp=(Get-Date).ToString('o'); RunState='Aborted'; ExitCode=$script:ExitCode
                Preview=$script:PreviewMode; CleanupLevel=$CleanupLevel; Scope=$Scope; Error=$abortMessage
                Results=$script:Results.ToArray()
            }
            [IO.File]::WriteAllText(($runReports.BasePath + '.json'), ($aborted | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
        } catch { [Console]::Error.WriteLine('Could not save the aborted-run report.') }
    }
    if ($script:MutexAcquired -and $null -ne $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $script:Mutex) {
        $script:Mutex.Dispose()
    }
    if ($null -ne $script:LogWriter) {
        $script:LogWriter.Dispose()
    }
}

exit $script:ExitCode

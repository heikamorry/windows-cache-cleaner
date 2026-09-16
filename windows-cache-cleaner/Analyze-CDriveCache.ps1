#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Safe', 'Deep', 'Maximum')]
    [string]$CleanupLevel = 'Maximum',

    [ValidateSet('All', 'User', 'System')]
    [string]$Scope = 'All',

    [switch]$IncludeBrowsers,
    [switch]$IncludeWindowsUpdate,
    [switch]$IncludeApplicationCaches,
    [switch]$IncludeDeveloperCaches,
    [switch]$IncludeWindowsErrorReports,
    [switch]$IncludeCrashDumps,
    [switch]$IncludeAllUserTemp,
    [switch]$IncludeOfflineWebCaches,
    [switch]$IncludeDownloadedModels,
    [switch]$IncludeRecycleBin,
    [switch]$AnalyzeComponentStore,

    [ValidateRange(-1, 3650)]
    [int]$TempFileAgeDays = -1,

    [string]$ReportDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'CacheCleanup.Common.ps1')

if ([string]::IsNullOrWhiteSpace($ReportDirectory)) {
    $ReportDirectory = Join-Path $scriptRoot 'reports'
}

function Initialize-ReportBase {
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
        New-Item -Path $Directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $directoryItem = Get-Item -LiteralPath $Directory -Force -ErrorAction Stop
    if (Test-ReparsePoint -Item $directoryItem) {
        throw ('Refusing to write reports through a reparse point: {0}' -f $Directory)
    }

    $unique = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    return Join-Path $directoryItem.FullName ('analysis-' + $unique)
}

function New-AnalysisResult {
    param(
        [string]$Name,
        [string]$Category,
        [string]$Status,
        [Int64]$SizeBytes,
        [string]$Path,
        [string]$Notes,
        [int]$ItemCount = 0,
        [int]$FileCount = 0,
        [int]$AccessErrors = 0,
        [int]$ReparsePointsSkipped = 0,
        [bool]$CountInPotential = $true
    )

    return [pscustomobject]@{
        Name             = $Name
        Category         = $Category
        Status           = $Status
        SizeBytes        = $SizeBytes
        Size             = if ($SizeBytes -ge 0) { Format-Bytes -Bytes $SizeBytes } else { 'n/a' }
        ItemCount        = $ItemCount
        FileCount        = $FileCount
        AccessErrors     = $AccessErrors
        ReparsePointsSkipped = $ReparsePointsSkipped
        CountInPotential = $CountInPotential
        Path             = $Path
        Notes            = $Notes
    }
}

function Get-DeliveryOptimizationAnalysis {
    if ($Scope -eq 'User') { return $null }
    $command = Get-Command -Name Get-DeliveryOptimizationPerfSnap -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return New-AnalysisResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'Unavailable' -SizeBytes 0 -Path 'DeliveryOptimization API' -Notes 'The Windows DeliveryOptimization PowerShell module is unavailable.' -CountInPotential $false
    }

    try {
        if ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows')) -ne 'C:\') {
            return New-AnalysisResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'SkippedScope' -SizeBytes 0 -Path 'DeliveryOptimization API' -Notes 'Windows is not on C:.' -CountInPotential $false
        }
        foreach ($key in @(
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization',
            'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeliveryOptimization',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config')) {
            if (Test-Path -LiteralPath $key -ErrorAction Stop) {
                $config = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                if ($config.PSObject.Properties['DOModifyCacheDrive'] -and $config.DOModifyCacheDrive) {
                    return New-AnalysisResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'SkippedScope' -SizeBytes 0 -Path 'DeliveryOptimization API' -Notes 'A custom DO cache drive is configured; review it in Windows Storage settings.' -CountInPotential $false
                }
            }
        }
        $snapshot = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop
        $size = [Int64]$snapshot.CacheSizeBytes
        $pending = [int]$snapshot.ForegroundDownloadsPending + [int]$snapshot.BackgroundDownloadsPending + [int]$snapshot.ForegroundDownloadCount + [int]$snapshot.BackgroundDownloadCount
        $status = if ($pending -gt 0) { 'Busy' } elseif ($size -gt 0) { 'Found' } else { 'Empty' }
        $notes = if ($pending -gt 0) {
            ('{0} download(s) pending; cleanup will be skipped while downloads are active.' -f $pending)
        }
        else {
            'Measured through the supported Delivery Optimization API; pinned content is retained by default.'
        }
        return New-AnalysisResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status $status -SizeBytes $size -Path 'DeliveryOptimization API' -Notes $notes -CountInPotential ($pending -eq 0)
    }
    catch {
        return New-AnalysisResult -Name 'Delivery Optimization Cache' -Category 'Safe' -Status 'ScanFailed' -SizeBytes 0 -Path 'DeliveryOptimization API' -Notes $_.Exception.Message -CountInPotential $false
    }
}

function Get-RecycleBinAnalysis {
    $systemDrive = Get-SystemDriveRoot
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $recycleRoot = Join-Path $systemDrive '$Recycle.Bin'
    $target = New-CacheTarget -Name 'Recycle Bin (system drive)' -Path (Join-Path $recycleRoot $sid) -AllowedRoot $recycleRoot -Category 'UserData' -Notes 'Recoverable personal files; never included unless explicitly requested.'
    $measurement = Measure-CacheTarget -Target $target
    if (-not $measurement.SafeToClean) {
        return New-AnalysisResult -Name $target.Name -Category 'UserData' -Status 'UnsafePath' -SizeBytes 0 -Path $target.Path -Notes $measurement.SafetyReason -CountInPotential $false
    }
    if (-not $measurement.Exists) {
        return New-AnalysisResult -Name $target.Name -Category 'UserData' -Status 'NotFound' -SizeBytes 0 -Path $target.Path -Notes $target.Notes -CountInPotential $false
    }

    $status = if ($measurement.MeasurementComplete) { 'Review' } else { 'ReviewPartial' }
    return New-AnalysisResult -Name $target.Name -Category 'UserData' -Status $status -SizeBytes $measurement.SizeBytes -Path $target.Path -Notes $target.Notes -ItemCount $measurement.ItemCount -FileCount $measurement.FileCount -AccessErrors $measurement.AccessErrors -CountInPotential $false
}

function Get-ComponentStoreAnalysis {
    if ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows')) -ne 'C:\') {
        return New-AnalysisResult -Name 'Windows Component Store' -Category 'System' -Status 'SkippedScope' -SizeBytes 0 -Path 'DISM /AnalyzeComponentStore' -Notes 'Windows is not on C:.' -CountInPotential $false
    }
    if (-not (Test-RunningAsAdministrator)) {
        return New-AnalysisResult -Name 'Windows Component Store' -Category 'System' -Status 'AdminRequired' -SizeBytes 0 -Path 'DISM /AnalyzeComponentStore' -Notes 'Run the analysis as Administrator for the supported DISM assessment.' -CountInPotential $false
    }

    $dismPath = Join-Path ([Environment]::SystemDirectory) 'Dism.exe'
    if (-not (Test-Path -LiteralPath $dismPath -PathType Leaf)) {
        return New-AnalysisResult -Name 'Windows Component Store' -Category 'System' -Status 'Unavailable' -SizeBytes 0 -Path $dismPath -Notes 'DISM was not found.' -CountInPotential $false
    }

    try {
        $output = @(& $dismPath /Online /Cleanup-Image /AnalyzeComponentStore /English 2>&1)
        $exitCode = $LASTEXITCODE
        $outputText = $output -join [Environment]::NewLine
        if ($exitCode -ne 0) {
            return New-AnalysisResult -Name 'Windows Component Store' -Category 'System' -Status 'ScanFailed' -SizeBytes 0 -Path 'DISM /AnalyzeComponentStore' -Notes ('DISM exit code: {0}' -f $exitCode) -CountInPotential $false
        }

        $recommendation = [regex]::Match($outputText, 'Component Store Cleanup Recommended\s*:\s*(Yes|No)')
        $packageMatch = [regex]::Match($outputText, 'Number of Reclaimable Packages\s*:\s*(\d+)')
        $packages = if ($packageMatch.Success) { $packageMatch.Groups[1].Value } else { 'unknown' }
        $status = if (-not $recommendation.Success) { 'Unknown' } elseif ($recommendation.Groups[1].Value -eq 'Yes') { 'CleanupRecommended' } else { 'NoCleanupRecommended' }
        $notes = 'DISM reports {0} reclaimable package(s). DISM does not provide a reliable byte estimate.' -f $packages
        return New-AnalysisResult -Name 'Windows Component Store' -Category 'System' -Status $status -SizeBytes 0 -Path 'DISM /Online /Cleanup-Image /AnalyzeComponentStore' -Notes $notes -CountInPotential $false
    }
    catch {
        return New-AnalysisResult -Name 'Windows Component Store' -Category 'System' -Status 'ScanFailed' -SizeBytes 0 -Path 'DISM /AnalyzeComponentStore' -Notes $_.Exception.Message -CountInPotential $false
    }
}

function Get-HibernationFileAnalysis {
    $root = Get-SystemDriveRoot
    $path = Join-Path $root 'hiberfil.sys'
    try {
        $file = Get-ChildItem -LiteralPath $root -Force -File -ErrorAction Stop | Where-Object { $_.Name -eq 'hiberfil.sys' } | Select-Object -First 1
        if ($null -eq $file) {
            return $null
        }
        return New-AnalysisResult -Name 'Hibernation file (review only)' -Category 'FeatureChange' -Status 'Review' -SizeBytes ([Int64]$file.Length) -Path $path -Notes 'Not redundant cache. Reduced mode can retain Fast Startup but disables full hibernation; Off disables both.' -CountInPotential $false
    }
    catch {
        return $null
    }
}

try { $reportBase = Initialize-ReportBase -Directory $ReportDirectory }
catch { [Console]::Error.WriteLine(('Could not initialize analysis reports: {0}' -f $_.Exception.Message)); exit 10 }
$reportFile = $reportBase + '.txt'
$jsonFile = $reportBase + '.json'
$csvFile = $reportBase + '.csv'
$isAdmin = Test-RunningAsAdministrator
$systemDrive = Get-SystemDriveRoot
$driveInfo = New-Object IO.DriveInfo($systemDrive)
$freeBytes = [Int64]$driveInfo.AvailableFreeSpace
$totalBytes = [Int64]$driveInfo.TotalSize

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
$scanTimeUtc = [datetime]::UtcNow

$results = New-Object System.Collections.Generic.List[object]
foreach ($target in $targets) {
    if ($target.RequiresAdmin -and -not $isAdmin) {
        $results.Add((New-AnalysisResult -Name $target.Name -Category $target.Category -Status 'AdminRequired' -SizeBytes 0 -Path $target.Path -Notes 'Run as Administrator for a complete measurement.' -CountInPotential $false)) | Out-Null
        continue
    }

    $measurement = Measure-CacheTarget -Target $target -CutoffUtc ($scanTimeUtc.AddDays(-$target.MinimumAgeDays))
    if (-not $measurement.SafeToClean) {
        $status = if ($measurement.AccessErrors -gt 0) { 'ScanFailed' } else { 'UnsafePath' }
        $results.Add((New-AnalysisResult -Name $target.Name -Category $target.Category -Status $status -SizeBytes 0 -Path $target.Path -Notes $measurement.SafetyReason -AccessErrors $measurement.AccessErrors -CountInPotential $false)) | Out-Null
        continue
    }
    if (-not $measurement.Exists) {
        continue
    }
    if (-not $measurement.MeasurementComplete -and $measurement.SizeBytes -le 0 -and $measurement.ItemCount -le 0) {
        $results.Add((New-AnalysisResult -Name $target.Name -Category $target.Category -Status 'ScanFailed' -SizeBytes 0 -Path $target.Path -Notes ('Measurement failed with {0} access error(s).' -f $measurement.AccessErrors) -CountInPotential $false)) | Out-Null
        continue
    }
    if ($measurement.SizeBytes -le 0 -and $measurement.ItemCount -le 0 -and $measurement.ReparsePointsSkipped -eq 0) {
        continue
    }

    $complete = $measurement.MeasurementComplete -and $measurement.ReparsePointsSkipped -eq 0
    $status = if ($complete) { 'Found' } else { 'FoundPartial' }
    $notes = $measurement.Notes
    $countInPotential = $true
    if ($target.ProcessNames.Count -gt 0 -and @(Get-Process -Name $target.ProcessNames -ErrorAction SilentlyContinue).Count -gt 0) {
        $status = 'Busy'
        $countInPotential = $false
        $notes += ' Related application/build process is running; close it before cleanup. Excluded from the available candidate total.'
    }
    if (-not $complete) {
        $notes = '{0} Measurement incomplete: {1} access error(s), {2} reparse point(s) skipped.' -f $notes, $measurement.AccessErrors, $measurement.ReparsePointsSkipped
    }
    $results.Add((New-AnalysisResult -Name $measurement.Name -Category $measurement.Category -Status $status -SizeBytes $measurement.SizeBytes -Path $measurement.Path -Notes $notes -ItemCount $measurement.ItemCount -FileCount $measurement.FileCount -AccessErrors $measurement.AccessErrors -ReparsePointsSkipped $measurement.ReparsePointsSkipped -CountInPotential $countInPotential)) | Out-Null
}

$deliveryResult = Get-DeliveryOptimizationAnalysis
if ($null -ne $deliveryResult) { $results.Add($deliveryResult) | Out-Null }
if ($IncludeRecycleBin -and $Scope -ne 'System') {
    $results.Add((Get-RecycleBinAnalysis)) | Out-Null
}
if ($Scope -ne 'User' -and ($AnalyzeComponentStore -or $CleanupLevel -ne 'Safe')) {
    $results.Add((Get-ComponentStoreAnalysis)) | Out-Null
}
$hibernationResult = if ($Scope -ne 'User') { Get-HibernationFileAnalysis } else { $null }
if ($null -ne $hibernationResult) {
    $results.Add($hibernationResult) | Out-Null
}

$potentialItems = @($results | Where-Object { $_.CountInPotential -and $_.Status -in @('Found', 'FoundPartial') })
$potentialBytes = [Int64]0
foreach ($item in $potentialItems) { $potentialBytes += [Int64]$item.SizeBytes }
$projectedFree = [Math]::Min($totalBytes, $freeBytes + $potentialBytes)
$freePercent = if ($totalBytes -gt 0) { 100 * $freeBytes / $totalBytes } else { 0 }
$projectedPercent = if ($totalBytes -gt 0) { 100 * $projectedFree / $totalBytes } else { 0 }

$header = @(
    'Windows system-drive cleanup analysis',
    ('Timestamp: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('Cleanup level assessed: {0}' -f $CleanupLevel),
    ('Scope: {0}' -f $Scope),
    ('System drive: {0}' -f $systemDrive),
    ('Administrator: {0}' -f $isAdmin),
    ('Current free space: {0} ({1:N1}%)' -f (Format-Bytes -Bytes $freeBytes), $freePercent),
    ('Measured reclaimable candidate bytes: {0}' -f (Format-Bytes -Bytes $potentialBytes)),
    ('Projected free space: {0} ({1:N1}%)' -f (Format-Bytes -Bytes $projectedFree), $projectedPercent),
    'Candidate sizes are logical file sizes and can differ from the actual volume-space change.',
    'Busy applications are excluded from the total. Projected space is an estimate, not a cleanup result.',
    ''
)

$sorted = @($results | Sort-Object @{ Expression = 'CountInPotential'; Descending = $true }, @{ Expression = 'SizeBytes'; Descending = $true }, Name)
$table = $sorted | Select-Object Name, Category, Status, Size, ItemCount, FileCount, Path, Notes | Format-Table -Wrap -AutoSize | Out-String -Width 4096
$text = ($header -join [Environment]::NewLine) + [Environment]::NewLine + $table

$summaryObject = [pscustomobject]@{
    SchemaVersion             = 3
    Timestamp                 = (Get-Date).ToString('o')
    CleanupLevel              = $CleanupLevel
    Scope                     = $Scope
    SystemDrive               = $systemDrive
    Administrator             = $isAdmin
    TotalBytes                = $totalBytes
    FreeBytes                 = $freeBytes
    FreePercent               = $freePercent
    PotentialReclaimableBytes = $potentialBytes
    ProjectedFreeBytes        = $projectedFree
    ProjectedFreePercent      = $projectedPercent
    Results                   = $sorted
}

$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($reportFile, $text, $utf8NoBom)
[IO.File]::WriteAllText($jsonFile, ($summaryObject | ConvertTo-Json -Depth 6), $utf8NoBom)
$sorted | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8

Write-Host $text
Write-Host ('Text report: {0}' -f $reportFile)
Write-Host ('JSON report: {0}' -f $jsonFile)
Write-Host ('CSV report:  {0}' -f $csvFile)

if (@($results | Where-Object { $_.Status -in @('UnsafePath','ScanFailed','FoundPartial','ReviewPartial','Unknown') -or $_.AccessErrors -gt 0 -or $_.ReparsePointsSkipped -gt 0 }).Count -gt 0) { exit 2 }
exit 0

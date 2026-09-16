#Requires -Version 5.1

function Format-Bytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Int64]$Bytes
    )

    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $size = [double]$Bytes
    $index = 0

    while ([Math]::Abs($size) -ge 1024 -and $index -lt ($units.Length - 1)) {
        $size = $size / 1024
        $index++
    }

    return ('{0:N2} {1}' -f $size, $units[$index])
}

function Test-RunningAsAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SystemDriveRoot {
    [CmdletBinding()]
    param()

    # This project deliberately targets C:, even if Windows is installed elsewhere.
    return 'C:\'
}

function Get-SystemDriveFreeBytes {
    [CmdletBinding()]
    param()

    try {
        $drive = New-Object IO.DriveInfo((Get-SystemDriveRoot))
        return [Int64]$drive.AvailableFreeSpace
    }
    catch {
        return $null
    }
}

function ConvertTo-NormalizedFileSystemPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') {
        throw ('Path must be an absolute drive-letter path (for example C:\Cache): {0}' -f $Path)
    }
    if ($Path.Substring(2) -match '[:*?"<>|\x00-\x1F]' -or $Path -match '(^|[\\/])\.\.([\\/]|$)') {
        throw ('Path contains an unsafe component, wildcard or alternate data stream: {0}' -f $Path)
    }
    foreach ($component in ($Path.Substring(3) -split '[\\/]')) {
        if ($component -match '[. ]$') {
            throw ('Path components must not end in a dot or space: {0}' -f $Path)
        }
    }

    $normalized = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($normalized)
    if (-not $normalized.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }

    return $normalized
}

function Test-PathWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root,

        [switch]$AllowEqual
    )

    try {
        $normalizedPath = ConvertTo-NormalizedFileSystemPath -Path $Path
        $normalizedRoot = ConvertTo-NormalizedFileSystemPath -Path $Root
    }
    catch {
        return $false
    }

    if ($normalizedPath.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $AllowEqual.IsPresent
    }

    $prefix = $normalizedRoot.TrimEnd('\') + '\'
    return $normalizedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function New-CacheTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$AllowedRoot,

        [ValidateSet('DirectoryContents', 'FilePattern')]
        [string]$Mode = 'DirectoryContents',

        [string]$Filter = '*',

        [bool]$RequiresAdmin = $false,

        [string]$Category = 'Safe',

        [string]$Notes = '',

        [string[]]$ServicesToStop = @(),

        [ValidateRange(0, 3650)]
        [int]$MinimumAgeDays = 0,

        [string[]]$ProcessNames = @(),

        [string]$UserProfileSid = ''
    )

    [pscustomobject]@{
        Name           = $Name
        Path           = $Path
        AllowedRoot    = $AllowedRoot
        Mode           = $Mode
        Filter         = $Filter
        RequiresAdmin  = $RequiresAdmin
        Category       = $Category
        Notes          = $Notes
        ServicesToStop = @($ServicesToStop)
        MinimumAgeDays = $MinimumAgeDays
        ProcessNames   = @($ProcessNames)
        UserProfileSid = $UserProfileSid
    }
}

function Test-CacheTargetSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Target
    )

    $result = [ordered]@{
        IsSafe         = $false
        NormalizedPath = $null
        Reason         = ''
        AccessErrors   = 0
        ReparsePointsSkipped = 0
    }

    try {
        $path = ConvertTo-NormalizedFileSystemPath -Path $Target.Path
        $allowedRoot = ConvertTo-NormalizedFileSystemPath -Path $Target.AllowedRoot
        $systemDrive = ConvertTo-NormalizedFileSystemPath -Path (Get-SystemDriveRoot)
    }
    catch {
        $result.Reason = $_.Exception.Message
        return [pscustomobject]$result
    }

    $result.NormalizedPath = $path
    $pathRoot = ConvertTo-NormalizedFileSystemPath -Path ([IO.Path]::GetPathRoot($path))
    if (-not $pathRoot.Equals($systemDrive, [StringComparison]::OrdinalIgnoreCase)) {
        $result.Reason = ('Target is outside the permitted C: drive: {0}' -f $path)
        return [pscustomobject]$result
    }

    if (-not (Test-PathWithinRoot -Path $path -Root $allowedRoot -AllowEqual)) {
        $result.Reason = ('Target escaped its allowed root: {0}' -f $allowedRoot)
        return [pscustomobject]$result
    }

    if ($Target.Mode -notin @('DirectoryContents', 'FilePattern')) {
        $result.Reason = 'Unknown target mode.'
        return [pscustomobject]$result
    }
    if ($Target.Mode -eq 'FilePattern' -and ([string]::IsNullOrWhiteSpace($Target.Filter) -or $Target.Filter -in @('*', '*.*') -or $Target.Filter -match '[\\/:]')) {
        $result.Reason = 'A file-pattern target cannot use an unrestricted filter.'
        return [pscustomobject]$result
    }

    $windowsRoot = [Environment]::GetFolderPath('Windows')
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $appData = [Environment]::GetFolderPath('ApplicationData')
    $protectedPaths = @(
        $systemDrive,
        $windowsRoot,
        (Join-Path $systemDrive 'Users'),
        $programData,
        $programFiles,
        $programFilesX86,
        $userProfile,
        $localAppData,
        $appData
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        try { ConvertTo-NormalizedFileSystemPath -Path $_ } catch { $null }
    } | Where-Object { $null -ne $_ }

    if ($Target.Mode -eq 'DirectoryContents') {
        foreach ($protectedPath in $protectedPaths) {
            if ($path.Equals($protectedPath, [StringComparison]::OrdinalIgnoreCase)) {
                $result.Reason = ('Refusing to delete the contents of protected root: {0}' -f $path)
                return [pscustomobject]$result
            }
        }
    }

    $components = Test-FileSystemPathComponents -Path $path
    if (-not $components.IsSafe) {
        $result.Reason = $components.Reason
        $result.AccessErrors = $components.AccessErrors
        if ($components.ReparsePoint) { $result.ReparsePointsSkipped = 1 }
        return [pscustomobject]$result
    }

    $result.IsSafe = $true
    $result.Reason = 'Validated'
    return [pscustomobject]$result
}

function Test-FileSystemPathComponents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = [ordered]@{ IsSafe = $false; Reason = ''; ReparsePoint = $false; AccessErrors = 0 }
    try {
        $cursor = ConvertTo-NormalizedFileSystemPath -Path $Path
        $driveRoot = [IO.Path]::GetPathRoot($cursor)
        if (-not $driveRoot.Equals((Get-SystemDriveRoot), [StringComparison]::OrdinalIgnoreCase)) {
            $result.Reason = 'Only C: paths are permitted.'
            return [pscustomobject]$result
        }
    }
    catch {
        $result.Reason = $_.Exception.Message
        return [pscustomobject]$result
    }

    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        try {
            $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $result.Reason = ('Target or ancestor is a reparse point: {0}' -f $cursor)
                $result.ReparsePoint = $true
                return [pscustomobject]$result
            }
        }
        catch [System.Management.Automation.ItemNotFoundException] {
        }
        catch {
            $result.Reason = ('Could not validate path component {0}: {1}' -f $cursor, $_.Exception.Message)
            $result.AccessErrors = 1
            return [pscustomobject]$result
        }

        if ($cursor.Equals($driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($cursor, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $cursor = $parent
    }

    $result.IsSafe = $true
    $result.Reason = 'Validated'
    return [pscustomobject]$result
}

function Test-ReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-CacheTargetItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Target,

        [datetime]$CutoffUtc
    )

    $arguments = @{ Target = $Target }
    if ($PSBoundParameters.ContainsKey('CutoffUtc')) {
        $arguments.CutoffUtc = $CutoffUtc
    }
    $inventory = Get-CacheTargetInventory @arguments
    if (-not $inventory.SafeToClean) {
        return @()
    }

    # Never return directories that a legacy caller might recursively delete.
    return $inventory.Files
}

function Test-CacheFileAge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item,

        [Parameter(Mandatory = $true)]
        [datetime]$CutoffUtc,

        [ValidateRange(0, 3650)]
        [int]$MinimumAgeDays = 0
    )

    if ($MinimumAgeDays -eq 0) {
        return $true
    }
    # A newly copied file can preserve an old modification time. Both clocks
    # must be old before a file is eligible for age-based TEMP cleanup.
    return ($Item.LastWriteTimeUtc -le $CutoffUtc.ToUniversalTime() -and
        $Item.CreationTimeUtc -le $CutoffUtc.ToUniversalTime())
}

function Get-CacheTargetInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Target,

        [datetime]$CutoffUtc
    )

    if (-not $PSBoundParameters.ContainsKey('CutoffUtc')) {
        $CutoffUtc = [datetime]::UtcNow.AddDays(-1 * $Target.MinimumAgeDays)
    }
    $CutoffUtc = $CutoffUtc.ToUniversalTime()
    $files = New-Object 'System.Collections.Generic.List[object]'
    $directories = New-Object 'System.Collections.Generic.List[object]'
    $result = [ordered]@{
        Files                = @()
        Directories          = @()
        CutoffUtc            = $CutoffUtc
        SizeBytes            = [Int64]0
        FileCount            = 0
        ItemCount            = 0
        AccessErrors         = 0
        ReparsePointsSkipped = 0
        RetainedFiles        = 0
        Exists               = $null
        SafeToClean          = $false
        SafetyReason         = ''
        MeasurementComplete  = $true
    }

    $safety = Test-CacheTargetSafety -Target $Target
    $result.SafeToClean = $safety.IsSafe
    $result.SafetyReason = $safety.Reason
    if (-not $safety.IsSafe) {
        $result.AccessErrors = $safety.AccessErrors
        $result.ReparsePointsSkipped = $safety.ReparsePointsSkipped
        $result.MeasurementComplete = $false
        return [pscustomobject]$result
    }

    try {
        $container = Get-Item -LiteralPath $safety.NormalizedPath -Force -ErrorAction Stop
        $result.Exists = $true
        if (-not $container.PSIsContainer) {
            $result.SafeToClean = $false
            $result.SafetyReason = 'The target is not a directory.'
            $result.MeasurementComplete = $false
            return [pscustomobject]$result
        }
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        $result.Exists = $false
        return [pscustomobject]$result
    }
    catch {
        $result.AccessErrors = 1
        $result.SafeToClean = $false
        $result.SafetyReason = ('Could not read target: {0}' -f $_.Exception.Message)
        $result.MeasurementComplete = $false
        return [pscustomobject]$result
    }

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($safety.NormalizedPath)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        # Revalidate queued directories and their ancestors immediately before
        # enumerating them. No recursive provider traversal follows junctions.
        $components = Test-FileSystemPathComponents -Path $directory
        if (-not $components.IsSafe) {
            if ($components.ReparsePoint) {
                $result.ReparsePointsSkipped++
            }
            else {
                $result.AccessErrors++
            }
            if ($directory.Equals($safety.NormalizedPath, [StringComparison]::OrdinalIgnoreCase)) {
                $result.SafeToClean = $false
                $result.SafetyReason = $components.Reason
                $result.MeasurementComplete = $false
            }
            continue
        }

        try {
            if ($Target.Mode -eq 'FilePattern') {
                $children = @(Get-ChildItem -LiteralPath $directory -File -Force -Filter $Target.Filter -ErrorAction Stop)
            }
            else {
                $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
            }
        }
        catch {
            $result.AccessErrors++
            if ($directory.Equals($safety.NormalizedPath, [StringComparison]::OrdinalIgnoreCase)) {
                $result.SafeToClean = $false
                $result.SafetyReason = ('Could not enumerate target: {0}' -f $_.Exception.Message)
            }
            continue
        }

        foreach ($child in $children) {
            if (-not (Test-PathWithinRoot -Path $child.FullName -Root $safety.NormalizedPath)) {
                $result.AccessErrors++
                continue
            }
            if (Test-ReparsePoint -Item $child) {
                $result.ReparsePointsSkipped++
                continue
            }
            if ($child.PSIsContainer) {
                $directories.Add($child) | Out-Null
                $pending.Push($child.FullName)
                continue
            }
            try {
                if (-not (Test-CacheFileAge -Item $child -CutoffUtc $CutoffUtc -MinimumAgeDays $Target.MinimumAgeDays)) {
                    $result.RetainedFiles++
                    continue
                }
                $result.SizeBytes += [Int64]$child.Length
                $files.Add($child) | Out-Null
            }
            catch {
                $result.AccessErrors++
            }
        }
    }

    $result.Files = $files.ToArray()
    $result.Directories = @($directories.ToArray() | Sort-Object { $_.FullName.Length } -Descending)
    $result.FileCount = $files.Count
    $result.ItemCount = $files.Count + $directories.Count
    if ($result.AccessErrors -gt 0) {
        $result.MeasurementComplete = $false
    }
    return [pscustomobject]$result
}

function Measure-FileSystemEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    $sizeBytes = [Int64]0
    $fileCount = 0
    $accessErrors = 0
    $reparseSkipped = 0

    $components = Test-FileSystemPathComponents -Path $Item.FullName
    if ((Test-ReparsePoint -Item $Item) -or -not $components.IsSafe) {
        return [pscustomobject]@{
            SizeBytes      = $sizeBytes
            FileCount      = $fileCount
            AccessErrors   = $components.AccessErrors
            ReparseSkipped = [int]((Test-ReparsePoint -Item $Item) -or $components.ReparsePoint)
        }
    }

    if (-not $Item.PSIsContainer) {
        try {
            $sizeBytes = [Int64]$Item.Length
            $fileCount = 1
        }
        catch {
            $accessErrors++
        }

        return [pscustomobject]@{
            SizeBytes      = $sizeBytes
            FileCount      = $fileCount
            AccessErrors   = $accessErrors
            ReparseSkipped = $reparseSkipped
        }
    }

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Item.FullName)

    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $components = Test-FileSystemPathComponents -Path $directory
        if (-not $components.IsSafe) {
            $accessErrors += $components.AccessErrors
            if ($components.ReparsePoint) { $reparseSkipped++ }
            continue
        }
        try {
            $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
        }
        catch {
            $accessErrors++
            continue
        }

        foreach ($child in $children) {
            if (Test-ReparsePoint -Item $child) {
                $reparseSkipped++
                continue
            }

            if ($child.PSIsContainer) {
                $pending.Push($child.FullName)
                continue
            }

            try {
                $sizeBytes += [Int64]$child.Length
                $fileCount++
            }
            catch {
                $accessErrors++
            }
        }
    }

    return [pscustomobject]@{
        SizeBytes      = $sizeBytes
        FileCount      = $fileCount
        AccessErrors   = $accessErrors
        ReparseSkipped = $reparseSkipped
    }
}

function Measure-CacheTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Target,

        [datetime]$CutoffUtc
    )

    $result = [ordered]@{
        Name                 = $Target.Name
        Path                 = $Target.Path
        Category             = $Target.Category
        RequiresAdmin        = $Target.RequiresAdmin
        Notes                = $Target.Notes
        Exists               = $false
        SafeToClean          = $false
        SafetyReason         = ''
        ItemCount            = 0
        FileCount            = 0
        SizeBytes            = [Int64]0
        AccessErrors         = 0
        ReparsePointsSkipped = 0
        RetainedFiles        = 0
        CutoffUtc            = $null
        MeasurementComplete  = $true
    }

    $arguments = @{ Target = $Target }
    if ($PSBoundParameters.ContainsKey('CutoffUtc')) {
        $arguments.CutoffUtc = $CutoffUtc
    }
    $inventory = Get-CacheTargetInventory @arguments
    foreach ($property in @('Exists', 'SafeToClean', 'SafetyReason', 'ItemCount', 'FileCount', 'SizeBytes', 'AccessErrors', 'ReparsePointsSkipped', 'RetainedFiles', 'CutoffUtc', 'MeasurementComplete')) {
        $result[$property] = $inventory.$property
    }

    return [pscustomobject]$result
}

function Get-CacheProfileDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $probe = New-CacheTarget -Name 'Profile discovery' -Path $Root -AllowedRoot $Root
    $safety = Test-CacheTargetSafety -Target $probe
    if (-not $safety.IsSafe) {
        if ($safety.AccessErrors -gt 0) {
            Write-Warning ('Could not discover profiles under {0}: {1}' -f $Root, $safety.Reason)
        }
        else {
            Write-Verbose ('Skipping profile discovery: {0}' -f $safety.Reason)
        }
        return @()
    }
    try {
        $container = Get-Item -LiteralPath $safety.NormalizedPath -Force -ErrorAction Stop
        if (-not $container.PSIsContainer) { return @() }
        return @(Get-ChildItem -LiteralPath $safety.NormalizedPath -Directory -Force -ErrorAction Stop | Where-Object {
            -not (Test-ReparsePoint -Item $_)
        })
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return @()
    }
    catch {
        Write-Warning ('Could not discover profiles under {0}: {1}' -f $Root, $_.Exception.Message)
        return @()
    }
}

function Get-ChromiumCacheTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BrowserName,

        [Parameter(Mandatory = $true)]
        [string]$UserDataRoot,

        [switch]$IncludeOfflineWebCaches,
        [switch]$IncludeDownloadedModels,

        [string[]]$ProcessNames = @()
    )

    $targets = New-Object System.Collections.Generic.List[object]
    if ($ProcessNames.Count -eq 0) {
        $ProcessNames = switch ($BrowserName) {
            'Chrome' { @('chrome') }
            'Edge' { @('msedge') }
            default { @($BrowserName.ToLowerInvariant()) }
        }
    }

    $profiles = @(Get-CacheProfileDirectories -Root $UserDataRoot | Where-Object {
        $_.Name -eq 'Default' -or
        $_.Name -eq 'Guest Profile' -or
        $_.Name -eq 'System Profile' -or
        $_.Name -like 'Profile *'
    })

    $profileRelativePaths = @(
        'Cache',
        'Code Cache',
        'GPUCache',
        'GrShaderCache',
        'DawnCache',
        'DawnGraphiteCache',
        'DawnWebGPUCache',
        'GraphiteDawnCache',
        'Media Cache',
        'Network\Cache'
    )
    if ($IncludeOfflineWebCaches) {
        $profileRelativePaths += 'Service Worker\CacheStorage'
    }

    foreach ($profile in $profiles) {
        foreach ($relativePath in $profileRelativePaths) {
            $targets.Add((New-CacheTarget -Name ("{0} {1} {2}" -f $BrowserName, $profile.Name, $relativePath) -Path (Join-Path $profile.FullName $relativePath) -AllowedRoot $UserDataRoot -Category 'Browser' -ProcessNames $ProcessNames -Notes 'Browser-generated cache; open tabs may need to download content again.')) | Out-Null
        }
    }

    foreach ($relativePath in @('ShaderCache', 'GrShaderCache', 'GraphiteDawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'component_crx_cache')) {
        $targets.Add((New-CacheTarget -Name ("{0} shared {1}" -f $BrowserName, $relativePath) -Path (Join-Path $UserDataRoot $relativePath) -AllowedRoot $UserDataRoot -Category 'Browser' -ProcessNames $ProcessNames -Notes 'Shared downloadable browser cache.')) | Out-Null
    }

    if ($IncludeDownloadedModels) {
        foreach ($relativePath in @('OptGuideOnDeviceModel', 'optimization_guide_model_store')) {
            $targets.Add((New-CacheTarget -Name ("{0} downloaded {1}" -f $BrowserName, $relativePath) -Path (Join-Path $UserDataRoot $relativePath) -AllowedRoot $UserDataRoot -Category 'DownloadedModel' -ProcessNames $ProcessNames -Notes 'Large browser model; features may download it again.')) | Out-Null
        }
    }

    return $targets.ToArray()
}

function Get-FirefoxCacheTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfilesRoot
    )

    $targets = New-Object System.Collections.Generic.List[object]
    $profiles = @(Get-CacheProfileDirectories -Root $ProfilesRoot)
    foreach ($profile in $profiles) {
        foreach ($relativePath in @('cache2', 'startupCache', 'shader-cache', 'jumpListCache', 'thumbnails')) {
            $targets.Add((New-CacheTarget -Name ("Firefox {0} {1}" -f $profile.Name, $relativePath) -Path (Join-Path $profile.FullName $relativePath) -AllowedRoot $ProfilesRoot -Category 'Browser' -ProcessNames @('firefox') -Notes 'Firefox-generated cache.')) | Out-Null
        }
    }

    return $targets.ToArray()
}

function Get-ApplicationCacheTargets {
    [CmdletBinding()]
    param()

    $targets = New-Object System.Collections.Generic.List[object]
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $appData = [Environment]::GetFolderPath('ApplicationData')
    $applications = @(
        [pscustomobject]@{ Name = 'Microsoft Teams (classic)'; Root = (Join-Path $appData 'Microsoft\Teams'); Processes = @('Teams') },
        [pscustomobject]@{ Name = 'Microsoft Teams'; Root = (Join-Path $localAppData 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams'); Processes = @('ms-teams', 'msteams', 'msedgewebview2') },
        [pscustomobject]@{ Name = 'Visual Studio Code'; Root = (Join-Path $appData 'Code'); Processes = @('Code') },
        [pscustomobject]@{ Name = 'Discord'; Root = (Join-Path $appData 'discord'); Processes = @('Discord', 'DiscordCanary', 'DiscordPTB') },
        [pscustomobject]@{ Name = 'Slack'; Root = (Join-Path $appData 'Slack'); Processes = @('slack') }
    )

    foreach ($application in $applications) {
        foreach ($relativePath in @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'CachedData', 'CachedExtensionVSIXs')) {
            $targets.Add((New-CacheTarget -Name ("{0} {1}" -f $application.Name, $relativePath) -Path (Join-Path $application.Root $relativePath) -AllowedRoot $application.Root -Category 'Application' -ProcessNames $application.Processes -Notes 'Application-generated cache; the application must be closed.')) | Out-Null
        }
    }

    return $targets.ToArray()
}

function Get-UwpTempStateTargets {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 3650)]
        [int]$MinimumAgeDays = 1
    )

    $targets = New-Object System.Collections.Generic.List[object]
    $packagesRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Packages'
    foreach ($package in @(Get-CacheProfileDirectories -Root $packagesRoot)) {
        $tempState = Join-Path $package.FullName 'TempState'
        $targets.Add((New-CacheTarget -Name ("UWP TempState ({0})" -f $package.Name) -Path $tempState -AllowedRoot $package.FullName -Category 'Application' -ProcessNames @('ApplicationFrameHost', 'RuntimeBroker') -Notes 'UWP temporary state; skipped while shared UWP host processes run. LocalState and generic LocalCache are never scanned.' -MinimumAgeDays $MinimumAgeDays)) | Out-Null
    }

    return $targets.ToArray()
}

function Get-DeveloperCacheTargets {
    [CmdletBinding()]
    param()

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $definitions = @(
        [pscustomobject]@{ Name = 'npm download cache'; Path = (Join-Path $localAppData 'npm-cache'); Root = $localAppData; Processes = @('node', 'npm', 'npx'); Notes = 'Packages will be downloaded again when needed.' },
        [pscustomobject]@{ Name = 'pip HTTP cache'; Path = (Join-Path $localAppData 'pip\Cache\http'); Root = $localAppData; Processes = @('python', 'pythonw', 'pip', 'pip3', 'uv'); Notes = 'Python package HTTP downloads can be fetched again.' },
        [pscustomobject]@{ Name = 'pip HTTP v2 cache'; Path = (Join-Path $localAppData 'pip\Cache\http-v2'); Root = $localAppData; Processes = @('python', 'pythonw', 'pip', 'pip3', 'uv'); Notes = 'Python package HTTP downloads can be fetched again.' },
        [pscustomobject]@{ Name = 'pip wheel cache'; Path = (Join-Path $localAppData 'pip\Cache\wheels'); Root = $localAppData; Processes = @('python', 'pythonw', 'pip', 'pip3', 'uv'); Notes = 'Cached wheels will be rebuilt or downloaded again.' },
        [pscustomobject]@{ Name = 'NuGet HTTP cache'; Path = (Join-Path $localAppData 'NuGet\v3-cache'); Root = $localAppData; Processes = @('nuget', 'dotnet', 'devenv', 'MSBuild'); Notes = 'NuGet HTTP responses will be downloaded again when needed.' },
        [pscustomobject]@{ Name = 'NuGet plug-in cache'; Path = (Join-Path $localAppData 'NuGet\plugins-cache'); Root = $localAppData; Processes = @('nuget', 'dotnet', 'devenv', 'MSBuild'); Notes = 'NuGet plug-in metadata will be rebuilt.' },
        [pscustomobject]@{ Name = 'Yarn cache'; Path = (Join-Path $localAppData 'Yarn\Cache'); Root = $localAppData; Processes = @('node', 'yarn'); Notes = 'Packages will be downloaded again when needed.' },
        [pscustomobject]@{ Name = 'Go build cache'; Path = (Join-Path $localAppData 'go-build'); Root = $localAppData; Processes = @('go', 'gopls', 'compile', 'link'); Notes = 'Go build outputs will be regenerated.' }
    )
    # Maven local repositories may contain unpublished artifacts. NuGet global
    # packages, Gradle dependency stores and pnpm stores are also excluded.

    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($definition in $definitions) {
        $targets.Add((New-CacheTarget -Name $definition.Name -Path $definition.Path -AllowedRoot $definition.Root -Category 'Developer' -ProcessNames $definition.Processes -Notes $definition.Notes)) | Out-Null
    }
    return $targets.ToArray()
}

function Get-WindowsErrorReportTargets {
    [CmdletBinding()]
    param()

    $targets = New-Object System.Collections.Generic.List[object]
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    $roots = @(
        [pscustomobject]@{ Label = 'User WER'; Root = (Join-Path $localAppData 'Microsoft\Windows\WER'); AllowedRoot = $localAppData; Admin = $false },
        [pscustomobject]@{ Label = 'System WER'; Root = (Join-Path $programData 'Microsoft\Windows\WER'); AllowedRoot = $programData; Admin = $true }
    )

    foreach ($root in $roots) {
        foreach ($relativePath in @('ReportArchive', 'ReportQueue', 'Temp')) {
            $targets.Add((New-CacheTarget -Name ("{0} {1}" -f $root.Label, $relativePath) -Path (Join-Path $root.Root $relativePath) -AllowedRoot $root.AllowedRoot -RequiresAdmin $root.Admin -Category 'Diagnostics' -MinimumAgeDays 7 -ProcessNames @('WerFault', 'WerFaultSecure', 'wermgr') -Notes 'Windows Error Reporting data at least seven days old; keep it while troubleshooting crashes.')) | Out-Null
        }
    }

    return $targets.ToArray()
}

function Get-CrashDumpTargets {
    [CmdletBinding()]
    param()

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $windowsRoot = [Environment]::GetFolderPath('Windows')
    return @(
        (New-CacheTarget -Name 'Application crash dumps' -Path (Join-Path $localAppData 'CrashDumps') -AllowedRoot $localAppData -Category 'Diagnostics' -MinimumAgeDays 7 -Notes 'Crash diagnostics at least seven days old; delete only after troubleshooting is complete.'),
        (New-CacheTarget -Name 'Windows minidumps' -Path (Join-Path $windowsRoot 'Minidump') -AllowedRoot $windowsRoot -RequiresAdmin $true -Category 'Diagnostics' -MinimumAgeDays 7 -Notes 'Blue-screen diagnostics at least seven days old; delete only after troubleshooting is complete.'),
        (New-CacheTarget -Name 'Live kernel reports' -Path (Join-Path $windowsRoot 'LiveKernelReports') -AllowedRoot $windowsRoot -RequiresAdmin $true -Category 'Diagnostics' -MinimumAgeDays 7 -Notes 'Kernel diagnostics at least seven days old; delete only after troubleshooting is complete.'),
        (New-CacheTarget -Name 'Windows memory dump' -Path $windowsRoot -AllowedRoot $windowsRoot -Mode 'FilePattern' -Filter 'MEMORY.DMP' -RequiresAdmin $true -Category 'Diagnostics' -MinimumAgeDays 7 -Notes 'Full blue-screen dump at least seven days old; often large, but useful for diagnosis.')
    )
}

function Get-GpuCacheTargets {
    [CmdletBinding()]
    param()

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    return @(
        (New-CacheTarget -Name 'NVIDIA DirectX shader cache' -Path (Join-Path $localAppData 'NVIDIA\DXCache') -AllowedRoot $localAppData -Category 'Graphics' -Notes 'Will be rebuilt by the display driver.'),
        (New-CacheTarget -Name 'NVIDIA OpenGL shader cache' -Path (Join-Path $localAppData 'NVIDIA\GLCache') -AllowedRoot $localAppData -Category 'Graphics' -Notes 'Will be rebuilt by the display driver.'),
        (New-CacheTarget -Name 'NVIDIA shared shader cache' -Path (Join-Path $programData 'NVIDIA Corporation\NV_Cache') -AllowedRoot $programData -RequiresAdmin $true -Category 'Graphics' -Notes 'Will be rebuilt by the display driver.'),
        (New-CacheTarget -Name 'AMD DirectX shader cache' -Path (Join-Path $localAppData 'AMD\DxCache') -AllowedRoot $localAppData -Category 'Graphics' -Notes 'Will be rebuilt by the display driver.'),
        (New-CacheTarget -Name 'AMD OpenGL shader cache' -Path (Join-Path $localAppData 'AMD\GLCache') -AllowedRoot $localAppData -Category 'Graphics' -Notes 'Will be rebuilt by the display driver.'),
        (New-CacheTarget -Name 'AMD Vulkan shader cache' -Path (Join-Path $localAppData 'AMD\VkCache') -AllowedRoot $localAppData -Category 'Graphics' -Notes 'Will be rebuilt by the display driver.'),
        (New-CacheTarget -Name 'Intel shader cache' -Path (Join-Path $localAppData 'Intel\ShaderCache') -AllowedRoot $localAppData -Category 'Graphics' -Notes 'Will be rebuilt by the display driver.')
    )
}

function Get-AllUserTempTargets {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 3650)]
        [int]$MinimumAgeDays = 1
    )

    $targets = New-Object System.Collections.Generic.List[object]
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    try {
        $currentProfile = ConvertTo-NormalizedFileSystemPath -Path $userProfile
        $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop)
    }
    catch {
        Write-Warning ('Other-user TEMP discovery was skipped because profile state could not be verified: {0}' -f $_.Exception.Message)
        return $targets.ToArray()
    }

    foreach ($profile in $profiles) {
        if ($null -eq $profile.Loaded -or $null -eq $profile.Special -or
            $profile.Loaded -or $profile.Special -or
            $profile.SID -notmatch '^S-1-(5-21|12-1)-') {
            continue
        }
        try {
            $profilePath = ConvertTo-NormalizedFileSystemPath -Path $profile.LocalPath
        }
        catch {
            Write-Warning ('Skipping a profile with an invalid local path: {0}' -f $_.Exception.Message)
            continue
        }
        if ($profilePath.Equals($currentProfile, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-PathWithinRoot -Path $profilePath -Root (Get-SystemDriveRoot))) {
            continue
        }
        $tempPath = Join-Path $profilePath 'AppData\Local\Temp'
        $target = New-CacheTarget -Name ("User TEMP ({0})" -f (Split-Path -Leaf $profilePath)) -Path $tempPath -AllowedRoot $profilePath -RequiresAdmin $true -Category 'AllUsers' -UserProfileSid $profile.SID -Notes 'TEMP for an unloaded, non-special local profile; current and service accounts are excluded.' -MinimumAgeDays $MinimumAgeDays
        $safety = Test-CacheTargetSafety -Target $target
        if (-not $safety.IsSafe) {
            Write-Warning ('Other-user TEMP discovery skipped {0}: {1}' -f $profilePath, $safety.Reason)
            continue
        }
        $targets.Add($target) | Out-Null
    }

    return $targets.ToArray()
}

function Get-CacheTargets {
    [CmdletBinding()]
    param(
        [ValidateSet('Safe', 'Deep', 'Maximum')]
        [string]$CleanupLevel = 'Safe',

        [switch]$IncludeBrowsers,
        [switch]$IncludeWindowsUpdate,
        [switch]$IncludeApplicationCaches,
        [switch]$IncludeDeveloperCaches,
        [switch]$IncludeWindowsErrorReports,
        [switch]$IncludeCrashDumps,
        [switch]$IncludeAllUserTemp,
        [switch]$IncludeOfflineWebCaches,
        [switch]$IncludeDownloadedModels,

        [ValidateRange(-1, 3650)]
        [int]$TempFileAgeDays = -1
    )

    $isDeep = $CleanupLevel -eq 'Deep' -or $CleanupLevel -eq 'Maximum'
    $isMaximum = $CleanupLevel -eq 'Maximum'
    if ($TempFileAgeDays -lt 0) {
        $TempFileAgeDays = switch ($CleanupLevel) {
            'Safe' { 7 }
            'Deep' { 2 }
            'Maximum' { 1 }
        }
    }

    $useBrowsers = $IncludeBrowsers.IsPresent -or $isDeep
    $useWindowsUpdate = $IncludeWindowsUpdate.IsPresent -or $isDeep
    $useApplicationCaches = $IncludeApplicationCaches.IsPresent -or $isDeep
    $useDeveloperCaches = $IncludeDeveloperCaches.IsPresent -or $isMaximum
    $useWindowsErrorReports = $IncludeWindowsErrorReports.IsPresent
    $useCrashDumps = $IncludeCrashDumps.IsPresent
    $useAllUserTemp = $IncludeAllUserTemp.IsPresent
    $useOfflineWebCaches = $IncludeOfflineWebCaches.IsPresent
    $useDownloadedModels = $IncludeDownloadedModels.IsPresent -or $isMaximum

    $targets = New-Object System.Collections.Generic.List[object]
    $windowsRoot = [Environment]::GetFolderPath('Windows')
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $appData = [Environment]::GetFolderPath('ApplicationData')
    $userTemp = Join-Path $localAppData 'Temp'
    $targets.Add((New-CacheTarget -Name 'User TEMP' -Path $userTemp -AllowedRoot $userProfile -Category 'Safe' -Notes ("Current-user temporary files older than {0} day(s)." -f $TempFileAgeDays) -MinimumAgeDays $TempFileAgeDays)) | Out-Null
    $targets.Add((New-CacheTarget -Name 'Windows TEMP' -Path (Join-Path $windowsRoot 'Temp') -AllowedRoot $windowsRoot -RequiresAdmin $true -Category 'Safe' -Notes ("System temporary files older than {0} day(s)." -f $TempFileAgeDays) -MinimumAgeDays $TempFileAgeDays)) | Out-Null
    $targets.Add((New-CacheTarget -Name 'DirectX Shader Cache' -Path (Join-Path $localAppData 'D3DSCache') -AllowedRoot $localAppData -Category 'Safe' -Notes 'Graphics shader cache; it will be rebuilt.')) | Out-Null
    $targets.Add((New-CacheTarget -Name 'Explorer Thumbnail Cache' -Path (Join-Path $localAppData 'Microsoft\Windows\Explorer') -AllowedRoot $localAppData -Mode 'FilePattern' -Filter 'thumbcache*.db' -Category 'Safe' -Notes 'Thumbnail previews will be rebuilt.')) | Out-Null
    $targets.Add((New-CacheTarget -Name 'Explorer Icon Cache' -Path (Join-Path $localAppData 'Microsoft\Windows\Explorer') -AllowedRoot $localAppData -Mode 'FilePattern' -Filter 'iconcache*.db' -Category 'Safe' -Notes 'Icons may refresh after sign-in.')) | Out-Null
    $targets.Add((New-CacheTarget -Name 'Local Icon Cache' -Path $localAppData -AllowedRoot $localAppData -Mode 'FilePattern' -Filter 'IconCache.db' -Category 'Safe' -Notes 'Classic icon cache file.')) | Out-Null
    foreach ($target in (Get-GpuCacheTargets)) {
        $targets.Add($target) | Out-Null
    }

    if ($useWindowsUpdate) {
        $targets.Add((New-CacheTarget -Name 'Windows Update Download Cache' -Path (Join-Path $windowsRoot 'SoftwareDistribution\Download') -AllowedRoot $windowsRoot -RequiresAdmin $true -Category 'Advanced' -Notes 'Downloaded update packages. Do not run while Windows Update is installing updates.' -ServicesToStop @('wuauserv', 'bits'))) | Out-Null
    }

    if ($useBrowsers) {
        foreach ($target in (Get-ChromiumCacheTargets -BrowserName 'Chrome' -UserDataRoot (Join-Path $localAppData 'Google\Chrome\User Data') -IncludeOfflineWebCaches:$useOfflineWebCaches -IncludeDownloadedModels:$useDownloadedModels)) {
            $targets.Add($target) | Out-Null
        }
        foreach ($target in (Get-ChromiumCacheTargets -BrowserName 'Edge' -UserDataRoot (Join-Path $localAppData 'Microsoft\Edge\User Data') -IncludeOfflineWebCaches:$useOfflineWebCaches -IncludeDownloadedModels:$useDownloadedModels)) {
            $targets.Add($target) | Out-Null
        }
        foreach ($profileRoot in @(
            (Join-Path $localAppData 'Mozilla\Firefox\Profiles'),
            (Join-Path $appData 'Mozilla\Firefox\Profiles')
        )) {
            foreach ($target in (Get-FirefoxCacheTargets -ProfilesRoot $profileRoot)) {
                $targets.Add($target) | Out-Null
            }
        }
    }

    if ($useApplicationCaches) {
        foreach ($target in (Get-ApplicationCacheTargets)) {
            $targets.Add($target) | Out-Null
        }
        foreach ($target in (Get-UwpTempStateTargets -MinimumAgeDays ([Math]::Max(1, $TempFileAgeDays)))) {
            $targets.Add($target) | Out-Null
        }
    }
    if ($useDeveloperCaches) {
        foreach ($target in (Get-DeveloperCacheTargets)) {
            $targets.Add($target) | Out-Null
        }
    }
    if ($useWindowsErrorReports) {
        foreach ($target in (Get-WindowsErrorReportTargets)) {
            $targets.Add($target) | Out-Null
        }
    }
    if ($useCrashDumps) {
        foreach ($target in (Get-CrashDumpTargets)) {
            $targets.Add($target) | Out-Null
        }
    }
    if ($useAllUserTemp) {
        foreach ($target in (Get-AllUserTempTargets -MinimumAgeDays ([Math]::Max(1, $TempFileAgeDays)))) {
            $targets.Add($target) | Out-Null
        }
    }

    $deduplicated = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($target in $targets) {
        try {
            $normalized = ConvertTo-NormalizedFileSystemPath -Path $target.Path
        }
        catch {
            $normalized = $target.Path
        }
        $key = ('{0}|{1}|{2}' -f $normalized.ToLowerInvariant(), $target.Mode, $target.Filter.ToLowerInvariant())
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $deduplicated.Add($target) | Out-Null
        }
    }

    return $deduplicated.ToArray()
}

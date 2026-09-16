#Requires -Version 5.1
<#
Run with powershell.exe or pwsh.exe -NoProfile -File tests\Invoke-SafetyTests.ps1.
No Pester dependency. The cleanup entry point is NEVER executed: only its AST
function declarations are loaded. Every file/junction is inside a unique fixture
under tests. System service/process mutation commands are fail-closed sentinels.
#>
[CmdletBinding()]
param([switch]$CommonOnly)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$script:Count = 0
$script:Failures = 0
$script:MutationCalls = 0
$script:Fixture = Join-Path $PSScriptRoot ('.safety-fixture-' + [Guid]::NewGuid().ToString('N'))
$script:FixtureToken = [IO.Path]::GetFileName($script:Fixture)
$script:OldUtc = [DateTime]::UtcNow.AddDays(-30)
$script:FreshUtc = [DateTime]::UtcNow
$script:CutoffUtc = [DateTime]::UtcNow.AddDays(-7)

function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ('{0} Expected: {1}; actual: {2}' -f $Message, $Expected, $Actual) }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:Count++
    try { & $Body; Write-Host ('PASS ' + $Name) }
    catch { $script:Failures++; Write-Host ('FAIL {0}: {1}' -f $Name, $_.Exception.Message) -ForegroundColor Red }
}
function Assert-FixturePath {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($script:Fixture)
    if (-not $fullPath.StartsWith(($fullRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Refusing test mutation outside unique fixture: ' + $Path)
    }
    return $fullPath
}
function New-TestDirectory {
    param([string]$RelativePath)
    $testPath = Assert-FixturePath (Join-Path $script:Fixture $RelativePath)
    [IO.Directory]::CreateDirectory($testPath) | Out-Null
    return $testPath
}
function New-TestFile {
    param([string]$RelativePath, [string]$Content = 'cache', [DateTime]$CreationUtc = $script:OldUtc, [DateTime]$WriteUtc = $script:OldUtc)
    $testPath = Assert-FixturePath (Join-Path $script:Fixture $RelativePath)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($testPath)) | Out-Null
    [IO.File]::WriteAllText($testPath, $Content, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::SetCreationTimeUtc($testPath, $CreationUtc)
    [IO.File]::SetLastWriteTimeUtc($testPath, $WriteUtc)
    return Get-Item -LiteralPath $testPath -Force
}
function New-TestTarget {
    param([string]$RelativePath, [int]$MinimumAgeDays = 0, [string]$Filter = '')
    $parameters = @{ Name = $RelativePath; Path = (New-TestDirectory $RelativePath); AllowedRoot = $script:Fixture; MinimumAgeDays = $MinimumAgeDays }
    if ($Filter) { $parameters.Mode = 'FilePattern'; $parameters.Filter = $Filter }
    return New-CacheTarget @parameters
}
function Remove-TestFixture {
    $resolved = [IO.Path]::GetFullPath($script:Fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -ne $script:FixtureToken -or $script:FixtureToken -notmatch '^\.safety-fixture-[a-f0-9]{32}$') {
        throw 'Fixture cleanup root validation failed.'
    }
    if (-not (Test-Path -LiteralPath $resolved)) { return }
    $rootItem = Get-Item -LiteralPath $resolved -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Fixture root became a reparse point.' }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $pending.Push($resolved)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $directories.Add($directory)
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            $validated = Assert-FixturePath $entry.FullName
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                # Delete the junction itself, without recursive traversal.
                if ($entry.PSIsContainer) { [IO.Directory]::Delete($validated, $false) }
                else { [IO.File]::Delete($validated) }
            }
            elseif ($entry.PSIsContainer) { $pending.Push($validated) }
            else { [IO.File]::Delete($validated) }
        }
    }
    foreach ($directory in @($directories | Sort-Object { $_.Length } -Descending)) { [IO.Directory]::Delete($directory, $false) }
}

function Stop-Service { $script:MutationCalls++; throw 'Blocked real Stop-Service.' }
function Start-Service { $script:MutationCalls++; throw 'Blocked real Start-Service.' }
function Stop-Process { $script:MutationCalls++; throw 'Blocked real Stop-Process.' }
function Start-Process { $script:MutationCalls++; throw 'Blocked real Start-Process.' }
function Clear-RecycleBin { $script:MutationCalls++; throw 'Blocked real Clear-RecycleBin.' }
function Delete-DeliveryOptimizationCache { $script:MutationCalls++; throw 'Blocked real delivery-cache mutation.' }
function Remove-Item { $script:MutationCalls++; throw 'Deletion tests require the validated native helper.' }
function Invoke-TestBlockedNative { $script:MutationCalls++; throw 'Blocked native system command in test.' }

try {
    New-Item -Path $script:Fixture -ItemType Directory -ErrorAction Stop | Out-Null
    Test-Case 'all project PowerShell files parse' {
        $sources = @(Get-ChildItem -LiteralPath $projectRoot -Filter '*.ps1' -File)
        $sources += @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)
        foreach ($source in $sources) {
            $tokens = $null; $errors = $null
            [Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$errors) | Out-Null
            Assert-Equal 0 @($errors).Count ('Parse errors in ' + $source.Name + ': ' + ($errors -join '; '))
        }
    }
    . (Join-Path $projectRoot 'CacheCleanup.Common.ps1')

    Test-Case 'drive root and Windows root are rejected' {
        $drive = Get-SystemDriveRoot
        foreach ($path in @($drive, [Environment]::GetFolderPath('Windows'))) {
            $target = New-CacheTarget -Name 'protected' -Path $path -AllowedRoot $drive
            Assert-True (-not (Test-CacheTargetSafety $target).IsSafe) ('Protected path accepted: ' + $path)
        }
    }
    Test-Case 'relative, drive-relative and provider paths are rejected' {
        foreach ($path in @('.\cache', 'C:relative', '\Windows\Temp', 'FileSystem::C:\Windows\Temp')) {
            $target = New-CacheTarget -Name 'relative' -Path $path -AllowedRoot $script:Fixture
            Assert-True (-not (Test-CacheTargetSafety $target).IsSafe) ('Non-absolute path accepted: ' + $path)
        }
    }
    Test-Case 'prefix siblings and parent traversal cannot escape allowed root' {
        $allowed = New-TestDirectory 'bound'
        $outside = New-TestDirectory 'bound-other'
        foreach ($path in @($outside, (Join-Path $allowed '..\bound-other'))) {
            Assert-True (-not (Test-PathWithinRoot -Path $path -Root $allowed)) 'Sibling accepted inside root.'
            $target = New-CacheTarget -Name 'escape' -Path $path -AllowedRoot $allowed
            Assert-True (-not (Test-CacheTargetSafety $target).IsSafe) 'Escaped target accepted.'
        }
    }
    Test-Case 'unrestricted FilePattern is rejected' {
        $target = New-CacheTarget -Name 'wildcard' -Path (New-TestDirectory 'wildcard') -AllowedRoot $script:Fixture -Mode FilePattern -Filter '*'
        Assert-True (-not (Test-CacheTargetSafety $target).IsSafe) 'Unrestricted FilePattern accepted.'
    }
    Test-Case 'file age checks creation and write times despite old parent directory' {
        $target = New-TestTarget 'age' -MinimumAgeDays 7
        $old = New-TestFile 'age\old-parent\old.tmp' 'old'
        New-TestFile 'age\old-parent\fresh-write.tmp' 'new-write' -WriteUtc $script:FreshUtc | Out-Null
        New-TestFile 'age\old-parent\fresh-create.tmp' 'new-create' -CreationUtc $script:FreshUtc | Out-Null
        [IO.Directory]::SetLastWriteTimeUtc((Join-Path $target.Path 'old-parent'), $script:OldUtc)
        $inventory = Get-CacheTargetInventory -Target $target -CutoffUtc $script:CutoffUtc
        Assert-True $inventory.SafeToClean 'Fixture rejected.'
        Assert-True $inventory.MeasurementComplete 'Fixture scan incomplete.'
        Assert-Equal 1 @($inventory.Files).Count 'Wrong eligible file count.'
        Assert-Equal $old.FullName $inventory.Files[0].FullName 'Wrong file selected.'
        Assert-Equal 3 $inventory.SizeBytes 'Retained file bytes counted.'
        Assert-Equal 2 $inventory.RetainedFiles 'Fresh files not counted as retained.'
        Assert-True (-not (@($inventory.Directories) -contains $target.Path)) 'Inventory schedules root directory.'
    }
    Test-Case 'FilePattern selects only matching direct files' {
        $target = New-TestTarget 'filter' -Filter '*.tmp'
        $match = New-TestFile 'filter\selected.tmp'
        New-TestFile 'filter\keep.txt' | Out-Null
        New-TestFile 'filter\nested\keep.tmp' | Out-Null
        $inventory = Get-CacheTargetInventory -Target $target
        Assert-Equal 1 @($inventory.Files).Count 'Nonmatching or nested files selected.'
        Assert-Equal $match.FullName $inventory.Files[0].FullName 'Wrong pattern result.'
        Assert-Equal 0 @($inventory.Directories).Count 'FilePattern schedules directories.'
    }
    Test-Case 'root and ancestor junctions rejected; nested junction skipped' {
        $outside = New-TestDirectory 'external'
        $sentinel = New-TestFile 'external\sentinel.txt' 'DO NOT DELETE'
        New-TestDirectory 'external\child' | Out-Null
        $link = Assert-FixturePath (Join-Path $script:Fixture 'linked-root')
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        foreach ($path in @($link, (Join-Path $link 'child'))) {
            $target = New-CacheTarget -Name 'link' -Path $path -AllowedRoot $script:Fixture
            Assert-True (-not (Test-CacheTargetSafety $target).IsSafe) 'Junction target accepted.'
            Assert-Equal 0 @((Get-CacheTargetInventory $target).Files).Count 'Junction yielded candidates.'
        }
        $target = New-TestTarget 'nested-link'
        New-TestFile 'nested-link\ordinary.tmp' | Out-Null
        New-Item -ItemType Junction -Path (Assert-FixturePath (Join-Path $target.Path 'outside-link')) -Target $outside | Out-Null
        $inventory = Get-CacheTargetInventory $target
        Assert-Equal 1 @($inventory.Files).Count 'Nested junction was followed.'
        Assert-True ($inventory.ReparsePointsSkipped -ge 1) 'Skipped junction not reported.'
        Assert-Equal 'DO NOT DELETE' ([IO.File]::ReadAllText($sentinel.FullName)) 'External sentinel changed.'
    }
    Test-Case 'missing target yields empty complete inventory' {
        $target = New-CacheTarget -Name 'missing' -Path (Join-Path $script:Fixture 'missing') -AllowedRoot $script:Fixture
        $inventory = Get-CacheTargetInventory $target
        Assert-True (-not $inventory.Exists) 'Missing target exists.'
        Assert-Equal 0 @($inventory.Files).Count 'Missing target has files.'
        Assert-True $inventory.MeasurementComplete 'Missing target marked access failure.'
    }
    Test-Case 'Safe excludes aggressive categories and offline web data stays opt-in' {
        $safe = @(Get-CacheTargets -CleanupLevel Safe)
        Assert-Equal 0 @($safe | Where-Object { $_.Category -in @('Browser', 'Developer', 'DownloadedModel') }).Count 'Safe includes aggressive categories.'
        $maximum = @(Get-CacheTargets -CleanupLevel Maximum)
        Assert-Equal 0 @($maximum | Where-Object { $_.Path -like '*Service Worker\CacheStorage' }).Count 'Offline web cache implicitly included.'
        $keys = @($maximum | ForEach-Object { ('{0}|{1}|{2}' -f $_.Path, $_.Mode, $_.Filter).ToLowerInvariant() })
        Assert-Equal $keys.Count @($keys | Select-Object -Unique).Count 'Duplicate targets.'
    }

    if (-not $CommonOnly) {
        $tokens = $null; $errors = $null
        $cleanupAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'Clean-CDriveCache.ps1'), [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { throw 'Cannot load malformed cleanup functions.' }
        foreach ($statement in $cleanupAst.EndBlock.Statements) {
            if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
                $functionText = $statement.Extent.Text
                # Replace native ampersand calls in loaded function copies only.
                # This ensures a broken preview can fail without running DISM/powercfg.
                $nativeCalls = @($statement.FindAll({ param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand
                }, $true) | Sort-Object { $_.Extent.StartOffset } -Descending)
                foreach ($nativeCall in $nativeCalls) {
                    $offset = $nativeCall.Extent.StartOffset - $statement.Extent.StartOffset
                    $functionText = $functionText.Remove($offset, $nativeCall.Extent.Text.Length).Insert($offset, 'Invoke-TestBlockedNative')
                }
                . ([scriptblock]::Create($functionText))
            }
        }
        . (Join-Path $projectRoot 'CacheCleanup.Native.ps1')
        Initialize-CacheNativeCode
        $script:IsAdmin = $false
        $script:PreviewMode = $false
        $script:Scope = 'All'
        $script:RunCutoffUtc = $script:CutoffUtc
        $script:ActiveServiceStates = New-Object 'System.Collections.Generic.List[object]'
        $script:LogWriter = New-Object IO.StringWriter
        function Invoke-TestExecution {
            [CmdletBinding(SupportsShouldProcess = $true)]
            param([pscustomobject]$Target)
            $script:PSCmdlet = $PSCmdlet
            return Invoke-TargetCleanup -Target $Target
        }

        Test-Case 'ordinary old file deletion and exact byte accounting' {
            $target = New-TestTarget 'delete-old' -MinimumAgeDays 7
            $file = New-TestFile 'delete-old\old.tmp' '12345678'
            $outcome = Remove-SafeFileSystemItem -Item $file -Target $target -CutoffUtc $script:CutoffUtc
            Assert-Equal 1 $outcome.Removed 'Old file not deleted.'
            Assert-Equal 8 $outcome.BytesRemoved 'Incorrect deleted byte count.'
            Assert-Equal 0 $outcome.Failed 'Ordinary delete failed.'
            Assert-True (-not [IO.File]::Exists($file.FullName)) 'Deleted file exists.'
            Assert-True ([IO.Directory]::Exists($target.Path)) 'Target root was deleted.'
        }
        Test-Case 'newly created or written file survives under old directory' {
            $target = New-TestTarget 'delete-age' -MinimumAgeDays 7
            $write = New-TestFile 'delete-age\old-parent\new-write.tmp' 'write' -WriteUtc $script:FreshUtc
            $create = New-TestFile 'delete-age\old-parent\new-create.tmp' 'create' -CreationUtc $script:FreshUtc
            [IO.Directory]::SetLastWriteTimeUtc((Join-Path $target.Path 'old-parent'), $script:OldUtc)
            foreach ($file in @($write, $create)) {
                $outcome = Remove-SafeFileSystemItem -Item $file -Target $target -CutoffUtc $script:CutoffUtc
                Assert-Equal 0 $outcome.Removed 'Fresh file deleted.'
                Assert-True ([IO.File]::Exists($file.FullName)) 'Fresh file missing.'
            }
        }
        Test-Case 'out-of-target file rejected by deletion helper' {
            $target = New-TestTarget 'delete-bound'
            $outside = New-TestFile 'delete-bound-other\sentinel.txt' 'KEEP'
            $outcome = Remove-SafeFileSystemItem -Item $outside -Target $target
            Assert-Equal 0 $outcome.Removed 'Outside file deleted.'
            Assert-True ($outcome.Failed -gt 0) 'Outside path rejection not reported.'
            Assert-Equal 'KEEP' ([IO.File]::ReadAllText($outside.FullName)) 'Outside sentinel changed.'
        }
        Test-Case 'deletion helper rechecks FilePattern' {
            $target = New-TestTarget 'delete-filter' -Filter '*.tmp'
            $file = New-TestFile 'delete-filter\keep.txt' 'KEEP'
            $outcome = Remove-SafeFileSystemItem -Item $file -Target $target
            Assert-Equal 0 $outcome.Removed 'Nonmatching file deleted.'
            Assert-True ([IO.File]::Exists($file.FullName)) 'Nonmatching file missing.'
        }
        Test-Case 'locked file survives and failure is reported' {
            $target = New-TestTarget 'delete-locked'
            $file = New-TestFile 'delete-locked\locked.tmp' 'LOCKED'
            $handle = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                $outcome = Remove-SafeFileSystemItem -Item $file -Target $target
                Assert-Equal 0 $outcome.Removed 'Locked file reported deleted.'
                Assert-True ($outcome.Failed -gt 0) 'Locked-file error hidden.'
                Assert-True ([IO.File]::Exists($file.FullName)) 'Locked file missing.'
            }
            finally { $handle.Dispose() }
        }
        Test-Case 'nonempty directory retained, empty child removed, root rejected' {
            $target = New-TestTarget 'delete-directory'
            $file = New-TestFile 'delete-directory\nonempty\keep.txt' 'KEEP'
            $emptyPath = New-TestDirectory 'delete-directory\empty'
            $nonempty = Get-Item -LiteralPath (Split-Path -Parent $file.FullName)
            $outcome = Remove-SafeFileSystemItem -Item $nonempty -Target $target
            Assert-Equal 0 $outcome.Removed 'Nonempty directory was recursively removed.'
            Assert-Equal 'KEEP' ([IO.File]::ReadAllText($file.FullName)) 'Child file changed.'
            $outcome = Remove-SafeFileSystemItem -Item (Get-Item -LiteralPath $emptyPath) -Target $target
            Assert-Equal 1 $outcome.Removed 'Empty directory not removed.'
            $outcome = Remove-SafeFileSystemItem -Item (Get-Item -LiteralPath $target.Path) -Target $target
            Assert-Equal 0 $outcome.Removed 'Target root removed.'
            Assert-True ($outcome.Failed -gt 0) 'Root rejection not reported.'
        }
        Test-Case 'target cleanup removes old file but retains recent children' {
            $target = New-TestTarget 'integration-age' -MinimumAgeDays 7
            $old = New-TestFile 'integration-age\old-parent\old.tmp' 'OLD'
            $fresh = New-TestFile 'integration-age\old-parent\new.tmp' 'FRESH' -WriteUtc $script:FreshUtc
            [IO.Directory]::SetLastWriteTimeUtc((Join-Path $target.Path 'old-parent'), $script:OldUtc)
            $outcome = Invoke-TestExecution -Target $target -Confirm:$false
            Assert-Equal 'CleanedWithRetained' $outcome.Status 'Retained parent directory was not reported.'
            Assert-True ($outcome.RetainedItems -gt 0) 'Retained directory count missing.'
            Assert-Equal 3 $outcome.ReclaimedBytes 'Reclaimed size includes retained files.'
            Assert-True (-not [IO.File]::Exists($old.FullName)) 'Old file was retained.'
            Assert-Equal 'FRESH' ([IO.File]::ReadAllText($fresh.FullName)) 'Fresh child was changed.'
        }
        Test-Case 'file changed after inventory is retained with accurate mixed result' {
            $target = New-TestTarget 'integration-changed' -MinimumAgeDays 7
            $old = New-TestFile 'integration-changed\old.tmp' 'OLD'
            $changed = New-TestFile 'integration-changed\changed.tmp' 'NEW'
            $script:ChangedFilePath = Assert-FixturePath $changed.FullName
            $script:BusyChecks = 0
            function Get-TargetBusyReason {
                $script:BusyChecks++
                if ($script:BusyChecks -eq 2) { [IO.File]::SetLastWriteTimeUtc($script:ChangedFilePath, $script:FreshUtc) }
                return ''
            }
            $outcome = Invoke-TestExecution -Target $target -Confirm:$false
            Assert-Equal 'CleanedWithRetained' $outcome.Status 'Changed candidate was hidden by Cleaned status.'
            Assert-Equal 1 $outcome.RetainedItems 'Changed candidate not counted as retained.'
            Assert-Equal 6 $outcome.CandidateBytes 'Initial inventory size incorrect.'
            Assert-Equal 3 $outcome.ReclaimedBytes 'Retained candidate counted as reclaimed.'
            Assert-True (-not [IO.File]::Exists($old.FullName)) 'Unchanged old candidate not deleted.'
            Assert-Equal 'NEW' ([IO.File]::ReadAllText($changed.FullName)) 'Changed candidate was deleted.'
        }
        Test-Case 'fresh empty-directory replacement survives stale directory metadata' {
            $target = New-TestTarget 'directory-race' -MinimumAgeDays 7
            $directory = New-TestDirectory 'directory-race\child'
            [IO.Directory]::SetCreationTimeUtc($directory, $script:OldUtc)
            [IO.Directory]::SetLastWriteTimeUtc($directory, $script:OldUtc)
            $stale = Get-Item -LiteralPath $directory
            Assert-True ($stale.CreationTimeUtc -lt $script:CutoffUtc) 'Directory fixture is not old.'
            Assert-True ($stale.LastWriteTimeUtc -lt $script:CutoffUtc) 'Directory fixture write time is not old.'
            [IO.Directory]::Delete((Assert-FixturePath $directory), $false)
            [IO.Directory]::CreateDirectory((Assert-FixturePath $directory)) | Out-Null
            [IO.Directory]::SetCreationTimeUtc($directory, $script:FreshUtc)
            $outcome = Remove-SafeFileSystemItem -Item $stale -Target $target -CutoffUtc $script:CutoffUtc
            Assert-Equal 0 $outcome.Removed 'Fresh replacement empty directory deleted.'
            Assert-True ([IO.Directory]::Exists($directory)) 'Replacement empty directory missing.'
        }
        Test-Case 'active writer prevents deletion even when it permits shared deletion' {
            $target = New-TestTarget 'delete-writer'
            $file = New-TestFile 'delete-writer\writer.tmp' 'WRITER'
            $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $handle = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, $sharing)
            try {
                $outcome = Remove-SafeFileSystemItem -Item $file -Target $target
                Assert-Equal 0 $outcome.Removed 'Actively writable file deleted.'
                Assert-True ($outcome.Failed -gt 0) 'Active writer conflict not reported.'
                Assert-True ([IO.File]::Exists($file.FullName)) 'Active writer file missing.'
            }
            finally { $handle.Dispose() }
        }
        Test-Case 'junction replacement after inventory protects outside sentinel' {
            $target = New-TestTarget 'delete-race'
            $stale = New-TestFile 'delete-race\child\old.tmp' 'inside'
            $outside = New-TestDirectory 'delete-race-outside'
            $sentinel = New-TestFile 'delete-race-outside\old.tmp' 'OUTSIDE'
            $child = Assert-FixturePath (Join-Path $target.Path 'child')
            [IO.File]::Delete((Assert-FixturePath $stale.FullName))
            [IO.Directory]::Delete($child, $false)
            New-Item -ItemType Junction -Path $child -Target $outside | Out-Null
            $outcome = Remove-SafeFileSystemItem -Item $stale -Target $target
            Assert-Equal 0 $outcome.Removed 'Replacement junction followed.'
            Assert-Equal 'OUTSIDE' ([IO.File]::ReadAllText($sentinel.FullName)) 'Outside sentinel changed.'
        }

        foreach ($serviceScenario in @('StopFailure', 'RestoreFailure', 'LogFailure')) {
            Test-Case ('service transaction safely handles ' + $serviceScenario) {
                $target = New-TestTarget ('service-' + $serviceScenario)
                $target.RequiresAdmin = $true
                $target.ServicesToStop = @('FixtureService')
                $file = New-TestFile (('service-' + $serviceScenario) + '\sentinel.tmp') 'SERVICE'
                $script:IsAdmin = $true
                $script:ActiveServiceStates.Clear()
                $script:FakeService = [pscustomobject]@{ Name='FixtureService'; Status='Running'; DependentServices=@() }
                $script:FakeService | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
                $script:FakeService | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
                    param($Desired, $Timeout)
                    if ($this.Status -ne $Desired) { throw 'Simulated service did not reach requested state.' }
                }
                $script:ServiceStops = 0
                $script:ServiceStarts = 0
                function Get-Service { return $script:FakeService }
                function Get-ServicingBlockReason { return '' }
                function Stop-Service {
                    $script:ServiceStops++
                    if ($serviceScenario -eq 'StopFailure') { throw 'Simulated stop failure.' }
                    $script:FakeService.Status = 'Stopped'
                }
                function Start-Service {
                    $script:ServiceStarts++
                    if ($serviceScenario -eq 'RestoreFailure') { throw 'Simulated restore failure.' }
                    $script:FakeService.Status = 'Running'
                }
                function Write-Log {
                    param([string]$Message, [string]$Level)
                    if ($serviceScenario -eq 'LogFailure' -and $script:FakeService.Status -eq 'Stopped') {
                        throw 'Simulated log write failure after stopping service.'
                    }
                }
                try {
                    $threw = $false
                    $outcome = $null
                    try { $outcome = Invoke-TestExecution -Target $target -Confirm:$false }
                    catch { $threw = $true }
                    Assert-Equal 1 $script:ServiceStops 'Stop gateway was not exercised.'
                    if ($serviceScenario -eq 'StopFailure') {
                        Assert-True (-not $threw) 'Stop failure unexpectedly escaped.'
                        Assert-Equal 'ServiceStopFailed' $outcome.Status 'Stop failure was not reported.'
                        Assert-Equal 'SERVICE' ([IO.File]::ReadAllText($file.FullName)) 'Cleanup ran after stop failure.'
                        Assert-Equal 'Running' $script:FakeService.Status 'Previously running service left stopped.'
                    }
                    elseif ($serviceScenario -eq 'RestoreFailure') {
                        Assert-True (-not $threw) 'Restore failure unexpectedly escaped.'
                        Assert-Equal 'ServiceRestoreFailed' $outcome.Status 'Restore failure was hidden.'
                        Assert-Equal 1 $script:ServiceStarts 'Restore gateway not attempted.'
                        Assert-True ($script:ActiveServiceStates.Count -gt 0) 'Failed restoration lost recovery state.'
                    }
                    else {
                        Assert-True $threw 'Log failure was swallowed.'
                        Assert-Equal 1 $script:ServiceStarts 'Finally did not restore service after log failure.'
                        Assert-Equal 'Running' $script:FakeService.Status 'Service left stopped after log failure.'
                        Assert-Equal 'SERVICE' ([IO.File]::ReadAllText($file.FullName)) 'Cleanup ran after log failure.'
                    }
                }
                finally { $script:IsAdmin = $false; $script:ActiveServiceStates.Clear() }
            }
        }

        function Remove-SafeFileSystemItem { $script:MutationCalls++; throw 'Preview reached file deletion.' }
        function Stop-RequiredServices { $script:MutationCalls++; throw 'Preview reached service changes.' }
        function Restore-ServiceStates { $script:MutationCalls++; throw 'Preview reached service restoration.' }
        function Invoke-TestPreview {
            [CmdletBinding(SupportsShouldProcess = $true)]
            param([pscustomobject]$Target, [switch]$DryRun)
            $script:PreviewMode = $DryRun.IsPresent -or [bool]$WhatIfPreference
            $script:PSCmdlet = $PSCmdlet
            return Invoke-TargetCleanup -Target $Target
        }
        Test-Case 'entry point connects DryRun and WhatIf to preview mode' {
            $assignments = @($cleanupAst.FindAll({ param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:PreviewMode'
            }, $true))
            Assert-True ($assignments.Count -ge 1) 'Preview assignment missing.'
            $assignment = $assignments[0].Right.Extent.Text
            Assert-True ($assignment -match '\$DryRun' -and $assignment -match '\$WhatIfPreference' -and $assignment -match '-or') 'Preview flags not both wired.'
        }
        foreach ($previewMode in @('DryRun', 'WhatIf')) {
            Test-Case ($previewMode + ' invokes zero mutation gateways') {
                function Get-ServicingBlockReason { return '' }
                $target = New-TestTarget ('preview-' + $previewMode)
                $target.ServicesToStop = @('NeverTouchRealService')
                $file = New-TestFile (('preview-' + $previewMode) + '\sentinel.tmp') 'PREVIEW'
                $script:MutationCalls = 0
                $parameters = @{ Target = $target }
                $parameters[$previewMode] = $true
                $outcome = Invoke-TestPreview @parameters
                Assert-Equal 'Preview' $outcome.Status 'Wrong preview status.'
                Assert-Equal 0 $script:MutationCalls 'Preview invoked a mutation gateway.'
                Assert-Equal 'PREVIEW' ([IO.File]::ReadAllText($file.FullName)) 'Preview changed sentinel.'
            }
        }
        Test-Case 'preview with skipped junction reports PreviewPartial without mutation' {
            $target = New-TestTarget 'preview-link'
            $outside = New-TestDirectory 'preview-link-outside'
            $sentinel = New-TestFile 'preview-link-outside\sentinel.tmp' 'OUTSIDE'
            New-TestFile 'preview-link\ordinary.tmp' | Out-Null
            New-Item -ItemType Junction -Path (Assert-FixturePath (Join-Path $target.Path 'link')) -Target $outside | Out-Null
            $script:MutationCalls = 0
            $outcome = Invoke-TestPreview -Target $target -DryRun
            Assert-Equal 'PreviewPartial' $outcome.Status 'Skipped junction hidden in ordinary Preview status.'
            Assert-True ($outcome.ReparsePointsSkipped -gt 0) 'Skipped junction count missing.'
            Assert-Equal 0 $script:MutationCalls 'Preview invoked mutation gateway.'
            Assert-Equal 'OUTSIDE' ([IO.File]::ReadAllText($sentinel.FullName)) 'Outside sentinel changed.'
        }
        Test-Case 'optional-action preview invokes no native/process/service mutation' {
            $script:PreviewMode = $true
            $script:IsAdmin = $true
            $script:MutationCalls = 0
            $Scope = 'All'
            $CleanupLevel = 'Maximum'
            $RunDismComponentCleanup = $true
            $ResetComponentBase = $true
            $RemovePreviousWindowsInstallation = $true
            $HibernationMode = 'Reduced'
            $IncludeRecycleBin = $true
            $SkipRecycleBin = $false
            $IncludePinnedDeliveryFiles = $true
            $StopBrowserProcesses = $true
            $ForceCloseBrowserProcesses = $true
            function Get-RecycleBinMeasurement {
                return [pscustomobject]@{ SafeToClean=$true; MeasurementComplete=$true; Exists=$true; SizeBytes=4096; SafetyReason='' }
            }
            function Get-DeliveryOptimizationPerfSnap {
                return [pscustomobject]@{ CacheSizeBytes=4096; ForegroundDownloadsPending=0; BackgroundDownloadsPending=0; ForegroundDownloadCount=0; BackgroundDownloadCount=0 }
            }
            function Get-CurrentSessionBrowserProcesses {
                $fake = [pscustomobject]@{ Id=-1234; ProcessName='fixture-browser'; HasExited=$false; MainWindowHandle=1 }
                $fake | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $script:MutationCalls++; throw 'Preview attempted browser close.' }
                $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { throw 'Preview attempted process wait.' }
                return $fake
            }
            foreach ($action in @('Invoke-RecycleBinCleanup', 'Invoke-DismCleanup', 'Invoke-HibernationChange', 'Invoke-PreviousWindowsCleanup')) {
                $outcome = & $action
                Assert-Equal 'Preview' $outcome.Status ('Optional action did not preview: ' + $action)
            }
            $outcome = Invoke-DeliveryOptimizationCleanup
            Assert-True ($outcome.Status -in @('Preview', 'SkippedScope')) 'Delivery preview failed.'
            Handle-BrowserProcesses -BrowserTargetsExist $true
            Assert-Equal 0 $script:MutationCalls 'Optional preview invoked a mutation gateway.'
            $script:IsAdmin = $false
        }
        Test-Case 'failed post-recycle measurement reports unknown reclamation' {
            $script:PreviewMode = $false
            $script:RecycleMeasureCalls = 0
            $script:FakeRecycleClears = 0
            $Scope = 'User'
            $IncludeRecycleBin = $true
            $SkipRecycleBin = $false
            function Get-RecycleBinMeasurement {
                $script:RecycleMeasureCalls++
                if ($script:RecycleMeasureCalls -eq 1) {
                    return [pscustomobject]@{ SafeToClean=$true; MeasurementComplete=$true; Exists=$true; SizeBytes=4096; SafetyReason='' }
                }
                return [pscustomobject]@{ SafeToClean=$false; MeasurementComplete=$false; Exists=$false; SizeBytes=0; SafetyReason='Simulated post-clear access failure.' }
            }
            function Clear-RecycleBin { $script:FakeRecycleClears++ }
            function Invoke-TestRecycle {
                [CmdletBinding(SupportsShouldProcess = $true)]
                param()
                $script:PSCmdlet = $PSCmdlet
                return Invoke-RecycleBinCleanup
            }
            try {
                $outcome = Invoke-TestRecycle -Confirm:$false
                Assert-Equal 1 $script:FakeRecycleClears 'Fake clear gateway not exercised exactly once.'
                Assert-Equal 2 $script:RecycleMeasureCalls 'Post-clear measurement was not attempted.'
                Assert-Equal 'ScanFailed' $outcome.Status 'Post-clear measurement failure was hidden.'
                Assert-Equal 4096 $outcome.CandidateBytes 'Initial candidate amount was lost.'
                Assert-Equal 0 $outcome.ReclaimedBytes 'Unknown reclaimed bytes incorrectly reported as recovered.'
                Assert-True ($outcome.Notes -match 'unknown') 'Report does not explain unknown reclaimed amount.'
            }
            finally { $script:PreviewMode = $true }
        }
        $script:LogWriter.Dispose()
    }
}
catch { $script:Failures++; Write-Host ('TEST HARNESS ERROR: ' + $_.Exception.Message) -ForegroundColor Red }
finally {
    try { Remove-TestFixture }
    catch { $script:Failures++; Write-Host ('Fixture retained after safe cleanup failure: {0}; {1}' -f $script:Fixture, $_.Exception.Message) -ForegroundColor Red }
}
Write-Host ('PowerShell {0}: {1} checks, {2} failure(s).' -f $PSVersionTable.PSVersion, $script:Count, $script:Failures)
if ($script:Failures -gt 0) { exit 1 }
exit 0

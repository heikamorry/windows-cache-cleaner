#Requires -Version 5.1
# Backward-compatible entry point; the regression suite no longer needs Pester.
[CmdletBinding()]
param()

& (Join-Path $PSScriptRoot 'Invoke-SafetyTests.ps1') -CommonOnly
exit $LASTEXITCODE

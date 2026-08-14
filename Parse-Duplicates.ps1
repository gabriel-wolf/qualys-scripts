function Parse-Duplicates {
    param (
        [string]$CsvPath = "$PSScriptRoot\export.csv"
    )

    if (-not (Test-Path $CsvPath)) {
        $FallbackCsv = Get-ChildItem -Path $PSScriptRoot -Filter "*.csv" | Select-Object -First 1
        if ($FallbackCsv) {
            $CsvPath = $FallbackCsv.FullName
        } else {
            Write-Host "[ERROR] Could not find any CSV at: $CsvPath" -ForegroundColor Red
            return @()
        }
    }

    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "PARSING CSV: EXACT ASSET NAME MATCHING ONLY" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    $RawAssets = Import-Csv -Path $CsvPath
    Write-Host "[LOADED] Total rows read from CSV ($($CsvPath)): $($RawAssets.Count)" -ForegroundColor Gray

    # PASS 1: CACHE EXACT ASSET NAMES THAT HAVE AN AGENT ID
    $AgentExactNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Row in $RawAssets) {
        $AgentId = $Row.'Agent ID'
        $Name    = $Row.'Asset Name'

        if (-not [string]::IsNullOrWhiteSpace($AgentId) -and -not [string]::IsNullOrWhiteSpace($Name)) {
            [void]$AgentExactNames.Add($Name.Trim())
        }
    }

    Write-Host "[AGENT MAP CREATED] Cached $($AgentExactNames.Count) unique exact Cloud Agent Asset Names" -ForegroundColor Gray

    # PASS 2: MATCH NON-AGENT ROWS BY EXACT ASSET NAME ONLY
    $PurgeList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $IndexCounter = 0

    foreach ($Row in $RawAssets) {
        $AgentId = $Row.'Agent ID'
        $AssetId = $Row.'Asset ID'
        $HostId  = $Row.'Host ID'
        $Name    = $Row.'Asset Name'

        if ([string]::IsNullOrWhiteSpace($AgentId) -and -not [string]::IsNullOrWhiteSpace($Name)) {
            $ExactName = $Name.Trim()

            if ($AgentExactNames.Contains($ExactName)) {
                $IndexCounter++
                $PurgeList.Add([PSCustomObject]@{
                    OriginalIndex = $IndexCounter
                    AssetID       = if ($AssetId) { $AssetId.Trim() } else { $null }
                    HostID        = if ($HostId)  { $HostId.Trim() }  else { $null }
                    AssetName     = $ExactName
                })
            }
        }
    }

    # STATS & PREVIEW
    Write-Host "[SUCCESS] $($PurgeList.Count) EXACT MATCH DUPLICATES IDENTIFIED`n" -ForegroundColor Green

    if ($PurgeList.Count -gt 0) {
        Write-Host "--- FIRST 3 CANDIDATES ---" -ForegroundColor DarkCyan
        $First3 = $PurgeList | Select-Object -First 3
        foreach ($Item in $First3) {
            Write-Host "  [#$($Item.OriginalIndex)] AssetID: $($Item.AssetID) | HostID: $($Item.HostID) | Name: $($Item.AssetName)" -ForegroundColor Gray
        }

        if ($PurgeList.Count -gt 3) {
            Write-Host "`n--- LAST 3 CANDIDATES ---" -ForegroundColor DarkCyan
            $Last3 = $PurgeList | Select-Object -Last 3
            foreach ($Item in $Last3) {
                Write-Host "  [#$($Item.OriginalIndex)] AssetID: $($Item.AssetID) | HostID: $($Item.HostID) | Name: $($Item.AssetName)" -ForegroundColor Gray
            }
        }
        Write-Host ""
    }

    return $PurgeList
}

# --- STANDALONE TEST RUNNER ---
if ($MyInvocation.InvocationName -ne '.') {
    $TestResults = Parse-Duplicates
}

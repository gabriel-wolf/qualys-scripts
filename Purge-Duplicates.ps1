[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CONFIGURATION ---
$QualysUsername = "<qualys-api-username>"
$QualysPlatform = "<qualysapi.qualys.com?"
$SecretPath = "<path-to-secret-enc>"
$ParserScript   = "$PSScriptRoot\Parse-Duplicates.ps1"
$RandomizeOrder = $true  

# --- IMPORT PARSER FUNCTION ---
if (-not (Test-Path $ParserScript)) {
    Throw "Error: Missing dependency $ParserScript."
}
. $ParserScript # Dot-source Parse-Duplicates.ps1

# --- RUN PARSER TO GET CANDIDATES ---
$TargetsToPurge = Parse-Duplicates
$TotalCount     = $TargetsToPurge.Count

if ($TotalCount -eq 0) {
    Write-Host "[FINISHED] No valid purge candidates found. Exiting." -ForegroundColor Yellow
    exit
}

# --- SHUFFLE LIST IN MAIN SCRIPT IF ENABLED ---
if ($RandomizeOrder) {
    Write-Host "[RANDOMIZING] Shuffling list order..." -ForegroundColor Yellow
    $TargetsToPurge = $TargetsToPurge | Get-Random -Count $TotalCount
}

# --- LOAD CREDENTIALS ---
if (-not (Test-Path $SecretPath)) {
    Throw "Error: Encrypted Qualys key not found at $SecretPath."
}

try {
    $QualysPassword = Get-Content -Path $SecretPath | ConvertTo-SecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($QualysPassword)
    $PlaintextQualysKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
} catch {
    Throw "Decryption Failed for user: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
}

# --- AUTH HEADERS ---
$BasicAuthString = [System.Text.Encoding]::UTF8.GetBytes("${QualysUsername}:${PlaintextQualysKey}")
$BasicAuthBase64 = [System.Convert]::ToBase64String($BasicAuthString)
$Headers = @{ 
    'Authorization'    = "Basic $BasicAuthBase64"
    'X-Requested-With' = "QualysAutomation"
}

$AmSearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/asset"
$AmDeleteURL = "https://$QualysPlatform/qps/rest/2.0/delete/am/asset/"

# --- PROCESS PURGES ---
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "STARTING EXECUTION FOR $TotalCount CANDIDATES (SHUFFLED: $RandomizeOrder)" -ForegroundColor Cyan
Write-Host "=========================================================`n" -ForegroundColor Cyan

$CurrentProgress = 0

foreach ($Target in $TargetsToPurge) {
    $CurrentProgress++
    $OrigIndex = $Target.OriginalIndex
    $AssetId   = $Target.AssetID
    $HostId    = $Target.HostID
    $Name      = $Target.AssetName

    Write-Host "[$CurrentProgress/$TotalCount] (Orig #$OrigIndex) Target: $Name (Asset ID: $AssetId | Host ID: $HostId)" -ForegroundColor Green

    # -------------------------------------------------------------------
    # REAL-TIME LIVE API CHECK: Query CSAM Search API for Agent Status
    # -------------------------------------------------------------------
    Write-Host " -> Verifying live Agent status via CSAM API (Asset ID: $AssetId)..." -ForegroundColor Gray
    
    $IsAgentPresent = $false
    $CheckPassed    = $false

    $SearchPayload = "<ServiceRequest><filters><Criteria field=`"id`" operator=`"EQUALS`">$AssetId</Criteria></filters></ServiceRequest>"

    try {
        $SearchResponse = Invoke-WebRequest -Uri $AmSearchURL `
                                           -Method "Post" `
                                           -Headers $Headers `
                                           -ContentType "text/xml" `
                                           -Body $SearchPayload `
                                           -ErrorAction Stop

        [xml]$AssetXml = $SearchResponse.Content
        $AssetRecord   = $AssetXml.ServiceResponse.data.Asset
        $AgentInfoNode = $AssetRecord.agentInfo

        # Verify if live CSAM object has an active agentId attached
        if ($null -ne $AgentInfoNode -and (-not [string]::IsNullOrWhiteSpace($AgentInfoNode.agentId))) {
            $IsAgentPresent = $true
        }

        $CheckPassed = $true
    }
    catch {
        Write-Host " [SAFETY SKIPPED] Live CSAM API search failed ($($_.Exception.Message)). Aborting purge for safety." -ForegroundColor Red
        Write-Host "---------------------------------------------------------" -ForegroundColor Gray
        continue
    }

    # SAFETY BLOCK: ABORT PURGE IF AGENT IS DETECTED LIVE
    if ($IsAgentPresent) {
        Write-Host " [SAFETY SKIPPED] Asset ID $AssetId has an active Cloud Agent live in Qualys! Aborting purge." -ForegroundColor Red
        Write-Host "---------------------------------------------------------" -ForegroundColor Gray
        continue
    }

    # -------------------------------------------------------------------
    # EXECUTE ASSET MANAGEMENT DELETE
    # -------------------------------------------------------------------
    if ($CheckPassed -and -not $IsAgentPresent) {
        Write-Host " -> API confirmed NO live Agent present. Executing Asset Management Delete..." -ForegroundColor Yellow

        $AmDeletePayload = "<ServiceRequest><filters><Criteria field=`"id`" operator=`"EQUALS`">$AssetId</Criteria></filters></ServiceRequest>"

        try {
            $DeleteResponse = Invoke-WebRequest -Uri $AmDeleteURL `
                                                -Method "Post" `
                                                -Headers $Headers `
                                                -ContentType "text/xml" `
                                                -Body $AmDeletePayload `
                                                -ErrorAction Stop

            Write-Host " [AM DELETED] Asset ID $AssetId ($Name) successfully deleted!" -ForegroundColor Green
        }
        catch {
            Write-Host " [AM DELETE FAILED] Could not delete AM Asset $AssetId : $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host "---------------------------------------------------------" -ForegroundColor Gray
}

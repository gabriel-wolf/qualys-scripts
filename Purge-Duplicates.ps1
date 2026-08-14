[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CONFIGURATION ---
$QualysUsername = "<qualys-api-username>"
$QualysPlatform = "<qualysapi.qualys.com?"
$SecretPath = "<path-to-secret-enc>"
$ParserScript   = "$PSScriptRoot\Get-Duplicates.ps1"

# --- IMPORT PARSER FUNCTION ---
if (-not (Test-Path $ParserScript)) {
    Throw "Error: Missing dependency $ParserScript."
}
. $ParserScript # Dot-source Get-Duplicates.ps1

# --- RUN PARSER TO GET FILTERED CANDIDATES ---
$TargetsToPurge = Get-Duplicates
$TotalCount     = $TargetsToPurge.Count

if ($TotalCount -eq 0) {
    Write-Host "[FINISHED] No valid purge candidates found. Exiting." -ForegroundColor Yellow
    exit
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

$VmHostInfoURL = "https://$QualysPlatform/api/2.0/fo/asset/host/"
$VmPurgeURL    = "https://$QualysPlatform/api/2.0/fo/asset/host/"
$AmDeleteURL   = "https://$QualysPlatform/qps/rest/2.0/delete/am/asset/"

# --- PROCESS PURGES ---
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "STARTING EXECUTION FOR $TotalCount EXACT DUPLICATE CANDIDATES" -ForegroundColor Cyan
Write-Host "=========================================================`n" -ForegroundColor Cyan

$CurrentLine = 0

foreach ($Target in $TargetsToPurge) {
    $CurrentLine++
    $AssetId = $Target.AssetID
    $HostId  = $Target.HostID
    $Name    = $Target.AssetName

    # PATH A: Direct VM Host ID Purge
    if (-not [string]::IsNullOrWhiteSpace($HostId)) {
        Write-Host "[$CurrentLine/$TotalCount] Target: $Name (Asset ID: $AssetId | Host ID: $HostId)" -ForegroundColor Green
        
        # -------------------------------------------------------------------
        # REAL-TIME API DOUBLE CHECK: Verify Host ID has no agent live in Qualys
        # -------------------------------------------------------------------
        Write-Host " -> Verifying live Agent status via API for Host ID $HostId..." -ForegroundColor Gray
        
        $VerifyUrl = "${VmHostInfoURL}?action=list&ids=${HostId}&details=All"
        $IsAgentPresent = $false
        
        try {
            [xml]$HostXml = Invoke-RestMethod -Uri $VerifyUrl -Headers $Headers -Method Get -ErrorAction Stop
            
            $TrackingMethod = $HostXml.HOST_LIST_OUTPUT.RESPONSE.HOST_LIST.HOST.TRACKING_METHOD
            $AgentInfo      = $HostXml.HOST_LIST_OUTPUT.RESPONSE.HOST_LIST.HOST.AGENT_INFO

            if ($TrackingMethod -eq "AGENTS" -or $null -ne $AgentInfo) {
                $IsAgentPresent = $true
            }
        }
        catch {
            Write-Host " [WARNING] Could not verify live status via API ($($_.Exception.Message)). Proceeding with caution..." -ForegroundColor Yellow
        }

        # SAFETY BLOCK: If API reports an Agent is linked, SKIP IT!
        if ($IsAgentPresent) {
            Write-Host " [SAFETY SKIPPED] Host ID $HostId has an active Cloud Agent attached in Qualys! Skipping purge." -ForegroundColor Red
            Write-Host "---------------------------------------------------------" -ForegroundColor Gray
            continue
        }

        # -------------------------------------------------------------------
        # EXECUTE PURGE
        # -------------------------------------------------------------------
        Write-Host " -> API confirmed NO Agent present. Executing True VM Purge..." -ForegroundColor Yellow

        $PurgeBody = @{
            "action"       = "purge"
            "ids"          = $HostId
            "echo_request" = "0"
        }

        try {
            $PurgeResponse = Invoke-WebRequest -Uri $VmPurgeURL `
                                               -Method "Post" `
                                               -Headers $Headers `
                                               -Body $PurgeBody `
                                               -ErrorAction Stop

            Write-Host " [VM PURGED] Host ID $HostId ($Name) permanently purged!" -ForegroundColor Green
        }
        catch {
            Write-Host " [PURGE FAILED] Could not purge Host ID $HostId : $($_.Exception.Message)" -ForegroundColor Red
        }

    # PATH B: Direct AM Asset Delete (Fallback for DNS-only shells missing a VM Host ID)
    } elseif (-not [string]::IsNullOrWhiteSpace($AssetId)) {
        Write-Host "[$CurrentLine/$TotalCount] Target: $Name (Asset ID: $AssetId | Host ID: NONE)" -ForegroundColor Yellow
        Write-Host " -> No Host ID present. Executing Asset Management Delete..." -ForegroundColor Yellow

        $AmDeletePayload = "<ServiceRequest><filters><Criteria field=`"id`" operator=`"EQUALS`">$AssetId</Criteria></filters></ServiceRequest>"

        try {
            $DeleteResponse = Invoke-WebRequest -Uri $AmDeleteURL `
                                                -Method "Post" `
                                                -Headers $Headers `
                                                -ContentType "text/xml" `
                                                -Body $AmDeletePayload `
                                                -ErrorAction Stop

            Write-Host " [AM DELETED] Asset ID $AssetId ($Name) deleted from Asset Management!" -ForegroundColor Green
        }
        catch {
            Write-Host " [DELETE FAILED] Could not delete AM Asset $AssetId : $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host "---------------------------------------------------------" -ForegroundColor Gray
}

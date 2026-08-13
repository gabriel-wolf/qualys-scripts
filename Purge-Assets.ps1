[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CONFIGURATION ---
$QualysUsername = "<qualys-api-username>"
$QualysPlatform = "<qualysapi.qualys.com?"
$SecretPath = "<path-to-secret-enc>"

$TxtFilePath = "$PSScriptRoot\AssetIDs.txt"

# --- READ FILE & VERIFY ---
if (-not (Test-Path $TxtFilePath)) {
    Throw "Error: Could not find $TxtFilePath. Please make sure the file exists in this directory."
}

$TargetAssetIds = Get-Content -Path $TxtFilePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

Write-Host "[LOADED] Found $($TargetAssetIds.Count) Asset IDs in $TxtFilePath" -ForegroundColor Cyan

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

$SearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/asset"
$PurgeURL  = "https://$QualysPlatform/api/2.0/fo/asset/host/"

# --- PROCESS ASSET IDs ---
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "PROCESSING PURGE FOR $( $TargetAssetIds.Count ) ASSETS FROM FILE" -ForegroundColor Cyan
Write-Host "=========================================================`n" -ForegroundColor Cyan

foreach ($AssetId in $TargetAssetIds) {
    # Trim any leftover whitespace from line reads
    $CleanId = $AssetId.Trim()

    $SearchPayload = "<ServiceRequest><filters><Criteria field=`"id`" operator=`"EQUALS`">$CleanId</Criteria></filters></ServiceRequest>"

    try {
        # 1. SEARCH / SAFETY CHECK
        $Response = Invoke-WebRequest -Uri $SearchURL `
                                      -Method "Post" `
                                      -Headers $Headers `
                                      -ContentType "text/xml" `
                                      -Body $SearchPayload `
                                      -ErrorAction Stop

        [xml]$XmlResult = $Response.Content
        $AssetNode = $XmlResult.SelectSingleNode("//Asset")

        if ($AssetNode) {
            $Name    = $AssetNode.SelectSingleNode("name").InnerText
            $IP      = $AssetNode.SelectSingleNode(".//address | .//HostInterface/address").InnerText
            $AgentId = $AssetNode.SelectSingleNode(".//agentInfo/agentId").InnerText

            Write-Host "[MATCH FOUND] Asset ID: $CleanId ($Name - $IP)" -ForegroundColor Green

            # 2. EVALUATE SAFETY CHECK
            if ([string]::IsNullOrWhiteSpace($AgentId)) {
                Write-Host " -> Agent ID: NONE. Safe to purge. Executing purge..." -ForegroundColor Yellow

                # Construct Purge Payload for API v2 (Host Asset API)
                $PurgeBody = @{
                    "action"   = "purge"
                    "ids"      = $CleanId
                }

                try {
                    $PurgeResponse = Invoke-WebRequest -Uri $PurgeURL `
                                                       -Method "Post" `
                                                       -Headers $Headers `
                                                       -Body $PurgeBody `
                                                       -ErrorAction Stop

                    Write-Host " [SUCCESS] Asset ID $CleanId successfully purged from Qualys!" -ForegroundColor Green
                }
                catch {
                    Write-Host " [PURGE FAILED] Could not purge $CleanId : $($_.Exception.Message)" -ForegroundColor Red
                }

            } else {
                # FAIL-SAFE TRIGGERED
                Write-Host " [ABORTED] Agent ID $AgentId detected! Skipping purge to protect Cloud Agent record." -ForegroundColor Red
            }

            Write-Host "---------------------------------------------------------" -ForegroundColor Gray
        } 
        else {
            Write-Host "[NOT FOUND] Asset ID $CleanId does not exist or was already purged." -ForegroundColor DarkYellow
        }
    } 
    catch {
        Write-Host "[ERROR] Failed to query Asset ID $CleanId : $($_.Exception.Message)" -ForegroundColor Red
    }
}

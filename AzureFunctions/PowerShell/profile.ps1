# Azure Functions profile.ps1
#
# This profile.ps1 will get executed every "cold start" of your Function App.
# "cold start" occurs when:
#
# * A Function App starts up for the very first time
# * A Function App starts up after being de-allocated due to inactivity
#
# You can define helper functions, run commands, or specify environment variables
# NOTE: any variables defined that are not environment variables will get reset after the first execution

# Authenticate with Azure PowerShell using MSI.
# Remove this if you are not planning on using MSI or Azure PowerShell.
# if ($env:QWorksLiteAppSecret) {
#     Disable-AzContextAutosave -Scope Process | Out-Null
#     Connect-AzAccount -Identity | Out-Null
# }

# Uncomment the next line to enable legacy AzureRm alias in Azure PowerShell.
# Enable-AzureRmAlias

# You can also define functions or aliases that can be referenced in any of your PowerShell functions.

function Test-Profile {
    param (

    )

    $text = "Hello World"
    
}

# Define function to connect to Microsoft Graph
# Source: https://adamtheautomator.com/powershell-graph-api/
function Connect-MgGraphHTTP {
    param (
        [Parameter(Mandatory = $true)][String]$TenantId,
        [Parameter(Mandatory = $true)][String]$AppId,
        [Parameter(Mandatory = $true)][String]$AppSecret
    )

    # Define scope and url
    $scope = "https://graph.microsoft.com/.default"
    $url = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

    # Add System.Web for url encoding
    Add-Type -AssemblyName System.Web

    # Create body
    $tokenRequestbody = @{
        client_id     = $AppId
        client_secret = $AppSecret
        scope         = $Scope
        grant_type    = "client_credentials"
    }

    # Request graph token
    $tokenRequest = Invoke-RestMethod -Method Post -Uri $url -Body $tokenRequestbody -ContentType "application/x-www-form-urlencoded"
    
    # Create header
    $header = @{
        Authorization = "$($tokenRequest.token_type) $($tokenRequest.access_token)"
    }

}

function Retry-AnalyzeCallRecord {
    param (
        
    )

    Write-Host "Error message(s):"
    $Error | ForEach-Object { Write-Host $_.Exception.Message }

    $maxRetries = 3
    $delayBetweenRetries = 1000 # milliseconds
    $attemptCounter = 1

    if ($retryCount) {

        $retryCount ++

    }

    else {

        $retryCount = 1

    }

    if ($retryCount -le 10) {

        $callIdRetry = "$callId;retry_$retryCount"

        do {
            try {
                # Send callId to storage queue
                Push-OutputBinding -Name outputQueueItem -Value $callIdRetry
                Write-Host "Successfully added call record '$callIdRetry' to the queue."
                $success = $true # Indicate success
            }
            catch {
                $attemptCounter ++
                Write-Host "Attempt $attemptCounter failed to add call record '$callIdRetry' to the queue: $_"
                
                if ($attemptCounter -eq $maxRetries) {
                    Write-Host "Max retries reached. Could not add call record '$callIdRetry' to the queue."
                    $success = $false # Indicate failure
                }
                else {
                    Write-Host "Retrying in $delayBetweenRetries milliseconds..."
                    Start-Sleep -Milliseconds $delayBetweenRetries # Wait before retrying
                }
            }
        } until ($success -or $attemptCounter -eq $maxRetries)

    }

    else {

        Write-Host "Max retries reached (10). Dropping call record."

    }
    
}
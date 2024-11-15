using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

$clientState = ($env:QWorksLiteGraphSubscriptionClientState)

if ($TriggerMetadata.validationToken) {

    Write-Host "Function was invoked by Graph to update subscription. No new call records to process."

}
elseif ($Request.body.value.changeType -eq "updated") {

    Write-Host "Function was invoked by Graph to deliver an 'updated' notification. Ignoring."

}
elseif ($Request.body.value.clientState -eq $clientState -and $Request.body.value.changeType -eq "created") {

    Write-Host "Function was invoked by Graph to deliver a 'created' notification."
    Write-Host "Origin of the request matches client state. Processing call records."

    Write-Host "Notification resource id (call record id): '$($Request.body.value.resource)'"

    $callRecordIds = $($Request.body.value).resource

    foreach ($callId in $callRecordIds) {

        $callId = $callId.Split("/")[-1]
        Write-Host "Adding call record to storage queue: '$callId'."

        $maxRetries = 3
        $delayBetweenRetries = 1000 # milliseconds
        $attemptCounter = 1

        do {
            try {
                # Send callId to storage queue
                Push-OutputBinding -Name outputQueueItem -Value $callId
                Write-Host "Successfully added call record '$callId' to the queue."
                $success = $true # Indicate success
            }
            catch {
                $attemptCounter ++
                Write-Host "Attempt $attemptCounter failed to add call record '$callId' to the queue: $_"
                
                if ($attemptCounter -eq $maxRetries) {
                    Write-Host "Max retries reached. Could not add call record '$callId' to the queue."
                    $success = $false # Indicate failure
                }
                else {
                    Write-Host "Retrying in $delayBetweenRetries milliseconds..."
                    Start-Sleep -Milliseconds $delayBetweenRetries # Wait before retrying
                }
            }
        } until ($success -or $attemptCounter -eq $maxRetries)

    }
}
else {

    Write-Host "Function was invoked by an unknown source."
    Write-Host "Origin of the request does not match client state. Ignoring."

}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        Headers    = @{'Content-Type' = 'text/plain' }
        StatusCode = [HttpStatusCode]::OK
        Body       = $TriggerMetadata.validationToken
    })

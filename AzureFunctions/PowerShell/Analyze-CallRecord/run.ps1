# Input bindings are passed in via param block.
param($QueueItem, $TriggerMetadata)

$Error.Clear()

# Write out the queue message and insertion time to the information log.
Write-Host "PowerShell queue trigger function processed work item: $QueueItem"
Write-Host "Queue item insertion time: $($TriggerMetadata.InsertionTime)"

if ($Host.Name -eq "Visual Studio Code Host") {

    . .\AzureFunctions\PowerShell\profile.ps1

    $localEnvironment = Get-Content -Path .\.local\LocalEnvironment.json | ConvertFrom-Json

    $tenantId = $localEnvironment.TenantId
    $appId = $localEnvironment.AppId
    $powerAutomateTriggerUri = $localEnvironment.PowerAutomateTriggerUri
    $pythonFunctionUrl = $localEnvironment.PythonFunctionUrl
    $clientState = $localEnvironment.ClientState
    $testCallId = $localEnvironment.TestCallId

    $appSecret = ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Get-Content -Path .\.local\SecureCreds\QWorksLiteAppSecret.txt | ConvertTo-SecureString))) | Out-String).Trim()

    $QueueItem = $testCallId

}

else {

    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null

    # $tenantId = ($env:QWorksLiteTenantId)
    $tenantId = (Get-AzContext).Tenant.Id
    $appId = ($env:QWorksLiteAppId)
    $appSecret = ($env:QWorksLiteAppSecret)
    $clientState = ($env:QWorksLiteGraphSubscriptionClientState)

    $pythonFunctionUrl = ($env:QWorksLiteFormatPhoneNumberFunctionUrl)
    $powerAutomateTriggerUri = ($env:QWorksLitePowerAutomateTriggerUrl)

}

. Connect-MgGraphHTTP -TenantId $tenantId -AppId $appId -AppSecret $appSecret

if ($QueueItem -match ";") {

    $callId = $QueueItem.Split(";")[0]

    [int]$retryCount = $QueueItem.Split(";")[1].Split("_")[-1]

    Write-Host "Call Id previously failed. Retry attempt: $retryCount"

    if ($retryCount -le 10) {

        Write-Host "Sleeping for 5 minutes before retrying..."

        Start-Sleep -Seconds 300

    }

    else {

        Write-Host "Max retries reached (10). Dropping call record."

        exit

    }

}

else {

    $callId = $QueueItem

}

Write-Host "Notification resource id (call record id): '$callId'"

$callId = $callId.Split("/")[-1]

Write-Host "Processing call record with id: '$callId'."

$call = Invoke-RestMethod -Method Get -Headers $header -Uri "https://graph.microsoft.com/beta/communications/callRecords/$callId" -ContentType "application/json"

$sessions = Invoke-RestMethod -Method Get -Headers $header -Uri "https://graph.microsoft.com/beta/communications/callRecords/$($call.id)/sessions"

if (!$call -or !$sessions) {

    Write-Host "Error in retrieving call record from Graph. Disregarding call record."

}

if ($call -and $sessions) {

    $callOrganizer = $call.organizer_v2.id

    if ($call.type -ne "groupCall" -or $callOrganizer -notmatch "\+") {

        Write-Host "Call is not a group call or not a PSTN call. Disregarding call record."

    }

    else {

        Write-Host "Call record is a group call. Checking PSTN call records to determine callee number."

        $sessionIds = $sessions.value.id

        $callStartDateTime = (Get-Date -Date $call.startDateTime).ToUniversalTime()
        $callEndDateTime = (Get-Date -Date $call.endDateTime).ToUniversalTime()

        $fromTime = $callStartDateTime.AddMinutes(-1).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $toTime = $callEndDateTime.AddMinutes(1).ToString("yyyy-MM-ddTHH:mm:ssZ")

        # You may remove either the get direct routing calls or get PSTN calls endpoint depending on your environment
        $pstnCalls = Invoke-RestMethod -Method Get -Headers $header "https://graph.microsoft.com/beta/communications/callRecords/getPstnCalls(fromDateTime=$($fromTime),toDateTime=$($toTime))" -ContentType "application/json"

        if (!$pstnCalls.value) {

            $pstnCalls = Invoke-RestMethod -Method Get -Headers $header "https://graph.microsoft.com/beta/communications/callRecords/getDirectRoutingCalls(fromDateTime=$($fromTime),toDateTime=$($toTime))" -ContentType "application/json"

        }

        if (!$pstnCalls.value) {

            Write-Host "No matching PSTN call found. Disregarding call record."

        }

        else {
                    
            $pstnCalls = $pstnCalls.value | Where-Object { $_.callType -eq "ucap_in" -or $_.callType -eq "oc_ucap_in" -or $_.callType -eq "ByotInUcap" }

            if ($pstnCalls.Count -gt 1) {

                # Check for matching call id for Direct Routing and Operator Connect calls
                $matchingPstnCall = $pstnCalls | Where-Object { $_.callId -eq $call.id }

                # If Calling Plan call
                if (-not $matchingPstnCall) {

                    $matchingPstnCall = $pstnCalls | Where-Object { $($callOrganizer).Replace('+', '') -like "*$($_.callerNumber.Replace('*', '').Replace('+',''))*" -and $_.userId -in $sessions.value.caller.identity.user.id }

                }

                if ($matchingPstnCall.Count -gt 1) {

                    $matchingPstnCall = $matchingPstnCall | Sort-Object -Property callerNumber -Unique

                }

            }

            else {

                $matchingPstnCall = $pstnCalls

            }

            # Call python function to get caller number in international format
            $callerNumberBody = @{
                PhoneNumber = $callOrganizer
            } | ConvertTo-Json

            # Make the POST request
            $response = Invoke-RestMethod -Uri $pythonFunctionUrl -Method Post -Body $callerNumberBody -ContentType "application/json"

            $callOrganizerPrettyNumber = $response.InternationalPhoneNumber

            # Call python function to get callee number in international format
            $calleeNumber = $matchingPstnCall.calleeNumber

            $calleeNumberBody = @{
                PhoneNumber = $calleeNumber
            } | ConvertTo-Json

            # Make the POST request
            $response = Invoke-RestMethod -Uri $pythonFunctionUrl -Method Post -Body $calleeNumberBody -ContentType "application/json"

            $calleeNumberPretty = $response.InternationalPhoneNumber

            # Create eventual header for advanced filtering of Teams
            $eventualHeader = $header += @{ ConsistencyLevel = "eventual" }

            Write-Host "Checking for QWorks enabled Team matching callee number '$($calleeNumberPretty)'."

            $qWorksEnabledTeams = Invoke-RestMethod -Method Get -Headers $eventualHeader -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=startsWith(Description, 'Q.Works')&`$count=true&`$top=999" -ContentType "application/json"

            if (!$qWorksEnabledTeams) {

                Write-Host "No QWorks enabled Teams found for '$calleeNumberPretty'."

            }

            else {

                $notificationTeam = $qWorksEnabledTeams.value | Where-Object { $_.Description.Split(":")[1].Replace(" ", "").Trim() -eq $calleeNumber }

                Write-Host "QWorks enabled Teams found for '$($calleeNumberPretty)': '$($notificationTeam.displayName)'."

                $checkQWorksNotificationChannel = Invoke-RestMethod -Method Get -Headers $eventualHeader -Uri "https://graph.microsoft.com/v1.0/teams/$($notificationTeam.id)/allChannels?`$filter=displayName eq 'Q Works Notifications'" -ContentType "application/json"

                if (!$checkQWorksNotificationChannel.value) {

                    Write-Host "No Q Works Notifications channel found in '$($notificationTeam.displayName)'. Creating a new one."

                    # Create new channel
                    $newChannel = @{
                        displayName    = "Q Works Notifications"
                        description    = "Channel for Q Works Notifications"
                        membershipType = "standard"
                    } | ConvertTo-Json

                    Start-Sleep -Seconds 10

                    $newChannel = Invoke-RestMethod -Method Post -Headers $header -Uri "https://graph.microsoft.com/v1.0/teams/$($notificationTeam.id)/channels" -ContentType "application/json" -Body $newChannel

                    $notificationChannelId = $newChannel.id

                }

                else {

                    Write-Host "Q Works Notifications channel found in $($notificationTeam.displayName). Channel name: '$($checkQWorksNotificationChannel.value.displayName)'."

                    $notificationChannelId = $checkQWorksNotificationChannel.value.id

                }

                $callDuration = $callEndDateTime - $callStartDateTime

                # format call duarion as hh:mm:ss
                $callDuration = "{0:hh\:mm\:ss}" -f $callDuration

                $powerAutomateHeaders = @{
                    "CallId"                = $callId
                    "CallRecordVersion"     = $call.version
                    "NotificationTeamId"    = $notificationTeam.id
                    "NotificationChannelId" = $notificationChannelId
                    "CallerNumber"          = $callOrganizer
                    "CallerNumberPretty"    = $callOrganizerPrettyNumber
                    "CalleeNumber"          = $calleeNumber
                    "CalleeNumberPretty"    = $calleeNumberPretty
                    "CalledVoiceApp"        = $matchingPstnCall.userDisplayName
                    "StartTime"             = $callStartDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
                    "EndTime"               = $callEndDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
                    "CallDuration"          = $callDuration
                    "TriggerSecret"         = $clientState
                    "SessionIds"            = $sessionIds -join ";"
                }

                # Create blank adaptive card
                $powerAutomateBody = @{

                    type        = "message"
                    attachments = @(
                        @{
                            contentType = "application/vnd.microsoft.card.adaptive"
                            contentUrl  = $null
                            content     = @{
                                type      = "AdaptiveCard"
                                '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                                version   = "1.3"
                                body      = @(
                                )
                            }
                        }
                    )

                } | ConvertTo-Json -Depth 99

                # $forceError = Get-ChildItem -Path "Foo" -ErrorAction SilentlyContinue # Uncomment to force error

                if (!$Error) {

                    if ($retryCount) {

                        Write-Host "Successfully processed call record '$callId' after $retryCount retries."

                    }

                    else {

                        Write-Host "Successfully processed call record '$callId'."

                    }

                    Write-Host "Sending call record to Power Automate."

                    try {

                        Invoke-RestMethod -Method Post -Uri $powerAutomateTriggerUri -Headers $powerAutomateHeaders -Body $powerAutomateBody -ContentType "application/json" | Out-Null

                        Write-Host "Call record successfully sent to Power Automate."

                        # $forceError = Get-ChildItem -Path "Foo" -ErrorAction Continue # Uncomment to force error

                    }
                    catch {

                        Write-Host "Error in sending call record to Power Automate. Call record will be retried."

                        . Retry-AnalyzeCallRecord

                    }

                }

                else {

                    Write-Host "Error in processing call record. Call record will be retried."

                    . Retry-AnalyzeCallRecord

                }

            }

        }

    }

}
# Input bindings are passed in via param block.
param($Timer)

# Cron expression: 0 15 12 * * *
# Runs at 12:15 PM UTC every day.

# Get the current universal time in the default string format.
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# Write an information log with the current time.
Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"

### Begin Q Works Lite Code ###

Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null

# $tenantId = ($env:QWorksLiteTenantId)
$tenantId = (Get-AzContext).Tenant.Id
$appId = ($env:QWorksLiteAppId)
$appSecret = ($env:QWorksLiteAppSecret)
$clientState = ($env:QWorksLiteGraphSubscriptionClientState)
$functionUrl = ($env:QWorksLiteReceiveGraphNotificationsFunctionUrl)

. Connect-MgGraphHTTP -TenantId $tenantId -AppId $appId -AppSecret $appSecret

$existingSubscriptions = Invoke-RestMethod -Method Get -Headers $header -Uri "https://graph.microsoft.com/v1.0/subscriptions" -ContentType "application/json"

if ($existingSubscriptions.value.resource -eq "/communications/callRecords") {

    $existingSubscription = $existingSubscriptions.value | Where-Object { $_.resource -eq "/communications/callRecords" }

    Write-Output "Call records subscription already exists. Renewing subscription."

    $jsonBodyRenew = @{
        "expirationDateTime" = (Get-Date).AddDays(2).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        "clientState"        = "$clientState"
    }

    $jsonBodyRenew = $jsonBodyRenew | ConvertTo-Json

    $updateSubscription = Invoke-RestMethod -Method Patch -Headers $header -Uri "https://graph.microsoft.com/v1.0/subscriptions/$($existingSubscription.id)" -Body $jsonBodyRenew -ContentType "application/json"

    $updateSubscription

}

else {

    Write-Output "Creating call records subscription."

    $body = [ordered]@{
        "changeType"         = "created,updated"
        "notificationUrl"    = "$functionUrl"
        "resource"           = "/communications/callRecords"
        "expirationDateTime" = (Get-Date).AddDays(2).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        "clientState"        = "$clientState"
    }

    $jsonBody = $body | ConvertTo-Json

    $jsonBody

    $createSubscription = Invoke-RestMethod -Method Post -Headers $header -Uri "https://graph.microsoft.com/v1.0/subscriptions" -Body $jsonBody -ContentType "application/json"

    $createSubscription

}
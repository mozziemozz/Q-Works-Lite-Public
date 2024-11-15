#Requires -Version 7.0

function New-RandomString {
    param (
        [int]$length = 4,
        [bool]$LowerCaseOnly = $true
    )

    if ($LowerCaseOnly) {
        $characters = 'abcdefghijklmnopqrstuvwxyz0123456789'
    } else {
        $characters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    }

    $randomName = -join (1..$length | ForEach-Object { Get-Random -InputObject $characters.ToCharArray() })

    return $randomName
}

function New-NCTEncryptedPassword {
    param (
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $false)][string]$Secret
    )
    
    $secureCredsFolder = ".\.local\SecureCreds"

    if (!(Test-Path -Path $secureCredsFolder)) {

        New-Item -Path $secureCredsFolder -ItemType Directory

    }

    if ($Secret) {

        $SecureStringPassword = ConvertTo-SecureString $Secret -AsPlainText -Force

    }
    else {

        $SecureStringPassword = Read-Host "Please enter the password you would like to hash" -AsSecureString

    }
    
    $PasswordHash = $SecureStringPassword | ConvertFrom-SecureString

    Set-Content -Path "$secureCredsFolder\$($FileName).txt" -Value $PasswordHash -Force

    Write-Host "Secret has been encrypted and saved to .local\SecureCreds\$($FileName).txt" -ForegroundColor Yellow
    Write-Host "The secret can only be decrypted by the user who encrypted it using the same machine it was encrypted on." -ForegroundColor Yellow

}

$environment = Get-Content -Path .\Deployment\environment.json | ConvertFrom-Json

$solutionName = $environment.SolutionName
$companyShortName = $environment.CompanyShortName
$azLocation = $environment.AzureRegion

$solutionNameHyphensLow = $solutionName.Replace(" ", "-").ToLower()
$solutionNameNoSpacesLow = $solutionName.Replace(" ", "").ToLower()
$companyShortNameLow = $companyShortName.ToLower()

$resourceGroupName = "$($solutionNameHyphensLow)-$($companyShortNameLow)"

$functionAppNamePython = "$($solutionNameHyphensLow)-py-$($companyShortNameLow)"
$functionAppNamePowerShell = "$($solutionNameHyphensLow)-ps-$($companyShortNameLow)"

$appServicePlanName = "ASP-$($solutionNameNoSpacesLow)$($companyShortNameLow)-LINUX-$(New-RandomString)"

$keyVaultName = "$($solutionNameNoSpacesLow)-$($companyShortNameLow)-kv"

$storageAccountNamePython = "$($solutionNameNoSpacesLow)$($companyShortNameLow)py$(New-RandomString)"
$storageAccountNamePowerShell = "$($solutionNameNoSpacesLow)$($companyShortNameLow)ps$(New-RandomString)"

if ($storageAccountNamePython.Length -gt 24) {
    $storageAccountNamePython = ("$($solutionNameNoSpacesLow)$($companyShortNameLow)").Substring(0, 18) + "py" + $(New-RandomString)
}

if ($storageAccountNamePowerShell.Length -gt 24) {
    $storageAccountNamePowerShell = ("$($solutionNameNoSpacesLow)$($companyShortNameLow)").Substring(0, 18) + "ps" + $(New-RandomString)
}

$storageQueueName = "call-records-queue"

$resourceNames = [pscustomobject]@{
    ResourceGroupName = $resourceGroupName
    FunctionAppNamePython = $functionAppNamePython
    FunctionAppNamePowerShell = $functionAppNamePowerShell
    AppServicePlanName = $appServicePlanName
    StorageAccountNamePython = $storageAccountNamePython
    StorageAccountNamePowerShell = $storageAccountNamePowerShell
    StorageQueueName = $storageQueueName
    KeyVaultName = $keyVaultName
}

$resourceNames

# Connect to Graph
Connect-MgGraph -NoWelcome -Scopes "Application.ReadWrite.All", "User.Read.All"

$tenantId = (Get-MgContext).TenantId

$checkM365CLI = Get-MgApplication -Filter "displayName eq 'CLI for Microsoft 365' or displayName eq 'CLI for M365'"

if (!$checkM365CLI) {

    m365 setup

    # Connect to M365 CLI
    m365 login --appId $checkM365CLI.AppId --tenant $tenantId --authType browser

}

else {

    try {
        # Connect to M365 CLI
        m365 login --appId $checkM365CLI.AppId --tenant $tenantId --authType browser    }
    catch {
        m365 setup

        $checkM365CLI = Get-MgApplication -Filter "displayName eq 'CLI for Microsoft 365'"

        # Connect to M365 CLI
        m365 login --appId $checkM365CLI.AppId

    }

}

# Add Flow.Read.All delegated permission to the M365 CLI app
m365 entra app permission add --appId $checkM365CLI.AppId `
    --delegatedPermissions 'https://service.flow.microsoft.com/Flows.Read.All' `
    --grantAdminConsent

# Connect to Azure Account
$checkAzureSession = Get-AzContext

if (!$checkAzureSession.Tenant.Id -eq $tenantId) {

    Set-AzConfig -EnableLoginByWam $false

    Connect-AzAccount -TenantId $tenantId

    $azSubscriptions = Get-AzSubscription

    if ($azSubscriptions.Count -gt 1) {

        Write-Host "Multiple Azure Subcriptions found. Please choose one from the list..." -ForegroundColor Cyan

        $azSubscription = $azSubscriptions | Out-GridView -Title "Choose a Subscription From The List" -OutputMode Single

        Select-AzSubscription $azSubscription.Id

    }

}

### Start create app registration ###
$appName = "$solutionNameHyphensLow"

$checkAppRegistration = Get-MgApplication -Filter "displayName eq '$appName'"

if ($checkAppRegistration) {

    Write-Warning "App registration '$appName' already exists."

    $localAppSecretPath = ".\.local\SecureCreds\QWorksLiteAppSecret.txt"

    $checkLocalAppSecret = Test-Path -Path $localAppSecretPath

    if ($checkLocalAppSecret) {

        $appSecret = ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Get-Content -Path .\.local\SecureCreds\QWorksLiteAppSecret.txt | ConvertTo-SecureString))) | Out-String).Trim()

        if ($?) {

            Write-Host "App secret found in '.local\SecureCreds\QWorksLiteAppSecret.txt' No new app will be registered." -ForegroundColor Green

            $createAppRegistration = $false

        }

        else {

            Write-Warning "App secret not found in '.local\SecureCreds\QWorksLiteAppSecret.txt'. A new app will be registered."

            $createAppRegistration = $true

        }

    }

    else {

        Write-Warning "App secret not found in '.local\SecureCreds\QWorksLiteAppSecret.txt'. A new app will be registered."

        $createAppRegistration = $true

    }

}

if (!$checkAppRegistration -or $createAppRegistration -eq $true) {

    $newEntraApp = m365 entra app add --name $appName --withSecret `
        --redirectUris 'https://login.microsoftonline.com/common/oauth2/nativeclient,http://localhost' `
        --platform publicClient `
        --scopeConsentBy adminsAndUsers

    $appId = $newEntraApp[0].Split(":")[-1].Trim()
    $objectId = $newEntraApp[1].Split(":")[-1].Trim()
    $appSecret = ($newEntraApp[2].Split("secrets :")[-1].Trim() | ConvertFrom-Json).value

    New-NCTEncryptedPassword -FileName "QWorksLiteAppSecret" -Secret $appSecret

    m365 entra app permission add --appId $appId `
        --applicationPermissions 'https://graph.microsoft.com/CallRecord-PstnCalls.Read.All https://graph.microsoft.com/CallRecords.Read.All https://graph.microsoft.com/Channel.Create https://graph.microsoft.com/Channel.ReadBasic.All https://graph.microsoft.com/Group.Read.All https://graph.microsoft.com/Team.ReadBasic.All https://graph.microsoft.com/User.Read.All' `
        --grantAdminConsent

    do {
        Start-Sleep -Seconds 5
        $checkMgApplicaiton = Get-MgApplication -Filter "appId eq '$appId'"
    } until (
        $checkMgApplicaiton
    )

    Start-Sleep -Seconds 30

    # Add currently signed in admin account as owner of the app and service principal
    $adminAccount = Get-MgUser -UserId (Get-MgContext).Account

    do {

        try {
            New-MgApplicationOwnerByRef -ApplicationId $objectId -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($adminAccount.Id)" }
            Start-Sleep -Seconds 5
            $checkMgApplicationOwner = Get-MgApplicationOwner -ApplicationId $objectId
        }
        catch {

        }
    
    } until (
        $checkMgApplicationOwner.Id -contains $adminAccount.Id
    )

    Write-Host "Admin account added as owner of the app registration '$appName'." -ForegroundColor Green

    # Add currently signed in admin account as owner of the service principal
    $servicePrincipal = Get-MgServicePrincipal -Filter "appId eq '$appId'"

    do {
        try {
            New-MgServicePrincipalOwnerByRef -ServicePrincipalId $servicePrincipal.Id -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($adminAccount.Id)" }
            Start-Sleep -Seconds 5
            $checkMgServicePrincipalOwner = Get-MgServicePrincipalOwner -ServicePrincipalId $servicePrincipal.Id
        }
        catch {

        }
    } until (
        $checkMgServicePrincipalOwner.Id -contains $adminAccount.Id
    )

    Write-Host "Admin account added as owner of the service principal '$appName'." -ForegroundColor Green

    ### End create app registration ###

}

$checkResourceGroup = Get-AzResourceGroup -Name $resourceGroupName

if (!$checkResourceGroup) {

    # Create a new, empty Resource Group
    New-AzResourceGroup -Name $resourceGroupName -Location $azLocation

}

else {

    Write-Host "Resource group '$resourceGroupName' already exists." -ForegroundColor Green

    $storageAccounts = Get-AzStorageAccount -ResourceGroupName $resourceGroupName

    $checkStorageAccountPython = $storageAccounts | Where-Object { $_.StorageAccountName -match "$($storageAccountNamePython.Substring(0, ($storageAccountNamePython.Length -4 )))" }

    $checkStorageAccountPowerShell = $storageAccounts | Where-Object { $_.StorageAccountName -match "$($storageAccountNamePowerShell.Substring(0, ($storageAccountNamePowerShell.Length -4 )))" }

    $checkAppServicePlan = Get-AzAppServicePlan -ResourceGroupName $resourceGroupName | Where-Object { $_.Name -match "ASP-$($solutionNameNoSpacesLow)$($companyShortNameLow)-LINUX-" }

    $checkAzKeyVault = Get-AzKeyVault -ResourceGroupName $resourceGroupName -Name $keyVaultName
}

if (!$checkAppServicePlan) {

    # Create new Linux app service plan
    $newAppServicePlan = New-AzAppServicePlan -ResourceGroupName $resourceGroupName -Name $appServicePlanName -Location $azLocation -Tier "Y1" -Linux

}

else {

    Write-Host "App Service Plan '$appServicePlanName' already exists." -ForegroundColor Green

    $newAppServicePlan = $checkAppServicePlan

}

if (!$checkStorageAccountPython) {

    # Create a new storage account for the python function app
    $newStorageAccountPython = New-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountNamePython -SkuName "Standard_LRS" -Location $azLocation

}

else {

    Write-Host "Storage account '$storageAccountNamePython' for Python Function App already exists." -ForegroundColor Green

    $newStorageAccountPython = $checkStorageAccountPython

}

if (!$checkStorageAccountPowerShell) {

    # Create a new storage account for the PowerShell function app
    $newStorageAccountPowerShell = New-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountNamePowerShell -SkuName "Standard_LRS" -Location $azLocation

}

else {

    Write-Host "Storage account '$storageAccountNamePowerShell' for PowerShell Function App already exists." -ForegroundColor Green

    $newStorageAccountPowerShell = $checkStorageAccountPowerShell

}

$checkAzStorageQueue = Get-AzStorageQueue -Name $storageQueueName -Context $newStorageAccountPowerShell.Context

if (!$checkAzStorageQueue) {

    # Create new storage queue in PowerShell storage account
    $newAzStorageQueue = New-AzStorageQueue -Name $storageQueueName -Context $newStorageAccountPowerShell.Context

}

else {

    Write-Host "Storage queue '$storageQueueName' already exists in PowerShell storage account." -ForegroundColor Green

    $newAzStorageQueue = $checkAzStorageQueue

}

$checkFunctionAppPython = Get-AzFunctionApp -ResourceGroupName $resourceGroupName -Name $functionAppNamePython

$checkFunctionAppPowerShell = Get-AzFunctionApp -ResourceGroupName $resourceGroupName -Name $functionAppNamePowerShell

if (!$checkFunctionAppPython) {

    # Create the Python Function App
    $newFunctionAppPython = New-AzFunctionApp -ResourceGroupName $resourceGroupName -Name $functionAppNamePython -StorageAccountName $($newStorageAccountPython.StorageAccountName) `
        -OSType Linux -Runtime Python -RuntimeVersion 3.11 -FunctionsVersion 4 -Location $azLocation

}

else {

    $newFunctionAppPython = $checkFunctionAppPython

}

if (!$checkFunctionAppPowerShell) {

    # Create the PowerShell Function App
    $newFunctionAppPowerShell = New-AzFunctionApp -ResourceGroupName $resourceGroupName -Name $functionAppNamePowerShell -StorageAccountName $($newStorageAccountPowerShell.StorageAccountName) `
        -OSType Linux -Runtime PowerShell -RuntimeVersion 7.4 -FunctionsVersion 4 -Location $azLocation
    
}

else {

    $newFunctionAppPowerShell = $checkFunctionAppPowerShell

}

# Add the PowerShell functions to the function app
$workingDirectory = Get-Location

$functionLocationPowerShell = ".\AzureFunctions\PowerShell"
Set-Location -Path $functionLocationPowerShell
func azure functionapp publish $functionAppNamePowerShell --powershell

Set-Location -Path $workingDirectory

# Add the Python functions to the function app
$functionLocationPython = ".\AzureFunctions\Python"
Set-Location -Path $functionLocationPython
func azure functionapp publish $functionAppNamePython --python

Set-Location -Path $workingDirectory

$checkManagedIdentity = (Get-AzFunctionApp -ResourceGroupName $resourceGroupName -Name $functionAppNamePowerShell)

if ($checkManagedIdentity.IdentityType -eq "SystemAssigned") {

    Write-Host "Managed identity already enabled for the PowerShell Function App." -ForegroundColor Green

    $managedIdentityId = $checkManagedIdentity.IdentityPrincipalId

}

else {

    # Enable system-assigned managed identity for the Function App
    Update-AzFunctionApp -ResourceGroupName $resourceGroupName -Name $functionAppNamePowerShell -IdentityType SystemAssigned -Force

    $managedIdentityId = (Get-AzFunctionApp -ResourceGroupName $resourceGroupName -Name $functionAppNamePowerShell).IdentityPrincipalId

}

if (!$checkAzKeyVault) {

    # Create new Azure Key Vault
    New-AzKeyVault -ResourceGroupName $resourceGroupName -VaultName $keyVaultName -Location $azLocation -Sku "Standard"

    # Assign the Key Vault Secrets Officer role to the user
    New-AzRoleAssignment -ObjectId $($adminAccount.Id) -RoleDefinitionName "Key Vault Secrets Officer" `
        -Scope "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$resourceGroupName/providers/Microsoft.KeyVault/vaults/$keyVaultName"

    # Add the managed identity of the PowerShell function app as a Key Vault Secrets User
    New-AzRoleAssignment -ObjectId $managedIdentityId -RoleDefinitionName "Key Vault Secrets User" `
        -Scope "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$resourceGroupName/providers/Microsoft.KeyVault/vaults/$keyVaultName"

    # Add the app secret to the key vault
    $appSecret = ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Get-Content -Path .\.local\SecureCreds\QWorksLiteAppSecret.txt | ConvertTo-SecureString))) | Out-String).Trim()

    do {
        
        $checkRoleAssignment = Get-AzRoleAssignment -ObjectId $($adminAccount.Id) | Where-Object { $_.Scope -eq "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$resourceGroupName/providers/Microsoft.KeyVault/vaults/$keyVaultName" }

        if (!$checkRoleAssignment) {

            Write-Host "Waiting for the Key Vault Secrets Officer role assignment to complete..." -ForegroundColor Yellow

            Start-Sleep -Seconds 30

        }

    } until (
        $checkRoleAssignment
    )

    $keyVaultSecretAppSecret = Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "QWorksLiteAppSecret" -SecretValue (ConvertTo-SecureString -String $appSecret -AsPlainText -Force)

}

else {

    $keyVaultSecretAppSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "QWorksLiteAppSecret"

}



# Retrieve function URL for the Python function app
$functionWebAppPython = Get-AzWebApp -ResourceGroupName $resourceGroupName -Name $functionAppNamePython

$triggerNameFormatPhoneNumber = "FormatPhoneNumber"
$functionKeyFormatPhoneNumber = (Invoke-AzResourceAction -ResourceId "$($functionWebAppPython.Id)/functions/$triggerNameFormatPhoneNumber" -Action listkeys -Force).default
$functionUrlFormatPhoneNumber = "https://" + $($functionWebAppPython.DefaultHostName) + "/api/" + $triggerNameFormatPhoneNumber + "?code=" + $functionKeyFormatPhoneNumber

# Retrieve function URL for the PowerShell function app
$functionWebAppPowerShell = Get-AzWebApp -ResourceGroupName $resourceGroupName -Name $functionAppNamePowerShell

$triggerNameReceiveGraphNotifications = "Receive-GraphNotifications"
$functionKeyReceiveGraphNotifications = (Invoke-AzResourceAction -ResourceId "$($functionWebAppPowerShell.Id)/functions/$triggerNameReceiveGraphNotifications" -Action listkeys -Force).default
$functionUrlReceiveGraphNotifications = "https://" + $($functionWebAppPowerShell.DefaultHostName) + "/api/" + $triggerNameReceiveGraphNotifications + "?code=" + $functionKeyReceiveGraphNotifications

# Add environment variables to the PowerShell function app
$appSettingPowerShell = Get-AzFunctionAppSetting -ResourceGroupName $resourceGroupName -Name $functionAppNamePowerShell

$qWorksLiteEntraAppId = (Get-MgApplication -Filter "displayName eq '$solutionNameHyphensLow'")

if (!$appSettingPowerShell.QWorksLiteGraphSubscriptionClientState) {

    $newClientState = $(New-RandomString -length 16 -LowerCaseOnly $false)

}
else {
    
    $newClientState = $appSettingPowerShell.QWorksLiteGraphSubscriptionClientState

}

if (!$appSettingPowerShell.QWorksLitePowerAutomateTriggerUrl) {

    # $powerAutomateTriggerUrl = Read-Host -Prompt "Paste the Power Automate trigger URL"

    # m365 logout

    # Write-Host "Sign in to M365 CLI with the Flow Service Account to get the Power Automate trigger URL." -ForegroundColor Yellow

    # # Connect to M365 CLI
    # m365 login --appId $checkM365CLI.AppId --tenant $tenantId --authType browser

    # $powerAutomateAccessToken = m365 util accesstoken get --resource "https://service.flow.microsoft.com"

    # $powerAutomateAuthHeader = @{ Authorization = "Bearer $powerAutomateAccessToken" }

    # $powerAutomateEnvironments = m365 pp environment list --output json | ConvertFrom-Json -Depth 99

    # $powerAutomateEnvironment = $powerAutomateEnvironments | Where-Object { $_.displayName -match "(default)" }

    # $powerAutomateEnvironmentUrl = $powerAutomateEnvironment.properties.linkedEnvironmentMetadata.instanceUrl
    # $powerAutomateEnvironmentDisplayName = $powerAutomateEnvironment.displayName
    # $powerAutomateEnvironmentName = $powerAutomateEnvironment.name

    Expand-Archive -Path ".\PowerAutomate\QWorksLiteNotificationsV3.zip" -DestinationPath ".\PowerAutomate\QWorksLiteNotificationsV3" -Force

    $flowDefinition = Get-Content -Path ".\PowerAutomate\QWorksLiteNotificationsV3\Microsoft.Flow\flows\36db369f-ad9e-4a7b-a889-f3ded9ceaad0\definition.json" -Raw

    $flowDefinition = $flowDefinition -replace "TriggerSecretPlaceHolder", $newClientState

    Set-Content -Path ".\PowerAutomate\QWorksLiteNotificationsV3\Microsoft.Flow\flows\36db369f-ad9e-4a7b-a889-f3ded9ceaad0\definition.json" -Value $flowDefinition

    Compress-Archive -Path ".\PowerAutomate\QWorksLiteNotificationsV3\*" -DestinationPath ".\PowerAutomate\QWorksLiteNotificationsDeploymentPackage.zip" -Force

    Remove-Item -Path ".\PowerAutomate\QWorksLiteNotificationsV3" -Recurse -Force

    Write-Host "Go to https://make.powerautomate.com now and import the '.\PowerAutomate\QWorksLiteNotificationsDeploymentPackage.zip' file. Then enable the flow, copy the trigger URL and come back here and paste it in the next step." -ForegroundColor Yellow

    # Read-Host "Only press enter if the flow has been imported and enabled!"

    # $flows = Invoke-RestMethod -Method Get -Uri "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/environments/$($powerAutomateEnvironmentName)/flows?api-version=2016-11-01&`$expand=properties.protectionStatus&`$filter=search(%27personal%27)&`$top=50&draftFlow=true" -Headers $powerAutomateAuthHeader -ContentType "application/json"

    # $flow = ($flows.value | Where-Object { $_.properties.displayName -eq "Q Works Lite Notifications V3" })

    # $powerAutomateTriggerUrl = (Invoke-RestMethod -Method Post -Uri "https://emea.api.flow.microsoft.com/providers/Microsoft.ProcessSimple/environments/$($powerAutomateEnvironmentName)/flows/$($flow.name)/triggers/manual/listCallbackUrl?api-version=2016-11-01" -Headers $powerAutomateAuthHeader -ContentType "application/json").response.value

    $powerAutomateTriggerUrl = Read-Host -Prompt "Paste the Power Automate trigger URL"

}

else {
    
    $powerAutomateTriggerUrl = $appSettingPowerShell.QWorksLitePowerAutomateTriggerUrl

}

$appSettingPowerShell["QWorksLiteAppId"] = [string]$qWorksLiteEntraAppId.AppId
$appSettingPowerShell["QWorksLiteGraphSubscriptionClientState"] = $newClientState
$appSettingPowerShell["QWorksLiteReceiveGraphNotificationsFunctionUrl"] = $functionUrlReceiveGraphNotifications
$appSettingPowerShell["QWorksLiteFormatPhoneNumberFunctionUrl"] = $functionUrlFormatPhoneNumber
# The client state is stored in key vault and in environment variables (unencrypted) so that the Receive-GraphNotification function can respond to Graph faster (no Connect-AzAccount needed)
$appSettingPowerShell["QWorksLiteAppSecret"] = "@Microsoft.KeyVault(SecretUri=$($keyVaultSecretAppSecret.Id))"
$appSettingPowerShell["QWorksLitePowerAutomateTriggerUrl"] = $powerAutomateTriggerUrl

Update-AzFunctionAppSetting -ResourceGroupName $resourceGroupName -Name $functionAppNamePowerShell -AppSetting $appSettingPowerShell -Force

$corsUrl = "https://portal.azure.com"

# Add CORS rule to the PowerShell Function App
New-AzResource -PropertyObject @{Cors = @{AllowedOrigins = @($corsUrl) } } `
    -ResourceGroupName $resourceGroupName `
    -ResourceType "Microsoft.Web/sites/config" `
    -ResourceName "$functionAppNamePowerShell/web" `
    -Force

# Add CORS rule to the Python Function App
New-AzResource -PropertyObject @{Cors = @{AllowedOrigins = @($corsUrl) } } `
    -ResourceGroupName $resourceGroupName `
    -ResourceType "Microsoft.Web/sites/config" `
    -ResourceName "$functionAppNamePython/web" `
    -Force

Restart-AzFunctionApp -ResourceGroupName $resourceGroupName -Name $functionAppNamePowerShell -Force

Write-Host "Finished deployment." -ForegroundColor Green
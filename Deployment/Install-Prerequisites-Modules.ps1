#Requires -Version 7.0; -RunAsAdministrator

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

$requiredModules = @(

    "Az.Accounts",
    "Az.Functions",
    "Az.Resources",
    "Az.Storage",
    "Az.Websites",
    "Az.KeyVault",
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Identity.SignIns",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Applications"

)


foreach ($module in $requiredModules) {

    $checkModule = Get-PSResource -Name $module -Scope AllUsers

    if ($null -eq $checkModule) {

        Install-PSResource -Name $module -Scope AllUsers

    }

    else {

        Write-Host "$module is already installed." -ForegroundColor Green

    }

}

# Install M365 CLI
npm i -g @pnp/cli-microsoft365

# Install PowerApps CLI
# dotnet tool install -g --add-source 'https://api.nuget.org/v3/index.json' --ignore-failed-sources "Microsoft.PowerApps.CLI.Tool"
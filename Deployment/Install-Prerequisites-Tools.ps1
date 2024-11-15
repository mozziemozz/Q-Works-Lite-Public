#Requires -RunAsAdministrator

$tools = @(

    "9MZ1SNWT0N5D", # PowerShell 7
    "XP9KHM4BK9FZ7Q" # VS Code
    "Microsoft.Azure.FunctionsCoreTools",
    "Microsoft.AzureCLI",
    "Python.Python.3.11",
    "OpenJS.NodeJS"
    # "Microsoft.DotNet.SDK.8"

)

foreach ($tool in $tools) {

    $checkTool = winget list --id $tool -e

    if ($checkTool -match "No installed package found matching input criteria.") {

        winget install --id $tool -e

    }

    else {

        Write-Host "$tool is already installed." -ForegroundColor Green

    }

}

Write-Host "Pre-requisite tools installed successfully. Run 'Install-Prerequisites-Modules' in PowerShell 7 next." -ForegroundColor Green
Start-Sleep -Seconds 5
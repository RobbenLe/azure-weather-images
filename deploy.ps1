<#
    Deploys the Weather Images solution to Azure.

    Steps:
        0. Check prerequisites (Docker running, logged in to Azure)
        1. Publish all three projects with the dotnet CLI
        2. Resource group
        3. Log Analytics workspace
        4. Container Apps environment      (Azure CLI - see comment below)
        5. Container registry
        6. Build the three container images
        7. Push them to the registry
        8. Deploy every other resource from the Bicep template

    Usage:
        .\deploy.ps1
        .\deploy.ps1 -ImageTag v4
#>

param(
    [string] $ResourceGroup         = 'rg-weatherimages-dev',
    [string] $ResourceGroupLocation = 'westeurope',
    [string] $NamePrefix            = 'weatherimg707875',
    [string] $Location              = 'swedencentral',
    [string] $EnvironmentLocation   = 'norwayeast',
    [string] $ImageTag              = (Get-Date -Format 'yyyyMMddHHmm')
)

# Native programs (dotnet, docker, az) write progress and warnings to stderr.
# With 'Stop', Windows PowerShell turns any stderr line into a terminating error
# and would abort the script on a harmless warning. Failures from native programs
# are detected with $LASTEXITCODE in Assert-Ok instead.
$ErrorActionPreference = 'Continue'


# $ErrorActionPreference only applies to PowerShell cmdlets. External programs
# (dotnet, docker, az) report failure through $LASTEXITCODE, which PowerShell
# ignores by default, so every external call is checked explicitly.
function Assert-Ok($what) {
    if ($LASTEXITCODE -ne 0) {
        throw "$what failed (exit code $LASTEXITCODE)"
    }
}

$acrName          = "acr$NamePrefix"
$acrServer        = "$acrName.azurecr.io"
$environmentName  = 'cae-weatherimages'
$logAnalyticsName = "log-weatherimages-$NamePrefix"

# ---------------------------------------------------------------- 0. Prerequisites
Write-Host "=== 0/8  Checking prerequisites ===" -ForegroundColor Cyan

docker info *> $null
Assert-Ok "Docker is not running - start Docker Desktop and try again"

az account show -o none
Assert-Ok "Not logged in to Azure - run 'az login'"

# ---------------------------------------------------------------- 1. dotnet publish
Write-Host "=== 1/8  Publishing the solution with the dotnet CLI ===" -ForegroundColor Cyan

dotnet publish src/WeatherImages.Api/WeatherImages.Api.csproj -c Release -o artifacts/api
Assert-Ok "dotnet publish (api)"

dotnet publish src/WeatherImages.Jobs.FetchWeather/WeatherImages.Jobs.FetchWeather.csproj -c Release -o artifacts/fetchweather
Assert-Ok "dotnet publish (fetchweather)"

dotnet publish src/WeatherImages.Jobs.ProcessImage/WeatherImages.Jobs.ProcessImage.csproj -c Release -o artifacts/processimage
Assert-Ok "dotnet publish (processimage)"

# ---------------------------------------------------------------- 2. Resource group
Write-Host "=== 2/8  Resource group ===" -ForegroundColor Cyan

az group create -n $ResourceGroup -l $ResourceGroupLocation `
    --tags project=weather-images course=cloud-computing-minor student=707875 -o none
Assert-Ok "az group create"

# ---------------------------------------------------------------- 3. Log Analytics
Write-Host "=== 3/8  Log Analytics workspace ===" -ForegroundColor Cyan

az monitor log-analytics workspace create -g $ResourceGroup -n $logAnalyticsName -l $Location -o none
Assert-Ok "az monitor log-analytics workspace create"

$wsId = az monitor log-analytics workspace show -g $ResourceGroup -n $logAnalyticsName --query customerId -o tsv
Assert-Ok "reading the Log Analytics workspace id"

$wsKey = az monitor log-analytics workspace get-shared-keys -g $ResourceGroup -n $logAnalyticsName --query primarySharedKey -o tsv
Assert-Ok "reading the Log Analytics workspace key"

# ---------------------------------------------------------------- 4. Container Apps environment
Write-Host "=== 4/8  Container Apps environment ===" -ForegroundColor Cyan

# Created with the Azure CLI rather than Bicep: ARM has no flag to avoid "express"
# environments, and express environments do not support Container Apps Jobs.
# main.bicep references this environment with `existing`. See README.
$envExists = az containerapp env list -g $ResourceGroup --query "[?name=='$environmentName'] | length(@)" -o tsv
Assert-Ok "az containerapp env list"

if ($envExists -eq '0') {
    az containerapp env create -n $environmentName -g $ResourceGroup -l $EnvironmentLocation `
        --enable-workload-profiles true --logs-workspace-id $wsId --logs-workspace-key $wsKey -o none
    Assert-Ok "az containerapp env create"
} else {
    Write-Host "    already exists, skipping"
}

# ---------------------------------------------------------------- 5. Container registry
Write-Host "=== 5/8  Container registry ===" -ForegroundColor Cyan

az acr create -n $acrName -g $ResourceGroup -l $Location --sku Basic --admin-enabled true -o none
Assert-Ok "az acr create"

az acr login -n $acrName
Assert-Ok "az acr login"

# ---------------------------------------------------------------- 6. Build images
Write-Host "=== 6/8  Building container images (tag: $ImageTag) ===" -ForegroundColor Cyan

docker build -f Dockerfile.api -t "$acrServer/weatherimages-api:$ImageTag" .
Assert-Ok "docker build (api)"

docker build -f Dockerfile.fetchweather -t "$acrServer/weatherimages-fetchweather:$ImageTag" .
Assert-Ok "docker build (fetchweather)"

docker build -f Dockerfile.processimage -t "$acrServer/weatherimages-processimage:$ImageTag" .
Assert-Ok "docker build (processimage)"

# ---------------------------------------------------------------- 7. Push images
Write-Host "=== 7/8  Pushing images ===" -ForegroundColor Cyan

docker push "$acrServer/weatherimages-api:$ImageTag"
Assert-Ok "docker push (api)"

docker push "$acrServer/weatherimages-fetchweather:$ImageTag"
Assert-Ok "docker push (fetchweather)"

docker push "$acrServer/weatherimages-processimage:$ImageTag"
Assert-Ok "docker push (processimage)"

# ---------------------------------------------------------------- 8. Bicep deployment
Write-Host "=== 8/8  Deploying resources from the Bicep template ===" -ForegroundColor Cyan

az deployment group create `
    --resource-group $ResourceGroup `
    --template-file infra/main.bicep `
    --parameters namePrefix=$NamePrefix location=$Location environmentLocation=$EnvironmentLocation imageTag=$ImageTag `
    -o none
Assert-Ok "az deployment group create"

$fqdn = az deployment group show -g $ResourceGroup -n main --query properties.outputs.apiFqdn.value -o tsv
Assert-Ok "reading the deployment output"

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host "  API : https://$fqdn"
Write-Host "  Try : Invoke-RestMethod -Method Post -Uri `"https://$fqdn/api/images`""
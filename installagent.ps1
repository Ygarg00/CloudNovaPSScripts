<#  
.SYNOPSIS  
    Adds an WVD Session Host to an existing WVD Hostpool *** SPRING UPDATE 2020***
.DESCRIPTION  
    This scripts adds an WVD Session Host to an existing WVD Hostpool by performing the following action:
    - Download the WVD agent
    - Download the WVD Boot Loader
    - Install the WVD Agent, using the provided hostpoolRegistrationToken
    - Install the WVD Boot Loader
    - Set the WVD Host into drain mode (optionally)
    - Create the Workspace <-> App Group Association (optionally)
    The script is designed and optimized to run as PowerShell Extension as part of a JSON deployment.
.NOTES  
    File Name  : add-WVDHostToHostpoolSpring.ps1
    Author     : Freek Berson - Wortell - RDSGurus
    Version    : v1.3.8
.EXAMPLE
    .\Add-WVDHostToHostpool.ps1 existingWVDWorkspaceName existingWVDHostPoolName `
      existingWVDAppGroupName servicePrincipalApplicationID servicePrincipalPassword azureADTenantID 
      resourceGroupName azureSubscriptionID Drainmode createWorkspaceAppGroupAsso >> <yourlogdir>\dd-WVDHostToHostpoolSpring.log
.DISCLAIMER
    Use at your own risk. This scripts are provided AS IS without warranty of any kind. The author further disclaims all implied
    warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose. The entire risk
    arising out of the use or performance of the scripts and documentation remains with you. In no event shall the author, or anyone else involved
    in the creation, production, or delivery of the scripts be liable for any damages whatsoever (including, without limitation, damages for loss
    of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability
    to use the this script.
#>

#Get Parameters
$existingWVDWorkspaceName = $args[0]
$existingWVDHostPoolName = $args[1]
$existingWVDAppGroupName = $args[2]
$servicePrincipalApplicationID = $args[3]
$servicePrincipalPassword = $args[4]
$azureADTenantID =  $args[5]
$resourceGroupName = $args[6]
$azureSubscriptionID = $args[7]
$drainmode = $args[8]
$createWorkspaceAppGroupAsso = $args[9]

#Set Variables
$RootFolder = "C:\Packages\Plugins\"
$WVDAgentInstaller = $RootFolder+"WVD-Agent.msi"
$WVDBootLoaderInstaller = $RootFolder+"WVD-BootLoader.msi"

#Create Folder structure
if (!(Test-Path -Path $RootFolder)){New-Item -Path $RootFolder -ItemType Directory}

#Download and Import Modules
install-packageProvider -Name NuGet -MinimumVErsion 2.8.5.201 -force
Install-Module -Name Az.DesktopVirtualization -AllowClobber -Force
Set-ExecutionPolicy -ExecutionPolicy Bypass -force
Import-Module -Name Az.DesktopVirtualization

#Configure logging
function log
{
   param([string]$message)
   "`n`n$(get-date -f o)  $message" 
}

#Create ServicePrincipal Credential
log "Creating credentials"
$ServicePrincipalCreds = New-Object System.Management.Automation.PSCredential($servicePrincipalApplicationID, (ConvertTo-SecureString $servicePrincipalPassword -AsPlainText -Force))

#Download all source file async and wait for completion
log  "Download WVD Agent & bootloader"
$files = @(
    @{url = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv"; path = $WVDAgentInstaller}
    @{url = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH"; path = $WVDBootLoaderInstaller}
)
$workers = foreach ($f in $files)
{ 
    $wc = New-Object System.Net.WebClient
    Write-Output $wc.DownloadFileTaskAsync($f.url, $f.path)
}
$workers.Result

#Authenticatie against the WVD Tenant
log "Authenticatie against the WVD Tenant"
Connect-AzAccount -ServicePrincipal -Credential $ServicePrincipalCreds  -Tenant $azureADTenantID

#Obtain RdsRegistrationInfotoken
log "Obtain RdsRegistrationInfotoken"
$Registered = Get-AzWvdRegistrationInfo -SubscriptionId "$azureSubscriptionID" -ResourceGroupName "$resourceGroupName" -HostPoolName $existingWVDHostPoolName
if (-not(-Not $Registered.Token)){$registrationTokenValidFor = (NEW-TIMESPAN -Start (get-date) -End $Registered.ExpirationTime | select Days,Hours,Minutes,Seconds)}
log "Token is valid for:$registrationTokenValidFor"
if ((-Not $Registered.Token) -or ($Registered.ExpirationTime -le (get-date)))
{
    $Registered = New-AzWvdRegistrationInfo -SubscriptionId $azureSubscriptionID -ResourceGroupName $resourceGroupName -HostPoolName $existingWVDHostPoolName -ExpirationTime (Get-Date).AddHours(4) -ErrorAction SilentlyContinue
}
$RdsRegistrationInfotoken = $Registered.Token

#Install the WVD Agent
Log "Install the WVD Agent"
Start-Process -FilePath "msiexec.exe" -ArgumentList "/i $WVDAgentInstaller", "/quiet", "/qn", "/norestart", "/passive", "REGISTRATIONTOKEN=$RdsRegistrationInfotoken", "/l* C:\Users\AgentInstall.txt" | Wait-process

#Install the WVD Bootloader
Log "Install the Boot Loader"
Start-Process -FilePath "msiexec.exe" -ArgumentList "/i $WVDBootLoaderInstaller", "/quiet", "/qn", "/norestart", "/passive", "/l* C:\Users\AgentBootLoaderInstall.txt" | Wait-process

#Set WVD Session Host in drain mode
if ($drainmode -eq "Yes")
{
    #Wait 1 minute to let the WVD host register before configuring Drain mode
    Start-sleep 60
    Log "Set WVD Session Host in drain mode"
    $CurrentHostName = [System.Net.Dns]::GetHostByName($env:computerName).hostname
    Update-AzWvdSessionHost -SubscriptionId "$azureSubscriptionID" -ResourceGroupName "$resourceGroupName" -HostPoolName $existingWVDHostPoolName -Name $CurrentHostName -AllowNewSession:$false
}

#Create Workspace-AppGroup Association
if ($createWorkspaceAppGroupAsso -eq "Yes")
{
    Update-AzWvdWorkspace -SubscriptionId "$azureSubscriptionID" -ResourceGroupName "$resourceGroupName" -Name $existingWVDWorkspaceName -ApplicationGroupReference (Get-AzWvdApplicationGroup -SubscriptionId "$azureSubscriptionID" -ResourceGroupName "$resourceGroupName" -Name $existingWVDAppGroupName | select id).id
}

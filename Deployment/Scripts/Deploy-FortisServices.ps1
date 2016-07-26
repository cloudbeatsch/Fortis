#
# Deploy_FortisServices.ps1

Param(
	[string] [Parameter(Mandatory=$true)] $DeploymentPostFix,
	[string] [Parameter(Mandatory=$true)] $Location,
	[string] [Parameter(Mandatory=$true)] $ResourceGroupName,
	[string] [Parameter(Mandatory=$true)] $SubscriptionId,
	[string] [Parameter(Mandatory=$true)] $TwitterConsumerKey,
	[string] [Parameter(Mandatory=$true)] $TwitterConsumerSecret,
	[string] [Parameter(Mandatory=$true)] $TwitterAccessTokenKey,
	[string] [Parameter(Mandatory=$true)] $TwitterAccessTokenSecret,
	[string] [Parameter(Mandatory=$true)] $BoundingBox, 
	[string] [Parameter(Mandatory=$true)] $SparkFilter, 
	[string] [Parameter(Mandatory=$true)] $HdiPassword,
	[Boolean] [Parameter(Mandatory = $true)] $DeploySites,  
	[string] [Parameter(Mandatory=$false)] $MsBuildPath ="C:\Program Files (x86)\MSBuild\14.0\bin",
	[string] [Parameter(Mandatory=$false)] $ZipCmd = "C:\Program Files\7-Zip\7z.exe",
	[string] [Parameter(Mandatory=$false)] $DevenvCmd = "C:\Program Files (x86)\Microsoft Visual Studio 14.0\Common7\IDE\devenv.exe"
)

function GenerateKey() {
	$bytes = New-Object Byte[] 32
	$rand = [System.Security.Cryptography.RandomNumberGenerator]::Create()
	$rand.GetBytes($bytes)
	$rand.Dispose()
	$key = [System.Convert]::ToBase64String($bytes)
	Write-Host $key

	return $key
}
function Convert-HashToString
{
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]
        $Hash
    )
	$hashstr = ""
    $keys = $Hash.keys
    foreach ($key in $keys)
    {
        $v = $Hash[$key]
        $hashstr += $key + "=" + $v + "`n"
    }
    return $hashstr
}

#configure powershell with Azure modules
Import-Module Azure
Import-Module Azure -ErrorAction SilentlyContinue

Write-Host "This script needs to run in an elevated shell (as Administrator)"
Write-Host "Before you start, you need to do the following things:"
Write-Host "1.) run Add-AzureAccount, Login-AzureRmAccount"
Write-Host "---Press a key when ready---"
$x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

# Login-AzureRmAccount
# Add-AzureAccount
# azure login

Set-AzureSubscription -SubscriptionId $SubscriptionId
Select-AzureRmSubscription -SubscriptionId $SubscriptionId
Select-AzureSubscription -SubscriptionId $SubscriptionId

function Create-StorageAccountIfNotExist {
	[CmdletBinding()] 
	param ( 
		[string] [Parameter(Mandatory = $true)] $StorageRGName,
		[string] [Parameter(Mandatory = $true)] $StorageAccountName
	)

     $StorageAccount = Get-AzureRmStorageAccount | Where-Object {$_.StorageAccountName -eq $StorageAccountName }  
	 if ($StorageAccount -eq $null) { 
         Write-Host "create storage account $StorageAccountName in $Location" 
		 New-AzureRmResourceGroup -Name $StorageRGName -Location $Location
		 New-AzureRmStorageAccount -ResourceGroup $StorageRGName -AccountName $StorageAccountName -Location $Location -Type "Standard_GRS"
     } 
     else { 
         Write-Host "storage $StorageAccountName already exists" 
     }   
} 

&$MsBuildPath\msbuild.exe ..\..\TrendPipelineServices.sln /p:Configuration=Release /t:Clean /verbosity:quiet
Write-Host "Build Orion-Services\TrendPipelineServices Solution"
&$MsBuildPath\msbuild.exe ..\..\TrendPipelineServices.sln /p:Configuration=Release /t:Publish /p:TargetProfile=Cloud /verbosity:quiet

$DeploymentResourceGroupName = $ResourceGroupName+"-Deployment"
$DeploymentStorageAccount = ($ResourceGroupName + "deployment").ToLower()
Create-StorageAccountIfNotExist $DeploymentResourceGroupName $DeploymentStorageAccount

$FortisRG = Get-AzureRmResourceGroup $ResourceGroupName -ErrorAction SilentlyContinue

if ($FortisRG -eq $null) {
	Write-Host "Deploying ResourceGroup $ResourceGroupName"
	$OptionalParameters = New-Object -TypeName Hashtable
	$OptionalParameters.Add("deploymentPostFix", $DeploymentPostFix)
	$OptionalParameters.Add("boundingBox", $BoundingBox)
	$OptionalParameters.Add("twitterConsumerKey", $TwitterConsumerKey)
	$OptionalParameters.Add("twitterConsumerSecret", $TwitterConsumerSecret)
	$OptionalParameters.Add("twitterAccessTokenKey", $TwitterAccessTokenKey)
	$OptionalParameters.Add("twitterAccessTokenSecret", $TwitterAccessTokenSecret)
	$key = GenerateKey
    $OptionalParameters.Add("eventHubSendPrimaryKey1", $key )
	$key = GenerateKey
    $OptionalParameters.Add("eventHubSendSecondaryKey1", $key )
	$key = GenerateKey
    $OptionalParameters.Add("eventHubListenPrimaryKey1", $key )
	$key = GenerateKey
    $OptionalParameters.Add("eventHubListenSecondaryKey1", $key )
	$key = GenerateKey
    $OptionalParameters.Add("eventHubSendPrimaryKey2", $key )
	$key = GenerateKey
    $OptionalParameters.Add("eventHubSendSecondaryKey2", $key )
	$key = GenerateKey
    $OptionalParameters.Add("eventHubListenPrimaryKey2", $key )
	$key = GenerateKey
    $OptionalParameters.Add("eventHubListenSecondaryKey2", $key )
	$FortisRG = .\Deploy-AzureResourceGroup -ResourceGroupLocation $Location `
		-ResourceGroupName $ResourceGroupName `
		-OptionalParameters $OptionalParameters `
	    -TemplateFile '..\Templates\Fortis.json' `
		-TemplateParametersFile '..\Templates\Fortis.parameters.json' `
		-UploadArtifacts -StorageAccountName $DeploymentStorageAccount
}
else {
	Write-Host "ResourceGroup $ResourceGroupName already exists"
}

$Deployment = Get-AzureRmResourceGroupDeployment $ResourceGroupName
$DataStorageAccountName = $Deployment.Outputs.dataStorageAccountName.Value
$DataStorageAccountKey = $Deployment.Outputs.dataStorageAccountKey.Value
$DataStorageAccountConnectionString = $Deployment.Outputs.dataStorageAccountConnectionString.Value
$ClusterStorageAccountName = $Deployment.Outputs.clusterStorageAccountName.Value
$ClusterStorageAccountKey = $Deployment.Outputs.clusterStorageAccountKey.Value
$RefDataContainer = $Deployment.Outputs.refDataContainer.Value
$WebJobWebSiteName = $Deployment.Outputs.webJobWebSiteName.Value
$KeywordsSAJobName = $Deployment.Outputs.keywordsSAJobName.Value
$GroupsSAJobName = $Deployment.Outputs.groupsSAJobName.Value

if ($DeploySites -eq $true) {
	Write-Host "Starting $KeywordsSAJobName stream analytics job"
	Start-AzureRMStreamAnalyticsJob -ResourceGroupName $ResourceGroupName -Name $KeywordsSAJobName
	Write-Host "Starting $GroupsSAJobName stream analytics job"
	Start-AzureRMStreamAnalyticsJob -ResourceGroupName $ResourceGroupName -Name $GroupsSAJobName

	Write-Host "StorageAccountName: $DataStorageAccountName"
	Write-Host "StorageAccountKey: $DataStorageAccountKey"

	Write-Host "Upload reference data to blob"
	Push-Location
	cd ..\..\
	$RootPath = (Get-Item -Path ".\" -Verbose).FullName
	$AzCopyPath = [System.IO.Path]::Combine($PSScriptRoot, "..\Tools\AzCopy.exe")
	&$AzCopyPath $RootPath\data\refdata\ https://$DataStorageAccountName.blob.core.windows.net/$RefDataContainer /DestKey:$DataStorageAccountKey *.* /S /Y
	Pop-Location

	Write-Host "Deploy all WebJobs to $WebJobWebSiteName"
	.\Deploy-FortisServicesWebJobs $Location $WebJobWebSiteName $DataStorageAccountConnectionString $ZipCmd
}



# from here on, we set up the hdi cluster for scheduling
$HdiResourceGroupName = $ResourceGroupName+"-Hdi"
$FortisHdiRG = Get-AzureRmResourceGroup $HdiResourceGroupName -ErrorAction SilentlyContinue
if ($FortisHdiRG -eq $null) {
	
	$ClusterBaseName = $ResourceGroupName+"Spark"
    $AutomationAccountName = "FortisAutomationAccount"

	$ArtifactsContainerName = "artifacts"
	$ArtifactsBaseUri = "https://$DeploymentStorageAccount.blob.core.windows.net/$ArtifactsContainerName"
	$DeploymentStorageAccountContext = (Get-AzureRmStorageAccount | Where-Object{$_.StorageAccountName -eq $DeploymentStorageAccount}).Context
    New-AzureStorageContainer -Name $ArtifactsContainerName -Context $DeploymentStorageAccountContext -Permission Container -ErrorAction SilentlyContinue *>&1
	$DeploymentStorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $DeploymentResourceGroupName -AccountName $DeploymentStorageAccount).Value[0]

	# define the start time for the scheduler
	$startDate = Get-Date -format yyyy-MM-dd
	$startTime = $startDate+"T23:59:59.9999999+00:00"

	.\Deploy-FortisSparkAutomation -AutomationAccountName $AutomationAccountName `
		-Location $Location `
		-DeploymentStorageAccount $DeploymentStorageAccount `
		-ArtifactsBaseUri $ArtifactsBaseUri `
		-ArtifactsStorageAccountKey $DeploymentStorageAccountKey `
		-HdiResourceGroupName $HdiResourceGroupName `
		-SubscriptionId $SubscriptionId `
		-ClusterStorageAccountName $ClusterStorageAccountName `
		-ClusterStorageAccountKey $ClusterStorageAccountKey `
		-ClusterContainerName $ClusterBaseName `
		-DataStorageAccountName $DataStorageAccountName `
		-DataStorageAccountKey $DataStorageAccountKey `
		-SparkFilter $SparkFilter `
		-HdiPassword $HdiPassword `
		-PyFile "timeSeriesAggregator.py" `
		-PyFolder "fortis" `
		-ScheduleName "WeeklySchedule" `
		-RunbookName "Aggregation" `
		-StartTime $startTime
}
else {
	Write-Host "ResourceGroup $HdiResourceGroupName already exists"
}



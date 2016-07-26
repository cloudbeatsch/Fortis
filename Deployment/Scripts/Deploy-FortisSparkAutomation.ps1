Param(
	[string] [Parameter(Mandatory=$true)] $AutomationAccountName,
	[string] [Parameter(Mandatory=$true)] $Location,
	[string] [Parameter(Mandatory=$true)] $DeploymentStorageAccount,
	[string] [Parameter(Mandatory=$true)] $ArtifactsBaseUri,
	[string] [Parameter(Mandatory=$true)] $ArtifactsStorageAccountKey,
	[string] [Parameter(Mandatory=$true)] $HdiResourceGroupName,
	[string] [Parameter(Mandatory=$true)] $SubscriptionId,
	[string] [Parameter(Mandatory=$true)] $ClusterStorageAccountName,
	[string] [Parameter(Mandatory=$true)] $ClusterStorageAccountKey,
	[string] [Parameter(Mandatory=$true)] $ClusterContainerName,
	[string] [Parameter(Mandatory=$true)] $DataStorageAccountName,
	[string] [Parameter(Mandatory=$true)] $DataStorageAccountKey,
	[string] [Parameter(Mandatory=$true)] $SparkFilter, 
	[string] [Parameter(Mandatory=$true)] $HdiPassword,
	[string] [Parameter(Mandatory=$true)] $PyFile,
	[string] [Parameter(Mandatory=$true)] $PyFolder,
	[string] [Parameter(Mandatory=$true)] $ScheduleName,
	[string] [Parameter(Mandatory=$true)] $RunbookName,
	[string] [Parameter(Mandatory=$true)] $StartTime
)
	Write-Host "Copy the cluster deployment script & template to the artifacts blob - this container needs to have public access"
	$TmpDeployment = "TmpDeployment"
	$TmpDeploymentPath = ".\$TmpDeployment"

	if (Test-Path $TmpDeployment) 
	{
		rd $TmpDeployment -Recurse
	}
	Push-Location
	md $TmpDeployment
	cd $TmpDeployment
	$ps1 = "Automation-FortisHdiRunbook.ps1"
	copy ..\$ps1 
	(Get-Content "$ps1") | 
	
	Foreach-Object {$_ -replace '__SUBSCRIPTION_ID__', $SubscriptionId } |
	Foreach-Object {$_ -replace '__RESOURCE_GROUP_NAME__', $HdiResourceGroupName } |
	Foreach-Object {$_ -replace '__AUTOMATION_ACCOUNT_NAME__', $AutomationAccountName } |
	Out-File $ps1 -Encoding utf8
	
	$rootPath = (Get-Item -Path ".\" -Verbose).FullName
	$azCopyPath = [System.IO.Path]::Combine($rootPath, "..\..\Tools\AzCopy.exe")

	&$azCopyPath $rootPath $ArtifactsBaseUri $ps1 /DestKey:$ArtifactsStorageAccountKey /Y
	cd "..\..\templates"
	$rootPath = (Get-Item -Path ".\" -Verbose).FullName
	&$azCopyPath $rootPath $ArtifactsBaseUri "hdinsight-arm-template.json" /DestKey:$ArtifactsStorageAccountKey /Y
	Pop-Location
	Remove-Item $TmpDeploymentPath -Recurse -Force
	
	Write-Host "Deploying ResourceGroup $HdiResourceGroupName"

	#Set the parameter values for the template
	$OptionalParameters = @{
		accountName = $AutomationAccountName ;
		scriptUri = "$ArtifactsBaseUri/Automation-FortisHdiRunbook.ps1";
		runbookName = $RunbookName;
		scheduleName = $ScheduleName;
		startTime = $StartTime;
	}

	$FortisHdiRG = .\Deploy-AzureResourceGroup -ResourceGroupLocation $Location `
		-ResourceGroupName $HdiResourceGroupName `
		-OptionalParameters $OptionalParameters `
	    -TemplateFile '..\Templates\FortisSpark.json' `
		-TemplateParametersFile '..\Templates\FortisSpark.parameters.json' `
		-UploadArtifacts `
		-StorageAccountName $DeploymentStorageAccount
	Register-AzureRmAutomationScheduledRunbook -AutomationAccountName $AutomationAccountName `
		 -Name $RunbookName `
		 -ScheduleName $ScheduleName `
		 -ResourceGroupName $HdiResourceGroupName



	Write-Host "Create service principles for the runbook"
		.\New-AzureServicePrincipal -ResourceGroup $HdiResourceGroupName `
			-AutomationAccountName $AutomationAccountName `
			-ApplicationDisplayName $AutomationAccountName `
			-SubscriptionId $SubscriptionId `
			-CertPlainPassword $HdiPassword

	$ClusterContainerName = $ClusterBaseName.ToLower()
	$Parameters = @{
		clusterName = "";
		clusterType = "spark"; 
		clusterVersion = "3.4";
		clusterLoginUserName = "admin";
		clusterLoginPassword = $HdiPassword;
		sshUserName = "ops";
		sshPassword = $HdiPassword;
		location = $Location;
		clusterStorageAccountName = $ClusterStorageAccountName
		clusterStorageAccountKey = $ClusterStorageAccountKey
		clusterContainer = $ClusterContainerName;
		dataStorageAccountName = $DataStorageAccountName
		dataStorageAccountKey = $DataStorageAccountKey
		dataContainer = "groups";
    }
	$ParametersString = Convert-HashToString $Parameters
	$Hash = ConvertFrom-StringData -StringData $ParametersString



	# uploading the python job
	Write-Host "Upload python job to hdi blob"
	Push-Location
	cd ..\..\AggregatorSparkJobs
	$rootPath = (Get-Item -Path ".\" -Verbose).FullName
	$azCopyPath = [System.IO.Path]::Combine($rootPath, "..\Deployment\Tools\AzCopy.exe")


	&$azCopyPath $rootPath https://$ClusterStorageAccountName.blob.core.windows.net/$ClusterContainerName/$PyFolder /DestKey:$ClusterStorageAccountKey $PyFile /Y
	Pop-Location

	Write-Host "Set automation variables, inc. $ParametersString"
	New-AzureRmAutomationVariable -ResourceGroupName $HdiResourceGroupName -AutomationAccountName $AutomationAccountName -Name "ClusterBaseName" -Value $ClusterBaseName -Encrypted $false
	New-AzureRmAutomationVariable -ResourceGroupName $HdiResourceGroupName -AutomationAccountName $AutomationAccountName -Name "ArmTemplateUrl" -Value "$ArtifactsBaseUri/hdinsight-arm-template.json" -Encrypted $false
	New-AzureRmAutomationVariable -ResourceGroupName $HdiResourceGroupName -AutomationAccountName $AutomationAccountName -Name "Parameters" -Value $ParametersString -Encrypted $false
	New-AzureRmAutomationVariable -ResourceGroupName $HdiResourceGroupName -AutomationAccountName $AutomationAccountName -Name "Filter" -Value $SparkFilter -Encrypted $false
	New-AzureRmAutomationVariable -ResourceGroupName $HdiResourceGroupName -AutomationAccountName $AutomationAccountName -Name "pyFile" -Value $PyFile -Encrypted $false
	New-AzureRmAutomationVariable -ResourceGroupName $HdiResourceGroupName -AutomationAccountName $AutomationAccountName -Name "pyFolder" -Value $PyFolder -Encrypted $false
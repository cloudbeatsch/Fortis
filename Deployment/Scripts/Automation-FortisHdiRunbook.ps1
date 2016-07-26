$connectionName = "AzureRunAsConnection"
$SubId = "__SUBSCRIPTION_ID__"
   try
   {
      # Get the connection "AzureRunAsConnection "
      $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

      "Logging in to Azure..."
      Add-AzureRmAccount `
         -ServicePrincipal `
         -TenantId $servicePrincipalConnection.TenantId `
         -ApplicationId $servicePrincipalConnection.ApplicationId `
         -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
      "Setting context to a specific subscription"   
      Set-AzureRmContext -SubscriptionId $SubId          
   }
   catch {
       if (!$servicePrincipalConnection)
       {
           $ErrorMessage = "Connection $connectionName not found."
           throw $ErrorMessage
       } else{
           Write-Error -Message $_.Exception
           throw $_.Exception
       }
   } 

Import-Module Azure -ErrorAction SilentlyContinue

"`nConnecting to your Azure subscription ..."
try{Get-AzureRmContext}
catch{Login-AzureRmAccount}

"Create HDI cluster"

$resourceGroupName = "__RESOURCE_GROUP_NAME__"
$AutomationAccountName = "__AUTOMATION_ACCOUNT_NAME__"
$clusterBaseNameParam = 	Get-AzureRmAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $AutomationAccountName -Name "ClusterBaseName" 
$templateFileParam = Get-AzureRmAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $AutomationAccountName -Name "ArmTemplateUrl" 
$parametersStringParam = Get-AzureRmAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $AutomationAccountName -Name "Parameters"
$filterParam = Get-AzureRmAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $AutomationAccountName -Name "Filter" 
$pyFileParam = Get-AzureRmAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $AutomationAccountName -Name "pyFile" 
$pyFolderParam = Get-AzureRmAutomationVariable -ResourceGroupName $resourceGroupName -AutomationAccountName $AutomationAccountName -Name "pyFolder" 


$id = Get-Random -Maximum 10000000
$clusterName = $clusterBaseNameParam.Value + $id
$templateFile = $templateFileParam.Value
$filter = $filterParam.Value 
$pyFile = $pyFileParam.Value 
$pyFolder = $pyFolderParam.Value 

$parametersStringParam.Value
$parameters = ConvertFrom-StringData -StringData $parametersStringParam.Value
$parameters.clusterName = $clusterName
$parameters

# Create the HDI resuorce group
New-AzureRmResourceGroup -Name $resourceGroupName -Location $parameters.location -Force

# Deploy the HDI cluster
New-AzureRmResourceGroupDeployment `
    -Name $clusterName `
    -ResourceGroupName $resourceGroupName `
    -TemplateFile $templateFile `
    -TemplateParameterObject $parameters


$clusterStorageAccount = $parameters.clusterStorageAccountName
$clusterContainer = $parameters.clusterContainer;
$dataStorageAccount = $parameters.dataStorageAccountName
$dataStorageKey = $parameters.dataStorageAccountKey
$dataContainer = $parameters.dataContainer
$filter = "*/*/*/*/*.json"

# Submit the sparkjob
$hdfsfPyFile = "wasb://$clusterContainer@$clusterStorageAccount.blob.core.windows.net/$pyFolder/$pyFile"
$filterExpr = "wasb://$dataContainer@$dataStorageAccount.blob.core.windows.net/$filter"
$job = ('{ "file":"FILE", "args": [ "ACCOUNT_NAME", "ACCOUNT_KEY", "FILTER" ] }').Replace("FILE", $hdfsfPyFile)

$job = ($job).Replace("ACCOUNT_NAME", $dataStorageAccount)
$job = ($job).Replace("ACCOUNT_KEY", $dataStorageKey)
$job = ($job).Replace("FILTER", $filterExpr)

$job

$root = "https://$clusterName.azurehdinsight.net/livy/batches"
$secpasswd = ConvertTo-SecureString $parameters.clusterLoginPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($parameters.clusterLoginUserName, $secpasswd)

$result = Invoke-RestMethod -Method Post `
	-Uri $root `
	-Credential $credential `
	-Body $job `
	-Header @{"Accept" = "application/json"} `
	-ContentType "application/json"

$result.id
$finished = $false

$statusUrl = "$root/" + $result.id
$statusUrl
While ($finished -eq $false)
{
	$status = Invoke-RestMethod -Method Get -Uri $statusUrl -Credential $credential -ContentType "application/json"
	$status.state
	if (($status.state -ne "running") -and ( $status.state -ne "starting")) {
		"ready to shut down cluster"
		$finished = $true
	}
	else {
		Sleep 60
	}
}

"Delete HDI cluster $clusterName in resource group $resourceGroupName"
Remove-AzureRmResource -ResourceGroup $resourceGroupName `
	 -ResourceName $clusterName `
	 -ResourceType "Microsoft.HDInsight/clusters" `
	 -Force	

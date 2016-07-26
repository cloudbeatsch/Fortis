#
# Deploy_AzureWebJob.ps1
#

Param(
	[string] [Parameter(Mandatory=$true)] $Location,
	[string] [Parameter(Mandatory=$true)] $WebsiteName,
	[string] [Parameter(Mandatory=$true)] $WebJobName,
	[string] [Parameter(Mandatory=$true)] $JobCollectionName,
	[string] [Parameter(Mandatory=$true)] $JobType, # e.g. Triggered
	[string] [Parameter(Mandatory=$true)] $JobFile,
	[string] [Parameter(Mandatory=$false)] $UseAzureScheduler = $false,
	[string] [Parameter(Mandatory=$false)] $Interval, # e.g. 5
	[string] [Parameter(Mandatory=$false)] $Frequency, # e.g. Minute
	[string] [Parameter(Mandatory=$false)] $StartTime, # e.g. "2014-01-01" 
	[string] [Parameter(Mandatory=$false)] $EndTime # e.g. "2015-01-01" 

)

$site = Get-AzureRmWebApp -Name $WebsiteName

# check if we already have such a webjob
$existingJob = Get-AzureWebsiteJob -Name $site.Name -JobName $WebJobName -JobType $JobType
if ($existingJob -ne $null)
{
	Write-Host "AzureWebJob $WebJobName in Website $WebsiteName already exists and will be deleted"
	Remove-AzureWebsiteJob -Name $site.Name -JobName $WebJobName -JobType $JobType -Force
}

Write-Host "Create AzureWebJob $WebJobName in Website $WebsiteName"
$job = New-AzureWebsiteJob -Name $site.Name `
  -JobName $WebJobName `
  -JobType $JobType `
  -JobFile $JobFile;
Write-Host "Done"

if ($UseAzureScheduler -eq $true)
{
	$JobCollection = Get-AzureSchedulerJobCollection `
	  -Location $Location `
	  -JobCollectionName $JobCollectionName;

	if ($JobCollection -eq $null)
	{
		Write-Host "Create JobCollection $JobCollectionName"

		$JobCollection = New-AzureSchedulerJobCollection `
			-Location $Location `
			-JobCollectionName $JobCollectionName;
		Write-Host "Done"
	}


	$authPair = "$($site.PublishingUsername):$($site.PublishingPassword)";
	$pairBytes = [System.Text.Encoding]::UTF8.GetBytes($authPair);
	$encodedPair = [System.Convert]::ToBase64String($pairBytes);
	#  -JobCollectionName $JobCollection[0].JobCollectionName `

	Write-Host "Create Schedule for $WebJobName in $JobCollectionName"
	New-AzureSchedulerHttpJob `
	  -JobCollectionName $JobCollectionName `
	  -JobName $WebJobName `
	  -Method POST `
	  -URI "$($job.Url)\run" `
	  -Location $Location `
	  -Interval $Interval `
	  -Frequency $Frequency `
	  -Headers @{ `
		"Content-Type" = "text/plain"; `
		"Authorization" = "Basic $encodedPair"; `
	  };
	Write-Host "Done"
}
#
# Deploy-FortisServicesWebJobs.ps1
# .\Deploy-FortisServicesWebJobs.ps1 
#
Param(
	[string] [Parameter(Mandatory=$true)] $Location,
	[string] [Parameter(Mandatory=$true)] $WebsiteName,
	[string] [Parameter(Mandatory=$true)] $ConnectionString,
	[string] [Parameter(Mandatory=$true)] $ZipCmd
)
	$JobCollectionName = "$WebsiteName-Collection"

	function DeployAndConfigureCSharpWebjob { 
		 [CmdletBinding()] 
		 param ( 
			[string] [Parameter(Mandatory = $true)]  $exe,  
			[string] [Parameter(Mandatory = $true)]  $path,  
			[string] [Parameter(Mandatory=$true)] $WebJobName,
		 	[string] [Parameter(Mandatory=$true)] $JobType, # e.g. Triggered
 			[string] [Parameter(Mandatory=$false)] $UseAzureScheduler = $false,
			[string] [Parameter(Mandatory=$false)] $Interval, # e.g. 5
			[string] [Parameter(Mandatory=$false)] $Frequency # e.g. Minute
		 ) 
		Write-Host "Deploy and Configure $WebJobName in $JobCollectionName"

		Push-Location
		cd $path

		$cfg = [xml](get-content ".\$exe.config")
		$con= $cfg.configuration.connectionStrings.add|?{$_.name -eq "AzureWebJobsStorage"};
		$con.connectionString = $ConnectionString
		$con= $cfg.configuration.connectionStrings.add|?{$_.name -eq "AzureWebJobsDashboard"};
		$con.connectionString = $ConnectionString
		# $PWD is needed to call the local variable see: http://powershell.org/wp/2013/09/26/powershell-gotcha-relative-paths-and-net-methods/
		$cfg.Save("$PWD\$exe.config");

		Write-Host "Create zip file for $path"
		$a = "a"
		$r = "-r"
		$f = "$WebJobName.zip"
		&$ZipCmd $a $r $f > output.log
		del output.log
		Write-Host "Done"

		Pop-Location
		$WebjobFilename = "$path\$f"
		# .\Deploy-AzureWebjob.ps1 $Location $WebsiteName $WebJobName $JobCollectionName Triggered $WebjobFilename 5 Minute
		.\Deploy-AzureWebjob.ps1 $Location $WebsiteName $WebJobName $JobCollectionName $JobType $WebjobFilename $UseAzureScheduler $Interval $Frequency
		Write-Host "Remove $WebjobFilename"
		Remove-Item $WebjobFilename


		Write-Host "Finished Deploy and Configure $WebJobName in $JobCollectionName"
	}

	function DeployAndConfigureNodeWebjob { 
		 [CmdletBinding()] 
		 param ( 
			[string] [Parameter(Mandatory = $true)]  $path,  
			[string] [Parameter(Mandatory=$true)] $WebJobName,
		 	[string] [Parameter(Mandatory=$true)] $JobType, # e.g. Triggered
			[string] [Parameter(Mandatory=$false)] $UseAzureScheduler = $false,
			[string] [Parameter(Mandatory=$false)] $Interval, # e.g. 5
			[string] [Parameter(Mandatory=$false)] $Frequency # e.g. Minute
		 ) 

		Write-Host "Deploy and Configure $WebJobName in $JobCollectionName"

		Push-Location
		cd $path

		Write-Host "install packages"
		npm install

		Write-Host "Create zip file for $path"
		
		$a = "a"
		$r = "-r"
		$f = "$WebJobName.zip"
		&$ZipCmd $a $r $f > output.log
		del output.log
		Write-Host "Done"

		Pop-Location
		$WebjobFilename = "$path\$f"
		.\Deploy-AzureWebjob.ps1 $Location $WebsiteName $WebJobName $JobCollectionName $JobType $WebjobFilename $UseAzureScheduler $Interval $Frequency
		Write-Host "Remove deplyoment zip $WebjobFilename"
		Remove-Item $WebjobFilename 

		Write-Host "Finished Deploy and Configure $WebJobName in $JobCollectionName"
	}

	DeployAndConfigureCSharpWebjob KeywordInferenceWebJob.exe "..\..\KeywordInferenceWebJob\bin\Release" KeywordInferenceWebJob Continuous
    DeployAndConfigureNodeWebjob "..\..\pct-geotwit\jobs\build_user_graph" BuildUserGraphWebJob Continuous 
	DeployAndConfigureNodeWebjob "..\..\pct-geotwit\jobs\infer_location" InferLocationWebJob Triggered $false
	DeployAndConfigureNodeWebjob "..\..\pct-geotwit\jobs\twitter_ingest" TwitterIngestWebJob Continuous
	Push-Location;




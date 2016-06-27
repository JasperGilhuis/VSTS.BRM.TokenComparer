[CmdletBinding(DefaultParameterSetName = 'TokenComparer')]
param
(
      	[string] $targetFiles,
		[string] $tokenPrefix,
		[string] $tokenSuffix,
		[string] $serviceEndpoint,
		[string] $comparerResultAction
)
 
import-module "Microsoft.TeamFoundation.DistributedTask.Task.Internal"
import-module "Microsoft.TeamFoundation.DistributedTask.Task.Common"

# parse the provided files for tokens
function Resolve-PathSafe
{
	param
	(
		[string] $path
	)
	$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
}

# function to get variables
function Find-Properties()
{
    param(
        [Object] $data,
        [string] $type,
        [PSObject] $relObjs
    )

    $data | foreach-object {
        $name = $_.Name
        $value = $_.value
    
        $realValue = $($value.Value)
        if($_.Value.isSecret -eq $True)
        {
          $realValue = "*** secret ***"
        }
        
        $releaseProps = @{'Token'=$name; 'Value'=$realValue; 'Type'=$type; 'AsToken'=''}
        $releaseObj = New-Object -TypeName PSObject -Property $releaseProps
        
        # store object
        $relObjs += $releaseObj
    }
    return $relObjs
}

# function for parsing provided files
function Parse-Files-ForTokens()
{
	param(
		[string] $targetFiles,
		[string] $tokenPrefix,
		[string] $tokenSuffix
	)

	$tokenObjs = @()

	# regex for finding Tokens
	$regex = [regex] "${tokenPrefix}((?:(?!${tokenSuffix}).)*)${tokenSuffix}"

	if (-not $targetFiles -eq "") 
	{ 
		[string[]] $filesToParse = $targetFiles -split ';|\r?\n' 
 		foreach ($item in $filesToParse) 
		{ 
			if ($item){
				$item = Resolve-PathSafe $item
			
				Write-Verbose "Parsing file [$item] for tokens..." -Verbose
				$file = Get-ChildItem $item

				$data = ""
				$file | select-string $regex -AllMatches | % {$_.Matches} | % {  $data+="$($_.Groups[1].Value);"}
				$data.Split(";") | foreach {
					if(-not $_ -eq "")
					{
						Write-Verbose "Found Token [$($_)]"   -Verbose

						$tokenProps = @{'Token'=$_; 'File'=$file.Name; 'AsVariable'=''}
						$tokenObj = New-Object -TypeName PSObject -Property $tokenProps
        
						# store object
						$tokenObjs += $tokenObj

					}
				}
			} 
		}
		return $tokenObjs
	}
}

# compare the two result object collections
function Compare-Collections()
{
	for($i=0; $i -le  $ReleaseVariables.Count -1; $i++)
	{
		$item = $ReleaseVariables[$i]

		$found =  $ReleaseTokens | Where-Object { $_.Token -eq $item.Token } 

		if($found -eq $null)
		{
			$item.AsToken = $False
		}
		else
		{
			$item.AsToken = $True
		}
	}

	for($i=0; $i -le  $ReleaseTokens.Count -1; $i++)
	{
		$item = $ReleaseTokens[$i]

		$found =  $ReleaseVariables | Where-Object { $_.Token -eq $item.Token } 

		if($found -eq $null)
		{
			$item.AsVariable = $False
		}
		else
		{
			$item.AsVariable = $True
		}
	}
}

# render output
function Render-Output()
{
	$svg_red = "<svg width='10' height='10'><rect width='10' height='10' style='fill:rgb(229,20,1);'></svg>"
	$svg_green = "<svg width='10' height='10'><rect width='10' height='10' style='fill:rgb(51,153,51);'></svg>"

 	$stream = [System.IO.StreamWriter] "$env:SYSTEM_DEFAULTWORKINGDIRECTORY\Release.md"
	$stream.WriteLine("<table>")

	foreach ($item in $ReleaseTokens) 
	{
		if($item.AsVariable -eq "False")
		{
			$stream.WriteLine("<tr><td><div>$svg_green Token [$($item.Token)] in file [$($item.File)] has variable defined.</div></td></tr>")
		}
		else
		{
			$stream.WriteLine("<tr><td><div>$svg_red Token [$($item.Token)] in file [$($item.File)] does not have variable defined.</div></td></tr>")
			$script:HasErrors = 1
		}
	}
	$stream.WriteLine("</table>")
	$stream.close()

	Write-Verbose "Has errors:$HasErrors"

	"##vso[task.uploadsummary] $env:SYSTEM_DEFAULTWORKINGDIRECTORY\Release.md"
}

# Render Action output
function Render-Action()
{
	switch($comparerResultAction)
	{
		'continue' {
			 # silent  
		}
		'warn' { 
			if($HasErrors -eq 1)
			{
				Write-Warning "Warning, one or more Tokens do not have a matching variable defined, see the Release Summary for details." 
			}
		}
		'fail' { 
			if($HasErrors -eq 1)
			{
				Write-Error "Error, one or more Tokens do not have a matching variable defined, see the Release Summary for details." 
			}
		}
		default { Write-Verbose "No visuble result action selected." } 
	}
}

############################################## Token Comparer Execution starts here ##########################################
Write-Verbose "Starting TokenComparer..."

# create token/release result containers
$ReleaseVariables = @()
$ReleaseTokens = @()

$VSTSEndpoint = Get-ServiceEndpoint -Context $distributedTaskContext -Name $serviceEndpoint
if ($VSTSEndpoint -eq $null)
{
    throw "Could not locate service endpoint $serviceEndpoint"
}

$vstsuri = $VSTSEndpoint.Url
$userName = $VSTSEndpoint.Authorization.Parameters.UserName
$vstsPAT = $VSTSEndpoint.Authorization.Parameters.Password

# Base64-encodes the Personal Access Token (PAT) appropriately
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(( "{0}:{1}" -f $userName, $vstsPAT )))
           
 
# URL via SP en added "vsrm."

# construct API call URL Release Defnitions
$vsrmUri = $vstsuri -replace "visualstudio.com", "vsrm.visualstudio.com" 
$uri = "$($vsrmUri)_apis/release/definitions?api-version=3.0-preview.1"

Write-Verbose $uri

# execute Get Request to retreive data
$result = Invoke-RestMethod -Uri $uri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)}

# get release definition results
if($result -ne $null -and $result.count -eq 1)
{
	$releaseDetailURL = $result.value.Item(0).url 
	Write-Verbose $releaseDetailURL
}
else
{
	throw "Expected only 1 result. Please check parameters."
}

# get the release defintion variables
$result2 = Invoke-RestMethod -Uri $releaseDetailURL -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)}
	
# Parse Main Variables
$ReleaseVariables = Find-Properties $result2.variables.PSObject.Properties -type "Main Release" -relObjs $ReleaseVariables

# Parse Environment Variables
$result2.environments | foreach-object {
    $ReleaseVariables = Find-Properties $_.variables.PSObject.Properties  -type $_.name -relObjs $ReleaseVariables
}

# Parse Provided Files
$ReleaseTokens = Parse-Files-ForTokens  -targetFiles $targetFiles -tokenPrefix $tokenPrefix -tokenSuffix $tokenSuffix 

# compare the two colletions
Compare-Collections

# Show and Render output
$ReleaseVariables | Out-Default
$ReleaseTokens | Out-Default

# start with no errors
New-Variable -Scope Script -Name HasErrors -Value 0

# Create Output
Render-Output

# Render Task Action
Render-Action

Write-Verbose "Token Comparer == Done...."


      

$PSake.use_exit_on_error = $true

$Here = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"

$RepoRoot = $(Split-Path -parent $Here)
$SolutionRoot = "$RepoRoot\src"

$ProjectName = "StreamExtended"
$GitHubProjectName = "StreamExtended"
$GitHubUserName = "justcoding121"

$SolutionFile = "$SolutionRoot\$ProjectName.sln"

## This comes from the build server iteration
if(!$BuildNumber) { $BuildNumber = $env:APPVEYOR_BUILD_NUMBER }
if(!$BuildNumber) { $BuildNumber = "0"}

## The build configuration, i.e. Debug/Release
if(!$Configuration) { $Configuration = $env:Configuration }
if(!$Configuration) { $Configuration = "Release" }

if(!$Version) { $Version = $env:APPVEYOR_BUILD_VERSION }
if(!$Version) { $Version = "0.0.$BuildNumber" }

if(!$Branch) { $Branch = $env:APPVEYOR_REPO_BRANCH }
if(!$Branch) { $Branch = "local" }

if($Branch -eq "beta" ) { $Version = "$Version-beta" }

$NuGet = Join-Path $RepoRoot ".nuget\nuget.exe"

$MSBuild = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\Community\MSBuild\15.0\Bin\msbuild.exe"
$MSBuild -replace ' ', '` '

FormatTaskName (("-"*25) + "[{0}]" + ("-"*25))

#default task
Task default -depends Clean, Build, Document, Package

#cleans obj, b
Task Clean {
    Get-ChildItem .\ -include bin,obj -Recurse | foreach ($_) { Remove-Item $_.fullname -Force -Recurse }
    exec { . $MSBuild $SolutionFile /t:Clean /v:quiet }
}

#install build tools
Task Install-BuildTools -depends Clean  {
    if(!(Test-Path $MSBuild)) 
    { 
        cinst microsoft-build-tools -y
    }
}

#restore nuget packages
Task Restore-Packages -depends Install-BuildTools  {
    exec { . dotnet restore "$SolutionRoot\$ProjectName.sln" }
}

#build
Task Build -depends Restore-Packages{
    exec { . $MSBuild $SolutionFile /t:Build /v:normal /p:Configuration=$Configuration /t:restore }
}

#publish API documentation changes for GitHub pages under master\docs directory
Task Document -depends Build {

	if($Branch -eq "master")
	{
		
		#use docfx to generate API documentation from source metadata
		docfx docfx.json

		#patch index.json so that it is always sorted
		#otherwise git will think file was changed 
		$IndexJsonFile = "$RepoRoot\docs\index.json"
		$unsorted = Get-Content $IndexJsonFile | Out-String
		[Reflection.Assembly]::LoadFile("$Here\lib\Newtonsoft.Json.dll")
		[System.Reflection.Assembly]::LoadWithPartialName("System")
		$hashTable = [Newtonsoft.Json.JsonConvert]::DeserializeObject($unsorted, [System.Collections.Generic.SortedDictionary[[string],[object]]])
		$obj = [Newtonsoft.Json.JsonConvert]::SerializeObject($hashTable, [Newtonsoft.Json.Formatting]::Indented)
		Set-Content -Path $IndexJsonFile -Value $obj

		#setup clone directory
		$TEMP_REPO_DIR =(Split-Path -parent $RepoRoot) + "\temp-repo-clone"

		If(test-path $TEMP_REPO_DIR)
		{
			Remove-Item $TEMP_REPO_DIR -Force -Recurse
		}

		New-Item -ItemType Directory -Force -Path $TEMP_REPO_DIR

		#clone
		git clone https://github.com/$GitHubUserName/$GitHubProjectName.git --branch master $TEMP_REPO_DIR

		If(test-path "$TEMP_REPO_DIR\docs")
		{
			Remove-Item "$TEMP_REPO_DIR\docs" -Force -Recurse
		}
		New-Item -ItemType Directory -Force -Path "$TEMP_REPO_DIR\docs"

		#cd to docs folder
		cd "$TEMP_REPO_DIR\docs"

		#copy docs to clone directory\docs 
		Copy-Item -Path "$RepoRoot\docs\*" -Destination "$TEMP_REPO_DIR\docs" -Recurse -Force

		#push changes to master
		git config --global credential.helper store
		Add-Content "$HOME\.git-credentials" "https://$($env:github_access_token):x-oauth-basic@github.com`n"
		git config --global user.email $env:github_email
		git config --global user.name "buildbot121"
		git add . -A
		git commit -m "API documentation update by build server"
		git push origin master

		#move cd back to current location
		cd $Here	
	}
}

#package nuget files
Task Package -depends Document {
    exec { . $NuGet pack "$SolutionRoot\$ProjectName\$ProjectName.nuspec" -Properties Configuration=$Configuration -OutputDirectory "$RepoRoot" -Version "$Version" }
}


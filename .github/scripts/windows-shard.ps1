param(
	[Parameter(Mandatory)]
	[ValidateSet('compile', 'link', 'verify')]
	[string] $Mode,
	[Parameter(Mandatory)]
	[string] $BuildPath,
	[string] $Ninja = 'ninja',
	[int] $Shard = 0,
	[int] $ShardCount = 10,
	[string] $ArtifactPath = 'shard-artifact'
)

$ErrorActionPreference = 'Stop'

if ($ShardCount -lt 1 -or $Shard -lt 0 -or $Shard -ge $ShardCount) {
	throw "Invalid shard $Shard of $ShardCount."
}

$build = (Resolve-Path -LiteralPath $BuildPath).Path
$ninjaFile = Join-Path $build 'build-Debug.ninja'
if (-not (Test-Path -LiteralPath $ninjaFile)) {
	throw "Missing $ninjaFile."
}

$targetLines = @(& $Ninja -C $build -f build-Debug.ninja -t targets all)
if ($LASTEXITCODE -ne 0) {
	throw 'Could not read Ninja targets.'
}

$targets = @($targetLines | ForEach-Object {
	if ($_ -match '^(.+\.(?:obj|res)):\s+(.+)$' -and $Matches[2] -ne 'phony') {
		$Matches[1]
	}
} | Sort-Object -Unique)

if ($targets.Count -eq 0) {
	throw 'No compilation targets found.'
}

$shards = @(for ($index = 0; $index -lt $ShardCount; ++$index) {
	,@(for ($target = $index; $target -lt $targets.Count; $target += $ShardCount) {
		$targets[$target]
	})
})

if ($Mode -eq 'verify') {
	$joined = @($shards | ForEach-Object { $_ })
	$unique = @($joined | Sort-Object -Unique)
	if ($joined.Count -ne $targets.Count -or $unique.Count -ne $targets.Count) {
		throw 'Shard coverage is incomplete or duplicated.'
	}
	for ($index = 0; $index -lt $ShardCount; ++$index) {
		Write-Host "Shard $index contains $($shards[$index].Count) targets."
	}
}

if ($Mode -eq 'compile') {
	$selected = @($shards[$Shard])
	Write-Host "Compiling $($selected.Count) targets in shard $Shard of $ShardCount."
	for ($offset = 0; $offset -lt $selected.Count; $offset += 64) {
		$last = [Math]::Min($offset + 63, $selected.Count - 1)
		$batch = @($selected[$offset..$last])
		& $Ninja -C $build -f build-Debug.ninja $batch
		if ($LASTEXITCODE -ne 0) {
			throw "Ninja failed in shard $Shard."
		}
	}
	$artifact = Join-Path $build $ArtifactPath
	foreach ($target in $selected) {
		$source = Join-Path $build $target
		if (-not (Test-Path -LiteralPath $source)) {
			throw "Missing compiled target $target."
		}
		$destination = Join-Path $artifact $target
		New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
		Copy-Item -LiteralPath $source -Destination $destination
	}
	return
}

$commands = @(& $Ninja -C $build -f build-Debug.ninja -t commands Telegram:Debug Updater:Debug)
if ($LASTEXITCODE -ne 0) {
	throw 'Could not read Ninja commands.'
}

$archivePattern = '(?i)(^|[\\/\s"])(lib)\.exe([\s"]|$)'
$applicationPattern = '(?i)(^|[\\/\s"])(?:lld-)?link\.exe([\s"]|$).*/out:"?Debug[\\/](AyuGram|Updater)\.exe"?'
$outputPattern = '(?i)\s/out:"?([^"\s]+)"?'
$responsePattern = '@([^\s]+\.rsp)'
$linkCommands = @($commands | Where-Object {
	($_ -match $archivePattern) -or ($_ -match $applicationPattern)
})
$archives = @($linkCommands | Where-Object { $_ -match $archivePattern })
$applications = @($linkCommands | Where-Object { $_ -match $applicationPattern })
if ($archives.Count -eq 0 -or $applications.Count -ne 2 -or @($linkCommands | Where-Object { $_ -notmatch $outputPattern }).Count) {
	throw 'Could not isolate the archive and application link commands.'
}

$implementation = Get-Content (Join-Path $build 'CMakeFiles\impl-Debug.ninja')
function Get-ResponseFile([string] $command) {
	if ($command -notmatch $responsePattern) {
		return
	}
	$response = $Matches[1]
	$command -match $outputPattern | Out-Null
	$target = $Matches[1]
	$prefix = "build ${target}:"
	$edge = -1
	for ($index = 0; $index -lt $implementation.Count; ++$index) {
		if ($implementation[$index].StartsWith($prefix)) {
			$edge = $index
			break
		}
	}
	if ($edge -lt 0) {
		throw "Could not find the Ninja edge for $target."
	}
	$inputText = $implementation[$edge].Substring($prefix.Length + 1)
	$ruleEnd = $inputText.IndexOf(' ')
	if ($ruleEnd -lt 0) {
		throw "Could not parse the Ninja edge for $target."
	}
	$inputText = $inputText.Substring($ruleEnd + 1)
	$inputEnd = $inputText.Length
	foreach ($marker in @(' | ', ' || ')) {
		$position = $inputText.IndexOf($marker)
		if ($position -ge 0 -and $position -lt $inputEnd) {
			$inputEnd = $position
		}
	}
	$inputs = @($inputText.Substring(0, $inputEnd).Split(' ') | Where-Object { $_ })
	$values = @{}
	for ($index = $edge + 1; $index -lt $implementation.Count; ++$index) {
		$line = $implementation[$index]
		if (-not $line.StartsWith('  ')) {
			break
		}
		if ($line -match '^  (LINK_PATH|LINK_LIBRARIES) = (.*)$') {
			$values[$Matches[1]] = $Matches[2]
		}
	}
	$content = @(
		$inputs
		$values['LINK_PATH']
		$values['LINK_LIBRARIES']
	) | Where-Object { $_ } | ForEach-Object {
		$_.Replace('$:', ':').Replace('$ ', ' ').Replace('$$', '$')
	}
	if ($content.Count -eq 0) {
		throw "Could not create the response file for $target."
	}
	[pscustomobject]@{
		Path = Join-Path $build $response
		Content = $content -join "`r`n"
	}
}

$responseFiles = @($linkCommands | ForEach-Object { Get-ResponseFile $_ })
if ($Mode -eq 'verify') {
	Write-Host "Found $($linkCommands.Count) final commands and $($responseFiles.Count) response files."
	return
}

foreach ($responseFile in $responseFiles) {
	New-Item -ItemType Directory -Path (Split-Path $responseFile.Path) -Force | Out-Null
	[System.IO.File]::WriteAllText(
		$responseFile.Path,
		$responseFile.Content,
		[System.Text.UTF8Encoding]::new($false))
}

Push-Location $build
try {
	foreach ($command in $linkCommands) {
		$command -match $outputPattern | Out-Null
		$output = Join-Path $build $Matches[1]
		New-Item -ItemType Directory -Path (Split-Path $output) -Force | Out-Null
	}
	$commandGroups = @(, $archives; , $applications)
	foreach ($group in $commandGroups) {
		$group | ForEach-Object -Parallel {
			Set-Location $using:build
			& $env:ComSpec /d /s /c $_
			if ($LASTEXITCODE -ne 0) {
				throw 'A final archive or link command failed.'
			}
		} -ThrottleLimit 4
		if (-not $?) {
			throw 'A final archive or link command failed.'
		}
	}
} finally {
	Pop-Location
}

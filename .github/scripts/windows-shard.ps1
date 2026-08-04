param(
	[Parameter(Mandatory)]
	[ValidateSet('compile', 'link', 'verify')]
	[string] $Mode,
	[Parameter(Mandatory)]
	[string] $BuildPath,
	[string] $Ninja = 'ninja',
	[int] $Shard = 0,
	[int] $ShardCount = 6,
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
		New-Item -ItemType HardLink -Path $destination -Target $source | Out-Null
	}
	return
}

$commands = @(& $Ninja -C $build -f build-Debug.ninja -t commands Telegram:Debug Updater:Debug)
if ($LASTEXITCODE -ne 0) {
	throw 'Could not read Ninja commands.'
}

$archivePattern = '(?i)(^|[\\/\s"])(lib)\.exe([\s"]|$)'
$applicationPattern = '(?i)(^|[\\/\s"])link\.exe([\s"]|$).*/out:"?Debug[\\/](AyuGram|Updater)\.exe"?'
$outputPattern = '(?i)\s/out:"?([^"\s]+)"?'
$linkCommands = @($commands | Where-Object {
	($_ -match $archivePattern) -or ($_ -match $applicationPattern)
})
$applications = @($linkCommands | Where-Object { $_ -match $applicationPattern })
if ($linkCommands.Count -eq 0 -or $applications.Count -ne 2 -or @($linkCommands | Where-Object { $_ -notmatch $outputPattern }).Count) {
	throw 'Could not isolate the archive and application link commands.'
}

if ($Mode -eq 'verify') {
	Write-Host "Found $($linkCommands.Count) final archive and link commands."
	return
}

Push-Location $build
try {
	foreach ($command in $linkCommands) {
		$command -match $outputPattern | Out-Null
		$output = Join-Path $build $Matches[1]
		New-Item -ItemType Directory -Path (Split-Path $output) -Force | Out-Null
		& $env:ComSpec /d /s /c $command
		if ($LASTEXITCODE -ne 0) {
			throw 'A final archive or link command failed.'
		}
	}
} finally {
	Pop-Location
}

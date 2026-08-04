param(
	[Parameter(Mandatory)]
	[ValidateSet('compile', 'link', 'verify')]
	[string] $Mode,
	[Parameter(Mandatory)]
	[string] $BuildPath,
	[string] $Ninja = 'ninja',
	[int] $Shard = 0,
	[int] $ShardCount = 4
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

$objects = @($targetLines | ForEach-Object {
	if ($_ -match '^(.+\.obj):\s+(.+)$' -and $Matches[2] -ne 'phony') {
		$Matches[1]
	}
} | Sort-Object -Unique)

if ($objects.Count -eq 0) {
	throw 'No object targets found.'
}

$shards = @(for ($index = 0; $index -lt $ShardCount; ++$index) {
	,@(for ($object = $index; $object -lt $objects.Count; $object += $ShardCount) {
		$objects[$object]
	})
})

if ($Mode -eq 'verify') {
	$joined = @($shards | ForEach-Object { $_ })
	$unique = @($joined | Sort-Object -Unique)
	if ($joined.Count -ne $objects.Count -or $unique.Count -ne $objects.Count) {
		throw 'Shard coverage is incomplete or duplicated.'
	}
	for ($index = 0; $index -lt $ShardCount; ++$index) {
		Write-Host "Shard $index contains $($shards[$index].Count) objects."
	}
}

if ($Mode -eq 'compile') {
	$selected = @($shards[$Shard])
	Write-Host "Compiling $($selected.Count) objects in shard $Shard of $ShardCount."
	for ($offset = 0; $offset -lt $selected.Count; $offset += 64) {
		$last = [Math]::Min($offset + 63, $selected.Count - 1)
		$batch = @($selected[$offset..$last])
		& $Ninja -C $build -f build-Debug.ninja $batch
		if ($LASTEXITCODE -ne 0) {
			throw "Ninja failed in shard $Shard."
		}
	}
	return
}

$commands = @(& $Ninja -C $build -f build-Debug.ninja -t commands Telegram:Debug Updater:Debug)
if ($LASTEXITCODE -ne 0) {
	throw 'Could not read Ninja commands.'
}

$archivePattern = '(?i)(^|[\\/\s"])(lib)\.exe([\s"]|$)'
$applicationPattern = '(?i)(^|[\\/\s"])link\.exe([\s"]|$).*/out:"?Debug[\\/](AyuGram|Updater)\.exe"?'
$linkCommands = @($commands | Where-Object {
	($_ -match $archivePattern) -or ($_ -match $applicationPattern)
})
$applications = @($linkCommands | Where-Object { $_ -match $applicationPattern })
if ($linkCommands.Count -eq 0 -or $applications.Count -ne 2) {
	throw 'Could not isolate the archive and application link commands.'
}

if ($Mode -eq 'verify') {
	Write-Host "Found $($linkCommands.Count) final archive and link commands."
	return
}

Push-Location $build
try {
	foreach ($command in $linkCommands) {
		& $env:ComSpec /d /s /c $command
		if ($LASTEXITCODE -ne 0) {
			throw 'A final archive or link command failed.'
		}
	}
} finally {
	Pop-Location
}

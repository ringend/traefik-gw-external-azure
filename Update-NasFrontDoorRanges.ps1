[CmdletBinding()]
param(
    [string]$Location = 'eastus2'
)

$ErrorActionPreference = 'Stop'
$routesPath = Join-Path $PSScriptRoot 'config\routes.yml'
$original = [System.IO.File]::ReadAllText($routesPath)
$json = & az network list-service-tags --location $Location --query "values[?name=='AzureFrontDoor.Backend'] | [0]" --output json --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Azure service-tag lookup failed with exit code $LASTEXITCODE; routes unchanged."
}
$tag = ($json -join "`n") | ConvertFrom-Json
$prefixes = @($tag.properties.addressPrefixes)
if ($tag.name -ne 'AzureFrontDoor.Backend' -or $prefixes.Count -eq 0) {
    throw 'Missing AzureFrontDoor.Backend prefixes; routes unchanged.'
}
foreach ($prefix in $prefixes) {
    $parts = $prefix.Split('/')
    $address = $null
    $length = 0
    if ($parts.Count -ne 2 -or
        -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
        -not [int]::TryParse($parts[1], [ref]$length)) {
        throw "Invalid service-tag prefix: $prefix"
    }
    $maxLength = if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
    if ($length -le 0 -or $length -gt $maxLength) {
        throw "Unsafe service-tag prefix: $prefix"
    }
}
$pattern = '(?ms)^        # BEGIN generated AzureFrontDoor\.Backend ranges\r?\n.*?^        # END generated AzureFrontDoor\.Backend ranges'
if ([regex]::Matches($original, $pattern).Count -ne 1) {
    throw 'Expected exactly one NAS source-range block; routes unchanged.'
}
$lines = @(
    '        # BEGIN generated AzureFrontDoor.Backend ranges'
    "        # Azure service-tag change number $($tag.properties.changeNumber); refreshed $([DateTime]::UtcNow.ToString('yyyy-MM-dd'))."
    '        sourceRange:'
) + @($prefixes | ForEach-Object { '          - "' + $_ + '"' }) + @(
    '        # END generated AzureFrontDoor.Backend ranges'
)
$updated = [regex]::Replace($original, $pattern, ($lines -join "`n"))
if ([System.IO.File]::ReadAllText($routesPath) -cne $original) {
    throw 'Routes changed during lookup; retry rather than overwrite concurrent edits.'
}
# Keep the inode: the gateway bind-mounts this file and watches it for reloads.
[System.IO.File]::WriteAllText($routesPath, $updated, [System.Text.UTF8Encoding]::new($false))
Write-Output "Updated NAS-only allowlist: $($prefixes.Count) prefixes, change number $($tag.properties.changeNumber)."

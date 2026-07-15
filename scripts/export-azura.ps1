$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = Split-Path -Parent $scriptRoot
$outputRoot = Join-Path $workspaceRoot "azura-export"
$assetsRoot = Join-Path $outputRoot "assets"
$baseUrl = "https://azura-wbs.webflow.io"
$baseUri = [Uri]("$baseUrl/")
$assetExtensions = @(
  ".avif",
  ".css",
  ".eot",
  ".gif",
  ".ico",
  ".jpeg",
  ".jpg",
  ".js",
  ".json",
  ".mp4",
  ".otf",
  ".png",
  ".svg",
  ".ttf",
  ".webm",
  ".webp",
  ".woff",
  ".woff2"
)

$seedRoutes = @(
  "/",
  "/about",
  "/feature",
  "/pricing",
  "/career",
  "/blog",
  "/contact",
  "/privacy-policy",
  "/404",
  "/401",
  "/utility-pages/link-in-bio",
  "/utility-pages/coming-soon",
  "/user-pages/log-in",
  "/user-pages/sign-up",
  "/user-pages/reset-password",
  "/user-pages/update-password",
  "/user-pages/email-confirmation",
  "/utility-pages/style-guide",
  "/utility-pages/instructions",
  "/utility-pages/licenses",
  "/utility-pages/changelog"
)

function Ensure-Directory([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) {
    New-Item -ItemType Directory -Path $path | Out-Null
  }
}

function Get-TextResponse([string]$url) {
  $request = [System.Net.HttpWebRequest]::Create($url)
  $request.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  try {
    $response = $request.GetResponse()
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) {
      $response = $_.Exception.Response
    } else {
      throw
    }
  }

  try {
    $stream = $response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($stream)
    try {
      return [pscustomobject]@{
        Content = $reader.ReadToEnd()
        Status = [int]$response.StatusCode
      }
    } finally {
      $reader.Close()
    }
  } finally {
    $response.Close()
  }
}

function Save-BinaryResponse([string]$url, [string]$path) {
  Ensure-Directory (Split-Path -Parent $path)
  $request = [System.Net.HttpWebRequest]::Create($url)
  $request.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  try {
    $response = $request.GetResponse()
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) {
      $response = $_.Exception.Response
    } else {
      throw
    }
  }

  try {
    $inputStream = $response.GetResponseStream()
    $outputStream = [System.IO.File]::Create($path)
    try {
      $inputStream.CopyTo($outputStream)
    } finally {
      $outputStream.Close()
    }
  } finally {
    $response.Close()
  }
}

function Normalize-Route([string]$route) {
  if ([string]::IsNullOrWhiteSpace($route)) {
    return $null
  }

  $clean = $route.Split("#")[0].Split("?")[0]
  if ([string]::IsNullOrWhiteSpace($clean) -or $clean -eq "/") {
    return "/"
  }

  $clean = "/" + $clean.Trim("/")
  return $clean
}

function Resolve-InternalRoute([string]$href) {
  if ([string]::IsNullOrWhiteSpace($href)) {
    return $null
  }

  $value = [System.Net.WebUtility]::HtmlDecode($href).Trim()
  if ($value.StartsWith("#") -or $value -match "^(?i)(mailto|tel|javascript):") {
    return $null
  }

  $uri = $null
  if ([Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
    if ($uri.Host -ne $baseUri.Host) {
      return $null
    }

    return Normalize-Route $uri.AbsolutePath
  }

  if ($value.StartsWith("/")) {
    $resolved = [Uri]::new($baseUri, $value)
    return Normalize-Route $resolved.AbsolutePath
  }

  return $null
}

function Get-PageRelativePath([string]$route) {
  $normalized = Normalize-Route $route
  if ($normalized -eq "/") {
    return "index.html"
  }

  $trimmed = $normalized.Trim("/")
  $parts = $trimmed -split "/"
  if ($parts.Length -eq 1) {
    return $parts[0] + ".html"
  }

  return (Join-Path -Path ($parts[0..($parts.Length - 2)] -join [System.IO.Path]::DirectorySeparatorChar) -ChildPath ($parts[-1] + ".html")).TrimStart([System.IO.Path]::DirectorySeparatorChar)
}

function Get-AssetKey([Uri]$uri) {
  $builder = [UriBuilder]::new($uri)
  $builder.Fragment = ""
  return $builder.Uri.AbsoluteUri
}

function Get-AssetRelativePath([Uri]$uri) {
  $path = $uri.AbsolutePath.TrimStart("/")
  if ([string]::IsNullOrWhiteSpace($path) -or $path.EndsWith("/")) {
    $path = $path.TrimEnd("/") + "/index"
  }

  $parts = @("assets", $uri.Host) + ($path -split "/" | Where-Object { $_ -ne "" })
  return Join-Path -Path ($parts[0..($parts.Length - 2)] -join [System.IO.Path]::DirectorySeparatorChar) -ChildPath $parts[-1]
}

function Get-RelativeFileHref([string]$fromFile, [string]$toFile) {
  $fromDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($fromFile))
  $fromDirUri = [Uri]::new(([System.IO.Path]::GetFullPath($fromDir) + [System.IO.Path]::DirectorySeparatorChar))
  $toUri = [Uri]::new([System.IO.Path]::GetFullPath($toFile))
  return $fromDirUri.MakeRelativeUri($toUri).ToString()
}

function Add-AssetUrl([string]$rawUrl, [Uri]$contextUri, [System.Collections.Generic.Queue[string]]$queue, [hashtable]$queued) {
  if ([string]::IsNullOrWhiteSpace($rawUrl)) {
    return
  }

  $value = [System.Net.WebUtility]::HtmlDecode($rawUrl).Trim()
  if ($value.StartsWith("#") -or $value -match "^(?i)(data|mailto|tel|javascript):") {
    return
  }

  $uri = $null
  if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
    if ($null -eq $contextUri) {
      return
    }
    $uri = [Uri]::new($contextUri, $value)
  }

  if ($uri.Scheme -notin @("http", "https")) {
    return
  }

  if ($uri.Host -eq $baseUri.Host) {
    return
  }

  $extension = [System.IO.Path]::GetExtension($uri.AbsolutePath).ToLowerInvariant()
  if ($extension -notin $assetExtensions) {
    return
  }

  $key = Get-AssetKey $uri
  if (-not $queued.ContainsKey($key)) {
    $queued[$key] = $uri.AbsoluteUri
    $queue.Enqueue($key)
  }
}

function Add-AssetsFromText([string]$text, [Uri]$contextUri, [System.Collections.Generic.Queue[string]]$queue, [hashtable]$queued) {
  foreach ($match in [regex]::Matches($text, "(?i)\b(?:src|href)\s*=\s*[""']([^""']+)[""']")) {
    Add-AssetUrl $match.Groups[1].Value $contextUri $queue $queued
  }

  foreach ($match in [regex]::Matches($text, "(?i)\bsrcset\s*=\s*[""']([^""']+)[""']")) {
    $items = $match.Groups[1].Value -split ","
    foreach ($item in $items) {
      $url = ($item.Trim() -split "\s+")[0]
      Add-AssetUrl $url $contextUri $queue $queued
    }
  }

  foreach ($match in [regex]::Matches($text, "(?i)url\(\s*[""']?([^""')]+)[""']?\s*\)")) {
    Add-AssetUrl $match.Groups[1].Value $contextUri $queue $queued
  }
}

function Rewrite-CssUrls([string]$css, [Uri]$cssUri, [string]$cssFile, [hashtable]$assetMap) {
  return [regex]::Replace($css, "(?i)url\(\s*([""']?)([^""')]+)\1\s*\)", {
    param($match)

    $quote = $match.Groups[1].Value
    $raw = $match.Groups[2].Value
    if ($raw -match "^(?i)(data|mailto|tel|javascript):" -or $raw.StartsWith("#")) {
      return $match.Value
    }

    $resolved = [Uri]::new($cssUri, [System.Net.WebUtility]::HtmlDecode($raw))
    $key = Get-AssetKey $resolved
    if (-not $assetMap.ContainsKey($key)) {
      return $match.Value
    }

    $assetFile = Join-Path $outputRoot $assetMap[$key]
    $relative = Get-RelativeFileHref $cssFile $assetFile
    return "url($quote$relative$quote)"
  })
}

$resolvedWorkspaceRoot = [System.IO.Path]::GetFullPath($workspaceRoot)
$resolvedOutputRoot = [System.IO.Path]::GetFullPath($outputRoot)
if ((Test-Path -LiteralPath $outputRoot) -and $resolvedOutputRoot.StartsWith($resolvedWorkspaceRoot) -and (Split-Path -Leaf $resolvedOutputRoot) -eq "azura-export") {
  Remove-Item -LiteralPath $outputRoot -Recurse -Force
}

Ensure-Directory $outputRoot
Ensure-Directory $assetsRoot

$pageQueue = [System.Collections.Generic.Queue[string]]::new()
$queuedPages = @{}
$pages = [ordered]@{}
$assetQueue = [System.Collections.Generic.Queue[string]]::new()
$queuedAssets = @{}
$assetMap = @{}

foreach ($route in $seedRoutes) {
  $normalized = Normalize-Route $route
  if (-not $queuedPages.ContainsKey($normalized)) {
    $queuedPages[$normalized] = $true
    $pageQueue.Enqueue($normalized)
  }
}

while ($pageQueue.Count -gt 0 -and $pages.Count -lt 150) {
  $route = $pageQueue.Dequeue()
  $url = [Uri]::new($baseUri, $route).AbsoluteUri
  Write-Host "Fetching page $route"
  $response = Get-TextResponse $url
  $pages[$route] = [pscustomobject]@{
    Url = $url
    Status = $response.Status
    Content = $response.Content
  }

  Add-AssetsFromText $response.Content ([Uri]$url) $assetQueue $queuedAssets

  foreach ($match in [regex]::Matches($response.Content, "(?i)\bhref\s*=\s*[""']([^""']+)[""']")) {
    $foundRoute = Resolve-InternalRoute $match.Groups[1].Value
    if ($null -eq $foundRoute) {
      continue
    }
    if ($foundRoute -match "\.[a-zA-Z0-9]{2,6}$") {
      continue
    }
    if (-not $queuedPages.ContainsKey($foundRoute)) {
      $queuedPages[$foundRoute] = $true
      $pageQueue.Enqueue($foundRoute)
    }
  }
}

while ($assetQueue.Count -gt 0) {
  $assetKey = $assetQueue.Dequeue()
  $downloadUrl = $queuedAssets[$assetKey]
  $assetUri = [Uri]$assetKey
  $relativePath = Get-AssetRelativePath $assetUri
  $assetMap[$assetKey] = $relativePath
  $assetFile = Join-Path $outputRoot $relativePath

  if (-not (Test-Path -LiteralPath $assetFile)) {
    Write-Host "Fetching asset $assetKey"
    Save-BinaryResponse $downloadUrl $assetFile
  }

  if ($assetUri.AbsolutePath -match "\.css$") {
    $css = [System.IO.File]::ReadAllText($assetFile)
    Add-AssetsFromText $css $assetUri $assetQueue $queuedAssets
  }
}

foreach ($assetKey in @($assetMap.Keys)) {
  $assetUri = [Uri]$assetKey
  if ($assetUri.AbsolutePath -notmatch "\.css$") {
    continue
  }

  $assetFile = Join-Path $outputRoot $assetMap[$assetKey]
  $css = [System.IO.File]::ReadAllText($assetFile)
  $rewrittenCss = Rewrite-CssUrls $css $assetUri $assetFile $assetMap
  [System.IO.File]::WriteAllText($assetFile, $rewrittenCss, [System.Text.Encoding]::UTF8)
}

foreach ($route in $pages.Keys) {
  $relativePagePath = Get-PageRelativePath $route
  $pageFile = Join-Path $outputRoot $relativePagePath
  Ensure-Directory (Split-Path -Parent $pageFile)
  $html = $pages[$route].Content

  foreach ($assetKey in ($assetMap.Keys | Sort-Object Length -Descending)) {
    $assetFile = Join-Path $outputRoot $assetMap[$assetKey]
    $relativeAsset = Get-RelativeFileHref $pageFile $assetFile
    $html = $html.Replace($assetKey, $relativeAsset)
    $html = $html.Replace(([System.Net.WebUtility]::HtmlEncode($assetKey)), $relativeAsset)
  }

  $html = [regex]::Replace($html, "(?i)\bhref=([""'])([^""']+)\1", {
    param($match)

    $quote = $match.Groups[1].Value
    $href = $match.Groups[2].Value
    $targetRoute = Resolve-InternalRoute $href
    if ($null -eq $targetRoute -or -not $pages.Contains($targetRoute)) {
      return $match.Value
    }

    $targetFile = Join-Path $outputRoot (Get-PageRelativePath $targetRoute)
    $relativeHref = Get-RelativeFileHref $pageFile $targetFile
    return "href=$quote$relativeHref$quote"
  })

  $html = [regex]::Replace($html, "\s+integrity=([""']).*?\1", "")
  $html = [regex]::Replace($html, "\s+crossorigin=([""']).*?\1", "")
  [System.IO.File]::WriteAllText($pageFile, $html, [System.Text.Encoding]::UTF8)
}

$manifest = [pscustomobject]@{
  source = $baseUrl
  generatedAt = (Get-Date).ToString("s")
  pages = @($pages.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{
      route = $_.Key
      file = Get-PageRelativePath $_.Key
      status = $_.Value.Status
      url = $_.Value.Url
    }
  })
  assetCount = $assetMap.Count
}

$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot "manifest.json") -Encoding UTF8

Write-Host "Exported $($pages.Count) pages and $($assetMap.Count) assets to $outputRoot"

$ErrorActionPreference = 'Stop'

$docx = 'src/assets/LISTADO PRODUCTOS EPPTOTAL 2026.DOCX'
$tmp = 'tmp/docx_extract'

if (Test-Path $tmp) {
  Remove-Item -Recurse -Force $tmp
}

New-Item -ItemType Directory -Force -Path $tmp | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($docx, $tmp)

[xml]$relsXml = Get-Content -Raw -Encoding utf8 (Join-Path $tmp 'word/_rels/document.xml.rels')
$relMap = @{}
foreach ($r in $relsXml.Relationships.Relationship) {
  if ($r.Type -like '*image') {
    $relMap[$r.Id] = $r.Target
  }
}

$docRaw = Get-Content -Raw -Encoding utf8 (Join-Path $tmp 'word/document.xml')
$paraMatches = [regex]::Matches($docRaw, '<w:p[\s\S]*?</w:p>')
$paras = @()
foreach ($m in $paraMatches) {
  $p = $m.Value

  $texts = [regex]::Matches($p, '<w:t[^>]*>([\s\S]*?)</w:t>') | ForEach-Object { $_.Groups[1].Value }
  $text = ($texts -join '') -replace '\s+', ' '
  $text = $text.Trim()

  $embeds = [regex]::Matches($p, 'r:embed="(rId\d+)"') | ForEach-Object { $_.Groups[1].Value }
  $targets = @()
  foreach ($e in $embeds) {
    if ($relMap.ContainsKey($e)) {
      $targets += $relMap[$e]
    }
  }

  $paras += [pscustomobject]@{ Text = $text; Targets = $targets }
}

$products = @()
$current = $null
$lastCategory = ''

foreach ($p in $paras) {
  if ($p.Text) {
    $t = $p.Text.Trim()
    if (
      $t.Length -ge 6 -and
      $t -notmatch '^PRODUCTO' -and
      $t -eq $t.ToUpperInvariant() -and
      $t -match '^[^a-z]+' 
    ) {
      $lastCategory = $t
    }
  }

  if ($p.Text -match '^PRODUCTO\s*:\s*(.+)$') {
    if ($current) {
      $products += $current
    }

    $current = [ordered]@{
      category = $lastCategory
      name = ($Matches[1].Trim())
      brand = ''
      description = ''
      features = @()
      productImage = ''
      brandImage = ''
      _images = @()
      _inFeatures = $false
      _inDesc = $false
    }
  }

  if ($current) {
    foreach ($t in $p.Targets) {
      $current._images += $t
    }

    if ($p.Text -match '^Marca\s*:\s*(.+)$') {
      $current.brand = $Matches[1].Trim()
    }

    if ($p.Text -match '^Caracter(í|i)sticas$') {
      $current._inFeatures = $true
      $current._inDesc = $false
      continue
    }

    if ($p.Text -match '^Descripcion$') {
      $current._inDesc = $true
      $current._inFeatures = $false
      continue
    }

    if ($current._inFeatures -and $p.Text -and $p.Text -notmatch '^(Caracter(í|i)sticas|Marca\s*:|Descripcion)$') {
      $current.features += $p.Text
    }

    if ($current._inDesc -and $p.Text -and $p.Text -notmatch '^(Descripcion|Marca\s*:)$') {
      if ($current.description) {
        $current.description += "`n`n" + $p.Text
      } else {
        $current.description = $p.Text
      }
    }
  }
}

if ($current) {
  $products += $current
}

$publicDir = 'public/catalogo'
New-Item -ItemType Directory -Force -Path $publicDir | Out-Null

$dataDir = 'src/data'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

function Slug([string]$s) {
  $s = ($s.ToLowerInvariant() -replace '[^a-z0-9áéíóúñ ]', '' -replace '\s+', ' ').Trim()
  $s = $s -replace 'á', 'a' -replace 'é', 'e' -replace 'í', 'i' -replace 'ó', 'o' -replace 'ú', 'u' -replace 'ñ', 'n'
  return ($s -replace ' ', '-')
}

foreach ($prod in $products) {
  $imgs = @($prod._images | ForEach-Object { $_ -replace '^media/', '' } | Select-Object -Unique)

  if ($imgs.Count -ge 1) {
    $src = Join-Path $tmp ('word/media/' + $imgs[0])
    if (Test-Path $src) {
      $dstName = (Slug($prod.name)) + '-producto' + ([IO.Path]::GetExtension($src))
      Copy-Item -Force $src (Join-Path $publicDir $dstName)
      $prod.productImage = '/catalogo/' + $dstName
    }
  }

  if ($imgs.Count -ge 2) {
    $src = Join-Path $tmp ('word/media/' + $imgs[1])
    if (Test-Path $src) {
      $dstName = (Slug($prod.brand)) + '-marca' + ([IO.Path]::GetExtension($src))
      Copy-Item -Force $src (Join-Path $publicDir $dstName)
      $prod.brandImage = '/catalogo/' + $dstName
    }
  }

  $prod.Remove('_images') | Out-Null
  $prod.Remove('_inFeatures') | Out-Null
  $prod.Remove('_inDesc') | Out-Null
}

$products | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $dataDir 'catalogo.json') -Encoding UTF8

Write-Host ('Productos detectados: ' + $products.Count)

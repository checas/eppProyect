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
  $text = ($texts -join '')
  # Defensive cleanup: in some DOCX exports, stray XML fragments can leak into text
  $text = $text -replace '<[^>]+>', ' '
  $text = $text -replace '&nbsp;|\u00A0', ' '
  $text = $text -replace '\s+', ' '
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
  # Images often appear in paragraphs following the PRODUCTO line; keep attaching them to the current product.
  if ($current) {
    foreach ($t in $p.Targets) {
      $current._images += $t
    }
  }

  # If paragraph has no text, it may still contain images. We've already attached them above.
  if (-not $p.Text) { continue }

  # Sometimes multiple 'PRODUCTO ...' blocks end up in a single paragraph; split them safely.
  $chunks = @($p.Text)
  if ($p.Text -match 'PRODUCTO' -and $p.Text -notmatch '^PRODUCTO') {
    $chunks = [regex]::Split($p.Text, '(?=PRODUCTO\s*[:\-])') | Where-Object { $_.Trim() }
  }

  foreach ($chunk in $chunks) {
    $text = ($chunk -replace '\s+', ' ').Trim()

    # Category heuristic (tight): uppercase headings, short, no digits, known keywords
    $isCategory = $false
    if (
      $text.Length -ge 6 -and $text.Length -le 60 -and
      $text -notmatch '^PRODUCTO' -and
      $text -eq $text.ToUpperInvariant() -and
      $text -notmatch '\d' -and
      $text -notmatch ':' -and
      $text -match '^(PROTECCI|CALZADO|ROPA|SENAL|ALTURA|AUDIT|RESPIR|MANOS|PIES|OCULAR|VISUAL)'
    ) {
      $isCategory = $true
    }

    if ($isCategory) {
      $lastCategory = $text
      if ($current) {
        $current._inDesc = $false
        $current._inFeatures = $false
      }
      continue
    }

    # Product start can be 'PRODUCTO: ...' or 'PRODUCTO - ...'
    $productName = $null
    if ($text -match '^PRODUCTO\s*[:\-]\s*(.+)$') {
      $productName = $Matches[1].Trim()
    } elseif ($text -match '^PRODUCTO\s+(.+)$' -and $text -notmatch '^PRODUCTO\s*$') {
      $productName = $Matches[1].Trim()
    }

    if ($productName) {
      if ($current) {
        $products += $current
      }

      $current = [ordered]@{
        category = $lastCategory
        name = $productName
        brand = ''
        description = ''
        features = @()
        productImage = ''
        brandImage = ''
        _images = @()
        _inFeatures = $false
        _inDesc = $false
      }

      foreach ($t in $p.Targets) {
        $current._images += $t
      }

      continue
    }

    if (-not $current) { continue }

    if ($text -match '^Marca\s*:\s*(.+)$') {
      $current.brand = $Matches[1].Trim()
      continue
    }

    if ($text -match '^Caracter(í|i)sticas\s*:?$') {
      $current._inFeatures = $true
      $current._inDesc = $false
      continue
    }

    if ($text -match '^Descripci(o|ó)n\s*:?$' -or $text -match '^Descripcion\s*:?$') {
      $current._inDesc = $true
      $current._inFeatures = $false
      continue
    }

    if ($current._inFeatures -and $text -and $text -notmatch '^(Caracter(í|i)sticas\s*:|Marca\s*:|Descripci(o|ó)n\s*:|Descripcion\s*:)$') {
      $current.features += $text
      continue
    }

    if ($current._inDesc -and $text -and $text -notmatch '^(Descripci(o|ó)n\s*:|Descripcion\s*:|Marca\s*:)$') {
      if ($current.description) {
        $current.description += "`n`n" + $text
      } else {
        $current.description = $text
      }
      continue
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

  if ($imgs.Count -ge 2 -and $prod.brand) {
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

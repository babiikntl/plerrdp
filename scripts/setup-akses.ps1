# RdpFree: private Tailscale access only. Credit: KallAncrit.
$XyTag = 'RdpFree:access'
. "$PSScriptRoot/lib-common.ps1"
$ErrorActionPreference = 'Stop'
$work = 'C:\ProgramData\RdpFree\access'
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Run-Bounded([string]$File, [string[]]$ArgsList, [int]$Seconds=90) {
  $out = Join-Path $work ([guid]::NewGuid().ToString('N')+'.out')
  $err = "$out.err"
  try {
    $p = Start-Process -FilePath $File -ArgumentList $ArgsList -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
    try { $p | Wait-Process -Timeout $Seconds -ErrorAction Stop } catch { $p | Stop-Process -Force -ErrorAction SilentlyContinue; throw 'Perintah Tailscale melewati timeout' }
    $p.Refresh()
    return @{ code=$p.ExitCode; text=(Get-Content $out -Raw -ErrorAction SilentlyContinue) }
  } finally { Remove-Item $out,$err -Force -ErrorAction SilentlyContinue }
}

function Install-Tailscale {
  param(
    [string]$MsiPath,
    [string]$LogPath
  )

  $installArgs = @('/i', $MsiPath, '/qn', '/norestart', '/L*V', $LogPath)

  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      if (Get-Service -Name Tailscale -ErrorAction SilentlyContinue) {
        Stop-Service -Name Tailscale -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
      }

      $install = Run-Bounded 'msiexec.exe' $installArgs 300
      if ($install.code -in @(0,3010)) { return $true }

      if ($install.code -eq 1603) {
        Log "Installer Tailscale gagal (exit 1603) pada percobaan $attempt/3; membersihkan instalasi lama dan retry."

        $product = Get-CimInstance Win32_Product -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Tailscale' }
        foreach ($p in @($product)) {
          try { & msiexec.exe /x $p.IdentifyingNumber /qn /norestart /L*V $LogPath } catch {}
        }

        Remove-Item 'C:\Program Files\Tailscale' -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item 'C:\ProgramData\Tailscale' -Recurse -Force -ErrorAction SilentlyContinue
        Get-Service -Name Tailscale -ErrorAction SilentlyContinue | Stop-Service -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        continue
      }

      return $false
    } catch {
      Log "Install Tailscale error pada attempt $attempt/3: $($_.Exception.Message)"
      if ($attempt -eq 3) { throw }
      Start-Sleep -Seconds 10
    }
  }

  return $false
}

try {
  if (-not $env:TAILSCALE_AUTH_KEY) { throw 'Isi secret TAILSCALE_AUTH_KEY terlebih dahulu.' }
  $exe = "$env:ProgramFiles\Tailscale\tailscale.exe"
  if (-not (Test-Path $exe)) {
    $msi = Join-Path $work 'tailscale.msi'
    $log = Join-Path $work 'tailscale-install.log'

    $downloadUrls = @(
      'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi',
      'https://pkgs.tailscale.com/stable/tailscale-setup-1.76.6-amd64.msi'
    )

    $downloaded = $false
    foreach ($url in $downloadUrls) {
      if (Get-File $url $msi 90) {
        $downloaded = $true
        break
      }
    }

    if (-not $downloaded) { throw 'Unduhan Tailscale gagal' }

    $signature = Get-AuthenticodeSignature $msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Tailscale') { throw 'Signature installer Tailscale tidak valid' }

    if (-not (Install-Tailscale -MsiPath $msi -LogPath $log)) {
      throw "Installer Tailscale gagal setelah retry, lihat log: $log"
    }
  }

  if (-not (Test-Path $exe)) { throw 'Tailscale CLI tidak ditemukan' }
  Start-Service Tailscale -ErrorAction Stop
  $hostName = ("$env:HOSTNAME-$env:GITHUB_RUN_NUMBER" -replace '[^a-zA-Z0-9-]','').Trim('-')
  if (-not $hostName) { $hostName='rdpfree' }; if ($hostName.Length -gt 60) { $hostName=$hostName.Substring(0,60) }
  $up = Run-Bounded $exe @('up',"--auth-key=$env:TAILSCALE_AUTH_KEY","--hostname=$hostName",'--accept-dns=false','--timeout=90s') 120
  if ($up.code -ne 0) { throw 'Tailscale menolak koneksi. Periksa masa berlaku auth key dan persetujuan perangkat di tailnet.' }
  $state = Run-Bounded $exe @('status','--json') 30
  $status = $state.text | ConvertFrom-Json
  $ip = @($status.Self.TailscaleIPs | Where-Object { $_ -match '^100\.' }) | Select-Object -First 1
  if ($status.BackendState -ne 'Running' -or -not $ip) { throw 'Tailscale belum siap atau belum disetujui oleh pemilik tailnet' }
  $deadline=(Get-Date).AddSeconds(90)
  do {
    $listener=Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
    if ($listener) { break }; Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  if (-not $listener) { throw 'Tailscale tersambung tetapi listener RDP 3389 belum aktif; periksa setup-rdp.' }
  # Restrict known RDP rules to the private tailnet address space.
  Get-NetFirewallRule -Name 'RemoteDesktop-*' -ErrorAction SilentlyContinue | Set-NetFirewallRule -RemoteAddress '100.64.0.0/10' -ErrorAction SilentlyContinue
  Get-NetFirewallRule -DisplayName 'XyDesk Remote*' -ErrorAction SilentlyContinue | Set-NetFirewallRule -RemoteAddress '100.64.0.0/10' -ErrorAction SilentlyContinue
  Update-Status @{ akses=@{mode='tailscale';tailscale=@{status='ok';ip="$ip";magicdns="$($status.Self.DNSName)";hostname=$hostName;note='HP/PC harus login Tailscale pada tailnet yang sama. TCP 3389 dibatasi ke range 100.64.0.0/10.'}}} | Out-Null
  Log "Tailscale siap: $ip`:3389. Tidak ada akses publik."
} catch {
  Update-Status @{ akses=@{mode='tailscale';tailscale=@{status='failed';note=$_.Exception.Message}} } | Out-Null
  throw
}

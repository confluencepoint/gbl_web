# Minimaler statischer HTTP-Server fuer index.html (kein Install noetig).
# Start:  powershell -ExecutionPolicy Bypass -File .\serve.ps1
# Stop:   Strg+C

$ErrorActionPreference = 'Stop'
# Root einmal kanonisch normalisieren: Split-Path liefert das, was
# der Aufrufer als Pfad uebergab. Wird das Skript via "..\..\serve.ps1"
# oder ueber eine Junction gestartet, ist $Root nicht GetFullPath-form
# und der StartsWith-Vergleich kann legitime Pfade ablehnen.
$Root = [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$RootWithSep = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$Port = 8765
$Prefix = "http://127.0.0.1:$Port/"

$Mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.mjs'  = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.woff' = 'font/woff'
    '.woff2'= 'font/woff2'
    '.map'  = 'application/json'
    '.wasm' = 'application/wasm'
    '.txt'  = 'text/plain; charset=utf-8'
}

# Globale Variablen: Event-Handler-ScriptBlocks laufen in einem eigenen
# Runspace, der den Skript-Scope NICHT sieht. $Global: ueberlebt diesen
# Wechsel zuverlaessig. $script: oder gar lokal funktioniert hier nicht.
$Global:GblListener = New-Object System.Net.HttpListener
$Global:GblListener.Prefixes.Add($Prefix)
try {
    $Global:GblListener.Start()
} catch {
    Write-Host "Konnte Listener nicht starten: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Tipp: Port belegt? Mit 'netstat -ano | findstr :$Port' pruefen."
    Remove-Variable -Name GblListener -Scope Global -ErrorAction SilentlyContinue
    exit 1
}

# Strg+C: GetContext() ist ein blockierender Native-.NET-Call. PowerShell
# kann das CancelKeyPress-Signal im Hauptthread nicht verarbeiten, solange
# der Call blockiert. Workaround: CancelKeyPress-Event auf einem ThreadPool-
# Thread abfangen, dort Listener.Stop() rufen. Das bringt GetContext() dazu,
# HttpListenerException zu werfen, was die Loop sauber verlaesst.
# Output via [Console]::Out - Write-Host hat im Event-Runspace keinen
# Konsolen-Host gebunden und schreibt ins Nirgendwo.
$Global:GblStopRequested = $false
$cancelHandler = {
    param($sender, $e)
    $e.Cancel = $true   # PowerShell-Prozess NICHT abrupt killen
    $Global:GblStopRequested = $true
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("Strg+C empfangen - Server wird beendet...")
    if ($Global:GblListener -and $Global:GblListener.IsListening) {
        try { $Global:GblListener.Stop() } catch {}
    }
}
# Vorherigen Handler abmelden, falls das Skript im selben PS-Session
# nochmal gestartet wird. add_CancelKeyPress haelt eine starke Referenz
# auf den Delegate; ohne remove wachsen die Handler kumulativ.
if ($Global:GblCancelHandler) {
    try { [Console]::remove_CancelKeyPress($Global:GblCancelHandler) } catch {}
}
$Global:GblCancelHandler = $cancelHandler
[Console]::add_CancelKeyPress($Global:GblCancelHandler)

Write-Host ""
Write-Host "  GeoBasis Loader Web" -ForegroundColor Cyan
Write-Host "  Serving:   $Root"
Write-Host "  URL:       ${Prefix}index.html" -ForegroundColor Green
Write-Host "  Stop:      Strg+C"
Write-Host ""

try {
    # IsListening flippt auf $false sobald der Cancel-Handler .Stop()
    # ruft; GetContext() wirft dann HttpListenerException und der
    # innere catch raucht die Loop. Zusaetzlich pruefen wir das Flag
    # nicht in der Loop-Bedingung, sondern nur im finally (zur
    # Unterscheidung "Strg+C" vs "anders abgebrochen").
    while ($Global:GblListener.IsListening) {
        try {
            $context = $Global:GblListener.GetContext()
        } catch [System.Net.HttpListenerException] {
            # Listener wurde via Stop() heruntergefahren -> sauber raus.
            break
        } catch [System.ObjectDisposedException] {
            break
        }
        $req = $context.Request
        $res = $context.Response
        $rel = '<unknown>'   # falls UnescapeDataString wirft, soll der 500-Log nicht $rel der Vor-Iteration zeigen
        try {
            $rel = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
            if ([string]::IsNullOrEmpty($rel)) { $rel = 'index.html' }

            # Pfad-Traversal verhindern. StartsWith ist Prefix-anfaellig:
            # `C:\Cursor\gbl_web_evil\foo` wuerde `StartsWith("C:\Cursor\gbl_web")`
            # bestehen. Stattdessen Trailing-Separator anhaengen und vergleichen.
            # $RootWithSep ist einmalig im Startup gesetzt (Modul-Scope).
            $full = [System.IO.Path]::GetFullPath((Join-Path $Root $rel))
            $isInside = ($full -eq $Root) -or
                        $full.StartsWith($RootWithSep, [StringComparison]::OrdinalIgnoreCase)
            if (-not $isInside) {
                $res.StatusCode = 403
                $res.Close()
                continue
            }

            if (-not (Test-Path $full -PathType Leaf)) {
                $res.StatusCode = 404
                $msg = [Text.Encoding]::UTF8.GetBytes("404 Not Found: $rel")
                $res.ContentType = 'text/plain; charset=utf-8'
                $res.OutputStream.Write($msg, 0, $msg.Length)
                $res.Close()
                Write-Host "404 $rel" -ForegroundColor DarkYellow
                continue
            }

            $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
            $ct  = $Mime[$ext]
            $res.ContentType = if ($ct) { $ct } else { 'application/octet-stream' }
            $bytes = [IO.File]::ReadAllBytes($full)
            $res.ContentLength64 = $bytes.Length
            $res.Headers.Add('Cache-Control', 'no-store')
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            $res.Close()
            Write-Host "200 $rel" -ForegroundColor DarkGray
        } catch {
            try {
                $res.StatusCode = 500
                $res.Close()
            } catch {}
            Write-Host "500 $rel : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} finally {
    if ($Global:GblCancelHandler) {
        try { [Console]::remove_CancelKeyPress($Global:GblCancelHandler) } catch {}
    }
    if ($Global:GblListener) {
        try {
            if ($Global:GblListener.IsListening) { $Global:GblListener.Stop() }
            $Global:GblListener.Close()
        } catch {}
    }
    # Sichtbare Erfolgsmeldung im Hauptthread (hier hat Write-Host wieder
    # einen gebundenen Host und kann farbig ausgeben).
    if ($Global:GblStopRequested) {
        Write-Host "Server gestoppt." -ForegroundColor Green
    } else {
        Write-Host "Server beendet." -ForegroundColor DarkGray
    }
    Remove-Variable -Name GblListener, GblStopRequested, GblCancelHandler -Scope Global -ErrorAction SilentlyContinue
}

param([Parameter(Mandatory=$true)][ValidateSet('info','copy-files','collect-logs','send-email','shutdown','cancel-shutdown')][string]$Action,[Parameter(Mandatory=$true)][string]$PayloadPath)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false)
$request=Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
function Progress($Message,$Percent) { [Console]::Error.WriteLine('PARTLY20_PROGRESS:'+(@{message=$Message;percent=$Percent;cancellable=$true}|ConvertTo-Json -Compress)) }
function Cancelled { if($request.cancelPath -and (Test-Path -LiteralPath $request.cancelPath)){throw 'Operation cancelled. Files already copied were preserved.'} }
function Native($Executable,$Arguments) { $text= & $Executable @Arguments 2>&1; if($LASTEXITCODE -ne 0){throw ($text -join "`n")};return ($text -join "`n") }
try {
    switch($Action){
        'info' {
            $machine=[string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
            $hash=[Security.Cryptography.SHA256]::Create()
            try{$pcId=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($machine)))).Replace('-','').Substring(0,24)}finally{$hash.Dispose()}
            $os=Get-CimInstance Win32_OperatingSystem
            $result=@{pcId=$pcId;computerName=$env:COMPUTERNAME;windows=[string]$os.Caption;windowsVersion=[string]$os.Version;architecture=[string]$os.OSArchitecture}
        }
        'copy-files' {
            $sources=@($request.sources)
            if(-not $sources.Count){throw 'Choose at least one file or folder.'}
            $destination=[IO.Path]::GetFullPath([string]$request.destination)
            if(-not (Test-Path -LiteralPath $destination -PathType Container)){throw 'Choose an existing destination folder.'}
            $done=New-Object 'System.Collections.Generic.List[string]'
            for($i=0;$i -lt $sources.Count;$i++){
                Cancelled
                $source=Get-Item -LiteralPath ([string]$sources[$i]) -Force
                $target=Join-Path $destination $source.Name
                if($destination.TrimEnd('\').StartsWith($source.FullName.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $destination.TrimEnd('\') -eq $source.FullName.TrimEnd('\')){throw 'The destination cannot be inside a source folder.'}
                Progress ('Copying '+$source.Name) ([int]($i*100/$sources.Count))
                if($source.PSIsContainer){
                    if((Test-Path -LiteralPath $target) -and -not $request.replaceExisting){throw ('The destination already contains '+$source.Name+'. Enable replace existing files to merge it.')}
                    $args=@($source.FullName,$target,'/E','/COPY:DAT','/DCOPY:DAT','/XJ','/R:1','/W:1','/NP','/NJH','/NJS')
                    $log=& "$env:SystemRoot\System32\robocopy.exe" @args 2>&1
                    if($LASTEXITCODE -ge 8){throw ($log -join "`n")}
                }else{
                    if((Test-Path -LiteralPath $target) -and -not $request.replaceExisting){throw ('The destination already contains '+$source.Name+'.')}
                    Copy-Item -LiteralPath $source.FullName -Destination $target -Force:([bool]$request.replaceExisting)
                    $before=Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256
                    $after=Get-FileHash -LiteralPath $target -Algorithm SHA256
                    if($before.Hash -ne $after.Hash){throw ('Verification failed for '+$source.Name)}
                }
                $done.Add($target)
            }
            Progress 'File copy completed' 100
            $result=@{success=$true;message='Files and folders copied successfully.';files=@($done.ToArray())}
        }
        'collect-logs' {
            $destination=[IO.Path]::GetFullPath([string]$request.destination)
            if([IO.Path]::GetExtension($destination) -ne '.zip'){throw 'Choose a .zip destination.'}
            if(Test-Path -LiteralPath $destination){throw 'The report destination already exists. Choose a new file.'}
            $temporary=Join-Path ([IO.Path]::GetTempPath()) ('partly20-diagnostics-'+[Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $temporary|Out-Null
            try{
                $request.diagnostics|ConvertTo-Json -Depth 25|Set-Content -LiteralPath (Join-Path $temporary 'diagnostics.json') -Encoding UTF8
                if($request.description){[string]$request.description|Set-Content -LiteralPath (Join-Path $temporary 'issue.txt') -Encoding UTF8}
                if($request.includeEvents){
                    foreach($name in @('Application','System')){
                        Cancelled
                        try{Get-WinEvent -LogName $name -MaxEvents 200 -ErrorAction Stop|Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $temporary ($name+'-events.json')) -Encoding UTF8}catch{[string]$_|Set-Content -LiteralPath (Join-Path $temporary ($name+'-unavailable.txt'))}
                    }
                }
                if($request.includeCrashDumps -and $request.crashDirectory -and (Test-Path -LiteralPath $request.crashDirectory)){
                    $dumps=@(Get-ChildItem -LiteralPath $request.crashDirectory -Recurse -File -Filter '*.dmp' -ErrorAction SilentlyContinue|Select-Object -First 5)
                    foreach($dump in $dumps){Cancelled;Copy-Item -LiteralPath $dump.FullName -Destination $temporary}
                }
                Progress 'Compressing diagnostic files' 80
                Compress-Archive -LiteralPath @(Get-ChildItem -LiteralPath $temporary|Select-Object -ExpandProperty FullName) -DestinationPath $destination -CompressionLevel Optimal
            }finally{Remove-Item -LiteralPath $temporary -Recurse -Force}
            $result=@{success=$true;path=$destination;message='Diagnostic report saved.'}
        }
        'send-email' {
            $smtp=$request.smtp
            if(-not [string]$smtp.host -or -not [string]$smtp.from -or -not [string]$smtp.to){throw 'Set the SMTP host, sender, and recipient first.'}
            $mail=New-Object Net.Mail.MailMessage([string]$smtp.from,[string]$smtp.to,[string]$request.subject,[string]$request.body)
            $client=New-Object Net.Mail.SmtpClient([string]$smtp.host,[int]$smtp.port)
            try{
                $client.EnableSsl=[bool]$smtp.tls
                $client.Timeout=30000
                if($smtp.username){$client.Credentials=New-Object Net.NetworkCredential([string]$smtp.username,[string]$smtp.password)}else{$client.UseDefaultCredentials=$false}
                $client.Send($mail)
            }finally{$mail.Dispose();$client.Dispose()}
            $result=@{success=$true;message='Notification email sent.'}
        }
        'shutdown' {Native "$env:SystemRoot\System32\shutdown.exe" @('/s','/t','60','/c','Partly 20 completed all disk operations. Save your work; shutdown begins in 60 seconds.')|Out-Null;$result=@{success=$true;message='Windows will shut down in 60 seconds. You can cancel from Partly 20.'}}
        'cancel-shutdown' {Native "$env:SystemRoot\System32\shutdown.exe" @('/a')|Out-Null;$result=@{success=$true;message='Scheduled shutdown cancelled.'}}
    }
    $result|ConvertTo-Json -Depth 15 -Compress
}catch{@{error=@{message=$_.Exception.Message}}|ConvertTo-Json -Depth 5 -Compress;exit 1}

# EditorHelper.ps1

$TriggerFile = "D:\Virtual_Machines\Editor_Helper\file_to_edit.txt"
$BringEditorToFront = "D:\Virtual_Machines\Editor_Helper\BringEditorToFront.exe"

Write-Host "EditorHelper started. Watching for edit requests..."

while ($true) {
    if (Test-Path $TriggerFile) {
        try {
            # Read the whole command line
            $commandLineRaw = Get-Content $TriggerFile -Raw
            $commandLine = $commandLineRaw.Trim()

            if ([string]::IsNullOrWhiteSpace($commandLine)) {
                Write-Host "Trigger file is empty. Skipping."
            }
            else {
                Write-Host "Launching editor with command: $commandLine"

                # Use Start-Process with -FilePath and -ArgumentList extracted
                # We need to split into executable + arguments safely:
                $parsed = [System.Management.Automation.PSParser]::Tokenize($commandLine, [ref]$null)
                if ($parsed.Count -eq 0) {
                    throw "No command found in trigger file."
                }

                $exe = $parsed[0].Content
                $args = @()
                if ($parsed.Count -gt 1) {
                    $args = $parsed[1..($parsed.Count - 1)] | ForEach-Object { $_.Content }
                }

                # Launch the editor
                $proc = Start-Process -FilePath $exe -ArgumentList $args -PassThru -WindowStyle Normal

                # Optionally bring to front
                #if (Test-Path $BringEditorToFront) {
                    #Start-Process -FilePath $BringEditorToFront
                #}

                # Wait for exit
                $proc.WaitForExit()
                Write-Host "Editing finished."
            }

            # Clean up
            Remove-Item $TriggerFile -Force
        }
        catch {
            Write-Host "Error: $_"
        }
    }
    Start-Sleep -Seconds 1
}

Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd /c python %USERPROFILE%\Projects\dairyplus-data-platform\ingestion\ingest_wms.py", 0, False

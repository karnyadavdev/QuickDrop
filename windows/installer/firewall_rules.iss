; QuickDrop firewall rules.
; Only devices on the same local network can connect.
[Run]
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""QuickDrop UDP Discovery"" dir=in action=allow program=""{app}\QuickDrop.exe"" protocol=UDP localport=55555 profile=any remoteip=localsubnet enable=yes"; Flags: runhidden
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""QuickDrop TCP Transfer"" dir=in action=allow program=""{app}\QuickDrop.exe"" protocol=TCP localport=50005-50050 profile=any remoteip=localsubnet enable=yes"; Flags: runhidden

[UninstallRun]
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""QuickDrop UDP Discovery"""; Flags: runhidden; RunOnceId: "QuickDropRemoveUdpRule"
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""QuickDrop TCP Transfer"""; Flags: runhidden; RunOnceId: "QuickDropRemoveTcpRule"

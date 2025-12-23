# Lagger

Basic Windows lab tool to degrade network throughput using NetQos policy.

## Requirements
- Windows 10/11
- Admin privileges (required for NetQos)

## Run
```
PowerShell -ExecutionPolicy Bypass -File .\Lagger.ps1
```

## Notes
- Uses a NetQos policy named `LagGenerator` to throttle total outbound bandwidth.
- Adds jitter and bursty packet loss by toggling a firewall block rule named `LagGeneratorBlock`.
- You can scope loss to specific ports by editing `$targetPorts` in `Lagger.ps1`.
- Click **Generar lag** to start, **Detener** to stop.

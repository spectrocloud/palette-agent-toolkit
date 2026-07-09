# Palette agent rules

When working with Spectro Cloud Palette clusters or edge hosts:

1. Load the palette skill (`diagnose-cluster`, `diagnose-edge`, or `health-overview`) before taking action.
2. Confirm destructive operations with the user before calling delete or update tools.
3. Use project-scoped queries when the user provides `PALETTE_PROJECT_UID`.

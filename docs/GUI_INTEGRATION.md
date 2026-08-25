# GUI Integration Guide

## How the GUIs Work

Both `.mlapp` files (CWS and MUSIC OTFS) are thin wrappers around `sim_head()`:

1. `startupFcn` calls `saved_profiles()` to populate the profile dropdown
2. Button callbacks build an `app_settings` struct from widget values
3. `sim_head(app_settings)` is called — all path setup, simulation, and figure generation happens inside `sim_head.m`

**The GUIs do NOT call `gen_figure`, `jsonencode_sorted`, or any shared function directly.** All integration with the shared repo is handled by `sim_head.m`.

## What This Means

**No GUI changes are required for the shared repo integration.** The path setup in `sim_head.m` (adding `Common-Wireless-Infrastructure/Meta Functions` to the path) is sufficient.

## Differences Between GUIs

### CWS (`Common Wireless Simulator/CommonWirelessSimulator.mlapp`)
- Simple: builds `app_settings`, calls `sim_head(app_settings)`
- No retry logic, no error handling
- Missing fields: `figure_statistic`, `IgnoreErrorsCheckBox`

### MUSIC OTFS (`MUSIC OTFS Channel Estimation/CommonWirelessSimulator.mlapp`)
- Advanced: retry loop with `ignore_errors`, `finish_flag` return from `sim_head`
- Extra fields: `FigureStatisticDropDown`, `IgnoreErrorsCheckBox`, `TrialsperiterationEditField`
- Uses `NumberofTrialsEditField` (vs CWS's `NumberofFramesEditField`)

### ODDM CE
- No GUI file (CLI only)

## Recommended GUI Updates (Optional)

If you want to standardize the CWS GUI to match MUSIC OTFS features:

### 1. Add `figure_statistic` field to `app_settings`
In `SimulateButtonPushed` and `GenerateFigureButtonPushed`, add:
```matlab
app_settings.figure_statistic = app.FigureStatisticDropDown.Value;
```

### 2. Add retry loop (from MUSIC OTFS)
Replace the direct `sim_head(app_settings)` call with:
```matlab
ignore_errors = app.IgnoreErrorsCheckBox.Value;
finish_flag = false;
while ~finish_flag
    if ignore_errors
        try
            finish_flag = sim_head(app_settings);
        catch
            clc
            fprintf("Error! Restarting...\n")
            pause(5)
        end
    else
        finish_flag = sim_head(app_settings);
    end
end
```

### 3. Add `finish_flag` return to `sim_head.m`
CWS `sim_head.m` currently doesn't return `finish_flag`. Add at the end:
```matlab
finish_flag = true;
```

### 4. Standardize widget names
- CWS uses `FramesIterationEditField` → rename to `TrialsperiterationEditField`
- CWS uses `NumberofFramesEditField` → rename to `NumberofTrialsEditField`

### 5. Create ODDM CE GUI
Clone CWS or MUSIC OTFS `.mlapp` and customize:
- Remove OFDM/OTFS-specific options
- Add ODDM-specific profile options
- Set default database table to ODDM-specific name

## Key Files
- `sim_head.m` — all path setup and dispatch (edit this, not the GUI)
- `saved_profiles.m` — profile definitions (GUI reads from this)
- `gen_figure.m` — figure generation (called by `sim_head.m`)

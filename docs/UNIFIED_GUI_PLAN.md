# Unified GUI Framework Plan

Single `.mlapp` file shared across all wireless projects, like the Meta Functions.

---

## Current State

### CWS GUI (`Common Wireless Simulator.mlapp`)
- 18 UI components
- Class: `CommonWirelessSimulator`
- Database tables: `{'results_TWC', 'OTFS_Journal'}`
- Field names: `NumberofFramesEditField`, `FramesIterationEditField`
- No `FigureStatisticDropDown`
- No `IgnoreErrorsCheckBox`
- No retry loop in Simulate callback
- `sim_head(app_settings)` returns nothing

### MUSIC OTFS GUI (`CommonWirelessSimulator.mlapp`)
- 21 UI components
- Class: `CommonWirelessSimulator` (same UUID as CWS!)
- Database tables: `{'results_MUSIC'}`
- Field names: `NumberofTrialsEditField`, `TrialsperiterationEditField`
- Has `FigureStatisticDropDown` (BER, SER, FER, Thr, RX_iters, t_RXfull, t_RXiter, recon_mse)
- Has `IgnoreErrorsCheckBox` (default true)
- Retry loop: `while ~finish_flag` with `try/catch`
- `sim_head(app_settings)` returns `finish_flag`

### ODDM CE
- No GUI (CLI only)

---

## Unified Component Inventory

Union of all components from both GUIs. Every component gets a standardized name.

| # | Component | Type | CWS | MUSIC | Unified Name | Default |
|---|-----------|------|-----|-------|-------------|---------|
| 1 | Database Table | DropDown | Yes | Yes | `DatabaseTableDropDown` | Dynamic |
| 2 | Save Priority | DropDown | Yes | Yes | `SavePriorityDropDown` | `'local'` |
| 3 | Enable MySQL | CheckBox | Yes | Yes | `EnableMySQLCheckBox` | `false` |
| 4 | Save Excel | CheckBox | Yes | Yes | `SaveExcelCheckBox` | `true` |
| 5 | Parallelization | CheckBox | Yes | Yes | `ParallelizationCheckBox` | `false` |
| 6 | Iteratively Render | CheckBox | Yes | Yes | `IterativelyRenderCheckBox` | `false` |
| 7 | Delete Selected Configs | CheckBox | Yes | Yes | `DeleteSelectedConfigsCheckBox` | `false` |
| 8 | Ignore Errors | CheckBox | No | Yes | `IgnoreErrorsCheckBox` | `true` |
| 9 | Number of Frames | NumericEditField | Yes | Yes | `NumberofFramesEditField` | `100` |
| 10 | Frames per Iteration | NumericEditField | Yes | Yes | `FramesPerIterationEditField` | `10` |
| 11 | Profile Select | DropDown | Yes | Yes | `ProfileSelectDropDown` | `'1'` |
| 12 | Figure Statistic | DropDown | No | Yes | `FigureStatisticDropDown` | `'BER'` |
| 13 | Reload Profiles | Button | Yes | Yes | `ReloadProfilesButton` | — |
| 14 | Simulate | Button | Yes | Yes | `SimulateButton` | — |
| 15 | Generate Figure | Button | Yes | Yes | `GenerateFigureButton` | — |

---

## Key Design Decisions

### 1. Dynamic Profile Population

The GUI calls `saved_profiles()` at startup and populates:
- `ProfileSelectDropDown.Items` — indices `{'1','2',...,'N'}`
- Console output — profile names with indices

This is already how both GUIs work. The unified version does the same.

### 2. Dynamic Database Table Population

The GUI reads a project-specific list of known table names. Two approaches:

**Option A (recommended):** Hard-code a shared list in the GUI:
```matlab
DatabaseTableDropDown.Items = {'results_TWC', 'OTFS_Journal', 'results_MUSIC', 'results_ODDM'};
```

**Option B:** Read from a config file or function. More flexible but adds complexity.

### 3. Figure Statistic Dropdown

Always present in the GUI. When the selected profile's `data_type` is known, the GUI pre-selects it. The user can override.

The `FigureStatisticDropDown` is always visible. The value is passed as `app_settings.figure_statistic`. In `sim_head.m`, this overrides `p.data_type` if provided.

### 4. Simulate Callback with Retry Loop

Adopt the MUSIC OTFS pattern (more robust):
```matlab
finish_flag = false;
while ~finish_flag
    if app.IgnoreErrorsCheckBox.Value
        try
            finish_flag = sim_head(app_settings);
        catch ME
            disp("Error: " + ME.message);
            pause(5);
        end
    else
        finish_flag = sim_head(app_settings);
    end
end
```

### 5. Field Name Standardization

All `app_settings` fields use the Phase 1a names:
- `use_parallel` (not `use_parellelization`)
- `frames_per_iter`
- `priority`
- `save_mysql`
- `save_excel`
- `profile_sel`
- `num_frames`
- `iteratively_render`
- `delete_sel`
- `figure_statistic`

### 6. Figure-Only Mode

`GenerateFigureButton` forces:
```matlab
app_settings.use_parallel = false;
app_settings.num_frames = 0;
app_settings.iteratively_render = false;
app_settings.delete_sel = false;
```

---

## Implementation Plan

### Step 1: Create the .m Code (document.xml content)

The unified GUI is a single MATLAB class file. Since `.mlapp` files are binary/XML archives that can't be easily edited by hand, the implementation approach is:

1. **Write the `.m` file first** — a plain classdef that defines all UI components, callbacks, and layout programmatically
2. **Test it as a plain `.m` file** — run it directly in MATLAB
3. **Convert to `.mlapp`** — open the `.m` file in App Designer and save as `.mlapp`

This is the recommended workflow because:
- `.m` files are version-controllable
- `.m` files can be reviewed in code review
- App Designer can import `.m` app files

### Step 2: Class Structure

```matlab
classdef WirelessSimulator < matlab.apps.AppBase
    % Properties (UI components)
    properties (Access = public)
        UIFigure                    matlab.ui.Figure
        DatabaseTableDropDown       matlab.ui.control.DropDown
        DatabaseTableDropDownLabel  matlab.ui.control.Label
        SavePriorityDropDown        matlab.ui.control.DropDown
        SavePriorityDropDownLabel   matlab.ui.control.Label
        EnableMySQLCheckBox         matlab.ui.control.CheckBox
        SaveExcelCheckBox           matlab.ui.control.CheckBox
        ParallelizationCheckBox     matlab.ui.control.CheckBox
        IterativelyRenderCheckBox   matlab.ui.control.CheckBox
        DeleteSelectedConfigsCheckBox  matlab.ui.control.CheckBox
        IgnoreErrorsCheckBox        matlab.ui.control.CheckBox
        NumberofFramesEditField     matlab.ui.control.NumericEditField
        NumberofFramesEditFieldLabel   matlab.ui.control.Label
        FramesPerIterationEditField matlab.ui.control.NumericEditField
        FramesPerIterationEditFieldLabel  matlab.ui.control.Label
        ProfileSelectDropDown       matlab.ui.control.DropDown
        ProfileSelectDropDownLabel  matlab.ui.control.Label
        FigureStatisticDropDown     matlab.ui.control.DropDown
        FigureStatisticDropDownLabel  matlab.ui.control.Label
        ReloadProfilesButton        matlab.ui.control.Button
        SimulateButton              matlab.ui.control.Button
        GenerateFigureButton        matlab.ui.control.Button
    end

    % Callbacks
    methods (Access = private)
        function startupFcn(app)
        function SimulateButtonPushed(app, event)
        function GenerateFigureButtonPushed(app, event)
        function ReloadProfilesButtonPushed(app, event)
    end

    % App lifecycle
    methods (Access = public)
        function app = WirelessSimulator
        function delete(app)
    end

    methods (Access = private)
        function createComponents(app)
    end
end
```

### Step 3: Layout

Fixed 400x400 pixel layout, matching existing GUIs:

```
y=363: Database Table [dropdown]
y=331: Save Priority  [dropdown]
y=310: [x] Enable MySQL
y=289: [x] Save Excel
y=260: Frames/Iteration [numeric]
y=230: [x] Parallelization
y=195: [button] Reload Profiles   [x] Iteratively Render
y=160: [x] Delete Selected Configs
y=130: [x] Ignore Errors
y=108: Figure Statistic [dropdown]
y=75:  Number of Frames [numeric]
y=46:  Profile Select [dropdown]
y=15:  [button] Simulate  [button] Generate Figure
```

### Step 4: SimulateButtonPushed Callback

```matlab
function SimulateButtonPushed(app, event)
    app_settings = buildSettings(app);
    finish_flag = false;
    while ~finish_flag
        if app.IgnoreErrorsCheckBox.Value
            try
                finish_flag = sim_head(app_settings);
            catch ME
                disp("Error: " + ME.message);
                pause(5);
            end
        else
            finish_flag = sim_head(app_settings);
        end
    end
end
```

### Step 5: buildSettings Helper

```matlab
function settings = buildSettings(app)
    settings.table_name          = app.DatabaseTableDropDown.Value;
    settings.use_parallel        = app.ParallelizationCheckBox.Value;
    settings.frames_per_iter     = app.FramesPerIterationEditField.Value;
    settings.priority            = app.SavePriorityDropDown.Value;
    settings.save_mysql          = app.EnableMySQLCheckBox.Value;
    settings.save_excel          = app.SaveExcelCheckBox.Value;
    settings.profile_sel         = str2double(app.ProfileSelectDropDown.Value);
    settings.num_frames          = app.NumberofFramesEditField.Value;
    settings.iteratively_render  = app.IterativelyRenderCheckBox.Value;
    settings.delete_sel          = app.DeleteSelectedConfigsCheckBox.Value;
    settings.figure_statistic    = app.FigureStatisticDropDown.Value;
end
```

### Step 6: GenerateFigureButtonPushed Callback

```matlab
function GenerateFigureButtonPushed(app, event)
    settings = buildSettings(app);
    settings.use_parallel       = false;
    settings.num_frames         = 0;
    settings.iteratively_render = false;
    settings.delete_sel         = false;
    sim_head(settings);
end
```

### Step 7: startupFcn and ReloadProfiles

```matlab
function startupFcn(app)
    [~, profile_names] = saved_profiles();
    fprintf("\n+----+--------------------------------------+\n");
    fprintf("| #  | Profile Name                         |\n");
    fprintf("+----+--------------------------------------+\n");
    for i = 1:numel(profile_names)
        fprintf("| %2d | %-37s |\n", i, profile_names{i});
    end
    fprintf("+----+--------------------------------------+\n\n");
    app.ProfileSelectDropDown.Items = arrayfun(@num2str, 1:numel(profile_names), 'UniformOutput', false);
end
```

### Step 8: Database Table Items

Hard-coded shared list (covers all current projects):
```matlab
app.DatabaseTableDropDown.Items = {'results_TWC', 'OTFS_Journal', 'results_MUSIC', 'results_ODDM'};
```

### Step 9: Figure Statistic Items

```matlab
app.FigureStatisticDropDown.Items = {'BER', 'SER', 'FER', 'Thr', 'RX_iters', 't_RXfull', 't_RXiter', 'recon_mse'};
```

---

## Changes Required in Other Files

### sim_head.m (all projects)

The `figure_statistic` field from `app_settings` should override `p.data_type` when provided:

```matlab
% In the profile extraction section, after eval loop:
if isfield(app_settings, 'figure_statistic') && ~isempty(app_settings.figure_statistic)
    data_type = app_settings.figure_statistic;
end
```

This replaces the MUSIC OTFS-specific `p_sel.data_type = figure_statistic` line with a generic mechanism.

### sim_head.m Return Value

All `sim_head` functions should return `finish_flag`:
- CWS: change `function sim_head(app_settings)` to `function finish_flag = sim_head(app_settings)` and add `finish_flag = true;` at end
- ODDM CE: same change
- MUSIC OTFS: already returns `finish_flag`

---

## Deployment

1. Save the unified `.m` file as `WirelessSimulator.m` in the shared repo root
2. Each project copies/symlinks it to their project root
3. Users run `WirelessSimulator` to launch the GUI
4. The GUI calls `saved_profiles()` which is project-specific (already on the path)

---

## Migration Checklist

- [ ] Write `WirelessSimulator.m` class file
- [ ] Test with CWS project (all 9 profiles)
- [ ] Test with MUSIC OTFS project (2 profiles)
- [ ] Test with ODDM CE project (2 profiles)
- [ ] Update `sim_head.m` in all projects to accept `figure_statistic` override
- [ ] Update `sim_head.m` in CWS and ODDM CE to return `finish_flag`
- [ ] Save as `.mlapp` via App Designer
- [ ] Add to shared repo
- [ ] Delete old `.mlapp` files from individual projects

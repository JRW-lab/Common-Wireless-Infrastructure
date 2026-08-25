# How to Use the Modular Simulator as a Template

A step-by-step guide for creating new simulation projects from the existing
framework. This template is designed for any project that **generates figures
from individual data points, where each point has different parameter settings**
(e.g. parameter sweeps, ablation studies, sensitivity analyses).

---

## Table of Contents

1. [When to Use This Template](#1-when-to-use-this-template)
2. [Architecture Overview](#2-architecture-overview)
3. [Step-by-Step Setup](#3-step-by-step-setup)
4. [File-by-File Reference](#4-file-by-file-reference)
5. [The Profile Schema](#5-the-profile-schema)
6. [Writing Your Simulation Function](#6-writing-your-simulation-function)
7. [Writing Your Dispatcher](#7-writing-your-dispatcher)
8. [Customizing gen_figure](#8-customizing-gen_figure)
9. [Running Your Project](#9-running-your-project)
10. [Checklist](#10-checklist)

---

## 1. When to Use This Template

This framework fits projects where:

- You sweep over one or more **independent variables** (e.g. SNR, number of
  antennas, velocity, learning rate).
- For each combination of the sweep variable and configuration, you run one or
  more **trials** (Monte Carlo iterations).
- Each trial produces a set of **metrics** (e.g. BER, throughput, accuracy,
  latency).
- You want to **plot** those metrics as line curves, one curve per
  configuration, with the sweep variable on the x-axis.
- You want results **cached** (MySQL or Excel) so re-runs skip already-computed
  points.

If your project matches this pattern, the framework handles the plumbing:
parameter generation, hash-based caching, parallelization, figure rendering,
and data persistence.

---

## 2. Architecture Overview

```
saved_profiles.m          You define parameter sweep profiles
     |
     v
sim_head.m                Orchestrator: reads profile, builds parameter
     |                    grid, runs simulations, renders figures
     v
sim_save.m                Dispatcher: checks cache, calls your sim_fun,
     |                    writes results to DB/Excel
     v
sim_fun_*.m               YOUR code: runs one simulation, returns metrics
     |
     v
gen_figure.m              Shared: plots results from DB/Excel as line figures
```

**Six files you create**, two of which are boilerplate you copy-paste:

| File | Your work | Boilerplate? |
|------|-----------|-------------|
| `saved_profiles.m` | Define sweep profiles | Partial |
| `sim_head.m` | Orchestrator | Mostly copy-paste |
| `sim_save.m` | Dispatcher | Copy-paste |
| `sim_fun_*.m` | Your simulation | 100% yours |
| `.mlapp` (optional) | GUI | Optional |

**Shared infrastructure** (git submodule, not your code):

| File | Purpose |
|------|---------|
| `jsonencode_sorted.m` | Deterministic hashing for cache keys |
| `gen_figure.m` | Line plot generation |
| `gen_table.m` | Console table display |
| `mysql_*.m` | MySQL I/O |
| `local_write.m` | Excel I/O |
| `mergestructs.m` | Struct merging |
| `updateProgressBar.m` | Progress display |

---

## 3. Step-by-Step Setup

### 3.1 Create Your Project Directory

```
MyProject/
├── Comm Functions/           Your simulation code
│   ├── sim_fun_MYSIM.m      Your simulation function
│   └── sim_save.m            Dispatcher (copy from template)
├── Common-Wireless-Infrastructure/   Shared repo (submodule)
│   └── Meta Functions/       Shared functions
├── Data/                     Excel output (auto-created)
├── Figures/                  Saved plots (auto-created)
├── Pre-rendered Lookup Tables/   Cached computations (optional)
├── saved_profiles.m          Profile definitions
└── sim_head.m                Orchestrator
```

### 3.2 Add the Shared Infrastructure

```bash
cd /path/to/MyProject
git submodule add https://github.com/JRW-lab/Common-Wireless-Infrastructure.git
```

If the shared repo is not yet on GitHub, copy the `Meta Functions/` folder
manually:

```bash
cp -r /path/to/Common-Wireless-Infrastructure/Meta Functions MyProject/Common-Wireless-Infrastructure/Meta Functions
```

### 3.3 Copy the Boilerplate Files

From any existing project (e.g. Common Wireless Simulator), copy:

1. `sim_head.m` (you will customize this)
2. `sim_save.m` (you will customize this)

### 3.4 Initialize Git (if needed)

```bash
cd /path/to/MyProject
git init
git add .
git commit -m "Initial project setup from simulator template"
```

---

## 4. File-by-File Reference

### 4.1 `saved_profiles.m` — Define Your Sweeps

This function returns a cell array of **profile structs**, one per experiment
you want to run. Each profile defines what variable to sweep, what values to
sweep over, what configurations to compare, and how to plot the results.

**Signature:**

```matlab
function [all_profiles, profile_names] = saved_profiles()
```

**Minimal working example:**

```matlab
function [all_profiles, profile_names] = saved_profiles()
all_profiles = cell(0);
profile_names = cell(0);

%% PROFILE 1
profile_name = "SNR Sweep";
p = struct;
p.primary_var = "EbN0";           % Field name in default_parameters to sweep
p.primary_vals = 0:2:20;          % Values to sweep over
p.default_parameters = struct(...
    'system_name', "MYSIM", ...
    'M', 64, ...
    'N', 16, ...
    'EbN0', 10, ...               % Default (overridden by primary_vals)
    'SNR', 10);
p.configs = {                     % One struct per curve on the plot
    struct()                       %   Empty = use defaults
    struct('M', 128)              %   Override M for this curve
    };
p.delete_configs = [];            % Configs to delete from DB before running
p.legend_vec = {                  % Legend labels (must match configs length)
    "M = 64"
    "M = 128"
    };
p.line_styles = {                 % MATLAB line style strings
    "-o"
    "-x"
    };
p.line_colors = {                 % Hex color strings
    "#0000FF"
    "#FF0000"
    };
p.vis_type = "figure";            % "figure" or "table"
p.data_type = "BER";              % Metric field name to plot on y-axis
p.legend_loc = "southwest";       % Legend position
p.ylim_vec = [1e-6 1e-1];        % Y-axis limits [min, max]

all_profiles = [all_profiles p];
profile_names = [profile_names profile_name];
end
```

**See [Section 5](#5-the-profile-schema) for the full field reference.**

### 4.2 `sim_head.m` — The Orchestrator

This is the main entry point. It:

1. Reads `app_settings` (from GUI or CLI)
2. Adds paths to MATLAB
3. Loads profiles and selects one
4. Builds a parameter grid (primary_vals x configs)
5. Hashes each parameter set for cache lookup
6. Runs simulations via `sim_save`
7. Renders figures via `gen_figure`

**What you customize:**

- **Path setup** (lines ~31-41): Add paths to your `Comm Functions/` and any
  subdirectories.
- **System-specific field removal** (lines ~169-188): If your project doesn't
  have systems with different field sets, delete or simplify this block.
- **Visualization switch** (lines ~242-249, ~351-358, ~388-395): If you only
  use `"figure"`, simplify to just call `gen_figure`.

**Minimal version (no MySQL, no parallelization):**

```matlab
function sim_head(app_settings)
clc;

% Import settings
profile_sel = app_settings.profile_sel;
num_frames = app_settings.num_frames;
frames_per_iter = app_settings.frames_per_iter;

% Settings
save_data.priority = "local";
save_data.save_excel = true;
save_data.save_mysql = false;
save_data.excel_folder = 'Data';
save_data.excel_name = app_settings.table_name;
save_data.excel_path = fullfile(save_data.excel_folder, ...
    save_data.excel_name + ".xlsx");

% Set paths
addpath(fullfile(pwd, 'Common-Wireless-Infrastructure', 'Meta Functions'));
addpath(fullfile(pwd, 'Comm Functions'));
addMysqlJarOnce();

% Load profiles
all_profiles = saved_profiles();

% Skip simulation if num_frames <= 0
skip_simulations = (num_frames <= 0);

% Extract profile fields into workspace
p_sel = all_profiles{profile_sel};
fields_names = fieldnames(p_sel);
for i = 1:numel(fields_names)
    eval([fields_names{i} ' = p_sel.(fields_names{i});']);
end

% Build figure_data struct
figure_data.ylim_vec = ylim_vec;
figure_data.legend_loc = legend_loc;
figure_data.data_type = data_type;
figure_data.primary_var = primary_var;
figure_data.primary_vals = primary_vals;
figure_data.legend_vec = legend_vec;
figure_data.line_styles = line_styles;
figure_data.line_colors = line_colors;
figure_data.save_sel = true;

% Load existing results
T = table;
if save_data.save_excel
    try
        T = readtable(save_data.excel_path, 'TextType', 'string');
    catch
    end
end
if ~isfolder(save_data.excel_folder), mkdir(save_data.excel_folder); end

% Build parameter grid
prvr_len = length(primary_vals);
conf_len = length(configs);
params_cell = cell(prvr_len, conf_len);
hash_cell = cell(prvr_len, conf_len);
prior_frames = zeros(prvr_len, conf_len);

for primvar_sel = 1:prvr_len
    for sel = 1:conf_len
        parameters = default_parameters;
        parameters.(primary_var) = primary_vals(primvar_sel);
        config_fields = fieldnames(configs{sel});
        for i = 1:length(config_fields)
            parameters.(config_fields{i}) = configs{sel}.(config_fields{i});
        end
        params_cell{primvar_sel, sel} = parameters;
        [~, paramHash] = jsonencode_sorted(parameters);
        hash_cell{primvar_sel, sel} = paramHash;
        try
            sim_result = T(string(T.param_hash) == paramHash, :);
            prior_frames(primvar_sel, sel) = sim_result.frames_simulated;
        catch
        end
    end
end

% Simulation loop
if ~skip_simulations
    num_iters = ceil(num_frames / frames_per_iter);
    for iter = 1:num_iters
        current_frames = min(iter * frames_per_iter, num_frames);
        for primvar_sel = 1:prvr_len
            for sel = 1:conf_len
                if current_frames > prior_frames(primvar_sel, sel)
                    parameters = params_cell{primvar_sel, sel};
                    paramHash = hash_cell{primvar_sel, sel};
                    sim_save(save_data, [], save_data.excel_name, ...
                        current_frames, parameters, paramHash);
                    prior_frames(primvar_sel, sel) = current_frames;
                end
            end
        end
    end
end

% Render figure
gen_figure(save_data, [], save_data.excel_name, hash_cell, configs, figure_data);
end
```

### 4.3 `sim_save.m` — The Dispatcher

This file is **boilerplate**. Copy it from an existing project. It:

1. Checks if results already exist for this parameter hash
2. Calculates how many new frames/trials to run
3. Calls your `sim_fun_*` function
4. Writes results to DB/Excel with weighted averaging

**The only thing you customize** is the `switch parameters.system_name`
block — replace the system names and function calls with your own:

```matlab
switch parameters.system_name
    case "MYSIM"
        metrics_add = sim_fun_MYSIM(new_frames, parameters);
    case "OTHER_SIM"
        metrics_add = sim_fun_OTHER(new_frames, parameters);
    otherwise
        error("Invalid system selected.")
end
```

If you only have one simulation function, simplify to:

```matlab
metrics_add = sim_fun_MYSIM(new_frames, parameters);
```

### 4.4 `sim_fun_*.m` — Your Simulation Function

This is where your actual work lives. The contract is simple:

**Signature:**

```matlab
function metrics_add = sim_fun_MYSIM(new_frames, parameters)
```

**Inputs:**

- `new_frames` — Number of Monte Carlo trials to run (integer)
- `parameters` — Struct with all simulation parameters (from `default_parameters`
  + config overrides + primary_var value)

**Output:**

- `metrics_add` — Struct with **one field per metric** you want to track.
  Each field must be a **scalar** (the mean value over the trials you ran).

**Example:**

```matlab
function metrics_add = sim_fun_MYSIM(new_frames, parameters)

% Unpack parameters
fields = fieldnames(parameters);
for i = 1:numel(fields)
    eval([fields{i} ' = parameters.(fields{i});']);
end

% Initialize accumulators
BER_acc = 0;
SER_acc = 0;

for trial = 1:new_frames
    % --- Your simulation code here ---
    % e.g. generate signal, pass through channel, demodulate, count errors

    % Example: random BER for demonstration
    ber_trial = 10^(-EbN0/10) * (1 + 0.1*randn());
    ser_trial = ber_trial * 2;

    BER_acc = BER_acc + ber_trial;
    SER_acc = SER_acc + ser_trial;
end

% Return MEAN metrics (not sums)
metrics_add = struct();
metrics_add.BER = BER_acc / new_frames;
metrics_add.SER = SER_acc / new_frames;

end
```

**Critical rules:**

- Output must be a **struct** with scalar fields (no vectors, no NaN).
- Return **means** over the trials, not sums. The framework handles weighted
  averaging across multiple runs via `local_write.m` / `mysql_write.m`.
- Field names become the `data_type` values in `gen_figure` (e.g. `"BER"`,
  `"SER"`, `"Thr"`, `"accuracy"`).

---

## 5. The Profile Schema

Each profile struct must contain these fields:

| Field | Type | Description |
|-------|------|-------------|
| `primary_var` | string | Name of the parameter to sweep (must match a field in `default_parameters`) |
| `primary_vals` | numeric vector | Values to sweep over (x-axis of the plot) |
| `default_parameters` | struct | Base parameter set; each field becomes a variable in the workspace |
| `configs` | cell array of structs | One struct per curve; fields override `default_parameters` |
| `delete_configs` | numeric vector | Indices of configs to delete from DB before running (usually `[]`) |
| `legend_vec` | string/cell array | Legend labels; **length must equal `length(configs)`** |
| `line_styles` | cell array of strings | MATLAB line style specs; **length must equal `length(configs)`** |
| `line_colors` | cell array of strings | Hex color strings; **length must equal `length(configs)`** |
| `vis_type` | string | `"figure"` for line plots, `"table"` for console table |
| `data_type` | string | Metric field name to plot (must match a field in `metrics_add`) |
| `legend_loc` | string | MATLAB legend location (e.g. `"southwest"`, `"northeast"`) |
| `ylim_vec` | [min, max] | Y-axis limits |

**Optional fields** (used by `gen_figure`):

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `use_latex` | logical | `true` | Enable LaTeX rendering on labels |
| `num_trials` | integer | `1` | If >1, plot error bars (std dev) |
| `render_title` | logical | `false` | Auto-generate title from parameters |
| `title_vars` | struct | `struct()` | Parameters to show in title |

**Common gotcha:** When you comment out entries in `configs`, you **must**
also comment out the matching entries in `legend_vec`, `line_styles`, and
`line_colors`. All four arrays must have the same length. This is the most
common source of errors.

---

## 6. Writing Your Simulation Function

### 6.1 Unpack Parameters

The standard pattern is:

```matlab
fields = fieldnames(parameters);
for i = 1:numel(fields)
    eval([fields{i} ' = parameters.(fields{i});']);
end
```

This puts every parameter into the workspace as a local variable. After this,
you can use `M`, `N`, `EbN0`, etc. directly.

**Alternative (no eval):**

```matlab
M = parameters.M;
N = parameters.N;
EbN0 = parameters.EbN0;
% ... etc
```

This is safer but more verbose.

### 6.2 Run Trials

```matlab
BER_acc = 0;
for trial = 1:new_frames
    % Your simulation
    BER_acc = BER_acc + trial_ber;
end
metrics_add.BER = BER_acc / new_frames;
```

### 6.3 Return Metrics

The output struct can have any number of fields, but each must be scalar:

```matlab
metrics_add = struct();
metrics_add.BER = 0.0012;
metrics_add.SER = 0.0045;
metrics_add.FER = 0.0123;
metrics_add.Thr = 1.85;    % Throughput
```

These field names become available as `data_type` values in your profiles.

---

## 7. Writing Your Dispatcher

### 7.1 The `sim_save.m` Contract

```
sim_save(save_data, conn, table_name, current_frames, parameters, paramHash)
```

| Argument | Type | Description |
|----------|------|-------------|
| `save_data` | struct | Contains `priority`, `save_excel`, `save_mysql`, `excel_path` |
| `conn` | database connection | MySQL connection (or `[]` for Excel-only) |
| `table_name` | string | Table/file name for results |
| `current_frames` | integer | Target number of frames/trials |
| `parameters` | struct | Full parameter set for this data point |
| `paramHash` | string | SHA-256 hash of `parameters` (from `jsonencode_sorted`) |

### 7.2 Customizing the Switch Statement

Replace the `system_name` dispatch with your own:

```matlab
% Original (multi-system)
switch parameters.system_name
    case "ODDM"
        metrics_add = sim_fun_ODDM_v3(new_frames, parameters);
    case "OTFS"
        metrics_add = sim_fun_OTFS(new_frames, parameters);
end

% Simplified (single system)
metrics_add = sim_fun_MYSIM(new_frames, parameters);
```

---

## 8. Customizing gen_figure

The shared `gen_figure.m` handles most cases automatically. You may need to
customize:

### 8.1 X-Axis Labels

If your `primary_var` isn't in the built-in switch list, add a case:

```matlab
case "my_custom_var"
    xlabel_name = "My Custom Variable (units)";
```

### 8.2 Y-Axis Labels

If your `data_type` isn't in the built-in switch list, the label defaults to
the raw `data_type` string. To add custom formatting:

```matlab
case "accuracy"
    ylabel_name = "Classification Accuracy (\%)";
    y_type = "linear";
    ylim_vec = [0 100];
```

### 8.3 Throughput Formulas

If your project has a custom throughput formula, add a case in the
`data_type == "Thr"` block:

```matlab
case "MY_PROJECT"
    % Your throughput formula
    trial_vals(row_idx) = your_formula(metrics_loaded, params_loaded);
```

### 8.4 Box Plots

For box plots instead of line plots, use `gen_boxplot.m` (separate file, not
part of the shared infrastructure). Create your own version or use the
existing one as a reference.

---

## 9. Running Your Project

### 9.1 From the Command Line

```matlab
% Set up
cd('/path/to/MyProject');

% Define app_settings manually
app_settings.table_name = "my_results";
app_settings.use_parellelization = false;
app_settings.frames_per_iter = 10;
app_settings.priority = "local";
app_settings.save_mysql = false;
app_settings.save_excel = true;
app_settings.profile_sel = 1;
app_settings.num_frames = 100;
app_settings.delete_sel = false;
app_settings.iteratively_render = false;

% Run
sim_head(app_settings);
```

### 9.2 From the GUI

If you created a `.mlapp` file, launch it:

```matlab
MyProjectApp
```

The GUI builds `app_settings` from widget values and calls `sim_head`.

### 9.3 Re-Running with Different Settings

Change `num_frames` to `0` to skip simulations and only re-render the figure:

```matlab
app_settings.num_frames = 0;
sim_head(app_settings);  % Just renders the figure
```

---

## 10. Checklist

Use this checklist when setting up a new project:

- [ ] Created directory structure (`Comm Functions/`, `Data/`, `Figures/`)
- [ ] Added shared infrastructure (submodule or copied `Meta Functions/`)
- [ ] Created `saved_profiles.m` with at least one profile
- [ ] Created `sim_head.m` (copy-paste + customize paths)
- [ ] Created `sim_save.m` (copy-paste + customize dispatch)
- [ ] Created `sim_fun_*.m` (your simulation code)
- [ ] Verified `legend_vec`, `line_styles`, `line_colors` lengths match `configs`
- [ ] Verified `data_type` matches a field in your `metrics_add` output
- [ ] Verified `primary_var` matches a field in `default_parameters`
- [ ] Tested with `num_frames = 0` (figure-only render)
- [ ] Tested with `num_frames = 10` (short simulation run)
- [ ] (Optional) Created `.mlapp` GUI
- [ ] (Optional) Added to git and pushed to GitHub

---

## Appendix A: Field Naming Conventions

| Field | Convention | Example |
|-------|-----------|---------|
| `system_name` | String identifier for the simulation type | `"ODDM"`, `"MUSIC"`, `"MYSIM"` |
| `primary_var` | Must match a field in `default_parameters` | `"EbN0"`, `"vel"`, `"M"` |
| `data_type` | Must match a field in `metrics_add` output | `"BER"`, `"SER"`, `"Thr"` |
| `param_hash` | SHA-256 hex string (auto-generated) | `"a1b2c3..."` |

## Appendix B: Hash-Based Caching

Every unique combination of parameters produces a SHA-256 hash via
`jsonencode_sorted`. This hash is used as the cache key in both MySQL and
Excel. When you re-run a simulation:

1. The framework loads existing results
2. Looks up the hash for each parameter set
3. If found, skips that data point (or runs only the delta frames)
4. If not found, runs the full simulation

This means you can safely interrupt a run and resume later — it will pick up
where it left off.

## Appendix C: Weighted Averaging

When you run additional trials on an already-cached data point, the framework
uses weighted averaging:

```
new_metric = (old_mean * N_old + new_mean * N_new) / (N_old + N_new)
```

This is done automatically by `local_write.m` (Excel) and `mysql_write.m`
(MySQL). You don't need to implement this yourself.

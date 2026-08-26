# Naming Audit & Standardization Plan

Cross-project audit of all naming conventions across CWS, MUSIC OTFS, and ODDM CE.
Each issue lists the current state, the problem, and the proposed standard.

---

## 1. Directory Structure

### Current State

| Directory | CWS | MUSIC OTFS | ODDM CE |
|---|---|---|---|
| `Comm Functions/` | Yes | Yes | Yes |
| `Comm Functions/Custom Functions/` | Yes | Yes | No (flat) |
| `Comm Functions/Generation Functions/` | Yes | Yes | No (flat) |
| `Comm Functions/OFDM Functions/` | Yes | No (commented out) | No |
| `Comm Functions/OTFS Functions/` | Yes | No (commented out) | No |
| `Comm Functions/OTFS-DD Functions/` | Yes | Yes | No (flat) |
| `Comm Functions/ODDM Functions/` | Yes | No (commented out) | No |
| `Comm Functions/TODDM Functions/` | Yes | No (commented out) | No |
| `Comm Functions/TX RX Functions/` | Yes | Yes | No (flat) |
| `Meta Functions/` (local) | Yes (stale) | Yes (stale) | No |
| `Common-Wireless-Infrastructure/` | Yes (submodule) | Yes (submodule) | Yes (copy) |
| `Data/` | Yes | Yes | Yes |
| `Figures/` | Yes | Yes (with subdirs) | Yes |
| `Legacy/` | `Legacy/` | `Legacy - Test Codes/` | No |
| `Pre-rendered Lookup Tables/` | Yes | Yes | Yes |
| `References/` | Yes | No | No |
| `Final Images/` | No | Yes | No |
| `Hidden Files/` | No | Yes | No |
| `Common Functions/` | No | No | Yes (unused leftover) |

### Issues

| # | Issue | Fix |
|---|---|---|
| D1 | CWS `Legacy/` vs MUSIC OTFS `Legacy - Test Codes/` | Standardize to `Legacy/` |
| D2 | ODDM CE has `Common Functions/` (empty, leftover) | Delete it |
| D3 | MUSIC OTFS has `Final Images/`, `Hidden Files/` | Rename to `Output/` or fold into `Figures/` |
| D4 | CWS has `References/` (only PDFs) | Keep, add to other projects as needed |
| D5 | Local `Meta Functions/` in CWS and MUSIC OTFS are stale copies | Delete entirely; rely on submodule only |
| D6 | ODDM CE `Comm Functions/` is flat (no subdirs) | Create `Custom Functions/`, `Generation Functions/`, `TX RX Functions/` subdirs to match |
| D7 | MUSIC OTFS has `OFDM Functions/`, `OTFS Functions/`, `ODDM Functions/`, `TODDM Functions/` commented out | Keep commented; projects only enable what they use |

### Standard

```
<project>/
├── Comm Functions/
│   ├── Custom Functions/        ← math helpers (ambig, DFT, etc.)
│   ├── Generation Functions/    ← channel/data generators
│   ├── <system> Functions/      ← one dir per system (OFDM, OTFS, OTFS-DD, ODDM, TODDM)
│   └── TX RX Functions/         ← modulator, demodulator, equalizer
├── Common-Wireless-Infrastructure/  ← git submodule
├── Data/                        ← Excel outputs
├── Figures/                     ← generated plots
├── Legacy/                      ← old code, not on path
├── Pre-rendered Lookup Tables/  ← cached lookup tables
└── References/                  ← papers, docs (optional)
```

---

## 2. Top-Level Profile Struct Fields (`p.*`)

### Current State

| Field | CWS | MUSIC OTFS | ODDM CE |
|---|---|---|---|
| `primary_var` | Yes | Yes | Yes |
| `primary_vals` | Yes | Yes | Yes |
| `default_parameters` | Yes | Yes | Yes |
| `MUSIC_settings` | No | Yes | No |
| `vehicle_motion_settings` | No | Yes | No |
| `configs` | Yes | Yes | Yes |
| `delete_configs` | Yes | Yes | Yes |
| `legend_vec` | Yes | Yes | Yes |
| `line_styles` | Yes | Yes | Yes |
| `line_colors` | Yes | Yes | Yes |
| `vis_type` | Yes | Yes | Yes |
| `data_type` | Yes (via eval) | Yes (via `figure_statistic`) | Yes |
| `legend_loc` | Yes | Yes | Yes |
| `ylim_vec` | Yes | Yes | Yes |
| `num_trials` | No | No | No |
| `save_sel` | No (hardcoded in sim_head) | No (hardcoded) | No (hardcoded) |

### Issues

| # | Issue | Fix |
|---|---|---|
| P1 | `MUSIC_settings` and `vehicle_motion_settings` are project-specific structs that don't exist in CWS or ODDM CE. They get merged into `parameters` via `mergestructs` in sim_head, then live alongside `default_parameters` in the profile. | Rename both to `extra_settings` (a cell array of structs). In sim_head, loop over `extra_settings` and mergestructs each one. This is generic and works for any number of settings groups. |
| P2 | `data_type` is set via `eval` in CWS (it's a profile field) but via `app_settings.figure_statistic` in MUSIC OTFS | Standardize: always a profile field, never overridden by app_settings. MUSIC OTFS sim_head drops `figure_statistic`. |
| P3 | `vis_type` is `"figure"` in every profile across all projects | Keep as-is (allows future `"table"` or `"hexgrid"` extensions). |
| P4 | `delete_configs` is referenced but never defined in scope — it's a profile field that gets eval'd | This is correct but fragile. Keep as-is for now. |

---

## 3. `default_parameters` Field Names

### Current State

| Field | CWS | MUSIC OTFS | ODDM CE | Meaning |
|---|---|---|---|---|
| `system_name` | Yes | Yes | Yes | System type string |
| `M_ary` | Yes | Yes | Yes | Modulation order (4, 16, 64, 256) |
| `M` | Yes | Yes | Yes | Number of subcarriers / time slots |
| `N` | Yes | Yes | Yes | Number of subcarriers (OTFS) / symbols (ODDM) |
| `U` | Yes | No | No | Number of users (unused in some profiles) |
| `T` | Yes | Yes | Yes | Symbol duration (s) |
| `Fc` | Yes | Yes | Yes | Carrier frequency (Hz) |
| `vel` | Yes | Yes | Yes | Vehicle speed (m/s) |
| `shape` | Yes | Yes | Yes | Pulse shape ("rrc", "rect", "ideal") |
| `alpha` | Yes | Yes | Yes | RRC roll-off factor |
| `Q` | Yes | Yes | Yes | Guard interval / oversampling factor |
| `CP` | Yes | No | No | Cyclic prefix (logical) |
| `receiver_name` | Yes | Yes | No | Receiver type string |
| `max_timing_offset` | Yes | Yes | No | Max timing offset for sync test |
| `N_iters` | Profile 9 only | No | No | Number of iterations |
| `channel_estimation_method` | No | Yes | No | CE method string |

### Issues

| # | Issue | Fix |
|---|---|---|
| N1 | **`M` vs `M_ary`** — Both start with M. `M` means subcarrier count, `M_ary` means modulation order. When reading quickly, `M` and `M_ary` are easily confused. | Rename `M` to `num_subcarriers` and `M_ary` to `mod_order`. |
| N2 | **`N`** — Single letter, means different things in different systems (OTFS time slots, ODDM symbols). | Rename to `num_symbols` or `N` (keep — it's standard in OTFS literature). |
| N3 | **`U`** — Single letter, "number of users". Only used in CWS, removed for ODDM/OTFS in hash cleanup. | Rename to `num_users` or drop entirely if unused. |
| N4 | **`T`** — Single letter, "symbol duration". Very generic name for a specific physical quantity. | Rename to `Ts` (standard notation for symbol period) or `symbol_duration`. |
| N5 | **`Q`** — Single letter, means "guard interval samples" in ODDM context. | Rename to `guard_interval` or keep `Q` (standard in ODDM literature). |
| N6 | **`Fc`** — Already standard. | Keep as-is. |
| N7 | **`vel`** — Abbreviated. | Rename to `velocity` for consistency with the longer names being introduced. |
| N8 | **`shape`** — Vague. | Rename to `pulse_shape` to be specific. |
| N9 | **`CP`** — Clear and standard. | Keep as-is. |
| N10 | **`alpha`** — Clear in context (RRC roll-off). | Keep as-is. |
| N11 | **`N_iters`** — Only appears in one CWS profile. | Keep as-is (project-specific field, not in the shared schema). |

### Proposed Standard Schema

```matlab
% Core fields (all projects)
p.default_parameters.system_name = "OTFS";      % string
p.default_parameters.mod_order = 4;              % was M_ary
p.default_parameters.num_subcarriers = 64;       % was M
p.default_parameters.num_symbols = 16;           % was N
p.default_parameters.Ts = 1/15000;               % was T (symbol duration)
p.default_parameters.Fc = 4e9;                   % carrier frequency (keep)
p.default_parameters.velocity = 500;             % was vel
p.default_parameters.pulse_shape = "rrc";        % was shape
p.default_parameters.alpha = 0.2;                % roll-off (keep)
p.default_parameters.guard_interval = 8;         % was Q

% Optional fields (project-dependent)
p.default_parameters.num_users = 1;              % was U (CWS only)
p.default_parameters.CP = false;                 % cyclic prefix (CWS only)
p.default_parameters.receiver_name = "CMC-MMSE"; % keep
p.default_parameters.max_timing_offset = 0.0;    % keep
```

---

## 4. `app_settings` Fields

### Current State

| Field | CWS | MUSIC OTFS | ODDM CE |
|---|---|---|---|
| `table_name` | Yes | Yes | Yes |
| `use_parellelization` | Yes (typo) | Yes (typo) | Yes (typo) |
| `frames_per_iter` | Yes | Yes | Yes |
| `priority` | Yes | Yes | Yes |
| `save_excel` | Yes | Yes | Yes |
| `save_mysql` | Yes | Yes | Yes |
| `profile_sel` | Yes | Yes | Yes |
| `num_frames` | Yes | Yes | Yes |
| `delete_sel` | Yes | Yes | Yes |
| `iteratively_render` | Yes | Yes | Yes |
| `figure_statistic` | No | Yes | No |

### Issues

| # | Issue | Fix |
|---|---|---|
| A1 | **`use_parellelization`** — misspelled across ALL projects and the .mlapp files. | Rename to `use_parallel` (shorter, no typo). Requires updating .mlapp files. |
| A2 | **`figure_statistic`** — only in MUSIC OTFS. Overrides profile's `data_type`. | Remove from app_settings; `data_type` is always a profile field. |
| A3 | **`frames_per_iter`** — clear name. | Keep as-is. |

---

## 5. `save_data` Fields

### Current State

| Field | CWS | MUSIC OTFS | ODDM CE |
|---|---|---|---|
| `priority` | Yes | Yes | Yes |
| `save_excel` | Yes | Yes | Yes |
| `save_mysql` | Yes | Yes | Yes |
| `excel_folder` | Yes | Yes | Yes |
| `excel_name` | Yes | Yes | Yes |
| `excel_path` | Yes | Yes | Yes |

### Issues

| # | Issue | Fix |
|---|---|---|
| S1 | All consistent. No changes needed. | Keep as-is. |

---

## 6. `figure_data` Fields

### Current State

| Field | CWS | MUSIC OTFS | ODDM CE |
|---|---|---|---|
| `ylim_vec` | Yes | Yes | Yes |
| `legend_loc` | Yes | Yes | Yes |
| `data_type` | Yes | Yes | Yes |
| `primary_var` | Yes | Yes | Yes |
| `primary_vals` | Yes | Yes | Yes |
| `legend_vec` | Yes | Yes | Yes |
| `line_styles` | Yes | Yes | Yes |
| `line_colors` | Yes | Yes | Yes |
| `save_sel` | Yes | Yes | Yes |

### Issues

| # | Issue | Fix |
|---|---|---|
| F1 | All consistent. No changes needed. | Keep as-is. |

---

## 7. `sim_head.m` Local Variable Names

### Current State (abbreviated variable names)

| Variable | Used In | Meaning |
|---|---|---|
| `prvr_len` | CWS, MUSIC OTFS, ODDM CE | Number of primary variable values |
| `conf_len` | CWS, MUSIC OTFS, ODDM CE | Number of configs |
| `primvar_sel` | CWS, MUSIC OTFS, ODDM CE | Current primary variable index |
| `primvar_val` | CWS, MUSIC OTFS, ODDM CE | Current primary variable value |
| `sel` | CWS, MUSIC OTFS, ODDM CE | Current config index |
| `dq` | CWS, MUSIC OTFS | DataQueue for progress bar |
| `p_sel` | CWS, MUSIC OTFS | Selected profile struct |

### Issues

| # | Issue | Fix |
|---|---|---|
| V1 | `prvr_len` — obscure abbreviation | Rename to `num_primary` |
| V2 | `conf_len` — abbreviated | Rename to `num_configs` |
| V3 | `primvar_sel` — mixed abbreviation | Rename to `primary_idx` |
| V4 | `primvar_val` — mixed abbreviation | Rename to `primary_val` |
| V5 | `sel` — too generic, used for config loop | Rename to `config_idx` |
| V6 | `dq` — MATLAB DataQueue abbreviation | Keep as-is (standard MATLAB pattern) |
| V7 | `p_sel` — ambiguous | Rename to `profile` |

---

## 8. Function Names

### Current State

| Function | CWS | MUSIC OTFS | ODDM CE | Shared Repo |
|---|---|---|---|---|
| `gen_figure.m` | No (has `gen_figure_v2.m` locally) | No (has `gen_figure_v2.m` locally) | No (deleted) | Yes |
| `gen_figure_v2.m` | Yes (local Meta Functions) | Yes (local Meta Functions) | No | No |
| `gen_hex_layout.m` | Yes (local Meta Functions) | Yes (local Meta Functions) | No | No |
| `gen_hexgrid_configs.m` | Yes (local Meta Functions) | Yes (local Meta Functions) | No | No |
| `comms_obj.m` | Yes | No | Yes | No |
| `comms_obj_OTFS.m` | Yes | Yes | Yes | No |
| `obj_comms_OTFS.m` | No | Yes (OTFS-DD Functions) | No | No |
| `generate_data.m` | Yes (2 copies!) | Yes (2 copies!) | Yes | No |
| `generate_fading.m` | Yes (2 copies!) | Yes (2 copies!) | Yes | No |
| `gen_data.m` | Yes | Yes | Yes | No |

### Issues

| # | Issue | Fix |
|---|---|---|
| FN1 | **`gen_figure` vs `gen_figure_v2`** — shared repo has `gen_figure.m`, local copies still have `gen_figure_v2.m` | Shared repo wins. Local `gen_figure_v2.m` files should be deleted once submodule is the sole source. |
| FN2 | **`comms_obj` vs `obj_comms_OTFS`** — inconsistent prefix placement | Rename `obj_comms_OTFS.m` to `comms_obj_OTFS.m` in MUSIC OTFS |
| FN3 | **`generate_data.m` and `generate_fading.m` exist in both `Generation Functions/` and `TX RX Functions/`** — two copies per project | Audit which version is canonical. Delete the other. |
| FN4 | **`gen_data.m` vs `generate_data.m`** — two different functions doing similar things | Rename `gen_data.m` to something more specific (e.g., `gen_binary_data.m`) or merge if identical |
| FN5 | **`gen_hex_layout.m`, `gen_hexgrid_configs.m`** — only in CWS, not in shared repo | Move to shared repo if other projects need them, or keep project-specific |

---

## 9. `sim_fun_*` Function Naming

### Current State

| Function | CWS | MUSIC OTFS | ODDM CE |
|---|---|---|---|
| `sim_fun_OFDM_v2.m` | Yes | No | No |
| `sim_fun_OTFS.m` | Yes | No | No |
| `sim_fun_OTFS_v3.m` | No | No | Yes (OTFS Functions) |
| `sim_fun_OTFS_DD_v3.m` | Yes | Yes | No |
| `sim_fun_ODDM_v3.m` | Yes | No | Yes |
| `sim_fun_TODDM_v3.m` | Yes | No | Yes |
| `sim_fun_OTFS_MUSIC.m` | No | Yes | No |
| `sim_fun_OTFS_SIC_MMSE.m` | No | Yes | No |

### Issues

| # | Issue | Fix |
|---|---|---|
| SF1 | **Version suffixes inconsistent** — `_v2`, `_v3`, no suffix | Standardize: drop version suffixes entirely. The function name describes the system; if you need a new version, replace the file. |
| SF2 | **`sim_fun_OTFS` (CWS) vs `sim_fun_OTFS_v3` (ODDM CE)** — same system, different names | Unify to `sim_fun_OTFS.m` |
| SF3 | **`sim_fun_OTFS_MUSIC` and `sim_fun_OTFS_SIC_MMSE`** — MUSIC OTFS specific | Keep as-is (project-specific systems) |

### Proposed Standard

```
sim_fun_OFDM.m
sim_fun_OTFS.m
sim_fun_OTFS_DD.m
sim_fun_ODDM.m
sim_fun_TODDM.m
sim_fun_OTFS_MUSIC.m        ← project-specific
sim_fun_OTFS_SIC_MMSE.m     ← project-specific
```

---

## 10. Hash Cleanup Logic (rmfield in sim_head)

### Current State

CWS removes `U` for ODDM/OTFS, removes `N, U, shape, alpha, Q` for OFDM.
MUSIC OTFS removes nothing for ODDM/OTFS, removes `N, shape, alpha, Q` for OFDM.
MUSIC OTFS has ~16 fields removed when `channel_estimation_method == "none"`.

### Issues

| # | Issue | Fix |
|---|---|---|
| H1 | The `U` field is removed in CWS but doesn't exist in MUSIC OTFS/ODDM CE. The logic is inconsistent. | After renaming to `num_users`, make removal conditional: `if isfield(parameters, 'num_users'), parameters = rmfield(parameters, 'num_users'); end` |
| H2 | The hash cleanup block is a long if-elseif chain that's hard to maintain | Create a shared function `clean_parameters_for_hash(parameters, system_name)` in the shared repo |

---

## 11. Pre-rendered Lookup Table Directory Names

### Current State

| Directory | CWS | MUSIC OTFS | ODDM CE |
|---|---|---|---|
| `ODDM DD Cross-Ambiguity Tables/` | Yes | No | Yes |
| `OTFS Cross-Ambiguity Tables/` | Yes | No | No |
| `OTFS Noise Covariance Matrices/` | Yes | No | No |
| `OTFS-DD Cross-Ambiguity Tables/` | Yes | Yes | No |
| `OTFS-DD Noise Covariance Matrices/` | Yes | No | No |

### Issues

| # | Issue | Fix |
|---|---|---|
| L1 | Directory names are long and inconsistent | Shorten to pattern: `<system>_<type>/` e.g. `OTFS_DD_ambig/`, `OTFS_DD_noisecov/`, `ODDM_DD_ambig/` |
| L2 | MUSIC OTFS has `Legacy - Test Codes/Pre-rendered Lookup Tables/` (nested) | Move to top-level `Pre-rendered Lookup Tables/` |

---

## Summary: Priority of Changes

### Phase 1 — Safe Renames (no behavioral change, just clarity)

1. Rename `M` → `num_subcarriers`, `M_ary` → `mod_order` in all `default_parameters`
2. Rename `T` → `Ts` in all `default_parameters`
3. Rename `vel` → `velocity` in all `default_parameters`
4. Rename `shape` → `pulse_shape` in all `default_parameters`
5. Rename `Q` → `guard_interval` in all `default_parameters`
6. Rename `U` → `num_users` in all `default_parameters`
7. Rename `use_parellelization` → `use_parallel` in `app_settings`
8. Rename `prvr_len` → `num_primary`, `conf_len` → `num_configs`, `primvar_sel` → `primary_idx`, `primvar_val` → `primary_val`, `sel` → `config_idx`, `p_sel` → `profile` in sim_head

### Phase 2 — Structural Changes (require testing)

9. Convert `MUSIC_settings` / `vehicle_motion_settings` → `extra_settings` (cell array of structs)
10. Remove `figure_statistic` from MUSIC OTFS `app_settings`
11. Move `gen_hex_layout.m` / `gen_hexgrid_configs.m` to shared repo
12. Rename `obj_comms_OTFS.m` → `comms_obj_OTFS.m`
13. Create `clean_parameters_for_hash()` shared function
14. Delete duplicate `generate_data.m` / `generate_fading.m` in `TX RX Functions/` (verify which copy is canonical)

### Phase 3 — Cleanup (low risk, housekeeping)

15. Delete stale local `Meta Functions/` from CWS and MUSIC OTFS
16. Delete unused `Common Functions/` from ODDM CE
17. Rename `Legacy - Test Codes/` → `Legacy/` in MUSIC OTFS
18. Create subdirectories in ODDM CE `Comm Functions/` to match standard layout
19. Drop version suffixes from `sim_fun_*` names
20. Shorten pre-rendered lookup table directory names

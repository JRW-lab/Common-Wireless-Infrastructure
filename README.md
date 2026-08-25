# Common Wireless Infrastructure

Shared MATLAB functions used across multiple wireless communications simulation projects. This repository is designed to be included as a **git submodule** in each project repository.

## Included Functions

### Database I/O

| Function | Purpose |
|----------|---------|
| `mysql_login.m` | Connect to MySQL (tries localhost root, then remote_user with retry) |
| `mysql_load.m` | Fetch rows from MySQL by param_hash |
| `mysql_write.m` | Insert/update with weighted-averaged metric merging (optional mutex) |
| `mysql_check.m` | Read flag from system_flags table |
| `mysql_set.m` / `mysql_unset.m` | Set/clear inter-process flags |
| `connectWithRetry.m` | Retry DB connection up to 50 times with 30s wait |
| `addMysqlJarOnce.m` | Add MySQL JDBC JAR to Java classpath once |
| `local_write.m` | Excel read/write fallback with weighted-averaging |

### Hashing

| Function | Purpose |
|----------|---------|
| `jsonencode_sorted.m` | Deterministic JSON encoding + SHA-256 hash (field names sorted alphabetically) |
| `DataHash.m` | Third-party SHA-256/MD5 utility (Jan Simon) |

### Visualization

| Function | Purpose |
|----------|---------|
| `gen_table.m` | Display results as a MATLAB table in the console |
| `updateProgressBar.m` | Braille-character progress bar with system parameter display |

### CLI Utilities

| Function | Purpose |
|----------|---------|
| `profile_select.m` | Interactive console menu for profile selection |
| `figure_settings.m` | Interactive console prompt for figure rendering settings |

## Usage as a Submodule

This repository is not meant to be used standalone. Each project that depends on these functions should add this repo as a git submodule:

```bash
git clone --recurse-submodules https://github.com/JRW-lab/Common-Wireless-Infrastructure.git
```

Or add to an existing project:

```bash
cd /path/to/project
git submodule add https://github.com/JRW-lab/Common-Wireless-Infrastructure.git Common-Wireless-Infrastructure
```

Then in MATLAB, add the submodule to your path:

```matlab
addpath('Common-Wireless-Infrastructure/Meta Functions');
```

## Versioning

Each project repo pins a specific commit of this shared infrastructure via `.gitmodules`. To update all projects to the latest shared code:

```bash
cd Common-Wireless-Infrastructure
git pull origin main
cd ..
git add Common-Wireless-Infrastructure
git commit -m "Update shared infrastructure to latest"
```

## Requirements

- MATLAB R2024b or later
- Database Toolbox (for MySQL functions)
- Parallel Computing Toolbox (for `parfor` progress reporting)
- `mysql-connector-j-8.4.0.jar` (JDBC driver, included in project repos)

## Contact

For questions, contact jrwimer@uark.edu or visit [my website](https://jrw-lab.github.io).

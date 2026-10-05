function gen_figure(save_data, conn, table_name, hash_cell, configs, figure_data)
% GEN_figure Plot simulation results from database/Excel as line figures.
%
%   gen_figure(save_data, conn, table_name, hash_cell, configs, figure_data)
%
%   Unified visualization function supporting:
%     - Multi-trial aggregation (mean/min/max with error bars)
%     - LaTeX rendering on all text elements
%     - Log x-axis and y-axis support
%     - Per-project throughput formulas (via system_name switch)
%     - Multi-system parameter correction (ODDM/TODDM/OTFS/OFDM)
%     - Optional title generation from parameters

% Plot settings
line_val = 2;
mark_val = 10;
font_val = 16;
figures_folder = 'Figures';

%% Load data from DB, scoped to just this figure's own param_hashes
% (an indexed lookup) rather than "*" (a full-table scan) - the results
% table is shared across every project, so a full reload here would only
% get slower as everyone else's history accumulates, and this can run
% repeatedly per simulation (Generate Figure, plus every iteration when
% Iteratively Render is on).
%
% Empty entries are dropped: a profile with flat configs leaves the
% non-anchor cells of those columns blank on purpose (see sim_head.m's
% FLAT CONFIGS note), and an empty key handed to mysql_load would widen the
% WHERE clause instead of narrowing it. For any other profile this is
% exactly hash_cell(:).
% NOTE: a separate variable -- hash_cell itself stays 2-D, because the
% results loop below indexes it as hash_cell{primvar_sel, sel}.
hash_list = hash_cell(:);
hash_list = hash_list(~cellfun(@isempty, hash_list));
switch save_data.priority
    case "mysql"
        if save_data.save_mysql
            try
                T = mysql_load(conn, table_name, hash_list);
            catch
                conn = mysql_login(conn.DataSource);
                T = mysql_load(conn, table_name, hash_list);
            end
        elseif save_data.save_excel
            try
                T = readtable(save_data.excel_path, 'TextType', 'string');
            catch
                T = table;
            end
        end
    case "local"
        if save_data.save_excel
            try
                T = readtable(save_data.excel_path, 'TextType', 'string');
            catch
                T = table;
            end
        elseif save_data.save_mysql
            try
                T = mysql_load(conn, table_name, hash_list);
            catch
                conn = mysql_login(conn.DataSource);
                T = mysql_load(conn, table_name, hash_list);
            end
        end
end

% Import figure settings
ylim_vec = figure_data.ylim_vec;
loc = figure_data.legend_loc;
data_type = figure_data.data_type;
primary_var = figure_data.primary_var;
primary_vals = figure_data.primary_vals;
legend_vec = figure_data.legend_vec;
line_styles = figure_data.line_styles;
line_colors = figure_data.line_colors;
save_sel = figure_data.save_sel;
if isfield(figure_data, 'use_latex')
    use_latex = figure_data.use_latex;
else
    use_latex = true;
end
num_configs = length(configs);
num_primary = length(primary_vals);

% Optional fields
if isfield(figure_data, 'num_trials')
    num_trials = figure_data.num_trials;
else
    num_trials = 1;
end
if isfield(figure_data, 'render_title')
    render_title = figure_data.render_title;
else
    render_title = false;
end
if isfield(figure_data, 'title_vars')
    title_vars = figure_data.title_vars;
else
    title_vars = struct();
end
if isfield(figure_data, 'identifier')
    identifier = figure_data.identifier;
else
    identifier = "system_name";
end

%% Load results
results_mat = NaN(num_primary, num_configs);
if num_trials > 1
    results_std = zeros(num_primary, num_configs);
end

for primvar_sel = 1:num_primary
    for sel = 1:num_configs
        paramHash = hash_cell{primvar_sel, sel};
        try
            sim_result = T(string(T.param_hash) == paramHash, :);
        catch
            sim_result = [];
        end

        if ~isempty(sim_result)
            try
                num_rows = height(sim_result);
                trial_vals = zeros(num_rows, 1);

                for row_idx = 1:num_rows
                    metrics_loaded = jsondecode(sim_result.metrics{row_idx});

                    % Throughput special case. PREFER THE STORED metrics.Thr:
                    % every sim_fun that reports Thr computes it from its OWN
                    % actual data-symbol count (syms_per_f - zero_syms, or the
                    % ported-geometry Ndata), which differs by algorithm --
                    % e.g. for CP-Free ODDM PT-MMSE at N=16/M=64/Q=4, perfect
                    % CSI's native single-guard band (L=12) leaves 832
                    % data symbols/frame, while DD-RELAX/SAGE/OMP/DT-MUSIC's
                    % ported guard+pilot band (2L-1=23) leaves only 656.
                    %
                    % The recompute below predates several of those ported
                    % estimators and uses ONE hardcoded guard formula (CWS's
                    % native L1=Q+1, L2=Q+1+floor(2510e-9/Ts)) for every
                    % non-MUSIC config regardless of which frame geometry it
                    % actually ran with. Applied uniformly across configs that
                    % share the same Q/M/N/T (as Figure 7's five curves do),
                    % it silently gives every curve the SAME recomputed
                    % ceiling at high SNR -- a rendering artifact that erases
                    % a real, physical throughput gap between perfect CSI and
                    % the pilot-based estimators. Bug found 2026-09-28.
                    %
                    % Kept only as a FALLBACK for rows written before Thr was
                    % part of the schema (or any system that still doesn't
                    % store it), so old data keeps rendering exactly as
                    % before -- this is strictly an accuracy fix, not a
                    % change to what gets plotted when a real Thr exists.
                    if data_type == "Thr"
                        if isfield(metrics_loaded, 'Thr')
                            trial_vals(row_idx) = metrics_loaded.Thr;
                        else
                        params_loaded = jsondecode(sim_result.parameters{row_idx});
                        % A "MUSIC" case used to sit here, switching on
                        % params_loaded.system_name -- but no row in
                        % sim_lookup has ever had system_name=="MUSIC"
                        % (confirmed 2026-09-29: distinct system_name
                        % values are OTFS-DD/ODDM/TODDM/OFDM/OTFS only;
                        % MUSIC-style profiles carry a
                        % channel_estimation_method field under
                        % system_name="OTFS-DD" instead, per
                        % build_point_params.m). It also used its OWN
                        % hardcoded guard-width formula that didn't match
                        % sim_fun_OTFS_MUSIC.m's real one (assumed
                        % shape=="rect" unconditionally, and hardcoded
                        % bits/symbol=2 regardless of M_ary) -- removed as
                        % dead code rather than fixed, since it was
                        % unreachable.
                        FER = metrics_loaded.FER;
                        T_val = params_loaded.T;
                        M = params_loaded.M;
                        try
                            N = params_loaded.N;
                        catch
                            N = 1;
                        end
                        try
                            Q = params_loaded.Q;
                        catch
                            Q = 1;
                        end
                        Ts = T_val / M;
                        L1 = Q + 1;
                        L2 = Q + 1 + floor(2510e-9 / Ts);
                        trial_vals(row_idx) = 2 * (1 - FER) * (M * N) / ((M + L1 + L2) * N);
                        end
                    else
                        trial_vals(row_idx) = metrics_loaded.(data_type);
                    end
                end

                results_mat(primvar_sel, sel) = mean(trial_vals);
                if num_trials > 1 && num_rows > 1
                    results_std(primvar_sel, sel) = std(trial_vals);
                end
            catch
                results_mat(primvar_sel, sel) = NaN;
            end
        end
    end
end

%% Create folder
if ~isfolder(figures_folder)
    mkdir(figures_folder);
end

%% X-Axis label
x_type = "linear";
switch primary_var
    case "EbN0"
        xlabel_name = "$E_b/N_0$ (dB)";
    case "vel"
        xlabel_name = "Vehicular velocity (km/hr)";
    case "T"
        primary_vals = primary_vals * 1e6;
        xlabel_name = "$T$ ($\mu$s)";
    case "frequency_limit"
        xlabel_name = "Cutoff Frequency (Hz)";
    case "max_timing_offset"
        xlabel_name = "$|\tau_e|$ (in $T_s$)";
    case "N_iters"
        xlabel_name = "Number of iterations";
    case "num_init_frames"
        xlabel_name = "Number of initialization frames";
    case "num_pilot_frames_during_init"
        xlabel_name = "Number of pilot frames during init.";
    case "shrinkage_alpha"
        xlabel_name = "$\alpha_{shrinkage}$";
    case "cov_epsilon"
        xlabel_name = "$\epsilon$";
    case "num_pilots"
        xlabel_name = "Pilots per frame";
        x_type = "log";
    case "pilot_energy_alloc"
        xlabel_name = "$E_{p,total} / E_{frame}$";
        x_type = "log";
    case "v_res"
        xlabel_name = "Resolution of pseudospectrum";
        x_type = "log";
    case "M"
        xlabel_name = "$M$ (num. subcarriers)";
        x_type = "log";
    case "N"
        xlabel_name = "$N$ (num. time syms.)";
        x_type = "log";
    case "gamma_p"
        xlabel_name = "Pilot SNR $\gamma_p$ (dB)";
    otherwise
        xlabel_name = string(primary_var);
end

% PER-PROFILE X-SCALE OVERRIDE (2026-09-19). The switch above infers the
% x-axis scale from primary_var alone, which cannot distinguish two profiles
% that sweep the SAME variable over different ranges -- e.g. an NGS sweep of
% 1:4 (linear reads better) versus [4 8 16 32] (log reads better). A profile
% may set `p.x_log = true` to force a log x-axis. Absent or false leaves the
% inferred behaviour exactly as before, so no existing profile changes.
if isfield(figure_data,'x_log') && ~isempty(figure_data.x_log) && figure_data.x_log
    x_type = "log";
end

%% Y-Axis label
y_type = "log";
switch data_type
    case "Thr"
        loc = "southeast";
        y_type = "linear";
        ylabel_name = "Throughput (bps/Hz)";
        ylim_vec = [0 2];
    % Timing metrics are handled generically below (t_<ALG>full /
    % t_<ALG>iter) rather than case-by-case. The old code had a case for
    % t_RXfull ONLY, so t_RXiter -- already offered in the GUI dropdown --
    % fell through to `otherwise` and rendered with no ms scaling and a raw
    % field name as its axis label. Handling the family fixes that and
    % accommodates channel-estimation timings without further edits.
    case "__timing_handled_below__"
        % unreachable; the real work happens after this switch
    case "RX_iters"
        y_type = "linear";
        ylabel_name = "Number of RX Iterations";
        ylim_vec = [0 8];
        loc = "northwest";
    case "recon_mse"
        ylabel_name = "Channel Estimation MSE";
    case "Cap"
        if identifier == "system_name"
            ylim_vec = [min(results_mat(:), [], 'omitnan') max(results_mat(:), [], 'omitnan')];
            ylabel_name = "Ergodic Capacity (kbps/Hz)";
            loc = "northwest";
        else
            ylabel_name = string(data_type);
        end
    otherwise
        ylabel_name = string(data_type);
end

% ---- Generic runtime-metric handling: t_<ALG>full / t_<ALG>iter ----
% ALG is a short algorithm tag, e.g. RX (reception/equalisation) or EST
% (channel estimation). Adding a new timed algorithm needs no change here.
%
% UNITS: these are stored in SECONDS and displayed in MILLISECONDS.
tm = regexp(char(data_type), '^t_([A-Za-z0-9]+?)(full|iter)$', 'tokens', 'once');
if ~isempty(tm)
    alg  = tm{1};
    kind = tm{2};
    results_mat = results_mat * 1000;
    % A trailing 'cpu' in the tag marks a CPU-TIME metric, which must be
    % labelled distinctly from the legacy wall-clock series: cputime SUMS
    % ACROSS THREADS (measured ~3x wall on a multithreaded matmul), so the
    % two are different quantities and must never be mistaken on a plot.
    isCPU = endsWith(alg,'cpu','IgnoreCase',true);
    if isCPU, alg = extractBefore(alg, strlength(alg)-2); end
    if strcmp(kind,'full'), sub = ",avg}$"; else, sub = ",iter}$"; end
    if isCPU
        ylabel_name = "$t^{cpu}_{" + string(alg) + sub + " (ms, CPU)";
    else
        ylabel_name = "$t_{" + string(alg) + sub + " (ms, wall)";
    end
    y_type = "linear";   % runtimes are not log-scaled by default
end

%% Plot
% FLAT CONFIGS (2026-09-21). A config listed in the profile's `flat_configs`
% holds ONE measurement that does not depend on the primary variable (the
% canonical case being a perfect-CSI reference on a pilot-SNR sweep, where
% the frame carries no pilot at all). It is stored at a single anchor row
% and is drawn here as a horizontal line spanning the whole x-range, rather
% than as a lone marker with a column of NaNs around it.
%
% THREE THINGS THAT LOOK OPTIONAL AND ARE NOT:
%
% 1. The flat line is drawn INSIDE this same loop, in config order. The
%    legend below is positional -- `legend(legend_vec, ...)` maps entries to
%    axis children in creation order -- so drawing flat configs in a second
%    pass, or with yline() (which parents differently), silently relabels
%    every curve on the figure.
% 2. Marker is forced off. A profile author writing "--bo" for a reference
%    line would otherwise get stray circles pinned at the two axis edges,
%    which read as data points that were never measured.
% 3. The span uses primary_vals(1)/end, matching the xlim set below, so the
%    line reaches both edges exactly rather than floating short of them.
flat_configs = [];
if isfield(figure_data,'flat_configs') && ~isempty(figure_data.flat_configs)
    flat_configs = figure_data.flat_configs;
end
if isfield(figure_data,'flat_row') && ~isempty(figure_data.flat_row)
    flat_row = figure_data.flat_row;
else
    flat_row = ones(1, num_configs);
end

figure(1);
clf;
hold on;
for sel = 1:num_configs
    if ismember(sel, flat_configs)
        yflat = results_mat(flat_row(sel), sel);
        if ~isnan(yflat)
            plot([primary_vals(1) primary_vals(end)], [yflat yflat], ...
                line_styles{sel}, ...
                Color=line_colors{sel}, ...
                linewidth=line_val, ...
                Marker='none');
        else
            % Keep the child count and ordering stable even with no data
            % yet, so the positional legend does not shift mid-collection.
            plot(NaN, NaN, line_styles{sel}, Color=line_colors{sel}, ...
                linewidth=line_val, Marker='none');
        end
    else
        plot(primary_vals, results_mat(:, sel), ...
            line_styles{sel}, ...
            Color=line_colors{sel}, ...
            linewidth=line_val, ...
            MarkerSize=mark_val);
    end
end
if num_trials > 1
    for sel = 1:num_configs
        if ismember(sel, flat_configs)
            continue;   % a single anchored measurement has no per-x spread
        end
        errorbar(primary_vals, results_mat(:, sel), results_std(:, sel), ...
            'Color', line_colors{sel}, ...
            'LineStyle', 'none', ...
            'LineWidth', 1);
    end
end
hold off;

ylabel(ylabel_name, Interpreter='latex');
xlabel(xlabel_name, Interpreter='latex');

if x_type == "log"
    set(gca, 'XScale', 'log');
end
if y_type == "log"
    set(gca, 'YScale', 'log');
end

if y_type == "log"
    ylim(ylim_vec);
end
xlim([primary_vals(1) primary_vals(end)]);
xticks(primary_vals);
grid on;
legend(legend_vec, Location=loc, Interpreter='latex');
set(gca, 'FontSize', font_val);
set(gca, 'Box', 'on');
set(gca, 'LineWidth', 1.2);

% Optional title
if render_title
    title_str = "";
    title_field_names = fieldnames(title_vars);
    for i = 1:length(title_field_names)
        val = title_vars.(title_field_names{i});
        key = title_field_names{i};
        if key == "T"
            val = val * 1e6;
            title_str = title_str + sprintf("%s = %.4g \\mu s, ", key, val);
        elseif key == "EbN0"
            title_str = title_str + sprintf("%s = %g dB, ", key, val);
        elseif key == "vel"
            title_str = title_str + sprintf("%s = %g km/hr, ", key, val);
        else
            title_str = title_str + sprintf("%s = %g, ", key, val);
        end
    end
    title_str = regexprep(title_str, ',\s*$', '');
    title(title_str, Interpreter='latex');
end

%% Save figure
if save_sel
    if ~isfolder(fullfile(figures_folder, data_type))
        mkdir(fullfile(figures_folder, data_type));
    end
    if ~isfolder(fullfile(figures_folder, data_type, string(primary_var)))
        mkdir(fullfile(figures_folder, data_type, string(primary_var)));
    end
    timestamp = datestr(now, 'yyyymmdd_HHMMSS');
    filename = fullfile(figures_folder, data_type, string(primary_var), ...
        sprintf('%s_%s.png', data_type, timestamp));
    saveas(gcf, filename);
end

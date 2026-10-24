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
% Every results source, merged; an exploration run's in-memory rows instead (storage steps 7a, 7a.1); reconnect by name
dbname_gf = "";
if isfield(save_data,'dbname'), dbname_gf = save_data.dbname; end
if isfield(save_data,'mem_table')
    T = save_data.mem_table;
else
    T = load_merged(conn, dbname_gf, table_name, hash_list, table, 300);
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
% ROWS, not axis values. On a secondary (grid) sweep the point list is the
% flattened primary x secondary product, so it is longer than primary_vals;
% for an ordinary sweep the two are equal. Taking it from hash_cell is
% correct in both cases and cannot drift from what sim_head actually built.
num_primary = size(hash_cell,1);

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
secondary_var  = "";
secondary_vals = [];
if isfield(figure_data,'secondary_var') && ~isempty(figure_data.secondary_var) ...
        && isfield(figure_data,'secondary_vals') && ~isempty(figure_data.secondary_vals)
    secondary_var  = string(figure_data.secondary_var);
    secondary_vals = figure_data.secondary_vals;
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
% Resolved through sweep_axis_label so the SECONDARY axis of a grid figure
% gets the identical treatment -- label, log/linear, and any unit scaling.
[xlabel_name, x_scale, x_type] = sweep_axis_label(primary_var);
primary_vals = primary_vals * x_scale;

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
        ylabel_name = "Uncoded Throughput (bps/Hz)";
        % ylim set by the throughput rule below, not here
    % Timing metrics are handled generically below (t_<ALG>full /
    % t_<ALG>iter) rather than case-by-case. The old code had a case for
    % t_RXfull ONLY, so t_RXiter -- already offered in the GUI dropdown --
    % fell through to `otherwise` and rendered with no ms scaling and a raw
    % field name as its axis label. Handling the family fixes that and
    % accommodates channel-estimation timings without further edits.
    case "__timing_handled_below__"
        % unreachable; the real work happens after this switch
    % CODED throughput (added 2026-10-05). Distinct from "Thr", which is
    % the UNCODED metric: Thr = log2(M)*syms_data*(1-FER) / (T*B) with FER
    % the uncoded frame error rate, so it collapses to exactly 0 for any
    % scheme whose raw BER exceeds roughly 1e-4 at a 1-2k-bit frame and
    % cannot express a coded result at all. These two count INFORMATION
    % bits delivered instead:
    %   Thr_coded     frame-level goodput -- every codeword in the frame
    %                 must decode correctly.
    %   Thr_coded_cw  per-codeword goodput -- each correct codeword
    %                 counts. Less pessimistic, and the more useful of the
    %                 two near FER = 1, where the frame-level metric
    %                 saturates and stops discriminating between schemes.
    % Both exceed 1 bps/Hz at code rates above 1/2, hence the same [0 2]
    % range as Thr rather than a tighter one.
    case {"Thr_coded", "Thr_coded_cw"}
        loc = "southeast";
        y_type = "linear";
        if data_type == "Thr_coded"
            ylabel_name = "Coded Throughput (bps/Hz)";
        else
            ylabel_name = "Coded Throughput, per codeword (bps/Hz)";
        end
        % ylim_vec = [ylim_vec(1) ylim_vec(2)];
    case "RX_iters"
        y_type = "linear";
        ylabel_name = "Number of RX Iterations";
        ylim_vec = [0 8];
        loc = "northwest";
    case "recon_mse"
        ylabel_name = "Channel Estimation MSE";
    case "recon_mse_r1"
        % NMSE of the FIRST (pilot-only) estimate, before any data-aided or
        % decoder-aided round (2026-10-16, see metric_stage.m).
        ylabel_name = "Channel Estimation MSE, first estimate";
    case "Cap"
        if identifier == "system_name"
            ylim_vec = [min(results_mat(:), [], 'omitnan') max(results_mat(:), [], 'omitnan')];
            ylabel_name = "Ergodic Capacity (kbps/Hz)";
            loc = "northwest";
        else
            ylabel_name = string(data_type);
        end
    case "BER_info"
        ylabel_name = "Coded Info. BER";
    case "FER_info"
        ylabel_name = "Coded Info. FER";
    case "CWER"
        ylabel_name = "Codeword Error Rate";
    case "LDPC_conv"
        ylabel_name = "Codeword Convergence Rate";
        ylim_vec = [0 1];
        y_type = "linear";
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
% GRID SWEEPS (2026-10-09). With a secondary variable the point list is a
% flattened primary x secondary product, so there is a SURFACE per config
% rather than a curve. One wireframe mesh per config on shared axes, faces
% off so they do not occlude one another; the positional-legend rule below
% applies here exactly as it does to the line plot (one graphics child per
% config, created in config order).
if ~isempty(secondary_vals)
    nP_grid = numel(primary_vals);
    nS_grid = numel(secondary_vals);
    if nP_grid < 2 || nS_grid < 2
        error("gen_figure:gridTooSmall", ...
            ['A mesh needs at least 2 values on each axis; this profile ' ...
             'has %d primary and %d secondary.'], nP_grid, nS_grid);
    end
    if size(results_mat,1) ~= nP_grid*nS_grid
        error("gen_figure:gridShapeMismatch", ...
            ['Point list has %d rows but the grid is %d x %d = %d. The ' ...
             'flattening order in sim_head and the reshape here must ' ...
             'agree.'], size(results_mat,1), nP_grid, nS_grid, nP_grid*nS_grid);
    end
    [XX, YY] = meshgrid(primary_vals, secondary_vals);   % nS x nP
    hold on;
    for sel = 1:num_configs
        % Rows run PRIMARY-FASTEST (see sim_head), so reshape to (nP x nS)
        % and transpose to match meshgrid's orientation.
        ZZ = reshape(results_mat(:, sel), nP_grid, nS_grid).';
        % SOLID slices (2026-10-09), not the open wireframe this started as.
        %
        % EDGES ARE KEPT, in the same colour as the face, and that is not
        % redundant: a surface face needs all FOUR of its corners to be
        % non-NaN, so a half-collected grid draws no faces at all. The
        % edges are what still show a partially-filled sweep -- with a
        % single populated row (one Eb/N0 slice, which is exactly where
        % Profile 5 stands today) a face-only surface renders completely
        % blank. On a full grid the edges simply disappear into the face.
        %
        % FaceAlpha is just under 1 so that a lower surface stays visible
        % through the one above it. With several configs on shared axes,
        % fully opaque faces hide whichever curve sits underneath -- the
        % figure would silently show two of three surfaces. Set it to 1 for
        % a single-config profile, or when occlusion is wanted.
        surf(XX, YY, ZZ, ...
            FaceColor=line_colors{sel}, ...
            FaceAlpha=0.9, ...
            EdgeColor=line_colors{sel}, ...
            LineWidth=1.2);
    end
    hold off;
    view(135, 25);
    % A 3-D axes needs a bigger canvas; the margins themselves are set
    % once, after labelling, in the MARGINS block below.
    set(gcf, 'Position', [100 100 820 620]);
else
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
end

if ~isempty(secondary_vals)
    % On a grid the metric moves to Z and the secondary variable takes the
    % y-axis, labelled through the same resolver as the x-axis.
    ylabel(sweep_axis_label(secondary_var), Interpreter='latex');
    zlabel(ylabel_name, Interpreter='latex');
else
    ylabel(ylabel_name, Interpreter='latex');
end
xlabel(xlabel_name, Interpreter='latex');

if x_type == "log"
    set(gca, 'XScale', 'log');
end
if y_type == "log"
    % The metric lives on Z once there is a secondary axis.
    if ~isempty(secondary_vals)
        set(gca, 'ZScale', 'log');
    else
        set(gca, 'YScale', 'log');
    end
end

% THROUGHPUT Y-AXIS RULE (revised 2026-10-09). Scale to the DATA:
% [0 max(results)]. The previous rule used [0 log2(max(M_ary))], the
% UNCODED ceiling, which is right in principle but wastes the plot in
% practice -- at rate 1/2 every curve tops out at 1.0 against an axis of 2,
% so half the figure was empty. It also becomes misleading once the code
% rate is swept, because the reachable ceiling is log2(M)*rate, not
% log2(M), and that differs per curve.
%
% Falls back to 1 if the data is empty or non-positive, so an unpopulated
% profile still renders a sane axis instead of an invalid one.
if any(data_type == ["Thr","Thr_coded","Thr_coded_cw"])
    ymax = max(results_mat(:), [], 'omitnan');
    if isempty(ymax) || ~isfinite(ymax) || ymax <= 0
        ymax = 1;
    end
    ylim_vec = [0 ymax];
end

% An explicit y-axis from the GUI wins over every default above. max <= min
% means the user left it on auto, so the defaults stand.
if isfield(figure_data,'ylim_user') && numel(figure_data.ylim_user) == 2 ...
        && figure_data.ylim_user(2) > figure_data.ylim_user(1)
    ylim_vec = figure_data.ylim_user;
end

% Same for the legend corner: the GUI's choice overrides the per-metric
% defaults set in the switch above.
if isfield(figure_data,'legend_loc_user') && strlength(figure_data.legend_loc_user) > 0
    loc = figure_data.legend_loc_user;
elseif ~isempty(secondary_vals) && (loc == "best" || strlength(string(loc)) == 0)
    % "best" inside a 3-D box lands the legend on top of the surfaces
    % whatever it picks, because the data fills the frame. Outside is the
    % only placement that is reliably readable; an explicit GUI choice
    % still wins over this.
    loc = "northeastoutside";
end

% Apply a y-axis only when one is actually usable. An empty or degenerate
% ylim means "auto", and a lower limit of <= 0 is meaningless on a log
% axis -- forcing it there produced a broken axis for every log-scale
% metric once profiles stopped carrying ylim_vec (2026-10-07).
apply_ylim = ~isempty(ylim_vec) && numel(ylim_vec) == 2 && ylim_vec(2) > ylim_vec(1);
if apply_ylim && y_type == "log" && ylim_vec(1) <= 0
    apply_ylim = false;
end
if apply_ylim
    if ~isempty(secondary_vals)
        zlim(ylim_vec);
    else
        ylim(ylim_vec);
    end
end
xlim([primary_vals(1) primary_vals(end)]);
xticks(primary_vals);
if ~isempty(secondary_vals)
    ylim([secondary_vals(1) secondary_vals(end)]);
    yticks(secondary_vals);
end
grid on;
% A ONE-CONFIG FIGURE GETS NO LEGEND (2026-10-09). A legend exists to tell
% curves apart; with a single curve it only repeats what the axes already
% say and covers part of the data doing it. Keyed on the number of configs
% rather than on the number of curves actually drawn, so a profile that is
% merely UNCOLLECTED still renders the same furniture it will have once it
% has data -- a legend that appears and disappears as frames arrive would
% make iterative rendering flicker.
if num_configs > 1
    legend(legend_vec, Location=loc, Interpreter='latex');
end
set(gca, 'FontSize', font_val);
set(gca, 'Box', 'on');
set(gca, 'LineWidth', 1.2);

% MARGINS. Run AFTER every label and the legend exist, because TightInset
% measures what is currently drawn -- asking before the labels are set
% reports the margin an unlabelled axes needs, which is the mistake that
% left "Coded Throughput, per codeword (bps/Hz)" clipped at the figure edge.
%
% A floor is applied on top of TightInset rather than trusting it alone: it
% does not account for the ROTATED tick labels a 3-D view produces, which is
% what clipped the x-label on the first mesh renders. 3-D needs the larger
% floor because it hangs both an x- and a z-label outside the plot box.
%
% 2-D DELIBERATELY ENLARGES THE CANVAS RATHER THAN TIGHTENING THE MARGINS.
% Margins are a FRACTION of figure size while the label is a fixed point
% size, so a bigger canvas buys the label more absolute room; shrinking
% LooseInset instead just lets the axes expand into the space the label
% needed, which made the clipping worse. TightInset is not a reliable
% backstop here either -- it under-measures rotated text drawn through the
% LaTeX interpreter, which is exactly what a long y-label like
% "Coded Throughput, per codeword (bps/Hz)" is.
if isempty(secondary_vals)
    set(gcf, 'Position', [100 100 760 560]);
end
drawnow;
ax_m = gca;
if ~isempty(secondary_vals)
    ax_m.LooseInset = max(ax_m.TightInset, [0.13 0.13 0.07 0.06]);
end

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

end   % gen_figure -- local functions follow

function [name, scale, ax_type] = sweep_axis_label(v)
% SWEEP_AXIS_LABEL  Display name, unit scaling and log/linear for a swept
% variable.
%
%   Factored out of gen_figure's x-axis switch on 2026-10-09 so that the
%   SECONDARY axis of a grid figure is labelled by the same rules as the
%   primary one. Returning the scale rather than mutating the caller's
%   values keeps it usable for either axis.
%
%   OUTPUTS:
%     name:    LaTeX display name
%     scale:   multiply the axis values by this (unit conversion)
%     ax_type: "linear" or "log"

scale   = 1;
ax_type = "linear";
switch string(v)
    case "EbN0"
        name = "$E_b/N_0$ (dB)";
    case "vel"
        name = "Vehicular velocity (km/hr)";
    case "T"
        scale = 1e6;
        name = "$T$ ($\mu$s)";
    case "frequency_limit"
        name = "Cutoff Frequency (Hz)";
    case "max_timing_offset"
        name = "$|\tau_e|$ (in $T_s$)";
    case "N_iters"
        name = "Number of iterations";
    case "num_init_frames"
        name = "Number of initialization frames";
    case "num_pilot_frames_during_init"
        name = "Number of pilot frames during init.";
    case "shrinkage_alpha"
        name = "$\alpha_{shrinkage}$";
    case "cov_epsilon"
        name = "$\epsilon$";
    case "num_pilots"
        name = "Pilots per frame";
        ax_type = "log";
    case "pilot_energy_alloc"
        name = "$E_{p,total} / E_{frame}$";
        ax_type = "log";
    case "v_res"
        name = "Resolution of pseudospectrum";
        ax_type = "log";
    case "M"
        name = "$M$ (num. subcarriers)";
        ax_type = "log";
    case "N"
        name = "$N$ (num. time syms.)";
        ax_type = "log";
    case "gamma_p"
        name = "Pilot SNR $\gamma_{p}$ (dB)";
    % LDPC sweep variables (the ldpc_* aliases resolve_ldpc_settings
    % exposes). Added with the grid feature: before this they fell through
    % to the default and an axis simply read "ldpc_rate".
    case "ldpc_rate"
        name = "Code rate $R$";
    case "ldpc_N"
        name = "Codeword length $N_c$";
        ax_type = "log";
    case "ldpc_bp_iters"
        name = "BP iterations";
    case "ldpc_colweight"
        name = "Column weight $w_c$";
    % Dictionary oversampling. Both are swept in doubling sequences, so a
    % log axis is the honest one: on a linear axis the 8-to-16 step and the
    % 32-to-64 step would look wildly different while costing the same
    % factor of search grid.
    case "PiTau"
        name = "$\Pi_\tau$ (delay grid oversampling)";
        ax_type = "log";
    case "PiNu"
        name = "$\Pi_\nu$ (Doppler grid oversampling)";
        ax_type = "log";
    case "NGS"
        name = "Gauss-Seidel sweeps $N_{GS}$";
    otherwise
        name = string(v);
end
end

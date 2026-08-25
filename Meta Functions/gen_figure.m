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

%% Load data from DB
switch save_data.priority
    case "mysql"
        if save_data.save_mysql
            try
                T = mysql_load(conn, table_name, "*");
            catch
                conn = mysql_login(conn.DataSource);
                T = mysql_load(conn, table_name, "*");
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
                T = mysql_load(conn, table_name, "*");
            catch
                conn = mysql_login(conn.DataSource);
                T = mysql_load(conn, table_name, "*");
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

                    % Throughput special case
                    if data_type == "Thr"
                        params_loaded = jsondecode(sim_result.parameters{row_idx});
                        switch params_loaded.system_name
                            case "MUSIC"
                                FER = metrics_loaded.FER;
                                T_val = params_loaded.T;
                                M = params_loaded.M;
                                N = params_loaded.N;
                                Q = params_loaded.num_pilots;
                                Ts = T_val / M;
                                L = 1 + floor(2510e-9 / Ts);
                                trial_vals(row_idx) = 2 * (1 - FER) * (M * N) / (M * N + (2 * L + 1) * Q);
                            otherwise
                                FER = metrics_loaded.FER;
                                params_loaded = jsondecode(sim_result.parameters{row_idx});
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
    otherwise
        xlabel_name = string(primary_var);
end

%% Y-Axis label
y_type = "log";
switch data_type
    case "Thr"
        loc = "southeast";
        y_type = "linear";
        ylabel_name = "Throughput (bps/Hz)";
        ylim_vec = [0 2];
    case "t_RXfull"
        results_mat = results_mat * 1000;
        ylabel_name = "$t_{RX,avg}$ (ms)";
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

%% Plot
figure(1);
clf;
hold on;
for sel = 1:num_configs
    plot(primary_vals, results_mat(:, sel), ...
        line_styles{sel}, ...
        Color=line_colors{sel}, ...
        linewidth=line_val, ...
        MarkerSize=mark_val);
end
if num_trials > 1
    for sel = 1:num_configs
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

function gen_table(save_data,conn,table_name,hash_cell,configs,figure_data)

% Import settings
data_type = figure_data.data_type;
primary_var = figure_data.primary_var;
primary_vals = figure_data.primary_vals;

% Load data from DB, scoped to this table's own param_hashes rather than
% "*" (a full-table scan of the results table shared across every project)
% Every results source, merged; an exploration run's in-memory rows instead (storage steps 7a, 7a.1)
if isfield(save_data,'mem_table')
    T = save_data.mem_table;
else
    T = load_merged(conn,"",table_name,hash_cell(:),table,300);
end


% GRID SWEEPS (2026-10-09). With a secondary variable the point list is the
% flattened primary x secondary product, so there are more ROWS than there
% are primary values. Sizing from hash_cell is correct either way; sizing
% from primary_vals left the table with fewer row names than rows, which
% array2table rejects only after the whole load loop has run.
secondary_var  = "";
secondary_vals = [];
if isfield(figure_data,'secondary_var') && ~isempty(figure_data.secondary_var) ...
        && isfield(figure_data,'secondary_vals') && ~isempty(figure_data.secondary_vals)
    secondary_var  = string(figure_data.secondary_var);
    secondary_vals = figure_data.secondary_vals;
end

% Load loop
results_mat = cell(size(hash_cell,1),length(configs));
% Samples behind each value (2026-10-16): metrics carry their own counts
% now (metric_sample_count), so frames_simulated no longer says how much
% data a given metric has. NaN where the point has no value.
count_mat = NaN(size(hash_cell,1),length(configs));
col_names = cell(length(configs),1);
for primvar_sel = 1:size(hash_cell,1)

    % Go through each settings profile
    for sel = 1:size(hash_cell,2)

        % Load data from DB
        paramHash = hash_cell{primvar_sel,sel};
        sim_result = T(string(T.param_hash) == paramHash, :);

        % Select data to extract. A POINT WITH NO ROW YET IS NORMAL -
        % every profile looks like this before it is fully collected, and
        % on a grid sweep most points are empty for a long time. This used
        % to index metrics{1} unconditionally and threw "Index exceeds
        % array bounds" on the first uncollected point, which made the
        % table view unusable on any partially-collected profile. An empty
        % hash (a flat config's non-anchor cell) lands here too.
        if isempty(sim_result) || isempty(paramHash)
            results_mat{primvar_sel,sel} = NaN;
        else
            metrics_loaded = jsondecode(sim_result.metrics{1});
            if isfield(metrics_loaded, data_type)
                results_val = metrics_loaded.(data_type);
            else
                results_val = [];
            end
            if isempty(results_val)
                results_mat{primvar_sel,sel} = NaN;
            else
                results_mat{primvar_sel,sel} = results_val;
                n_all = metric_sample_count(sim_result);
                if isfield(n_all, data_type)
                    count_mat(primvar_sel,sel) = n_all.(data_type);
                end
            end
        end

        if primvar_sel == 1
            % COLUMN NAMES MUST BE VALID MATLAB VARIABLE NAMES. This used
            % to be the whole config JSON, which is neither valid nor
            % short: anything beyond a trivial config exceeds
            % namelengthmax (63) and threw
            % MATLAB:table:VariableNameLengthMax, making vis_type="table"
            % unusable in practice. It went unnoticed because every
            % profile was hardcoded to "figure"; the 2026-10-07 GUI
            % visualization dropdown made the path reachable.
            %
            % The profile's own legend text is what the column means, so
            % prefer it and keep the JSON only as a fallback.
            if isfield(figure_data,'legend_vec') && numel(figure_data.legend_vec) >= sel ...
                    && strlength(string(figure_data.legend_vec{sel})) > 0
                col_names{sel} = char(string(figure_data.legend_vec{sel}));
            else
                col_names{sel} = jsonencode_sorted(configs{sel});
            end
        end

    end
end

% Create results table
if isempty(secondary_vals)
    row_names = cellstr(string(primary_vals));
else
    % One row per (primary, secondary) pair, labelled with both so the
    % table stays readable. PRIMARY VARIES FASTEST, matching the
    % flattening order in sim_head and the reshape in gen_figure.
    nP = numel(primary_vals);
    nS = numel(secondary_vals);
    row_names = cell(nP*nS,1);
    for s_i = 1:nS
        for p_i = 1:nP
            row_names{(s_i-1)*nP + p_i} = sprintf('%g, %s=%g', ...
                primary_vals(p_i), secondary_var, secondary_vals(s_i));
        end
    end
end
data_table = cell2table(results_mat);
data_table.Properties.DimensionNames{1} = char(primary_var);
data_table.Properties.RowNames = row_names;
% Sanitise: valid identifiers, unique, and within namelengthmax. Doing it
% here rather than at each assignment keeps the uniqueness check global.
col_names = matlab.lang.makeValidName(col_names);
col_names = matlab.lang.makeUniqueStrings(col_names, {}, namelengthmax);
data_table.Properties.VariableNames = col_names;

% Display table
disp(primary_var + " sweep table:");
disp(data_table)
count_table = array2table(count_mat, 'VariableNames', col_names, 'RowNames', row_names);
count_table.Properties.DimensionNames{1} = char(primary_var);
disp("Samples behind each " + string(data_type) + " value:");
disp(count_table)

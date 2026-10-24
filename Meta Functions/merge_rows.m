function row = merge_rows(rows)
% MERGE_ROWS  Combine result rows that share a param_hash into one row.
%
%   row = merge_rows(rows)
%
%   Rows for the same simulation point can sit in several results databases
%   (one per machine; notes/PER_MACHINE_DB_PLAN.md). Each row is a running
%   aggregate of independent frames, so the rows combine exactly as
%   mysql_write combines a new batch with a stored row:
%     - frames_simulated adds;
%     - each metric is the mean of the rows' values, weighted by the samples
%       behind it (metric_sample_count, so metrics_n and its gap rule apply);
%     - metrics_n holds the summed counts, with frames_basis = the total;
%     - metrics_aux is folded with merge_metrics_aux (counters add,
%       mean/M2 combine by Chan's formula).
%
%   INPUT:
%     rows: table of two or more rows with one param_hash, columns as
%           mysql_load returns them (JSON columns are cells of char).
%
%   OUTPUT:
%     row: one-row table with the same columns.
%
%   LIMITS: the merge is exact only if the rows hold different frames;
%   rows that replay the same seeds count those frames twice (notes S2).
%
%   REFERENCES: the accumulation rules of mysql_write.m. Field rules, and
%   why parameters comes from the first row, are in
%   Common Wireless Simulator/notes/merge_rows_NOTES.md, cited below as
%   (notes Sn).

% Start from the first row so every column and type carries over
row = rows(1, :);
F = double(rows.frames_simulated);
n_rows = height(rows);

% Each row's metric values and the samples behind them
m = cell(n_rows, 1);
n = cell(n_rows, 1);
for r = 1:n_rows
    m{r} = decode(rows.metrics(r));
    n{r} = metric_sample_count(rows(r, :));
end

% Every metric any row reports, in first-seen order
fields = {};
for r = 1:n_rows
    if isstruct(m{r}), fields = union(fields, fieldnames(m{r}), 'stable'); end
end

% Sample-weighted mean of each metric, and its summed count (notes S1)
metrics = struct();
metrics_n = struct('frames_basis', sum(F));
for f = 1:numel(fields)
    name = fields{f};
    [s, w] = deal(0);

    % Accumulate over the rows that hold samples of this metric
    for r = 1:n_rows
        if isstruct(m{r}) && isfield(m{r}, name) && isfield(n{r}, name) && n{r}.(name) > 0
            s = s + m{r}.(name) * n{r}.(name);
            w = w + n{r}.(name);
        end
    end

    % The weighted mean, or the first stored value when no row has samples
    if w > 0
        metrics.(name) = s / w;
    else
        metrics.(name) = first_value(m, name);
    end
    metrics_n.(name) = w;
end

% Fold the auxiliary aggregates the way mysql_write merges a batch (notes S1)
aux = [];
for r = 1:n_rows
    if ismember('metrics_aux', rows.Properties.VariableNames)
        a = decode(rows.metrics_aux(r));
        if isstruct(a), aux = merge_metrics_aux(aux, a); end
    end
end

% Write the merged values back in the stored JSON form
row.frames_simulated = cast(sum(F), 'like', rows.frames_simulated);
row.metrics = {jsonencode(metrics)};
if ismember('metrics_n', rows.Properties.VariableNames)
    row.metrics_n = {jsonencode(metrics_n)};
end
if ismember('metrics_aux', rows.Properties.VariableNames) && ~isempty(aux)
    row.metrics_aux = {jsonencode(aux)};
end

% The newest update time stands for the merged row
if ismember('updated_at', rows.Properties.VariableNames)
    t = string(rows.updated_at);
    t = t(~ismissing(t) & strlength(t) > 0);
    t = sort(t);
    if ~isempty(t), row.updated_at = {char(t(end))}; end
end
end

function s = decode(v)
% A JSON cell of a results table, or [] when it is NULL or empty.
s = [];
if iscell(v), v = v{1}; end
if isempty(v) || (isstring(v) && ismissing(v)), return; end
if isstruct(v), s = v; return; end
s = jsondecode(char(v));
end

function v = first_value(m, name)
% A metric no row has samples for keeps the first value stored for it.
v = [];
for r = 1:numel(m)
    if isstruct(m{r}) && isfield(m{r}, name), v = m{r}.(name); return; end
end
end

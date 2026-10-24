function [metrics, metrics_n, aux] = apply_batch(old, N_total, metrics_add, metrics_n_add, aux_delta)
% APPLY_BATCH  Blend one batch into a results row: the single merge rule of every store.
%
%   [metrics, metrics_n, aux] = apply_batch(old, N_total, metrics_add, metrics_n_add, aux_delta)
%
%   A results row is a running aggregate (mysql_write notes S1-S5, S8). This
%   is that aggregation, with no database access, so the MySQL, SQLite and
%   text stores and every row rebuild give the same row for the same
%   batches (STORAGE_BACKENDS_PLAN.md section 12 A). Extracted unchanged
%   from mysql_write on 2026-10-21 (storage step 3).
%
%   INPUTS:
%     old            [] for a new row, else struct with fields metrics (the
%                    stored metrics), n (metric_sample_count of the row) and
%                    aux (the stored metrics_aux, or [])
%     N_total        frames_simulated after this batch
%     metrics_add    this batch's mean per metric
%     metrics_n_add  samples behind each metric of the batch (every metric of
%                    metrics_add listed)
%     aux_delta      this batch's metrics_aux aggregate, or []
%
%   OUTPUTS:
%     metrics, metrics_n  the row's new metrics and per-metric counts
%                         (metrics_n.frames_basis = N_total)
%     aux                 merged metrics_aux, or [] when aux_delta is empty
%
%   LIMITS: the legacy cumulative metrics_aux form (notes S9) is not handled
%   here; mysql_write keeps it.

% A new row is the batch itself (field order as mysql_write always wrote it)
if isempty(old)
    metrics = metrics_add;
    metrics_n = metrics_n_add;
    metrics_n.frames_basis = N_total;
    aux = [];
    if ~isempty(aux_delta), aux = merge_metrics_aux([], aux_delta); end
    return
end

% Blend metric by metric over every field on the row or in the batch (notes S2)
metrics = struct();
metrics_n = struct('frames_basis', N_total);
all_fields = union(fieldnames(old.metrics), fieldnames(metrics_add), 'stable');
for iField = 1:numel(all_fields)
    field = all_fields{iField};
    n_o = 0;
    if isfield(old.n, field), n_o = old.n.(field); end

    % A field this batch did not report keeps its value and count.
    if ~isfield(metrics_add, field)
        metrics.(field) = old.metrics.(field);
        metrics_n.(field) = n_o;
        continue
    end

    % Sample-weighted mean; a field new to the row is seeded from the batch (notes S8).
    n_a = metrics_n_add.(field);
    if ~isfield(old.metrics, field) || n_o <= 0
        metrics.(field) = metrics_add.(field);
    elseif n_a <= 0
        metrics.(field) = old.metrics.(field);
    else
        metrics.(field) = (old.metrics.(field) * n_o + metrics_add.(field) * n_a) / (n_o + n_a);
    end
    metrics_n.(field) = n_o + n_a;
end

% Per-batch metrics_aux merged into the row's (notes S5)
aux = [];
if ~isempty(aux_delta), aux = merge_metrics_aux(old.aux, aux_delta); end
end

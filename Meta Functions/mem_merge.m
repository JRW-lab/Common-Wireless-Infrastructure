function T = mem_merge(T, batch)
% MEM_MERGE  Add one batch to an exploration run's in-memory results table.
%
%   T = mem_merge(T, batch)
%
%   An exploration run (sim_head with dont_save, storage step 7a.1) writes
%   nothing to any store. sim_save returns each batch instead, and sim_head
%   merges it here with apply_batch, the merge rule every store uses, so the
%   in-memory rows equal what a store would hold after the same batches.
%
%   INPUTS:
%     T      the in-memory table (param_hash, parameters, metrics,
%            metrics_n, metrics_aux as JSON text cells; frames_simulated),
%            or an empty table
%     batch  sim_save's output: param_hash, parameters, frames_add,
%            metrics_add, metrics_n_add, aux_delta; [] adds nothing
%
%   OUTPUT:
%     T: the table with the batch merged into its row (or a new row)
%
%   LIMITS: memory only; the table is gone when the run ends.

% An empty table gets its columns (mem_merge(table(), []) makes one); nothing simulated adds nothing
if width(T) == 0
    e = cell(0, 1);
    T = table(e, e, e, e, e, zeros(0, 1), 'VariableNames', {'param_hash', 'parameters', 'metrics', 'metrics_n', 'metrics_aux', 'frames_simulated'});
end
if isempty(batch), return; end

% Every reported metric gets a sample count; a missing one counts the batch's frames (mysql_write notes S1)
mn_add = batch.metrics_n_add; if isempty(mn_add), mn_add = struct(); end
fa = fieldnames(batch.metrics_add);
for i = 1:numel(fa)
    if ~isfield(mn_add, fa{i}), mn_add.(fa{i}) = batch.frames_add; end
end

% Merge with the store rule: a new row is the batch itself, an existing one is blended (apply_batch)
k = find(string(T.param_hash) == batch.param_hash, 1);
if isempty(k)
    N_total = batch.frames_add;
    [m, mn, aux] = apply_batch([], N_total, batch.metrics_add, mn_add, batch.aux_delta);
    k = height(T) + 1;
    T(k, :) = {char(batch.param_hash), jsonencode_sorted(batch.parameters), '', '', '', 0};
else
    N_total = double(T.frames_simulated(k)) + batch.frames_add;
    old = struct('metrics', jsondecode(T.metrics{k}), 'n', metric_sample_count(T(k, :)), 'aux', []);
    if ~isempty(T.metrics_aux{k}), old.aux = jsondecode(T.metrics_aux{k}); end
    [m, mn, aux] = apply_batch(old, N_total, batch.metrics_add, mn_add, batch.aux_delta);
    if isempty(batch.aux_delta) && ~isempty(old.aux), aux = old.aux; end
end

% Store the row back as JSON text, as a MySQL read returns it
T.metrics{k} = jsonencode(m);
T.metrics_n{k} = jsonencode(mn);
if ~isempty(aux), T.metrics_aux{k} = jsonencode(aux); end
T.frames_simulated(k) = N_total;
end

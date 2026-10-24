function [L, info] = ledger_records(dbname, table_name, hashes, with_archive)
% LEDGER_RECORDS  Batch records of some points from every results source.
%
%   [L, info] = ledger_records(dbname, table_name, hashes)
%   [L, info] = ledger_records(dbname, table_name, hashes, true)   + archived
%
%   Phase 3 step 4 (notes/PER_MACHINE_DB_PLAN.md 6.4): paired_compare and
%   ledger_check read the per-batch records here. Each computer is read
%   through store_read: its first usable store, MySQL or the synced copy of
%   a file store (another computer) or its live primary (this computer).
%   The legacy table has no ledger and is skipped. A source that can't be
%   read is listed in info.unreachable and left out (D4), never an error.
%
%   INPUTS:
%     dbname, table_name  the caller's own source, as for load_merged
%                         ("" for a computer without MySQL)
%     hashes              param_hash list, or "*"
%     with_archive        true: also records retired by deletes (archived)
%
%   OUTPUTS:
%     L:    records (store_read "records" columns) plus source and writer
%     info: struct with sources (read), unreachable, and used (store per source)
%
%   LIMITS: read only.

% Every registered source
if nargin < 4, with_archive = false; end
what = "records"; if with_archive, what = "records_all"; end
src = db_sources(dbname, table_name);
L = table(strings(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
    false(0, 1), strings(0, 1), strings(0, 1), 'VariableNames', {'param_hash', 'lane', 'seed_base', 'k_start', 'n_frames', ...
    'batch_uid', 'code_rev', 'delta', 'archived', 'source', 'writer'});
info = struct('sources', strings(1, 0), 'unreachable', strings(1, 0), 'used', strings(1, 0));

% One computer at a time: this one live, the others through their first usable store
for k = 1:numel(src)
    if src(k).role ~= "machine" && ~src(k).own, continue; end
    try
        if ~isempty(src(k).stores)
            mode = "remote"; if src(k).own, mode = "own"; end
            [Lk, u] = store_read(src(k), hashes, mode, what);
            used = u.key;
        else
            s = struct('kind', "mysql", 'priority', 1, 'host', src(k).host, 'dbname', src(k).dbname, 'table', src(k).table, 'path', "");
            [Lk, u] = store_read(struct('writer', src(k).writer, 'stores', s), hashes, "own", what);
            used = u.key;
        end
    catch ME
        info.unreachable(end+1) = src(k).name + " (" + string(ME.message) + ")";
        continue
    end

    % Tag each record with where it came from
    Lk.source = repmat(string(src(k).name), height(Lk), 1);
    Lk.writer = repmat(string(src(k).writer), height(Lk), 1);
    L = [L; Lk]; %#ok<AGROW>
    info.sources(end+1) = src(k).name;
    info.used(end+1) = string(used);
end
end

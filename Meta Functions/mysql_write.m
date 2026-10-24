function status = mysql_write(conn,table_name,parameters,new_frames,metrics_add,varargin)
%MYSQL_WRITE  Accumulate one batch of simulated frames into a results table.
%
%   mysql_write(conn,table,params,new_frames,metrics_add)
%   mysql_write(...,use_mutex)
%   mysql_write(...,use_mutex,metrics_aux_cumulative)
%   mysql_write(...,use_mutex,metrics_aux_cumulative,metrics_aux_delta)
%   mysql_write(...,use_mutex,metrics_aux_cumulative,metrics_aux_delta,metrics_n_add)
%   mysql_write(...,metrics_n_add,batch_record)
%   status = mysql_write(...)
%
%   PURPOSE. Adds one batch's results to the row keyed by the hash of
%   parameters, and creates the row if there is none. A row is a running
%   aggregate: frames_simulated is the total number of full frames, and each
%   metric is the mean over every sample behind it, so the batch is blended
%   in weighted by its own sample count, metric by metric. The write is a
%   compare-and-swap: it commits only if the row is unchanged since it was
%   read, and otherwise re-reads, re-merges and retries, so concurrent
%   writers on one row never lose or double-count frames.
%
%   INPUTS
%     conn           open database connection (mysql_login, db_source_conn).
%     table_name     results table, normally sim_lookup.
%     parameters     struct of the point's parameters; jsonencode_sorted
%                    hashes it into param_hash.
%     new_frames     frames in this batch that ran the whole pipeline;
%                    frames_simulated grows by exactly this. A stage-limited
%                    batch passes 0 (notes S1).
%     metrics_add    struct, metric name -> this batch's mean value.
%     use_mutex      optional, default false: also hold the mysql_check /
%                    mysql_set flag around the write.
%     metrics_aux_cumulative  optional, legacy: the caller's cumulative
%                    metrics_aux aggregate (notes S5).
%     metrics_aux_delta  optional: this batch's own metrics_aux aggregate,
%                    merged here with merge_metrics_aux (notes S5).
%     metrics_n_add  optional struct, metric name -> samples behind it in
%                    this batch; a metric not listed counts new_frames
%                    (notes S1).
%     batch_record   optional struct (the ledger): batch_uid (required, made
%                    once per batch by the caller with new_batch_uid and
%                    reused on its retries), and the optional Phase 3 fields
%                    lane, seed_base, k_start, code_rev, started_at,
%                    finished_at. When given, the batch is also recorded in
%                    the ledger table (sim_batches for sim_lookup, else
%                    <table>_batches) in the SAME transaction as the row
%                    update, so the row always equals its unledgered part
%                    plus the sum of its ledger deltas. Not combinable with
%                    use_mutex (notes S13).
%
%   OUTPUT
%     status: "committed", or "already_recorded" when the ledger
%                    already holds this batch_uid (a retry after a lost reply;
%                    nothing is added, warning mysql_write:batchAlreadyRecorded).
%     The row is updated or inserted. Errors after MAX_ATTEMPTS lost
%     races without recording the batch (notes S7). Warns when a legacy
%     cumulative metrics_aux could not be merged after a lost race (notes S9).
%
%   LIMITS. A write never deletes a stored metric (notes S2). Rows written
%   by older copies of this file, without metrics_n, are reconciled on read
%   by metric_sample_count (notes S3). merge_rows combines rows from several
%   databases by the same rules.
%
%   REFERENCES
%     Common Wireless Simulator/notes/DESIGN_concurrent_collection.md (the
%       compare-and-swap design and the designs not taken).
%   Why each choice was made, and its history, are in
%   Common Wireless Simulator/notes/mysql_write_NOTES.md, cited below as
%   (notes Sn).

%% ===== 1. OPTIONAL INPUTS =============================================
% Reads the optional arguments and gives every reported metric its sample
% count for this batch.

% Optional mutex flag.
use_mutex = false;
metrics_aux_new = [];
metrics_aux_delta = [];
if ~isempty(varargin)
    use_mutex = varargin{1};
end

% Optional cumulative and per-batch metrics_aux (notes S5).
if length(varargin) >= 2
    metrics_aux_new = varargin{2};
end
if length(varargin) >= 3
    metrics_aux_delta = varargin{3};
end

% Optional per-metric sample counts (notes S1).
metrics_n_add = [];
if length(varargin) >= 4
    metrics_n_add = varargin{4};
end

% Optional Phase 3 batch record; the mutex flag would be invisible inside the transaction (notes S13).
batch_record = [];
if length(varargin) >= 5
    batch_record = varargin{5};
end
use_txn = ~isempty(batch_record);
status = "committed";
if use_txn && (~isfield(batch_record, 'batch_uid') || strlength(string(batch_record.batch_uid)) ~= 64)
    error('mysql_write:noBatchUid', 'batch_record needs a 64-character batch_uid from new_batch_uid (notes S14).');
end
if use_txn && use_mutex
    error('mysql_write:mutexWithLedger', 'batch_record cannot be combined with use_mutex (notes S13).');
end

% A metric without a count came from the batch's full frames.
mf_add = fieldnames(metrics_add);
if isempty(metrics_n_add), metrics_n_add = struct(); end
for iField = 1:numel(mf_add)
    if ~isfield(metrics_n_add, mf_add{iField})
        metrics_n_add.(mf_add{iField}) = new_frames;
    end
end

%% ===== 2. TABLE COLUMNS ===============================================
% Adds the metrics_aux, metrics_n and write_seq columns when the table
% lacks them, once per table per MATLAB session (notes S6).

% Tables already checked in this session.
persistent metrics_aux_ready
if isempty(metrics_aux_ready)
    metrics_aux_ready = containers.Map('KeyType', 'char', 'ValueType', 'logical');
end

% Each ALTER fails harmlessly when the column already exists; metrics_aux first.
if ~isKey(metrics_aux_ready, char(table_name))
    try
        execute(conn, "ALTER TABLE " + table_name + " ADD COLUMN metrics_aux JSON NULL");
    catch
    end

    % Per-metric counts and the write counter the compare-and-swap uses (notes S1, S4).
    try
        execute(conn, "ALTER TABLE " + table_name + " ADD COLUMN metrics_n JSON NULL");
    catch
    end
    try
        execute(conn, "ALTER TABLE " + table_name + " ADD COLUMN write_seq INT NOT NULL DEFAULT 0");
    catch
    end
    metrics_aux_ready(char(table_name)) = true;
end

% The ledger table, created once per database and table in this session (notes S13).
persistent ledger_ready
if isempty(ledger_ready)
    ledger_ready = containers.Map('KeyType', 'char', 'ValueType', 'logical');
end
ledger_table = ledger_name(table_name);
ledger_key = char(string(conn.DataSource) + "." + ledger_table);
if use_txn && ~isKey(ledger_ready, ledger_key)
    execute(conn, ledger_ddl(ledger_table));

    % A ledger made before batch_uid existed gains the column and its UNIQUE key (notes S14)
    try
        execute(conn, "ALTER TABLE " + ledger_table + " ADD COLUMN batch_uid CHAR(64) NULL");
    catch
    end
    try
        execute(conn, "ALTER TABLE " + ledger_table + " ADD UNIQUE KEY uq_uid (batch_uid)");
    catch
    end
    ledger_ready(ledger_key) = true;
end

%% ===== 3. COMPARE-AND-SWAP WRITE =====================================
% Loops until the batch is committed: read the row, blend the batch into
% it, and UPDATE only where the row still holds the values that were read
% (frames_simulated, and write_seq where the row has it). A lost race
% re-reads and re-merges after a randomised backoff; the frames are still
% in hand, so nothing is re-simulated. A missing row is INSERTed; a
% duplicate-key rejection means another writer created it first, and is
% handled as a lost race. Gives up after MAX_ATTEMPTS attempts (notes S4,
% S7).

% Point hash, retry budget and loop state (notes S7).
[paramsJSON,paramHash] = jsonencode_sorted(parameters);
MAX_ATTEMPTS = 20;
attempt = 0;
aux_conflict_unresolvable = false;
need_to_write = true;

% With a batch record, every attempt is one transaction; cleanup rolls back anything uncommitted, then restores AutoCommit (notes S13)
if use_txn
    ac_old = conn.AutoCommit;
    conn.AutoCommit = 'off';
    txn_cleanup = onCleanup(@() end_txn(conn, ac_old));
end
while need_to_write

    % Count the attempt; give up loudly once the budget is spent.
    attempt = attempt + 1;
    if attempt > MAX_ATTEMPTS
        error('mysql_write:casRetriesExhausted', ...
            ['Could not commit %d frames for param_hash %s after %d ' ...
             'compare-and-swap attempts. Another writer is updating this ' ...
             'row continuously, or frames_simulated is being changed by ' ...
             'something outside mysql_write. The frames were NOT recorded.'], ...
            new_frames, paramHash, MAX_ATTEMPTS);
    end

    % Optional mutex: wait while another process holds the flag, then take it.
    if use_mutex
        mysql_flag_id = 0;
        flag_val = mysql_check(conn,mysql_flag_id);
        if flag_val
            waitTime = 1 + (5 - 1) * rand();
            pause(waitTime);
            continue
        end
        mysql_set(conn,mysql_flag_id);
    end

    % A batch_uid already in the ledger means this batch was committed before: confirm it and stop (notes S14).
    if use_txn
        prev = ledger_by_uid(conn, ledger_table, batch_record.batch_uid);
        if ~isempty(prev)
            rollback(conn);
            status = already_recorded(prev, paramHash, new_frames, batch_record);
            return
        end
    end

    % Read the row as it stands now.
    sim_result = mysql_load(conn,table_name,paramHash);

    % Existing row: the frame count read is both the merge base and the guard (notes S4).
    if ~isempty(sim_result)
        N_old = sim_result.frames_simulated;
        N_total = N_old + new_frames;

        % write_seq guards batches that add no frames; NaN when the row lacks it (notes S4).
        seq_old = NaN;
        if ismember('write_seq', sim_result.Properties.VariableNames)
            seq_old = double(sim_result.write_seq(1));
        end

        % The stored row as apply_batch takes it: metrics, sample counts (notes S3) and, for a per-batch delta, metrics_aux.
        old = struct('metrics', jsondecode(sim_result.metrics{1}), 'n', metric_sample_count(sim_result), 'aux', []);
        if ~isempty(metrics_aux_delta) && ismember('metrics_aux', sim_result.Properties.VariableNames) ...
                && ~ismissing(sim_result.metrics_aux(1)) && ~isempty(sim_result.metrics_aux{1})
            old.aux = jsondecode(sim_result.metrics_aux{1});
        end

        % Blend the batch into the row with the merge rule every store shares (apply_batch; notes S2, S5, S8, S15).
        [metrics, metrics_n, aux_merged] = apply_batch(old, N_total, metrics_add, metrics_n_add, metrics_aux_delta);
        metricsJSON = jsonencode(metrics);
        metrics_nJSON = jsonencode(metrics_n);

        % Per-batch metrics_aux, merged inside the guard (notes S5).
        write_aux = true;
        if ~isempty(metrics_aux_delta)
            metrics_auxJSON = jsonencode(aux_merged);

        % Legacy cumulative metrics_aux: written as given, but left alone after a lost race (notes S9).
        elseif ~isempty(metrics_aux_new)
            if attempt > 1
                write_aux = false;
                aux_conflict_unresolvable = true;
            end
            metrics_auxJSON = jsonencode(metrics_aux_new);
        else
            metrics_auxJSON = [];
        end

        % SET list, each newer column only where the row has it (notes S12).
        set_list = sprintf("metrics = '%s', frames_simulated = %d", metricsJSON, N_total);
        if ismember('metrics_n', sim_result.Properties.VariableNames)
            set_list = set_list + sprintf(", metrics_n = '%s'", metrics_nJSON);
        end
        if ~isempty(metrics_auxJSON) && write_aux
            set_list = set_list + sprintf(", metrics_aux = '%s'", metrics_auxJSON);
        end

        % Guarded UPDATE: frames_simulated, plus write_seq when the row has it (notes S4).
        guard = sprintf("param_hash = '%s' AND frames_simulated = %d", paramHash, N_old);
        if ~isnan(seq_old)
            set_list = set_list + sprintf(", write_seq = %d", seq_old + 1);
            guard = guard + sprintf(" AND write_seq = %d", seq_old);
        end
        sqlupdate = sprintf("UPDATE %s SET %s WHERE %s", table_name, set_list, guard);
        exec(conn, sqlupdate);

        % Rows the UPDATE matched, read straight after it; unreadable counts as applied (notes S10).
        affected = 0;
        try
            rc = fetch(conn, "SELECT ROW_COUNT() AS rc");
            if ~isempty(rc)
                affected = double(rc{1,1});
            end
        catch
            affected = 1;
        end

        % Lost the race: release the mutex, back off at random, then re-read and re-merge (notes S4).
        if affected == 0
            if use_mutex
                mysql_unset(conn,mysql_flag_id);
            end
            if use_txn, rollback(conn); end
            pause(0.05 + 0.25 * attempt * rand());
            continue
        end

    % No row yet: the batch itself becomes the row (apply_batch with no old row; notes S15).
    else
        N_total = new_frames;
        [metrics, metrics_n, aux_merged] = apply_batch([], N_total, metrics_add, metrics_n_add, metrics_aux_delta);
        metricsJSON = jsonencode(metrics);
        metrics_nJSON = jsonencode(metrics_n);

        % The new row's metrics_aux, from the per-batch or the cumulative form (notes S5).
        if ~isempty(metrics_aux_delta)
            metrics_auxJSON = jsonencode(aux_merged);
        elseif ~isempty(metrics_aux_new)
            metrics_auxJSON = jsonencode(metrics_aux_new);
        else
            metrics_auxJSON = [];
        end

        % Row to insert, with a metrics_aux column when there is one.
        if ~isempty(metrics_auxJSON)
            sim_result_new = table( ...
                string(paramHash), ...
                string(paramsJSON), ...
                string(metricsJSON), ...
                string(metrics_auxJSON), ...
                string(metrics_nJSON), ...
                N_total, ...
                'VariableNames', {'param_hash', 'parameters', 'metrics', 'metrics_aux', 'metrics_n', 'frames_simulated'} );

        % Otherwise without it.
        else
            sim_result_new = table( ...
                string(paramHash), ...
                string(paramsJSON), ...
                string(metricsJSON), ...
                string(metrics_nJSON), ...
                N_total, ...
                'VariableNames', {'param_hash', 'parameters', 'metrics', 'metrics_n', 'frames_simulated'} );
        end

        % INSERT, naming this connection's database (notes S11).
        try
            sqlwrite(conn,table_name,sim_result_new,'Catalog',char(conn.DataSource));
        catch ME

            % Duplicate key: another writer created the row first; go round and accumulate (notes S11).
            if contains(ME.message, 'Duplicate entry', 'IgnoreCase', true)
                if use_mutex
                    mysql_unset(conn,mysql_flag_id);
                end
                if use_txn, rollback(conn); end
                pause(0.05 + 0.25 * attempt * rand());
                continue
            end

            % Any other failure: release the mutex and rethrow.
            if use_mutex
                mysql_unset(conn,mysql_flag_id);
            end
            rethrow(ME);
        end

    end

    % Record the batch in the ledger and commit it together with the row (notes S13).
    if use_txn
        try
            execute(conn, ledger_insert(ledger_table, paramHash, new_frames, batch_record, ...
                metrics_add, metrics_n_add, metrics_aux_delta));
        catch ME

            % The same batch_uid: an earlier attempt committed; confirm it and stop without adding it again (notes S14)
            rollback(conn);
            if contains(ME.message, 'uq_uid')
                prev = ledger_by_uid(conn, ledger_table, batch_record.batch_uid);
                status = already_recorded(prev, paramHash, new_frames, batch_record);
                return
            end

            % A repeated frame range is a lane or seed bug, not a transient failure: say so (notes S13)
            if contains(ME.message, 'Duplicate entry', 'IgnoreCase', true)
                error('mysql_write:duplicateBatch', ['Frames %s of param_hash %s are already in the ledger; ' ...
                    'the batch was NOT recorded. A lane or seed_base is being reused.'], ...
                    field_sql(batch_record, 'k_start'), paramHash);
            end
            rethrow(ME);
        end
        commit(conn);
    end

    % Committed: release the mutex and leave the loop.
    if use_mutex
        mysql_unset(conn,mysql_flag_id);
    end
    need_to_write = false;

end

% Report a legacy metrics_aux that a lost race left unmerged (notes S9).
if aux_conflict_unresolvable
    warning('mysql_write:auxNotMergedUnderContention', ...
        ['Concurrent write detected on param_hash %s. frames_simulated ' ...
         'and metrics were merged correctly, but metrics_aux was left ' ...
         'unchanged because this caller supplied only a cumulative ' ...
         'aggregate, which cannot be re-merged against the new base. ' ...
         'Pass the per-batch aggregate as the 3rd optional argument to ' ...
         'make metrics_aux concurrency-safe too.'], paramHash);
end

function t = ledger_name(table_name)
% Ledger table paired with a results table: sim_batches for sim_lookup, else <table>_batches (notes S13).
if string(table_name) == "sim_lookup"
    t = "sim_batches";
else
    t = string(table_name) + "_batches";
end

function q = ledger_ddl(ledger_table)
% CREATE statement for the ledger: one row per committed batch (notes S13).
q = "CREATE TABLE IF NOT EXISTS " + ledger_table + " (" + ...
    "batch_id BIGINT AUTO_INCREMENT PRIMARY KEY, param_hash CHAR(64) NOT NULL, " + ...
    "machine VARCHAR(64) NOT NULL, lane INT NULL, seed_base BIGINT NULL, k_start BIGINT NULL, " + ...
    "n_frames INT NOT NULL, batch_uid CHAR(64) NOT NULL, code_rev CHAR(64) NULL, matlab_release VARCHAR(16) NULL, " + ...
    "started_at DATETIME(3) NULL, finished_at DATETIME(3) NULL, delta JSON NOT NULL, " + ...
    "written_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3), " + ...
    "UNIQUE KEY uq_frames (param_hash, seed_base, lane, k_start), UNIQUE KEY uq_uid (batch_uid), KEY k_hash (param_hash))";

function q = ledger_insert(ledger_table, paramHash, new_frames, br, metrics_add, metrics_n_add, aux_delta)
% INSERT for one batch: who, which frames, which code, and the batch's own delta (notes S13).
delta = struct('frames', new_frames, 'metrics', metrics_add, 'metrics_n', metrics_n_add);
if ~isempty(aux_delta), delta.metrics_aux = aux_delta; end

% Column values; an absent field is NULL
v = @(f) field_sql(br, f);
q = sprintf(['INSERT INTO %s (param_hash, machine, lane, seed_base, k_start, n_frames, batch_uid, code_rev, ' ...
    'matlab_release, started_at, finished_at, delta) VALUES (''%s'', ''%s'', %s, %s, %s, %d, %s, %s, ''%s'', %s, %s, %s)'], ...
    ledger_table, paramHash, host_id(), v('lane'), v('seed_base'), v('k_start'), ...
    new_frames, v('batch_uid'), v('code_rev'), version('-release'), v('started_at'), v('finished_at'), sql_str(jsonencode(delta)));

function s = field_sql(br, f)
% One batch_record field as an SQL literal: number, quoted text, or NULL.
if ~isstruct(br) || ~isfield(br, f) || isempty(br.(f))
    s = "NULL";
elseif isnumeric(br.(f))
    s = sprintf('%.0f', br.(f));
elseif isdatetime(br.(f))
    s = sql_str(char(br.(f), 'yyyy-MM-dd HH:mm:ss.SSS'));
else
    s = sql_str(char(string(br.(f))));
end

function s = sql_str(txt)
% Quote text for MySQL: backslashes and single quotes escaped.
s = "'" + replace(replace(string(txt), "\", "\\"), "'", "''") + "'";

function r = ledger_by_uid(conn, ledger_table, uid)
% The ledger row holding this batch_uid, or empty; a uid archived by a deletion stays taken (storage step 7b).
r = fetch(conn, sprintf("SELECT param_hash, n_frames, lane, k_start FROM %s WHERE batch_uid = '%s'", ledger_table, uid));
if height(r) == 0
    try
        r = fetch(conn, sprintf("SELECT param_hash, n_frames, lane, k_start FROM %s_deleted WHERE batch_uid = '%s'", ledger_table, uid));
    catch ME
        if ~contains(ME.message, "doesn't exist"), rethrow(ME); end
        r = table();
    end
end
if height(r) == 0, r = []; end

function status = already_recorded(prev, paramHash, new_frames, br)
% A batch_uid already in the ledger must be this same batch; anything else is a collision (notes S14).
same = string(prev.param_hash(1)) == string(paramHash) && double(prev.n_frames(1)) == new_frames;
if isfield(br, 'lane') && ~isempty(br.lane), same = same && double(prev.lane(1)) == double(br.lane); end
if isfield(br, 'k_start') && ~isempty(br.k_start), same = same && double(prev.k_start(1)) == double(br.k_start); end
if ~same
    error('mysql_write:uidCollision', 'batch_uid %s is already in the ledger for a different batch; nothing was written.', br.batch_uid);
end
warning('mysql_write:batchAlreadyRecorded', 'Batch %s is already recorded (a retry after a lost reply); not added again.', br.batch_uid);
status = "already_recorded";

function end_txn(conn, ac_old)
% Roll back anything uncommitted, then restore AutoCommit; turning it on first would commit a half-done attempt.
try
    rollback(conn);
catch
end
try
    conn.AutoCommit = ac_old;
catch
end

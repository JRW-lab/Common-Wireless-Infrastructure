function [T, used] = store_read(src, hash_list, mode, seed_base)
% STORE_READ  One computer's results, from the first of its stores that can be read.
%
%   [T, used] = store_read(src, hash_list)                 another computer
%   [T, used] = store_read(src, hash_list, "own")          own file primary
%   [T, used] = store_read(src, hash_list, "own_fallback") own, primary failed
%   [n, used] = store_read(src, hash_list, mode, seed_base) ledgered frames
%   [L, used] = store_read(src, hash_list, mode, "records") live ledger records
%   [L, used] = store_read(src, hash_list, mode, "records_all") live + archived
%
%   Storage step 6a (notes/STORAGE_BACKENDS_PLAN.md). load_merged reads each
%   computer through this: its stores are tried in priority order, skipping
%   any its owner has marked stale (Results/<writer>/store_status.json,
%   synced), and the first that reads is used. One computer's stores are
%   never summed: they hold the same batches.
%     mysql:  one db_source_conn attempt (5 s connect, 30 s socket).
%     sqlite: another computer's store is read from its synced snapshot
%             <file>.snapshot, opened read-only and closed at once so
%             Syncthing can replace it; the own computer reads its live file.
%     text:   batches.jsonl, rebuilt by the text adapter (a partial last
%             line, e.g. mid-sync, is ignored). Nothing is ever created in
%             another computer's folder.
%   A store that fails to open or read is skipped, never an error.
%
%   A stale flag reaches other computers with Syncthing's lag, so a reader
%   may still use a mirror its owner has just flagged. Mirrors are written
%   in transactions, so a stale mirror is behind, never wrong: the worst
%   case is an undercount and over-collection, as for an offline computer
%   (D4).
%
%   INPUTS:
%     src           one db_sources element (fields writer, stores)
%     hash_list     param_hash list, or "*"
%     mode          "remote" (default): another computer, files read from
%                   their synced copies. "own": this computer's primary
%                   only, live; a failure is an error, never a mirror
%                   (storage step 6b). "own_fallback" (or true): this
%                   computer's primary could not be read, so its mirrors
%                   are tried live, primary skipped.
%     seed_base     when given, T is instead the number of frames in the
%                   ledger under seed_base for hash_list (ledger_frames).
%                   "records" instead: T is one row per LIVE batch (archived
%                   ones excluded), columns param_hash, lane, seed_base,
%                   k_start, n_frames (NaN when absent), batch_uid, code_rev,
%                   delta (JSON text), archived (false). A text store whose
%                   live batches lack deltas (a resync-built mirror) is
%                   unusable for records, so the next store is tried.
%                   "records_all": archived batches too (archived true;
%                   delta "" for them). Phase 3 step 4: paired_compare,
%                   ledger_check.
%
%   OUTPUTS:
%     T     rows shaped like a MySQL sim_lookup read (text columns as cells)
%     used  struct: key, kind, fallback (not the primary), file_time
%           (snapshot or log modification time, "" for MySQL),
%           status_time (the owner's store_status.json time, "" if none)
%
%   A computer whose stores are all files that don't exist yet (registered,
%   never written) reads as no rows with used.kind "empty", not as
%   unreachable; so does an own file primary that was never created. A file
%   that exists but can't be read stays unreachable.
%
%   LIMITS: errors storage:noUsableStore when no store could be read; the
%   caller treats that machine as unreachable.

% The read mode, and rows or ledger frames
if nargin < 3 || isempty(mode), mode = "remote"; end
if islogical(mode) || isnumeric(mode)
    if mode, mode = "own_fallback"; else, mode = "remote"; end
end
mode = string(mode);
if nargin < 4, seed_base = []; end
own = mode ~= "remote";

% The computer's stores and its owner's status file
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
stores = src.stores;
S = [];
status_time = "";
try
    S = store_status(src.writer);
    info = dir(fullfile(root, 'Results', char(src.writer), 'store_status.json'));
    if ~isempty(info), status_time = string(datetime(info.datenum, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd HH:mm')); end
catch
end

% Try each store in priority order (own: the primary alone; own_fallback: the mirrors)
first = 1 + (mode == "own_fallback");
last = numel(stores);
if mode == "own", last = 1; end
why = strings(0, 1);
absent = 0;
for j = first:last
    s = stores(j);
    key = store_key(s);
    if s.kind == "excel", continue; end   % an export, never read (step 7a)
    if ~isempty(S)
        i = find(strcmp({S.key}, key), 1);
        if ~isempty(i) && S(i).stale, why(end+1) = key + ": stale"; continue; end %#ok<AGROW>
    end
    try
        [T, file_time] = read_one(s, hash_list, own, root, seed_base);
        used = struct('key', string(key), 'kind', s.kind, 'fallback', j > 1, 'file_time', file_time, 'status_time', status_time);
        return
    catch ME
        why(end+1) = key + ": " + string(ME.message); %#ok<AGROW>
        absent = absent + any(string(ME.identifier) == ["storage:noSnapshot" "storage:noLog"]);
    end
end

% A computer that has not written yet: every store is a file store whose file does not exist (none stale, none broken)
% (the own primary too, when it was never created: only a read-only caller meets that, since a collector opens it first)
never_written = mode == "remote" && absent == nnz([stores.kind] ~= "excel") && all([stores.kind] ~= "mysql");
never_written = never_written || (mode == "own" && absent == 1 && stores(1).kind ~= "mysql");
if never_written
    if isstring(seed_base) || ischar(seed_base)
        T = records_table(strings(0, 1), [], [], [], [], strings(0, 1), strings(0, 1), strings(0, 1), false(0, 1));
    elseif isempty(seed_base)
        T = cell2table(cell(0, 6), 'VariableNames', {'param_hash', 'parameters', 'metrics', 'frames_simulated', 'metrics_aux', 'metrics_n'});
    else
        T = 0;
    end
    used = struct('key', "", 'kind', "empty", 'fallback', false, 'file_time', "", 'status_time', status_time);
    return
end
if mode == "own"
    error('storage:ownPrimaryUnreadable', 'This computer''s primary store could not be read (%s); stopping rather than undercount.', strjoin(why, '; '));
end
error('storage:noUsableStore', 'No store of %s could be read (%s).', src.writer, strjoin(why, '; '));
end

function [T, file_time] = read_one(s, hash_list, own, root, seed_base)
% Read one store's rows for hash_list, shaped like a MySQL read; or, given seed_base, its ledgered frames; or its live records.
file_time = "";
records = isstring(seed_base) || ischar(seed_base);
with_archive = records && string(seed_base) == "records_all";
ledger = ~isempty(seed_base) && ~records;
switch s.kind
    case "mysql"
        c = db_source_conn(struct('host', s.host, 'dbname', s.dbname));
        if records
            T = sql_records(c, ledger_name(s.table), hash_list, false, with_archive);
        elseif ledger
            T = ledger_sum(c, ledger_name(s.table), hash_list, seed_base);
        else
            T = fetch(c, "SELECT * FROM " + s.table + where_hash(hash_list));
        end
        return
    case "sqlite"
        f = fullfile(root, char(s.path));
        if ~own, f = [f '.snapshot']; end
        if ~isfile(f), error('storage:noSnapshot', '%s does not exist.', f); end
        file_time = mtime(f);
        c = sqlite(f, 'readonly');
        try
            if records
                T = sql_records(c, "sim_batches", hash_list, true, with_archive);
            elseif ledger
                T = ledger_sum(c, "sim_batches", hash_list, seed_base);
            else
                R = fetch(c, "SELECT param_hash, parameters, metrics, COALESCE(metrics_n, '') AS metrics_n, " + ...
                    "COALESCE(metrics_aux, '') AS metrics_aux, frames_simulated FROM sim_lookup" + where_hash(hash_list));
            end
        catch ME
            close(c); rethrow(ME);
        end
        close(c);
        if ledger || records, return; end
    case "text"
        d = fullfile(root, char(s.path));
        c = struct('dir', d, 'log', fullfile(d, 'batches.jsonl'), 'rows', fullfile(d, 'rows.json'), 'lock', fullfile(d, 'write.lock'));
        if ~isfile(c.log), error('storage:noLog', '%s does not exist.', c.log); end
        file_time = mtime(c.log);
        ad = store_adapter("text");
        if records
            T = text_records(c.log, hash_list, with_archive);
            return
        end
        if ledger
            % Read only: the snapshot plus the log lines after it (nothing is written)
            T = 0;
            for h = reshape(hash_list_of(hash_list), 1, [])
                T = T + ad.ledger_frames_local(c, h, seed_base);
            end
            return
        end
        R = ad.load_rows(c);
        if ~is_all(hash_list)
            R = R(ismember(string(R.param_hash), string(hash_list)), :);
        end
    otherwise
        error('storage:kindNotBuilt', 'Reading store kind "%s" is not built.', s.kind);
end

% File stores: the same column types as a MySQL read (text columns as cells)
T = table(cellstr(string(R.param_hash)), cellstr(string(R.parameters)), cellstr(string(R.metrics)), ...
    double(R.frames_simulated), cellstr(string(R.metrics_aux)), cellstr(string(R.metrics_n)), ...
    'VariableNames', {'param_hash', 'parameters', 'metrics', 'frames_simulated', 'metrics_aux', 'metrics_n'});
end

function L = sql_records(c, ledger, hash_list, is_sqlite, with_archive)
% Ledger records of a MySQL or SQLite store, live and optionally archived (MATLAB sqlite can't fetch NULLs: COALESCE, then -1 -> NaN).
L = one_table(c, ledger, hash_list, is_sqlite, false);
if with_archive
    L = [L; one_table(c, ledger + "_deleted", hash_list, is_sqlite, true)];
end
end

function L = one_table(c, t, hash_list, is_sqlite, archived)
% The records of one ledger table; one that doesn't exist holds none.
d = "delta"; if archived, d = "''"; end
try
    if is_sqlite
        R = fetch(c, "SELECT param_hash, COALESCE(lane,-1) AS lane, COALESCE(seed_base,-1) AS seed_base, COALESCE(k_start,-1) AS k_start, " + ...
            "n_frames, batch_uid, COALESCE(code_rev,'') AS code_rev, " + d + " AS delta FROM " + t + where_hash(hash_list));
    else
        R = fetch(c, "SELECT param_hash, lane, seed_base, k_start, n_frames, batch_uid, code_rev, " + d + " AS delta FROM " + t + where_hash(hash_list));
    end
catch ME
    if ~contains(ME.message, ["doesn't exist" "no such table"]), rethrow(ME); end
    L = records_table(strings(0, 1), [], [], [], [], strings(0, 1), strings(0, 1), strings(0, 1), false(0, 1));
    return
end
L = records_table(txt_col(R.param_hash), neg(R.lane), neg(R.seed_base), neg(R.k_start), double(R.n_frames), ...
    txt_col(R.batch_uid), txt_col(R.code_rev), txt_col(R.delta), repmat(archived, height(R), 1));
end

function L = text_records(logf, hash_list, with_archive)
% Live ledger records of a text store, from its log: batch lines carry their delta; delete_row kills earlier batches of its point.
txt = fileread(logf);
last = find(txt == newline, 1, 'last');
lines = strings(0, 1);
if ~isempty(last), lines = splitlines(string(txt(1:last-1))); end
n = numel(lines);
[h, uid, cr, dl] = deal(strings(n, 1)); [ln, sb, ks, nf] = deal(nan(n, 1)); live = false(n, 1); dead = false(n, 1);
for i = 1:n
    if strlength(lines(i)) == 0, continue; end
    b = jsondecode(lines(i));
    t = string(b.type);
    if t == "delete_row"
        kill = live & h == string(b.param_hash);
        dead(kill) = true; live(kill) = false;
        continue
    end
    if t ~= "batch" && t ~= "ledger_import", continue; end
    h(i) = string(b.param_hash); uid(i) = string(b.batch_uid); nf(i) = double(b.frames); live(i) = true;
    if isfield(b, 'lane'), ln(i) = double(b.lane); end
    if isfield(b, 'seed_base'), sb(i) = double(b.seed_base); end
    if isfield(b, 'k_start'), ks(i) = double(b.k_start); end
    if isfield(b, 'code_rev'), cr(i) = string(b.code_rev); end
    if t == "batch"
        d = struct('frames', b.frames, 'metrics', b.metrics, 'metrics_n', b.metrics_n);
        if isfield(b, 'metrics_aux'), d.metrics_aux = b.metrics_aux; end
        dl(i) = string(jsonencode(d));
    end
end
if ~is_all(hash_list)
    keep = ismember(h, string(hash_list)); live = live & keep; dead = dead & keep;
end

% A resync-built text mirror indexes batches without their deltas: unusable for records, so the reader moves on (laptop review)
nodelta = nnz(live & dl == "");
if nodelta > 0
    error('storage:recordsNoDelta', '%s holds %d live batch(es) without deltas (a resync-built mirror); not usable for records.', logf, nodelta);
end
L = records_table(h(live), ln(live), sb(live), ks(live), nf(live), uid(live), cr(live), dl(live), false(nnz(live), 1));
if with_archive
    dl(dead) = "";
    L = [L; records_table(h(dead), ln(dead), sb(dead), ks(dead), nf(dead), uid(dead), cr(dead), dl(dead), true(nnz(dead), 1))];
end
end

function L = records_table(h, ln, sb, ks, nf, uid, cr, dl, ar)
% The records table every store returns.
L = table(string(h(:)), double(ln(:)), double(sb(:)), double(ks(:)), double(nf(:)), string(uid(:)), string(cr(:)), string(dl(:)), logical(ar(:)), ...
    'VariableNames', {'param_hash', 'lane', 'seed_base', 'k_start', 'n_frames', 'batch_uid', 'code_rev', 'delta', 'archived'});
end

function s = txt_col(v)
% A fetched text column as strings ("" for missing).
if iscell(v), v = string(v); end
s = string(v); s(ismissing(s)) = "";
end

function n = ledger_sum(c, ledger, hash_list, seed_base)
% Ledgered frames under seed_base for hash_list; a ledger that does not exist yet holds none.
try
    r = fetch(c, "SELECT COALESCE(SUM(n_frames),0) AS n FROM " + ledger + where_hash(hash_list) + ...
        sprintf(" AND seed_base = %d", seed_base));
    n = double(r{1,1});
catch ME
    if ~contains(ME.message, ["doesn't exist" "no such table"]), rethrow(ME); end
    n = 0;
end
end

function t = ledger_name(table_name)
% Ledger paired with a results table (the mysql_write rule).
if string(table_name) == "sim_lookup", t = "sim_batches"; else, t = string(table_name) + "_batches"; end
end

function tf = is_all(hash_list)
% True for "*".
tf = (isstring(hash_list) || ischar(hash_list)) && isscalar(string(hash_list)) && string(hash_list) == "*";
end

function hs = hash_list_of(hash_list)
% A ledger read needs named hashes.
assert(~is_all(hash_list), 'storage:ledgerAll', 'A ledger read needs named param_hashes, not "*".');
hs = unique(string(hash_list));
end

function w = where_hash(hash_list)
% SQL WHERE clause for a hash list, " WHERE 1=1" for "*".
if is_all(hash_list)
    w = " WHERE 1=1";
    return
end
hs = string(hash_list); hs = unique(hs(strlength(hs) > 0));
if isempty(hs), w = " WHERE 1=0"; else, w = " WHERE param_hash IN (" + strjoin("'" + hs + "'", ',') + ")"; end
end

function t = mtime(f)
% A file's modification time as text.
info = dir(f);
t = string(datetime(info.datenum, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd HH:mm:ss'));
end

function v = neg(v)
% A -1 placeholder (MATLAB sqlite can't fetch NULLs) back to NaN; MySQL NULLs already arrive as NaN.
v = double(v); v(v < 0) = NaN;
end

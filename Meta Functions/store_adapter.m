function ad = store_adapter(kind)
% STORE_ADAPTER  The operations of one kind of result store, behind one interface.
%
%   ad = store_adapter(kind)
%
%   PURPOSE. Returns the operations of one kind of result store as a struct
%   of function handles. Collectors, readers and the GUI reach every store
%   through the same handles, so a new store kind only has to supply them
%   (storage step 2 of notes/STORAGE_BACKENDS_PLAN.md; notes S1). Every
%   kind merges a batch into its row with apply_batch, records a batch
%   with a given batch_uid only once, and refuses a repeated Phase 3 frame
%   range, raising the same mysql_write:* identifiers.
%
%   INPUT
%     kind  "mysql", "sqlite" or "text".
%
%   OUTPUT: struct of function handles
%     Every kind:
%     write(conn, table, params, nf, metrics_add, opts) -> status
%         one batch; status "committed" or "already_recorded".
%         opts: use_mutex, metrics_aux_cumulative, metrics_aux_delta,
%         metrics_n_add, batch (batch_record with batch_uid), lock_timeout
%         (SQLite and text; a mirror passes a short cap). MySQL: mysql_write.
%     next_k_start(conn, table, hash, seed_base, lane, B)
%         this lane's largest committed k_start for the point + B, or
%         lane*2^32 + 1 (Phase 3 R1); a deleted point's ranges count too.
%     ledger_frames(conn, dbname, table, hash, seed_base)
%         ledgered frames of the point over every reachable source (D4;
%         notes S9).
%     lock_lane(tgt, table, lane) -> lock handle; lane_check(lock, lane)
%         before each batch; unlock_lane(lock, lane) at a normal end.
%     ledger_name(table)  the ledger table paired with a results table.
%     open(store) -> connection for a store struct (machine_stores element).
%     ledger_summary(conn, table) -> [batches, frames] of the live ledger.
%     delete_point(conn, table, hash)  removes the row and retires the
%         point's ledger records in one transaction (notes S10).
%     SQLite and text:
%     load_rows(conn) -> the rows as a sim_lookup-shaped table.
%     uids(conn) -> the live batch_uids (store_check).
%     import(conn, rows, ledger)  replaces the contents with a primary's
%         rows and ledger (store_resync; notes S7).
%     SQLite only:
%     flush(conn)  forces the snapshot refresh (notes S4).
%     Text only:
%     seed_rows(conn, T)  adds seed_row lines for rows that predate the
%         ledger; ledger_frames_local(conn, hash, seed_base) reads this
%         store's own ledger; ledger_rows(conn) -> the live ledger as a table.
%
%   STORE KINDS
%     MySQL: the results table and its ledger (<table>_batches, or
%       sim_batches for sim_lookup); writes go through mysql_write; lane
%       locks are MySQL named locks (notes S2).
%     SQLite (storage step 3): sim_lookup and sim_batches in one file,
%       Results/<writer>/<file>.sqlite. Every write is one BEGIN IMMEDIATE
%       transaction, so writers on one file serialise (notes S3). Other
%       computers read only <file>.snapshot, refreshed after commits
%       (notes S4).
%     Text (storage step 4): a folder holding batches.jsonl (append-only,
%       the truth), rows.json (a snapshot rebuilt from it) and a lock file.
%       A batch is committed when its line's newline is written (notes S5,
%       S6).
%     SQLite and text stores serve as mirrors (notes S7), or as the primary
%     of a computer without MySQL, whose lane locks are then files outside
%     the synced tree (notes S8).
%
%   LIMITS. Kinds other than "mysql", "sqlite" and "text" error
%   (storage:kindNotBuilt). A SQLite or text store holds only sim_lookup.
%   A deleted point's batch_uids and frame ranges stay reserved (notes S10).
%
%   REFERENCES
%     notes/STORAGE_BACKENDS_PLAN.md, section 14 (storage steps 2-7b).
%     notes/mysql_write_NOTES.md S13-S15 (ledger, batch_uid, apply_batch).
%   Reasons and history are in notes/store_adapter_NOTES.md; comments below
%   cite it as (notes Sn).

%% ===== 1. DISPATCH ===================================================
% Builds the handle struct for the requested kind; the local functions
% below implement each operation.

% The adapter for this kind
switch string(kind)
    case "mysql"
        % MySQL: mysql_write, MySQL named lane locks, ledger tables in the database
        ad = struct('write', @mysql_store_write, 'next_k_start', @next_k_start, 'ledger_frames', @ledger_frames, ...
            'lock_lane', @lock_lane, 'lane_check', @lane_check, 'unlock_lane', @unlock_lane, 'ledger_name', @ledger_name, ...
            'open', @(st) mysql_login(st.dbname), 'ledger_summary', @mysql_ledger_summary, 'delete_point', @mysql_delete_point);
    case "sqlite"
        % SQLite: one file per store, file lane locks, mirror operations and a snapshot flush
        ad = struct('write', @sqlite_store_write, 'next_k_start', @sqlite_next_k_start, 'ledger_frames', @ledger_frames, ...
            'lock_lane', @file_lock_lane, 'lane_check', @file_lane_check, 'unlock_lane', @file_unlock_lane, 'ledger_name', @ledger_name, ...
            'open', @sqlite_open, 'load_rows', @sqlite_rows, 'uids', @sqlite_uids, 'import', @sqlite_import, 'ledger_summary', @sqlite_ledger_summary, ...
            'flush', @(c) sqlite_snapshot(c, true), 'delete_point', @sqlite_delete_point);
    case "text"
        % Text: one folder per store, file lane locks, mirror operations and seed rows
        ad = struct('write', @text_store_write, 'next_k_start', @text_next_k_start, 'ledger_frames', @ledger_frames, ...
            'lock_lane', @file_lock_lane, 'lane_check', @file_lane_check, 'unlock_lane', @file_unlock_lane, 'ledger_name', @ledger_name, ...
            'open', @text_open, 'load_rows', @text_rows, 'seed_rows', @text_seed_rows, 'uids', @text_uids, 'import', @text_import, 'ledger_summary', @text_ledger_summary, ...
            'ledger_frames_local', @(c, h, sb) text_ledger_frames(c, [], [], h, sb), 'ledger_rows', @text_ledger_rows, 'delete_point', @text_delete_point);
    otherwise
        error('storage:kindNotBuilt', 'Store kind "%s" has no adapter yet.', kind);
end
end

%% ===== 2. MYSQL STORE AND SHARED LEDGER READS ========================
% The MySQL write, next k range, point deletion and named lane locks
% (notes S2). Also the option helpers every kind uses (cap_of, get_opt,
% ledger_name) and ledger_frames, the one cross-source frame count for
% every kind (notes S9).

function status = mysql_store_write(conn, table_name, parameters, nf, metrics_add, opts)
% One batch into a MySQL store: mysql_write with the options in order.
f = @(n) get_opt(opts, n);
use_mutex = isequal(f('use_mutex'), true);
status = mysql_write(conn, table_name, parameters, nf, metrics_add, use_mutex, ...
    f('metrics_aux_cumulative'), f('metrics_aux_delta'), f('metrics_n_add'), f('batch'));
end

function c = cap_of(opts)
% Lock wait cap in seconds: opts.lock_timeout when given (mirrors use a short one), else 120.
c = 120;
if isfield(opts, 'lock_timeout') && ~isempty(opts.lock_timeout), c = opts.lock_timeout; end
end

function v = get_opt(opts, name)
% An option's value, or [] when absent.
if isfield(opts, name), v = opts.(name); else, v = []; end
end

function t = ledger_name(table_name)
% Ledger paired with a results table: the same rule as mysql_write (mysql_write notes S13).
if string(table_name) == "sim_lookup", t = "sim_batches"; else, t = string(table_name) + "_batches"; end
end

function k = next_k_start(conn, table_name, h, seed_base, lane, B)
% This lane's next k range for point h: its largest committed k_start + B, or lane*2^32 + 1 (R1).

% Largest k_start in the live ledger; only a missing ledger means "no batches" (notes S2)
m = [];
try
    r = fetch(conn, sprintf("SELECT MAX(k_start) AS m FROM %s WHERE param_hash = '%s' AND seed_base = %d AND lane = %d", ...
        ledger_name(table_name), h, seed_base, lane));
    m = r{1,1};
    if iscell(m), m = m{1}; end
catch ME
    if ~contains(ME.message, "doesn't exist"), rethrow(ME); end
end

% A deleted point's archived ranges are never reused (notes S10)
try
    r = fetch(conn, sprintf("SELECT MAX(k_start) AS m FROM %s_deleted WHERE param_hash = '%s' AND seed_base = %d AND lane = %d", ...
        ledger_name(table_name), h, seed_base, lane));
    a = r{1,1};
    if iscell(a), a = a{1}; end
    if ~isempty(a) && ~(isnumeric(a) && isnan(a)), m = max([double(m) double(a)]); end
catch ME
    if ~contains(ME.message, "doesn't exist"), rethrow(ME); end
end

% Continue past the largest k_start, or start the lane's range
if isempty(m) || (isnumeric(m) && isnan(m))
    k = lane * 2^32 + 1;
else
    k = double(m) + B;
end
end

function mysql_delete_point(conn, table_name, h)
% Delete point h from a MySQL store: its ledger records to <ledger>_deleted and the row, in one transaction.
L = ledger_name(table_name); A = L + "_deleted";

% The archive (made outside the transaction: DDL commits); a store without a ledger only loses the row
has_ledger = true;
try
    execute(conn, "CREATE TABLE IF NOT EXISTS " + A + " AS SELECT * FROM " + L + " WHERE 1=0");
    % Add the deleted_at column unless an earlier delete already did
    try
        execute(conn, "ALTER TABLE " + A + " ADD COLUMN deleted_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP");
    catch ME
        if ~contains(ME.message, "Duplicate column"), rethrow(ME); end
    end
catch ME
    if ~contains(ME.message, "doesn't exist"), rethrow(ME); end
    has_ledger = false;
end

% Archive, unledger and delete together, with AutoCommit off for the transaction
ac = conn.AutoCommit;
conn.AutoCommit = 'off';
try
    % Archive and remove the ledger records, then delete the row
    if has_ledger
        execute(conn, sprintf("INSERT INTO %s SELECT *, CURRENT_TIMESTAMP FROM %s WHERE param_hash = '%s'", A, L, h));
        execute(conn, sprintf("DELETE FROM %s WHERE param_hash = '%s'", L, h));
    end
    execute(conn, sprintf("DELETE FROM %s WHERE param_hash = '%s'", table_name, h));
    commit(conn);
catch ME
    % Undo everything and restore AutoCommit before rethrowing
    rollback(conn);
    conn.AutoCommit = ac;
    rethrow(ME);
end
conn.AutoCommit = ac;
end

function n = ledger_frames(conn, dbname, table_name, h, seed_base)
% Ledgered frames of point h under seed_base, summed live over every reachable source (unreachable ones are skipped, D4).
src = db_sources(dbname, table_name);
n = 0;
for i = 1:numel(src)
    % This computer's own file primary must be readable: stop rather than undercount (notes S9)
    if src(i).own && src(i).kind ~= "mysql"
        n = n + own_file_ledger(conn, src(i).kind, h, seed_base);
        continue
    end

    % Own MySQL through its connection; another computer through its first usable store; legacy directly
    try
        if src(i).own
            n = n + mysql_ledger_sum(conn, src(i).table, h, seed_base);
        elseif src(i).role == "machine" && ~isempty(src(i).stores)
            n = n + store_read(src(i), h, "remote", seed_base);
        else
            n = n + mysql_ledger_sum(db_source_conn(src(i)), src(i).table, h, seed_base);
        end
    catch
    end
end
end

function n = mysql_ledger_sum(c, table_name, h, seed_base)
% Ledgered frames of one point in one MySQL table's ledger.
r = fetch(c, sprintf("SELECT COALESCE(SUM(n_frames),0) AS n FROM %s WHERE param_hash = '%s' AND seed_base = %d", ...
    ledger_name(table_name), h, seed_base));
n = double(r{1,1});
end

function n = own_file_ledger(c, kind, h, seed_base)
% Ledgered frames of one point in this computer's own SQLite or text primary.
if kind == "sqlite"
    n = sqlite_ledger_frames(c, [], [], h, seed_base);
else
    n = text_ledger_frames(c, [], [], h, seed_base);
end
end

function c = lock_lane(tgt, table_name, lane)
% Hold the MySQL named lock for this machine and lane on a connection of its own; a second collector refuses (notes S2).
src = db_sources(tgt.dbname, table_name);
c = db_source_conn(src(1));
got = fetch(c, sprintf("SELECT GET_LOCK('%s', 0) AS g", lock_name(lane))).g;
if got ~= 1
    error('collect_profile:laneInUse', 'Lane %d is already in use on %s (named lock %s held).', lane, char(host_id()), lock_name(lane));
end
end

function lane_check(c, lane)
% Before each batch, confirm the lane lock is still this connection's; re-take it once if the connection was lost.

% Is the named lock still held by this connection?
ok = false;
try
    ok = fetch(c, sprintf("SELECT IS_USED_LOCK('%s') = CONNECTION_ID() AS ok", lock_name(lane))).ok == 1;
catch
end

% If not, take it back once, or stop
if ~ok
    got = 0;
    try
        got = fetch(c, sprintf("SELECT GET_LOCK('%s', 0) AS g", lock_name(lane))).g;
    catch
    end
    if got ~= 1
        error('collect_profile:laneLost', 'Lost the lock on lane %d and could not take it back; stopping.', lane);
    end
end
end

function unlock_lane(c, lane)
% Release the lane lock at a normal end.
fetch(c, sprintf("SELECT RELEASE_LOCK('%s') AS r", lock_name(lane)));
end

function n = lock_name(lane)
% Named-lock key for one machine's lane.
n = sprintf('cws_lane_%s_%d', char(host_id()), lane);
end

%% ===== 3. FILE LANE LOCKS ============================================
% Phase 3 lane locks for a computer whose primary is a SQLite or text
% store: one lock file per lane outside the synced tree, holding
% pid|time|token, refreshed before each batch and broken only when its
% process is gone or is this process (notes S8).

function c = file_lock_lane(~, ~, lane)
% Take this computer's lane as a lock file outside the synced tree; a second collector refuses (notes S8).

% Thread-pool workers share the client's pid and have no Java or system(), so "one collector per process" holds only off them
try
    java.lang.System.currentTimeMillis();
catch
    error('collect_profile:threadWorker', 'A collector can not run on a thread-pool worker (no Java, shared pid); use process workers.');
end

% The lock file's path and this collector's token
d = local_state_dir('locks', host_id());
c = struct('file', fullfile(d, sprintf('lane_%d.lock', lane)), 'uid', char(new_batch_uid()));
attr = javaArray('java.nio.file.attribute.FileAttribute', 0);

% Create the lock atomically and write its content; at most two attempts
for attempt = 1:2
    try
        java.nio.file.Files.createFile(java.nio.file.Paths.get(c.file, javaArray('java.lang.String', 0)), attr);
        lane_lock_write(c);
        return
    catch ME
        if ~contains(ME.message, 'FileAlreadyExists'), rethrow(ME); end
    end

    % Held: break it only when its process is gone, then try once more
    if attempt == 1, lane_lock_break_dead(c.file); end
end

% Still held by a running process: refuse
error('collect_profile:laneInUse', 'Lane %d is already in use on %s (lock file %s held by a running process).', ...
    lane, char(host_id()), c.file);
end

function file_lane_check(c, lane)
% Before each batch: the lock file must still hold this collector's token; then refresh its time (heartbeat).

% Does the lock file still hold this collector's token?
ok = false;
try
    p = split(string(fileread(c.file)), "|");
    ok = numel(p) == 3 && p(3) == string(c.uid);
catch
end

% If not, stop; if so, rewrite its time
if ~ok
    error('collect_profile:laneLost', 'Lost the lock on lane %d (%s); stopping.', lane, c.file);
end
lane_lock_write(c);
end

function file_unlock_lane(c, ~)
% Release the lane at a normal end: delete the lock only if it is still this collector's.
try
    p = split(string(fileread(c.file)), "|");
    if numel(p) == 3 && p(3) == string(c.uid), delete(c.file); end
catch
end
end

function lane_lock_write(c)
% The lock's content: pid|time|token.
fid = fopen(c.file, 'w');
fwrite(fid, sprintf('%d|%.0f|%s', feature('getpid'), posixtime(datetime('now')), c.uid), 'char');
fclose(fid);
end

function lane_lock_break_dead(file)
% Break a lane lock whose process is gone, or left by a stopped run in this same process (notes S8).
try
    % Keep the lock when it names another process that is still alive
    old = fileread(file);
    p = sscanf(old, '%d|');
    if isempty(p), return; end
    if p(1) ~= feature('getpid') && pid_alive(p(1)), return; end

    % Take it aside by an atomic rename (as text_break_stale, notes S6)
    side = sprintf('%s.dead.%d', file, feature('getpid'));
    mv = javaArray('java.nio.file.CopyOption', 1); mv(1) = java.nio.file.StandardCopyOption.ATOMIC_MOVE;
    none = javaArray('java.lang.String', 0);
    java.nio.file.Files.move(java.nio.file.Paths.get(file, none), java.nio.file.Paths.get(side, none), mv);

    % Delete it only if unchanged; otherwise put it back
    if strcmp(fileread(side), old)
        delete(side);
        warning('collect_profile:laneLockBroken', 'Broke lane lock %s left by process %d (gone, or this process after a stopped run).', file, p(1));
    else
        java.nio.file.Files.move(java.nio.file.Paths.get(side, none), java.nio.file.Paths.get(file, none), mv);
    end
catch
end
end

%% ===== 4. SQLITE STORE ===============================================
% A SQLite store: open, write one batch in one BEGIN IMMEDIATE
% transaction, next k range, point deletion and the own ledger count,
% with the SQL quoting helpers q and sqlite_val (notes S3).

function c = sqlite_open(st)
% Open (creating if needed) the SQLite store of a machine_stores element, with both tables.

% The file under the project root, created with its folder if needed
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
f = fullfile(root, char(st.path));
if ~isfolder(fileparts(f)), mkdir(fileparts(f)); end
if isfile(f), c = sqlite(f); else, c = sqlite(f, 'create'); end

% A short busy wait; transactions are opened explicitly with BEGIN IMMEDIATE (notes S3)
execute(c, "PRAGMA busy_timeout = 2000");
c.AutoCommit = 'off';

% The results table, the ledger, and the archive of deleted points' ledger records
execute(c, "CREATE TABLE IF NOT EXISTS sim_lookup (param_hash TEXT PRIMARY KEY, parameters TEXT, metrics TEXT, " + ...
    "metrics_n TEXT, metrics_aux TEXT, frames_simulated INTEGER NOT NULL, write_seq INTEGER NOT NULL DEFAULT 0, updated_at TEXT)");
execute(c, "CREATE TABLE IF NOT EXISTS sim_batches (batch_id INTEGER PRIMARY KEY AUTOINCREMENT, param_hash TEXT NOT NULL, " + ...
    "machine TEXT NOT NULL, lane INTEGER, seed_base INTEGER, k_start INTEGER, n_frames INTEGER NOT NULL, " + ...
    "batch_uid TEXT NOT NULL UNIQUE, code_rev TEXT, matlab_release TEXT, started_at TEXT, finished_at TEXT, delta TEXT NOT NULL, " + ...
    "written_at TEXT DEFAULT CURRENT_TIMESTAMP, UNIQUE (param_hash, seed_base, lane, k_start))");
execute(c, "CREATE TABLE IF NOT EXISTS sim_batches_deleted (batch_id INTEGER, param_hash TEXT, machine TEXT, lane INTEGER, " + ...
    "seed_base INTEGER, k_start INTEGER, n_frames INTEGER, batch_uid TEXT, code_rev TEXT, matlab_release TEXT, started_at TEXT, " + ...
    "finished_at TEXT, delta TEXT, written_at TEXT, deleted_at TEXT)");
end

function status = sqlite_store_write(c, table_name, parameters, nf, metrics_add, opts)
% One batch into a SQLite store: one BEGIN IMMEDIATE transaction holding the row merge (apply_batch) and the ledger row.

% Check the table and the batch_uid, read the options, hash the parameters
assert(any(string(table_name) == ["sim_lookup" ""]), 'storage:sqliteTable', 'A SQLite store holds only sim_lookup.');
f = @(n) get_opt(opts, n);
br = f('batch'); aux_cum = f('metrics_aux_cumulative'); aux_delta = f('metrics_aux_delta');
if isempty(br) || ~isfield(br, 'batch_uid') || strlength(string(br.batch_uid)) ~= 64
    error('mysql_write:noBatchUid', 'A SQLite write needs a batch_record with a 64-character batch_uid.');
end
[paramsJSON, h] = jsonencode_sorted(parameters);

% Every reported metric gets a sample count; a missing one counts the batch's frames (mysql_write notes S1)
mn_add = f('metrics_n_add'); if isempty(mn_add), mn_add = struct(); end
fa = fieldnames(metrics_add);
for i = 1:numel(fa)
    if ~isfield(mn_add, fa{i}), mn_add.(fa{i}) = nf; end
end

% Take the write lock, retrying a busy file with a short random backoff (a mirror passes a short cap, opts.lock_timeout)
sqlite_begin(c, cap_of(opts));
try
    % The same batch_uid already in the ledger: the batch was committed before (mysql_write notes S14)
    prev = fetch(c, "SELECT param_hash, n_frames, COALESCE(lane,-1) AS lane, COALESCE(k_start,-1) AS k_start FROM sim_batches WHERE batch_uid = " + q(br.batch_uid) + ...
        " UNION ALL SELECT param_hash, n_frames, COALESCE(lane,-1), COALESCE(k_start,-1) FROM sim_batches_deleted WHERE batch_uid = " + q(br.batch_uid));
    if height(prev) > 0
        rollback(c);
        status = sqlite_already_recorded(prev, h, nf, br);
        return
    end

    % Merge the batch into the row as stored with apply_batch; nullable columns are read through COALESCE (notes S3)
    row = fetch(c, "SELECT param_hash, parameters, metrics, COALESCE(metrics_n, '') AS metrics_n, COALESCE(metrics_aux, '') AS metrics_aux, " + ...
        "frames_simulated, write_seq FROM sim_lookup WHERE param_hash = " + q(h));
    if height(row) == 0
        N_total = nf;
        [m, mn, aux] = apply_batch([], N_total, metrics_add, mn_add, aux_delta);
    else
        % An existing row: decode it and merge
        N_total = double(row.frames_simulated(1)) + nf;
        old = struct('metrics', jsondecode(char(row.metrics(1))), 'n', metric_sample_count(row), 'aux', []);
        if ~isempty(aux_delta) && strlength(row.metrics_aux(1)) > 0
            old.aux = jsondecode(char(row.metrics_aux(1)));
        end
        [m, mn, aux] = apply_batch(old, N_total, metrics_add, mn_add, aux_delta);
    end

    % The aux to store: the merged delta, else the cumulative form, as SQL
    if isempty(aux_delta) && ~isempty(aux_cum), aux = aux_cum; end
    auxSQL = "NULL";
    if ~isempty(aux), auxSQL = q(jsonencode(aux)); end

    % Insert or update the row
    if height(row) == 0
        execute(c, sprintf("INSERT INTO sim_lookup (param_hash, parameters, metrics, metrics_n, metrics_aux, frames_simulated, write_seq, updated_at) " + ...
            "VALUES (%s, %s, %s, %s, %s, %d, 0, CURRENT_TIMESTAMP)", q(h), q(paramsJSON), q(jsonencode(m)), q(jsonencode(mn)), auxSQL, N_total));
    else
        if isempty(aux), auxSQL = "metrics_aux"; end
        execute(c, sprintf("UPDATE sim_lookup SET metrics = %s, metrics_n = %s, metrics_aux = %s, frames_simulated = %d, " + ...
            "write_seq = write_seq + 1, updated_at = CURRENT_TIMESTAMP WHERE param_hash = %s", q(jsonencode(m)), q(jsonencode(mn)), auxSQL, N_total, q(h)));
    end

    % The ledger row's delta, and a reader for the batch_record's fields
    delta = struct('frames', nf, 'metrics', metrics_add, 'metrics_n', mn_add);
    if ~isempty(aux_delta), delta.metrics_aux = aux_delta; end
    v = @(fn) sqlite_val(br, fn);

    % The ledger row; a repeated frame range is a lane or seed bug (mysql_write notes S13)
    try
        execute(c, sprintf("INSERT INTO sim_batches (param_hash, machine, lane, seed_base, k_start, n_frames, batch_uid, code_rev, " + ...
            "matlab_release, started_at, finished_at, delta) VALUES (%s, %s, %s, %s, %s, %d, %s, %s, %s, %s, %s, %s)", ...
            q(h), q(host_id()), v('lane'), v('seed_base'), v('k_start'), nf, q(br.batch_uid), ...
            v('code_rev'), q(version('-release')), v('started_at'), v('finished_at'), q(jsonencode(delta))));
    catch ME
        if contains(ME.message, 'UNIQUE', 'IgnoreCase', true) && contains(ME.message, 'k_start')
            error('mysql_write:duplicateBatch', 'Frames %s of param_hash %s are already in the ledger; the batch was NOT recorded.', v('k_start'), h);
        end
        rethrow(ME);
    end

    % Commit the row and the ledger row together
    commit(c);
    status = "committed";

    % Refresh the snapshot other computers read through Syncthing (throttled; never fails the write)
    sqlite_snapshot(c, false);
catch ME
    % Any failure rolls the whole batch back
    try
        rollback(c);
    catch
    end
    rethrow(ME);
end
end

function sqlite_begin(c, cap)
% BEGIN IMMEDIATE (AutoCommit off alone opens no transaction); a busy file is retried for up to cap seconds (default 120).
if nargin < 2, cap = 120; end
t0 = tic;

% Retry a locked file after a random 0.05-0.5 s pause until cap (notes S3)
while true
    try
        execute(c, "BEGIN IMMEDIATE");
        return
    catch ME
        if ~contains(ME.message, 'locked', 'IgnoreCase', true) || toc(t0) > cap, rethrow(ME); end
        pause(0.05 + 0.45 * rand());
    end
end
end

function status = sqlite_already_recorded(prev, h, nf, br)
% A batch_uid already in the ledger must be this same batch (mysql_write notes S14).

% Same point, frame count, lane and k range?
same = string(prev.param_hash(1)) == string(h) && double(prev.n_frames(1)) == nf;
if isfield(br, 'lane') && ~isempty(br.lane), same = same && double(prev.lane(1)) == double(br.lane); end
if isfield(br, 'k_start') && ~isempty(br.k_start), same = same && double(prev.k_start(1)) == double(br.k_start); end

% A different batch is a uid collision; the same batch is reported, not added again
if ~same
    error('mysql_write:uidCollision', 'batch_uid %s is already in the ledger for a different batch; nothing was written.', br.batch_uid);
end
warning('mysql_write:batchAlreadyRecorded', 'Batch %s is already recorded (a retry after a lost reply); not added again.', br.batch_uid);
status = "already_recorded";
end

function k = sqlite_next_k_start(c, ~, h, seed_base, lane, B)
% This lane's next k range in a SQLite store, archived ranges included (Phase 3 R1; notes S10).
w = sprintf("WHERE param_hash = %s AND seed_base = %d AND lane = %d", q(h), seed_base, lane);
r = fetch(c, "SELECT MAX(COALESCE((SELECT MAX(k_start) FROM sim_batches " + w + "), -1), " + ...
    "COALESCE((SELECT MAX(k_start) FROM sim_batches_deleted " + w + "), -1)) AS m");
m = double(r.m(1));
if m < 0, k = lane * 2^32 + 1; else, k = m + B; end
end

function sqlite_delete_point(c, ~, h)
% Delete point h from a SQLite store: its ledger records to sim_batches_deleted and the row, in one transaction.

% Archive the ledger records, remove them and delete the row, all in one transaction
sqlite_begin(c);
try
    execute(c, "INSERT INTO sim_batches_deleted SELECT batch_id, param_hash, machine, lane, seed_base, k_start, n_frames, batch_uid, " + ...
        "code_rev, matlab_release, started_at, finished_at, delta, written_at, CURRENT_TIMESTAMP FROM sim_batches WHERE param_hash = " + q(h));
    execute(c, "DELETE FROM sim_batches WHERE param_hash = " + q(h));
    execute(c, "DELETE FROM sim_lookup WHERE param_hash = " + q(h));
    commit(c);
catch ME
    % Undo on failure
    try
        rollback(c);
    catch
    end
    rethrow(ME);
end

% Refresh the snapshot at once, so other computers see the deletion
sqlite_snapshot(c, true);
end

function n = sqlite_ledger_frames(c, ~, ~, h, seed_base)
% Ledgered frames of a point in this SQLite store.
r = fetch(c, sprintf("SELECT COALESCE(SUM(n_frames),0) AS n FROM sim_batches WHERE param_hash = %s AND seed_base = %d", q(h), seed_base));
n = double(r.n(1));
end

function s = q(txt)
% Quote text for SQLite: single quotes doubled (backslashes are literal in SQLite).
s = "'" + replace(string(txt), "'", "''") + "'";
end

function s = sqlite_val(br, f)
% One batch_record field as a SQLite literal: number, quoted text, or NULL.
if ~isstruct(br) || ~isfield(br, f) || isempty(br.(f))
    s = "NULL";
elseif isnumeric(br.(f))
    s = sprintf('%.0f', br.(f));
elseif isdatetime(br.(f))
    s = q(char(br.(f), 'yyyy-MM-dd HH:mm:ss.SSS'));
else
    s = q(string(br.(f)));
end
end

%% ===== 5. TEXT STORE =================================================
% A text store: open, write one batch as one JSON line under the lock,
% the in-memory state (snapshot plus log tail) and how each line type
% applies to it, the snapshot file, the write lock, next k range, the own
% ledger count, point deletion and seed rows (notes S5, S6).

function c = text_open(st)
% A text store: a folder holding batches.jsonl (the truth, append-only), rows.json (a snapshot rebuilt from it) and a lock file.

% The folder under the project root, created if needed
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
d = fullfile(root, char(st.path));
if ~isfolder(d), mkdir(d); end

% Its file names; an empty log is created on first open
c = struct('dir', d, 'log', fullfile(d, 'batches.jsonl'), 'rows', fullfile(d, 'rows.json'), 'lock', fullfile(d, 'write.lock'));
if ~isfile(c.log), fclose(fopen(c.log, 'a')); end
end

function status = text_store_write(c, table_name, parameters, nf, metrics_add, opts)
% One batch into a text store: under the lock, catch up the snapshot, check the uid and k range, append one line, save the snapshot.

% Check the table and the batch_uid, read the options, hash the parameters
assert(any(string(table_name) == ["sim_lookup" ""]), 'storage:textTable', 'A text store holds only sim_lookup.');
f = @(n) get_opt(opts, n);
br = f('batch'); aux_cum = f('metrics_aux_cumulative'); aux_delta = f('metrics_aux_delta');
if isempty(br) || ~isfield(br, 'batch_uid') || strlength(string(br.batch_uid)) ~= 64
    error('mysql_write:noBatchUid', 'A text-store write needs a batch_record with a 64-character batch_uid.');
end
[paramsJSON, h] = jsonencode_sorted(parameters);

% Every reported metric gets a sample count; a missing one counts the batch's frames (mysql_write notes S1)
mn_add = f('metrics_n_add'); if isempty(mn_add), mn_add = struct(); end
fa = fieldnames(metrics_add);
for i = 1:numel(fa)
    if ~isfield(mn_add, fa{i}), mn_add.(fa{i}) = nf; end
end

% Take the lock; everything below runs under it (a mirror passes a short cap, opts.lock_timeout)
tok = text_lock(c, cap_of(opts));
unlock = onCleanup(@() text_unlock(c, tok));

% The snapshot, caught up with any lines appended since it was saved
S = text_state(c);

% The same uid again: confirm it is this batch and stop (mysql_write notes S14)
if isKey(S.uids, char(br.batch_uid))
    b = S.uids(char(br.batch_uid));
    same = string(b.param_hash) == string(h) && b.frames == nf;
    if isfield(br, 'lane') && ~isempty(br.lane), same = same && isequal(b.lane, double(br.lane)); end
    if isfield(br, 'k_start') && ~isempty(br.k_start), same = same && isequal(b.k_start, double(br.k_start)); end
    if ~same
        error('mysql_write:uidCollision', 'batch_uid %s is already in the ledger for a different batch; nothing was written.', br.batch_uid);
    end
    % The same batch: a retry after a lost reply
    warning('mysql_write:batchAlreadyRecorded', 'Batch %s is already recorded (a retry after a lost reply); not added again.', br.batch_uid);
    status = "already_recorded";
    return
end

% A repeated frame range is a lane or seed bug (mysql_write notes S13)
kkey = frame_key(h, br);
if strlength(kkey) > 0 && isKey(S.kranges, char(kkey))
    error('mysql_write:duplicateBatch', 'Frames %s of param_hash %s are already in the ledger; the batch was NOT recorded.', ...
        string(br.k_start), h);
end

% The line: the whole batch record, committed when its newline reaches the file
L = struct('type', "batch", 'param_hash', string(h), 'parameters', string(paramsJSON), 'frames', nf, ...
    'metrics', metrics_add, 'metrics_n', mn_add, 'batch_uid', string(br.batch_uid), ...
    'machine', host_id(), 'matlab_release', string(version('-release')), ...
    'written_at', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS')));
if ~isempty(aux_delta), L.metrics_aux = aux_delta; end
if isempty(aux_delta) && ~isempty(aux_cum), L.metrics_aux_cumulative = aux_cum; end

% The batch_record's Phase 3 fields and times, when given, then the encoded line
for fn = ["lane" "seed_base" "k_start" "code_rev" "started_at" "finished_at"]
    if isfield(br, fn) && ~isempty(br.(fn))
        v = br.(fn); if isdatetime(v), v = string(v, 'yyyy-MM-dd HH:mm:ss.SSS'); end
        L.(fn) = v;
    end
end
line = [jsonencode(L) newline];

% Append it, after cutting off any partial line a crashed writer left (the lock makes that safe)
text_trim_partial(c.log);
fid = fopen(c.log, 'a'); fwrite(fid, line, 'char'); fclose(fid);

% Apply it to the snapshot and save the snapshot atomically
S = text_apply(S, L);
S.log_bytes = dir(c.log).bytes;
text_save(c, S);
status = "committed";
end

function S = text_state(c)
% The snapshot from rows.json, then every complete line after the byte it covers; a missing or bad snapshot is rebuilt.

% The saved snapshot, or an empty one when it is missing or unreadable
S = text_empty();
if isfile(c.rows)
    try
        S = text_load_snapshot(c.rows);
    catch
        S = text_empty();
    end
end

% Read the log past the byte the snapshot covers
info = dir(c.log);
if info.bytes > S.log_bytes
    fid = fopen(c.log, 'r'); fseek(fid, S.log_bytes, 'bof'); tail = fread(fid, inf, '*char')'; fclose(fid);
    % Apply only complete lines (up to the last newline); a partial last line is left out
    last = find(tail == newline, 1, 'last');
    if ~isempty(last)
        lines = splitlines(string(tail(1:last-1)));
        off = S.log_bytes;
        for i = 1:numel(lines)
            if strlength(lines(i)) > 0, S = text_apply(S, decode_line(lines(i), c.log, off)); end
            off = off + strlength(lines(i)) + 1;
        end
        S.log_bytes = S.log_bytes + last;
    end
end
end

function S = text_empty()
% An empty snapshot: rows by param_hash, the uid index, the frame-range index.
S = struct('log_bytes', 0, 'rows', containers.Map('KeyType', 'char', 'ValueType', 'any'), ...
    'uids', containers.Map('KeyType', 'char', 'ValueType', 'any'), 'kranges', containers.Map('KeyType', 'char', 'ValueType', 'logical'));
end

function S = text_apply(S, L)
% Apply one log line: delete_row, ledger_import, seed_row (a row that predates the ledger), or a batch merged with apply_batch.
h = char(L.param_hash);
if string(L.type) == "delete_row"
    % The point deleted (notes S10): row gone, its batches dead (uids and frame ranges stay reserved)
    if isKey(S.rows, h), remove(S.rows, h); end
    U = keys(S.uids);
    for i = 1:numel(U)
        b = S.uids(U{i});
        if string(b.param_hash) == string(h), b.dead = true; S.uids(U{i}) = b; end
    end
    return
end
if string(L.type) == "ledger_import"
    % A batch already inside an imported row: index it only (store_resync; notes S7)
    b = struct('param_hash', string(h), 'frames', double(L.frames), 'lane', field_or_empty(L, 'lane'), ...
        'seed_base', field_or_empty(L, 'seed_base'), 'k_start', field_or_empty(L, 'k_start'));
    S.uids(char(L.batch_uid)) = b;
    k = frame_key(h, L);
    if strlength(k) > 0, S.kranges(char(k)) = true; end
    return
end
if string(L.type) == "seed_row"
    % A row that predates the ledger; it must come before any batch for its point
    if isKey(S.rows, h), error('storage:seedRowConflict', 'seed_row for %s comes after the row already exists.', h); end
    S.rows(h) = struct('parameters', string(L.parameters), 'metrics', L.metrics, 'metrics_n', L.metrics_n, ...
        'metrics_aux', field_or_empty(L, 'metrics_aux'), 'frames_simulated', double(L.frames_simulated), 'write_seq', 0);
    return
end

% A batch line: start a new row, or merge into the existing one with apply_batch
nf = double(L.frames);
mn_add = L.metrics_n;
aux_delta = field_or_empty(L, 'metrics_aux');
if ~isKey(S.rows, h)
    [m, mn, aux] = apply_batch([], nf, L.metrics, mn_add, aux_delta);
    R = struct('parameters', string(L.parameters), 'metrics', m, 'metrics_n', mn, 'metrics_aux', aux, 'frames_simulated', nf, 'write_seq', 0);
else
    % An existing row: recover its sample counts, then merge
    R = S.rows(h);
    N_total = R.frames_simulated + nf;
    rowT = table(string(jsonencode(R.metrics)), string(jsonencode(R.metrics_n)), R.frames_simulated, ...
        'VariableNames', {'metrics', 'metrics_n', 'frames_simulated'});
    old = struct('metrics', R.metrics, 'n', metric_sample_count(rowT), 'aux', R.metrics_aux);
    [m, mn, aux] = apply_batch(old, N_total, L.metrics, mn_add, aux_delta);
    if isempty(aux_delta), aux = R.metrics_aux; end
    R.metrics = m; R.metrics_n = mn; R.metrics_aux = aux; R.frames_simulated = N_total; R.write_seq = R.write_seq + 1;
end

% Store the row (a cumulative aux replaces the stored one), then index the batch's uid and frame range
if isempty(aux_delta) && isfield(L, 'metrics_aux_cumulative'), R.metrics_aux = L.metrics_aux_cumulative; end
S.rows(h) = R;
b = struct('param_hash', string(h), 'frames', nf, 'lane', field_or_empty(L, 'lane'), 'seed_base', field_or_empty(L, 'seed_base'), ...
    'k_start', field_or_empty(L, 'k_start'));
S.uids(char(L.batch_uid)) = b;
k = frame_key(h, L);
if strlength(k) > 0, S.kranges(char(k)) = true; end
end

function v = field_or_empty(s, f)
% A struct field, or [] when absent.
if isfield(s, f), v = s.(f); else, v = []; end
end

function k = frame_key(h, b)
% The frame-range identity of a Phase 3 batch, or "" for a batch without one.
k = "";
if isfield(b, 'seed_base') && isfield(b, 'lane') && isfield(b, 'k_start') && ~isempty(b.k_start)
    k = sprintf('%s|%.0f|%.0f|%.0f', h, double(b.seed_base), double(b.lane), double(b.k_start));
end
end

function text_save(c, S)
% Write rows.json to a temporary name, then move it over the old one, so a reader never sees half a snapshot.

% The rows with their hashes, the uid index and the frame ranges
rows = values(S.rows); keys_ = keys(S.rows);
R = cell(1, numel(rows));
for i = 1:numel(rows), R{i} = rows{i}; R{i}.param_hash = string(keys_{i}); end
U = keys(S.uids); B = values(S.uids);
snap = struct('log_bytes', S.log_bytes, 'rows', {R}, 'uids', {U}, 'batches', {B}, 'kranges', {keys(S.kranges)});

% Write the temporary file and move it over rows.json
tmp = [c.rows '.tmp'];
fid = fopen(tmp, 'w'); fwrite(fid, jsonencode(snap), 'char'); fclose(fid);
movefile(tmp, c.rows, 'f');
end

function S = text_load_snapshot(file)
% Read rows.json back into the in-memory maps.

% The covered log byte and the rows by param_hash
j = jsondecode(fileread(file));
S = text_empty();
S.log_bytes = double(j.log_bytes);
R = j.rows; if isempty(R), R = {}; elseif ~iscell(R), R = num2cell(R); end
for i = 1:numel(R)
    r = R{i}; h = char(r.param_hash); r = rmfield(r, 'param_hash');
    if ~isfield(r, 'metrics_aux'), r.metrics_aux = []; end
    S.rows(h) = r;
end

% The uid index (jsondecode may return arrays rather than cells)
U = j.uids; B = j.batches;
if ~isempty(U)
    if ~iscell(U), U = cellstr(U); end
    if ~iscell(B), B = num2cell(B); end
    for i = 1:numel(U), S.uids(char(U{i})) = B{i}; end
end

% The frame-range index
K = j.kranges;
if ~isempty(K)
    if ~iscell(K), K = cellstr(K); end
    for i = 1:numel(K), S.kranges(char(K{i})) = true; end
end
end

function text_trim_partial(file)
% Cut off a last line without its newline: a writer that crashed mid-append never committed it.

% Read the last 64 KiB at most; a file ending in a newline needs nothing
info = dir(file);
if info.bytes == 0, return; end
fid = fopen(file, 'r'); fseek(fid, -min(info.bytes, 65536), 'eof'); tail = fread(fid, inf, '*char')'; fclose(fid);
if tail(end) == newline, return; end

% Keep everything up to the last newline and truncate the rest
last = find(tail == newline, 1, 'last');
if isempty(last)
    keep = info.bytes - numel(tail);          % no complete line in the tail read: keep what precedes it
else
    keep = info.bytes - numel(tail) + last;   % up to and including the last newline
end
raf = java.io.RandomAccessFile(file, 'rw'); raf.setLength(keep); raf.close();
end

function tok = text_lock(c, cap)
% Create the lock file atomically, holding an owner token; break it only if its owner process is gone and it is older than 5 minutes.

% The wait clock and this writer's owner token, pid|time|uid
if nargin < 2, cap = 120; end
t0 = tic;
attr = javaArray('java.nio.file.attribute.FileAttribute', 0);
tok = sprintf('%d|%.0f|%s', feature('getpid'), posixtime(datetime('now')), char(new_batch_uid()));

% Create the lock and write the token; while it is held, break a stale lock, back off 0.02-0.22 s, give up after cap
while true
    try
        java.nio.file.Files.createFile(java.nio.file.Paths.get(c.lock, javaArray('java.lang.String', 0)), attr);
    catch ME
        if ~contains(ME.message, 'FileAlreadyExists'), rethrow(ME); end
        text_break_stale(c.lock);
        if toc(t0) > cap, error('storage:textLockTimeout', 'Could not take %s within %g s.', c.lock, cap); end
        pause(0.02 + 0.2 * rand());
        continue
    end

    % The lock is ours: write the token, retrying while a reader briefly holds the file open (Windows)
    for attempt = 1:100
        fid = fopen(c.lock, 'w');
        if fid > 0, fwrite(fid, tok, 'char'); fclose(fid); return; end
        pause(0.02);
    end
    try
        delete(c.lock);
    catch
    end
    error('storage:textLockToken', 'Took %s but could not write its owner token.', c.lock);
end
end

function text_break_stale(lock)
% Break a lock whose owner is gone and which is older than 5 minutes, never deleting a fresh one (notes S6).
try
    % Keep a lock younger than 5 minutes, or whose owner process is alive
    old = fileread(lock);
    p = sscanf(old, '%d|%f');
    if numel(p) < 2
        % No token (its writer stopped between creating the lock and writing it): judge by the file's age alone
        if seconds(datetime('now') - datetime(dir(lock).datenum, 'ConvertFrom', 'datenum')) < 300, return; end
    else
        if posixtime(datetime('now')) - p(2) < 300, return; end
        if pid_alive(p(1)), return; end
    end

    % Take it aside by an atomic rename
    side = sprintf('%s.stale.%d', lock, feature('getpid'));
    mv = javaArray('java.nio.file.CopyOption', 1); mv(1) = java.nio.file.StandardCopyOption.ATOMIC_MOVE;
    none = javaArray('java.lang.String', 0);
    java.nio.file.Files.move(java.nio.file.Paths.get(lock, none), java.nio.file.Paths.get(side, none), mv);

    % Delete it only if the moved file still holds the content judged stale
    if strcmp(fileread(side), old)
        delete(side);
    else
        % A fresh lock was taken in the meantime: put it back untouched
        java.nio.file.Files.move(java.nio.file.Paths.get(side, none), java.nio.file.Paths.get(lock, none), mv);
    end
catch
end
end

function text_unlock(c, tok)
% Release the lock, only if it is still this writer's own.
% On Windows a delete fails while another writer has the file open to read it (text_break_stale), and MATLAB's
% delete only warns, which left a live owner's lock behind until every other writer timed out (2026-10-24,
% 12-worker parallel run on a text primary). Retry with a throwing delete until the file is gone, for up to 10 s.
none = javaArray('java.lang.String', 0);
for attempt = 1:200
    try
        if ~isfile(c.lock) || ~strcmp(fileread(c.lock), tok), return; end
        java.nio.file.Files.deleteIfExists(java.nio.file.Paths.get(c.lock, none));
        return
    catch
        pause(0.05);
    end
end
warning('storage:textUnlockFailed', 'Could not release %s; other writers will wait for it to go stale.', c.lock);
end

function k = text_next_k_start(c, ~, h, seed_base, lane, B)
% This lane's next k range in a text store (Phase 3 R1).

% Largest k_start of this point, seed_base and lane over every batch, dead ones included (notes S10)
S = text_state(c);
m = -1;
B_ = values(S.uids);
for i = 1:numel(B_)
    b = B_{i};
    if string(b.param_hash) == string(h) && isequal(b.seed_base, seed_base) && isequal(b.lane, lane)
        m = max(m, double(b.k_start));
    end
end

% Continue past it, or start the lane's range
if m < 0, k = lane * 2^32 + 1; else, k = m + B; end
end

function n = text_ledger_frames(c, ~, ~, h, seed_base)
% Ledgered frames of a point in this text store (read only; live batches).
S = text_state(c);
n = 0;
B_ = values(S.uids);
for i = 1:numel(B_)
    b = B_{i};
    if ~is_dead(b) && string(b.param_hash) == string(h) && isequal(b.seed_base, seed_base), n = n + b.frames; end
end
end

function tf = is_dead(b)
% A batch of a deleted point (text store).
tf = isfield(b, 'dead') && isequal(b.dead, true);
end

function text_delete_point(c, ~, h)
% Delete point h from a text store: one delete_row line under the lock (the row goes, its batches turn dead).

% Under the lock: catch up the snapshot and cut off any partial line
tok = text_lock(c);
unlock = onCleanup(@() text_unlock(c, tok));
S = text_state(c);
text_trim_partial(c.log);

% Append the delete_row line, apply it and save the snapshot
L = struct('type', "delete_row", 'param_hash', string(h), 'deleted_at', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS')));
fid = fopen(c.log, 'a'); fwrite(fid, [jsonencode(L) newline], 'char'); fclose(fid);
S = text_apply(S, L);
S.log_bytes = dir(c.log).bytes;
text_save(c, S);
end

function text_seed_rows(c, T)
% Write seed_row lines for rows that predate the ledger (review point C): T has sim_lookup's columns.

% Under the lock: catch up the snapshot and cut off any partial line
tok = text_lock(c);
unlock = onCleanup(@() text_unlock(c, tok));
S = text_state(c);
text_trim_partial(c.log);

% One seed_row line per row the store does not hold yet
fid = fopen(c.log, 'a');
for r = 1:height(T)
    h = char(string(T.param_hash(r)));
    if isKey(S.rows, h), continue; end

    % The row's cells (a cell or a string each); metrics_aux decoded when present
    aux = []; ax = T.metrics_aux(r); if iscell(ax), ax = ax{1}; end
    if ~isempty(ax) && ~(isstring(ax) && (ismissing(ax) || strlength(ax) == 0)), aux = jsondecode(char(ax)); end
    mt = T.metrics(r); if iscell(mt), mt = mt{1}; end
    mn = T.metrics_n(r); if iscell(mn), mn = mn{1}; end
    pr = T.parameters(r); if iscell(pr), pr = pr{1}; end

    % Build the line, write it and apply it
    L = struct('type', "seed_row", 'param_hash', string(h), 'parameters', string(pr), 'metrics', jsondecode(char(mt)), ...
        'metrics_n', jsondecode(char(mn)), 'frames_simulated', double(T.frames_simulated(r)));
    if ~isempty(aux), L.metrics_aux = aux; end
    fwrite(fid, [jsonencode(L) newline], 'char');
    S = text_apply(S, L);
end

% Close the log and save the snapshot
fclose(fid);
S.log_bytes = dir(c.log).bytes;
text_save(c, S);
end

%% ===== 6. MIRROR SUPPORT =============================================
% Whole-store reads and replacement for mirrors (notes S7): rows and
% ledgers as tables (load_rows, ledger_rows), batch_uid lists (uids),
% import from a primary, the ledger summaries every kind provides, and
% the cell-to-SQL helpers txt, null_or and num_or_null.

function T = text_rows(c)
% The text store's rows as a sim_lookup-shaped table (metrics as JSON text), rebuilt from batches.jsonl alone.

% Replay every complete line of the log into an empty state (the snapshot is not used)
S = text_empty();
fid = fopen(c.log, 'r'); txt = fread(fid, inf, '*char')'; fclose(fid);
last = find(txt == newline, 1, 'last');
if ~isempty(last)
    lines = splitlines(string(txt(1:last-1)));
    off = 0;
    for i = 1:numel(lines)
        if strlength(lines(i)) > 0, S = text_apply(S, decode_line(lines(i), c.log, off)); end
        off = off + strlength(lines(i)) + 1;
    end
end

% One table row per point, metrics as JSON text
k = keys(S.rows); n = numel(k);
[ph, pa, me, mn, ax] = deal(strings(n,1)); fr = zeros(n,1);
for i = 1:n
    R = S.rows(k{i});
    ph(i) = k{i}; pa(i) = R.parameters; me(i) = jsonencode(R.metrics); mn(i) = jsonencode(R.metrics_n); fr(i) = R.frames_simulated;
    if ~isempty(R.metrics_aux), ax(i) = jsonencode(R.metrics_aux); end
end
T = table(ph, pa, me, mn, ax, fr, 'VariableNames', {'param_hash', 'parameters', 'metrics', 'metrics_n', 'metrics_aux', 'frames_simulated'});
end

function L = decode_line(line, file, off)
% One complete log line as a struct; a line that isn't valid JSON is a damaged store, reported as such.
try
    L = jsondecode(line);
catch ME
    error('storage:corruptLog', 'The text-store log %s has a damaged line at byte %d (%s). The store needs repair; nothing was written.', ...
        file, off, ME.message);
end
end

function T = sqlite_rows(c)
% A SQLite store's rows as a sim_lookup-shaped table (nullable columns read through COALESCE).
T = fetch(c, "SELECT param_hash, parameters, metrics, COALESCE(metrics_n, '') AS metrics_n, " + ...
    "COALESCE(metrics_aux, '') AS metrics_aux, frames_simulated FROM sim_lookup");
end

function u = sqlite_uids(c)
% Every batch_uid in a SQLite store's ledger.
r = fetch(c, "SELECT batch_uid FROM sim_batches");
u = string(r.batch_uid);
end

function L = text_ledger_rows(c)
% A text store's ledger as a table: one row per batch or ledger import (absent lane, seed_base, k_start as NaN).

% Live batches only (a deleted point's are left out)
S = text_state(c);
U = keys(S.uids); B = values(S.uids);
live = ~cellfun(@is_dead, B); U = U(live); B = B(live); n = numel(U);

% One table row per batch
[h, uid] = deal(strings(n, 1)); [nf, ln, sb, ks] = deal(nan(n, 1));
for i = 1:n
    b = B{i}; h(i) = string(b.param_hash); uid(i) = string(U{i}); nf(i) = b.frames;
    if ~isempty(b.lane), ln(i) = double(b.lane); end
    if ~isempty(b.seed_base), sb(i) = double(b.seed_base); end
    if ~isempty(b.k_start), ks(i) = double(b.k_start); end
end
L = table(h, nf, uid, ln, sb, ks, 'VariableNames', {'param_hash', 'n_frames', 'batch_uid', 'lane', 'seed_base', 'k_start'});
end

function u = text_uids(c)
% Every live batch_uid in a text store (batches and ledger imports; not those of deleted points).
S = text_state(c);
U = keys(S.uids); B = values(S.uids);
u = string(U(~cellfun(@is_dead, B)))';
end

function sqlite_import(c, R, L)
% Replace a SQLite store's rows and ledger with R and L (a primary's tables), in one transaction.
sqlite_begin(c);
try
    % Empty both tables, then insert R's rows
    execute(c, "DELETE FROM sim_lookup"); execute(c, "DELETE FROM sim_batches");
    for i = 1:height(R)
        execute(c, sprintf("INSERT INTO sim_lookup (param_hash, parameters, metrics, metrics_n, metrics_aux, frames_simulated, write_seq, updated_at) " + ...
            "VALUES (%s, %s, %s, %s, %s, %d, 0, CURRENT_TIMESTAMP)", q(txt(R.param_hash(i))), q(txt(R.parameters(i))), q(txt(R.metrics(i))), ...
            q(txt(R.metrics_n(i))), null_or(txt(R.metrics_aux(i))), double(R.frames_simulated(i))));
    end

    % Insert L's ledger records, then commit
    for i = 1:height(L)
        execute(c, sprintf("INSERT INTO sim_batches (param_hash, machine, lane, seed_base, k_start, n_frames, batch_uid, code_rev, " + ...
            "matlab_release, started_at, finished_at, delta) VALUES (%s, %s, %s, %s, %s, %d, %s, %s, %s, %s, %s, %s)", ...
            q(txt(L.param_hash(i))), q(txt(L.machine(i))), num_or_null(L.lane(i)), num_or_null(L.seed_base(i)), num_or_null(L.k_start(i)), ...
            double(L.n_frames(i)), q(txt(L.batch_uid(i))), null_or(txt(L.code_rev(i))), null_or(txt(L.matlab_release(i))), ...
            null_or(txt(L.started_at(i))), null_or(txt(L.finished_at(i))), q(txt(L.delta(i)))));
    end
    commit(c);
catch ME
    % Undo on failure
    try
        rollback(c);
    catch
    end
    rethrow(ME);
end
end

function text_import(c, R, L)
% Replace a text store's contents: the old log is kept aside, then seed_row lines for R and ledger_import lines for L.

% Under the lock: keep the old log aside as .replaced and drop the snapshot
tok = text_lock(c);
unlock = onCleanup(@() text_unlock(c, tok));
if isfile(c.log), movefile(c.log, sprintf('%s.%s.replaced', c.log, char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')))); end
if isfile(c.rows), delete(c.rows); end

% A new log: one seed_row line per row of R
fid = fopen(c.log, 'w');
for i = 1:height(R)
    Ls = struct('type', "seed_row", 'param_hash', txt(R.param_hash(i)), 'parameters', txt(R.parameters(i)), ...
        'metrics', jsondecode(char(txt(R.metrics(i)))), 'metrics_n', jsondecode(char(txt(R.metrics_n(i)))), ...
        'frames_simulated', double(R.frames_simulated(i)));
    ax = txt(R.metrics_aux(i)); if strlength(ax) > 0, Ls.metrics_aux = jsondecode(char(ax)); end
    fwrite(fid, [jsonencode(Ls) newline], 'char');
end

% One ledger_import line per batch of L: indexed, never applied again (notes S7)
for i = 1:height(L)
    Li = struct('type', "ledger_import", 'param_hash', txt(L.param_hash(i)), 'frames', double(L.n_frames(i)), 'batch_uid', txt(L.batch_uid(i)));
    for f = ["lane" "seed_base" "k_start"]
        v = double(L.(f)(i)); if ~isnan(v), Li.(f) = v; end
    end
    fwrite(fid, [jsonencode(Li) newline], 'char');
end

% Close the log, rebuild the snapshot from it and save it
fclose(fid);
S = text_state(c);
text_save(c, S);
end

function s = txt(v)
% One table cell as a string: cell, char, string or missing all become a string ("" for empty or missing).
if iscell(v), v = v{1}; end
if isempty(v) || (isstring(v) && ismissing(v)), s = ""; else, s = string(v); end
end

function s = null_or(t)
% A quoted SQLite text value, or NULL for an empty string.
if strlength(t) == 0, s = "NULL"; else, s = q(t); end
end

function s = num_or_null(v)
% An integer SQLite value, or NULL for NaN or empty.
if iscell(v), v = v{1}; end
v = double(v);
if isempty(v) || isnan(v), s = "NULL"; else, s = sprintf('%.0f', v); end
end

function [n, fr] = mysql_ledger_summary(c, table_name)
% Batches and frames in a MySQL store's ledger (0, 0 when it has no ledger yet).
n = 0; fr = 0;
try
    r = fetch(c, "SELECT COUNT(*) AS n, COALESCE(SUM(n_frames),0) AS f FROM " + ledger_name(table_name));
    n = double(r.n(1)); fr = double(r.f(1));
catch ME
    if ~contains(ME.message, "doesn't exist"), rethrow(ME); end
end
end

function [n, fr] = sqlite_ledger_summary(c, ~)
% Batches and frames in a SQLite store's ledger.
r = fetch(c, "SELECT COUNT(*) AS n, COALESCE(SUM(n_frames),0) AS f FROM sim_batches");
n = double(r.n(1)); fr = double(r.f(1));
end

function [n, fr] = text_ledger_summary(c, ~)
% Batches (and ledger imports) and their frames in a text store.
S = text_state(c);
B = values(S.uids);
B = B(~cellfun(@is_dead, B));
n = numel(B); fr = 0;
for i = 1:n, fr = fr + B{i}.frames; end
end

%% ===== 7. SQLITE SNAPSHOTS ===========================================
% The copy of a SQLite store that other computers read through
% Syncthing, refreshed after commits and forced by flush (notes S4).

function sqlite_snapshot(c, force)
% Refresh <file>.snapshot from the live SQLite file (at most every 60 s unless forced; best effort, notes S4).

% At most every 60 s per file and process, unless forced
persistent last
if isempty(last), last = containers.Map('KeyType', 'char', 'ValueType', 'any'); end
f = char(c.Database);
if ~force && isKey(last, f) && toc(last(f)) < 60, return; end

% A temporary name unique to this process
uid = char(new_batch_uid());
tmp = sprintf('%s.snapshot.tmp.%d.%s', f, feature('getpid'), uid(1:8));
why = "";

% VACUUM INTO the temporary name, then rename it over the snapshot
try
    execute(c, "VACUUM INTO " + q(tmp));
    % Up to 5 rename tries, 0.2 s apart; a copy that could not be moved is deleted
    moved = false;
    for a = 1:5
        try
            movefile(tmp, [f '.snapshot'], 'f');
            moved = true;
            why = "";
            break
        catch ME
            why = string(ME.message);
            pause(0.2);
        end
    end
    if ~moved, delete(tmp); end
catch ME
    % The VACUUM failed: keep the reason and remove any partial copy
    why = string(ME.message);
    if isfile(tmp), delete(tmp); end
end

% Record this attempt's time; a miss is noted in store_status, never raised
last(f) = tic;
if strlength(why) > 0
    % Note the miss (not a stale flag): the reader keeps the previous snapshot
    try
        root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
        rel = strrep(extractAfter(string(f), strlength(string(root)) + 1), "\", "/");
        store_status(host_id(), "snapshot|" + rel, struct('stale', false, ...
            'reason', "snapshot refresh skipped: " + why, 'time', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'))));
    catch
    end
end
end

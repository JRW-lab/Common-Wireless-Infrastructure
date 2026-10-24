function conn = store_connect(tgt)
% STORE_CONNECT  Open this computer's primary results store for writing.
%
%   conn = store_connect(tgt)
%
%   Collectors write through results_write and read through load_merged,
%   both of which take the primary's handle. For a MySQL primary that is
%   mysql_login's connection; a computer without MySQL (storage step 6b,
%   notes/STORAGE_BACKENDS_PLAN.md) has a SQLite or text primary, opened by
%   its store adapter. collect_profile calls this wherever it used to call
%   mysql_login, including its reconnects.
%
%   INPUT:
%     tgt: db_target() (fields dbname, kind, store)
%
%   OUTPUT:
%     conn: a MySQL connection, a sqlite connection (AutoCommit off), or a
%           text-store struct. Pass dbname tgt.dbname ("" for a file
%           primary) alongside it to load_merged and ledger_frames.
%
%   LIMITS: a file primary is opened, never created elsewhere than its own
%   Results/<HOST>/ path (machine_stores checks that).

% MySQL, as before
if ~isfield(tgt, 'kind') || tgt.kind == "mysql"
    conn = mysql_login(tgt.dbname);
    return
end

% A SQLite or text primary, through its adapter
ad = store_adapter(tgt.kind);
conn = ad.open(tgt.store);
end

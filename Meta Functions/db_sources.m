function src = db_sources(dbname, table_name)
% DB_SOURCES  Results sources that readers merge, with the caller's own first.
%
%   src = db_sources(dbname, table_name)
%
%   Each machine writes to its own results database, and figures, tables
%   and frame targets read every one of them (notes/PER_MACHINE_DB_PLAN.md).
%   This function returns the registry (db_registry) as a struct array with
%   the source the caller passed as element 1. That source is added if the
%   registry does not list it. With no registry the caller's source is the
%   only one, which is the behaviour before the registry existed.
%
%   INPUTS:
%     dbname:     database the caller reads and writes, e.g. "comm_database";
%                 "" on a computer whose primary is a file store (storage
%                 step 6b), whose entry is then found by COMPUTERNAME
%     table_name: its results table, e.g. "sim_lookup"
%
%   OUTPUT:
%     src: struct array with fields name, host, dbname, table, role, own,
%          kind, store_priority, writer, stores. own is true only for
%          element 1. A machine is represented by its primary store, and
%          stores lists all of its stores in priority order (machine_stores),
%          which load_merged falls back through (store_read).
%
%   LIMITS: a registry entry matches the caller's source by dbname and
%   table. A test_* table is never merged: it is returned alone, so a test
%   run schedules and reads only its own frames (notes S9). Registry format
%   and roles: notes load_merged_NOTES.md S1.

% A computer without MySQL passes "" and is matched by COMPUTERNAME; otherwise the source must be named (storage step 6b)
if strlength(string(dbname)) == 0
    src = file_own(table_name);
    return
end

% The caller's source, which keeps its own connection and credentials
own = struct('name', "own", 'host', "", 'dbname', string(dbname), ...
    'table', string(table_name), 'role', "own", 'own', true, 'kind', "mysql", 'store_priority', 1, ...
    'writer', "", 'stores', []);
src = own;
reg = db_registry();
if isempty(reg)
    return
end

% The server that holds the caller's database, from the same lookup mysql_login uses
creds = db_creds(dbname);
if ~isempty(creds), src(1).host = string(creds.host); end

% A throwaway test_* table stands alone; merging it with real results would mix test and real frames (notes S9)
if startsWith(string(table_name), "test_")
    return
end

% Append every registry entry, a machine as its primary store (machine_stores, no connection); the caller's own entry renames element 1
for k = 1:numel(reg)
    p = struct('kind', "mysql", 'priority', 1, 'host', reg(k).host, 'dbname', reg(k).dbname, 'table', reg(k).table);
    st = [];
    if reg(k).role == "machine", st = machine_stores(reg(k)); p = st(1); end
    e = struct('name', reg(k).name, 'host', p.host, 'dbname', p.dbname, ...
        'table', p.table, 'role', reg(k).role, 'own', false, 'kind', p.kind, 'store_priority', p.priority, ...
        'writer', reg(k).writer, 'stores', st);
    if e.dbname == own.dbname && e.table == own.table
        src(1).name = e.name;
        src(1).role = e.role;
        src(1).writer = e.writer;
        src(1).stores = e.stores;
    else
        src(end+1) = e; %#ok<AGROW>
    end
end

% Two entries naming the same table would count its frames twice
check_unique(src);
end

function src = file_own(table_name)
% The registry with this computer's own file-primary entry first (a computer without MySQL, storage step 6b).
reg = db_registry();
me = host_id();
k = [];
if ~isempty(reg), k = find([reg.role] == "machine" & [reg.writer] == me, 1); end
if isempty(k)
    error('db_sources:noDbname', 'db_sources needs the caller''s database name (this computer has no registry entry).');
end

% Every registry entry, the own one first and marked own
order = [k setdiff(1:numel(reg), k)];
src = struct('name', {}, 'host', {}, 'dbname', {}, 'table', {}, 'role', {}, 'own', {}, 'kind', {}, ...
    'store_priority', {}, 'writer', {}, 'stores', {});
for i = order
    p = struct('kind', "mysql", 'priority', 1, 'host', reg(i).host, 'dbname', reg(i).dbname, 'table', reg(i).table);
    st = [];
    if reg(i).role == "machine", st = machine_stores(reg(i)); p = st(1); end
    src(end+1) = struct('name', reg(i).name, 'host', p.host, 'dbname', p.dbname, 'table', p.table, ...
        'role', reg(i).role, 'own', i == k, 'kind', p.kind, 'store_priority', p.priority, ...
        'writer', reg(i).writer, 'stores', st); %#ok<AGROW>
end

% Only this computer's own results table is merged
if src(1).kind == "mysql" || string(table_name) ~= src(1).table
    error('db_sources:noDbname', 'This computer''s primary is MySQL or another table; pass its database name.');
end
check_unique(src);
end

function check_unique(src)
% A table, or a file store, listed twice would count its frames twice.
keys = strings(1, numel(src));
for i = 1:numel(src)
    if src(i).kind == "mysql"
        keys(i) = src(i).host + "|" + src(i).dbname + "|" + src(i).table;
    else
        keys(i) = src(i).writer + "|" + src(i).kind + "|" + src(i).stores(1).path;
    end
end
if numel(unique(keys)) < numel(keys)
    error('db_sources:duplicate', ...
        'db_sources.json lists one table twice; its frames would be counted twice.');
end
end

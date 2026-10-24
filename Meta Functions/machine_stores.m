function st = machine_stores(entry)
% MACHINE_STORES  A computer's result stores, in priority order.
%
%   st = machine_stores(entry)
%
%   Each computer keeps its results in one or more stores (MySQL, SQLite,
%   text, Excel; notes/STORAGE_BACKENDS_PLAN.md). Priority 1 is the primary,
%   the rest are mirrors. The list lives in Results/<writer>/stores.json,
%   which only that computer writes (user decision F, 2026-10-21). Without
%   that file the registry's own machine entry is the one MySQL store, the
%   behaviour before stores existed, so a computer whose file has not synced
%   yet reads exactly as before.
%
%   INPUT:
%     entry: one machine element of db_registry (fields writer, host,
%            dbname, table).
%
%   OUTPUT:
%     st: struct array sorted by priority, fields kind, priority, host,
%         dbname, table, path. st(1) is the primary.
%
%   LIMITS: the primary may be "mysql", "sqlite" or "text" (a computer
%   without MySQL, storage step 6b); mirrors may be "sqlite" or "text", and
%   "mysql" too under a MySQL primary; "excel" is a mirror only, a whole-file
%   export refreshed by store_flush (step 7a). A file
%   store's table is "sim_lookup". When the registry entry names a
%   database, the primary must be that MySQL table
%   (storage:registryMismatch). Never connects to anything; reachability is
%   load_merged's job.

% The registry entry as a single MySQL store
v1 = struct('kind', "mysql", 'priority', 1, 'host', string(entry.host), ...
    'dbname', string(entry.dbname), 'table', string(entry.table), 'path', "");
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
f = fullfile(root, 'Results', char(entry.writer), 'stores.json');
if ~isfile(f)
    if strlength(v1.dbname) == 0
        error('storage:noStores', 'Machine %s has no database in the registry and no %s.', entry.writer, f);
    end
    st = v1;
    return
end

% Decode the computer's own list; it must be its own
raw = jsondecode(fileread(f));
if ~isfield(raw, 'writer') || upper(string(raw.writer)) ~= upper(string(entry.writer))
    error('storage:writerMismatch', '%s names a different writer than its folder.', f);
end
list = raw.stores;
if ~iscell(list), list = num2cell(list); end

% Normalise every store to the same fields
st = repmat(v1, 1, numel(list));
for k = 1:numel(list)
    e = list{k};
    st(k).kind = string(e.kind);
    st(k).priority = double(e.priority);
    for fld = ["host" "dbname" "table" "path"]
        if isfield(e, fld), st(k).(fld) = string(e.(fld)); else, st(k).(fld) = ""; end
    end
end
[~, o] = sort([st.priority]);
st = st(o);

% Priorities: unique, exactly one primary, Excel never primary
if numel(unique([st.priority])) < numel(st) || nnz([st.priority] == 1) ~= 1
    error('storage:priority', '%s: priorities must be unique, with exactly one priority 1.', f);
end
if st(1).kind == "excel"
    error('storage:excelPrimary', '%s: an Excel store can be a mirror only, never priority 1.', f);
end

% File stores stay inside the computer's own Results folder
for k = find([st.kind] ~= "mysql")
    if ~startsWith(replace(st(k).path, "\", "/"), "Results/" + string(entry.writer) + "/")
        error('storage:path', '%s: store paths must be under Results/%s/.', f, entry.writer);
    end
end

% Built kinds; a file primary has file mirrors only (storage step 6b)
bad = setdiff([st.kind], ["mysql" "sqlite" "text" "excel"]);
if ~isempty(bad)
    error('storage:kindNotBuilt', '%s: store kind "%s" is not built yet.', f, bad(1));
end
if st(1).kind ~= "mysql" && any([st.kind] == "mysql")
    error('storage:kindNotBuilt', '%s: a MySQL mirror under a %s primary is not built.', f, st(1).kind);
end

% A file store holds one table, sim_lookup
for k = find([st.kind] ~= "mysql")
    st(k).table = "sim_lookup";
end
if strlength(v1.dbname) > 0 && st(1).kind ~= "mysql"
    error('storage:registryMismatch', '%s: the registry gives this computer a MySQL database (%s) but its primary is %s.', ...
        f, v1.dbname, st(1).kind);
end
if strlength(v1.dbname) > 0 && (st(1).host ~= v1.host || st(1).dbname ~= v1.dbname || st(1).table ~= v1.table)
    error('storage:registryMismatch', ['%s: the primary store (%s, %s.%s) differs from the registry entry ' ...
        '(%s, %s.%s).'], f, st(1).host, st(1).dbname, st(1).table, v1.host, v1.dbname, v1.table);
end
end

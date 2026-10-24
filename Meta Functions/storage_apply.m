function out = storage_apply(V, host)
% STORAGE_APPLY  Save the GUI Storage panel's store list as this computer's stores.json.
%
%   out = storage_apply(V)        this computer (COMPUTERNAME)
%   out = storage_apply(V, host)
%
%   Storage step 7a (notes/STORAGE_BACKENDS_PLAN.md, sections 8 and 13b).
%   V is a storage_view table after the user's edits: ticked rows other than
%   the primary become the mirrors, in their "order", given priorities 2, 3,
%   ... The primary is kept as it is (changing it is a migration).
%
%   Order of the steps, so a collector running meanwhile never writes to a
%   mirror that should get no writes:
%     1. status entries are written under the NEW keys first (store_key
%        includes the priority): a new SQLite or text mirror is stale, "new,
%        not built", until store_resync builds it; a kept mirror carries
%        its stale flag to its new key;
%     2. stores.json is written to a temporary name and moved over the old
%        one, then checked with machine_stores; if that fails the old file
%        is put back and the error is rethrown;
%     3. status entries under keys that no longer exist are removed.
%   Removing a mirror only drops it from the list: its files stay on disk.
%
%   OUTPUT:
%     out: struct with fields changed (logical), new_mirrors (machine_stores
%          elements of new SQLite/text mirrors, to build with store_resync),
%          new_excel (new Excel mirrors, written by the next store_flush),
%          others_running (other MATLAB processes seen on this computer: a
%          rebuild must wait for them, under the hold).
%
%   LIMITS: only this computer's own Results/<host>/stores.json is written
%   (user decision F). File paths must lie under Results/<host>/.

% This computer's entry, current stores and the file
if nargin < 2, host = host_id(); end
host = upper(string(host));
reg = db_registry();
k = find([reg.role] == "machine" & [reg.writer] == host, 1);
assert(~isempty(k), 'storage:noEntry', 'This computer (%s) has no machine entry in db_sources.json.', host);
old = machine_stores(reg(k));
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
f = fullfile(root, 'Results', char(host), 'stores.json');

% The new list: the primary unchanged, then the ticked mirrors in their order
M = V(V.use & ~V.locked, :);
[~, o] = sort(M.order);
M = M(o, :);
assert(numel(unique(M.location)) == height(M), 'storage:duplicateStore', 'Two stores share one location.');
new = old(1);
for i = 1:height(M)
    s = old(1);
    s.kind = M.kind(i); s.priority = i + 1;
    j = find([old.kind] == s.kind & wheres(old) == M.location(i), 1);
    if ~isempty(j)
        s = old(j); s.priority = i + 1;
    elseif s.kind == "mysql"
        error('storage:newMysqlMirror', 'A MySQL mirror can not be added from the panel.');
    else
        [s.host, s.dbname] = deal(""); s.table = "sim_lookup"; s.path = M.location(i);
    end
    new(end+1) = s; %#ok<AGROW>
end
out = struct('changed', ~isequal(arrayfun(@store_key, old, 'UniformOutput', false), arrayfun(@store_key, new, 'UniformOutput', false)), ...
    'new_mirrors', new([]), 'new_excel', new([]), 'others_running', other_matlabs());
if ~out.changed, return; end

% 1. Status under the new keys: new file mirrors stale until built, kept mirrors keep their flags
S = store_status(host);
added = strings(0, 1);
for i = 2:numel(new)
    j = find([old.kind] == new(i).kind & wheres(old) == where(new(i)), 1);
    nk = string(store_key(new(i)));
    if isempty(j)
        if new(i).kind == "excel"
            out.new_excel(end+1) = new(i);
            continue
        end
        out.new_mirrors(end+1) = new(i);
        store_status(host, nk, struct('stale', true, 'reason', "new, not built", 'first_uid', "", 'time', now_text()));
        added(end+1) = nk; %#ok<AGROW>
    else
        e = find(strcmp({S.key}, char(store_key(old(j)))), 1);
        if ~isempty(e) && nk ~= string(S(e).key)
            store_status(host, nk, rmfield(S(e), 'key'));
            added(end+1) = nk; %#ok<AGROW>
        end
    end
end

% 2. stores.json via a temporary file; checked, and put back on failure
prev = "";
if isfile(f), prev = string(fileread(f)); end
write_atomic(f, stores_json(host, new));
try
    machine_stores(reg(k));
catch ME
    if strlength(prev) > 0, write_atomic(f, prev); else, delete(f); end
    for a = added', store_status(host, a, []); end
    rethrow(ME);
end

% 3. Status entries under keys that are gone
keep = string(arrayfun(@store_key, new, 'UniformOutput', false));
for i = 1:numel(old)
    ok = string(store_key(old(i)));
    if ~any(keep == ok) && any(strcmp({S.key}, char(ok))), store_status(host, ok, []); end
end
end

function w = wheres(st)
% Every store's location in a list, as a string array.
w = strings(1, numel(st));
for i = 1:numel(st), w(i) = where(st(i)); end
end

function w = where(s)
% A store's location as shown in the panel.
if s.kind == "mysql", w = s.host + "/" + s.dbname + "." + s.table; else, w = s.path; end
end

function t = stores_json(host, st)
% The stores.json text for a store list.
L = cell(1, numel(st));
for i = 1:numel(st)
    if st(i).kind == "mysql"
        L{i} = struct('kind', st(i).kind, 'priority', st(i).priority, 'host', st(i).host, 'dbname', st(i).dbname, 'table', st(i).table);
    else
        L{i} = struct('kind', st(i).kind, 'priority', st(i).priority, 'path', st(i).path);
    end
end
t = string(jsonencode(struct('writer', host, 'stores', {L}), 'PrettyPrint', true));
end

function write_atomic(f, t)
% Write text to a temporary name, then move it over the file.
tmp = sprintf('%s.tmp.%d', f, feature('getpid'));
fid = fopen(tmp, 'w'); fwrite(fid, char(t), 'char'); fclose(fid);
movefile(tmp, f, 'f');
end

function n = other_matlabs()
% MATLAB processes on this computer other than this one (possible collectors).
n = 0;
try
    if ispc
        [~, o] = system('tasklist /FI "IMAGENAME eq MATLAB.exe" /NH /FO CSV');
        lines = regexp(string(o), '"MATLAB\.exe","(\d+)"', 'tokens');
        pids = cellfun(@(c) double(c{1}), lines);
    else
        % Linux: the MATLAB processes of any user on this computer
        [~, o] = system('pgrep -x MATLAB');
        pids = str2double(splitlines(strtrim(string(o))));
        pids = pids(~isnan(pids));
    end
    n = nnz(pids ~= feature('getpid'));
catch
end
end

function t = now_text()
% The time as stored in store_status.
t = string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
end

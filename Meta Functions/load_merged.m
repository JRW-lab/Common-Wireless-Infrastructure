function [T, conn, ok, info] = load_merged(conn, dbname, table_name, hash_list, T_prev, maxWaitSeconds)
% LOAD_MERGED  Load results from every registered source, merged by param_hash.
%
%   [T,conn,ok,info] = load_merged(conn,dbname,table_name,hash_list,T_prev)
%   [T,conn,ok,info] = load_merged(...,maxWaitSeconds)
%
%   Drop-in replacement for mysql_load_resilient in readers: figures,
%   tables and frame-target checks (Phase 1 of notes/PER_MACHINE_DB_PLAN.md).
%   The caller's own source is read exactly as mysql_load_resilient reads
%   it, waiting out a lost connection. Every other source in db_sources.json
%   is then read once with a short timeout, and rows that share a param_hash
%   are combined by merge_rows. With one source, T is the caller's table
%   unchanged, so behaviour matches mysql_load_resilient exactly.
%
%   Writers must not use this: mysql_write's compare-and-swap needs the
%   writer's own row, not the merged one.
%
%   INPUTS:
%     conn, dbname, table_name, hash_list, T_prev, maxWaitSeconds:
%         as for mysql_load_resilient. hash_list may be "*".
%
%   OUTPUTS:
%     T:    results table, one row per param_hash, columns as mysql_load
%     conn: the caller's connection, refreshed if it was lost
%     ok:   false when the caller's own source could not be read in time
%           (T is then T_prev, as for mysql_load_resilient)
%     info: struct with fields
%             sources     names of the sources read, own first
%             unreachable names of sources that could not be read
%             partial     true when any source was unreachable
%             frames      table: param_hash and frames per source
%
%   A computer whose primary is SQLite or text (storage step 6b) passes
%   dbname "" and the store's open handle as conn: its own rows are read
%   live from the primary alone, and an unreadable primary is an error
%   (storage:ownPrimaryUnreadable), never a mirror, so a collector stops
%   rather than undercount.
%
%   LIMITS: other sources are read without retries, so a source that is
%   down drops its frames from T (with a warning and info.partial) rather
%   than stalling a figure. Notes: load_merged_NOTES.md.

% A computer without MySQL: its own file primary, read live; a failure stops the caller (storage step 6b)
if nargin < 5, T_prev = table; end
if nargin < 6, maxWaitSeconds = []; end
own_file = strlength(string(dbname)) == 0 && (isa(conn, 'sqlite') || isstruct(conn));
info = struct('sources', strings(1, 0), 'unreachable', strings(1, 0), 'partial', false, 'frames', table);
info.used = struct('name', {}, 'key', {}, 'kind', {}, 'fallback', {}, 'file_time', {}, 'status_time', {});
if own_file
    src = db_sources("", table_name);
    [T, u] = store_read(src(1), hash_list, "own");
    ok = true;
    info.used(end+1) = used_entry(src(1).name, u);
else
    % Read the caller's own source exactly as before
    [T, conn, ok] = mysql_load_resilient(conn, dbname, table_name, hash_list, T_prev, maxWaitSeconds);

    % An empty dbname means the caller reconnects off the handle; name it the same way
    if strlength(string(dbname)) == 0 && ~isempty(conn) && isvalid(conn)
        try
            dbname = string(conn.DataSource);
        catch
        end
    end
    src = db_sources(dbname, table_name);
end
info.sources = [src.name];

% Own MySQL source unreadable: when this computer has mirrors, read the first usable one live (storage step 6a)
if ~ok && src(1).role == "machine" && numel(src(1).stores) > 1
    try
        [T, u] = store_read(src(1), hash_list, true);
        ok = true;
        info.used(end+1) = used_entry(src(1).name, u);
        warning('load_merged:ownFallback', 'Own primary unreadable; read %s instead.', u.key);
    catch
    end
end

% One source, or a stale own table: return it unchanged
if isscalar(src) || ~ok
    info.frames = frames_table({T}, src(1).name);
    return
end

% Read every other source once; one that cannot be read marks T partial
parts = {T};
names = src(1).name;
for k = 2:numel(src)
    try
        if src(k).role == "machine" && ~isempty(src(k).stores)
            % A computer: its first usable store, in priority order (store_read; storage step 6a)
            [Tk, u] = store_read(src(k), hash_list);
            parts{end+1} = Tk; %#ok<AGROW>
            info.used(end+1) = used_entry(src(k).name, u);
            if u.kind == "empty"
                note_empty_once(src(k).name);
            elseif u.fallback
                warning('load_merged:storeFallback', 'Results source "%s" read from %s (file time %s, status %s).', ...
                    src(k).name, u.key, u.file_time, u.status_time);
            end
        else
            parts{end+1} = fetch_source(src(k), hash_list); %#ok<AGROW>
        end
        names(end+1) = src(k).name; %#ok<AGROW>
    catch ME
        warning('load_merged:sourceUnreachable', ...
            'Results source "%s" (%s, %s.%s) was not read: %s. Its frames are missing from this result.', ...
            src(k).name, src(k).host, src(k).dbname, src(k).table, ME.message);
        info.unreachable(end+1) = src(k).name;
        info.partial = true;
    end
end
info.sources = names;
info.frames = frames_table(parts, names);

% Stack the sources' rows over the columns any of them has
A = stack(parts);
if height(A) == 0
    return
end

% Merge each param_hash held by more than one source
h = string(A.param_hash);
[u, first] = unique(h, 'stable');
keep = true(height(A), 1);
for i = 1:numel(u)
    idx = find(h == u(i));
    if numel(idx) > 1
        A(first(i), :) = merge_rows(A(idx, :));
        keep(idx(2:end)) = false;
    end
end
T = A(keep, :);
end

function Tk = fetch_source(s, hash_list)
% Read one registered source with the SQL mysql_load uses, on its own connection.
c = db_source_conn(s);
if iscell(hash_list) || (isstring(hash_list) && ~isscalar(hash_list))
    hs = string(hash_list);
    hs = unique(hs(strlength(hs) > 0));
    if isempty(hs)
        q = sprintf("SELECT * FROM %s WHERE 1=0", s.table);
    else
        q = sprintf("SELECT * FROM %s WHERE param_hash IN (%s)", s.table, strjoin("'" + hs + "'", ','));
    end
elseif string(hash_list) == "*"
    q = sprintf("SELECT * FROM %s", s.table);
else
    q = sprintf("SELECT * FROM %s WHERE param_hash = '%s'", s.table, hash_list);
end
Tk = fetch(c, q);
end

function A = stack(parts)
% Vertically join tables whose column sets differ, filling absent cells.
parts = parts(cellfun(@(t) height(t) > 0, parts));
if isempty(parts), A = table; return; end
cols = parts{1}.Properties.VariableNames;
for k = 2:numel(parts), cols = union(cols, parts{k}.Properties.VariableNames, 'stable'); end

% Give every part every column, empty JSON or NaN where it had none
for k = 1:numel(parts)
    t = parts{k};
    for c = setdiff(cols, t.Properties.VariableNames, 'stable')
        if any(strcmp(c{1}, {'frames_simulated', 'write_seq'}))
            t.(c{1}) = nan(height(t), 1);
        else
            t.(c{1}) = repmat({''}, height(t), 1);
        end
    end
    parts{k} = t(:, cols);
end
A = vertcat(parts{:});
end

function F = frames_table(parts, names)
% Frames per param_hash in each source, for reporting and checks.
F = table;
for k = 1:numel(parts)
    t = parts{k};
    if height(t) == 0, continue; end
    Tk = table(string(t.param_hash), double(t.frames_simulated), ...
        'VariableNames', {'param_hash', char(names(k))});
    if isempty(F), F = Tk; else, F = outerjoin(F, Tk, 'Keys', 'param_hash', 'MergeKeys', true); end
end
end

function e = used_entry(name, u)
% One line of info.used: which store a source was read from.
e = struct('name', string(name), 'key', u.key, 'kind', u.kind, 'fallback', u.fallback, ...
    'file_time', u.file_time, 'status_time', u.status_time);
end

function note_empty_once(name)
% Say once per session that a registered computer has written nothing yet (storage step 6b; not an outage).
persistent seen
if isempty(seen), seen = strings(0, 1); end
if any(seen == string(name)), return; end
seen(end+1) = string(name);
warning('load_merged:sourceEmpty', 'Results source "%s" has no results yet (its stores do not exist); read as empty.', name);
end

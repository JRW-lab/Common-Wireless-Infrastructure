function store_flush(which)
% STORE_FLUSH  Refresh this computer's SQLite snapshots and Excel mirrors now.
%
%   store_flush()          SQLite snapshots and Excel mirrors
%   store_flush("excel")   Excel mirrors only (the GUI's Refresh Excel button)
%
%   A SQLite store refreshes <file>.snapshot at most every 60 s while
%   collecting (store_adapter); collect_profile and sim_head call this at
%   their normal end so the last batches reach other computers through
%   Syncthing without waiting (storage step 6a).
%
%   An Excel mirror (storage step 7a, user decision 2026-10-21) is never
%   written per batch: it is rewritten whole from the primary here, at the
%   normal end of each run and from the GUI. Sheets: sim_lookup (the rows,
%   JSON columns as text), sim_batches (the ledger) and info (writer, time,
%   primary, batch count, frame sum). The workbook is written to a temporary
%   name and renamed over the old one, so a reader never sees half of it.
%
%   Best effort: a store that can't be refreshed is skipped with a warning.
%   An Excel refresh that fails (the file open in Excel, a cell over Excel's
%   32767-character limit) is noted in store_status under "excel|<path>",
%   never as stale: the next refresh rewrites the whole file anyway.

% This computer's stores
if nargin < 1, which = "all"; end
reg = db_registry();
if isempty(reg), return; end
k = find([reg.role] == "machine" & [reg.writer] == host_id(), 1);
if isempty(k), return; end
st = machine_stores(reg(k));

% Force a snapshot of each SQLite store
if string(which) ~= "excel"
    for j = find([st.kind] == "sqlite")
        try
            ad = store_adapter("sqlite");
            c = ad.open(st(j));
            ad.flush(c);
            close(c);
        catch ME
            warning('storage:flushFailed', 'Snapshot of %s not refreshed: %s', st(j).path, ME.message);
        end
    end
end

% Rewrite each Excel mirror from the primary
for j = find([st.kind] == "excel")
    excel_export(st(1), st(j));
end
end

function excel_export(P, X)
% Rewrite one Excel mirror from the primary P; a failure is a note in store_status, never an error.
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
f = fullfile(root, char(X.path));
uid = char(new_batch_uid());
tmp = sprintf('%s.tmp.%d.%s.xlsx', f, feature('getpid'), uid(1:8));
why = "";
try
    % The primary's rows and ledger, and what they cover
    [R, L] = store_dump(P);
    nf = 0; if height(L) > 0, nf = sum(double(L.n_frames)); end
    info = table(host_id(), string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
        string(store_key(P)), height(R), height(L), nf, ...
        'VariableNames', {'writer', 'written_at', 'primary', 'rows', 'batches', 'ledger_frames'});

    % Excel holds at most 32767 characters per cell
    long = longest_text(R, L);
    if long > 32767
        error('storage:excelCellTooLong', 'a cell holds %d characters, over Excel''s 32767 limit', long);
    end

    % Write the workbook under a temporary name, then move it over the old one
    if ~isfolder(fileparts(f)), mkdir(fileparts(f)); end
    writetable(R, tmp, 'Sheet', 'sim_lookup');
    if height(L) > 0, writetable(L, tmp, 'Sheet', 'sim_batches'); end
    writetable(info, tmp, 'Sheet', 'info');
    movefile(tmp, f, 'f');
catch ME
    why = string(ME.message);
end
if isfile(tmp), delete(tmp); end

% Note the result for the GUI's status column (a miss is not a stale flag: the next refresh rewrites everything)
note = "refreshed";
if strlength(why) > 0
    note = "Excel refresh skipped: " + why;
    warning('storage:excelNotRefreshed', 'Excel mirror %s not refreshed: %s', X.path, why);
end
try
    store_status(host_id(), "excel|" + X.path, struct('stale', false, 'reason', note, ...
        'time', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'))));
catch
end
end

function n = longest_text(varargin)
% The longest text cell in the given tables.
n = 0;
for t = varargin
    T = t{1};
    for v = string(T.Properties.VariableNames)
        x = T.(v);
        if iscell(x) || isstring(x)
            s = string(x); s(ismissing(s)) = "";
            if ~isempty(s), n = max(n, max(strlength(s))); end
        end
    end
end
end

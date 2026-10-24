function V = storage_view(host)
% STORAGE_VIEW  This computer's result stores as rows for the GUI's Storage panel.
%
%   V = storage_view()        this computer (COMPUTERNAME)
%   V = storage_view(host)
%
%   Storage step 7a (notes/STORAGE_BACKENDS_PLAN.md, section 8 and 13b).
%   One row per store in priority order, then one unchecked row for each of
%   SQLite, text and Excel that the computer doesn't have yet, with a default
%   path, so ticking it and pressing Apply adds it (storage_apply).
%
%   OUTPUT:
%     V: table with columns use (logical), order (double), kind, location,
%        status (strings) and locked (true for the primary, which the panel
%        can't change: changing the primary is a migration). Empty when this
%        computer has no machine entry in the registry.
%
%   LIMITS: read only. Status comes from Results/<host>/store_status.json
%   (stale flags, snapshot and Excel notes) and the files' times.

% This computer's entry and stores
if nargin < 1, host = host_id(); end
host = upper(string(host));
V = table('Size', [0 6], 'VariableTypes', {'logical', 'double', 'string', 'string', 'string', 'logical'}, ...
    'VariableNames', {'use', 'order', 'kind', 'location', 'status', 'locked'});
reg = db_registry();
if isempty(reg), return; end
k = find([reg.role] == "machine" & [reg.writer] == host, 1);
if isempty(k), return; end
st = machine_stores(reg(k));
S = store_status(host);
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));

% The stores it has, in priority order, with their status
for j = 1:numel(st)
    s = st(j);
    if s.kind == "mysql", loc = s.host + "/" + s.dbname + "." + s.table; else, loc = s.path; end
    V(end+1, :) = {true, s.priority, s.kind, loc, status_text(s, S, root, j == 1), j == 1}; %#ok<AGROW>
end

% A row for each file kind it doesn't have yet, unticked, with a default path
defaults = ["sqlite" "results.sqlite"; "text" "results_text"; "excel" "results.xlsx"];
for d = 1:size(defaults, 1)
    if any([st.kind] == defaults(d, 1)), continue; end
    V(end+1, :) = {false, height(V) + 1, defaults(d, 1), "Results/" + host + "/" + defaults(d, 2), "not used", false}; %#ok<AGROW>
end
end

function t = status_text(s, S, root, primary)
% One store's status: primary, OK or STALE (reason), plus its last snapshot or Excel note and file time.
key = store_key(s);
i = find(strcmp({S.key}, key), 1);
if primary
    t = "primary";
elseif ~isempty(i) && S(i).stale
    t = "STALE: " + string(S(i).reason);
else
    t = "OK";
end

% The last snapshot or Excel refresh note, and the file's time
if s.kind ~= "mysql"
    n = find(strcmp({S.key}, char("snapshot|" + s.path)) | strcmp({S.key}, char("excel|" + s.path)), 1);
    if ~isempty(n), t = t + "; " + string(S(n).reason) + " " + string(S(n).time); end
    f = fullfile(root, char(s.path));
    if s.kind == "text", f = fullfile(f, 'batches.jsonl'); end
    info = dir(f);
    if isscalar(info)
        t = t + "; file " + string(datetime(info.datenum, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd HH:mm'));
    else
        t = t + "; no file yet";
    end
end
end

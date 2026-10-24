function reg = db_registry()
% DB_REGISTRY  The results-source registry, db_sources.json, as a struct array.
%
%   reg = db_registry()
%
%   Every machine writes its results to its own database, and readers merge
%   all of them (notes/PER_MACHINE_DB_PLAN.md). db_sources.json at the
%   project root lists those databases, says which server holds each, and
%   says which machine writes to each. This function reads and validates
%   it; db_sources (readers), db_target (writers) and db_creds (mysql_login)
%   all go through here, so they cannot disagree about the registry.
%
%   OUTPUT:
%     reg: struct array with fields name, host, dbname, table, role, writer,
%          or [] when there is no registry (the behaviour before it existed).
%          role is "legacy" (shared table; machines without their own entry
%          write here), "legacy-frozen" (read only) or "machine" (writer =
%          the COMPUTERNAME that writes to it). lane_base is a machine's
%          Phase 3 lane block (NaN when absent); bases must be distinct.
%
%   LIMITS: dbname must be unique across entries, because mysql_login finds
%   a database's server from its name alone. Format: notes
%   load_merged_NOTES.md S1.

% The registry sits at the project root, three levels above this file
reg = [];
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
reg_file = fullfile(root, 'db_sources.json');
if ~isfile(reg_file)
    return
end

% Decode it; an unreadable or empty registry is an error, not a fallback
raw = jsondecode(fileread(reg_file));
if ~isfield(raw, 'sources') || isempty(raw.sources)
    error('db_registry:empty', 'db_sources.json at %s lists no sources.', root);
end
list = raw.sources;
if ~iscell(list), list = num2cell(list); end

% Normalise every entry to strings, with writer "" where absent (entries with different fields decode as a cell)
reg = repmat(struct('name', "", 'host', "", 'dbname', "", 'table', "", 'role', "", 'writer', "", 'lane_base', NaN), 1, numel(list));
for k = 1:numel(list)
    e = list{k};
    for f = ["name" "host" "dbname" "table" "role"]
        % A machine without MySQL may omit host, dbname and table; its Results/<writer>/stores.json names its stores (STORAGE plan 12 F)
        if isfield(e, f), reg(k).(f) = string(e.(f)); end
    end
    if isfield(e, 'writer') && ~isempty(e.writer)
        reg(k).writer = upper(string(e.writer));
    end

    % Phase 3 lane base of a machine entry, NaN when absent (PER_MACHINE_DB_PLAN.md 6.3a)
    if isfield(e, 'lane_base') && ~isempty(e.lane_base)
        reg(k).lane_base = double(e.lane_base);
    end
end

% Reject entries that would route writes or reads ambiguously
roles = [reg.role];
if any(~ismember(roles, ["legacy" "legacy-frozen" "machine"]))
    error('db_registry:role', 'db_sources.json: role must be legacy, legacy-frozen or machine.');
end
if any(roles == "machine" & [reg.writer] == "")
    error('db_registry:writer', 'db_sources.json: every machine entry needs a writer (its COMPUTERNAME).');
end
% Only a machine may omit its dbname; named databases must be unique
if any(roles ~= "machine" & strlength([reg.dbname]) == 0)
    error('db_registry:noDbname', 'db_sources.json: the legacy entry needs host, dbname and table.');
end
named = [reg.dbname]; named = named(strlength(named) > 0);
if numel(unique(named)) < numel(named) || nnz(roles ~= "machine") > 1
    error('db_registry:duplicate', ['db_sources.json: each dbname may appear once, ' ...
        'and there may be one legacy entry.']);
end
w = [reg(roles == "machine").writer];
if numel(unique(w)) < numel(w)
    error('db_registry:twoWriters', 'db_sources.json: a machine may write to one database only.');
end

% Two machines with one lane base would draw the same Phase 3 frames
lb = [reg.lane_base]; lb = lb(~isnan(lb));
if numel(unique(lb)) < numel(lb) || any(lb < 1 | lb ~= fix(lb) | lb >= 2^19)
    error('db_registry:laneBase', 'db_sources.json: lane_base must be a distinct integer in 1..2^19-1 per machine.');
end
end

function t = db_target()
% DB_TARGET  The results database this machine writes to.
%
%   t = db_target()
%
%   Phase 2 of notes/PER_MACHINE_DB_PLAN.md: every machine writes to its own
%   database, and readers merge them all (load_merged). Writers (sim_head,
%   collect_profile) call this once to learn where to write:
%     1. the registry's machine entry whose writer is this COMPUTERNAME;
%     2. otherwise the legacy entry, while its role is "legacy";
%     3. otherwise an error, so nothing is written to a frozen table or to a
%        database no reader knows about.
%   With no registry it returns comm_database.sim_lookup, the target before
%   the registry existed.
%
%   OUTPUT:
%     t: struct with name, dbname, table, role, kind (the primary store's
%        kind) and store (the primary, a machine_stores element, or [] for
%        legacy). A computer without MySQL (storage step 6b) has kind
%        "sqlite" or "text", dbname "" and table "sim_lookup"; open it with
%        store_connect(t).
%
%   LIMITS: COMPUTERNAME is compared case-insensitively. Switching a machine
%   to its own database is adding its entry to db_sources.json; its running
%   collectors switch at their next collect_profile run.

% No registry: the single shared table
reg = db_registry();
if isempty(reg)
    t = struct('name', "legacy", 'dbname', "comm_database", 'table', "sim_lookup", 'role', "legacy", 'kind', "mysql", 'store', []);
    return
end

% This machine's own database, if it has one
me = host_id();
k = find([reg.role] == "machine" & [reg.writer] == me, 1);

% Otherwise the shared table, unless it has been frozen
if isempty(k)
    k = find([reg.role] == "legacy", 1);
end
if isempty(k)
    error('db_target:noTarget', ['This machine (%s) has no database in db_sources.json and the ' ...
        'legacy table is frozen, so there is nowhere to write. Add a machine entry for it.'], me);
end
t = struct('name', reg(k).name, 'dbname', reg(k).dbname, 'table', reg(k).table, 'role', reg(k).role, 'kind', "mysql", 'store', []);

% A machine writes to its primary store (Results/<writer>/stores.json, else the entry itself; machine_stores)
if reg(k).role == "machine"
    st = machine_stores(reg(k));
    t.dbname = st(1).dbname;
    t.table = st(1).table;
    t.kind = st(1).kind;
    t.store = st(1);
end
end

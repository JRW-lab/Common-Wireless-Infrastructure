function creds = db_creds(dbname, base)
% DB_CREDS  Server and credentials for a results database.
%
%   creds = db_creds(dbname)
%   creds = db_creds(dbname, base)
%
%   With per-machine databases (notes/PER_MACHINE_DB_PLAN.md) the databases
%   live on different servers, but code everywhere reconnects by database
%   NAME (mysql_login(dbname), mysql_ensure_conn, mysql_load's self-heal).
%   This function maps the name to its server through db_sources.json, then
%   picks the account for that server from mysql_local.json.
%
%   INPUTS:
%     dbname: database name, e.g. "comm_database_laptop"
%     base:   mysql_local.json as get_mysql_credentials returns it
%             (optional; read here when omitted)
%
%   OUTPUT:
%     creds: struct with host, user, password. A database the registry does
%            not list keeps base.host, so behaviour without a registry, and
%            for other databases such as med_database, is unchanged.
%
%   LIMITS: mysql_local.json may carry "hosts": [{host, user, password}] for
%   a server whose account differs; otherwise the top-level user and
%   password are used on every server (notes load_merged_NOTES.md S2).

% Start from this machine's mysql_local.json
if nargin < 2, base = get_mysql_credentials(); end
creds = base;
if isempty(base)
    return
end

% The registry names the server that holds this database
reg = db_registry();
if ~isempty(reg)
    k = find([reg.dbname] == string(dbname), 1);
    if ~isempty(k), creds.host = char(reg(k).host); end

    % A database named only in a machine's stores.json (an entry without dbname) is found there
    if isempty(k)
        for m = find([reg.role] == "machine" & strlength([reg.dbname]) == 0)
            st = machine_stores(reg(m));
            j = find([st.kind] == "mysql" & [st.dbname] == string(dbname), 1);
            if ~isempty(j), creds.host = char(st(j).host); break; end
        end
    end
end

% A per-server account overrides the default one
if isfield(base, 'hosts') && ~isempty(base.hosts)
    hs = base.hosts;
    if iscell(hs), hs = [hs{:}]; end
    k = find(string({hs.host}) == string(creds.host), 1);
    if ~isempty(k)
        creds.user = hs(k).user;
        creds.password = hs(k).password;
    end
end
if isfield(creds, 'hosts'), creds = rmfield(creds, 'hosts'); end
end

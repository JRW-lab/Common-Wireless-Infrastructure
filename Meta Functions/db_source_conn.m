function c = db_source_conn(s)
% DB_SOURCE_CONN  A live connection to a registered results source, without retries.
%
%   c = db_source_conn(s)
%
%   load_merged and delete_merged read or change sources other than the
%   caller's own. A source can be a different machine that is switched off,
%   so this connects once with a 5 s timeout instead of mysql_login's
%   retry loop (connectWithRetry waits up to 25 minutes). Connections are
%   kept per source for the MATLAB session and checked with a round trip
%   before reuse.
%
%   INPUT:
%     s: one element of db_sources (fields host, dbname).
%
%   OUTPUT:
%     c: open database connection; errors when the source cannot be reached.
%
%   LIMITS: the timeout is set in the JDBC host spec, since database()
%   appends the database name to the URL (notes load_merged_NOTES.md S2).

% Reuse this session's connection while it still answers
persistent pool
if isempty(pool), pool = containers.Map('KeyType', 'char', 'ValueType', 'any'); end
key = char(s.host + "|" + s.dbname);
if isKey(pool, key) && mysql_conn_is_live(pool(key))
    c = pool(key);
    return
end

% The account for this source's server
creds = db_creds(s.dbname);
if isempty(creds)
    error('db_source_conn:noCredentials', 'MySQL is not configured on this machine (no mysql_local.json).');
end

% One attempt: 5 s to connect, and 30 s for any read, so a host that stalls mid-query fails instead of hanging (notes S7)
url = sprintf('jdbc:mysql://address=(host=%s)(port=3306)(connectTimeout=5000)(socketTimeout=30000)/%s', s.host, s.dbname);
c = database(char(s.dbname), creds.user, creds.password, 'com.mysql.cj.jdbc.Driver', url);
if ~isopen(c)
    error('db_source_conn:connect', '%s', c.Message);
end
pool(key) = c;
end

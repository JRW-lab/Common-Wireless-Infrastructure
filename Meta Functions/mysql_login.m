function conn = mysql_login(dbname)

driver = 'com.mysql.cj.jdbc.Driver';
port = 3306;

% Resolve this machine's MySQL credentials (prompts once on first use;
% cached locally afterward). Returns [] if MySQL is disabled.
creds = get_mysql_credentials();
if isempty(creds)
    error("MySQL is not configured for this project - delete mysql_local.json to re-run setup, or disable 'Enable MySQL' to use local Excel storage only.");
end

% Reuse a live connection across calls in this MATLAB session instead of
% opening a fresh TCP + auth handshake (plus, on servers without
% skip-name-resolve, a reverse-DNS lookup) on every single Simulate /
% Generate Figure click. Callers that hit a stale/dead connection already
% detect it via isopen(...) and re-call mysql_login to recover, so this
% is a drop-in speedup, not a behavior change.
% ---------------------------------------------------------------------
% THE CACHE MUST BE VALIDATED WITH A ROUND TRIP, NOT WITH isopen().
%
% isopen() inspects the CLIENT-side handle only. When MySQL closes an idle
% connection server-side (wait_timeout, 8 hours by default) the client has
% no idea: isopen() still returns true, this function hands back a dead
% handle, and the caller's first fetch throws
%
%   "The last packet successfully received from the server was 42,851,106
%    milliseconds ago ... is longer than the server configured value of
%    'wait_timeout'"
%
% which is exactly the "open the GUI the next morning, hit Generate Figure,
% get an error, click it again and it works" symptom. It worked on the
% second click only because the failed attempt happened to leave the cache
% in a state that forced a genuine reconnect -- not by design.
%
% The comment that used to sit here claimed "callers already detect a
% stale connection via isopen(...) and re-call mysql_login to recover".
% That was wrong, and it is why the bug survived: every layer trusted a
% check that cannot see a server-side close.
%
% A SELECT 1 is a sub-millisecond round trip on the LAN, against the TCP
% connect + auth + (without skip-name-resolve) reverse-DNS lookup this
% cache exists to avoid. Validating is far cheaper than what it saves.
% ---------------------------------------------------------------------
persistent cached_conn cached_dbname
if ~isempty(cached_conn) && isequal(cached_dbname, dbname) && isopen(cached_conn)
    if mysql_conn_is_live(cached_conn)
        conn = cached_conn;
        return;
    end
    % Dead server-side. Drop it and fall through to a real reconnect.
    try, close(cached_conn); catch, end
    cached_conn = [];
    cached_dbname = [];
end

% Auto-provision the schema the first time this account connects to a
% fresh MySQL server (a plain `database(dbname,...)` call below fails
% outright if dbname doesn't exist yet). This opens a second, throwaway
% connection just to run CREATE DATABASE IF NOT EXISTS, so it's cached
% per dbname for the rest of the MATLAB session instead of paying that
% extra round trip on every single mysql_login call (every Simulate /
% Generate Figure click).
persistent schema_ready
if isempty(schema_ready)
    schema_ready = containers.Map('KeyType', 'char', 'ValueType', 'logical');
end
if ~isKey(schema_ready, char(dbname))
    try
        admin_conn = database('information_schema', creds.user, creds.password, driver, ...
            sprintf('jdbc:mysql://%s:%d/information_schema', creds.host, port));
        if isopen(admin_conn)
            execute(admin_conn, "CREATE DATABASE IF NOT EXISTS " + dbname);
            close(admin_conn);
        end
    catch
        % Schema may already exist, or this account may lack CREATE privileges -
        % fall through and let the real connection attempt below report the
        % actual problem.
    end
    schema_ready(char(dbname)) = true;
end

dburl = sprintf('jdbc:mysql://%s:%d/%s', creds.host, port, dbname);
conn = connectWithRetry(dbname, creds.user, creds.password, driver, dburl);

% Connection Check
if ~isopen(conn)
    error("Failure to form connection to MySQL database...");
end

cached_conn = conn;
cached_dbname = dbname;

function [sim_result, conn] = mysql_load(conn,table_name,paramHash)
% MYSQL_LOAD Fetch rows from table_name by param_hash.
%
%   paramHash == "*"        -> every row (use sparingly - now that every
%                               project shares one table, this scans the
%                               full accumulated history of all of them)
%   paramHash == a hash      -> that one row
%   paramHash == cell/string array of hashes -> just those rows, via a
%                               param_hash IN (...) lookup against the
%                               table's primary key (fast regardless of
%                               how large the shared table has grown)

if (iscell(paramHash) || (isstring(paramHash) && ~isscalar(paramHash)))
    hashes = cellstr(paramHash);
    hashes = unique(hashes(~cellfun(@isempty, hashes)));
    if isempty(hashes)
        sqlquery_results = sprintf("SELECT * FROM %s WHERE 1=0", table_name);
    else
        quoted = strjoin("'" + string(hashes) + "'", ',');
        sqlquery_results = sprintf("SELECT * FROM %s WHERE param_hash IN (%s)", ...
            table_name, quoted);
    end
elseif paramHash ~= "*"
    sqlquery_results = sprintf("SELECT * FROM %s WHERE param_hash = '%s'", ...
        table_name,paramHash);
else
    sqlquery_results = sprintf("SELECT * FROM %s", ...
        table_name);
end
% ---------------------------------------------------------------------
% SELF-HEAL A SERVER-SIDE-CLOSED CONNECTION, ONCE.
%
% mysql_login now validates its cached connection with a real round trip,
% which fixes the GUI case (every button press goes through it). But a
% long-running process -- sim_head holds one `conn` for hours, and the
% collectors for most of a day -- passes its own handle straight in here
% and never revisits mysql_login. MySQL closes an idle connection after
% `wait_timeout` (8 h default), so those callers can still be holding a
% corpse.
%
% Retry ONLY on connection-shaped failures. A blanket retry would silently
% re-run genuine SQL errors and hide real bugs behind a second identical
% failure, which is worse than the original problem.
%
% The refreshed connection comes back as an optional SECOND OUTPUT. Callers
% that capture it stop paying a failed fetch per call; callers that ignore
% it still get correct data, because mysql_login's cache has been refreshed
% as a side effect.
% ---------------------------------------------------------------------
try
    sim_result = fetch(conn, sqlquery_results);
catch ME
    if ~isConnectionFailure(ME)
        rethrow(ME);
    end
    dbname = "";
    try, dbname = string(conn.DataSource); catch, end
    if strlength(dbname) == 0
        rethrow(ME);
    end
    warning("mysql_load:reconnected", ...
        "MySQL connection was closed server-side (likely wait_timeout); reconnected and retried.");
    try, close(conn); catch, end
    conn = mysql_login(dbname);
    sim_result = fetch(conn, sqlquery_results);
end
end

function tf = isConnectionFailure(ME)
% Signatures MySQL Connector/J uses when the socket is gone. Matched on
% text because the database toolbox collapses them all into one generic
% identifier, so the identifier cannot distinguish them.
% Two distinct families show up, and missing either one reintroduces the
% bug:
%   - Connector/J's own text, which is what the user sees after an
%     overnight idle ("...wait_timeout", "last packet successfully
%     received...").
%   - The database toolbox's terse "Invalid connection.", which is what
%     comes back once the handle has already been marked bad client-side --
%     e.g. after any earlier probe on the same dead socket. The first
%     version of this list had only the first family, so the retry did not
%     fire in exactly that case.
msg = lower(string(ME.message));
needles = ["wait_timeout", "communications link failure", ...
           "no operations allowed after connection closed", ...
           "connection is closed", "last packet successfully received", ...
           "broken pipe", "connection reset", ...
           "invalid connection", "connection is not open", ...
           "closed connection"];
tf = any(arrayfun(@(n) contains(msg, n), needles));
end

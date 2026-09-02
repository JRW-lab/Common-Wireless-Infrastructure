function sim_result = mysql_load(conn,table_name,paramHash)
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
sim_result = fetch(conn, sqlquery_results);

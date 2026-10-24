function conn = mysql_ensure_conn(conn, dbname)
% MYSQL_ENSURE_CONN Return a connection that can actually run a query.
%
%   conn = mysql_ensure_conn(conn, dbname)
%
%   Long-lived callers (sim_head holds one for a whole run, and so does
%   every parfor worker) can be left holding a handle that is bad in three
%   ways, none of which the handle itself reveals:
%
%     hollow   broadcast into a parfor worker. The class crosses the
%              process boundary, the JDBC socket does not: isvalid is
%              true, isopen is false, and queries fail.
%     corpse   MySQL closed the socket server-side after wait_timeout.
%              isopen still reports true. See mysql_conn_is_live.
%     deleted  something already called close() on it. Every property
%              read now throws MATLAB:class:InvalidHandle.
%
%   Taking the database NAME rather than reading conn.DataSource is what
%   makes the deleted case recoverable: a name is always readable, while
%   the property read is itself the error. mysql_login caches per session,
%   so a replacement costs one login per process, not one per query.
%
%   A good handle is returned untouched after a single SELECT 1, cheap
%   enough to call before every query.
%
%   INPUTS:
%     conn:   database handle in any of the above states; may be []
%     dbname: database name used to reconnect

% Keep a handle that still answers
if ~isempty(conn) && isvalid(conn) && isopen(conn) && mysql_conn_is_live(conn)
    return;
end

% Fall back to the handle's own name, which only a non-deleted one has
if isempty(dbname) && ~isempty(conn) && isvalid(conn)
    try
        dbname = string(conn.DataSource);
    catch
    end
end

% Without a name there is nothing to reconnect to
if isempty(dbname)
    error("mysql_ensure_conn:noDatabase", ...
        ["The MySQL connection is unusable and no database name is available " ...
         "to reconnect with. Callers must pass save_data.dbname (or the " ...
         "database name they opened) so recovery does not depend on " ...
         "reading a property off the broken handle."]);
end

% Replace it
conn = mysql_login(dbname);

end

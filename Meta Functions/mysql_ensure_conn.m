function conn = mysql_ensure_conn(conn, dbname)
%MYSQL_ENSURE_CONN  Return a connection that can actually run a query.
%
%   mysql_login both opens a connection and caches one per session. Callers
%   that hold on to its result for a long time - sim_head holds one for the
%   whole length of a run, and every parfor worker ends up holding one too -
%   still have to be handed something usable, because a handle goes bad in
%   three ways that are easy to tell apart from the error message and
%   impossible to tell apart from the handle itself:
%
%     HOLLOW   A `database` object broadcast into a parfor worker. The class
%              definition crosses the process boundary; the JDBC socket does
%              not. On the worker:
%                  isvalid(conn)       -> true
%                  isopen(conn)        -> false
%                  conn.DataSource     -> works, and looks fine
%                  fetch(conn, "...")  -> "Invalid connection."
%                                         (database:database:invalidConnection)
%              Nothing is logged, nothing throws on the client, and the
%              object is simply a shell. Measured on R2024b Update 2 /
%              Database Toolbox 24.2 with a process-based local pool - do not
%              assume it, it is exactly the case that is invisible until a
%              query fails.
%
%     CORPSE   MySQL closed the socket server-side (wait_timeout, 8 h by
%              default). isopen still returns true, because that only
%              inspects the client-side handle. See mysql_conn_is_live.
%
%     DELETED  A previous recovery attempt called close() on it - notably
%              mysql_load's own self-heal, which closes before reconnecting.
%              isvalid is now false and every property read throws
%              MATLAB:class:InvalidHandle ("Invalid or deleted object.").
%
%   WHY THIS FUNCTION EXISTS. The obvious way to recover any of the three is
%
%       catch
%           conn = mysql_login(conn.DataSource);
%       end
%
%   and that idiom cannot recover a DELETED handle, because reading
%   .DataSource off one is itself the error. So a caller holding a DELETED
%   handle has a recovery block that is guaranteed to throw, and the error
%   the user sees is "Invalid or deleted object." pointing at the recovery
%   line rather than at the query that actually failed. That is the whole
%   reason a real failure gets reported as a nonsensical one.
%
%   Taking the database NAME as an argument sidesteps all of it: a name is a
%   string, it is always available, and mysql_login's per-session cache means
%   the replacement costs one login per process, not one per query.
%
%   A handle that is still good is returned untouched after a single SELECT 1,
%   so this is cheap enough to call before every query - one sub-millisecond
%   round trip on the LAN, nothing against the query that follows, and the
%   only way to notice a server-side close before it turns into a confusing
%   error three layers away.
%
%   conn may be [] (an Excel-only run, or a worker that has not connected
%   yet); the result is then a fresh connection.

if ~isempty(conn) && isvalid(conn) && isopen(conn) && mysql_conn_is_live(conn)
    return;
end

if isempty(dbname) && ~isempty(conn) && isvalid(conn)
    % Last resort: a hollow handle still reports its database even though it
    % cannot use it. A DELETED one cannot, which is the whole reason dbname
    % is an argument.
    try
        dbname = string(conn.DataSource);
    catch
    end
end
if isempty(dbname)
    error("mysql_ensure_conn:noDatabase", ...
        ["The MySQL connection is unusable and no database name is available " ...
         "to reconnect with. Callers must pass save_data.dbname (or the " ...
         "database name they opened) so recovery does not depend on " ...
         "reading a property off the broken handle."]);
end

conn = mysql_login(dbname);
end

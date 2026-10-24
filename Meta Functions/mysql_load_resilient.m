function [T, conn, ok] = mysql_load_resilient(conn, dbname, table_name, hash_list, T_prev, maxWaitSeconds)
% MYSQL_LOAD_RESILIENT Load results, waiting out a lost connection.
%
%   [T,conn,ok] = mysql_load_resilient(conn,dbname,table_name,hash_list,T_prev)
%   [T,conn,ok] = mysql_load_resilient(...,maxWaitSeconds)
%
%   Replaces the catch-and-reconnect idiom
%       catch, conn = mysql_login(conn.DataSource); end
%   which cannot recover the case it exists for: mysql_load's self-heal
%   closes conn before reconnecting, so a failed reconnect leaves the
%   caller holding a deleted handle, and reading .DataSource off one is
%   itself an error. Reconnecting through mysql_ensure_conn uses the
%   database NAME instead, which is always readable.
%
%   Retries until the server returns. Failures that waiting cannot fix
%   stop immediately, see mysql_is_permanent_failure. If a finite budget
%   is exhausted, T_prev is returned with ok = false so an unattended run
%   continues on stale frame counts rather than dying; collected frames
%   are already in the database and counts refresh on the next pass.
%
%   Each attempt is slow to fail, since mysql_login retries internally
%   through connectWithRetry before throwing.
%
%   INPUTS:
%     conn:           database handle, possibly closed or deleted; may be []
%     dbname:         database name used to reconnect
%     table_name:     results table to read
%     hash_list:      param_hash values to fetch, or "*" for all
%     T_prev:         table returned if the wait budget is exhausted
%     maxWaitSeconds: wait budget in seconds, default Inf

% Function setup
if nargin < 5, T_prev = table; end
if nargin < 6 || isempty(maxWaitSeconds), maxWaitSeconds = Inf; end
tStart     = tic;
attempt    = 0;
backoff    = 5;
backoffMax = 120;

% Retry the load until it succeeds or the budget runs out
while true
    attempt = attempt + 1;
    try
        % Reconnect by NAME, then read
        conn = mysql_ensure_conn(conn, dbname);
        T    = mysql_load(conn, table_name, hash_list);
        if attempt > 1
            fprintf('[%s] MySQL reconnected after %d attempt(s), %.1f min down.\n', ...
                string(datetime('now')), attempt, toc(tStart)/60);
        end
        ok = true;
        return;
    catch ME
        % Stop on failures that waiting cannot clear
        if mysql_is_permanent_failure(ME)
            rethrow(ME);
        end

        % Give up only against a finite budget, returning the old table
        elapsed = toc(tStart);
        if elapsed >= maxWaitSeconds
            warning("mysql_load_resilient:gaveUp", ...
                ['MySQL unreachable for %.1f min after %d attempts (%s). ' ...
                 'Continuing on the previous frame counts.'], ...
                elapsed/60, attempt, ME.message);
            T  = T_prev;
            ok = false;
            return;
        end

        % Report and back off before the next attempt
        fprintf('[%s] MySQL unreachable (attempt %d, %.1f min down): %s\n', ...
            string(datetime('now')), attempt, elapsed/60, ME.message);
        pause(backoff);
        backoff = min(backoff*2, backoffMax);
    end
end

end

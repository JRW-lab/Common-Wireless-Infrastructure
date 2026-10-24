function [conn, ok] = mysql_wait_for_conn(conn, dbname, maxWaitSeconds)
% MYSQL_WAIT_FOR_CONN Block until the database is reachable again.
%
%   [conn,ok] = mysql_wait_for_conn(conn,dbname)
%   [conn,ok] = mysql_wait_for_conn(conn,dbname,maxWaitSeconds)
%
%   For callers that must retry an operation after a connection loss but
%   cannot re-run it in a loop. Waiting is separated from retrying so the
%   operation is attempted exactly as many times as before, only now after
%   the server has returned.
%
%   Writes must NOT be looped. mysql_write re-reads frames_simulated on
%   each attempt and stores N_old + new_frames, so repeating a write whose
%   acknowledgement was lost adds the same frames twice. The compare-and-
%   swap guard does not catch this; it protects against other writers, not
%   against this one applying its own delta again. The retry count is
%   therefore a correctness parameter and this function adds none.
%
%   ok is false only when a finite maxWaitSeconds is exhausted.
%
%   INPUTS:
%     conn:           database handle, possibly closed or deleted; may be []
%     dbname:         database name used to reconnect
%     maxWaitSeconds: wait budget in seconds, default Inf

% Function setup
if nargin < 3 || isempty(maxWaitSeconds), maxWaitSeconds = Inf; end
tStart     = tic;
attempt    = 0;
backoff    = 5;
backoffMax = 120;
ok         = false;

% Retry until the server answers or the budget runs out
while true
    attempt = attempt + 1;
    try
        % Reconnect by NAME: a deleted handle throws on any property read
        conn = mysql_ensure_conn(conn, dbname);
        if attempt > 1
            fprintf('[%s] MySQL reachable again after %.1f min (%d attempts).\n', ...
                string(datetime('now')), toc(tStart)/60, attempt);
        end
        ok = true;
        return;
    catch ME
        % Stop on failures that waiting cannot clear
        if mysql_is_permanent_failure(ME)
            rethrow(ME);
        end

        % Give up only against a finite budget
        elapsed = toc(tStart);
        if elapsed >= maxWaitSeconds
            warning("mysql_wait_for_conn:gaveUp", ...
                "MySQL still unreachable after %.1f min: %s", elapsed/60, ME.message);
            return;
        end

        % Report and back off before the next attempt
        fprintf('[%s] Waiting for MySQL (attempt %d, %.1f min down): %s\n', ...
            string(datetime('now')), attempt, elapsed/60, ME.message);
        pause(backoff);
        backoff = min(backoff*2, backoffMax);
    end
end

end

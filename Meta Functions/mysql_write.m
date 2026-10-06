function mysql_write(conn,table_name,parameters,new_frames,metrics_add,varargin)
%MYSQL_WRITE  Accumulate a simulated point's result into the lookup table.
%
%   mysql_write(conn,table,params,new_frames,metrics_add)
%   mysql_write(...,use_mutex)
%   mysql_write(...,use_mutex,metrics_aux_cumulative)
%   mysql_write(...,use_mutex,metrics_aux_cumulative,metrics_aux_delta)
%
%   CONCURRENCY (design A, 2026-10-05). This accumulates with a
%   read-modify-write: it reads frames_simulated, blends metrics_add into
%   the stored average against that count, and writes the total back. With
%   two machines collecting the same point, both could read 300, both
%   write 325, and fifty frames of compute would be recorded as
%   twenty-five -- silently, and with the stored averages describing a
%   frame count that no longer matches the data behind them.
%
%   The write is therefore COMPARE-AND-SWAP: the UPDATE carries
%   "AND frames_simulated = <the value we read>", so it applies only if
%   nothing changed underneath. MySQL's affected-row count (read back via
%   ROW_COUNT() on this same connection, immediately after the UPDATE --
%   it describes the previous statement only) says which happened. Zero
%   means another writer won the race: we re-read, re-merge against the
%   NEW base, and retry after a randomised backoff. Nothing is lost on a
%   lost race -- the frames are still in hand, only the merge arithmetic
%   is redone.
%
%   This is detection, not probability-reduction. Merely re-reading closer
%   to the write would narrow the window without closing it, which turns a
%   reproducible bug into a rare one -- strictly worse, because nobody
%   goes looking for it.
%
%   See notes/DESIGN_concurrent_collection.md in Common Wireless Simulator
%   for the full analysis and the designs not taken.

% Optional mutex locking for multi-process environments
use_mutex = false;
metrics_aux_new = [];
metrics_aux_delta = [];
if ~isempty(varargin)
    use_mutex = varargin{1};
end
if length(varargin) >= 2
    metrics_aux_new = varargin{2};
end
if length(varargin) >= 3
    % PER-BATCH DELTA (optional, added with the CAS change).
    %
    % metrics_aux_new is a CUMULATIVE aggregate: the caller read the row,
    % merged its batch into what it found, and handed us the total. That
    % merge is itself a read-modify-write, performed OUTSIDE this function
    % and therefore outside the CAS guard -- so under concurrency the
    % guard would correct frames_simulated and metrics while metrics_aux
    % silently kept only one writer's history.
    %
    % When the caller also passes its raw per-batch aggregate, we redo the
    % merge HERE, against the row as freshly read inside the retry loop.
    % The whole accumulation then sits under the guard and is correct no
    % matter how many writers collide. Callers that do not pass it keep
    % the previous behaviour exactly (see the conflict handling below).
    metrics_aux_delta = varargin{3};
end

% Ensure metrics_aux column exists - this is called once per simulated
% point per iteration (potentially hundreds of times per run), so cache
% per table_name for the rest of the session instead of re-attempting
% (and failing on "duplicate column") an ALTER TABLE every single call.
persistent metrics_aux_ready
if isempty(metrics_aux_ready)
    metrics_aux_ready = containers.Map('KeyType', 'char', 'ValueType', 'logical');
end
if ~isKey(metrics_aux_ready, char(table_name))
    try
        execute(conn, "ALTER TABLE " + table_name + " ADD COLUMN metrics_aux JSON NULL");
    catch
    end
    metrics_aux_ready(char(table_name)) = true;
end

% Function setup
[paramsJSON,paramHash] = jsonencode_sorted(parameters);

% Retry policy. Bounded, so a pathological case fails loudly rather than
% spinning forever; generous enough that honest contention between a
% handful of machines never exhausts it. Each attempt costs one re-read
% and one merge (milliseconds), not a re-simulation.
MAX_ATTEMPTS = 20;
attempt = 0;
aux_conflict_unresolvable = false;

% Write to database
need_to_write = true;
while need_to_write

    attempt = attempt + 1;
    if attempt > MAX_ATTEMPTS
        error('mysql_write:casRetriesExhausted', ...
            ['Could not commit %d frames for param_hash %s after %d ' ...
             'compare-and-swap attempts. Another writer is updating this ' ...
             'row continuously, or frames_simulated is being changed by ' ...
             'something outside mysql_write. The frames were NOT recorded.'], ...
            new_frames, paramHash, MAX_ATTEMPTS);
    end

    % Check system usage flag (optional mutex)
    if use_mutex
        mysql_flag_id = 0;
        flag_val = mysql_check(conn,mysql_flag_id);
        if flag_val
            waitTime = 1 + (5 - 1) * rand();
            pause(waitTime);
            continue
        end
        mysql_set(conn,mysql_flag_id);
    end

    % Load from DB again
    sim_result = mysql_load(conn,table_name,paramHash);

    if ~isempty(sim_result) % Overwrite row in DB

        % Existing frame count. This is both the merge base and the CAS
        % guard: the UPDATE below commits only while the row still reads
        % N_old, so the average we are about to store always describes
        % exactly the data it was computed from.
        N_old = sim_result.frames_simulated;
        N_total = N_old + new_frames;

        % Decode existing metrics
        old_metrics = jsondecode(sim_result.metrics{1});

        % Initialize new metrics struct
        metrics = struct();

        % Average each metric field
        metric_fields = fieldnames(metrics_add);
        for iField = 1:numel(metric_fields)
            % Weighted average
            field = metric_fields{iField};
            if ~isfield(old_metrics, field)
                % NEW METRIC ON AN EXISTING ROW (guard added 2026-09-20).
                % Previously this threw 'Unrecognized field name' and killed
                % the worker, which meant that ADDING ANY NEW METRIC broke
                % top-up collection on every row collected before it existed
                % -- i.e. essentially the whole table. Hit for real when the
                % t_*cpu* timing metrics were introduced.
                %
                % The new field is seeded from THIS batch alone, because
                % there is no older value to blend with. That is a sound
                % estimator for a per-frame mean (timing, BER, MSE are all
                % stationary across frames, so a subset average is unbiased),
                % but note its effective support is new_frames, not N_total,
                % until enough further batches accumulate. Do NOT substitute
                % 0 for the missing history -- that would silently bias the
                % field toward zero in proportion to how much older data the
                % row already had.
                metrics.(field) = metrics_add.(field);
            else
                metrics.(field) = ...
                    (old_metrics.(field) * N_old + metrics_add.(field) * new_frames) / N_total;
            end
        end

        metricsJSON = jsonencode(metrics);

        % Resolve metrics_aux against the row as just read.
        write_aux = true;
        if ~isempty(metrics_aux_delta)
            % Preferred path: merge the caller's raw batch aggregate into
            % whatever the row holds right now, inside the guarded loop.
            old_aux = [];
            if ismember('metrics_aux', sim_result.Properties.VariableNames) ...
                    && ~ismissing(sim_result.metrics_aux(1)) ...
                    && ~isempty(sim_result.metrics_aux{1})
                old_aux = jsondecode(sim_result.metrics_aux{1});
            end
            metrics_auxJSON = jsonencode(merge_metrics_aux(old_aux, metrics_aux_delta));
        elseif ~isempty(metrics_aux_new)
            % Legacy path: metrics_aux_new is already the cumulative running
            % aggregate from the caller; do NOT re-merge against the table's
            % previous value or it would be double-counted.
            %
            % On attempt 1 that cumulative is trustworthy -- the caller read
            % the row moments ago. After a LOST RACE it is not: it carries
            % the caller's history blended with a base another writer has
            % since replaced, and we cannot recover the batch from it to
            % re-merge. Writing it anyway would overwrite a correct
            % aggregate with one missing the other writer's frames, which is
            % precisely the integrity cross-check metrics_aux exists to
            % provide. So we leave the column untouched instead and say so.
            if attempt > 1
                write_aux = false;
                aux_conflict_unresolvable = true;
            end
            metrics_auxJSON = jsonencode(metrics_aux_new);
        else
            metrics_auxJSON = [];
        end

        % Format and execute SQL update string. The trailing
        % "AND frames_simulated" is the compare-and-swap guard.
        if ~isempty(metrics_auxJSON) && write_aux
            sqlupdate = sprintf("UPDATE %s SET metrics = '%s', metrics_aux = '%s', frames_simulated = %d WHERE param_hash = '%s' AND frames_simulated = %d", ...
                table_name, ...
                metricsJSON, ...
                metrics_auxJSON, ...
                N_total, ...
                paramHash, ...
                N_old);
        else
            sqlupdate = sprintf("UPDATE %s SET metrics = '%s', frames_simulated = %d WHERE param_hash = '%s' AND frames_simulated = %d", ...
                table_name, ...
                metricsJSON, ...
                N_total, ...
                paramHash, ...
                N_old);
        end

        exec(conn, sqlupdate);

        % Did it apply? ROW_COUNT() reports the statement immediately
        % preceding it on this connection, so nothing may be issued in
        % between. The JDBC driver connects with CLIENT_FOUND_ROWS, so this
        % counts rows MATCHED, not rows changed -- a batch that happens to
        % leave every value identical still reports 1 and is not mistaken
        % for a conflict.
        affected = 0;
        try
            rc = fetch(conn, "SELECT ROW_COUNT() AS rc");
            if ~isempty(rc)
                affected = double(rc{1,1});
            end
        catch
            % Cannot tell. Assume it applied rather than risk
            % double-counting the batch on a retry; the guard still
            % prevented any incorrect write from landing.
            affected = 1;
        end

        if affected == 0
            % Lost the race. Release the mutex so the winner can proceed,
            % back off a randomised interval (so two machines in lockstep
            % do not collide again in phase), then re-read and re-merge.
            if use_mutex
                mysql_unset(conn,mysql_flag_id);
            end
            pause(0.05 + 0.25 * attempt * rand());
            continue
        end

    else % Make new row in DB

        % Use input metrics directly
        metrics = metrics_add;
        N_total = new_frames;
        metricsJSON = jsonencode(metrics);

        if ~isempty(metrics_aux_delta)
            metrics_auxJSON = jsonencode(merge_metrics_aux([], metrics_aux_delta));
        elseif ~isempty(metrics_aux_new)
            metrics_auxJSON = jsonencode(metrics_aux_new);
        else
            metrics_auxJSON = [];
        end

        if ~isempty(metrics_auxJSON)
            sim_result_new = table( ...
                string(paramHash), ...
                string(paramsJSON), ...
                string(metricsJSON), ...
                string(metrics_auxJSON), ...
                N_total, ...
                'VariableNames', {'param_hash', 'parameters', 'metrics', 'metrics_aux', 'frames_simulated'} );
        else
            sim_result_new = table( ...
                string(paramHash), ...
                string(paramsJSON), ...
                string(metricsJSON), ...
                N_total, ...
                'VariableNames', {'param_hash', 'parameters', 'metrics', 'frames_simulated'} );
        end

        try
            sqlwrite(conn,table_name,sim_result_new);
        catch ME
            % Two writers can both find no row and both INSERT; param_hash
            % is the primary key, so the loser is rejected on duplicate
            % key. That is the create-time form of the same race, and the
            % answer is the same: go round again, find the row the winner
            % created, and accumulate into it.
            if contains(ME.message, 'Duplicate entry', 'IgnoreCase', true)
                if use_mutex
                    mysql_unset(conn,mysql_flag_id);
                end
                pause(0.05 + 0.25 * attempt * rand());
                continue
            end
            if use_mutex
                mysql_unset(conn,mysql_flag_id);
            end
            rethrow(ME);
        end

    end

    % Release mutex and exit loop
    if use_mutex
        mysql_unset(conn,mysql_flag_id);
    end
    need_to_write = false;

end

if aux_conflict_unresolvable
    warning('mysql_write:auxNotMergedUnderContention', ...
        ['Concurrent write detected on param_hash %s. frames_simulated ' ...
         'and metrics were merged correctly, but metrics_aux was left ' ...
         'unchanged because this caller supplied only a cumulative ' ...
         'aggregate, which cannot be re-merged against the new base. ' ...
         'Pass the per-batch aggregate as the 3rd optional argument to ' ...
         'make metrics_aux concurrency-safe too.'], paramHash);
end

function status = results_write(conn, table_name, parameters, new_frames, metrics_add, opts)
% RESULTS_WRITE  Write one batch of frames to this computer's result stores.
%
%   status = results_write(conn, table_name, parameters, new_frames, metrics_add, opts)
%
%   The single write entry point for collect_profile and sim_save (storage
%   steps 2 and 5, notes/STORAGE_BACKENDS_PLAN.md). The batch goes to this
%   computer's primary store with full guarantees, then, best effort, to
%   each of its mirrors with the same batch_uid.
%
%   INPUTS:
%     conn, table_name     the primary store's connection and table
%     parameters, new_frames, metrics_add   as for mysql_write
%     opts                 struct: use_mutex, metrics_aux_cumulative,
%                          metrics_aux_delta, metrics_n_add, and batch, the
%                          batch_record carrying the caller's batch_uid
%                          (new_batch_uid, made once per batch and reused on
%                          its retries)
%
%   OUTPUT:
%     status: the primary's "committed" or "already_recorded" (see mysql_write).
%
%   MIRRORS: written after the primary commits (or already holds the batch,
%   since a lost reply may have skipped a mirror too), in priority order,
%   with a 10 s lock cap. A failure marks the mirror stale in
%   store_status.json with a warning (storage:mirrorStale), and collection
%   continues; a stale mirror is skipped until store_resync rebuilds it.
%   Mirrors are skipped when the write is not to the primary's own table
%   (a test_* run). Workers may reach the primary and a mirror in different
%   orders, so their means can differ by rounding (about 1e-16); store_check
%   compares to 1e-12.
%
%   LIMITS: a file primary (storage step 6b) has file mirrors only (machine_stores).

% This computer's stores (MySQL only, without a registry or an entry)
st = [];
writer = host_id();
reg = db_registry();
if ~isempty(reg)
    k = find([reg.role] == "machine" & [reg.writer] == writer, 1);
    if ~isempty(k), st = machine_stores(reg(k)); end
end
kind = "mysql";
if ~isempty(st), kind = st(1).kind; end

% The primary, with full guarantees; its error propagates and no mirror is touched
ad = store_adapter(kind);
status = ad.write(conn, table_name, parameters, new_frames, metrics_add, opts);

% Mirrors: only for writes to the primary's own table, and only those not marked stale
if numel(st) < 2 || string(table_name) ~= st(1).table, return; end
S = store_status(writer);
for j = 2:numel(st)
    key = store_key(st(j));
    i = find(strcmp({S.key}, key), 1);
    if ~isempty(i) && S(i).stale, continue; end

    % An Excel mirror is a whole-file export, rewritten by store_flush at the end of a run, never per batch (step 7a)
    if st(j).kind == "excel", continue; end

    % Same batch, same uid, short lock cap; a failure marks the mirror stale
    w = warning('off', 'mysql_write:batchAlreadyRecorded');
    try
        am = store_adapter(st(j).kind);
        cm = am.open(st(j));
        o = opts; o.lock_timeout = 10;
        am.write(cm, st(j).table, parameters, new_frames, metrics_add, o);
        if st(j).kind == "sqlite", close(cm); end
        warning(w);
    catch ME
        warning(w);
        uid = "";
        if isfield(opts, 'batch') && isfield(opts.batch, 'batch_uid'), uid = string(opts.batch.batch_uid); end
        store_status(writer, key, struct('stale', true, 'reason', "write failed: " + string(ME.message), ...
            'first_uid', uid, 'time', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'))));
        warning('storage:mirrorStale', 'Mirror %s marked stale (%s); collection continues on the primary.', key, ME.message);
    end
end
end

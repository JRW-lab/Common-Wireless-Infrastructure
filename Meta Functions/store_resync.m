function r = store_resync(mirror)
% STORE_RESYNC  Rebuild one of this computer's mirrors from its primary, then check it.
%
%   r = store_resync(mirror)   mirror: a machine_stores element (priority >= 2)
%
%   Storage step 5 (notes/STORAGE_BACKENDS_PLAN.md). The primary's rows and
%   ledger are read while collection is on hold on this computer (so the
%   view is consistent), the mirror's contents are replaced with them
%   (store_adapter import: SQLite tables copied; text gets seed_row and
%   ledger_import lines, the old log kept aside), and store_check then runs
%   in full. The mirror's stale flag is cleared only if that check passes;
%   the status records the primary's last batch_id that the rebuild covered.
%
%   OUTPUT: r, the store_check result.
%
%   LIMITS: refused (storage:resyncNeedsHold) unless
%   collectors/HOLD_<COMPUTERNAME> exists, since a write during the rebuild
%   would be lost from the mirror. The primary may be MySQL or SQLite;
%   from a text primary it is refused (storage:resyncNotBuilt, step 6b).

% Only with collection on hold on this computer
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
writer = host_id();
if ~isfile(fullfile(root, 'collectors', "HOLD_" + writer))
    error('storage:resyncNeedsHold', ['store_resync needs collection on hold on this computer ' ...
        '(collectors/HOLD_%s), so no batch is written during the rebuild.'], writer);
end

% The primary's rows and ledger, and how far the ledger reaches
reg = db_registry();
st = machine_stores(reg([reg.role] == "machine" & [reg.writer] == writer));
P = st(1);
assert(mirror.priority >= 2, 'storage:resyncPrimary', 'The primary itself can not be resynced.');
if P.kind == "text"
    error('storage:resyncNotBuilt', 'Rebuilding a mirror from a %s primary is not built (storage step 6b).', P.kind);
end
assert(mirror.kind ~= "excel", 'storage:resyncExcel', 'An Excel mirror is rewritten by store_flush, not resynced.');
[R, L] = store_dump(P);
last_id = 0;
if height(L) > 0, last_id = max(double(L.batch_id)); end

% Replace the mirror's contents, then compare it in full
am = store_adapter(mirror.kind);
cm = am.open(mirror);
if height(L) == 0
    L = cell2table(cell(0, 12), 'VariableNames', {'param_hash','machine','lane','seed_base','k_start','n_frames', ...
        'batch_uid','code_rev','matlab_release','started_at','finished_at','delta'});
end
am.import(cm, R, L);
if mirror.kind == "sqlite", close(cm); end
r = store_check(mirror);

% Clear the stale flag only when the rebuilt mirror matches
key = store_key(mirror);
if r.ok
    store_status(writer, key, struct('stale', false, 'reason', sprintf('resynced up to primary batch_id %d', last_id), ...
        'first_uid', "", 'time', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'))));
else
    warning('storage:resyncCheckFailed', 'Mirror %s still differs from the primary after resync: %s. It stays stale.', key, r.detail);
end
end


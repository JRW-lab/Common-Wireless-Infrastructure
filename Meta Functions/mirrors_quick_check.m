function n_behind = mirrors_quick_check()
% MIRRORS_QUICK_CHECK  Mark this computer's mirrors stale when they have fallen behind the primary.
%
%   n_behind = mirrors_quick_check()
%
%   A process that dies between committing a batch to the primary and
%   writing it to a mirror sets no stale flag, because nothing failed
%   (laptop review, 2026-10-21). So collect_profile and sim_head run this at
%   their start and normal end: each non-stale mirror's ledger batch count
%   and frame sum are compared with the primary's (store_check "quick"), and
%   a mismatch marks it stale with the reason "behind primary".
%
%   OUTPUT: n_behind, the number of mirrors newly marked stale. Without a
%   registry, a machine entry or mirrors it does nothing and returns 0.
%
%   LIMITS: run when no batch is in flight on this computer (start and end
%   of a run), or a batch between its primary and mirror writes is counted
%   as "behind". A mirror that can't even be opened is marked stale too.

% This computer's mirrors and their status
n_behind = 0;
writer = host_id();
reg = db_registry();
if isempty(reg), return; end
k = find([reg.role] == "machine" & [reg.writer] == writer, 1);
if isempty(k), return; end
st = machine_stores(reg(k));
if numel(st) < 2, return; end
S = store_status(writer);

% Compare each non-stale mirror with the primary
for j = 2:numel(st)
    % An Excel mirror is rewritten whole at the end of each run, so it is never "behind" (step 7a)
    if st(j).kind == "excel", continue; end
    key = store_key(st(j));
    i = find(strcmp({S.key}, key), 1);
    if ~isempty(i) && S(i).stale, continue; end
    try
        r = store_check(st(j), "quick");
        ok = r.ok; why = "behind primary: " + string(r.detail);
    catch ME
        ok = false; why = "check failed: " + string(ME.message);
    end
    if ~ok
        store_status(writer, key, struct('stale', true, 'reason', why, 'first_uid', "", ...
            'time', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'))));
        warning('storage:mirrorStale', 'Mirror %s marked stale (%s).', key, why);
        n_behind = n_behind + 1;
    end
end
end

function uid = new_batch_uid()
% NEW_BATCH_UID  A random, unique identifier for one batch of frames.
%
%   uid = new_batch_uid()
%
%   Every batch written to a results store carries a batch_uid, made ONCE by
%   the caller before the first write attempt and reused only for that
%   batch's retries (user decision B, 2026-10-21; STORAGE_BACKENDS_PLAN.md
%   section 12 B). The ledger keeps it UNIQUE, so a retry after a lost reply
%   is recognised as already recorded and the batch counts once.
%
%   OUTPUT:
%     uid: 64-character lowercase hex string, SHA-256 of COMPUTERNAME,
%          process ID, wall-clock microseconds and a per-process counter.
%
%   LIMITS: random on purpose, also for Phase 3 batches. A uid derived from
%   the frame range would make a lost reply and a replayed k range look the
%   same (laptop session review, 2026-10-21).

% Per-process counter, so two batches in one microsecond still differ
persistent counter
if isempty(counter), counter = 0; end
counter = counter + 1;

% Hash the identity, the time and the counter
key = sprintf('%s|%d|%.0f|%d', char(host_id()), feature('getpid'), posixtime(datetime('now')) * 1e6, counter);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(int8(md.digest(uint8(key))), 'uint8');
uid = string(lower(reshape(dec2hex(d, 2).', 1, [])));
end
